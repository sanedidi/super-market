package start

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
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
	// SameBarcode — найден по штрихкоду (тот же товар наверняка). Иначе —
	// совпали бренд, объём и фасовка, а штрихкод другой: «Это он» привяжет
	// штрихкод карточки к этому товару.
	SameBarcode bool `json:"same_barcode"`
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
	// Size и Pack — объём/вес («500 мл») и штук в упаковке с этикетки: по ним
	// (и по названию) решается, тот же это товар или другой (см. Spec).
	Size string `json:"size,omitempty"`
	Pack int    `json:"pack,omitempty"`
}

func (r *NewItemResult) spec() Spec { return specOf(r.Name, r.Size, r.Pack) }

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
	// Photo — чистое фото от Super Market (photos_store.go); nil — не делалось.
	Photo *NewItemPhoto `json:"photo"`
	// Duplicate — похоже, этот товар уже есть в «Новых» (см. NewItemDup).
	Duplicate *NewItemDup `json:"duplicate"`
	// BarcodeInvalid — контрольная цифра штрихкода не сходится (опечатка):
	// сам товар не добавляется, магазин проверяет код.
	BarcodeInvalid bool `json:"barcode_invalid"`
}

type NewItemCounts struct {
	Processing int `json:"processing"`
	Ready      int `json:"ready"`
	Failed     int `json:"failed"`
	// Bulk — сколько карточек «Провести все» поставит в «Мои товары».
	Bulk int `json:"bulk"`
}

// NewItemList — страница очереди. Counts и Total — по всей очереди магазина,
// а не по странице.
type NewItemList struct {
	Items  []NewItem     `json:"items"`
	Counts NewItemCounts `json:"counts"`
	Total  int           `json:"total"`
}

// mediaBase — начало ссылки первого фото (см. media.BaseOf).
func mediaBase(images []string) string {
	if len(images) == 0 {
		return ""
	}
	return media.BaseOf(images[0])
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
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('start_new_items:' || $1::text || ':' || barcode_key($2)))`, st.ID, code); err != nil {
				return err
			}
			err := tx.QueryRow(ctx, `SELECT id FROM start_new_items WHERE store_id = $1 AND barcode <> '' AND barcode_key(barcode) = barcode_key($2) AND status <> 'done' ORDER BY created_at LIMIT 1`,
				st.ID, code).Scan(&existing)
			if err == nil {
				return nil
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		return tx.QueryRow(ctx, `
			INSERT INTO start_new_items (network_id, store_id, created_by, barcode, images, status, error, media_base)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
			p.NetworkID, st.ID, p.EmployeeID, code, keys, status, msg, mediaBase(in.Images)).Scan(&id)
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
	       barcode, images, result, product_id, created_at, ` + newItemPhotoSQL + ` AS photo
	FROM start_new_items`

func scanNewItem(r pgx.CollectableRow) (NewItem, error) {
	var it NewItem
	var raw []byte
	var job []string
	err := r.Scan(&it.ID, &it.StoreID, &it.Status, &it.Error, &it.Barcode, &it.Images, &raw, &it.ProductID, &it.CreatedAt, &job)
	it.Photo = newItemPhoto(job)
	it.BarcodeInvalid = it.Barcode != "" && !BarcodeValid(it.Barcode)
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
	if out.Counts.Ready > 0 {
		if out.Counts.Bulk, err = s.bulkReady(ctx, p.NetworkID, st.ID); err != nil {
			return out, err
		}
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

// dupSQL — для карточек $1 (ещё не добавленных) более ранние карточки в
// «Новых» того же магазина — кандидаты в дубли: тот же штрихкод (с точностью
// до ведущих нулей) или похожее название. Решает queueDups — по полям.
const dupSQL = `
	SELECT x.id, x.result, d.id, d.name, d.image, d.barcode, d.status, d.result, d.same_code, d.core
	FROM start_new_items x
	JOIN LATERAL (
		SELECT o.id, COALESCE(o.result->>'name', '') AS name, o.images[1] AS image, o.barcode, o.result,
		       CASE WHEN o.status = 'processing' AND o.updated_at < now() - $2::interval THEN 'failed' ELSE o.status END AS status,
		       (x.barcode <> '' AND o.barcode <> '' AND barcode_key(o.barcode) = barcode_key(x.barcode)) AS same_code,
		       similarity(CORE_O, CORE_X) AS core
		FROM start_new_items o
		WHERE o.store_id = x.store_id AND o.id <> x.id AND o.status <> 'done'
		  AND (o.created_at, o.id) < (x.created_at, x.id)
		  AND ((x.barcode <> '' AND o.barcode <> '' AND barcode_key(o.barcode) = barcode_key(x.barcode))
		       OR (COALESCE(x.result->>'name', '') <> '' AND COALESCE(o.result->>'name', '') <> ''
		           AND similarity(lower(o.result->>'name'), lower(x.result->>'name')) >= $3))
		ORDER BY same_code DESC, core DESC, o.created_at
		LIMIT 5
	) d ON true
	WHERE x.id = ANY($1::uuid[]) AND x.status <> 'done'`

var dupQuery = strings.NewReplacer(
	"CORE_O", coreSQL("COALESCE(o.result->>'name', '')"),
	"CORE_X", coreSQL("COALESCE(x.result->>'name', '')"),
).Replace(dupSQL)

// queueDups — для карточек ids самая ранняя карточка очереди, которая, похоже,
// тот же товар: тот же штрихкод, или бренд, объём и фасовка не противоречат,
// а названия без чисел почти совпадают (см. Spec). Нет — карточки нет в ответе.
func (s *Service) queueDups(ctx context.Context, q db.Querier, ids []string) (map[string]NewItemDup, error) {
	return s.dupsBy(ctx, q, dupQuery, ids)
}

func (s *Service) dupsBy(ctx context.Context, q db.Querier, query string, ids []string) (map[string]NewItemDup, error) {
	out := map[string]NewItemDup{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, query, ids, newStale.String(), CandidateMin)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var xRaw, dRaw []byte
		var d NewItemDup
		var sameCode bool
		var core *float64
		if err := rows.Scan(&id, &xRaw, &d.ID, &d.Name, &d.Image, &d.Barcode, &d.Status, &dRaw, &sameCode, &core); err != nil {
			return nil, err
		}
		if _, done := out[id]; done {
			continue
		}
		if !sameCode && !sameCard(xRaw, dRaw, core) {
			continue
		}
		out[id] = d
	}
	return out, rows.Err()
}

// sameCard — две распознанные карточки с разными штрихкодами — один товар?
func sameCard(xRaw, dRaw []byte, core *float64) bool {
	if core == nil || *core < CoreMin {
		return false
	}
	var x, d NewItemResult
	if json.Unmarshal(xRaw, &x) != nil || json.Unmarshal(dRaw, &d) != nil {
		return false
	}
	return !brandConflicts(x.BrandID, x.Brand, d.BrandID, d.Brand) && !x.spec().Conflicts(d.spec())
}

// attachDuplicates — заполнить Duplicate у карточек (см. NewItemDup).
func (s *Service) attachDuplicates(ctx context.Context, items []NewItem) error {
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.ID
	}
	dups, err := s.queueDups(ctx, s.pool, ids)
	if err != nil {
		return err
	}
	for i := range items {
		if d, ok := dups[items[i].ID]; ok {
			items[i].Duplicate = &d
		}
	}
	return nil
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
	err = s.pool.QueryRow(ctx, `SELECT id FROM start_new_items WHERE store_id = $1 AND network_id = $2 AND barcode <> '' AND barcode_key(barcode) = barcode_key($3) AND status <> 'done' ORDER BY created_at LIMIT 1`,
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
	s.run(func() { s.recognizeNewItem(id, lang) })
}

// recognizeNewItem — распознать одну карточку; не вышло — она «не удалось».
func (s *Service) recognizeNewItem(id, lang string) {
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
}

func (s *Service) processNewItem(ctx context.Context, id, lang string) error {
	var keys []string
	var networkID, storeID, employeeID, code string
	if err := s.pool.QueryRow(ctx, `SELECT images, network_id, store_id, created_by, barcode FROM start_new_items WHERE id = $1`, id).
		Scan(&keys, &networkID, &storeID, &employeeID, &code); err != nil {
		return err
	}
	// Штрихкод уже есть в базе — это тот же товар, распознавать нечего.
	if code != "" {
		m, err := productByBarcode(ctx, s.pool, networkID, code)
		if err != nil {
			return err
		}
		if m != nil {
			res := NewItemResult{Name: m.Name, Match: m}
			raw, _ := json.Marshal(res)
			if _, err := s.pool.Exec(ctx, `UPDATE start_new_items SET status = 'ready', error = '', result = $2 WHERE id = $1 AND status = 'processing'`, id, raw); err != nil {
				return err
			}
			_, err = s.tryAutoAdd(ctx, id, networkID, storeID, employeeID, code, res, keys)
			return err
		}
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
	res := NewItemResult{Name: ans.Name, NameUz: ans.NameUz, Brand: ans.Brand, Description: strings.TrimSpace(ans.Description),
		Size: strings.TrimSpace(ans.Size), Pack: max(ans.Pack, 0)}
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
	if res.Match, err = sameProduct(ctx, s.pool, networkID, code, &res); err != nil {
		return err
	}
	if !strings.EqualFold(strings.TrimSpace(ans.Confidence), "high") && !minorDoubts(ans.Unclear) {
		res.Note = strings.TrimSpace(ans.Note)
		if res.Note == "" {
			res.Note = i18n.Pick(lang, "Super Market не уверен в карточке — проверьте название и категорию", "Super Market kartochkaga ishonchi komil emas — nomi va kategoriyani tekshiring")
		}
	}
	raw, _ := json.Marshal(res)
	if _, err := s.pool.Exec(ctx, `UPDATE start_new_items SET status = 'ready', error = '', result = $2 WHERE id = $1 AND status = 'processing'`, id, raw); err != nil {
		return err
	}
	// Новый товар — Super Market делает его чистое фото (в фоне).
	if res.Match == nil {
		s.photoNewItem(ctx, id, networkID, storeID, employeeID, keys)
	}
	// Сомнений нет — товар встаёт в «Мои товары» сам; магазину остаётся
	// только то, что требует внимания.
	_, err = s.tryAutoAdd(ctx, id, networkID, storeID, employeeID, code, res, keys)
	return err
}

// tryAutoAdd — добавить готовую карточку в «Мои товары», если она не требует
// внимания. Тот же товар в базе ищется заново прямо сейчас: пока карточка
// ждала, он мог появиться (например, его добавили из более ранней карточки);
// изменился — Match сохраняется в карточку для магазина.
//   - Тот же штрихкод в базе — карточка добавляет этот товар.
//   - Иначе новый товар создаётся, только если нет кандидата в базе и в
//     очереди, Super Market уверен, категория из дерева и штрихкод верный.
func (s *Service) tryAutoAdd(ctx context.Context, id, networkID, storeID, employeeID, code string, res NewItemResult, keys []string) (bool, error) {
	if err := s.refreshMatch(ctx, id, networkID, code, &res); err != nil {
		return false, err
	}
	p := &identity.Principal{NetworkID: networkID, EmployeeID: employeeID, IsOwner: true}
	if res.Match != nil {
		if !res.Match.SameBarcode {
			return false, nil
		}
		if _, err := s.ConfirmNewItem(ctx, p, id, NewItemConfirm{StoreID: storeID, ProductID: res.Match.ProductID}); err != nil {
			s.log.Info("новый товар: не добавили сами", "id", id, "err", err)
			return false, nil
		}
		return true, nil
	}
	ok, err := s.canAutoAdd(ctx, id, code, res)
	if err != nil || !ok {
		return false, err
	}
	return s.autoAddNewItem(ctx, p, id, storeID, res, keys), nil
}

// refreshMatch — заново найти тот же товар в базе для карточки; изменился —
// сохранить в карточку (магазин увидит «Это он»).
func (s *Service) refreshMatch(ctx context.Context, id, networkID, code string, res *NewItemResult) error {
	match, err := sameProduct(ctx, s.pool, networkID, code, res)
	if err != nil {
		return err
	}
	if sameMatch(match, res.Match) {
		return nil
	}
	res.Match = match
	raw, _ := json.Marshal(res)
	_, err = s.pool.Exec(ctx, `UPDATE start_new_items SET result = $2 WHERE id = $1 AND status = 'ready'`, id, raw)
	return err
}

func sameMatch(a, b *NewItemMatch) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.ProductID == b.ProductID && a.SameBarcode == b.SameBarcode
}

// SweepNewItems — разово пройти карточки «ready», распознанные до
// автодобавления (или когда оно не сработало), и добавить те, что не требуют
// внимания. По порядку создания: из пары одинаковых добавится ранняя, а поздняя
// найдёт её как тот же товар и останется магазину.
func (s *Service) SweepNewItems() {
	s.run(func() {
		ctx := context.Background()
		type card struct {
			id, networkID, storeID, employeeID, code string
			keys                                     []string
			raw                                      []byte
		}
		rows, err := s.pool.Query(ctx, `SELECT id, network_id, store_id, created_by, barcode, images, result FROM start_new_items
			WHERE status = 'ready' ORDER BY created_at, id`)
		if err != nil {
			s.log.Error("новые товары: обход", "err", err)
			return
		}
		var cards []card
		for rows.Next() {
			var c card
			if err := rows.Scan(&c.id, &c.networkID, &c.storeID, &c.employeeID, &c.code, &c.keys, &c.raw); err != nil {
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
			ok, err := s.tryAutoAdd(ctx, c.id, c.networkID, c.storeID, c.employeeID, c.code, res, c.keys)
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

// canAutoAdd — новый товар можно создать без магазина: Super Market уверен,
// категория нашлась в дереве, штрихкод верный (или его нет) и в очереди нет
// более ранней карточки того же товара.
func (s *Service) canAutoAdd(ctx context.Context, id, code string, res NewItemResult) (bool, error) {
	if (res.Note != "" && !sizeOnlyNote(res.Note)) || res.Match != nil || strings.TrimSpace(res.Name) == "" || res.UnitID == "" {
		return false, nil
	}
	if res.Suggestion == nil || res.Suggestion.Category == nil {
		return false, nil
	}
	if code != "" && !BarcodeValid(code) {
		return false, nil
	}
	dups, err := s.queueDups(ctx, s.pool, []string{id})
	if err != nil {
		return false, err
	}
	return len(dups) == 0, nil
}

// autoAddNewItem — создать товар и поставить его в «Мои товары» от имени
// магазина. Системный Principal ограничен сетью и магазином самой карточки;
// товар создаётся как свой товар сети в статусе draft и всё равно уходит на
// модерацию при «Записать и закрыть». Не получилось — карточка остаётся
// магазину в «Требуют внимания», это не ошибка распознавания.
func (s *Service) autoAddNewItem(ctx context.Context, p *identity.Principal, id, storeID string, res NewItemResult, keys []string) bool {
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

// productByBarcode — товар базы (общий каталог и свои товары сети) с этим
// штрихкодом с точностью до ведущих нулей. Внутренний код магазина (2…)
// ищется только среди своих товаров сети: у другой сети это другой товар.
func productByBarcode(ctx context.Context, q db.Querier, networkID, code string) (*NewItemMatch, error) {
	if strings.TrimSpace(code) == "" {
		return nil, nil
	}
	m := NewItemMatch{SameBarcode: true}
	err := q.QueryRow(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), p.images[1], pb.barcode, p.network_id IS NOT NULL
		FROM product_barcodes pb JOIN products p ON p.id = pb.product_id
		WHERE barcode_key(pb.barcode) = barcode_key($2) AND p.is_active
		  AND (p.network_id = $1 OR (p.network_id IS NULL AND NOT $3))
		ORDER BY pb.barcode = $2 DESC, p.network_id IS NULL DESC, p.id
		LIMIT 1`, networkID, strings.TrimSpace(code), InternalBarcode(code)).Scan(&m.ProductID, &m.Name, &m.Image, &m.Barcode, &m.Own)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// sameProductSQL — кандидаты в тот же товар по названию: похожие товары базы
// с брендом и похожестью «ядер» названий; решает sameProduct — по полям.
var sameProductSQL = `
	SELECT p.id, loc(p.name, p.name_uz), p.name, p.images[1],
	       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), p.network_id IS NOT NULL,
	       p.brand_id, COALESCE(b.name, ''), similarity(` + coreSQL("p.name") + `, ` + coreSQL("$2") + `)
	FROM products p LEFT JOIN brands b ON b.id = p.brand_id
	WHERE p.is_active AND (p.network_id IS NULL OR p.network_id = $1)
	  AND (lower(p.name) % lower($2) OR ($3 <> '' AND lower(p.name_uz) % lower($3)))
	  AND greatest(similarity(lower(p.name), lower($2)), CASE WHEN $3 <> '' THEN similarity(lower(p.name_uz), lower($3)) ELSE 0 END) >= $4
	ORDER BY greatest(similarity(lower(p.name), lower($2)), CASE WHEN $3 <> '' THEN similarity(lower(p.name_uz), lower($3)) ELSE 0 END) DESC, p.id
	LIMIT 10`

// sameProduct — тот же товар в базе: по штрихкоду, а если его нет — по полям
// (бренд, объём, фасовка, название без чисел; см. Spec). nil — такого нет,
// можно создавать новый.
func sameProduct(ctx context.Context, q db.Querier, networkID, code string, res *NewItemResult) (*NewItemMatch, error) {
	if m, err := productByBarcode(ctx, q, networkID, code); m != nil || err != nil {
		return m, err
	}
	if strings.TrimSpace(res.Name) == "" {
		return nil, nil
	}
	rows, err := q.Query(ctx, sameProductSQL, networkID, res.Name, res.NameUz, CandidateMin)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	spec := res.spec()
	for rows.Next() {
		var m NewItemMatch
		var name, brandName string
		var brandID *string
		var core float64
		if err := rows.Scan(&m.ProductID, &m.Name, &name, &m.Image, &m.Barcode, &m.Own, &brandID, &brandName, &core); err != nil {
			return nil, err
		}
		if core < CoreMin || brandConflicts(res.BrandID, res.Brand, brandID, brandName) || spec.Conflicts(ParseSpec(name)) {
			continue
		}
		return &m, nil
	}
	return nil, rows.Err()
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
	// KeepOwnPhoto — «Оставить моё фото»: чистое фото Super Market не ставить
	// первым (Images — как прислал магазин).
	KeepOwnPhoto bool `json:"keep_own_photo"`
}

type NewItemConfirmResult struct {
	ProductID string `json:"product_id"`
	Created   bool   `json:"created"`
	Line      Line   `json:"line"`
	Totals    Totals `json:"totals"`
	// Direct — «Начало работы» закрыто: товар сразу в магазине (line пуста).
	Direct bool `json:"direct"`
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
		draft, direct, err := s.target(ctx, tx, p, st)
		if err != nil {
			return err
		}
		out.Direct = direct
		add := func(in LineInput, ask bool) error {
			if direct {
				_, err := s.directLine(ctx, tx, p, st, in, ask)
				return err
			}
			_, err := s.setLine(ctx, tx, p, st, draft, in, ask)
			return err
		}
		pid := in.ProductID
		src := "new"
		if pid != "" {
			// «Это он» — товар базы; штрихкод — к нему.
			src = "photo"
			if err := add(LineInput{ProductID: pid, Add: true, Source: &src, ConfirmSimilar: true}, true); err != nil {
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
			if err := add(LineInput{ProductID: pid, Add: true, Source: &src}, false); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE start_new_items SET status = 'done', product_id = $2 WHERE id = $1`, id, pid); err != nil {
			return err
		}
		if err := s.confirmPhoto(ctx, tx, id, pid, out.Created, in.KeepOwnPhoto); err != nil {
			return err
		}
		out.ProductID = pid
		if direct {
			return nil
		}
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

// minorDoubts — модель сомневалась только в том, чего нет на упаковке: весе,
// объёме или числе штук. Такая карточка не требует внимания магазина —
// размер дописывают потом, если надо.
func minorDoubts(unclear []string) bool {
	if len(unclear) == 0 {
		return false
	}
	for _, u := range unclear {
		switch strings.ToLower(strings.TrimSpace(u)) {
		case "size", "pack":
		default:
			return false
		}
	}
	return true
}

// sizeOnlyNote — карточки, распознанные до поля unclear: каждое предложение
// заметки безобидно — не виден вес, объём или нетто (граммы, метры),
// рукописная цена, деталь не попала в название, потому что её нет на
// упаковке, «проверьте по штрихкоду / по упаковке».
// Хоть одно другое предложение (название, бренд, категория, фото) — сомнение
// настоящее, карточка остаётся магазину.
func sizeOnlyNote(note string) bool {
	n := strings.ToLower(strings.ReplaceAll(note, "ё", "е"))
	parts := noteSplit.Split(n, -1)
	seen := 0
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		seen++
		if !harmlessSentence(p) {
			return false
		}
	}
	return seen > 0
}

var noteSplit = regexp.MustCompile(`[.!?\n]+`)

// realDoubt — слова настоящего сомнения: если они есть, предложение не безобидно.
var realDoubt = []string{"бренд", "марк", "категор", "вкус", "размыт", "нечетк", "не разобрать", "не уверен", "читается плохо", "плохо читается", "производител", "другой товар", "похож"}

func harmlessSentence(p string) bool {
	has := func(ws ...string) bool {
		for _, w := range ws {
			if strings.Contains(p, w) {
				return true
			}
		}
		return false
	}
	if has(realDoubt...) {
		return false
	}
	switch {
	case strings.HasPrefix(p, "проверьте по "), strings.HasPrefix(p, "проверьте на упаковке"), strings.HasPrefix(p, "сверьте с упаковкой"):
		return true
	case has("рукописн"):
		return true
	case has("вес", "объем", "size", "нетто", "грамм", "метр", "длин") && has("не вид", "не указ", "не чита", "нет ", "пуст", "не напечат"):
		return !has("назван")
	case has("не указ", "не вид", "не написан", "не напечат") && has("в названии этого нет", "в названии нет", "не добавил", "не стал добавл", "не включ", "не указан в названии"):
		return true
	}
	return false
}
