package reports

import (
	"context"
	"math"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// -------------------------------------------- продажи для главной панели
//
// Здесь только то, чего нет в «Прибыли и убытке» и ABC/XYZ: те же суммы,
// разложенные по времени (sales-series) и по разрезам (sales-breakdown).
// Источники общие с остальными отчётами:
//   - выручка и прибыль по документам — как в ProfitLoss (docsCTE);
//   - строки товаров — как в ABC/XYZ (salesLinesCTE).

// docsCTE — документы продаж в сумах ($1 — сеть, $2 — магазины или NULL,
// $3–$4 — период). Чеки POS — по дате продажи, возвраты — по дате возврата,
// онлайн-заказы — по дате доставки, с платой за доставку. Сумма revenue по
// периоду равна revenue.total в ProfitLoss, revenue − cost — gross_profit.
const docsCTE = `
	docs AS (
		SELECT sold_at AS at, 'pos' AS ch, total AS revenue, cost, 1 AS checks, 0 AS orders, total AS check_total
		FROM sales WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND sold_at >= $3 AND sold_at < $4
		UNION ALL
		SELECT created_at, 'pos', -total, -cost, 0, 0, 0
		FROM customer_returns WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND created_at >= $3 AND created_at < $4
		UNION ALL
		SELECT delivered_at, 'online', subtotal + delivery_fee, COALESCE(cost, 0), 0, 1, 0
		FROM orders WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND status = 'delivered'
		  AND delivered_at >= $3 AND delivered_at < $4
	)`

// salesLinesCTE — строки проданных товаров ($1–$4 как в docsCTE): чеки POS,
// доставленные онлайн-заказы и возвраты покупателей с минусом. Доставка не
// входит — это не товар. Общая основа ABC/XYZ и разреза по товарам и категориям.
const salesLinesCTE = `
	lines AS (
		SELECT si.product_id, s.sold_at AS at, si.qty, si.total AS revenue, si.cost
		FROM sale_items si JOIN sales s ON s.id = si.sale_id
		WHERE s.network_id = $1 AND ($2::uuid[] IS NULL OR s.store_id = ANY($2)) AND s.sold_at >= $3 AND s.sold_at < $4
		UNION ALL
		SELECT oi.product_id, o.delivered_at, oi.qty, oi.total, COALESCE(oi.cost, 0)
		FROM order_items oi JOIN orders o ON o.id = oi.order_id
		WHERE o.network_id = $1 AND ($2::uuid[] IS NULL OR o.store_id = ANY($2)) AND o.status = 'delivered'
		  AND o.delivered_at >= $3 AND o.delivered_at < $4
		UNION ALL
		SELECT si.product_id, r.created_at, -ri.qty, -ri.total, -ri.cost
		FROM customer_return_items ri
		JOIN customer_returns r ON r.id = ri.return_id
		JOIN sale_items si ON si.sale_id = r.sale_id AND si.line = ri.sale_line
		WHERE r.network_id = $1 AND ($2::uuid[] IS NULL OR r.store_id = ANY($2)) AND r.created_at >= $3 AND r.created_at < $4
	)`

const (
	seriesMaxHours  = 72  // по часам — не больше трёх суток
	seriesMaxDays   = 366 // по дням — не больше года
	heatmapDays     = 28  // «Когда покупают» по умолчанию — последние 4 недели
	breakdownLimit  = 8
	breakdownMaxLim = 50
)

// comparison — с чем сравнивать: prev — предыдущий такой же отрезок,
// week — тот же отрезок неделей раньше («сегодня» ↔ «прошлая среда»).
func comparison(v string, sc scope) (time.Duration, error) {
	switch v {
	case "":
		return 0, nil
	case "prev":
		return sc.to.Sub(sc.from), nil
	case "week":
		return week, nil
	}
	return 0, apperr.Validation("compare: prev или week").Uz("compare: prev yoki week")
}

// live — конец периода, но не позже текущего момента: «сегодня» сравнивается
// с прошлым периодом до того же часа, а не с целым днём.
func (s *Service) live(sc scope) time.Time {
	if now := s.now(); now.Before(sc.to) {
		return now
	}
	return sc.to
}

// ---------------------------------------------------------- sales-series

type SeriesFilter struct {
	Filter
	Bucket  string // hour, day, weekday_hour
	Compare string // "", prev, week
}

type SeriesPoint struct {
	At      time.Time `json:"at"`
	Revenue string    `json:"revenue"`
	POS     string    `json:"pos"`    // касса: чеки минус возвраты
	Online  string    `json:"online"` // доставленные онлайн-заказы с доставкой
	Profit  string    `json:"profit"` // валовая: выручка минус себестоимость
	Checks  int       `json:"checks"`
	Orders  int       `json:"orders"`
}

type SeriesTotals struct {
	Revenue   string   `json:"revenue"`
	POS       string   `json:"pos"`
	Online    string   `json:"online"`
	Profit    string   `json:"profit"`
	MarginPct *float64 `json:"margin_pct"`
	Checks    int      `json:"checks"`
	Orders    int      `json:"orders"`
	AvgCheck  string   `json:"avg_check"` // по чекам POS, как в «Итогах дня»
}

// HeatCell — в среднем за один такой день недели и час.
type HeatCell struct {
	Weekday int     `json:"weekday"` // 1 — понедельник … 7 — воскресенье
	Hour    int     `json:"hour"`
	Checks  float64 `json:"checks"`
	Revenue string  `json:"revenue"`
}

type SalesSeries struct {
	From   time.Time `json:"from"`
	To     time.Time `json:"to"`
	Bucket string    `json:"bucket"`
	// Points — до текущего момента; будущие часы сегодняшнего дня не приходят.
	Points []SeriesPoint `json:"points"`
	Totals SeriesTotals  `json:"totals"`

	Compare  string     `json:"compare,omitempty"`
	PrevFrom *time.Time `json:"prev_from,omitempty"`
	PrevTo   *time.Time `json:"prev_to,omitempty"`
	// Prev — прошлый отрезок целиком (чтобы линия на графике шла до конца),
	// PrevTotals — только до того же момента, что и текущий.
	Prev       []SeriesPoint `json:"prev,omitempty"`
	PrevTotals *SeriesTotals `json:"prev_totals,omitempty"`
	ChangePct  *float64      `json:"change_pct,omitempty"` // выручка к прошлому отрезку, %

	Heatmap []HeatCell `json:"heatmap,omitempty"`
}

type seriesRow struct {
	pos, online, profit, checkTotal money.Dec
	checks, orders                  int
}

func (r seriesRow) point(at time.Time) SeriesPoint {
	return SeriesPoint{At: at, Revenue: r.pos.Add(r.online).Money(), POS: r.pos.Money(), Online: r.online.Money(),
		Profit: r.profit.Money(), Checks: r.checks, Orders: r.orders}
}

func zeroRow() seriesRow {
	z := money.D("0")
	return seriesRow{pos: z, online: z, profit: z, checkTotal: z}
}

func (a seriesRow) add(b seriesRow) seriesRow {
	return seriesRow{pos: a.pos.Add(b.pos), online: a.online.Add(b.online), profit: a.profit.Add(b.profit),
		checkTotal: a.checkTotal.Add(b.checkTotal), checks: a.checks + b.checks, orders: a.orders + b.orders}
}

func (r seriesRow) totals() SeriesTotals {
	rev := r.pos.Add(r.online)
	t := SeriesTotals{Revenue: rev.Money(), POS: r.pos.Money(), Online: r.online.Money(), Profit: r.profit.Money(),
		Checks: r.checks, Orders: r.orders, AvgCheck: "0.00"}
	if rev.Sign() > 0 {
		pr, _ := r.profit.Float64()
		rv, _ := rev.Float64()
		m := round2(pr / rv * 100)
		t.MarginPct = &m
	}
	if r.checks > 0 {
		t.AvgCheck = r.checkTotal.Div(money.D(strconv.Itoa(r.checks))).Money()
	}
	return t
}

// buckets — суммы по часам или дням (время Ташкента).
func (s *Service) buckets(ctx context.Context, network string, stores []string, from, to time.Time, unit string) (map[time.Time]seriesRow, error) {
	rows, err := s.pool.Query(ctx, `WITH `+docsCTE+`
		SELECT date_trunc($5, at AT TIME ZONE 'Asia/Tashkent'),
		       COALESCE(sum(revenue) FILTER (WHERE ch = 'pos'), 0)::numeric(18,2)::text,
		       COALESCE(sum(revenue) FILTER (WHERE ch = 'online'), 0)::numeric(18,2)::text,
		       sum(revenue - cost)::numeric(18,2)::text, sum(check_total)::numeric(18,2)::text,
		       sum(checks)::int, sum(orders)::int
		FROM docs GROUP BY 1`, network, stores, from, to, unit)
	if err != nil {
		return nil, err
	}
	out := map[time.Time]seriesRow{}
	for rows.Next() {
		var at time.Time
		var pos, online, profit, ct string
		var r seriesRow
		if err := rows.Scan(&at, &pos, &online, &profit, &ct, &r.checks, &r.orders); err != nil {
			rows.Close()
			return nil, err
		}
		r.pos, r.online, r.profit, r.checkTotal = money.D(pos), money.D(online), money.D(profit), money.D(ct)
		// timestamp без зоны — это местное время Ташкента.
		out[time.Date(at.Year(), at.Month(), at.Day(), at.Hour(), 0, 0, 0, tashkent)] = r
	}
	rows.Close()
	return out, rows.Err()
}

func step(t time.Time, unit string) time.Time {
	if unit == "hour" {
		return t.Add(time.Hour)
	}
	return t.AddDate(0, 0, 1)
}

func floorTo(t time.Time, unit string) time.Time {
	t = t.In(tashkent)
	if unit == "hour" {
		return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), 0, 0, 0, tashkent)
	}
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, tashkent)
}

// fill — точки с нулями для пустых отрезков [from, end).
func fill(m map[time.Time]seriesRow, from, end time.Time, unit string) ([]SeriesPoint, seriesRow) {
	pts := []SeriesPoint{}
	sum := zeroRow()
	for t := floorTo(from, unit); t.Before(end); t = step(t, unit) {
		r, ok := m[t]
		if !ok {
			r = zeroRow()
		}
		sum = sum.add(r)
		pts = append(pts, r.point(t))
	}
	return pts, sum
}

func (s *Service) SalesSeries(ctx context.Context, p *identity.Principal, f SeriesFilter) (SalesSeries, error) {
	if f.Bucket == "" {
		f.Bucket = "day"
	}
	if f.Bucket == "weekday_hour" {
		return s.heatmap(ctx, p, f)
	}
	if f.Bucket != "hour" && f.Bucket != "day" {
		return SalesSeries{}, apperr.Validation("bucket: hour, day или weekday_hour").Uz("bucket: hour, day yoki weekday_hour")
	}
	sc, err := s.scope(p, f.Filter)
	if err != nil {
		return SalesSeries{}, err
	}
	shift, err := comparison(f.Compare, sc)
	if err != nil {
		return SalesSeries{}, err
	}
	if f.Bucket == "hour" && sc.to.Sub(sc.from) > seriesMaxHours*time.Hour {
		return SalesSeries{}, apperr.Validation("period: по часам — не больше трёх суток").Uz("period: soatlar boʻyicha — uch sutkadan oshmasin")
	}
	if sc.to.Sub(sc.from) > seriesMaxDays*24*time.Hour {
		return SalesSeries{}, apperr.Validation("period: не больше года").Uz("period: bir yildan oshmasin")
	}
	out := SalesSeries{From: sc.from, To: sc.to, Bucket: f.Bucket, Compare: f.Compare}
	end := s.live(sc)

	cur, err := s.buckets(ctx, p.NetworkID, sc.stores, sc.from, end, f.Bucket)
	if err != nil {
		return out, err
	}
	var sum seriesRow
	out.Points, sum = fill(cur, sc.from, end, f.Bucket)
	out.Totals = sum.totals()

	if shift > 0 {
		pf, pt, pe := sc.from.Add(-shift), sc.to.Add(-shift), end.Add(-shift)
		out.PrevFrom, out.PrevTo = &pf, &pt
		prev, err := s.buckets(ctx, p.NetworkID, sc.stores, pf, pt, f.Bucket)
		if err != nil {
			return out, err
		}
		out.Prev, _ = fill(prev, pf, pt, f.Bucket)
		// Итоги прошлого отрезка — точно до того же момента (не до начала часа).
		var r seriesRow
		if r, err = s.docsTotal(ctx, p.NetworkID, sc.stores, pf, pe); err != nil {
			return out, err
		}
		t := r.totals()
		out.PrevTotals = &t
		out.ChangePct = changePct(money.D(out.Totals.Revenue), money.D(t.Revenue))
	}
	return out, nil
}

func (s *Service) docsTotal(ctx context.Context, network string, stores []string, from, to time.Time) (seriesRow, error) {
	var pos, online, profit, ct string
	r := zeroRow()
	err := s.pool.QueryRow(ctx, `WITH `+docsCTE+`
		SELECT COALESCE(sum(revenue) FILTER (WHERE ch = 'pos'), 0)::numeric(18,2)::text,
		       COALESCE(sum(revenue) FILTER (WHERE ch = 'online'), 0)::numeric(18,2)::text,
		       COALESCE(sum(revenue - cost), 0)::numeric(18,2)::text, COALESCE(sum(check_total), 0)::numeric(18,2)::text,
		       COALESCE(sum(checks), 0)::int, COALESCE(sum(orders), 0)::int
		FROM docs`, network, stores, from, to).Scan(&pos, &online, &profit, &ct, &r.checks, &r.orders)
	r.pos, r.online, r.profit, r.checkTotal = money.D(pos), money.D(online), money.D(profit), money.D(ct)
	return r, err
}

// heatmap — «Когда покупают»: среднее число чеков и выручка кассы за один
// такой день недели и час. По умолчанию — последние 4 полные недели.
func (s *Service) heatmap(ctx context.Context, p *identity.Principal, f SeriesFilter) (SalesSeries, error) {
	if f.Compare != "" {
		return SalesSeries{}, apperr.Validation("compare: для weekday_hour не используется").Uz("compare: weekday_hour uchun ishlatilmaydi")
	}
	if f.From == nil {
		to := f.To
		if to == nil {
			now := s.now().In(tashkent)
			t := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
			to = &t
		}
		from := to.AddDate(0, 0, -heatmapDays)
		f.From, f.To = &from, to
	}
	sc, err := s.scope(p, f.Filter)
	if err != nil {
		return SalesSeries{}, err
	}
	if sc.to.Sub(sc.from) > seriesMaxDays*24*time.Hour {
		return SalesSeries{}, apperr.Validation("period: не больше года").Uz("period: bir yildan oshmasin")
	}
	out := SalesSeries{From: sc.from, To: sc.to, Bucket: "weekday_hour", Points: []SeriesPoint{}, Heatmap: []HeatCell{}}
	end := s.live(sc)

	// Сколько раз каждый день недели попал в период.
	days := map[int]int{}
	for d := floorTo(sc.from, "day"); d.Before(end); d = d.AddDate(0, 0, 1) {
		days[isoWeekday(d)]++
	}
	rows, err := s.pool.Query(ctx, `WITH `+docsCTE+`
		SELECT extract(isodow FROM at AT TIME ZONE 'Asia/Tashkent')::int, extract(hour FROM at AT TIME ZONE 'Asia/Tashkent')::int,
		       sum(checks)::int, sum(revenue)::numeric(18,2)::text
		FROM docs WHERE ch = 'pos' GROUP BY 1, 2 ORDER BY 1, 2`, p.NetworkID, sc.stores, sc.from, end)
	if err != nil {
		return out, err
	}
	out.Heatmap, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (HeatCell, error) {
		var c HeatCell
		var n int
		var rev string
		if err := r.Scan(&c.Weekday, &c.Hour, &n, &rev); err != nil {
			return c, err
		}
		if k := days[c.Weekday]; k > 0 {
			c.Checks = math.Round(float64(n)/float64(k)*10) / 10
			c.Revenue = money.D(rev).Div(money.D(strconv.Itoa(k))).Money()
		} else {
			c.Revenue = "0.00"
		}
		return c, nil
	})
	if err != nil {
		return out, err
	}
	// Без пустых клеток: вычитанные возвраты могли дать ноль.
	cells := out.Heatmap[:0]
	for _, c := range out.Heatmap {
		if c.Checks > 0 || money.D(c.Revenue).Sign() != 0 {
			cells = append(cells, c)
		}
	}
	out.Heatmap = cells
	return out, nil
}

func isoWeekday(t time.Time) int {
	if wd := int(t.Weekday()); wd != 0 {
		return wd
	}
	return 7
}

// ------------------------------------------------------- sales-breakdown

type BreakdownFilter struct {
	Filter
	By       string // category, product, payment
	ParentID string // category: разложить подкатегории этой категории
	Compare  string
	Limit    int
}

type BreakdownItem struct {
	Key       string   `json:"key"` // id категории или товара, код способа оплаты
	Name      string   `json:"name"`
	Value     string   `json:"value"` // сум
	Qty       *string  `json:"qty,omitempty"`
	Unit      *string  `json:"unit,omitempty"`
	Image     *string  `json:"image,omitempty"`
	Share     float64  `json:"share"` // % от total
	PrevValue *string  `json:"prev_value,omitempty"`
	ChangePct *float64 `json:"change_pct,omitempty"`
}

type BreakdownOther struct {
	Count     int     `json:"count"`
	Value     string  `json:"value"`
	Share     float64 `json:"share"`
	PrevValue *string `json:"prev_value,omitempty"`
}

type SalesBreakdown struct {
	By        string          `json:"by"`
	From      time.Time       `json:"from"`
	To        time.Time       `json:"to"`
	Total     string          `json:"total"`
	Items     []BreakdownItem `json:"items"`
	Other     *BreakdownOther `json:"other"` // всё, что не вошло в limit
	Compare   string          `json:"compare,omitempty"`
	PrevFrom  *time.Time      `json:"prev_from,omitempty"`
	PrevTo    *time.Time      `json:"prev_to,omitempty"`
	PrevTotal *string         `json:"prev_total,omitempty"`
	ChangePct *float64        `json:"change_pct,omitempty"`
}

type part struct {
	key, name   string
	value, qty  money.Dec
	unit, image *string
}

// Названия способов оплаты онлайн-заказов (payment_provider).
var onlinePay = map[string]i18n.Text{"payme": {RU: "Payme"}, "click": {RU: "Click"}, "cash": {RU: "Наличные курьеру", UZ: "Kuryerga naqd pul"}}

func (s *Service) parts(ctx context.Context, network string, stores []string, from, to time.Time, f BreakdownFilter) (map[string]*part, error) {
	var q string
	args := []any{network, stores, from, to}
	switch f.By {
	case "category":
		// Ключ — раздел верхнего уровня, а с parent_id — его прямая подкатегория.
		q = `WITH RECURSIVE ` + salesLinesCTE + `,
			tree AS (
				SELECT id, ARRAY[id] AS path FROM categories WHERE parent_id IS NULL
				UNION ALL SELECT c.id, t.path || c.id FROM categories c JOIN tree t ON c.parent_id = t.id
			), parent AS (SELECT NULLIF($5, '')::uuid AS id
			), keyed AS (
				SELECT l.revenue, CASE WHEN pr.id IS NULL THEN t.path[1]
				                       ELSE t.path[array_position(t.path, pr.id) + 1] END AS k
				FROM lines l JOIN products p ON p.id = l.product_id JOIN tree t ON t.id = p.category_id
				CROSS JOIN parent pr
				WHERE pr.id IS NULL OR pr.id = ANY(t.path)
			)
			SELECT COALESCE(k::text, $5), COALESCE(loc(c.name, c.name_uz), loc('Без подкатегории', 'Ichki kategoriyasiz')), sum(revenue)::numeric(18,2)::text, '0', NULL::text, NULL::text
			FROM keyed LEFT JOIN categories c ON c.id = k
			GROUP BY 1, 2`
		args = append(args, f.ParentID)
	case "product":
		q = `WITH ` + salesLinesCTE + `
			SELECT p.id::text, loc(p.name, p.name_uz), sum(l.revenue)::numeric(18,2)::text, sum(l.qty)::text, loc(u.short_name, u.short_name_uz), p.images[1]
			FROM lines l JOIN products p ON p.id = l.product_id JOIN units u ON u.id = p.unit_id
			GROUP BY 1, 2, 5, 6`
	case "payment":
		// Как платили покупатели: оплаты чеков, продажи в долг и онлайн-заказы.
		// Возвраты не вычитаются — это структура поступлений, а не выручка.
		q = `SELECT pm.id::text, pm.name, sum(sp.amount)::numeric(18,2)::text, '0', NULL::text, NULL::text
			FROM sale_payments sp JOIN sales s ON s.id = sp.sale_id JOIN payment_methods pm ON pm.id = sp.payment_method_id
			WHERE s.network_id = $1 AND ($2::uuid[] IS NULL OR s.store_id = ANY($2)) AND s.sold_at >= $3 AND s.sold_at < $4
			GROUP BY 1, 2
			UNION ALL
			SELECT 'debt', loc('В долг', 'Qarzga'), sum(debt_amount)::numeric(18,2)::text, '0', NULL, NULL
			FROM sales WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND sold_at >= $3 AND sold_at < $4
			HAVING sum(debt_amount) > 0
			UNION ALL
			SELECT 'online:' || payment_provider, payment_provider, sum(subtotal + delivery_fee)::numeric(18,2)::text, '0', NULL, NULL
			FROM orders WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND status = 'delivered'
			  AND delivered_at >= $3 AND delivered_at < $4
			GROUP BY payment_provider`
	}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	out := map[string]*part{}
	for rows.Next() {
		var key, name, value, qty string
		var unit, image *string
		if err := rows.Scan(&key, &name, &value, &qty, &unit, &image); err != nil {
			rows.Close()
			return nil, err
		}
		if n, ok := onlinePay[name]; ok && len(key) > 7 && key[:7] == "online:" {
			name = n.Ctx(ctx)
		}
		x := out[key]
		if x == nil {
			x = &part{key: key, name: name, value: money.D("0"), qty: money.D("0"), unit: unit, image: image}
			out[key] = x
		}
		x.value, x.qty = x.value.Add(money.D(value)), x.qty.Add(money.D(qty))
	}
	rows.Close()
	return out, rows.Err()
}

func (s *Service) SalesBreakdown(ctx context.Context, p *identity.Principal, f BreakdownFilter) (SalesBreakdown, error) {
	switch f.By {
	case "category", "product", "payment":
	default:
		return SalesBreakdown{}, apperr.Validation("by: category, product или payment").Uz("by: category, product yoki payment")
	}
	if f.ParentID != "" && (f.By != "category" || !httpx.IsUUID(f.ParentID)) {
		return SalesBreakdown{}, apperr.Validation("parent_id: неверный id категории").Uz("parent_id: kategoriya id notoʻgʻri")
	}
	if f.Limit == 0 {
		f.Limit = breakdownLimit
		if f.By == "payment" {
			f.Limit = breakdownMaxLim
		}
	}
	if f.Limit < 1 || f.Limit > breakdownMaxLim {
		return SalesBreakdown{}, apperr.Validation("limit: от 1 до 50").Uz("limit: 1 dan 50 gacha")
	}
	sc, err := s.scope(p, f.Filter)
	if err != nil {
		return SalesBreakdown{}, err
	}
	if sc.to.Sub(sc.from) > seriesMaxDays*24*time.Hour {
		return SalesBreakdown{}, apperr.Validation("period: не больше года").Uz("period: bir yildan oshmasin")
	}
	shift, err := comparison(f.Compare, sc)
	if err != nil {
		return SalesBreakdown{}, err
	}
	out := SalesBreakdown{By: f.By, From: sc.from, To: sc.to, Items: []BreakdownItem{}, Compare: f.Compare}
	end := s.live(sc)
	cur, err := s.parts(ctx, p.NetworkID, sc.stores, sc.from, end, f)
	if err != nil {
		return out, err
	}
	var prev map[string]*part
	if shift > 0 {
		pf, pt := sc.from.Add(-shift), sc.to.Add(-shift)
		out.PrevFrom, out.PrevTo = &pf, &pt
		if prev, err = s.parts(ctx, p.NetworkID, sc.stores, pf, end.Add(-shift), f); err != nil {
			return out, err
		}
	}

	list := make([]*part, 0, len(cur))
	total := money.D("0")
	for _, x := range cur {
		if x.value.Sign() <= 0 {
			continue // всё вернули
		}
		total = total.Add(x.value)
		list = append(list, x)
	}
	sort.Slice(list, func(i, j int) bool {
		if c := list[i].value.Cmp(list[j].value); c != 0 {
			return c > 0
		}
		return list[i].name < list[j].name
	})
	out.Total = total.Money()
	tf, _ := total.Float64()
	share := func(v money.Dec) float64 {
		if tf <= 0 {
			return 0
		}
		x, _ := v.Float64()
		return round2(x / tf * 100)
	}
	prevOf := func(key string) money.Dec {
		if x := prev[key]; x != nil {
			return x.value
		}
		return money.D("0")
	}
	for i, x := range list {
		if i >= f.Limit {
			if out.Other == nil {
				out.Other = &BreakdownOther{Value: "0.00"}
			}
			out.Other.Count++
			out.Other.Value = money.D(out.Other.Value).Add(x.value).Money()
			continue
		}
		it := BreakdownItem{Key: x.key, Name: x.name, Value: x.value.Money(), Share: share(x.value), Unit: x.unit, Image: x.image}
		if f.By == "product" {
			q := x.qty.Fixed(3)
			it.Qty = &q
		}
		if prev != nil {
			pv := prevOf(x.key)
			s := pv.Money()
			it.PrevValue, it.ChangePct = &s, changePct(x.value, pv)
		}
		out.Items = append(out.Items, it)
	}
	if out.Other != nil {
		out.Other.Share = share(money.D(out.Other.Value))
		if prev != nil {
			pv := money.D("0")
			for _, x := range list[f.Limit:] {
				pv = pv.Add(prevOf(x.key))
			}
			s := pv.Money()
			out.Other.PrevValue = &s
		}
	}
	if prev != nil {
		pt := money.D("0")
		for _, x := range prev {
			if x.value.Sign() > 0 {
				pt = pt.Add(x.value)
			}
		}
		s := pt.Money()
		out.PrevTotal, out.ChangePct = &s, changePct(total, pt)
	}
	return out, nil
}

// changePct — изменение к прошлому значению, %; nil — прошлого не было.
func changePct(cur, prev money.Dec) *float64 {
	if prev.Sign() <= 0 {
		return nil
	}
	c, _ := cur.Float64()
	p, _ := prev.Float64()
	v := math.Round((c-p)/p*1000) / 10
	return &v
}
