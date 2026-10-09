package start

import (
	"context"
	"encoding/json"
	"errors"
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
// Магазин проверяет карточку и подтверждает — только тогда создаётся свой
// товар сети (статус draft) и встаёт в «Мои товары». На модерацию в общую
// базу он уходит при «Записать и закрыть».
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
}

type NewItemCounts struct {
	Processing int `json:"processing"`
	Ready      int `json:"ready"`
	Failed     int `json:"failed"`
}

type NewItemList struct {
	Items  []NewItem     `json:"items"`
	Counts NewItemCounts `json:"counts"`
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
	var id string
	if err := s.pool.QueryRow(ctx, `
		INSERT INTO start_new_items (network_id, store_id, created_by, barcode, images, status, error)
		VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
		p.NetworkID, st.ID, p.EmployeeID, code, keys, status, msg).Scan(&id); err != nil {
		return NewItem{}, err
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
func (s *Service) ListNewItems(ctx context.Context, p *identity.Principal, storeID string) (NewItemList, error) {
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return NewItemList{}, err
	}
	rows, err := s.pool.Query(ctx, `SELECT * FROM (`+newItemSelect+` WHERE store_id = $1 AND network_id = $2 AND status <> 'done') x
		ORDER BY x.status = 'ready' DESC, x.status = 'failed' DESC, x.created_at DESC LIMIT 200`, newItemArgs(ctx, st.ID, p.NetworkID)...)
	if err != nil {
		return NewItemList{}, err
	}
	out := NewItemList{}
	if out.Items, err = pgx.CollectRows(rows, scanNewItem); err != nil {
		return out, err
	}
	for _, it := range out.Items {
		switch it.Status {
		case NewProcessing:
			out.Counts.Processing++
		case NewReady:
			out.Counts.Ready++
		case NewFailed:
			out.Counts.Failed++
		}
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
	return it, nil
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
	raw, _ := json.Marshal(res)
	_, err = s.pool.Exec(ctx, `UPDATE start_new_items SET status = 'ready', error = '', result = $2 WHERE id = $1 AND status = 'processing'`, id, raw)
	return err
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
