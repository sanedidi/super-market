package cafe

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// Данные для панели кафе (этап 2): стоп-лист, поиск продуктов для техкарты,
// цены продуктов, «Склад продуктов → Остатки», предпросмотр производства.

// ---------------------------------------------------------------- стоп-лист

type StopItem struct {
	ProductID string    `json:"product_id"`
	Name      string    `json:"name"`
	Group     *string   `json:"menu_group_name"`
	Image     *string   `json:"image"`
	Since     time.Time `json:"since"`
	By        *string   `json:"by"`
}

func (s *Service) ListStop(ctx context.Context, p *identity.Principal, storeID string) ([]StopItem, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT sl.product_id, loc(pr.name, pr.name_uz), (SELECT loc(g.name, g.name_uz) FROM menu_groups g WHERE g.id = pr.menu_group_id),
		       pr.images[1], sl.created_at, e.full_name
		FROM stop_list sl JOIN products pr ON pr.id = sl.product_id LEFT JOIN employees e ON e.id = sl.created_by
		WHERE sl.store_id = $1 ORDER BY sl.created_at DESC`, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[StopItem])
}

type StopInput struct {
	StoreID   string `json:"store_id"`
	ProductID string `json:"product_id"`
	Stopped   bool   `json:"stopped"`
}

// SetStop ставит блюдо на стоп в точке или снимает со стопа.
func (s *Service) SetStop(ctx context.Context, p *identity.Principal, in StopInput) ([]StopItem, error) {
	if err := p.RequireAny(identity.PermCatalogManage, identity.PermSalesPOS); err != nil {
		return nil, err
	}
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if !httpx.IsUUID(in.ProductID) {
		return nil, apperr.Validation("product_id: блюдо не найдено").Uz("product_id: taom topilmadi")
	}
	if err := setStop(ctx, s.pool, p.NetworkID, in.StoreID, in.ProductID, in.Stopped, p.EmployeeID); err != nil {
		return nil, err
	}
	return s.ListStop(ctx, p, in.StoreID)
}

// ------------------------------------------------- продукты для техкарты

type Ingredient struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Kind      string  `json:"kind"`
	UnitShort string  `json:"unit_short"`
	Barcode   *string `json:"barcode"`
	// Цена последнего прихода (у заготовки — по техкарте); nil — не приходовали.
	Cost *string `json:"cost"`
}

// SearchIngredients — товары каталога и заготовки сети для техкарты
// (без блюд); пустой запрос — заготовки сети.
func (s *Service) SearchIngredients(ctx context.Context, p *identity.Principal, raw string, withDishes bool) ([]Ingredient, error) {
	if err := s.read(ctx, p); err != nil {
		return nil, err
	}
	raw = strings.TrimSpace(raw)
	args := []any{p.NetworkID, withDishes}
	var sql string
	if raw == "" {
		sql = `SELECT p.id, loc(p.name, p.name_uz), p.kind, loc(u.short_name, u.short_name_uz), NULL::text
			FROM products p JOIN units u ON u.id = p.unit_id
			WHERE p.network_id = $1 AND p.is_active AND (p.kind = 'prep' OR ($2 AND p.kind = 'dish'))
			ORDER BY p.kind DESC, p.name LIMIT 30`
	} else {
		sc := productsearch.Scope{NetworkID: p.NetworkID}
		m, err := productsearch.Resolve(ctx, s.pool, raw, sc)
		if err != nil {
			return nil, err
		}
		if m.Empty() {
			return []Ingredient{}, nil
		}
		sql = `SELECT p.id, loc(p.name, p.name_uz), p.kind, loc(u.short_name, u.short_name_uz),
			       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id)
			FROM product_search s JOIN products p ON p.id = s.product_id JOIN units u ON u.id = p.unit_id
			WHERE ` + sc.Where("s", &args) + ` AND ` + m.Where("s", &args) + ` AND p.is_active
			  AND (p.kind <> 'dish' OR ($2 AND p.network_id = $1))
			ORDER BY (p.network_id IS NOT NULL) DESC, ` + m.Rank("s", &args) + ` DESC, s.score DESC, ` + productsearch.NameOrder("s") + ` LIMIT 30`
	}
	rows, err := s.pool.Query(ctx, sql, productsearch.Args(args)...)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Ingredient, error) {
		var i Ingredient
		err := r.Scan(&i.ID, &i.Name, &i.Kind, &i.UnitShort, &i.Barcode)
		return i, err
	})
	if err != nil || len(list) == 0 {
		return list, err
	}
	book, err := loadCostBook(ctx, s.pool, p.NetworkID)
	if err != nil {
		return nil, err
	}
	if err := book.loadLast(ctx, s.pool, p.NetworkID, ingredientIDs(list)); err != nil {
		return nil, err
	}
	for i := range list {
		if v := book.unit(list[i].ID); v.complete {
			c := v.cost.Money()
			list[i].Cost = &c
		}
	}
	return list, nil
}

func ingredientIDs(list []Ingredient) []string {
	out := make([]string, len(list))
	for i, x := range list {
		out[i] = x.ID
	}
	return out
}

// loadLast — цена последней партии для продуктов, которых нет в техкартах.
func (b *costBook) loadLast(ctx context.Context, q db.Querier, networkID string, ids []string) error {
	need := []string{}
	for _, id := range ids {
		if _, ok := b.last[id]; !ok {
			need = append(need, id)
		}
	}
	if len(need) == 0 {
		return nil
	}
	rows, err := q.Query(ctx, `
		SELECT DISTINCT ON (product_id) product_id, unit_cost::text
		FROM batches WHERE network_id = $1 AND product_id = ANY($2::uuid[])
		ORDER BY product_id, created_at DESC, id DESC`, networkID, need)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, c string
		if err := rows.Scan(&id, &c); err != nil {
			return err
		}
		b.last[id] = money.D(c)
		delete(b.memo, id)
	}
	return rows.Err()
}

// --------------------------------------------- Склад продуктов → Остатки

type StockItem struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Kind      string  `json:"kind"`
	UnitShort string  `json:"unit_short"`
	Qty       string  `json:"qty"`  // остаток за вычетом «минуса»
	Cost      *string `json:"cost"` // цена последнего прихода
	Value     string  `json:"value"`
	PerDay    string  `json:"per_day"`
	// DaysLeft — на сколько дней хватит (nil — расхода не было).
	DaysLeft  *string `json:"days_left"`
	DishCount int     `json:"dish_count"`
	// ok, low (хватит меньше чем на 2 дня), minus, none (нет и не расходуется).
	Status string `json:"status"`
}

type StockSummary struct {
	WarehouseID string      `json:"warehouse_id"`
	Value       string      `json:"value"`
	Low         int         `json:"low"`
	Minus       int         `json:"minus"`
	SpoilWeek   string      `json:"spoil_week"`
	SpoilShare  *string     `json:"spoil_share"` // % порчи от расхода за неделю
	Items       []StockItem `json:"items"`
}

// lowDays — «заканчивается»: хватит меньше чем на столько дней.
const lowDays = 2

// Stock — остатки продуктов на складе кафе: сколько осталось, расход в
// день за 14 дней, на сколько хватит, что ушло в минус, в скольких блюдах.
func (s *Service) Stock(ctx context.Context, p *identity.Principal, storeID, warehouseID, q, status string) (StockSummary, error) {
	out := StockSummary{Items: []StockItem{}}
	if err := s.read(ctx, p); err != nil {
		return out, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return out, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var wh *string
	if warehouseID != "" {
		wh = &warehouseID
	}
	w, err := storeWarehouse(ctx, s.pool, p.NetworkID, storeID, wh)
	if err != nil {
		return out, err
	}
	out.WarehouseID = w
	rows, err := s.pool.Query(ctx, `
		WITH ids AS (
			SELECT product_id FROM batches WHERE warehouse_id = $1 AND qty_remaining > 0
			UNION SELECT product_id FROM stock_shortfalls WHERE warehouse_id = $1 AND closed_at IS NULL
			UNION SELECT ri.ingredient_id FROM recipe_items ri JOIN products d ON d.id = ri.product_id
			      WHERE d.network_id = $2 AND d.is_active AND NOT ri.not_tracked
		), x AS (
			SELECT pr.id, loc(pr.name, pr.name_uz) AS name, pr.kind, loc(u.short_name, u.short_name_uz) AS unit,
			       COALESCE((SELECT sum(b.qty_remaining) FROM batches b WHERE b.warehouse_id = $1 AND b.product_id = pr.id), 0)
			     - COALESCE((SELECT sum(f.qty - f.qty_closed) FROM stock_shortfalls f WHERE f.warehouse_id = $1 AND f.product_id = pr.id AND f.closed_at IS NULL), 0) AS qty,
			       (SELECT b.unit_cost FROM batches b WHERE b.network_id = $2 AND b.product_id = pr.id ORDER BY b.created_at DESC, b.id DESC LIMIT 1) AS cost,
			       COALESCE((SELECT sum(b.qty_remaining * b.unit_cost) FROM batches b WHERE b.warehouse_id = $1 AND b.product_id = pr.id AND b.qty_remaining > 0), 0) AS value,
			       (COALESCE((SELECT -sum(m.qty) FROM stock_movements m WHERE m.warehouse_id = $1 AND m.product_id = pr.id AND m.qty < 0
			                  AND m.doc_type IN ('sale', 'order', 'production') AND m.created_at > now() - interval '14 days'), 0)
			      + COALESCE((SELECT sum(f.qty - f.qty_closed) FROM stock_shortfalls f WHERE f.warehouse_id = $1 AND f.product_id = pr.id
			                  AND f.closed_at IS NULL AND f.created_at > now() - interval '14 days'), 0)) / 14.0 AS per_day,
			       (SELECT count(DISTINCT ri.product_id) FROM recipe_items ri JOIN products d ON d.id = ri.product_id
			         WHERE ri.ingredient_id = pr.id AND d.is_active)::int AS dishes
			FROM ids JOIN products pr ON pr.id = ids.product_id JOIN units u ON u.id = pr.unit_id
			WHERE pr.kind <> 'dish' AND ($3 = '' OR pr.name ILIKE '%' || $3 || '%' OR pr.name_uz ILIKE '%' || $3 || '%'
			      OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = pr.id AND pb.barcode = $3))
		)
		SELECT id, name, kind, unit, trim_scale(round(qty, 3))::text, round(cost, 2)::text, round(value, 2)::text,
		       trim_scale(round(per_day, 3))::text,
		       CASE WHEN per_day > 0 AND qty > 0 THEN trim_scale(round(qty / per_day, 1))::text END,
		       dishes,
		       CASE WHEN qty < 0 THEN 'minus' WHEN per_day > 0 AND qty < per_day * $4 THEN 'low'
		            WHEN qty <= 0 AND per_day = 0 THEN 'none' ELSE 'ok' END
		FROM x ORDER BY (qty < 0) DESC, (per_day > 0 AND qty < per_day * $4) DESC, name`,
		w, p.NetworkID, strings.TrimSpace(q), lowDays)
	if err != nil {
		return out, err
	}
	all, err := pgx.CollectRows(rows, pgx.RowToStructByPos[StockItem])
	if err != nil {
		return out, err
	}
	total := money.D("0")
	for _, it := range all {
		total = total.Add(money.D(it.Value))
		switch it.Status {
		case "minus":
			out.Minus++
		case "low":
			out.Low++
		}
		if status == "" || status == it.Status {
			out.Items = append(out.Items, it)
		}
	}
	out.Value = total.Money()
	if !SeesCost(p) {
		out.Value = ""
		for i := range out.Items {
			out.Items[i].Cost, out.Items[i].Value = nil, ""
		}
	}
	var spent string
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE((SELECT sum(total) FROM stock_documents WHERE warehouse_id = $1 AND type = 'write_off' AND status = 'posted'
		                 AND posted_at > now() - interval '7 days'), 0)::numeric(18,2)::text,
		       COALESCE((SELECT -sum(qty * unit_cost) FROM stock_movements WHERE warehouse_id = $1 AND qty < 0
		                 AND doc_type IN ('sale', 'order', 'production') AND created_at > now() - interval '7 days'), 0)::numeric(18,2)::text`,
		w).Scan(&out.SpoilWeek, &spent); err != nil {
		return out, err
	}
	if sp := money.D(spent); sp.Sign() > 0 {
		v := money.D(out.SpoilWeek).Mul(money.D("100")).Div(sp).Fixed(1)
		out.SpoilShare = &v
	}
	return out, nil
}

// SeesCost — себестоимость видят владелец и роли со складом или отчётами.
func SeesCost(p *identity.Principal) bool {
	return p.CanAny(identity.PermInventoryManage, identity.PermReportsView, identity.PermCatalogManage)
}

// ------------------------------------------- предпросмотр производства

type PreviewLine struct {
	IngredientID string `json:"ingredient_id"`
	Name         string `json:"name"`
	UnitShort    string `json:"unit_short"`
	Qty          string `json:"qty"`
	Stock        string `json:"stock"`
	Enough       bool   `json:"enough"`
	Short        string `json:"short"`
}

type ProductionPreview struct {
	WarehouseID   string        `json:"warehouse_id"`
	WarehouseName string        `json:"warehouse_name"`
	Qty           string        `json:"qty"`
	Cost          string        `json:"cost"`
	ExpiresAt     *time.Time    `json:"expires_at"`
	Lines         []PreviewLine `json:"lines"`
	NotTracked    []string      `json:"not_tracked"`
}

// PreviewProduction — что спишется по техкарте заготовки и хватает ли (П12).
func (s *Service) PreviewProduction(ctx context.Context, p *identity.Principal, storeID, productID, rawQty string) (ProductionPreview, error) {
	out := ProductionPreview{Lines: []PreviewLine{}, NotTracked: []string{}}
	if err := s.read(ctx, p); err != nil {
		return out, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return out, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	q := money.Qty(rawQty)
	if !q.Valid() || money.D(rawQty).Sign() <= 0 {
		return out, apperr.Validation("qty: количество должно быть больше нуля").Uz("qty: miqdor noldan katta boʻlishi kerak")
	}
	qty := money.D(money.D(rawQty).Fixed(3))
	out.Qty = qty.Fixed(3)
	var shelf *int
	var kind string
	err := s.pool.QueryRow(ctx, `SELECT kind, shelf_hours FROM products WHERE id = $1 AND network_id = $2`, productID, p.NetworkID).Scan(&kind, &shelf)
	if !httpx.IsUUID(productID) || errors.Is(err, pgx.ErrNoRows) || (err == nil && kind != KindPrep) {
		return out, apperr.Validation("product_id: заготовка не найдена").Uz("product_id: yarim tayyor mahsulot topilmadi")
	}
	if err != nil {
		return out, err
	}
	if out.WarehouseID, err = storeWarehouse(ctx, s.pool, p.NetworkID, storeID, nil); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `SELECT name FROM warehouses WHERE id = $1`, out.WarehouseID).Scan(&out.WarehouseName); err != nil {
		return out, err
	}
	if shelf != nil {
		t := s.now().Add(time.Duration(*shelf) * time.Hour)
		out.ExpiresAt = &t
	}
	needs, err := Explode(ctx, s.pool, productID, qty, nil)
	if err != nil {
		return out, err
	}
	book, err := loadCostBook(ctx, s.pool, p.NetworkID)
	if err != nil {
		return out, err
	}
	cost := money.D("0")
	for _, n := range needs {
		l := PreviewLine{IngredientID: n.IngredientID, Qty: n.Qty.Fixed(3)}
		var stock string
		if err := s.pool.QueryRow(ctx, `
			SELECT loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz),
			       (COALESCE((SELECT sum(qty_remaining) FROM batches WHERE warehouse_id = $2 AND product_id = p.id), 0)
			      - COALESCE((SELECT sum(qty - qty_closed) FROM stock_shortfalls WHERE warehouse_id = $2 AND product_id = p.id AND closed_at IS NULL), 0))::numeric(14,3)::text
			FROM products p JOIN units u ON u.id = p.unit_id WHERE p.id = $1`, n.IngredientID, out.WarehouseID).Scan(&l.Name, &l.UnitShort, &stock); err != nil {
			return out, err
		}
		l.Stock = stock
		have := money.D(stock)
		l.Enough = have.Cmp(n.Qty) >= 0
		short := n.Qty.Sub(have)
		if have.Sign() < 0 {
			short = n.Qty
		}
		if short.Sign() < 0 {
			short = money.D("0")
		}
		l.Short = short.Fixed(3)
		cost = cost.Add(book.unit(n.IngredientID).cost.Mul(n.Qty))
		out.Lines = append(out.Lines, l)
	}
	out.Cost = cost.Money()
	rows, err := s.pool.Query(ctx, `SELECT loc(i.name, i.name_uz) FROM recipe_items ri JOIN products i ON i.id = ri.ingredient_id
		WHERE ri.product_id = $1 AND ri.not_tracked ORDER BY ri.line`, productID)
	if err != nil {
		return out, err
	}
	if out.NotTracked, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return out, err
	}
	if out.NotTracked == nil {
		out.NotTracked = []string{}
	}
	return out, nil
}
