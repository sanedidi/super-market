// Package staff — серверная часть приложения «SM Сотрудник» (Figma
// «Super Market · SM Сотрудник», С1–С13): цена и остаток по скану, автозадачи
// (товары в минусе, не посчитаны, поменять ценники, принять товар),
// списание с фото и «Мой день». Пересчёт — POST /store/start/count, сборка
// заказов — /store/orders/{id}/take и соседние (internal/orders/picking.go).
package staff

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/reports"
)

type Service struct {
	pool *pgxpool.Pool
	inv  *inventory.Service
	rep  *reports.Service
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool, inv *inventory.Service, rep *reports.Service) *Service {
	return &Service{pool: pool, inv: inv, rep: rep, now: time.Now}
}

// store — магазин сотрудника: основной склад и тип цены кассы.
type store struct {
	ID          string
	WarehouseID string
	PriceType   string
}

func (s *Service) store(ctx context.Context, p *identity.Principal, storeID string) (store, error) {
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return store{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	var wh *string
	err := s.pool.QueryRow(ctx, `SELECT default_warehouse_id FROM stores WHERE id = $1 AND network_id = $2`, storeID, p.NetworkID).Scan(&wh)
	if errors.Is(err, pgx.ErrNoRows) {
		return store{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if err != nil {
		return store{}, err
	}
	if wh == nil {
		return store{}, apperr.Conflict("no_warehouse", "у магазина нет основного склада — выберите его в настройках магазина").Uz("doʻkonda asosiy ombor yoʻq — uni doʻkon sozlamalarida tanlang")
	}
	pt, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if err != nil {
		return store{}, err
	}
	return store{ID: storeID, WarehouseID: *wh, PriceType: pt}, nil
}

// ------------------------------------------------------------ сканер (С5)

// Glance — шторка сканера: цена продажи, остаток, продажи. Цену закупки и
// прибыль сотрудник не видит — только «не задана» (С5б), если она нужна.
type Glance struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	Barcode      *string `json:"barcode"`
	Category     string  `json:"category"`
	UnitShort    string  `json:"unit_short"`
	IsFractional bool    `json:"is_fractional"`
	// InStore — товар есть в «Моих товарах» магазина.
	InStore bool `json:"in_store"`
	// Price — цена продажи на кассе (null — не задана), PriceChangedAt — когда менялась.
	Price          *string    `json:"price"`
	PriceChangedAt *time.Time `json:"price_changed_at"`
	// Qty — остаток на основном складе; Uncounted — остаток ни разу не вводили;
	// Short — продано сверх остатка после подсчёта (товар «в минусе»).
	Qty       string `json:"qty"`
	Uncounted bool   `json:"uncounted"`
	Short     string `json:"short"`
	// Sold7 — продано за 7 дней; DaysLeft — на сколько дней хватит (по продажам за 28 дней).
	Sold7    string `json:"sold_7d"`
	DaysLeft *int   `json:"days_left"`
	// Weight — вес с наклейки весов, кг (если сканировали наклейку).
	Weight *string `json:"weight"`
	// Что можно сделать из шторки: «Цена» (prices.manage), «Пересчитать» и «Списать» (inventory.manage).
	CanPrice bool `json:"can_price"`
	CanCount bool `json:"can_count"`
	// NoCost — цена закупки не задана (только с правом «Склад», иначе поля нет):
	// stock — остаток без цены, sold — продано без себестоимости.
	NoCost *NoCost `json:"no_cost,omitempty"`
}

type NoCost struct {
	Stock string `json:"stock"`
	Sold  string `json:"sold"`
}

// GlanceInput — код со сканера (штрихкод, наклейка весов, код маркировки) или товар.
type GlanceInput struct {
	StoreID   string
	Code      string
	ProductID string
}

func requireStaff(p *identity.Principal) error {
	return p.RequireAny(identity.PermSalesPOS, identity.PermInventoryManage, identity.PermOrdersManage, identity.PermPricesManage)
}

// Glance — цена и остаток товара по скану.
func (s *Service) Glance(ctx context.Context, p *identity.Principal, in GlanceInput) (Glance, error) {
	var g Glance
	if err := requireStaff(p); err != nil {
		return g, err
	}
	st, err := s.store(ctx, p, in.StoreID)
	if err != nil {
		return g, err
	}
	productID := strings.TrimSpace(in.ProductID)
	if productID == "" {
		code := strings.TrimSpace(in.Code)
		if code == "" {
			return g, apperr.Validation("code: отсканируйте штрихкод").Uz("code: shtrix-kodni skanerlang")
		}
		var weight *string
		productID, weight, err = s.resolve(ctx, p, st, code)
		if err != nil {
			return g, err
		}
		g.Weight = weight
	} else if !httpx.IsUUID(productID) {
		return g, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	var priceSet bool
	err = s.pool.QueryRow(ctx, `
		WITH pr AS (
			SELECT p.id, loc(p.name, p.name_uz) AS name, p.images[1] AS image, loc(c.name, c.name_uz) AS category,
			       loc(u.short_name, u.short_name_uz) AS unit, u.is_fractional, p.base_price,
			       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id) AS barcode
			FROM products p JOIN units u ON u.id = p.unit_id JOIN categories c ON c.id = p.category_id
			WHERE p.id = $1 AND p.is_active AND (p.network_id = $4 OR (p.network_id IS NULL AND p.moderation_status = 'approved'))
		)
		SELECT pr.id, pr.name, pr.image, pr.barcode, pr.category, pr.unit, pr.is_fractional,
		       sp.product_id IS NOT NULL, COALESCE(sp.uncounted_since IS NOT NULL, false),
		       COALESCE(spr.price, npr.price, pr.base_price)::text, COALESCE(spr.price, npr.price) IS NOT NULL OR pr.base_price > 0,
		       COALESCE(spr.updated_at, npr.updated_at),
		       trim_scale(COALESCE((SELECT sum(b.qty_remaining) FROM batches b WHERE b.warehouse_id = $3 AND b.product_id = pr.id AND b.qty_remaining > 0), 0))::text,
		       trim_scale(COALESCE((SELECT sum(i.short_qty) FROM sales x JOIN sale_items i ON i.sale_id = x.id
		         WHERE x.store_id = $2 AND i.product_id = pr.id AND i.short_qty > 0
		           AND x.sold_at > GREATEST(now() - interval '30 days', COALESCE(sp.counted_at, '-infinity'::timestamptz))), 0))::text,
		       trim_scale(COALESCE((SELECT -sum(m.qty) FROM stock_movements m WHERE m.warehouse_id = $3 AND m.product_id = pr.id
		         AND m.doc_type IN ('sale', 'order') AND m.qty < 0 AND m.created_at > now() - interval '7 days'), 0))::text,
		       (SELECT CASE WHEN per_day > 0 THEN floor(GREATEST(COALESCE((SELECT sum(b.qty_remaining) FROM batches b
		                 WHERE b.warehouse_id = $3 AND b.product_id = pr.id AND b.qty_remaining > 0), 0), 0) / per_day)::int END
		        FROM (SELECT COALESCE((SELECT -sum(m.qty) FROM stock_movements m WHERE m.warehouse_id = $3 AND m.product_id = pr.id
		               AND m.doc_type IN ('sale', 'order') AND m.qty < 0 AND m.created_at > now() - interval '28 days'), 0) / 28.0 AS per_day) d)
		FROM pr
		LEFT JOIN store_products sp ON sp.store_id = $2 AND sp.product_id = pr.id
		LEFT JOIN prices spr ON spr.product_id = pr.id AND spr.price_type_id = $5 AND spr.store_id = $2
		LEFT JOIN prices npr ON npr.product_id = pr.id AND npr.price_type_id = $5 AND npr.store_id IS NULL AND npr.network_id = $4`,
		productID, st.ID, st.WarehouseID, p.NetworkID, st.PriceType).
		Scan(&g.ProductID, &g.Name, &g.Image, &g.Barcode, &g.Category, &g.UnitShort, &g.IsFractional,
			&g.InStore, &g.Uncounted, &g.Price, &priceSet, &g.PriceChangedAt, &g.Qty, &g.Short, &g.Sold7, &g.DaysLeft)
	if errors.Is(err, pgx.ErrNoRows) {
		return Glance{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if err != nil {
		return Glance{}, err
	}
	if !priceSet {
		g.Price = nil
	}
	if g.Uncounted {
		g.DaysLeft = nil
	}
	g.CanPrice = p.Can(identity.PermPricesManage)
	g.CanCount = p.Can(identity.PermInventoryManage)
	if g.CanCount && s.rep != nil {
		stock, sold, err := s.rep.MissingCost(ctx, p.NetworkID, st.ID, g.ProductID)
		if err != nil {
			return Glance{}, err
		}
		if money.D(stock).Sign() > 0 || money.D(sold).Sign() > 0 {
			g.NoCost = &NoCost{Stock: stock, Sold: sold}
		}
	}
	return g, nil
}

// SetCost — «Поставить» цену закупки из шторки сканера (С5в): только с правом
// «Склад» и только там, где её нет (остаток без цены и проданные без
// себестоимости чеки). Уже заданную цену меняет приход.
func (s *Service) SetCost(ctx context.Context, p *identity.Principal, in reports.CostInput) (reports.CostResult, error) {
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return reports.CostResult{}, err
	}
	return s.rep.SetCost(ctx, p, in)
}

// resolve — товар по коду со сканера: штрихкод товара, наклейка весов
// (префикс · номер на весах · вес) или код маркировки (01 + GTIN).
func (s *Service) resolve(ctx context.Context, p *identity.Principal, st store, code string) (string, *string, error) {
	find := func(barcodes ...string) (string, error) {
		var id string
		err := s.pool.QueryRow(ctx, `
			SELECT p.id FROM product_barcodes b JOIN products p ON p.id = b.product_id
			LEFT JOIN store_products sp ON sp.store_id = $3 AND sp.product_id = p.id
			WHERE barcode_key(b.barcode) = ANY(SELECT barcode_key(x) FROM unnest($2::text[]) x) AND p.is_active AND p.kind <> 'dish'
			  AND (p.network_id = $1 OR (p.network_id IS NULL AND p.moderation_status = 'approved'))
			ORDER BY (sp.product_id IS NOT NULL) DESC, (p.network_id IS NOT NULL) DESC LIMIT 1`, p.NetworkID, barcodes, st.ID).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", nil
		}
		return id, err
	}
	// Наклейка весов: EAN-13, первые 2 цифры — префикс сети.
	if len(code) == 13 && digitsOnly(code) && validEAN13(code) {
		var enabled bool
		var prefixes []string
		var digits, step int
		var value string
		if err := s.pool.QueryRow(ctx, `SELECT scales_enabled, pos_weight_prefixes, scale_item_digits, scale_value, scale_weight_step
			FROM networks WHERE id = $1`, p.NetworkID).Scan(&enabled, &prefixes, &digits, &value, &step); err != nil {
			return "", nil, err
		}
		if enabled && contains(prefixes, code[:2]) {
			if digits < 4 || digits > 6 {
				digits = 5
			}
			plu, _ := strconv.Atoi(code[2 : 2+digits])
			raw, _ := strconv.Atoi(code[2+digits : 12])
			var id string
			err := s.pool.QueryRow(ctx, `SELECT product_id FROM pos_plu WHERE network_id = $1 AND plu = $2`, p.NetworkID, plu).Scan(&id)
			if err == nil && raw > 0 {
				var w *string
				if value != "sum" {
					grams := raw
					if step == 10 {
						grams *= 10
					}
					kg := money.D(strconv.Itoa(grams)).Div(money.D("1000")).Fixed(3)
					w = &kg
				}
				return id, w, nil
			}
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return "", nil, err
			}
		}
	}
	codes := []string{code}
	// Код маркировки DataMatrix: 01 + GTIN-14 + …
	if strings.HasPrefix(code, "01") && len(code) >= 16 && digitsOnly(code[2:16]) {
		gtin := code[2:16]
		codes = append(codes, gtin, strings.TrimPrefix(gtin, "0"))
	}
	id, err := find(codes...)
	if err != nil {
		return "", nil, err
	}
	if id == "" {
		return "", nil, apperr.NotFound("товара с этим штрихкодом нет в Super Market").Uz("bu shtrix-kodli mahsulot Super Marketda yoʻq")
	}
	return id, nil, nil
}

func digitsOnly(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}

func validEAN13(c string) bool {
	sum := 0
	for i := 0; i < 12; i++ {
		d := int(c[i] - '0')
		if i%2 == 1 {
			d *= 3
		}
		sum += d
	}
	return (10-sum%10)%10 == int(c[12]-'0')
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------- задачи (С12)

// Tasks — автозадачи на сегодня: создаются и закрываются сами. Видят
// сотрудники с правом «Склад» (inventory.manage) и владелец; у остальных — пусто.
type Tasks struct {
	// Negative — товары в минусе: продали больше, чем было после подсчёта.
	Negative int `json:"negative"`
	// Uncounted — остаток ни разу не вводили (магазин начал без инвентаризации).
	Uncounted int `json:"uncounted"`
	// PriceTags — у скольких товаров поменялась цена, а ценник ещё старый.
	PriceTags          int        `json:"price_tags"`
	PriceTagsChangedAt *time.Time `json:"price_tags_changed_at"`
	// Incoming — приходы от агентов, которые ждут приёмки.
	Incoming []Incoming `json:"incoming"`
	// Done — что сотрудник сделал сегодня (вкладка «Выполнены»).
	Done []DoneItem `json:"done"`
	// Open — задач на сегодня (непустые автозадачи и приходы).
	Open int `json:"open"`
}

type Incoming struct {
	DocumentID string `json:"document_id"`
	Number     int64  `json:"number"`
	Supplier   string `json:"supplier"`
	// SupplierID — поставщик-агент (/store/suppliers/{id}), null — обычный контрагент.
	SupplierID *string   `json:"supplier_id"`
	ItemsCount int       `json:"items_count"`
	Total      string    `json:"total"`
	CreatedAt  time.Time `json:"created_at"`
}

type DoneItem struct {
	Kind  string    `json:"kind"` // count, write_off, price_tags, order, income
	Title string    `json:"title"`
	At    time.Time `json:"at"`
}

// shortExpr — сколько товара продали сверх остатка после подсчёта (за 30 дней),
// как в «Посчитать остатки» (internal/start/count.go).
const shortExpr = `COALESCE((SELECT sum(i.short_qty) FROM sales x JOIN sale_items i ON i.sale_id = x.id
	WHERE x.store_id = sp.store_id AND i.product_id = sp.product_id AND i.short_qty > 0
	  AND x.sold_at > GREATEST(now() - interval '30 days', COALESCE(sp.counted_at, '-infinity'::timestamptz))), 0)`

func (s *Service) Tasks(ctx context.Context, p *identity.Principal, storeID string) (Tasks, error) {
	out := Tasks{Incoming: []Incoming{}, Done: []DoneItem{}}
	if err := requireStaff(p); err != nil {
		return out, err
	}
	st, err := s.store(ctx, p, storeID)
	if err != nil {
		return out, err
	}
	if p.Can(identity.PermInventoryManage) {
		if err := s.pool.QueryRow(ctx, `
			SELECT (count(*) FILTER (WHERE sp.uncounted_since IS NULL AND `+shortExpr+` > 0))::int,
			       (count(*) FILTER (WHERE sp.uncounted_since IS NOT NULL))::int
			FROM store_products sp JOIN products pr ON pr.id = sp.product_id AND pr.is_active AND pr.kind <> 'dish'
			WHERE sp.store_id = $1`, st.ID).Scan(&out.Negative, &out.Uncounted); err != nil {
			return out, err
		}
		tags, err := s.priceTags(ctx, p, st, 0)
		if err != nil {
			return out, err
		}
		out.PriceTags = len(tags)
		for _, t := range tags {
			if out.PriceTagsChangedAt == nil || t.ChangedAt.After(*out.PriceTagsChangedAt) {
				at := t.ChangedAt
				out.PriceTagsChangedAt = &at
			}
		}
		rows, err := s.pool.Query(ctx, `
			SELECT d.id, d.number, COALESCE(c.name, ''), c.distributor_id::text, (SELECT count(*) FROM stock_document_items i WHERE i.document_id = d.id)::int,
			       COALESCE((SELECT sum(i.qty * i.price) FROM stock_document_items i WHERE i.document_id = d.id), 0)::numeric(18,2)::text,
			       d.created_at
			FROM stock_documents d JOIN warehouses w ON w.id = d.warehouse_id
			LEFT JOIN counterparties c ON c.id = d.counterparty_id
			WHERE d.network_id = $1 AND w.store_id = $2 AND d.type = 'income' AND d.status = 'draft' AND d.source_shipment_id IS NOT NULL
			ORDER BY d.created_at`, p.NetworkID, st.ID)
		if err != nil {
			return out, err
		}
		if out.Incoming, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Incoming]); err != nil {
			return out, err
		}
	}
	if out.Negative > 0 {
		out.Open++
	}
	if out.Uncounted > 0 {
		out.Open++
	}
	if out.PriceTags > 0 {
		out.Open++
	}
	out.Open += len(out.Incoming)
	out.Done, err = s.done(ctx, p, st)
	return out, err
}

// done — что сотрудник сделал сегодня (по Ташкенту).
func (s *Service) done(ctx context.Context, p *identity.Principal, st store) ([]DoneItem, error) {
	from := dayStart(s.now())
	rows, err := s.pool.Query(ctx, `
		SELECT 'count', 'Пересчитано товаров: ' || (SELECT count(*) FROM stock_document_items i WHERE i.document_id = d.id), d.posted_at
		FROM stock_documents d JOIN warehouses w ON w.id = d.warehouse_id
		WHERE d.created_by = $1 AND w.store_id = $2 AND d.type = 'inventory' AND d.status = 'posted' AND d.posted_at >= $3
		UNION ALL
		SELECT 'write_off', 'Списано: ' || COALESCE((SELECT string_agg(loc(pr.name, pr.name_uz), ', ') FROM stock_document_items i
		         JOIN products pr ON pr.id = i.product_id WHERE i.document_id = d.id), ''), d.posted_at
		FROM stock_documents d JOIN warehouses w ON w.id = d.warehouse_id
		WHERE d.created_by = $1 AND w.store_id = $2 AND d.type = 'write_off' AND d.status = 'posted' AND d.posted_at >= $3
		UNION ALL
		SELECT 'income', 'Принят приход №' || d.number, d.posted_at
		FROM stock_documents d JOIN warehouses w ON w.id = d.warehouse_id
		WHERE d.posted_by = $1 AND w.store_id = $2 AND d.type = 'income' AND d.status = 'posted' AND d.posted_at >= $3
		UNION ALL
		SELECT 'price_tags', 'Поменяно ценников: ' || count(*), max(m.marked_at)
		FROM price_tag_marks m WHERE m.employee_id = $1 AND m.store_id = $2 AND m.marked_at >= $3 HAVING count(*) > 0
		UNION ALL
		SELECT 'order', 'Собран заказ №' || o.number, o.picked_at
		FROM orders o WHERE o.picker_id = $1 AND o.store_id = $2 AND o.picked_at >= $3
		ORDER BY 3 DESC`, p.EmployeeID, st.ID, from)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[DoneItem])
}

// dayStart — начало дня по Ташкенту.
func dayStart(t time.Time) time.Time {
	l := t.In(delivery.Tashkent)
	return time.Date(l.Year(), l.Month(), l.Day(), 0, 0, 0, 0, delivery.Tashkent)
}

// ------------------------------------------------------- ценники (С12)

// PriceTag — товар, у которого поменялась цена: ценник на полке надо поменять.
type PriceTag struct {
	ProductID string    `json:"product_id"`
	Name      string    `json:"name"`
	Image     *string   `json:"image"`
	Barcode   *string   `json:"barcode"`
	UnitShort string    `json:"unit_short"`
	OldPrice  string    `json:"old_price"`
	Price     string    `json:"price"`
	ChangedAt time.Time `json:"changed_at"`
}

// priceTags — товары магазина, цена которых на кассе поменялась за 30 дней
// документом цен (магазина или всей сети), а ценник ещё не отмечен
// поменянным. Первая цена товара (раньше её не было) — не в счёт.
func (s *Service) priceTags(ctx context.Context, p *identity.Principal, st store, limit int) ([]PriceTag, error) {
	lim := ""
	if limit > 0 {
		lim = fmt.Sprintf(" LIMIT %d", limit)
	}
	rows, err := s.pool.Query(ctx, `
		WITH ch AS (
			SELECT DISTINCT ON (i.product_id) i.product_id, i.previous_price, d.posted_at
			FROM price_document_items i JOIN price_documents d ON d.id = i.document_id
			WHERE d.network_id = $1 AND d.status = 'posted' AND d.price_type_id = $3 AND (d.store_id = $2 OR d.store_id IS NULL)
			  AND d.posted_at > now() - interval '30 days' AND i.previous_price IS NOT NULL AND i.previous_price <> i.new_price
			ORDER BY i.product_id, d.posted_at DESC
		), cur AS (
			SELECT ch.*, COALESCE(spr.price, npr.price) AS price
			FROM ch
			JOIN store_products sp ON sp.store_id = $2 AND sp.product_id = ch.product_id
			LEFT JOIN prices spr ON spr.product_id = ch.product_id AND spr.price_type_id = $3 AND spr.store_id = $2
			LEFT JOIN prices npr ON npr.product_id = ch.product_id AND npr.price_type_id = $3 AND npr.store_id IS NULL AND npr.network_id = $1
		)
		SELECT pr.id, loc(pr.name, pr.name_uz), pr.images[1],
		       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = pr.id),
		       loc(u.short_name, u.short_name_uz), trim_scale(COALESCE(m.price, cur.previous_price))::text,
		       trim_scale(cur.price)::text, cur.posted_at
		FROM cur
		JOIN products pr ON pr.id = cur.product_id AND pr.is_active
		JOIN units u ON u.id = pr.unit_id
		LEFT JOIN price_tag_marks m ON m.store_id = $2 AND m.product_id = cur.product_id
		WHERE cur.price IS NOT NULL AND (m.product_id IS NULL OR (m.marked_at < cur.posted_at AND m.price <> cur.price))
		ORDER BY cur.posted_at DESC, loc(pr.name, pr.name_uz)`+lim, p.NetworkID, st.ID, st.PriceType)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[PriceTag])
}

func requireStock(p *identity.Principal) error {
	return p.RequireAny(identity.PermInventoryManage, identity.PermPricesManage)
}

// PriceTags — список «Поменять ценники».
func (s *Service) PriceTags(ctx context.Context, p *identity.Principal, storeID string) ([]PriceTag, error) {
	if err := requireStock(p); err != nil {
		return nil, err
	}
	st, err := s.store(ctx, p, storeID)
	if err != nil {
		return nil, err
	}
	return s.priceTags(ctx, p, st, 500)
}

type MarkTagsInput struct {
	StoreID    string   `json:"store_id"`
	ProductIDs []string `json:"product_ids"`
}

// MarkTags — «Ценник поменял»: товар уходит из задачи до следующей смены цены.
func (s *Service) MarkTags(ctx context.Context, p *identity.Principal, in MarkTagsInput) (map[string]int, error) {
	if err := requireStock(p); err != nil {
		return nil, err
	}
	st, err := s.store(ctx, p, in.StoreID)
	if err != nil {
		return nil, err
	}
	if len(in.ProductIDs) == 0 || len(in.ProductIDs) > 500 {
		return nil, apperr.Validation("product_ids: от 1 до 500 товаров").Uz("product_ids: 1 dan 500 tagacha mahsulot")
	}
	for _, id := range in.ProductIDs {
		if !httpx.IsUUID(id) {
			return nil, apperr.Validation("product_ids: товар не найден").Uz("product_ids: mahsulot topilmadi")
		}
	}
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO price_tag_marks (store_id, product_id, price, employee_id)
		SELECT $1, sp.product_id, COALESCE(spr.price, npr.price, pr.base_price), $4
		FROM store_products sp JOIN products pr ON pr.id = sp.product_id
		LEFT JOIN prices spr ON spr.product_id = sp.product_id AND spr.price_type_id = $3 AND spr.store_id = $1
		LEFT JOIN prices npr ON npr.product_id = sp.product_id AND npr.price_type_id = $3 AND npr.store_id IS NULL AND npr.network_id = $5
		WHERE sp.store_id = $1 AND sp.product_id = ANY($2::uuid[])
		ON CONFLICT (store_id, product_id) DO UPDATE SET price = EXCLUDED.price, employee_id = EXCLUDED.employee_id, marked_at = now()`,
		st.ID, in.ProductIDs, st.PriceType, p.EmployeeID, p.NetworkID)
	if err != nil {
		return nil, err
	}
	return map[string]int{"marked": int(tag.RowsAffected())}, nil
}

// ------------------------------------------------------------ списание (С11)

// Причины списания.
var writeOffReasons = map[string]string{
	"expired": "Просрочка",
	"defect":  "Брак",
	"broken":  "Разбилось",
	"spoiled": "Испортился",
	"other":   "Другое",
}

type WriteOffInput struct {
	StoreID   string    `json:"store_id"`
	ProductID string    `json:"product_id"`
	Qty       money.Qty `json:"qty"`
	// Reason — expired, defect, broken, spoiled, other («Другое» — с комментарием).
	Reason  string   `json:"reason"`
	Photos  []string `json:"photos"`
	Comment string   `json:"comment"`
}

type DocRef struct {
	ID     string `json:"id"`
	Number int64  `json:"number"`
}

type WriteOffResult struct {
	Document DocRef `json:"document"`
	Glance   Glance `json:"product"`
}

// WriteOff — списание товара с основного склада магазина: причина и фото
// обязательны, проводится сразу (остаток меняется, владелец видит его в журнале).
func (s *Service) WriteOff(ctx context.Context, p *identity.Principal, in WriteOffInput) (WriteOffResult, error) {
	var res WriteOffResult
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return res, err
	}
	st, err := s.store(ctx, p, in.StoreID)
	if err != nil {
		return res, err
	}
	if !httpx.IsUUID(in.ProductID) {
		return res, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	if !in.Qty.Valid() || money.D(string(in.Qty)).Sign() <= 0 {
		return res, apperr.Validation("qty: сколько списать").Uz("qty: qancha hisobdan chiqarish")
	}
	reason, ok := writeOffReasons[in.Reason]
	if !ok {
		return res, apperr.Validation("reason: выберите причину").Uz("reason: sababni tanlang")
	}
	comment := strings.TrimSpace(in.Comment)
	if in.Reason == "other" && comment == "" {
		return res, apperr.Validation("comment: напишите, что случилось").Uz("comment: nima boʻlganini yozing")
	}
	photos := []string{}
	for _, u := range in.Photos {
		if u = strings.TrimSpace(u); u != "" {
			photos = append(photos, u)
		}
	}
	if len(photos) == 0 {
		return res, apperr.Validation("photos: добавьте фото").Uz("photos: rasm qoʻshing")
	}
	items := []inventory.ItemInput{{ProductID: in.ProductID, Qty: in.Qty}}
	note := comment
	wh := st.WarehouseID
	doc, err := s.inv.Create(ctx, p, inventory.Input{Type: inventory.TypeWriteOff, WarehouseID: &wh, Reason: &reason,
		Note: &note, Items: &items, Photos: &photos})
	if err != nil {
		return res, err
	}
	if _, err := s.inv.Post(ctx, p, doc.ID); err != nil {
		_ = s.inv.Delete(context.WithoutCancel(ctx), p, doc.ID)
		return res, err
	}
	res.Document = DocRef{ID: doc.ID, Number: doc.Number}
	res.Glance, err = s.Glance(ctx, p, GlanceInput{StoreID: st.ID, ProductID: in.ProductID})
	return res, err
}

// ------------------------------------------------------------ мой день (С13)

type Day struct {
	// Продажи сотрудника сегодня: сумма, чеков, средний чек.
	Sales    string `json:"sales"`
	Receipts int    `json:"receipts"`
	Average  string `json:"average"`
	// Собрано заказов, списаний, пересчитано товаров сегодня.
	OrdersPicked int `json:"orders_picked"`
	WriteOffs    int `json:"write_offs"`
	Counted      int `json:"counted"`
}

func (s *Service) Day(ctx context.Context, p *identity.Principal, storeID string) (Day, error) {
	var d Day
	if err := requireStaff(p); err != nil {
		return d, err
	}
	st, err := s.store(ctx, p, storeID)
	if err != nil {
		return d, err
	}
	from := dayStart(s.now())
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE((SELECT sum(total) FROM sales WHERE cashier_id = $1 AND store_id = $2 AND sold_at >= $3), 0)::numeric(18,2)::text,
		       (SELECT count(*) FROM sales WHERE cashier_id = $1 AND store_id = $2 AND sold_at >= $3)::int,
		       (SELECT count(*) FROM orders WHERE picker_id = $1 AND store_id = $2 AND picked_at >= $3)::int,
		       (SELECT count(*) FROM stock_documents d JOIN warehouses w ON w.id = d.warehouse_id
		         WHERE d.created_by = $1 AND w.store_id = $2 AND d.type = 'write_off' AND d.status = 'posted' AND d.posted_at >= $3)::int,
		       (SELECT count(*) FROM stock_document_items i JOIN stock_documents d ON d.id = i.document_id JOIN warehouses w ON w.id = d.warehouse_id
		         WHERE d.created_by = $1 AND w.store_id = $2 AND d.type = 'inventory' AND d.status = 'posted' AND d.posted_at >= $3)::int`,
		p.EmployeeID, st.ID, from).Scan(&d.Sales, &d.Receipts, &d.OrdersPicked, &d.WriteOffs, &d.Counted)
	if err != nil {
		return d, err
	}
	d.Average = "0.00"
	if d.Receipts > 0 {
		d.Average = money.D(d.Sales).Div(money.D(strconv.Itoa(d.Receipts))).Money()
	}
	return d, nil
}
