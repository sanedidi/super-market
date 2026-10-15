package supply

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// Supplier — дистрибьютор глазами магазина.
type Supplier struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Phone       string   `json:"phone"`
	Address     string   `json:"address"`
	SupplyTerms string   `json:"supply_terms"`
	LeadDays    int      `json:"lead_days"`
	DistanceKm  *float64 `json:"distance_km"`
	// Связь с этим магазином: none, requested, active, rejected, disconnected.
	LinkStatus  string `json:"link_status"`
	LinkID      string `json:"link_id"`
	RequestedBy string `json:"requested_by"`
	Message     string `json:"message"`
	WaitsForMe  bool   `json:"waits_for_me"`
	// Сколько товаров в прайсе; для поиска — сколько из них подходят и примеры.
	ProductsCount int      `json:"products_count"`
	Matched       int      `json:"matched"`
	Examples      []string `json:"examples"`
	OpenOrders    int      `json:"open_orders"`
	// Бренды агента.
	Brands []string `json:"brands"`
	// Долг поставщику (плюс — мы должны) и оплаты, которые ждут его ответа
	// (disputed — агент получил другую сумму).
	Debt             string `json:"debt"`
	PendingPayments  int    `json:"pending_payments"`
	DisputedPayments int    `json:"disputed_payments"`
}

func (s *Service) suppliers(ctx context.Context, storeID, where, query string, extra []any, page httpx.Page) ([]Supplier, error) {
	args := append([]any{storeID, page.Limit, page.Offset}, extra...)
	matchExpr := "0"
	examples := "'{}'::text[]"
	if strings.TrimSpace(query) != "" {
		search := productsearch.Filter("p", query, &args)
		matchExpr = `(SELECT count(*)::int FROM store_products sp JOIN products p ON p.id = sp.product_id
			WHERE sp.store_id = pt.id AND p.network_id IS NULL AND ` + search + `)`
		examples = `ARRAY(SELECT loc(p.name, p.name_uz) FROM store_products sp JOIN products p ON p.id = sp.product_id
			WHERE sp.store_id = pt.id AND p.network_id IS NULL AND ` + search + ` ORDER BY 1 LIMIT 3)`
	}
	rows, err := s.pool.Query(ctx, fmt.Sprintf(`
		WITH me AS (SELECT location FROM stores WHERE id = $1),
		d AS (
			SELECT n.id, n.name, COALESCE(pt.phone, '') AS phone, COALESCE(pt.address, '') AS address, n.supply_terms, n.lead_days,
			       CASE WHEN pt.location IS NOT NULL AND me.location IS NOT NULL
			            THEN round((ST_Distance(pt.location, me.location) / 1000)::numeric, 1)::float8 END AS km,
			       COALESCE(l.status, 'none') AS link_status, COALESCE(l.id::text, '') AS link_id,
			       COALESCE(l.requested_by, '') AS requested_by, COALESCE(l.message, '') AS message,
			       (SELECT count(*)::int FROM store_products sp JOIN products p ON p.id = sp.product_id
			        WHERE sp.store_id = pt.id AND p.network_id IS NULL) AS products,
			       %s AS matched, %s AS examples,
			       (SELECT count(*)::int FROM supply_orders o WHERE o.store_id = $1 AND o.network_id = n.id
			        AND o.status IN ('new', 'accepted', 'assembled')) AS open_orders,
			       ARRAY(SELECT b.name FROM distributor_brands db JOIN brands b ON b.id = db.brand_id
			             WHERE db.network_id = n.id ORDER BY b.name) AS brands,
			       COALESCE((SELECT sum(e.amount) FROM counterparties c JOIN counterparty_entries e ON e.counterparty_id = c.id
			                 WHERE c.distributor_id = n.id AND c.network_id = (SELECT network_id FROM stores WHERE id = $1)), 0)::numeric(18,2)::text AS debt,
			       (SELECT count(*)::int FROM supply_payments sp WHERE sp.distributor_id = n.id AND sp.store_id = $1 AND sp.status = 'pending') AS pending_payments,
			       (SELECT count(*)::int FROM supply_payments sp WHERE sp.distributor_id = n.id AND sp.store_id = $1 AND sp.status = 'disputed') AS disputed_payments,
			       pt.location
			FROM networks n
			JOIN LATERAL (SELECT * FROM stores x WHERE x.network_id = n.id AND x.status = 'active' ORDER BY x.created_at LIMIT 1) pt ON true
			CROSS JOIN me
			LEFT JOIN supply_links l ON l.distributor_id = n.id AND l.store_id = $1
			WHERE n.kind = 'distributor' AND n.status = 'active'
			  AND (NOT n.self_registered OR EXISTS (SELECT 1 FROM distributor_brands db WHERE db.network_id = n.id))
		)
		SELECT id, name, phone, address, supply_terms, lead_days, km, link_status, link_id, requested_by, message,
		       products, matched, examples, open_orders, brands, debt, pending_payments, disputed_payments
		FROM d WHERE %s
		ORDER BY (link_status = 'active') DESC, matched DESC, km NULLS LAST, name
		LIMIT $2 OFFSET $3`, matchExpr, examples, where), productsearch.Args(args)...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Supplier, error) {
		var x Supplier
		err := row.Scan(&x.ID, &x.Name, &x.Phone, &x.Address, &x.SupplyTerms, &x.LeadDays, &x.DistanceKm, &x.LinkStatus, &x.LinkID,
			&x.RequestedBy, &x.Message, &x.ProductsCount, &x.Matched, &x.Examples, &x.OpenOrders,
			&x.Brands, &x.Debt, &x.PendingPayments, &x.DisputedPayments)
		x.WaitsForMe = x.LinkStatus == LinkRequested && x.RequestedBy != SideStore
		if x.LinkStatus != LinkActive {
			x.Phone = "" // телефон — после подключения
		}
		return x, err
	})
}

// Suppliers — подключённые поставщики магазина и запросы (Поставщики).
func (s *Service) Suppliers(ctx context.Context, p *identity.Principal, storeID string) ([]Supplier, error) {
	if err := requireStoreSide(p); err != nil {
		return nil, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return nil, err
	}
	if err := storeOfNetwork(ctx, s.pool, p, storeID); err != nil {
		return nil, err
	}
	return s.suppliers(ctx, storeID, `link_status IN ('active', 'requested')`, "", nil, httpx.Page{Limit: 200})
}

// SearchSuppliers — «Найти поставщика»: кто возит товар q рядом с магазином.
// Без q — все дистрибьюторы рядом.
func (s *Service) SearchSuppliers(ctx context.Context, p *identity.Principal, storeID, q string, page httpx.Page) ([]Supplier, error) {
	if err := requireStoreSide(p); err != nil {
		return nil, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return nil, err
	}
	if err := storeOfNetwork(ctx, s.pool, p, storeID); err != nil {
		return nil, err
	}
	where := fmt.Sprintf(`products > 0 AND (location IS NULL OR km IS NULL OR km * 1000 <= %d)`, searchRadiusM)
	if strings.TrimSpace(q) != "" {
		where += ` AND matched > 0`
	}
	return s.suppliers(ctx, storeID, where, q, nil, page)
}

// SupplierDetail — карточка поставщика для магазина.
func (s *Service) SupplierDetail(ctx context.Context, p *identity.Principal, storeID, distributorID string) (Supplier, error) {
	if err := requireStoreSide(p); err != nil {
		return Supplier{}, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Supplier{}, err
	}
	if err := storeOfNetwork(ctx, s.pool, p, storeID); err != nil {
		return Supplier{}, err
	}
	if err := checkDistributor(ctx, s.pool, distributorID); err != nil {
		return Supplier{}, err
	}
	out, err := s.suppliers(ctx, storeID, `id = $4`, "", []any{distributorID}, httpx.Page{Limit: 1})
	if err != nil {
		return Supplier{}, err
	}
	if len(out) == 0 {
		return Supplier{}, apperr.NotFound("дистрибьютор не найден").Uz("distribyutor topilmadi")
	}
	return out[0], nil
}

// PriceItem — строка прайса дистрибьютора для магазина.
type PriceItem struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Image     string `json:"image"`
	Unit      string `json:"unit"`
	Price     string `json:"price"`
	// Есть ли у дистрибьютора на складе (без количества).
	Available bool `json:"available"`
	// У магазина: остаток, продажи в день, статус и сколько заказать.
	MyQty     string `json:"my_qty"`
	PerDay    string `json:"per_day"`
	Status    string `json:"status"`
	Recommend string `json:"recommend"`
	// Товар уже есть в ассортименте магазина.
	Carried bool `json:"carried"`
}

// Catalog — прайс подключённого дистрибьютора: сначала то, что пора заказать.
func (s *Service) Catalog(ctx context.Context, p *identity.Principal, storeID, distributorID, q string, page httpx.Page) ([]PriceItem, error) {
	if err := requireStoreSide(p); err != nil {
		return nil, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return nil, err
	}
	if err := storeOfNetwork(ctx, s.pool, p, storeID); err != nil {
		return nil, err
	}
	if err := checkDistributor(ctx, s.pool, distributorID); err != nil {
		return nil, err
	}
	if _, err := activeLink(ctx, s.pool, storeID, distributorID); err != nil {
		return nil, err
	}
	pt, err := distPoint(ctx, s.pool, distributorID)
	if err != nil {
		return nil, err
	}
	args := []any{storeID, pt.StoreID, pt.PriceTypeID, pt.LeadDays, page.Limit, page.Offset}
	search := productsearch.Filter("p", q, &args)
	rows, err := s.pool.Query(ctx, fmt.Sprintf(`
		SELECT y.id, y.name, y.image, y.unit, y.price::text, y.available, y.qty::text, round(y.per_day, 1)::text,
		       CASE WHEN y.carried THEN %s ELSE '' END, CASE WHEN y.carried THEN (%s)::text ELSE '' END, y.carried
		FROM (
			SELECT p.id, loc(p.name, p.name_uz) AS name, COALESCE(p.images[1], '') AS image, loc(u.short_name, u.short_name_uz) AS unit,
			       %s AS price, %s > 0 AS available, %s AS qty, %s AS per_day,
			       EXISTS (SELECT 1 FROM store_products my WHERE my.store_id = $1 AND my.product_id = p.id) AS carried
			FROM store_products sp
			JOIN products p ON p.id = sp.product_id AND p.network_id IS NULL AND p.is_active
			JOIN units u    ON u.id = p.unit_id
			WHERE sp.store_id = $2 AND %s
		) y
		WHERE y.price IS NOT NULL
		ORDER BY y.carried DESC, CASE WHEN y.carried THEN CASE %[1]s WHEN 'out' THEN 0 WHEN 'low' THEN 1 ELSE 2 END ELSE 3 END, y.name
		LIMIT $5 OFFSET $6`,
		statusSQL("y.qty", "y.per_day", "$4"), recommendSQL("y.qty", "y.per_day", "$4"),
		priceSQL("p", "$3", "$2"), stockSQL("$2", "p.id"), stockSQL("$1", "p.id"), perDaySQL("$1", "p.id"), search),
		productsearch.Args(args)...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[PriceItem])
}

// ReorderGroup — «Что заказать» по одному поставщику.
type ReorderGroup struct {
	DistributorID *string       `json:"distributor_id"` // nil — товары без подключённого поставщика
	Distributor   string        `json:"distributor_name"`
	Items         []ReorderItem `json:"items"`
	Total         string        `json:"total"`
}

// ReorderItem — товар, который пора заказать.
type ReorderItem struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Image     string  `json:"image"`
	Unit      string  `json:"unit"`
	Qty       string  `json:"qty"`
	PerDay    string  `json:"per_day"`
	Status    string  `json:"status"`
	Recommend string  `json:"recommend"`
	Price     *string `json:"price"`
}

// Reorder — что заказать: закончилось или не хватит до поставки, по
// поставщикам. Поставщик товара — подключённый дистрибьютор, у которого
// товар есть в прайсе (первый по времени подключения).
func (s *Service) Reorder(ctx context.Context, p *identity.Principal, storeID string) ([]ReorderGroup, error) {
	if err := requireStoreSide(p); err != nil {
		return nil, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return nil, err
	}
	if err := storeOfNetwork(ctx, s.pool, p, storeID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, fmt.Sprintf(`
		WITH dist AS (
			SELECT l.distributor_id, n.name, n.lead_days, l.accepted_at, pt.id AS point, ptp.id AS price_type
			FROM supply_links l
			JOIN networks n     ON n.id = l.distributor_id AND n.status = 'active'
			JOIN LATERAL (SELECT x.id FROM stores x WHERE x.network_id = n.id AND x.status = 'active' ORDER BY x.created_at LIMIT 1) pt ON true
			JOIN price_types ptp ON ptp.network_id = n.id AND ptp.is_default
			WHERE l.store_id = $1 AND l.status = 'active'
		),
		lines AS (
			SELECT p.id, loc(p.name, p.name_uz) AS name, COALESCE(p.images[1], '') AS image, loc(u.short_name, u.short_name_uz) AS unit,
			       %s AS qty, %s AS per_day, sup.distributor_id, sup.name AS dist_name, COALESCE(sup.lead_days, 2) AS lead, sup.price
			FROM store_products sp
			JOIN products p ON p.id = sp.product_id AND p.is_active
			JOIN units u    ON u.id = p.unit_id
			LEFT JOIN LATERAL (
				SELECT d.distributor_id, d.name, d.lead_days, %s AS price
				FROM dist d
				WHERE EXISTS (SELECT 1 FROM store_products ds WHERE ds.store_id = d.point AND ds.product_id = p.id)
				  AND %[3]s IS NOT NULL
				ORDER BY d.accepted_at LIMIT 1
			) sup ON true
			WHERE sp.store_id = $1
		)
		SELECT id, name, image, unit, qty::text, round(per_day, 1)::text, %s, (%s)::text, price::text, distributor_id, dist_name
		FROM lines
		WHERE %[4]s <> 'ok' AND (per_day > 0 OR distributor_id IS NOT NULL)
		ORDER BY dist_name NULLS LAST, CASE %[4]s WHEN 'out' THEN 0 ELSE 1 END, per_day DESC, name
		LIMIT 500`,
		stockSQL("$1", "p.id"), perDaySQL("$1", "p.id"), priceSQL("p", "d.price_type", "d.point"),
		statusSQL("qty", "per_day", "lead"), recommendSQL("qty", "per_day", "lead")), storeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReorderGroup{}
	index := map[string]int{}
	for rows.Next() {
		var it ReorderItem
		var distID, distName *string
		if err := rows.Scan(&it.ProductID, &it.Name, &it.Image, &it.Unit, &it.Qty, &it.PerDay, &it.Status, &it.Recommend, &it.Price,
			&distID, &distName); err != nil {
			return nil, err
		}
		key := ""
		if distID != nil {
			key = *distID
		}
		i, ok := index[key]
		if !ok {
			g := ReorderGroup{DistributorID: distID, Items: []ReorderItem{}, Total: "0"}
			if distName != nil {
				g.Distributor = *distName
			}
			out = append(out, g)
			i = len(out) - 1
			index[key] = i
		}
		out[i].Items = append(out[i].Items, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Сумма по группе — рекомендация × отпускная цена.
	for i := range out {
		total := "0"
		for _, it := range out[i].Items {
			if it.Price == nil {
				continue
			}
			if err := s.pool.QueryRow(ctx, `SELECT round($1::numeric + $2::numeric * $3::numeric, 2)::text`, total, it.Recommend, *it.Price).
				Scan(&total); err != nil {
				return nil, err
			}
		}
		out[i].Total = total
	}
	return out, nil
}
