package supply

import (
	"context"
	"math"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Главная агента с дашбордом (Figma «Правки 16 окт» → А1): отгружено за
// период с прошлым периодом, расходов, магазинов, средний расход, долги,
// топ магазинов и товаров. Отгрузка — проведённые расходы магазинам.

var tashkent = time.FixedZone("Asia/Tashkent", 5*3600)

// overdueDays — «давно не платят»: долг есть, а оплат не было дольше.
const overdueDays = 14

// DashPoint — столбик графика: час (сегодня) или день.
type DashPoint struct {
	At      time.Time `json:"at"`
	Shipped string    `json:"shipped"`
	Prev    string    `json:"prev"`
}

type DashStore struct {
	StoreID string `json:"store_id"`
	Name    string `json:"name"`
	Sum     string `json:"sum"`
}

type DashProduct struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Image     string `json:"image"`
	Unit      string `json:"unit"`
	Qty       string `json:"qty"`
	Sum       string `json:"sum"`
}

type Dashboard struct {
	Period    string    `json:"period"`
	From      time.Time `json:"from"`
	To        time.Time `json:"to"`
	Bucket    string    `json:"bucket"` // hour | day
	Shipped   string    `json:"shipped"`
	Prev      string    `json:"prev"`
	ChangePct *float64  `json:"change_pct"` // nil — в прошлом периоде отгрузок не было
	Shipments int       `json:"shipments"`
	// Расходов сегодня — подпись под «Расходов».
	ShipmentsToday int    `json:"shipments_today"`
	Stores         int    `json:"stores"`        // скольким магазинам отгружали
	LinkedStores   int    `json:"linked_stores"` // подключено всего
	AvgShipment    string `json:"avg_shipment"`
	// Долги магазинов (как «Вам должны»).
	OwedTotal     string        `json:"owed_total"`
	OwedStores    int           `json:"owed_stores"`
	OverdueStores int           `json:"overdue_stores"`
	Points        []DashPoint   `json:"points"`
	TopStores     []DashStore   `json:"top_stores"`
	TopProducts   []DashProduct `json:"top_products"`
}

// dashRange — границы периода по Ташкенту: today (по часам), week (7 дней), month (30 дней).
func dashRange(period string, now time.Time) (from, to time.Time, prevFrom time.Time, bucket string, n int, err error) {
	now = now.In(tashkent)
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
	to = day.AddDate(0, 0, 1)
	switch period {
	case "today":
		return day, to, day.AddDate(0, 0, -1), "hour", 24, nil
	case "", "week":
		return day.AddDate(0, 0, -6), to, day.AddDate(0, 0, -13), "day", 7, nil
	case "month":
		return day.AddDate(0, 0, -29), to, day.AddDate(0, 0, -59), "day", 30, nil
	}
	return time.Time{}, time.Time{}, time.Time{}, "", 0, apperr.Validation("period: today, week или month").Uz("period: today, week yoki month")
}

// AgentDashboard — данные главной агента за период.
func (s *Service) AgentDashboard(ctx context.Context, p *identity.Principal, period string) (Dashboard, error) {
	if err := requireDistributor(p); err != nil {
		return Dashboard{}, err
	}
	if period == "" {
		period = "week"
	}
	from, to, prevFrom, bucket, n, err := dashRange(period, time.Now())
	if err != nil {
		return Dashboard{}, err
	}
	d := Dashboard{Period: period, From: from, To: to, Bucket: bucket, Points: []DashPoint{}, TopStores: []DashStore{}, TopProducts: []DashProduct{}}
	if d.OwedTotal, d.OwedStores, _, _, err = agentMoney(ctx, s.pool, p.NetworkID); err != nil {
		return d, err
	}
	step := "1 day"
	if bucket == "hour" {
		step = "1 hour"
	}
	// Итоги и график: текущий период [from, to) и прошлый той же длины.
	span := to.Sub(from)
	rows, err := s.pool.Query(ctx, `
		WITH docs AS (
			SELECT posted_at, total, to_store_id FROM stock_documents
			WHERE network_id = $1 AND type = 'shipment' AND status = 'posted' AND posted_at >= $3 AND posted_at < $2
		), g AS (
			SELECT generate_series($4::timestamptz, $2::timestamptz - $5::interval, $5::interval) AS at
		)
		SELECT g.at,
		       COALESCE((SELECT sum(total) FROM docs WHERE posted_at >= g.at AND posted_at < g.at + $5::interval), 0)::numeric(18,2)::text,
		       COALESCE((SELECT sum(total) FROM docs WHERE posted_at >= g.at - make_interval(secs => $6) AND posted_at < g.at - make_interval(secs => $6) + $5::interval), 0)::numeric(18,2)::text
		FROM g ORDER BY g.at`, p.NetworkID, to, prevFrom, from, step, span.Seconds())
	if err != nil {
		return d, err
	}
	d.Points, err = pgx.CollectRows(rows, pgx.RowToStructByPos[DashPoint])
	if err != nil {
		return d, err
	}
	if len(d.Points) != n {
		d.Points = d.Points[:min(len(d.Points), n)]
	}
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(total) FILTER (WHERE posted_at >= $2), 0)::numeric(18,2)::text,
		       COALESCE(sum(total) FILTER (WHERE posted_at < $2), 0)::numeric(18,2)::text,
		       count(*) FILTER (WHERE posted_at >= $2)::int,
		       count(*) FILTER (WHERE posted_at >= $5)::int,
		       count(DISTINCT to_store_id) FILTER (WHERE posted_at >= $2)::int,
		       (SELECT count(*)::int FROM supply_links WHERE distributor_id = $1 AND status = 'active'),
		       (SELECT count(*)::int FROM (
		           SELECT c.id FROM counterparties c
		           LEFT JOIN counterparty_entries e ON e.counterparty_id = c.id
		           WHERE c.network_id = $1 AND c.store_id IS NOT NULL
		           GROUP BY c.id
		           HAVING -COALESCE(sum(e.amount), 0) > 0
		              AND COALESCE(max(e.created_at) FILTER (WHERE e.amount > 0), min(e.created_at)) < now() - make_interval(days => $6)) o)
		FROM stock_documents
		WHERE network_id = $1 AND type = 'shipment' AND status = 'posted' AND posted_at >= $3 AND posted_at < $4`,
		p.NetworkID, from, prevFrom, to, to.AddDate(0, 0, -1), overdueDays).
		Scan(&d.Shipped, &d.Prev, &d.Shipments, &d.ShipmentsToday, &d.Stores, &d.LinkedStores, &d.OverdueStores)
	if err != nil {
		return d, err
	}
	cur, prev := money.D(d.Shipped), money.D(d.Prev)
	if prev.Sign() > 0 {
		r, _ := cur.Div(prev).Float64()
		pct := math.Round((r-1)*1000) / 10
		d.ChangePct = &pct
	}
	d.AvgShipment = cur.Div(money.D(strconv.Itoa(d.Shipments))).Money()
	rows, err = s.pool.Query(ctx, `
		SELECT d.to_store_id::text, s.name, sum(d.total)::numeric(18,2)::text
		FROM stock_documents d JOIN stores s ON s.id = d.to_store_id
		WHERE d.network_id = $1 AND d.type = 'shipment' AND d.status = 'posted' AND d.posted_at >= $2 AND d.posted_at < $3
		GROUP BY 1, 2 ORDER BY sum(d.total) DESC, 2 LIMIT 5`, p.NetworkID, from, to)
	if d.TopStores, err = collect[DashStore](rows, err); err != nil {
		return d, err
	}
	rows, err = s.pool.Query(ctx, `
		SELECT p.id::text, loc(p.name, p.name_uz), COALESCE(p.images[1], ''), loc(u.short_name, u.short_name_uz),
		       sum(i.qty)::text, sum(i.qty * COALESCE(i.price, 0))::numeric(18,2)::text
		FROM stock_documents d
		JOIN stock_document_items i ON i.document_id = d.id
		JOIN products p ON p.id = i.product_id
		JOIN units u    ON u.id = p.unit_id
		WHERE d.network_id = $1 AND d.type = 'shipment' AND d.status = 'posted' AND d.posted_at >= $2 AND d.posted_at < $3
		GROUP BY p.id, u.id ORDER BY 6 DESC, 2 LIMIT 5`, p.NetworkID, from, to)
	d.TopProducts, err = collect[DashProduct](rows, err)
	return d, err
}
