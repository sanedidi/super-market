package start

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Новый товар по фото («Начало работы», вкладка «Новые»). Товара нет ни в
// базе, ни в каталоге ИКПУ: магазин фотографирует его (1–3 фото) и работает
// дальше. Super Market в фоне заполняет карточку: название ru/uz, бренд,
// единицу, категорию (из дерева или новую) и ищет похожий товар в базе.
// Распознал уверенно и это не дубль (нет похожего товара в базе и похожей
// карточки в очереди) — товар сети (статус draft) создаётся сам и встаёт в
// «Мои товары». Остальное (дубли, сомнения, не распознал) магазин видит во
// вкладке «Требуют внимания» и подтверждает сам. На модерацию в общую базу
// товар уходит при «Записать и закрыть».
//
// ИИ не подключён или не справился — карточка в статусе failed: фото и
// штрихкод уже есть, остальное магазин заполняет сам.

const (
	NewProcessing = "processing"
	NewReady      = "ready"
	NewFailed     = "failed"
	NewDone       = "done"

	maxNewImages = 3
	// Через столько «распознаётся» считается зависшим (сервер перезапускали).
	newStale = 5 * time.Minute
)

// NewItemInput — POST /store/start/new-items.
type NewItemInput struct {
	StoreID string   `json:"store_id"`
	Barcode string   `json:"barcode"`
	Images  []string `json:"images"`
}

// NewItemMatch — похожий товар, который уже есть в базе.
type NewItemMatch struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Image     *string `json:"image"`
	Barcode   *string `json:"barcode"`
	Own       bool    `json:"own"`
}

// NewItemResult — карточка, которую заполнил Super Market.
type NewItemResult struct {
	Name        string              `json:"name"`
	NameUz      string              `json:"name_uz"`
	Brand       string              `json:"brand"`
	BrandID     *string             `json:"brand_id"`
	Description string              `json:"description"`
	UnitID      string              `json:"unit_id"`
	UnitShort   string              `json:"unit_short"`
	Suggestion  *CategorySuggestion `json:"suggestion"`
	Match       *NewItemMatch       `json:"match"`
	// Note — почему карточка требует внимания магазина (Super Market что-то
	// домыслил). Пусто — сомнений не было.
	Note string `json:"note"`
}

// NewItemDup — другая карточка в «Новых» этого магазина, похожая на эту:
// тот же штрихкод или похожее название (по распознанному). Помечается
// только более поздняя карточка из пары — её магазин и сверяет («Это он»).
type NewItemDup struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	Image   *string `json:"image"`
	Barcode string  `json:"barcode"`
	Status  string  `json:"status"`
}

// NewItem — фото нового товара в очереди. Images — ключи хранилища (ссылки
// подставляет HTTP-слой).
type NewItem struct {
	ID        string         `json:"id"`
	StoreID   string         `json:"store_id"`
	Status    string         `json:"status"`
	Error     string         `json:"error"`
	Barcode   string         `json:"barcode"`
	Images    []string       `json:"images"`
	Result    *NewItemResult `json:"result"`
	ProductID *string        `json:"product_id"`
	CreatedAt time.Time      `json:"created_at"`
	// Duplicate — похоже, этот товар уже есть в «Новых» (см. NewItemDup).
	Duplicate *NewItemDup `json:"duplicate"`
}

type NewItemCounts struct {
	Processing int `json:"processing"`
	Ready      int `json:"ready"`
	Failed     int `json:"failed"`
}

// NewItemList — страница очереди. Counts и Total — по всей очереди магазина,
// а не по странице.
type NewItemList struct {
	Items  []NewItem     `json:"items"`
	Counts NewItemCounts `json:"counts"`
	Total  int           `json:"total"`
}

func errNewOff(lang string) string {
	return i18n.Pick(lang, "Super Market пока не распознаёт фото — заполните карточку сами", "Super Market hozircha rasmni aniqlamaydi — kartochkani oʻzingiz toʻldiring")
}

func errNewStale(lang string) string {
	return i18n.Pick(lang, "Super Market не ответил — попробуйте ещё раз или заполните сами", "Super Market javob bermadi — qayta urinib koʻring yoki oʻzingiz toʻldiring")
}

// CreateNewItem — фото загружены (/store/uploads); Super Market заполняет карточку в фоне.
func (s *Service) CreateNewItem(ctx context.Context, p *identity.Principal, in NewItemInput) (NewItem, error) {
	st, err := s.store(ctx, s.pool, p, in.StoreID)
	if err != nil {
		return NewItem{}, err
	}
	if len(in.Images) == 0 || len(in.Images) > maxNewImages {
		return NewItem{}, apperr.Validation("images: от 1 до 3 фото").Uz("images: 1 dan 3 tagacha rasm")
	}
	keys := make([]string, 0, len(in.Images))
	for _, u := range in.Images {
		k, ok := media.KeyFromURL(u)
		if !ok {
			return NewItem{}, apperr.Validation("images: фото должно быть загружено через /store/uploads").Uz("images: rasm /store/uploads orqali yuklangan boʻlishi kerak")
		}
		keys = append(keys, k)
	}
	code := strings.TrimSpace(in.Barcode)
	if code != "" && !barcodeRe.MatchString(code) {
		return NewItem{}, apperr.Validation("barcode: неверный штрихкод").Uz("barcode: shtrix-kod notoʻgʻri")
	}
	lang := i18n.FromContext(ctx)
	status, msg := NewProcessing, ""
	if _, err := s.ai.Conn(ctx); err != nil {
		if ae, ok := apperr.As(err); !ok || ae.Code != "ai_not_configured" {
			return NewItem{}, err
		}
		status, msg = NewFailed, errNewOff(lang)
	}
	var id, existing string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if code != "" {
			// Тот же штрихкод уже в «Новых» — вторую карточку не заводим (даже
			// если два сотрудника сканируют одновременно: блокировка на штрихкод).
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('start_new_items:' || $1::text || ':' || $2))`, st.ID, code); err != nil {
				return err
			}
			err := tx.QueryRow(ctx, `SELECT id FROM start_new_items WHERE store_id = $1 AND barcode = $2 AND status <> 'done' ORDER BY created_at LIMIT 1`,
				st.ID, code).Scan(&existing)
			if err == nil {
				return nil
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		return tx.QueryRow(ctx, `
			INSERT INTO start_new_items (network_id, store_id, created_by, barcode, images, status, error)
			VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
			p.NetworkID, st.ID, p.EmployeeID, code, keys, status, msg).Scan(&id)
	})
	if err != nil {
		return NewItem{}, err
	}
	if existing != "" {
		return NewItem{}, errNewExists(existing)
	}
	if status == NewProcessing {
		s.startNewItem(id, lang)
	}
	return s.GetNewItem(ctx, p, id)
}

const newItemSelect = `
	SELECT id, store_id,
	       CASE WHEN status = 'processing' AND updated_at < now() - $3::interval THEN 'failed' ELSE status END,
	       CASE WHEN status = 'processing' AND updated_at < now() - $3::interval THEN $4 ELSE error END,
	       barcode, images, result, product_id, created_at
	FROM start_new_items`

func scanNewItem(r pgx.CollectableRow) (NewItem, error) {
	var it NewItem
	var raw []byte
	err := r.Scan(&it.ID, &it.StoreID, &it.Status, &it.Error, &it.Barcode, &it.Images, &raw, &it.ProductID, &it.CreatedAt)
	if err == nil && (it.Status == NewReady || it.Status == NewFailed) && len(raw) > 2 {
		var res NewItemResult
		if json.Unmarshal(raw, &res) == nil {
			it.Result = &res
		}
	}
	return it, err
}

// newItemArgs — $1, $2 и параметры зависших ($3, $4) для newItemSelect.
func newItemArgs(ctx context.Context, a, b string) []any {
	return []any{a, b, newStale.String(), errNewStale(i18n.FromContext(ctx))}
}

// ListNewItems — очередь магазина без добавленных: готовые к проверке сверху.
// Страница — page (limit/offset); счётчики — по всей очереди.
func (s *Service) ListNewItems(ctx context.Context, p *identity.Principal, storeID string, page httpx.Page) (NewItemList, error) {
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return NewItemList{}, err
	}
	out := NewItemList{Items: []NewItem{}}
	cnt, err := s.pool.Query(ctx, `
		SELECT CASE WHEN status = 'processing' AND updated_at < now() - $3::interval THEN 'failed' ELSE status END, count(*)
		FROM start_new_items WHERE store_id = $1 AND network_id = $2 AND status <> 'done'
		GROUP BY 1`, st.ID, p.NetworkID, newStale.String())
	if err != nil {
		return out, err
	}
	var status string
	var n int
	if _, err := pgx.ForEachRow(cnt, []any{&status, &n}, func() error {
		switch status {
		case NewProcessing:
			out.Counts.Processing += n
		case NewReady:
			out.Counts.Ready += n
		case NewFailed:
			out.Counts.Failed += n
		}
		out.Total += n
		return nil
	}); err != nil {
		return out, err
	}
	if out.Total == 0 || page.Offset >= out.Total {
		return out, nil
	}
	// id — для стабильного порядка между страницами.
	rows, err := s.pool.Query(ctx, `SELECT * FROM (`+newItemSelect+` WHERE store_id = $1 AND network_id = $2 AND status <> 'done') x
		ORDER BY x.status = 'ready' DESC, x.status = 'failed' DESC, x.created_at DESC, x.id
		LIMIT `+strconv.Itoa(page.Limit)+` OFFSET `+strconv.Itoa(page.Offset), newItemArgs(ctx, st.ID, p.NetworkID)...)
	if err != nil {
		return out, err
	}
	if out.Items, err = pgx.CollectRows(rows, scanNewItem); err != nil {
		return out, err
	}
	if err := s.attachDuplicates(ctx, out.Items); err != nil {
		return out, err
	}
	return out, nil
}

func (s *Service) GetNewItem(ctx context.Context, p *identity.Principal, id string) (NewItem, error) {
	if !httpx.IsUUID(id) {
		return NewItem{}, errNewNotFound()
	}
	rows, err := s.pool.Query(ctx, newItemSelect+` WHERE id = $1 AND network_id = $2`, newItemArgs(ctx, id, p.NetworkID)...)
	if err != nil {
		return NewItem{}, err
	}
	it, err := pgx.CollectExactlyOneRow(rows, scanNewItem)
	if errors.Is(err, pgx.ErrNoRows) {
		return NewItem{}, errNewNotFound()
	}
	if err != nil {
		return NewItem{}, err
	}
	if err := require(p, it.StoreID); err != nil {
		return NewItem{}, err
	}
	items := []NewItem{it}
	if err := s.attachDuplicates(ctx, items); err != nil {
		return NewItem{}, err
	}
	return items[0], nil
}

// dupSQL — для карточек $1 (ещё не добавленных) самая похожая более ранняя
// карточка в «Новых» того же магазина: тот же штрихкод или похожее название.
const dupSQL = `
	SELECT x.id, d.id, d.name, d.image, d.barcode, d.status
	FROM start_new_items x
	JOIN LATERAL (
		SELECT o.id, COALESCE(o.result->>'name', '') AS name, o.images[1] AS image, o.barcode,
		       CASE WHEN o.status = 'processing' AND o.updated_at < now() - $2::interval THEN 'failed' ELSE o.status END AS status
		FROM start_new_items o
		WHERE o.store_id = x.store_id AND o.id <> x.id AND o.status <> 'done'
		  AND (o.created_at, o.id) < (x.created_at, x.id)
		  AND ((x.barcode <> '' AND o.barcode = x.barcode)
		       OR (COALESCE(x.result->>'name', '') <> '' AND COALESCE(o.result->>'name', '') <> ''
		           AND similarity(lower(o.result->>'name'), lower(x.result->>'name')) >= $3))
		ORDER BY (x.barcode <> '' AND o.barcode = x.barcode) DESC,
		         similarity(lower(COALESCE(o.result->>'name', '')), lower(COALESCE(x.result->>'name', ''))) DESC, o.created_at
		LIMIT 1
	) d ON true
	WHERE x.id = ANY($1::uuid[]) AND x.status <> 'done'`

// attachDuplicates — заполнить Duplicate у карточек (см. NewItemDup).
func (s *Service) attachDuplicates(ctx context.Context, items []NewItem) error {
	if len(items) == 0 {
		return nil
	}
	ids := make([]string, len(items))
	at := make(map[string]int, len(items))
	for i, it := range items {
		ids[i] = it.ID
		at[it.ID] = i
	}
	rows, err := s.pool.Query(ctx, dupSQL, ids, newStale.String(), SimilarMin)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var d NewItemDup
		if err := rows.Scan(&id, &d.ID, &d.Name, &d.Image, &d.Barcode, &d.Status); err != nil {
			return err
		}
		if i, ok := at[id]; ok {
			dup := d
			items[i].Duplicate = &dup
		}
	}
	return rows.Err()
}

// NewItemByBarcode — карточка в «Новых» магазина с этим штрихкодом (nil — нет):
// сканер проверяет её, прежде чем предлагать «Новый товар».
func (s *Service) NewItemByBarcode(ctx context.Context, p *identity.Principal, storeID, code string) (*NewItem, error) {
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return nil, err
	}
	code = strings.TrimSpace(code)
	if !barcodeRe.MatchString(code) {
		return nil, nil
	}
	var id string
	err = s.pool.QueryRow(ctx, `SELECT id FROM start_new_items WHERE store_id = $1 AND network_id = $2 AND barcode = $3 AND status <> 'done' ORDER BY created_at LIMIT 1`,
		st.ID, p.NetworkID, code).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	it, err := s.GetNewItem(ctx, p, id)
	if err != nil {
		return nil, err
	}
	return &it, nil
}

// NewItemMerge — POST /store/start/new-items/{id}/merge: «Это он» — эта
// карточка — тот же товар, что Into. Фото переходят к Into (не больше
// maxMergedImages), штрихкод — если у Into его нет; эта карточка удаляется.
type NewItemMerge struct {
	StoreID string `json:"store_id"`
	Into    string `json:"into"`
}

const maxMergedImages = 6

func (s *Service) MergeNewItem(ctx context.Context, p *identity.Principal, id string, in NewItemMerge) (NewItem, error) {
	if !httpx.IsUUID(id) {
		return NewItem{}, errNewNotFound()
	}
	if !httpx.IsUUID(in.Into) || in.Into == id {
		return NewItem{}, apperr.Validation("into: выберите другую карточку").Uz("into: boshqa kartochkani tanlang")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, in.StoreID)
		if err != nil {
			return err
		}
		type card struct {
			barcode, status string
			images          []string
		}
		got := map[string]card{}
		rows, err := tx.Query(ctx, `SELECT id, barcode, status, images FROM start_new_items WHERE id = ANY($1::uuid[]) AND store_id = $2 AND network_id = $3 ORDER BY id FOR UPDATE`,
			[]string{id, in.Into}, st.ID, p.NetworkID)
		if err != nil {
			return err
		}
		for rows.Next() {
			var cid string
			var c card
			if err := rows.Scan(&cid, &c.barcode, &c.status, &c.images); err != nil {
				rows.Close()
				return err
			}
			got[cid] = c
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		src, ok1 := got[id]
		dst, ok2 := got[in.Into]
		if !ok1 || !ok2 {
			return errNewNotFound()
		}
		if src.status == NewDone {
			return apperr.Conflict("already_added", "товар уже добавлен").Uz("mahsulot allaqachon qoʻshilgan")
		}
		if dst.status == NewDone {
			return apperr.Conflict("into_added", "та карточка уже добавлена в «Мои товары» — просто уберите эту").
				Uz("u kartochka allaqachon «Mening mahsulotlarim»ga qoʻshilgan — buni olib tashlang")
		}
		images := dst.images
		seen := map[string]bool{}
		for _, k := range images {
			seen[k] = true
		}
		for _, k := range src.images {
			if len(images) >= maxMergedImages {
				break
			}
			if !seen[k] {
				images = append(images, k)
				seen[k] = true
			}
		}
		code := dst.barcode
		if code == "" {
			code = src.barcode
		}
		if _, err := tx.Exec(ctx, `DELETE FROM start_new_items WHERE id = $1`, id); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE start_new_items SET images = $2, barcode = $3 WHERE id = $1`, in.Into, images, code)
		return err
	})
	if err != nil {
		return NewItem{}, err
	}
	return s.GetNewItem(ctx, p, in.Into)
}

// errNewExists — штрихкод уже в «Новых»: details.item_id — та карточка.
func errNewExists(id string) error {
	return apperr.Conflict("new_item_exists", "этот товар уже в «Новых» — проверьте его карточку").
		Uz("bu mahsulot allaqachon «Yangilar»da — uning kartochkasini tekshiring").
		WithDetails(map[string]any{"item_id": id})
}

func errNewNotFound() error {
	return apperr.NotFound("карточка не найдена").Uz("kartochka topilmadi")
}

// RetryNewItem — распознать заново (не получилось или зависло).
func (s *Service) RetryNewItem(ctx context.Context, p *identity.Principal, id string) (NewItem, error) {
	it, err := s.GetNewItem(ctx, p, id)
	if err != nil {
		return it, err
	}
	if it.Status != NewFailed {
		return it, apperr.Conflict("not_failed", "карточка уже готова или распознаётся").Uz("kartochka tayyor yoki aniqlanmoqda")
	}
	if _, err := s.ai.Conn(ctx); err != nil {
		if ae, ok := apperr.As(err); ok && ae.Code == "ai_not_configured" {
			return it, apperr.Conflict("ai_not_configured", errNewOff(i18n.RU)).Uz(errNewOff(i18n.UZ))
		}
		return it, err
	}
	if _, err := s.pool.Exec(ctx, `UPDATE start_new_items SET status = 'processing', error = '' WHERE id = $1 AND status <> 'done'`, id); err != nil {
		return it, err
	}
	s.startNewItem(id, i18n.FromContext(ctx))
	return s.GetNewItem(ctx, p, id)
}

// DeleteNewItem — убрать карточку из очереди (товар не создаётся).
func (s *Service) DeleteNewItem(ctx context.Context, p *identity.Principal, id string) error {
	if _, err := s.GetNewItem(ctx, p, id); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `DELETE FROM start_new_items WHERE id = $1 AND status <> 'done'`, id)
	if err == nil && tag.RowsAffected() == 0 {
		return errNewNotFound()
	}
	return err
}

func (s *Service) startNewItem(id, lang string) {
	s.run(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		if err := s.processNewItem(ctx, id, lang); err != nil {
			msg := i18n.Pick(lang, "Super Market не смог разобрать фото — переснимите или заполните сами",
				"Super Market rasmni aniqlay olmadi — qayta suratga oling yoki oʻzingiz toʻldiring")
			var ae *apperr.Error
			switch {
			case errors.As(err, &ae) && ae.Code == "ai_not_configured":
				msg = errNewOff(lang)
			case errors.As(err, &ae) && ae.Status < 500:
				msg = ae.Text(lang)
			default:
				s.log.Error("start new item", "id", id, "err", err)
			}
			if _, err := s.pool.Exec(context.Background(),
				`UPDATE start_new_items SET status = 'failed', error = $2 WHERE id = $1 AND status = 'processing'`, id, msg); err != nil {
				s.log.Error("start new item fail", "id", id, "err", err)
			}
		}
	})
}

func (s *Service) processNewItem(ctx context.Context, id, lang string) error {
	var keys []string
	var networkID, storeID, employeeID, code string
	if err := s.pool.QueryRow(ctx, `SELECT images, network_id, store_id, created_by, barcode FROM start_new_items WHERE id = $1`, id).
		Scan(&keys, &networkID, &storeID, &employeeID, &code); err != nil {
		return err
	}
	conn, err := s.ai.Conn(ctx)
	if err != nil {
		return err
	}
	images := make([]ai.Image, 0, len(keys))
	for _, k := range keys {
		data, mime, err := s.media.Read(ctx, k)
		if err != nil {
			return apperr.Validation("фото не найдено в хранилище").Uz("rasm serverda topilmadi")
		}
		images = append(images, ai.Image{MIME: mime, Data: data})
	}
	tree, err := loadTree(ctx, s.pool)
	if err != nil {
		return err
	}
	ans, u, err := conn.RecognizeProduct(ctx, ai.ProductAsk{Images: images, Barcode: code, Sections: tree.sections(), Leaves: tree.leaves()})
	if u.Input+u.Output > 0 || err == nil {
		pp := &identity.Principal{NetworkID: networkID, EmployeeID: employeeID}
		s.usage(pp, storeID, "product", conn, u, err == nil)
	}
	if err != nil {
		return err
	}
	if !ans.Product {
		msg := strings.TrimSpace(ans.Problem)
		if msg == "" || lang == i18n.UZ {
			msg = i18n.Pick(lang, "на фото не удалось разглядеть товар", "rasmda mahsulotni aniqlab boʻlmadi")
		}
		return apperr.Validation(upperFirst(msg) + " — переснимите или заполните сами").
			Uz(upperFirst(msg) + " — qayta suratga oling yoki oʻzingiz toʻldiring")
	}
	res := NewItemResult{Name: ans.Name, NameUz: ans.NameUz, Brand: ans.Brand, Description: strings.TrimSpace(ans.Description)}
	if res.Brand != "" {
		if bid, err := catalog.BrandByName(ctx, s.pool, res.Brand); err != nil {
			return err
		} else if bid != "" {
			res.BrandID = &bid
		}
	}
	unit := "шт"
	if strings.EqualFold(strings.TrimSpace(ans.Unit), "кг") {
		unit = "кг"
	}
	if res.UnitID, err = catalog.UnitByShort(ctx, s.pool, unit); err != nil {
		return err
	}
	res.UnitShort = unit
	res.Suggestion = tree.suggestion(ans.Match, ans.Alternatives, ans.New)
	if res.Match, err = similarProduct(ctx, s.pool, networkID, ans.Name, ans.NameUz); err != nil {
		return err
	}
	if !strings.EqualFold(strings.TrimSpace(ans.Confidence), "high") {
		res.Note = strings.TrimSpace(ans.Note)
	}
	raw, _ := json.Marshal(res)
	if _, err := s.pool.Exec(ctx, `UPDATE start_new_items SET status = 'ready', error = '', result = $2 WHERE id = $1 AND status = 'processing'`, id, raw); err != nil {
		return err
	}
	// Сомнений нет — товар встаёт в «Мои товары» сам; магазину остаётся
	// только то, что требует внимания.
	_, err = s.tryAutoAdd(ctx, id, networkID, storeID, employeeID, res, keys)
	return err
}

// tryAutoAdd — добавить готовую карточку в «Мои товары», если она не требует
// внимания (см. canAutoAdd). Похожий товар базы перепроверяется прямо сейчас:
// пока карточка ждала, такой товар мог появиться (например, его добавили из
// более ранней карточки) — тогда Match сохраняется в карточку для магазина.
func (s *Service) tryAutoAdd(ctx context.Context, id, networkID, storeID, employeeID string, res NewItemResult, keys []string) (bool, error) {
	match, err := similarProduct(ctx, s.pool, networkID, res.Name, res.NameUz)
	if err != nil {
		return false, err
	}
	if match != nil && res.Match == nil {
		res.Match = match
		raw, _ := json.Marshal(res)
		if _, err := s.pool.Exec(ctx, `UPDATE start_new_items SET result = $2 WHERE id = $1 AND status = 'ready'`, id, raw); err != nil {
			return false, err
		}
	}
	ok, err := s.canAutoAdd(ctx, id, res)
	if err != nil || !ok {
		return false, err
	}
	return s.autoAddNewItem(ctx, id, networkID, storeID, employeeID, res, keys), nil
}

// SweepNewItems — разово пройти карточки «ready», распознанные до
// автодобавления (или когда оно не сработало), и добавить те, что не требуют
// внимания. По порядку создания: из пары похожих добавится ранняя, а поздняя
// увидит её как похожий товар и останется магазину.
func (s *Service) SweepNewItems() {
	s.run(func() {
		ctx := context.Background()
		type card struct {
			id, networkID, storeID, employeeID string
			keys                               []string
			raw                                []byte
		}
		rows, err := s.pool.Query(ctx, `SELECT id, network_id, store_id, created_by, images, result FROM start_new_items
			WHERE status = 'ready' ORDER BY created_at, id`)
		if err != nil {
			s.log.Error("новые товары: обход", "err", err)
			return
		}
		var cards []card
		for rows.Next() {
			var c card
			if err := rows.Scan(&c.id, &c.networkID, &c.storeID, &c.employeeID, &c.keys, &c.raw); err != nil {
				rows.Close()
				s.log.Error("новые товары: обход", "err", err)
				return
			}
			cards = append(cards, c)
		}
		rows.Close()
		added := 0
		for _, c := range cards {
			var res NewItemResult
			if len(c.raw) <= 2 || json.Unmarshal(c.raw, &res) != nil {
				continue
			}
			ok, err := s.tryAutoAdd(ctx, c.id, c.networkID, c.storeID, c.employeeID, res, c.keys)
			if err != nil {
				s.log.Error("новые товары: обход", "id", c.id, "err", err)
				continue
			}
			if ok {
				added++
			}
		}
		if len(cards) > 0 {
			s.log.Info("новые товары: добавлены сами", "added", added, "checked", len(cards))
		}
	})
}

// canAutoAdd — карточку можно добавить без магазина: Super Market уверен,
// категория нашлась в дереве, похожего товара в базе нет и в очереди нет
// более ранней похожей карточки (возможного дубля).
func (s *Service) canAutoAdd(ctx context.Context, id string, res NewItemResult) (bool, error) {
	if res.Note != "" || res.Match != nil || strings.TrimSpace(res.Name) == "" || res.UnitID == "" {
		return false, nil
	}
	if res.Suggestion == nil || res.Suggestion.Category == nil {
		return false, nil
	}
	var dupID string
	err := s.pool.QueryRow(ctx, `SELECT q.dup FROM (`+dupSQL+`) AS q(card, dup, name, image, barcode, status) LIMIT 1`,
		[]string{id}, newStale.String(), SimilarMin).Scan(&dupID)
	if errors.Is(err, pgx.ErrNoRows) {
		return true, nil
	}
	return false, err
}

// autoAddNewItem — создать товар и поставить его в «Мои товары» от имени
// магазина. Системный Principal ограничен сетью и магазином самой карточки;
// товар создаётся как свой товар сети в статусе draft и всё равно уходит на
// модерацию при «Записать и закрыть». Не получилось — карточка остаётся
// магазину в «Требует внимания», это не ошибка распознавания.
func (s *Service) autoAddNewItem(ctx context.Context, id, networkID, storeID, employeeID string, res NewItemResult, keys []string) bool {
	images := make([]string, 0, len(keys))
	for _, k := range keys {
		u := s.media.PublicURL(k)
		if u == "" {
			return false
		}
		images = append(images, u)
	}
	in := NewItemConfirm{StoreID: storeID, Name: res.Name, NameUz: res.NameUz, Description: res.Description,
		CategoryID: res.Suggestion.Category.ID, UnitID: res.UnitID, Images: images}
	if res.BrandID != nil {
		in.BrandID = *res.BrandID
	} else {
		in.BrandName = res.Brand
	}
	p := &identity.Principal{NetworkID: networkID, EmployeeID: employeeID, IsOwner: true}
	if _, err := s.ConfirmNewItem(ctx, p, id, in); err != nil {
		s.log.Info("новый товар: не добавили сами", "id", id, "err", err)
		return false
	}
	return true
}

func upperFirst(s string) string {
	r := []rune(s)
	if len(r) == 0 {
		return s
	}
	return strings.ToUpper(string(r[:1])) + string(r[1:])
}

// similarProduct — самый похожий по названию товар базы (общий каталог и свои
// товары сети), если похож достаточно, — чтобы не завести дубль.
func similarProduct(ctx context.Context, q db.Querier, networkID, name, nameUz string) (*NewItemMatch, error) {
	var m NewItemMatch
	err := q.QueryRow(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), p.images[1],
		       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), p.network_id IS NOT NULL
		FROM products p
		WHERE p.is_active AND (p.network_id IS NULL OR p.network_id = $1)
		  AND (lower(p.name) % lower($2) OR ($3 <> '' AND lower(p.name_uz) % lower($3)))
		  AND greatest(similarity(lower(p.name), lower($2)), CASE WHEN $3 <> '' THEN similarity(lower(p.name_uz), lower($3)) ELSE 0 END) >= 0.55
		ORDER BY greatest(similarity(lower(p.name), lower($2)), CASE WHEN $3 <> '' THEN similarity(lower(p.name_uz), lower($3)) ELSE 0 END) DESC, p.id
		LIMIT 1`, networkID, name, nameUz).Scan(&m.ProductID, &m.Name, &m.Image, &m.Barcode, &m.Own)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// NewItemConfirm — POST /store/start/new-items/{id}/confirm: магазин проверил
// карточку. ProductID — «Это он»: добавить похожий товар базы (штрихкод
// привязывается к нему). Иначе — новый товар: категория (category_id или
// new_category), единица, бренд (brand_id или brand_name), фото — ссылки.
type NewItemConfirm struct {
	StoreID     string               `json:"store_id"`
	ProductID   string               `json:"product_id"`
	Name        string               `json:"name"`
	NameUz      string               `json:"name_uz"`
	Description string               `json:"description"`
	BrandID     string               `json:"brand_id"`
	BrandName   string               `json:"brand_name"`
	CategoryID  string               `json:"category_id"`
	NewCategory *catalog.NewCategory `json:"new_category"`
	UnitID      string               `json:"unit_id"`
	Barcode     *string              `json:"barcode"`
	Images      []string             `json:"images"`
}

type NewItemConfirmResult struct {
	ProductID string `json:"product_id"`
	Created   bool   `json:"created"`
	Line      Line   `json:"line"`
	Totals    Totals `json:"totals"`
}

func (s *Service) ConfirmNewItem(ctx context.Context, p *identity.Principal, id string, in NewItemConfirm) (NewItemConfirmResult, error) {
	var out NewItemConfirmResult
	if !httpx.IsUUID(id) {
		return out, errNewNotFound()
	}
	for name, v := range map[string]string{"product_id": in.ProductID, "brand_id": in.BrandID, "category_id": in.CategoryID, "unit_id": in.UnitID} {
		if v != "" && !httpx.IsUUID(v) {
			return out, apperr.Validation(name + ": запись не найдена").Uz(name + ": yozuv topilmadi")
		}
	}
	nameUz := strings.TrimSpace(in.NameUz)
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, in.StoreID)
		if err != nil {
			return err
		}
		var code, status string
		err = tx.QueryRow(ctx, `SELECT barcode, status FROM start_new_items WHERE id = $1 AND store_id = $2 AND network_id = $3 FOR UPDATE`,
			id, st.ID, p.NetworkID).Scan(&code, &status)
		if errors.Is(err, pgx.ErrNoRows) {
			return errNewNotFound()
		}
		if err != nil {
			return err
		}
		if status == NewDone {
			return apperr.Conflict("already_added", "товар уже добавлен").Uz("mahsulot allaqachon qoʻshilgan")
		}
		if in.Barcode != nil {
			code = strings.TrimSpace(*in.Barcode)
		}
		draft, err := s.ensureDraft(ctx, tx, p, st)
		if err != nil {
			return err
		}
		pid := in.ProductID
		src := "new"
		if pid != "" {
			// «Это он» — товар базы; штрихкод — к нему.
			src = "photo"
			if _, err := s.setLine(ctx, tx, p, st, draft, LineInput{ProductID: pid, Add: true, Source: &src, ConfirmSimilar: true}, true); err != nil {
				return err
			}
			if code != "" {
				if err := bindBarcode(ctx, tx, p, pid, code); err != nil {
					return err
				}
			}
		} else {
			if err := p.Require(identity.PermCatalogManage); err != nil {
				return err
			}
			catID := in.CategoryID
			if in.NewCategory != nil {
				if catID, err = catalog.EnsureCategory(ctx, tx, *in.NewCategory); err != nil {
					return err
				}
			}
			if catID == "" {
				return apperr.Validation("category_id: выберите категорию").Uz("category_id: kategoriyani tanlang")
			}
			if in.UnitID == "" {
				return apperr.Validation("unit_id: выберите единицу").Uz("unit_id: oʻlchov birligini tanlang")
			}
			var brandID *string
			if in.BrandID != "" {
				brandID = &in.BrandID
			} else if strings.TrimSpace(in.BrandName) != "" {
				b, err := catalog.EnsureBrand(ctx, tx, in.BrandName)
				if err != nil {
					return err
				}
				brandID = &b
			}
			if code != "" && !barcodeRe.MatchString(code) {
				return apperr.Validation("barcode: неверный штрихкод").Uz("barcode: shtrix-kod notoʻgʻri")
			}
			if pid, err = catalog.CreateDraftProduct(ctx, tx, catalog.DraftProduct{
				NetworkID: p.NetworkID, StoreID: st.ID, Name: in.Name, NameUz: nameUz, Description: in.Description,
				BrandID: brandID, CategoryID: catID, UnitID: in.UnitID, Barcode: code, Images: in.Images, Source: "photo",
			}); err != nil {
				return err
			}
			out.Created = true
			if _, err := s.setLine(ctx, tx, p, st, draft, LineInput{ProductID: pid, Add: true, Source: &src}, false); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE start_new_items SET status = 'done', product_id = $2 WHERE id = $1`, id, pid); err != nil {
			return err
		}
		out.ProductID = pid
		rows, err := tx.Query(ctx, lineSelect+` WHERE l.draft_id = $1 AND l.product_id = $4`, draft, st.PriceTypeID, st.ID, pid)
		if err != nil {
			return err
		}
		if out.Line, err = pgx.CollectExactlyOneRow(rows, scanLine); err != nil {
			return err
		}
		out.Totals, err = s.totals(ctx, tx, draft, st)
		return err
	})
	if err != nil {
		return out, err
	}
	if out.Created && nameUz == "" {
		s.translateName(p, in.StoreID, out.ProductID, strings.TrimSpace(in.Name))
	}
	return out, nil
}
