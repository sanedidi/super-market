// Package start — «Начало работы»: магазин заводит товары, которые у него
// уже есть. Сначала магазин выбирает, как начать («Как начнём?», mode):
//   - stock — «Сразу с остатками»: количество и цена продажи по каждому товару;
//     можно остановиться — «Остальное посчитаю потом» (rest_later);
//   - prices — «Только товары и цены»: только цена продажи, у товаров
//     «Остаток не посчитан» (store_products.uncounted_since), посчитать потом
//     (count.go).
//
// Черновик общий для панели и «SM Магазин» и идёт в два шага:
//  1. «Мои товары» — магазин находит свои товары в центральной базе (поиск по
//     названию и штрихкоду, сканер, фото полок) или создаёт свой. Тот же товар
//     второй раз не добавляется; на похожий — предупреждение.
//  2. «Инвентаризация: Начало работы» — количество и цена продажи по каждому
//     товару (обязательны, можно 0) и, по желанию, себестоимость. В режиме
//     prices — «Цены»: обязательна только цена продажи.
//
// «Записать и закрыть» проводит черновик: оприходование на склад, установка
// цен магазина, товары — в ассортименте магазина. После этого «Начало работы»
// закрыто: дальше товары заводятся обычными документами.
package start

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// Режимы «Начала работы» («Как начнём?»).
const (
	ModeStock  = "stock"
	ModePrices = "prices"
)

const (
	StatusOpen    = "open"
	StatusPosting = "posting"
	StatusPosted  = "posted"

	// Строк в одном оприходовании (предел складского документа).
	docChunk = 1000
)

type Service struct {
	pool  *pgxpool.Pool
	ai    *ai.Service
	media *media.Service
	inv   *inventory.Service
	cat   *catalog.Service
	log   *slog.Logger
	// run — распознавание фото (в тестах — синхронно).
	run func(func())
	// OnOwnAdded — в сеть добавились свои товары («Провести все»): Super
	// Market ищет среди них группы вариаций.
	OnOwnAdded func(networkID string)
	// Photos — нормализация фото для магазина (photos_store.go); nil — выключена.
	Photos *ai.PhotoService
}

func NewService(pool *pgxpool.Pool, aiSvc *ai.Service, mediaSvc *media.Service, inv *inventory.Service, cat *catalog.Service, log *slog.Logger) *Service {
	return &Service{pool: pool, ai: aiSvc, media: mediaSvc, inv: inv, cat: cat, log: log, run: func(f func()) { go f() }}
}

// Sync — распознавать фото сразу в запросе (для тестов).
func (s *Service) Sync() { s.run = func(f func()) { f() } }

func require(p *identity.Principal, storeID string) error {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return nil
}

// store — основной склад и тип цены приложения магазина.
type store struct {
	ID            string
	Name          string
	WarehouseID   string
	WarehouseName string
	PriceTypeID   string
}

func (s *Service) store(ctx context.Context, q db.Querier, p *identity.Principal, storeID string) (store, error) {
	if err := require(p, storeID); err != nil {
		return store{}, err
	}
	var st store
	var wh, whName *string
	err := q.QueryRow(ctx, `
		SELECT s.id, s.name, s.default_warehouse_id, w.name, COALESCE(s.online_price_type_id, pt.id)
		FROM stores s
		JOIN price_types pt ON pt.network_id = s.network_id AND pt.is_default
		LEFT JOIN warehouses w ON w.id = s.default_warehouse_id AND w.is_active
		WHERE s.id = $1 AND s.network_id = $2`, storeID, p.NetworkID).Scan(&st.ID, &st.Name, &wh, &whName, &st.PriceTypeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if err != nil {
		return st, err
	}
	if wh == nil || whName == nil {
		return st, apperr.Conflict("no_warehouse", "у магазина нет основного склада — выберите его в настройках магазина").Uz("doʻkonda asosiy ombor yoʻq — uni doʻkon sozlamalarida tanlang")
	}
	st.WarehouseID, st.WarehouseName = *wh, *whName
	return st, nil
}

// --------------------------------------------------------------- черновик

type Line struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	UnitShort    string  `json:"unit_short"`
	IsFractional bool    `json:"is_fractional"`
	Barcode      *string `json:"barcode"`
	// Qty и Price — null, пока не введены на шаге «Инвентаризация».
	Qty          *string   `json:"qty"`
	Cost         *string   `json:"cost"`
	Price        *string   `json:"price"`
	CurrentPrice string    `json:"current_price"`
	Source       string    `json:"source"`
	Own          bool      `json:"own"`
	Moderation   string    `json:"moderation"`
	Posted       bool      `json:"posted"`
	AddedAt      time.Time `json:"added_at"`
	// Variant — товар в подтверждённой группе вариаций: инвентаризация
	// показывает группу своей таблицей, цена ставится на вес (или на группу).
	Variant *LineVariant `json:"variant"`
	// Photo — фото от Super Market: processing — делается, done — первым
	// стоит его фото, "" — нет.
	Photo string `json:"photo"`
}

// LineVariant — место товара в группе вариаций.
type LineVariant struct {
	GroupID     string `json:"group_id"`
	GroupName   string `json:"group_name"`
	WeightLabel string `json:"weight_label"`
	FlavorLabel string `json:"flavor_label"`
	Weight      string `json:"weight"`
	Flavor      string `json:"flavor"`
	// OwnPrice — «своя цена»: цена веса этот товар не меняет.
	OwnPrice bool `json:"own_price"`
}

type Totals struct {
	Products   int    `json:"products"`
	Qty        string `json:"qty"`
	CostTotal  string `json:"cost_total"`
	PriceTotal string `json:"price_total"`
	NoCost     int    `json:"no_cost"`
	Pending    int    `json:"pending"`
	// Unfilled — незаполненных строк: без количества или цены продажи (в
	// режиме prices и при «Остальное посчитаю потом» — только без цены).
	// Пока они есть, «Записать и закрыть» не проходит.
	Unfilled int `json:"unfilled"`
	// NoQty и NoPrice — строк без количества и без цены продажи.
	NoQty   int `json:"no_qty"`
	NoPrice int `json:"no_price"`
	// NoPhoto — строк без фото товара: пока они есть, «Записать и закрыть»
	// не проходит — без фото покупатель не увидит товар в каталоге.
	NoPhoto int `json:"no_photo"`
}

type Draft struct {
	ID            *string `json:"id"`
	StoreID       string  `json:"store_id"`
	StoreName     string  `json:"store_name"`
	WarehouseID   string  `json:"warehouse_id"`
	WarehouseName string  `json:"warehouse_name"`
	Status        string  `json:"status"`
	// Mode — как магазин начинает: stock — «Сразу с остатками», prices —
	// «Только товары и цены», null — ещё не выбрал (показать «Как начнём?»).
	// Черновики, начатые до выбора режима, — stock.
	Mode *string `json:"mode"`
	// Step — на каком шаге магазин: 1 — выбор товаров, 2 — инвентаризация.
	// Общий для панели и «SM Магазин»: от него зависит, что делает сканер.
	Step          int        `json:"step"`
	Lines         []Line     `json:"lines"`
	Totals        Totals     `json:"totals"`
	StockProducts int        `json:"stock_products"`
	LastPostedAt  *time.Time `json:"last_posted_at"`
	// Closed — «Начало работы» уже записано и закрыто: больше не показывается.
	Closed bool `json:"closed"`
}

type Filter struct {
	Query  string
	Only   string // unfilled | no_cost | new
	Limit  int
	Offset int
	// Order — "groups": сначала группы вариаций (группа → вес → вариант),
	// потом обычные товары — инвентаризация показывает группу своей таблицей.
	Order string
}

// openDraft — открытый черновик склада (nil — ещё не начат).
func openDraft(ctx context.Context, q db.Querier, warehouseID string) (*string, string, error) {
	var id, status string
	err := q.QueryRow(ctx, `SELECT id, status FROM start_drafts WHERE warehouse_id = $1 AND status <> 'posted'`, warehouseID).Scan(&id, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, "", nil
	}
	if err != nil {
		return nil, "", err
	}
	return &id, status, nil
}

const lineSelect = `
	SELECT l.product_id, loc(p.name, p.name_uz), p.images[1], loc(u.short_name, u.short_name_uz), u.is_fractional,
	       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id),
	       trim_scale(l.qty)::text, trim_scale(l.cost)::text, l.price::text,
	       COALESCE(sp.price, np.price, p.base_price)::text,
	       l.source, p.network_id IS NOT NULL, p.moderation_status, l.document_id IS NOT NULL, l.added_at,
	       vg.id, loc(vg.name, vg.name_uz), loc(vg.weight_label, vg.weight_label_uz), loc(vg.flavor_label, vg.flavor_label_uz),
	       loc(p.variant_weight, p.variant_weight_uz), loc(p.variant_flavor, p.variant_flavor_uz),
	       EXISTS (SELECT 1 FROM variant_own_prices o WHERE o.store_id = $3 AND o.product_id = p.id),
	       COALESCE(` + linePhotoSQL + `, '')
	FROM start_lines l
	JOIN products p ON p.id = l.product_id
	JOIN units u ON u.id = p.unit_id
	LEFT JOIN variant_groups vg ON vg.id = p.variant_group_id AND vg.status = 'confirmed'
	LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $2 AND sp.store_id = $3
	LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $2 AND np.store_id IS NULL`

func scanLine(row pgx.CollectableRow) (Line, error) {
	var l Line
	var gid, gname, wl, fl, w, f *string
	var own bool
	err := row.Scan(&l.ProductID, &l.Name, &l.Image, &l.UnitShort, &l.IsFractional, &l.Barcode, &l.Qty, &l.Cost, &l.Price,
		&l.CurrentPrice, &l.Source, &l.Own, &l.Moderation, &l.Posted, &l.AddedAt, &gid, &gname, &wl, &fl, &w, &f, &own, &l.Photo)
	if err == nil && gid != nil {
		l.Variant = &LineVariant{GroupID: *gid, GroupName: deref(gname), WeightLabel: deref(wl), FlavorLabel: deref(fl),
			Weight: deref(w), Flavor: deref(f), OwnPrice: own}
	}
	return l, err
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func (s *Service) totals(ctx context.Context, q db.Querier, draftID string, st store) (Totals, error) {
	var t Totals
	err := q.QueryRow(ctx, `
		SELECT count(*)::int, trim_scale(COALESCE(sum(l.qty), 0))::text,
		       round(COALESCE(sum(l.qty * l.cost), 0), 2)::text,
		       round(COALESCE(sum(l.qty * COALESCE(l.price, sp.price, np.price, p.base_price)), 0), 2)::text,
		       (count(*) FILTER (WHERE l.cost IS NULL))::int,
		       (count(*) FILTER (WHERE p.network_id IS NOT NULL AND p.moderation_status <> 'approved'))::int,
		       (count(*) FILTER (WHERE l.price IS NULL OR (l.qty IS NULL AND d.mode IS DISTINCT FROM 'prices')))::int,
		       (count(*) FILTER (WHERE COALESCE(cardinality(p.images), 0) = 0))::int,
		       (count(*) FILTER (WHERE l.qty IS NULL))::int,
		       (count(*) FILTER (WHERE l.price IS NULL))::int
		FROM start_lines l
		JOIN start_drafts d ON d.id = l.draft_id
		JOIN products p ON p.id = l.product_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $2 AND sp.store_id = $3
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $2 AND np.store_id IS NULL
		WHERE l.draft_id = $1`, draftID, st.PriceTypeID, st.ID).
		Scan(&t.Products, &t.Qty, &t.CostTotal, &t.PriceTotal, &t.NoCost, &t.Pending, &t.Unfilled, &t.NoPhoto, &t.NoQty, &t.NoPrice)
	return t, err
}

// Get — открытый черновик магазина со строками (новые сверху) и итогами.
func (s *Service) Get(ctx context.Context, p *identity.Principal, storeID string, f Filter) (Draft, error) {
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return Draft{}, err
	}
	d := Draft{StoreID: st.ID, StoreName: st.Name, WarehouseID: st.WarehouseID, WarehouseName: st.WarehouseName,
		Status: StatusOpen, Step: 1, Lines: []Line{}, Totals: Totals{Qty: "0", CostTotal: "0.00", PriceTotal: "0.00"}}
	if err := s.pool.QueryRow(ctx, `
		SELECT (SELECT count(DISTINCT b.product_id)::int FROM batches b WHERE b.warehouse_id = $1 AND b.qty_remaining > 0),
		       (SELECT max(posted_at) FROM start_drafts WHERE warehouse_id = $1 AND status = 'posted')`, st.WarehouseID).
		Scan(&d.StockProducts, &d.LastPostedAt); err != nil {
		return d, err
	}
	d.Closed = d.LastPostedAt != nil
	id, status, err := openDraft(ctx, s.pool, st.WarehouseID)
	if err != nil || id == nil {
		return d, err
	}
	d.ID, d.Status = id, status
	if err := s.pool.QueryRow(ctx, `SELECT step, mode FROM start_drafts WHERE id = $1`, *id).Scan(&d.Step, &d.Mode); err != nil {
		return d, err
	}
	if d.Totals, err = s.totals(ctx, s.pool, *id, st); err != nil {
		return d, err
	}
	where := ` WHERE l.draft_id = $1`
	args := []any{*id, st.PriceTypeID, st.ID}
	if strings.TrimSpace(f.Query) != "" {
		where += ` AND ` + productsearch.Filter("p", f.Query, &args)
	}
	switch f.Only {
	case "":
	case "unfilled":
		if d.Mode != nil && *d.Mode == ModePrices {
			where += ` AND l.price IS NULL`
		} else {
			where += ` AND (l.qty IS NULL OR l.price IS NULL)`
		}
	case "no_qty":
		where += ` AND l.qty IS NULL`
	case "no_cost":
		where += ` AND l.cost IS NULL`
	case "new":
		where += ` AND p.network_id IS NOT NULL`
	case "no_photo":
		where += ` AND COALESCE(cardinality(p.images), 0) = 0`
	default:
		return d, apperr.Validation("only: ожидается unfilled, no_qty, no_cost, no_photo или new").Uz("only: unfilled, no_qty, no_cost, no_photo yoki new boʻlishi kerak")
	}
	limit := f.Limit
	if limit <= 0 {
		limit = 200
	}
	order := `l.added_at DESC, loc(p.name, p.name_uz)`
	switch f.Order {
	case "":
	case "groups":
		order = `vg.id IS NULL, loc(vg.name, vg.name_uz), vg.id, p.variant_weight_sort, p.variant_weight, p.variant_sort,
			loc(p.name, p.name_uz), l.product_id`
	default:
		return d, apperr.Validation("order: ожидается groups").Uz("order: groups boʻlishi kerak")
	}
	rows, err := s.pool.Query(ctx, lineSelect+where+fmt.Sprintf(` ORDER BY %s LIMIT %d OFFSET %d`, order, min(limit, 1000), max(f.Offset, 0)), productsearch.Args(args)...)
	if err != nil {
		return d, err
	}
	d.Lines, err = pgx.CollectRows(rows, scanLine)
	return d, err
}

// ---------------------------------------------------------------- строки

var barcodeRe = regexp.MustCompile(`^[0-9A-Za-z-]{4,32}$`)

var sources = map[string]bool{"photo": true, "barcode": true, "catalog": true, "search": true, "new": true, "manual": true, "tasnif": true}

type LineInput struct {
	ProductID string `json:"product_id"`
	// Add — добавить товар в «Мои товары» (шаг 1). Если он уже там — ошибка
	// already_added; в пакете из нескольких товаров такие пропускаются.
	// Без Add строка правится (шаг 2) или создаётся.
	Add bool `json:"add"`
	// ConfirmSimilar — магазин ответил «всё равно добавить» на похожий товар.
	ConfirmSimilar bool                         `json:"confirm_similar"`
	Qty            httpx.Optional[money.Qty]    `json:"qty"`
	Cost           httpx.Optional[money.Price]  `json:"cost"`
	Price          httpx.Optional[money.Amount] `json:"price"`
	Barcode        *string                      `json:"barcode"`
	Source         *string                      `json:"source"`
}

type LinesInput struct {
	StoreID string      `json:"store_id"`
	Items   []LineInput `json:"items"`
}

type LinesResult struct {
	Lines  []Line `json:"lines"`
	Totals Totals `json:"totals"`
	// Skipped — товары пакета, которые уже были в «Моих товарах».
	Skipped []string `json:"skipped"`
}

// SetLines — добавить или изменить строки черновика (черновик создаётся сам).
func (s *Service) SetLines(ctx context.Context, p *identity.Principal, in LinesInput) (LinesResult, error) {
	if len(in.Items) == 0 || len(in.Items) > 500 {
		return LinesResult{}, apperr.Validation("items: от 1 до 500 товаров").Uz("items: 1 dan 500 tagacha mahsulot")
	}
	out := LinesResult{Lines: []Line{}, Skipped: []string{}}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, in.StoreID)
		if err != nil {
			return err
		}
		id, err := s.ensureDraft(ctx, tx, p, st)
		if err != nil {
			return err
		}
		single := len(in.Items) == 1
		ids := make([]string, 0, len(in.Items))
		for i, it := range in.Items {
			// Спрашиваем (повтор — ошибка, похожий — вопрос) только когда товар
			// добавляют по одному поиском или сканером. Фото полок и только что
			// созданный свой товар добавляются без вопросов, повтор — пропуск.
			ask := single && (it.Source == nil || (*it.Source != "photo" && *it.Source != "new"))
			skipped, err := s.setLine(ctx, tx, p, st, id, it, ask)
			if err != nil {
				if ae, ok := apperr.As(err); ok && !single && ae.Status == 400 {
					return apperr.Validation(fmt.Sprintf("товар %d: %s", i+1, ae.Message)).Uz(fmt.Sprintf("%d-mahsulot: %s", i+1, ae.Text(i18n.UZ)))
				}
				return err
			}
			if skipped {
				out.Skipped = append(out.Skipped, it.ProductID)
				continue
			}
			ids = append(ids, it.ProductID)
		}
		rows, err := tx.Query(ctx, lineSelect+` WHERE l.draft_id = $1 AND l.product_id = ANY($4::uuid[]) ORDER BY l.added_at DESC`,
			id, st.PriceTypeID, st.ID, ids)
		if err != nil {
			return err
		}
		if out.Lines, err = pgx.CollectRows(rows, scanLine); err != nil {
			return err
		}
		out.Totals, err = s.totals(ctx, tx, id, st)
		return err
	})
	return out, err
}

func errClosed() error {
	return apperr.Conflict("start_closed", "«Начало работы» уже записано и закрыто — новые товары добавляйте приходом или инвентаризацией").
		Uz("«Ishni boshlash» allaqachon yozilgan va yopilgan — yangi mahsulotlarni kirim yoki inventarizatsiya orqali qoʻshing")
}

func (s *Service) ensureDraft(ctx context.Context, tx pgx.Tx, p *identity.Principal, st store) (string, error) {
	// Сериализуем создание черновика склада.
	if _, err := tx.Exec(ctx, `SELECT 1 FROM warehouses WHERE id = $1 FOR UPDATE`, st.WarehouseID); err != nil {
		return "", err
	}
	id, status, err := openDraft(ctx, tx, st.WarehouseID)
	if err != nil {
		return "", err
	}
	if id != nil {
		if status == StatusPosting {
			return "", apperr.Conflict("draft_posting", "черновик сейчас проводится — подождите несколько секунд").Uz("qoralama hozir oʻtkazilmoqda — bir necha soniya kuting")
		}
		return *id, nil
	}
	var closed bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM start_drafts WHERE warehouse_id = $1 AND status = 'posted')`, st.WarehouseID).Scan(&closed); err != nil {
		return "", err
	}
	if closed {
		return "", errClosed()
	}
	var nid string
	err = tx.QueryRow(ctx, `
		INSERT INTO start_drafts (network_id, store_id, warehouse_id, created_by) VALUES ($1, $2, $3, $4) RETURNING id`,
		p.NetworkID, st.ID, st.WarehouseID, p.EmployeeID).Scan(&nid)
	return nid, err
}

// SimilarMin — с какой похожести названий (pg_trgm, 0…1) товар считается
// похожим. Кроме того, у похожих совпадают числа в названии (объём, вес) и
// бренд (или он не указан): «Sprite 1 л» и «Sprite 1,5 л» — разные товары.
const SimilarMin = 0.7

// similarSQL — товары черновика $1, похожие на товар $2, о которых магазин $3
// ещё не отвечал «всё равно добавить»; самые похожие первыми.
const similarSQL = `
	WITH n AS (SELECT id, brand_id, lower(name) AS name, lower(name_uz) AS name_uz,
	                  (SELECT array_agg(m[1] ORDER BY m[1]) FROM regexp_matches(replace(name, ',', '.'), '(\d+(?:\.\d+)?)', 'g') m) AS nums
	           FROM products WHERE id = $2),
	     o AS (SELECT p.id, p.brand_id, loc(p.name, p.name_uz) AS title, p.images[1] AS image,
	                  (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id) AS barcode,
	                  greatest(similarity(lower(p.name), n.name),
	                           CASE WHEN p.name_uz <> '' AND n.name_uz <> '' THEN similarity(lower(p.name_uz), n.name_uz) ELSE 0 END) AS score,
	                  (SELECT array_agg(m[1] ORDER BY m[1]) FROM regexp_matches(replace(p.name, ',', '.'), '(\d+(?:\.\d+)?)', 'g') m) AS nums
	           FROM start_lines l JOIN products p ON p.id = l.product_id, n
	           WHERE l.draft_id = $1 AND p.id <> n.id
	             AND (p.brand_id IS NULL OR n.brand_id IS NULL OR p.brand_id = n.brand_id))
	SELECT o.id, o.title, o.image, o.barcode
	FROM o, n
	WHERE o.score >= $4 AND o.nums IS NOT DISTINCT FROM n.nums
	  AND NOT EXISTS (SELECT 1 FROM start_similar_ok k
	                  WHERE k.store_id = $3 AND k.product_id = least(o.id, n.id) AND k.similar_id = greatest(o.id, n.id))
	ORDER BY o.score DESC, o.id`

// Similar — похожий товар, который уже в «Моих товарах».
type Similar struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Image     *string `json:"image"`
	Barcode   *string `json:"barcode"`
}

func (s *Service) similar(ctx context.Context, tx pgx.Tx, st store, draftID, productID string) ([]Similar, error) {
	rows, err := tx.Query(ctx, similarSQL, draftID, productID, st.ID, SimilarMin)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Similar, error) {
		var x Similar
		err := r.Scan(&x.ProductID, &x.Name, &x.Image, &x.Barcode)
		return x, err
	})
}

// setLine — одна строка. ask — спросить про повтор и похожий товар (иначе
// повтор пропускается: skipped, похожий добавляется без вопроса).
func (s *Service) setLine(ctx context.Context, tx pgx.Tx, p *identity.Principal, st store, draftID string, in LineInput, ask bool) (bool, error) {
	if !httpx.IsUUID(in.ProductID) {
		return false, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	var fractional, active, inStore bool
	err := tx.QueryRow(ctx, `
		SELECT u.is_fractional, p.is_active, EXISTS (SELECT 1 FROM store_products a WHERE a.store_id = $3 AND a.product_id = p.id)
		FROM products p JOIN units u ON u.id = p.unit_id
		WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2)`, in.ProductID, p.NetworkID, st.ID).Scan(&fractional, &active, &inStore)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	if err != nil {
		return false, err
	}
	if !active {
		return false, apperr.Validation("product_id: товар отключён").Uz("product_id: mahsulot oʻchirilgan")
	}
	source := "manual"
	if in.Source != nil {
		if !sources[*in.Source] {
			return false, apperr.Validation("source: photo, barcode, catalog, search, new, tasnif или manual").Uz("source: photo, barcode, catalog, search, new, tasnif yoki manual")
		}
		source = *in.Source
	}
	var exists bool
	err = tx.QueryRow(ctx, `SELECT true FROM start_lines WHERE draft_id = $1 AND product_id = $2 FOR UPDATE`, draftID, in.ProductID).Scan(&exists)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}

	// Шаг 1: тот же товар второй раз не добавляется.
	if in.Add && (exists || inStore) {
		if !ask {
			return true, nil
		}
		return false, apperr.Conflict("already_added", "товар уже добавлен").Uz("mahsulot allaqachon qoʻshilgan").
			WithDetails(map[string]any{"product_id": in.ProductID, "in_store": inStore && !exists})
	}
	// Похожий товар — спросить один раз на пару.
	if in.Add && !exists && ask {
		sim, err := s.similar(ctx, tx, st, draftID, in.ProductID)
		if err != nil {
			return false, err
		}
		if len(sim) > 0 {
			if !in.ConfirmSimilar {
				return false, apperr.Conflict("similar_exists", "похожий товар уже есть в списке").Uz("oʻxshash mahsulot roʻyxatda allaqachon bor").
					WithDetails(map[string]any{"product_id": in.ProductID, "similar": sim[0]})
			}
			for _, x := range sim {
				if _, err := tx.Exec(ctx, `
					INSERT INTO start_similar_ok (store_id, product_id, similar_id) VALUES ($1, least($2::uuid, $3::uuid), greatest($2::uuid, $3::uuid))
					ON CONFLICT DO NOTHING`, st.ID, in.ProductID, x.ProductID); err != nil {
					return false, err
				}
			}
		}
	}

	if v := in.Qty.Or(); v != nil {
		if !v.Valid() {
			return false, apperr.Validation("qty: неверное количество").Uz("qty: miqdor notoʻgʻri")
		}
		q := money.D(string(*v))
		if q.Sign() < 0 {
			return false, apperr.Validation("qty: количество не может быть меньше нуля").Uz("qty: miqdor noldan kichik boʻlmasin")
		}
		if !fractional && q.Cmp(money.D(q.Fixed(0))) != 0 {
			return false, apperr.Validation("qty: товар штучный — количество целое").Uz("qty: mahsulot donali — miqdor butun son boʻlsin")
		}
		if q.Cmp(money.D("99999999")) > 0 {
			return false, apperr.Validation("qty: слишком большое количество").Uz("qty: miqdor juda katta")
		}
	}
	if v := in.Price.Or(); v != nil && (!v.Valid() || money.D(string(*v)).Sign() < 0) {
		return false, apperr.Validation("price: неверная цена продажи").Uz("price: sotish narxi notoʻgʻri")
	}
	if v := in.Cost.Or(); v != nil && !v.Valid() {
		return false, apperr.Validation("cost: неверная себестоимость").Uz("cost: tannarx notoʻgʻri")
	}
	if in.Barcode != nil && strings.TrimSpace(*in.Barcode) != "" {
		if err := bindBarcode(ctx, tx, p, in.ProductID, strings.TrimSpace(*in.Barcode)); err != nil {
			return false, err
		}
	}
	var qty, cost, price *string
	if v := in.Qty.Or(); v != nil {
		x := string(*v)
		qty = &x
	}
	if v := in.Cost.Or(); v != nil {
		x := string(*v)
		cost = &x
	}
	if v := in.Price.Or(); v != nil {
		x := string(*v)
		price = &x
	}
	if !exists {
		_, err = tx.Exec(ctx, `
			INSERT INTO start_lines (draft_id, product_id, qty, cost, price, source, added_by)
			VALUES ($1, $2, $3::numeric, $4::numeric, $5::numeric, $6, $7)`,
			draftID, in.ProductID, qty, cost, price, source, p.EmployeeID)
		return false, err
	}
	_, err = tx.Exec(ctx, `
		UPDATE start_lines SET qty = CASE WHEN $3 THEN $4::numeric ELSE qty END,
		       cost = CASE WHEN $5 THEN $6::numeric ELSE cost END,
		       price = CASE WHEN $7 THEN $8::numeric ELSE price END,
		       document_id = NULL
		WHERE draft_id = $1 AND product_id = $2`,
		draftID, in.ProductID, in.Qty.Set, qty, in.Cost.Set, cost, in.Price.Set, price)
	return false, err
}

// bindBarcode — привязать штрихкод к товару, если его ещё нет в каталоге.
// Штрихкод уникален на всю платформу: чужой штрихкод — 409.
func bindBarcode(ctx context.Context, tx pgx.Tx, p *identity.Principal, productID, code string) error {
	if !barcodeRe.MatchString(code) {
		return apperr.Validation("barcode: неверный штрихкод").Uz("barcode: shtrix-kod notoʻgʻri")
	}
	// Тот же код с точностью до ведущих нулей (UPC-A и EAN-13) — тоже занят.
	var owner string
	var exact bool
	err := tx.QueryRow(ctx, `SELECT product_id, barcode = $1 FROM product_barcodes WHERE barcode_key(barcode) = barcode_key($1)
		ORDER BY product_id = $2, barcode = $1 DESC LIMIT 1`, code, productID).Scan(&owner, &exact)
	if err == nil && owner == productID && !exact {
		// Тот же код в другом формате — запомнить и его, чтобы находился сканером.
		err = pgx.ErrNoRows
	}
	if err == nil {
		if owner == productID {
			return nil
		}
		return apperr.Conflict("barcode_exists", "штрихкод "+code+" уже есть у другого товара").Uz(code + " shtrix-kodi boshqa mahsulotda allaqachon bor").
			WithDetails(map[string]any{"product_id": owner})
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if err := p.Require(identity.PermCatalogManage); err != nil {
		return err
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM product_barcodes WHERE product_id = $1`, productID).Scan(&n); err != nil {
		return err
	}
	if n >= 10 {
		return apperr.Validation("barcode: у товара уже 10 штрихкодов").Uz("barcode: mahsulotda allaqachon 10 ta shtrix-kod bor")
	}
	_, err = tx.Exec(ctx, `INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, code, productID)
	if db.IsCheckViolation(err) {
		return apperr.Validation("barcode: неверный штрихкод").Uz("barcode: shtrix-kod notoʻgʻri")
	}
	return err
}

// DeleteLine — убрать товар из черновика.
func (s *Service) DeleteLine(ctx context.Context, p *identity.Principal, storeID, productID string) (Totals, error) {
	var t Totals
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, storeID)
		if err != nil {
			return err
		}
		id, status, err := openDraft(ctx, tx, st.WarehouseID)
		if err != nil {
			return err
		}
		if id == nil {
			return apperr.NotFound("товара нет в черновике").Uz("mahsulot qoralamada yoʻq")
		}
		if status == StatusPosting {
			return apperr.Conflict("draft_posting", "черновик сейчас проводится").Uz("qoralama hozir oʻtkazilmoqda")
		}
		tag, err := tx.Exec(ctx, `DELETE FROM start_lines WHERE draft_id = $1 AND product_id = $2`, *id, productID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("товара нет в черновике").Uz("mahsulot qoralamada yoʻq")
		}
		t, err = s.totals(ctx, tx, *id, st)
		return err
	})
	return t, err
}

// ------------------------------------------------------------- проведение

type DocRef struct {
	ID     string `json:"id"`
	Number int64  `json:"number"`
}

type PostResult struct {
	DraftID  string `json:"draft_id"`
	Products int    `json:"products"`
	// Uncounted — товаров с пометкой «Остаток не посчитан» (без количества).
	Uncounted     int      `json:"uncounted"`
	Qty           string   `json:"qty"`
	CostTotal     string   `json:"cost_total"`
	Documents     []DocRef `json:"documents"`
	PriceDocument *DocRef  `json:"price_document"`
	// Товары, которые уже видят покупатели (общий каталог, активные).
	Visible int `json:"visible"`
	// Свои новые товары — появятся в приложении после модерации.
	Pending int `json:"pending"`
}

type postLine struct {
	ProductID string
	Qty       *string
	Cost      *string
	Price     *string
	Current   string
	Posted    bool
	NoPhoto   bool
}

// PostInput — «Записать и закрыть». RestLater — «Остальное посчитаю потом»:
// строки без количества записываются с пометкой «Остаток не посчитан».
type PostInput struct {
	StoreID   string `json:"store_id"`
	RestLater bool   `json:"rest_later"`
}

// Post — «Записать и закрыть»: у каждой строки должны быть количество и цена
// продажи (можно 0). В режиме prices и с RestLater количество не обязательно:
// строки без него — «Остаток не посчитан»; фото обязательно только в режиме
// stock. Создаёт установку цен магазина (где цена отличается от
// действующей) и оприходование на основной склад по себестоимости (строки с
// количеством больше нуля), товары попадают в ассортимент магазина. Проведённые
// строки отмечаются — повторный вызов после сбоя доделывает оставшееся.
func (s *Service) Post(ctx context.Context, p *identity.Principal, in PostInput) (PostResult, error) {
	st, err := s.store(ctx, s.pool, p, in.StoreID)
	if err != nil {
		return PostResult{}, err
	}
	var draftID string
	err = s.pool.QueryRow(ctx, `
		UPDATE start_drafts SET status = 'posting' WHERE warehouse_id = $1 AND status = 'open' RETURNING id`, st.WarehouseID).Scan(&draftID)
	if errors.Is(err, pgx.ErrNoRows) {
		id, status, gerr := openDraft(ctx, s.pool, st.WarehouseID)
		if gerr == nil && id != nil && status == StatusPosting {
			return PostResult{}, apperr.Conflict("draft_posting", "черновик уже проводится").Uz("qoralama allaqachon oʻtkazilmoqda")
		}
		return PostResult{}, apperr.Conflict("draft_empty", "добавьте товары, которые есть в магазине").Uz("doʻkonda bor mahsulotlarni qoʻshing")
	}
	if err != nil {
		return PostResult{}, err
	}
	res, err := s.post(ctx, p, st, draftID, in.RestLater)
	if err != nil {
		if _, rerr := s.pool.Exec(context.WithoutCancel(ctx), `UPDATE start_drafts SET status = 'open' WHERE id = $1 AND status = 'posting'`, draftID); rerr != nil {
			s.log.Error("start: вернуть черновик", "id", draftID, "err", rerr)
		}
	}
	return res, err
}

func (s *Service) post(ctx context.Context, p *identity.Principal, st store, draftID string, restLater bool) (PostResult, error) {
	res := PostResult{DraftID: draftID, Documents: []DocRef{}}
	var mode *string
	if err := s.pool.QueryRow(ctx, `SELECT mode FROM start_drafts WHERE id = $1`, draftID).Scan(&mode); err != nil {
		return res, err
	}
	pricesMode := mode != nil && *mode == ModePrices
	// Количество обязательно только «Сразу с остатками» без «посчитаю потом».
	needQty := !pricesMode && !restLater
	rows, err := s.pool.Query(ctx, `
		SELECT l.product_id, trim_scale(l.qty)::text, l.cost::text, l.price::text,
		       COALESCE(sp.price, np.price, p.base_price)::text, l.document_id IS NOT NULL,
		       COALESCE(cardinality(p.images), 0) = 0
		FROM start_lines l
		JOIN products p ON p.id = l.product_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $2 AND sp.store_id = $3
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $2 AND np.store_id IS NULL
		WHERE l.draft_id = $1 ORDER BY l.added_at, l.product_id`, draftID, st.PriceTypeID, st.ID)
	if err != nil {
		return res, err
	}
	lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (postLine, error) {
		var l postLine
		err := r.Scan(&l.ProductID, &l.Qty, &l.Cost, &l.Price, &l.Current, &l.Posted, &l.NoPhoto)
		return l, err
	})
	if err != nil {
		return res, err
	}
	if len(lines) == 0 {
		return res, apperr.Conflict("draft_empty", "добавьте товары, которые есть в магазине").Uz("doʻkonda bor mahsulotlarni qoʻshing")
	}
	unfilled := 0
	for _, l := range lines {
		if l.Price == nil || (needQty && l.Qty == nil) {
			unfilled++
		}
	}
	if unfilled > 0 && !needQty {
		return res, apperr.Conflict("lines_unfilled", fmt.Sprintf("укажите цену продажи — без цены строк: %d", unfilled)).
			Uz(fmt.Sprintf("sotish narxini kiriting — narxsiz qatorlar: %d", unfilled)).
			WithDetails(map[string]any{"count": unfilled})
	}
	if unfilled > 0 {
		return res, apperr.Conflict("lines_unfilled", fmt.Sprintf("заполните количество и цену продажи — не заполнено строк: %d", unfilled)).
			Uz(fmt.Sprintf("miqdor va sotish narxini kiriting — toʻldirilmagan qatorlar: %d", unfilled)).
			WithDetails(map[string]any{"count": unfilled})
	}
	noPhoto := 0
	for _, l := range lines {
		if l.NoPhoto && !pricesMode {
			noPhoto++
		}
	}
	if noPhoto > 0 {
		return res, apperr.Conflict("lines_no_photo", fmt.Sprintf("добавьте фото товаров — без фото: %d", noPhoto)).
			Uz(fmt.Sprintf("mahsulot rasmlarini qoʻshing — rasmsiz: %d", noPhoto)).
			WithDetails(map[string]any{"count": noPhoto})
	}

	// 1. Цены: только изменённые относительно действующих.
	type priceItem = struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	}
	var prices []priceItem
	for _, l := range lines {
		if l.Price != nil && !l.Posted && money.D(*l.Price).Cmp(money.D(l.Current)) != 0 {
			prices = append(prices, priceItem{ProductID: l.ProductID, NewPrice: money.Amount(*l.Price)})
		}
	}
	if len(prices) > 0 {
		if err := p.Require(identity.PermPricesManage); err != nil {
			return res, apperr.Forbidden("нет права «Установка цен» — уберите свои цены продажи или попросите владельца провести").Uz("«Narxlarni belgilash» huquqi yoʻq — oʻz sotish narxlaringizni olib tashlang yoki egasidan oʻtkazishni soʻrang")
		}
		note := "Начало работы"
		doc, err := s.cat.CreatePriceDoc(ctx, p, catalog.PriceDocInput{PriceTypeID: &st.PriceTypeID, StoreID: &st.ID, Note: &note,
			Items: (*[]struct {
				ProductID string       `json:"product_id"`
				NewPrice  money.Amount `json:"new_price"`
			})(&prices)})
		if err != nil {
			return res, err
		}
		if _, err := s.cat.PostPriceDoc(ctx, p, doc.ID); err != nil {
			return res, err
		}
		res.PriceDocument = &DocRef{ID: doc.ID, Number: doc.Number}
		if _, err := s.pool.Exec(ctx, `UPDATE start_drafts SET price_doc_id = $2 WHERE id = $1`, draftID, doc.ID); err != nil {
			return res, err
		}
	}

	// 2. Оприходование по 1000 строк; каждая порция отмечается сразу.
	var todo []postLine
	for _, l := range lines {
		if !l.Posted && l.Qty != nil && money.D(*l.Qty).Sign() > 0 {
			todo = append(todo, l)
		}
	}
	note := "Начало работы"
	for i := 0; i < len(todo); i += docChunk {
		chunk := todo[i:min(i+docChunk, len(todo))]
		items := make([]inventory.ItemInput, 0, len(chunk))
		ids := make([]string, 0, len(chunk))
		for _, l := range chunk {
			cost := "0"
			if l.Cost != nil {
				cost = *l.Cost
			}
			price := money.Price(cost)
			items = append(items, inventory.ItemInput{ProductID: l.ProductID, Qty: money.Qty(*l.Qty), Price: &price})
			ids = append(ids, l.ProductID)
		}
		wh := st.WarehouseID
		doc, err := s.inv.Create(ctx, p, inventory.Input{Type: inventory.TypePosting, WarehouseID: &wh, Note: &note, Items: &items})
		if err != nil {
			return res, err
		}
		if _, err := s.inv.Post(ctx, p, doc.ID); err != nil {
			_ = s.inv.Delete(context.WithoutCancel(ctx), p, doc.ID)
			return res, err
		}
		res.Documents = append(res.Documents, DocRef{ID: doc.ID, Number: doc.Number})
		if _, err := s.pool.Exec(ctx, `
			WITH l AS (UPDATE start_lines SET document_id = $2 WHERE draft_id = $1 AND product_id = ANY($3::uuid[]))
			UPDATE start_drafts SET document_ids = array_append(document_ids, $2::uuid) WHERE id = $1`,
			draftID, doc.ID, ids); err != nil {
			return res, err
		}
	}

	// 3. Свои новые товары (draft) — на модерацию в общую базу.
	if _, err := s.pool.Exec(ctx, `
		UPDATE products SET moderation_status = 'pending'
		WHERE network_id = $2 AND moderation_status = 'draft'
		  AND id IN (SELECT product_id FROM start_lines WHERE draft_id = $1)`, draftID, p.NetworkID); err != nil {
		return res, err
	}

	// 4. Все товары черновика — в ассортимент магазина (и с нулевым остатком).
	// Без количества — «Остаток не посчитан», с количеством — посчитан.
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO store_products AS sp (network_id, store_id, product_id, uncounted_since, counted_at)
		SELECT $2, $3, product_id, CASE WHEN qty IS NULL THEN now() END, CASE WHEN qty IS NOT NULL THEN now() END
		FROM start_lines WHERE draft_id = $1
		ON CONFLICT (store_id, product_id) DO UPDATE
		SET uncounted_since = CASE WHEN EXCLUDED.counted_at IS NULL THEN COALESCE(sp.uncounted_since, EXCLUDED.uncounted_since) END,
		    counted_at = COALESCE(EXCLUDED.counted_at, sp.counted_at)`, draftID, p.NetworkID, st.ID); err != nil {
		return res, err
	}

	err = s.pool.QueryRow(ctx, `
		WITH d AS (
			UPDATE start_drafts SET status = 'posted', posted_by = $2, posted_at = now() WHERE id = $1 RETURNING id
		)
		SELECT count(*)::int, (count(*) FILTER (WHERE l.qty IS NULL))::int,
		       trim_scale(COALESCE(sum(l.qty), 0))::text, round(COALESCE(sum(l.qty * l.cost), 0), 2)::text,
		       (count(*) FILTER (WHERE p.network_id IS NULL AND p.is_active))::int,
		       (count(*) FILTER (WHERE p.network_id IS NOT NULL))::int
		FROM start_lines l JOIN products p ON p.id = l.product_id
		WHERE l.draft_id = (SELECT id FROM d)`, draftID, p.EmployeeID).
		Scan(&res.Products, &res.Uncounted, &res.Qty, &res.CostTotal, &res.Visible, &res.Pending)
	return res, err
}
