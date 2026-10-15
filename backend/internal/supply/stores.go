package supply

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// StoreCard — магазин на карте и в списке дистрибьютора (Д2).
type StoreCard struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Address    string   `json:"address"`
	Lat        *float64 `json:"lat"`
	Lng        *float64 `json:"lng"`
	DistanceKm *float64 `json:"distance_km"`
	// Связь: none, requested (requested_by — кто просил), active, rejected, disconnected.
	LinkStatus  string `json:"link_status"`
	RequestedBy string `json:"requested_by"`
	LinkID      string `json:"link_id"`
	// out, low, ok, no_brand — для подключённых; not_linked — остальным.
	Status string `json:"status"`
	// Только для подключённых: сколько наших товаров закончилось / мало / всего у магазина.
	OutCount     int        `json:"out_count"`
	LowCount     int        `json:"low_count"`
	CarriedCount int        `json:"carried_count"`
	LastOrderAt  *time.Time `json:"last_order_at"`
	// Отгружено магазину за 30 дней, сум.
	MonthSum string `json:"month_sum"`
}

// linesAggSQL — счётчики out/low/carried по нашим товарам в магазине s.id.
// $1 — дистрибьютор, $2 — его точка, $3 — срок поставки.
var linesAggSQL = fmt.Sprintf(`
	SELECT count(*) FILTER (WHERE x.st = 'out')::int AS out_n,
	       count(*) FILTER (WHERE x.st = 'low')::int AS low_n,
	       count(*)::int AS carried_n
	FROM (
		SELECT %s AS st
		FROM (
			SELECT %s AS qty, %s AS per_day
			FROM store_products sp
			WHERE sp.store_id = s.id AND sp.product_id IN (SELECT product_id FROM store_products WHERE store_id = $2)
		) y
	) x`,
	statusSQL("y.qty", "y.per_day", "$3"), stockSQL("s.id", "sp.product_id"), perDaySQL("s.id", "sp.product_id"))

// StoresFilter — фильтр списка магазинов дистрибьютора.
type StoresFilter struct {
	Status string // out, low, ok, no_brand, not_linked, linked, requests
	Query  string
	Page   httpx.Page
}

// Stores — подключённые магазины со статусами и неподключённые рядом (15 км).
func (s *Service) Stores(ctx context.Context, p *identity.Principal, f StoresFilter) ([]StoreCard, error) {
	if err := requireDistributor(p); err != nil {
		return nil, err
	}
	pt, err := distPoint(ctx, s.pool, p.NetworkID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		WITH me AS (SELECT location FROM stores WHERE id = $2),
		cards AS (
			SELECT s.id, s.name, s.address,
			       ST_Y(s.location::geometry) AS lat, ST_X(s.location::geometry) AS lng,
			       CASE WHEN s.location IS NOT NULL AND me.location IS NOT NULL
			            THEN round((ST_Distance(s.location, me.location) / 1000)::numeric, 1)::float8 END AS km,
			       COALESCE(l.status, 'none') AS link_status, COALESCE(l.requested_by, '') AS requested_by, COALESCE(l.id::text, '') AS link_id,
			       COALESCE(agg.out_n, 0) AS out_n, COALESCE(agg.low_n, 0) AS low_n, COALESCE(agg.carried_n, 0) AS carried_n,
			       (SELECT max(o.created_at) FROM supply_orders o WHERE o.store_id = s.id AND o.network_id = $1) AS last_order_at,
			       COALESCE((SELECT sum(d.total) FROM stock_documents d WHERE d.network_id = $1 AND d.type = 'shipment'
			                 AND d.to_store_id = s.id AND d.status = 'posted' AND d.posted_at > now() - interval '30 days'), 0)::numeric(18,2)::text AS month_sum
			FROM stores s
			JOIN networks n ON n.id = s.network_id AND n.kind <> 'distributor' AND n.status = 'active'
			CROSS JOIN me
			LEFT JOIN supply_links l ON l.store_id = s.id AND l.distributor_id = $1
			LEFT JOIN LATERAL (`+linesAggSQL+`) agg ON l.status = 'active'
			WHERE s.status = 'active'
			  AND (l.status IN ('active', 'requested')
			       OR (s.location IS NOT NULL AND me.location IS NOT NULL AND ST_DWithin(s.location, me.location, $4)))
			  AND ($5 = '' OR s.name ILIKE '%' || $5 || '%' OR s.address ILIKE '%' || $5 || '%')
		)
		SELECT id, name, address, lat, lng, km, link_status, requested_by, link_id,
		       CASE WHEN link_status <> 'active' THEN 'not_linked'
		            WHEN carried_n = 0 THEN 'no_brand'
		            WHEN out_n > 0 THEN 'out' WHEN low_n > 0 THEN 'low' ELSE 'ok' END AS status,
		       out_n, low_n, carried_n, last_order_at, month_sum
		FROM cards c
		WHERE $6 = '' OR ($6 = 'linked' AND link_status = 'active') OR ($6 = 'requests' AND link_status = 'requested')
		   OR $6 = CASE WHEN link_status <> 'active' THEN 'not_linked'
		                WHEN carried_n = 0 THEN 'no_brand'
		                WHEN out_n > 0 THEN 'out' WHEN low_n > 0 THEN 'low' ELSE 'ok' END
		ORDER BY (link_status = 'active') DESC, out_n DESC, low_n DESC, km NULLS LAST, name
		LIMIT $7 OFFSET $8`,
		p.NetworkID, pt.StoreID, pt.LeadDays, nearbyRadiusM, strings.TrimSpace(f.Query), f.Status, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (StoreCard, error) {
		var c StoreCard
		err := row.Scan(&c.ID, &c.Name, &c.Address, &c.Lat, &c.Lng, &c.DistanceKm, &c.LinkStatus, &c.RequestedBy, &c.LinkID,
			&c.Status, &c.OutCount, &c.LowCount, &c.CarriedCount, &c.LastOrderAt, &c.MonthSum)
		return c, err
	})
}

// Line — наш товар в магазине: остаток, продажи, рекомендация.
type Line struct {
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

// Missing — наш товар, которого нет на полке магазина.
type Missing struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Image     string  `json:"image"`
	Price     *string `json:"price"`
	// В скольких магазинах (из подключённых к нам) он продаётся.
	StoresCount int `json:"stores_count"`
}

// StoreDetail — экран магазина у дистрибьютора (Д3).
type StoreDetail struct {
	StoreCard
	Phone string `json:"phone"`
	// Только для подключённых.
	Lacking   []Line               `json:"lacking"`
	Lines     []Line               `json:"lines"`
	Missing   []Missing            `json:"missing"`
	Shipments []inventory.Document `json:"shipments"`
	Link      *Link                `json:"link"`
}

func (s *Service) storeLines(ctx context.Context, q db.Querier, pt point, storeID string) ([]Line, error) {
	rows, err := q.Query(ctx, fmt.Sprintf(`
		SELECT y.id, y.name, y.image, y.unit, y.qty::text, round(y.per_day, 1)::text,
		       %s, %s::text, y.price::text
		FROM (
			SELECT p.id, loc(p.name, p.name_uz) AS name, COALESCE(p.images[1], '') AS image, loc(u.short_name, u.short_name_uz) AS unit,
			       %s AS qty, %s AS per_day, %s AS price
			FROM store_products sp
			JOIN products p ON p.id = sp.product_id
			JOIN units u    ON u.id = p.unit_id
			WHERE sp.store_id = $1 AND sp.product_id IN (SELECT product_id FROM store_products WHERE store_id = $2)
		) y
		ORDER BY CASE %[1]s WHEN 'out' THEN 0 WHEN 'low' THEN 1 ELSE 2 END, y.per_day DESC, y.name`,
		statusSQL("y.qty", "y.per_day", "$3"), recommendSQL("y.qty", "y.per_day", "$3"),
		stockSQL("$1", "sp.product_id"), perDaySQL("$1", "sp.product_id"), priceSQL("p", "$4", "$2")),
		storeID, pt.StoreID, pt.LeadDays, pt.PriceTypeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Line])
}

// StoreDetail — магазин глазами дистрибьютора.
func (s *Service) StoreDetail(ctx context.Context, p *identity.Principal, storeID string) (StoreDetail, error) {
	if err := requireDistributor(p); err != nil {
		return StoreDetail{}, err
	}
	pt, err := distPoint(ctx, s.pool, p.NetworkID)
	if err != nil {
		return StoreDetail{}, err
	}
	if _, err := checkStore(ctx, s.pool, storeID); err != nil {
		return StoreDetail{}, err
	}
	var out StoreDetail
	var linkID *string
	err = s.pool.QueryRow(ctx, `
		SELECT s.id, s.name, s.address, s.phone, ST_Y(s.location::geometry), ST_X(s.location::geometry),
		       CASE WHEN s.location IS NOT NULL AND me.location IS NOT NULL
		            THEN round((ST_Distance(s.location, me.location) / 1000)::numeric, 1)::float8 END,
		       COALESCE(l.status, 'none'), COALESCE(l.requested_by, ''), l.id::text,
		       (SELECT max(o.created_at) FROM supply_orders o WHERE o.store_id = s.id AND o.network_id = $1),
		       COALESCE((SELECT sum(d.total) FROM stock_documents d WHERE d.network_id = $1 AND d.type = 'shipment'
		                 AND d.to_store_id = s.id AND d.status = 'posted' AND d.posted_at > now() - interval '30 days'), 0)::numeric(18,2)::text
		FROM stores s
		CROSS JOIN (SELECT location FROM stores WHERE id = $2) me
		LEFT JOIN supply_links l ON l.store_id = s.id AND l.distributor_id = $1
		WHERE s.id = $3`, p.NetworkID, pt.StoreID, storeID).
		Scan(&out.ID, &out.Name, &out.Address, &out.Phone, &out.Lat, &out.Lng, &out.DistanceKm,
			&out.LinkStatus, &out.RequestedBy, &linkID, &out.LastOrderAt, &out.MonthSum)
	if err != nil {
		return StoreDetail{}, err
	}
	out.Lacking, out.Lines, out.Missing, out.Shipments = []Line{}, []Line{}, []Missing{}, []inventory.Document{}
	if linkID != nil {
		out.LinkID = *linkID
		l, err := getLink(ctx, s.pool, SideDistributor, *linkID)
		if err != nil {
			return StoreDetail{}, err
		}
		out.Link = &l
	}
	if out.LinkStatus != LinkActive {
		// Неподключённому — только название, адрес и расстояние; телефон — после подключения.
		out.Status, out.Phone = StatusNotLinked, ""
		return out, nil
	}
	lines, err := s.storeLines(ctx, s.pool, pt, storeID)
	if err != nil {
		return StoreDetail{}, err
	}
	out.Lines = lines
	for _, l := range lines {
		switch l.Status {
		case StatusOut:
			out.OutCount++
			out.Lacking = append(out.Lacking, l)
		case StatusLow:
			out.LowCount++
			out.Lacking = append(out.Lacking, l)
		}
	}
	out.CarriedCount = len(lines)
	switch {
	case out.CarriedCount == 0:
		out.Status = StatusNoBrand
	case out.OutCount > 0:
		out.Status = StatusOut
	case out.LowCount > 0:
		out.Status = StatusLow
	default:
		out.Status = StatusOK
	}

	// Нет на полке: наши товары с ценой, которых у магазина нет, — сначала те,
	// что продают больше подключённых к нам магазинов.
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), COALESCE(p.images[1], ''), `+priceSQL("p", "$3", "$2")+`::text,
		       (SELECT count(*)::int FROM store_products o JOIN supply_links ol ON ol.store_id = o.store_id
		        WHERE o.product_id = p.id AND ol.distributor_id = $4 AND ol.status = 'active') AS n
		FROM store_products mine
		JOIN products p ON p.id = mine.product_id AND p.network_id IS NULL AND p.is_active
		WHERE mine.store_id = $2
		  AND NOT EXISTS (SELECT 1 FROM store_products sp WHERE sp.store_id = $1 AND sp.product_id = p.id)
		  AND `+priceSQL("p", "$3", "$2")+` IS NOT NULL
		ORDER BY n DESC, 2 LIMIT 20`, storeID, pt.StoreID, pt.PriceTypeID, p.NetworkID)
	if err != nil {
		return StoreDetail{}, err
	}
	if out.Missing, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Missing]); err != nil {
		return StoreDetail{}, err
	}

	docs, err := s.inv.List(ctx, p, inventory.Filter{Type: inventory.TypeShipment, Page: httpx.Page{Limit: 200}})
	if err != nil {
		return StoreDetail{}, err
	}
	for _, d := range docs {
		if d.ToStoreID != nil && *d.ToStoreID == storeID {
			out.Shipments = append(out.Shipments, d)
			if len(out.Shipments) == 10 {
				break
			}
		}
	}
	return out, nil
}

// ShipmentForStore — «Сформировать расход»: черновик расхода по рекомендациям
// (Д3). Товары без отпускной цены и с нулевой рекомендацией пропускаются.
func (s *Service) ShipmentForStore(ctx context.Context, p *identity.Principal, storeID string) (inventory.Document, error) {
	if err := requireDistributor(p); err != nil {
		return inventory.Document{}, err
	}
	pt, err := distPoint(ctx, s.pool, p.NetworkID)
	if err != nil {
		return inventory.Document{}, err
	}
	if _, err := checkStore(ctx, s.pool, storeID); err != nil {
		return inventory.Document{}, err
	}
	if _, err := activeLink(ctx, s.pool, storeID, p.NetworkID); err != nil {
		return inventory.Document{}, err
	}
	lines, err := s.storeLines(ctx, s.pool, pt, storeID)
	if err != nil {
		return inventory.Document{}, err
	}
	items := []inventory.ItemInput{}
	for _, l := range lines {
		if l.Status == StatusOK || l.Price == nil || strings.Trim(l.Recommend, "0.") == "" {
			continue
		}
		price := money.Price(*l.Price)
		items = append(items, inventory.ItemInput{ProductID: l.ProductID, Qty: money.Qty(l.Recommend), Price: &price})
	}
	if len(items) == 0 {
		return inventory.Document{}, apperr.Conflict("nothing_to_ship", "магазину сейчас всего хватает").Uz("doʻkonda hozir hamma narsa yetarli")
	}
	wh := pt.WarehouseID
	return s.inv.Create(ctx, p, inventory.Input{Type: inventory.TypeShipment, WarehouseID: &wh, ToStoreID: &storeID, Items: &items})
}

// Summary — главная дистрибьютора (Д1).
type Summary struct {
	NewOrders     int `json:"new_orders"`
	Requests      int `json:"requests"`
	LinkedStores  int `json:"linked_stores"`
	OutStores     int `json:"out_stores"`
	LowStores     int `json:"low_stores"`
	NoBrandStores int `json:"no_brand_stores"`
	// Магазины, которым больше всего не хватает (до 3).
	Top []StoreCard `json:"top"`
	// Сегодня: отгружено (сумма проведённых расходов), документы.
	ShippedToday     string `json:"shipped_today"`
	ShipmentsToday   int    `json:"shipments_today"`
	InTransit        int    `json:"in_transit"`
	IncomesToday     int    `json:"incomes_today"`
	IncomesTodaySum  string `json:"incomes_today_sum"`
	ShippedYesterday string `json:"shipped_yesterday"`
	// Магазины открыты (у сам зарегистрированного агента есть бренд).
	Verified bool `json:"verified"`
	// «Вам должны»: долг магазинов агенту и сколько магазинов должны.
	OwedTotal  string `json:"owed_total"`
	OwedStores int    `json:"owed_stores"`
	// Оплаты, которые магазины отдали и ждут подтверждения агента.
	PendingPayments    int    `json:"pending_payments"`
	PendingPaymentsSum string `json:"pending_payments_sum"`
}

// Summary — счётчики главной.
func (s *Service) Summary(ctx context.Context, p *identity.Principal) (Summary, error) {
	if err := requireDistributor(p); err != nil {
		return Summary{}, err
	}
	var out Summary
	out.Top = []StoreCard{}
	var err error
	if out.Verified, err = verified(ctx, s.pool, p.NetworkID); err != nil {
		return out, err
	}
	if out.OwedTotal, out.OwedStores, out.PendingPayments, out.PendingPaymentsSum, err = agentMoney(ctx, s.pool, p.NetworkID); err != nil {
		return out, err
	}
	out.ShippedToday, out.IncomesTodaySum, out.ShippedYesterday = "0.00", "0.00", "0.00"
	if !out.Verified {
		return out, nil
	}
	cards, err := s.Stores(ctx, p, StoresFilter{Status: "linked", Page: httpx.Page{Limit: 1000}})
	if err != nil {
		return Summary{}, err
	}
	for _, c := range cards {
		out.LinkedStores++
		switch c.Status {
		case StatusOut:
			out.OutStores++
		case StatusLow:
			out.LowStores++
		case StatusNoBrand:
			out.NoBrandStores++
		}
		if (c.Status == StatusOut || c.Status == StatusLow) && len(out.Top) < 3 {
			out.Top = append(out.Top, c)
		}
	}
	err = s.pool.QueryRow(ctx, `
		SELECT (SELECT count(*)::int FROM supply_orders WHERE network_id = $1 AND status = 'new'),
		       (SELECT count(*)::int FROM supply_links WHERE distributor_id = $1 AND status = 'requested' AND requested_by = 'store'),
		       COALESCE(sum(total) FILTER (WHERE type = 'shipment' AND posted_at >= date_trunc('day', now())), 0)::numeric(18,2)::text,
		       count(*) FILTER (WHERE type = 'shipment' AND posted_at >= date_trunc('day', now()))::int,
		       (SELECT count(*)::int FROM supply_orders WHERE network_id = $1 AND status = 'assembled'),
		       count(*) FILTER (WHERE type = 'income' AND posted_at >= date_trunc('day', now()))::int,
		       COALESCE(sum(total) FILTER (WHERE type = 'income' AND posted_at >= date_trunc('day', now())), 0)::numeric(18,2)::text,
		       COALESCE(sum(total) FILTER (WHERE type = 'shipment' AND posted_at >= date_trunc('day', now()) - interval '1 day'
		                                  AND posted_at < date_trunc('day', now())), 0)::numeric(18,2)::text
		FROM stock_documents
		WHERE network_id = $1 AND status = 'posted' AND posted_at >= date_trunc('day', now()) - interval '1 day'`, p.NetworkID).
		Scan(&out.NewOrders, &out.Requests, &out.ShippedToday, &out.ShipmentsToday, &out.InTransit,
			&out.IncomesToday, &out.IncomesTodaySum, &out.ShippedYesterday)
	return out, err
}

// Settings — условия дистрибьютора, которые видят магазины.
type Settings struct {
	SupplyTerms string `json:"supply_terms"`
	LeadDays    int    `json:"lead_days"`
}

func (s *Service) GetSettings(ctx context.Context, p *identity.Principal) (Settings, error) {
	if err := requireDistributor(p); err != nil {
		return Settings{}, err
	}
	var out Settings
	err := s.pool.QueryRow(ctx, `SELECT supply_terms, lead_days FROM networks WHERE id = $1`, p.NetworkID).Scan(&out.SupplyTerms, &out.LeadDays)
	return out, err
}

type SettingsInput struct {
	SupplyTerms *string `json:"supply_terms"`
	LeadDays    *int    `json:"lead_days"`
}

func (s *Service) UpdateSettings(ctx context.Context, p *identity.Principal, in SettingsInput) (Settings, error) {
	if err := requireDistributor(p); err != nil {
		return Settings{}, err
	}
	if !p.IsOwner {
		return Settings{}, apperr.Forbidden("условия меняет владелец").Uz("shartlarni egasi oʻzgartiradi")
	}
	if in.SupplyTerms != nil && len([]rune(strings.TrimSpace(*in.SupplyTerms))) > 500 {
		return Settings{}, apperr.Validation("supply_terms: не длиннее 500 символов").Uz("supply_terms: 500 belgidan oshmasin")
	}
	if in.LeadDays != nil && (*in.LeadDays < 1 || *in.LeadDays > 30) {
		return Settings{}, apperr.Validation("lead_days: от 1 до 30 дней").Uz("lead_days: 1 dan 30 kungacha")
	}
	_, err := s.pool.Exec(ctx, `
		UPDATE networks SET supply_terms = COALESCE(btrim($2), supply_terms), lead_days = COALESCE($3, lead_days) WHERE id = $1`,
		p.NetworkID, in.SupplyTerms, in.LeadDays)
	if err != nil {
		return Settings{}, err
	}
	return s.GetSettings(ctx, p)
}

// storeName — для текстов уведомлений.
func storeName(ctx context.Context, q db.Querier, id string) string {
	var n string
	if err := q.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, id).Scan(&n); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return ""
	}
	return n
}
