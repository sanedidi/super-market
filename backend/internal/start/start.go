// Package start — «Начало работы»: магазин заводит товары, которые у него
// уже есть. Черновик общий для панели и «SM Магазин»: товары добавляют по
// фото полок (Super Market находит их в каталоге), штрихкоду, каталогу и
// поиску. Проведение создаёт установку цен магазина и оприходование на склад.
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
	"github.com/sanedidi/super-market/backend/internal/platform/money"
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
		return apperr.NotFound("магазин не найден")
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
		return st, apperr.NotFound("магазин не найден")
	}
	if err != nil {
		return st, err
	}
	if wh == nil || whName == nil {
		return st, apperr.Conflict("no_warehouse", "у магазина нет основного склада — выберите его в настройках магазина")
	}
	st.WarehouseID, st.WarehouseName = *wh, *whName
	return st, nil
}

// --------------------------------------------------------------- черновик

type Line struct {
	ProductID    string    `json:"product_id"`
	Name         string    `json:"name"`
	Image        *string   `json:"image"`
	UnitShort    string    `json:"unit_short"`
	IsFractional bool      `json:"is_fractional"`
	Barcode      *string   `json:"barcode"`
	Qty          string    `json:"qty"`
	Cost         *string   `json:"cost"`
	Price        *string   `json:"price"`
	CurrentPrice string    `json:"current_price"`
	Source       string    `json:"source"`
	Own          bool      `json:"own"`
	Moderation   string    `json:"moderation"`
	Posted       bool      `json:"posted"`
	AddedAt      time.Time `json:"added_at"`
}

type Totals struct {
	Products   int    `json:"products"`
	Qty        string `json:"qty"`
	CostTotal  string `json:"cost_total"`
	PriceTotal string `json:"price_total"`
	NoCost     int    `json:"no_cost"`
	Pending    int    `json:"pending"`
}

type Draft struct {
	ID            *string    `json:"id"`
	StoreID       string     `json:"store_id"`
	StoreName     string     `json:"store_name"`
	WarehouseID   string     `json:"warehouse_id"`
	WarehouseName string     `json:"warehouse_name"`
	Status        string     `json:"status"`
	Lines         []Line     `json:"lines"`
	Totals        Totals     `json:"totals"`
	StockProducts int        `json:"stock_products"`
	LastPostedAt  *time.Time `json:"last_posted_at"`
}

type Filter struct {
	Query  string
	Only   string // no_cost | new
	Limit  int
	Offset int
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
	SELECT l.product_id, p.name, p.images[1], u.short_name, u.is_fractional,
	       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id),
	       trim_scale(l.qty)::text, trim_scale(l.cost)::text, l.price::text,
	       COALESCE(sp.price, np.price, p.base_price)::text,
	       l.source, p.network_id IS NOT NULL, p.moderation_status, l.document_id IS NOT NULL, l.added_at
	FROM start_lines l
	JOIN products p ON p.id = l.product_id
	JOIN units u ON u.id = p.unit_id
	LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $2 AND sp.store_id = $3
	LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $2 AND np.store_id IS NULL`

func scanLine(row pgx.CollectableRow) (Line, error) {
	var l Line
	err := row.Scan(&l.ProductID, &l.Name, &l.Image, &l.UnitShort, &l.IsFractional, &l.Barcode, &l.Qty, &l.Cost, &l.Price,
		&l.CurrentPrice, &l.Source, &l.Own, &l.Moderation, &l.Posted, &l.AddedAt)
	return l, err
}

func (s *Service) totals(ctx context.Context, q db.Querier, draftID string, st store) (Totals, error) {
	var t Totals
	err := q.QueryRow(ctx, `
		SELECT count(*)::int, trim_scale(COALESCE(sum(l.qty), 0))::text,
		       round(COALESCE(sum(l.qty * l.cost), 0), 2)::text,
		       round(COALESCE(sum(l.qty * COALESCE(l.price, sp.price, np.price, p.base_price)), 0), 2)::text,
		       (count(*) FILTER (WHERE l.cost IS NULL))::int,
		       (count(*) FILTER (WHERE p.network_id IS NOT NULL AND p.moderation_status <> 'approved'))::int
		FROM start_lines l
		JOIN products p ON p.id = l.product_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $2 AND sp.store_id = $3
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $2 AND np.store_id IS NULL
		WHERE l.draft_id = $1`, draftID, st.PriceTypeID, st.ID).
		Scan(&t.Products, &t.Qty, &t.CostTotal, &t.PriceTotal, &t.NoCost, &t.Pending)
	return t, err
}

// Get — открытый черновик магазина со строками (новые сверху) и итогами.
func (s *Service) Get(ctx context.Context, p *identity.Principal, storeID string, f Filter) (Draft, error) {
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return Draft{}, err
	}
	d := Draft{StoreID: st.ID, StoreName: st.Name, WarehouseID: st.WarehouseID, WarehouseName: st.WarehouseName,
		Status: StatusOpen, Lines: []Line{}, Totals: Totals{Qty: "0", CostTotal: "0.00", PriceTotal: "0.00"}}
	if err := s.pool.QueryRow(ctx, `
		SELECT (SELECT count(DISTINCT b.product_id)::int FROM batches b WHERE b.warehouse_id = $1 AND b.qty_remaining > 0),
		       (SELECT max(posted_at) FROM start_drafts WHERE warehouse_id = $1 AND status = 'posted')`, st.WarehouseID).
		Scan(&d.StockProducts, &d.LastPostedAt); err != nil {
		return d, err
	}
	id, status, err := openDraft(ctx, s.pool, st.WarehouseID)
	if err != nil || id == nil {
		return d, err
	}
	d.ID, d.Status = id, status
	if d.Totals, err = s.totals(ctx, s.pool, *id, st); err != nil {
		return d, err
	}
	where := ` WHERE l.draft_id = $1`
	args := []any{*id, st.PriceTypeID, st.ID}
	if q := strings.ToLower(strings.TrimSpace(f.Query)); q != "" {
		args = append(args, q)
		where += fmt.Sprintf(` AND (lower(p.name) LIKE '%%' || $%d || '%%'
			OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $%d))`, len(args), len(args))
	}
	switch f.Only {
	case "":
	case "no_cost":
		where += ` AND l.cost IS NULL`
	case "new":
		where += ` AND p.network_id IS NOT NULL`
	default:
		return d, apperr.Validation("only: ожидается no_cost или new")
	}
	limit := f.Limit
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.pool.Query(ctx, lineSelect+where+fmt.Sprintf(` ORDER BY l.added_at DESC, p.name LIMIT %d OFFSET %d`, min(limit, 1000), max(f.Offset, 0)), args...)
	if err != nil {
		return d, err
	}
	d.Lines, err = pgx.CollectRows(rows, scanLine)
	return d, err
}

// ---------------------------------------------------------------- строки

var barcodeRe = regexp.MustCompile(`^[0-9A-Za-z-]{4,32}$`)

var sources = map[string]bool{"photo": true, "barcode": true, "catalog": true, "search": true, "new": true, "manual": true}

type LineInput struct {
	ProductID string                       `json:"product_id"`
	Qty       *money.Qty                   `json:"qty"`
	Add       bool                         `json:"add"` // прибавить qty к строке (скан ещё одной штуки)
	Cost      httpx.Optional[money.Price]  `json:"cost"`
	Price     httpx.Optional[money.Amount] `json:"price"`
	Barcode   *string                      `json:"barcode"`
	Source    *string                      `json:"source"`
}

type LinesInput struct {
	StoreID string      `json:"store_id"`
	Items   []LineInput `json:"items"`
}

type LinesResult struct {
	Lines  []Line `json:"lines"`
	Totals Totals `json:"totals"`
}

// SetLines — добавить или изменить строки черновика (черновик создаётся сам).
func (s *Service) SetLines(ctx context.Context, p *identity.Principal, in LinesInput) (LinesResult, error) {
	if len(in.Items) == 0 || len(in.Items) > 500 {
		return LinesResult{}, apperr.Validation("items: от 1 до 500 товаров")
	}
	var out LinesResult
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, in.StoreID)
		if err != nil {
			return err
		}
		id, err := s.ensureDraft(ctx, tx, p, st)
		if err != nil {
			return err
		}
		ids := make([]string, 0, len(in.Items))
		for i, it := range in.Items {
			if err := s.setLine(ctx, tx, p, id, it); err != nil {
				if ae, ok := apperr.As(err); ok && len(in.Items) > 1 && ae.Status == 400 {
					return apperr.Validation(fmt.Sprintf("товар %d: %s", i+1, ae.Message))
				}
				return err
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
			return "", apperr.Conflict("draft_posting", "черновик сейчас проводится — подождите несколько секунд")
		}
		return *id, nil
	}
	var nid string
	err = tx.QueryRow(ctx, `
		INSERT INTO start_drafts (network_id, store_id, warehouse_id, created_by) VALUES ($1, $2, $3, $4) RETURNING id`,
		p.NetworkID, st.ID, st.WarehouseID, p.EmployeeID).Scan(&nid)
	return nid, err
}

func (s *Service) setLine(ctx context.Context, tx pgx.Tx, p *identity.Principal, draftID string, in LineInput) error {
	if !httpx.IsUUID(in.ProductID) {
		return apperr.Validation("product_id: товар не найден")
	}
	var fractional, active bool
	err := tx.QueryRow(ctx, `
		SELECT u.is_fractional, p.is_active FROM products p JOIN units u ON u.id = p.unit_id
		WHERE p.id = $1 AND (p.network_id IS NULL OR p.network_id = $2)`, in.ProductID, p.NetworkID).Scan(&fractional, &active)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("product_id: товар не найден")
	}
	if err != nil {
		return err
	}
	if !active {
		return apperr.Validation("product_id: товар отключён")
	}
	source := "manual"
	if in.Source != nil {
		if !sources[*in.Source] {
			return apperr.Validation("source: photo, barcode, catalog, search, new или manual")
		}
		source = *in.Source
	}
	var curQty *string
	err = tx.QueryRow(ctx, `SELECT qty::text FROM start_lines WHERE draft_id = $1 AND product_id = $2 FOR UPDATE`, draftID, in.ProductID).Scan(&curQty)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	qty := ""
	switch {
	case in.Qty != nil && !in.Qty.Valid():
		return apperr.Validation("qty: неверное количество")
	case in.Add:
		add := "1"
		if in.Qty != nil {
			add = string(*in.Qty)
		}
		qty = add
		if curQty != nil {
			qty = money.D(*curQty).Add(money.D(add)).Fixed(3)
		}
	case in.Qty != nil:
		qty = string(*in.Qty)
	case curQty == nil:
		return apperr.Validation("qty: укажите количество")
	}
	if qty != "" {
		q := money.D(qty)
		if q.Sign() <= 0 {
			return apperr.Validation("qty: количество должно быть больше нуля")
		}
		if !fractional && q.Cmp(money.D(q.Fixed(0))) != 0 {
			return apperr.Validation("qty: товар штучный — количество целое")
		}
		if q.Cmp(money.D("99999999")) > 0 {
			return apperr.Validation("qty: слишком большое количество")
		}
	}
	if in.Price.Set && in.Price.Value != nil && (!in.Price.Value.Valid() || money.D(string(*in.Price.Value)).Sign() <= 0) {
		return apperr.Validation("price: цена продажи должна быть больше нуля")
	}
	if in.Cost.Set && in.Cost.Value != nil && !in.Cost.Value.Valid() {
		return apperr.Validation("cost: неверная закупочная цена")
	}
	if in.Barcode != nil && strings.TrimSpace(*in.Barcode) != "" {
		if err := bindBarcode(ctx, tx, p, in.ProductID, strings.TrimSpace(*in.Barcode)); err != nil {
			return err
		}
	}
	var cost, price *string
	if v := in.Cost.Or(); v != nil {
		c := string(*v)
		cost = &c
	}
	if v := in.Price.Or(); v != nil {
		pr := string(*v)
		price = &pr
	}
	if curQty == nil {
		_, err = tx.Exec(ctx, `
			INSERT INTO start_lines (draft_id, product_id, qty, cost, price, source, added_by)
			VALUES ($1, $2, $3::numeric, $4::numeric, $5::numeric, $6, $7)`,
			draftID, in.ProductID, qty, cost, price, source, p.EmployeeID)
		return err
	}
	_, err = tx.Exec(ctx, `
		UPDATE start_lines SET qty = COALESCE($3::numeric, qty),
		       cost = CASE WHEN $4 THEN $5::numeric ELSE cost END,
		       price = CASE WHEN $6 THEN $7::numeric ELSE price END,
		       document_id = NULL
		WHERE draft_id = $1 AND product_id = $2`,
		draftID, in.ProductID, nilIfEmpty(qty), in.Cost.Set, cost, in.Price.Set, price)
	return err
}

func nilIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// bindBarcode — привязать штрихкод к товару, если его ещё нет в каталоге.
// Штрихкод уникален на всю платформу: чужой штрихкод — 409.
func bindBarcode(ctx context.Context, tx pgx.Tx, p *identity.Principal, productID, code string) error {
	if !barcodeRe.MatchString(code) {
		return apperr.Validation("barcode: неверный штрихкод")
	}
	var owner string
	err := tx.QueryRow(ctx, `SELECT product_id FROM product_barcodes WHERE barcode = $1`, code).Scan(&owner)
	if err == nil {
		if owner == productID {
			return nil
		}
		return apperr.Conflict("barcode_exists", "штрихкод "+code+" уже есть у другого товара").
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
		return apperr.Validation("barcode: у товара уже 10 штрихкодов")
	}
	_, err = tx.Exec(ctx, `INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)`, code, productID)
	if db.IsCheckViolation(err) {
		return apperr.Validation("barcode: неверный штрихкод")
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
			return apperr.NotFound("товара нет в черновике")
		}
		if status == StatusPosting {
			return apperr.Conflict("draft_posting", "черновик сейчас проводится")
		}
		tag, err := tx.Exec(ctx, `DELETE FROM start_lines WHERE draft_id = $1 AND product_id = $2`, *id, productID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("товара нет в черновике")
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
	DraftID       string   `json:"draft_id"`
	Products      int      `json:"products"`
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
	Qty       string
	Cost      *string
	Price     *string
	Current   string
	Posted    bool
}

// Post — провести черновик: установка цен магазина (если цены изменены)
// и оприходование на основной склад по закупочным ценам. Проведённые строки
// отмечаются — повторный вызов после сбоя доделывает оставшееся.
func (s *Service) Post(ctx context.Context, p *identity.Principal, storeID string) (PostResult, error) {
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return PostResult{}, err
	}
	var draftID string
	err = s.pool.QueryRow(ctx, `
		UPDATE start_drafts SET status = 'posting' WHERE warehouse_id = $1 AND status = 'open' RETURNING id`, st.WarehouseID).Scan(&draftID)
	if errors.Is(err, pgx.ErrNoRows) {
		id, status, gerr := openDraft(ctx, s.pool, st.WarehouseID)
		if gerr == nil && id != nil && status == StatusPosting {
			return PostResult{}, apperr.Conflict("draft_posting", "черновик уже проводится")
		}
		return PostResult{}, apperr.Conflict("draft_empty", "добавьте товары, которые есть в магазине")
	}
	if err != nil {
		return PostResult{}, err
	}
	res, err := s.post(ctx, p, st, draftID)
	if err != nil {
		if _, rerr := s.pool.Exec(context.WithoutCancel(ctx), `UPDATE start_drafts SET status = 'open' WHERE id = $1 AND status = 'posting'`, draftID); rerr != nil {
			s.log.Error("start: вернуть черновик", "id", draftID, "err", rerr)
		}
	}
	return res, err
}

func (s *Service) post(ctx context.Context, p *identity.Principal, st store, draftID string) (PostResult, error) {
	res := PostResult{DraftID: draftID, Documents: []DocRef{}}
	rows, err := s.pool.Query(ctx, `
		SELECT l.product_id, trim_scale(l.qty)::text, l.cost::text, l.price::text,
		       COALESCE(sp.price, np.price, p.base_price)::text, l.document_id IS NOT NULL
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
		err := r.Scan(&l.ProductID, &l.Qty, &l.Cost, &l.Price, &l.Current, &l.Posted)
		return l, err
	})
	if err != nil {
		return res, err
	}
	if len(lines) == 0 {
		return res, apperr.Conflict("draft_empty", "добавьте товары, которые есть в магазине")
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
			return res, apperr.Forbidden("нет права «Установка цен» — уберите свои цены продажи или попросите владельца провести")
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
		if !l.Posted {
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
			items = append(items, inventory.ItemInput{ProductID: l.ProductID, Qty: money.Qty(l.Qty), Price: &price})
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

	err = s.pool.QueryRow(ctx, `
		WITH d AS (
			UPDATE start_drafts SET status = 'posted', posted_by = $2, posted_at = now() WHERE id = $1 RETURNING id
		)
		SELECT count(*)::int, trim_scale(COALESCE(sum(l.qty), 0))::text, round(COALESCE(sum(l.qty * l.cost), 0), 2)::text,
		       (count(*) FILTER (WHERE p.network_id IS NULL AND p.is_active))::int,
		       (count(*) FILTER (WHERE p.network_id IS NOT NULL))::int
		FROM start_lines l JOIN products p ON p.id = l.product_id
		WHERE l.draft_id = (SELECT id FROM d)`, draftID, p.EmployeeID).
		Scan(&res.Products, &res.Qty, &res.CostTotal, &res.Visible, &res.Pending)
	return res, err
}
