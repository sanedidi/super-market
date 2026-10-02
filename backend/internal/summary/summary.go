// Package summary — итоги дня владельцу: выручка и прибыль со сравнением со
// вчера, что требует внимания, выручка по магазинам, деньги на вечер.
// Каждый вечер в выбранный час — push в приложение магазина.
package summary

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
	"github.com/sanedidi/super-market/backend/internal/reports"
)

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

// Пороги «требует внимания».
const (
	lowStockDays     = 2  // остатка хватит меньше чем на столько дней продаж
	lowStockWindow   = 14 // дней продаж для средней
	lowStockMinSold  = 3  // меньше продаж за окно — товар не считаем ходовым
	invoiceSoonDays  = 3
	orderWaitMinutes = 10
)

type Service struct {
	pool    *pgxpool.Pool
	reports *reports.Service
	finance *finance.Service
	log     *slog.Logger
	now     func() time.Time
}

func NewService(pool *pgxpool.Pool, log *slog.Logger) *Service {
	return &Service{pool: pool, reports: reports.NewService(pool), finance: finance.NewService(pool), log: log, now: time.Now}
}

type Alert struct {
	Kind   string  `json:"kind"`  // shortage, low_stock, supplier, billing, orders
	Level  string  `json:"level"` // red, amber, blue
	Title  string  `json:"title"`
	Text   string  `json:"text"`
	Target string  `json:"target"` // куда ведёт: shift, stock, supplier, billing, orders
	ID     *string `json:"id"`
}

type StoreDay struct {
	StoreID     string `json:"store_id"`
	Name        string `json:"name"`
	Revenue     string `json:"revenue"`
	RevenuePrev string `json:"revenue_prev"`
	ChangePct   *int   `json:"change_pct"`
}

type Money struct {
	StoresCash *string `json:"stores_cash"`
	MainCash   *string `json:"main_cash"`
	Available  *string `json:"available"`
}

type Summary struct {
	Date        string     `json:"date"`
	Revenue     string     `json:"revenue"`
	RevenuePrev string     `json:"revenue_prev"`
	ChangePct   *int       `json:"change_pct"`
	Profit      string     `json:"profit"`
	MarginPct   *int       `json:"margin_pct"`
	SalesCount  int        `json:"sales_count"`
	AvgCheck    string     `json:"avg_check"`
	OrdersCount int        `json:"orders_count"`
	OrdersTotal string     `json:"orders_total"`
	Alerts      []Alert    `json:"alerts"`
	Stores      []StoreDay `json:"stores"`
	Money       Money      `json:"money"`
}

func pct(cur, prev money.Dec) *int {
	if prev.Sign() <= 0 {
		return nil
	}
	f, _ := cur.Sub(prev).Div(prev).Float64()
	v := int(math.Round(f * 100))
	return &v
}

func (s *Service) pl(ctx context.Context, p *identity.Principal, from time.Time, storeID string) (reports.ProfitLoss, error) {
	to := from.AddDate(0, 0, 1)
	return s.reports.ProfitLoss(ctx, p, reports.Filter{From: &from, To: &to, StoreID: storeID})
}

// Day — итоги за день date (YYYY-MM-DD по Ташкенту, пусто — сегодня); storeID — один магазин или все доступные.
func (s *Service) Day(ctx context.Context, p *identity.Principal, date, storeID string) (Summary, error) {
	out := Summary{Alerts: []Alert{}, Stores: []StoreDay{}}
	if err := p.Require(identity.PermReportsView); err != nil {
		return out, err
	}
	now := s.now().In(tashkent)
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
	if date != "" {
		d, err := time.ParseInLocation("2006-01-02", date, tashkent)
		if err != nil {
			return out, apperr.Validation("date: дата YYYY-MM-DD")
		}
		day = d
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return out, apperr.NotFound("магазин не найден")
	}
	out.Date = day.Format("2006-01-02")
	prevDay := day.AddDate(0, 0, -1)

	cur, err := s.pl(ctx, p, day, storeID)
	if err != nil {
		return out, err
	}
	prev, err := s.pl(ctx, p, prevDay, storeID)
	if err != nil {
		return out, err
	}
	out.Revenue, out.RevenuePrev = cur.Revenue.Total, prev.Revenue.Total
	out.ChangePct = pct(money.D(cur.Revenue.Total), money.D(prev.Revenue.Total))
	out.Profit = cur.NetProfit
	if money.D(cur.Revenue.Total).Sign() > 0 {
		f, _ := money.D(cur.NetProfit).Div(money.D(cur.Revenue.Total)).Float64()
		m := int(math.Round(f * 100))
		out.MarginPct = &m
	}
	out.SalesCount, out.OrdersCount = cur.SalesCount, cur.OrdersCount
	out.OrdersTotal = money.D(cur.Revenue.OnlineOrders).Add(money.D(cur.Revenue.DeliveryFees)).Money()
	out.AvgCheck = "0.00"
	if cur.SalesCount > 0 {
		out.AvgCheck = money.D(cur.Revenue.POSSales).Div(money.D(fmt.Sprint(cur.SalesCount))).Money()
	}

	// По магазинам — только когда их больше одного.
	if storeID == "" {
		stores, err := s.stores(ctx, p)
		if err != nil {
			return out, err
		}
		if len(stores) > 1 {
			for _, st := range stores {
				c, err := s.pl(ctx, p, day, st[0])
				if err != nil {
					return out, err
				}
				pv, err := s.pl(ctx, p, prevDay, st[0])
				if err != nil {
					return out, err
				}
				out.Stores = append(out.Stores, StoreDay{StoreID: st[0], Name: st[1], Revenue: c.Revenue.Total, RevenuePrev: pv.Revenue.Total,
					ChangePct: pct(money.D(c.Revenue.Total), money.D(pv.Revenue.Total))})
			}
		}
	}

	if out.Alerts, err = s.alerts(ctx, p, day, storeID); err != nil {
		return out, err
	}
	if out.Money, err = s.money(ctx, p, storeID); err != nil {
		return out, err
	}
	return out, nil
}

func (s *Service) stores(ctx context.Context, p *identity.Principal) ([][2]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT id::text, name FROM stores WHERE network_id = $1 AND ($2 OR id = ANY($3::uuid[]))
		ORDER BY created_at LIMIT 30`, p.NetworkID, p.SeesAllStores(), p.StoreIDs)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) ([2]string, error) {
		var v [2]string
		err := r.Scan(&v[0], &v[1])
		return v, err
	})
}

const scope = `network_id = $1 AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4)`

func (s *Service) alerts(ctx context.Context, p *identity.Principal, day time.Time, storeID string) ([]Alert, error) {
	out := []Alert{}
	args := []any{p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID}

	// Недостачи на закрытии смен.
	rows, err := s.pool.Query(ctx, `
		SELECT sh.id::text, (-sh.diff)::text, e.full_name, st.name, d.name
		FROM pos_shifts sh JOIN employees e ON e.id = sh.opened_by JOIN stores st ON st.id = sh.store_id JOIN pos_devices d ON d.id = sh.device_id
		WHERE sh.`+strings.ReplaceAll(scope, "store_id", "sh.store_id")+` AND sh.diff < 0 AND sh.closed_at >= $5 AND sh.closed_at < $6
		ORDER BY sh.diff LIMIT 5`, append(args, day, day.AddDate(0, 0, 1))...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id, amount, who, store, device string
		if err := rows.Scan(&id, &amount, &who, &store, &device); err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, Alert{Kind: "shortage", Level: "red", Title: "Недостача " + money.Group(amount) + " сум",
			Text: shortName(who) + " · " + store + ", " + device, Target: "shift", ID: &id})
	}
	rows.Close()

	// Товары заканчиваются: остатка меньше чем на 2 дня продаж.
	if p.CanAny(identity.PermInventoryManage, identity.PermReportsView) {
		var n int
		var name, qty, unit string
		err := s.pool.QueryRow(ctx, `
			WITH sold AS (
				SELECT sl.store_id, si.product_id, sum(si.qty) AS q
				FROM sale_items si JOIN sales sl ON sl.id = si.sale_id
				WHERE sl.`+strings.ReplaceAll(scope, "store_id", "sl.store_id")+` AND sl.sold_at >= $5 AND sl.sold_at < $6
				GROUP BY 1, 2 HAVING sum(si.qty) >= $7),
			     left_ AS (
				SELECT sold.store_id, sold.product_id, sold.q,
				       COALESCE((SELECT sum(b.qty_remaining) FROM batches b JOIN warehouses w ON w.id = b.warehouse_id
				                 WHERE w.store_id = sold.store_id AND b.product_id = sold.product_id), 0) AS stock
				FROM sold),
			     low AS (SELECT * FROM left_ WHERE stock <= q / $8 * $9)
			SELECT (SELECT count(DISTINCT product_id) FROM low)::int,
			       COALESCE(top.name, ''), COALESCE(top.qty, ''), COALESCE(top.unit, '')
			FROM (SELECT 1) one
			LEFT JOIN LATERAL (
				SELECT pr.name, trim(trailing '.' FROM trim(trailing '0' FROM low.stock::text)) AS qty, u.short_name AS unit
				FROM low JOIN products pr ON pr.id = low.product_id JOIN units u ON u.id = pr.unit_id
				ORDER BY low.stock / NULLIF(low.q, 0) LIMIT 1) top ON true`,
			append(args, day.AddDate(0, 0, 1-lowStockWindow), day.AddDate(0, 0, 1), lowStockMinSold, lowStockWindow, lowStockDays)...).
			Scan(&n, &name, &qty, &unit)
		if err != nil {
			return nil, err
		}
		if n > 0 {
			if qty == "" {
				qty = "0"
			}
			out = append(out, Alert{Kind: "low_stock", Level: "amber", Title: fmt.Sprintf("%d %s заканчива%s", n, plural(n, "товар", "товара", "товаров"), map[bool]string{true: "ется", false: "ются"}[n%10 == 1 && n%100 != 11]),
				Text: name + " — осталось " + qty + " " + unit, Target: "stock"})
		}
	}

	// Поставщики, которым давно не платили.
	if p.CanAny(identity.PermCounterpartiesManage, identity.PermInventoryManage, identity.PermFinanceManage) {
		d, err := s.finance.SupplierDebts(ctx, p, "we_owe", "")
		if err != nil {
			return nil, err
		}
		var long []finance.Debt
		for _, x := range d.Items {
			if x.DaysUnpaid != nil && *x.DaysUnpaid >= finance.DebtsLongUnpaid {
				long = append(long, x)
			}
		}
		if len(long) > 0 {
			x := long[0]
			title := fmt.Sprintf("%s: %d %s без оплаты", x.Name, *x.DaysUnpaid, plural(*x.DaysUnpaid, "день", "дня", "дней"))
			text := "долг " + money.Group(x.Balance) + " сум"
			if len(long) > 1 {
				text += fmt.Sprintf(" · ещё %d %s", len(long)-1, plural(len(long)-1, "поставщик", "поставщика", "поставщиков"))
			}
			id := x.ID
			out = append(out, Alert{Kind: "supplier", Level: "amber", Title: title, Text: text, Target: "supplier", ID: &id})
		}
	}

	// Счёт за подписку: просрочен или срок через 3 дня.
	if p.Can(identity.PermPayoutsManage) {
		var due time.Time
		var amount string
		err := s.pool.QueryRow(ctx, `SELECT due_date, amount_uzs::text FROM subscription_invoices
			WHERE network_id = $1 AND status = 'unpaid' AND due_date <= $2 ORDER BY due_date LIMIT 1`,
			p.NetworkID, day.AddDate(0, 0, invoiceSoonDays)).Scan(&due, &amount)
		if err == nil {
			text := "оплатить до " + ruDate(due) + " · " + money.Group(amount) + " сум"
			level := "blue"
			if due.Before(day) {
				text, level = "просрочен с "+ruDate(due)+" · "+money.Group(amount)+" сум", "red"
			}
			out = append(out, Alert{Kind: "billing", Level: level, Title: "Счёт за подписку", Text: text, Target: "billing"})
		} else if err != pgx.ErrNoRows {
			return nil, err
		}
	}

	// Оплаченные заказы, которые никто не принял.
	if p.Can(identity.PermOrdersManage) {
		var n int
		if err := s.pool.QueryRow(ctx, `SELECT count(*)::int FROM orders WHERE `+scope+` AND status = 'paid'
			AND paid_at < now() - make_interval(mins => $5)`, append(args, orderWaitMinutes)...).Scan(&n); err != nil {
			return nil, err
		}
		if n > 0 {
			out = append(out, Alert{Kind: "orders", Level: "red", Title: fmt.Sprintf("%d %s ждут приёма", n, plural(n, "заказ", "заказа", "заказов")),
				Text: fmt.Sprintf("оплачены больше %d минут назад", orderWaitMinutes), Target: "orders"})
		}
	}
	return out, nil
}

func (s *Service) money(ctx context.Context, p *identity.Principal, storeID string) (Money, error) {
	var m Money
	if p.Can(identity.PermFinanceManage) {
		var stores, main string
		if err := s.pool.QueryRow(ctx, `
			SELECT COALESCE(sum(e.amount) FILTER (WHERE c.store_id IS NOT NULL), 0)::numeric(18,2)::text,
			       COALESCE(sum(e.amount) FILTER (WHERE c.is_main), 0)::numeric(18,2)::text
			FROM cashboxes c JOIN cash_entries e ON e.cashbox_id = c.id
			WHERE c.network_id = $1 AND c.currency = 'UZS' AND c.is_active
			  AND (c.is_main OR $2 OR c.store_id = ANY($3::uuid[])) AND ($4 = '' OR c.store_id::text = $4 OR c.is_main)`,
			p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID).Scan(&stores, &main); err != nil {
			return m, err
		}
		m.StoresCash = &stores
		if p.SeesAllStores() {
			m.MainCash = &main
		}
	}
	if p.Can(identity.PermPayoutsManage) {
		var a string
		if err := s.pool.QueryRow(ctx, `SELECT COALESCE(sum(amount) FILTER (WHERE status = 'available'), 0)::numeric(18,2)::text
			FROM balance_entries WHERE network_id = $1`, p.NetworkID).Scan(&a); err != nil {
			return m, err
		}
		m.Available = &a
	}
	return m, nil
}

// ------------------------------------------------------------ настройки

type Settings struct {
	Enabled bool `json:"enabled"`
	Hour    int  `json:"hour"`
}

func (s *Service) GetSettings(ctx context.Context, p *identity.Principal) (Settings, error) {
	if err := p.Require(identity.PermReportsView); err != nil {
		return Settings{}, err
	}
	st := Settings{Enabled: p.IsOwner, Hour: 21}
	err := s.pool.QueryRow(ctx, `SELECT enabled, hour FROM owner_summary_settings WHERE employee_id = $1`, p.EmployeeID).Scan(&st.Enabled, &st.Hour)
	if err != nil && err != pgx.ErrNoRows {
		return st, err
	}
	return st, nil
}

func (s *Service) SaveSettings(ctx context.Context, p *identity.Principal, in Settings) (Settings, error) {
	if err := p.Require(identity.PermReportsView); err != nil {
		return Settings{}, err
	}
	if in.Hour < 0 || in.Hour > 23 {
		return Settings{}, apperr.Validation("hour: от 0 до 23")
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO owner_summary_settings (employee_id, enabled, hour) VALUES ($1, $2, $3)
		ON CONFLICT (employee_id) DO UPDATE SET enabled = $2, hour = $3, updated_at = now()`, p.EmployeeID, in.Enabled, in.Hour)
	return in, err
}

// ------------------------------------------------------------ рассылка

// Tick — раз в минуту: кому пора, отправляет итоги дня (один раз за день).
func (s *Service) Tick(ctx context.Context) error {
	now := s.now().In(tashkent)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
	rows, err := s.pool.Query(ctx, `
		SELECT e.id::text, COALESCE(os.enabled, r.is_owner)
		FROM employees e
		JOIN roles r ON r.id = e.role_id
		JOIN networks n ON n.id = e.network_id AND n.status = 'active'
		LEFT JOIN owner_summary_settings os ON os.employee_id = e.id
		WHERE e.status = 'active' AND (r.is_owner OR 'reports.view' = ANY(r.permissions))
		  AND COALESCE(os.enabled, r.is_owner) AND COALESCE(os.hour, 21) <= $1
		  AND (os.last_sent IS NULL OR os.last_sent < $2::date)
		  AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = e.user_id AND d.app = 'store')
		LIMIT 200`, now.Hour(), today.Format("2006-01-02"))
	if err != nil {
		return err
	}
	type who struct {
		id      string
		enabled bool
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (who, error) {
		var w who
		err := r.Scan(&w.id, &w.enabled)
		return w, err
	})
	if err != nil {
		return err
	}
	for _, w := range list {
		if err := s.send(ctx, w.id, w.enabled, today); err != nil {
			s.log.Error("итоги дня: не отправлены", "employee_id", w.id, "err", err)
		}
	}
	return nil
}

func (s *Service) send(ctx context.Context, employeeID string, enabled bool, today time.Time) error {
	p, err := identity.EmployeePrincipal(ctx, s.pool, employeeID)
	if err != nil {
		return err
	}
	sum, err := s.Day(ctx, p, today.Format("2006-01-02"), "")
	if err != nil {
		return err
	}
	title, body := PushText(sum, today)
	if err := push.EnqueueEmployee(ctx, s.pool, employeeID, "owner_summary", title, body,
		map[string]string{"type": "summary", "date": sum.Date}); err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO owner_summary_settings (employee_id, enabled, last_sent) VALUES ($1, $2, $3::date)
		ON CONFLICT (employee_id) DO UPDATE SET last_sent = $3::date`, employeeID, enabled, today.Format("2006-01-02"))
	return err
}

// PushText — «Итоги дня · 2 октября» / «Выручка 6,1 млн (+12% к вчера), прибыль 1,2 млн. Недостача 45 000 у кассира, …».
func PushText(s Summary, day time.Time) (string, string) {
	title := "Итоги дня · " + ruDate(day)
	var b strings.Builder
	b.WriteString("Выручка " + Short(s.Revenue))
	if s.ChangePct != nil {
		sign := "+"
		if *s.ChangePct < 0 {
			sign = "−"
		}
		fmt.Fprintf(&b, " (%s%d%% к вчера)", sign, abs(*s.ChangePct))
	}
	b.WriteString(", прибыль " + Short(s.Profit) + ".")
	var notes []string
	for _, a := range s.Alerts {
		switch a.Kind {
		case "shortage":
			notes = append(notes, lowerFirst(a.Title)+" у кассира")
		case "low_stock", "orders":
			notes = append(notes, a.Title)
		case "supplier":
			notes = append(notes, "долг поставщику без оплаты")
		case "billing":
			notes = append(notes, "счёт за подписку")
		}
		if len(notes) == 3 {
			break
		}
	}
	if len(notes) > 0 {
		n := []rune(strings.Join(notes, ", "))
		b.WriteString(" " + strings.ToUpper(string(n[:1])) + string(n[1:]) + ".")
	}
	return title, b.String()
}

// Short — «6140000.00» → «6,1 млн», «45000» → «45 000».
func Short(v string) string {
	f, _ := money.D(v).Float64()
	a := math.Abs(f)
	sign := ""
	if f < 0 {
		sign = "−"
	}
	if a >= 1_000_000 {
		s := fmt.Sprintf("%.1f", a/1_000_000)
		s = strings.TrimSuffix(strings.ReplaceAll(s, ".", ","), ",0")
		return sign + s + " млн"
	}
	return sign + money.Group(fmt.Sprintf("%.0f", a))
}

var months = [...]string{"января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"}

func ruDate(t time.Time) string { return fmt.Sprintf("%d %s", t.Day(), months[t.Month()-1]) }

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func plural(n int, one, few, many string) string {
	n = n % 100
	if n >= 11 && n <= 14 {
		return many
	}
	switch n % 10 {
	case 1:
		return one
	case 2, 3, 4:
		return few
	}
	return many
}

func shortName(name string) string {
	parts := strings.Fields(name)
	if len(parts) < 2 {
		return name
	}
	return parts[0] + " " + string([]rune(parts[1])[:1]) + "."
}

func lowerFirst(s string) string {
	r := []rune(s)
	if len(r) == 0 {
		return s
	}
	return strings.ToLower(string(r[:1])) + string(r[1:])
}
