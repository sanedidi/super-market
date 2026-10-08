package pos

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Контроль кассиров: итоги по каждому кассиру за период, расхождения
// на закрытии смен и «сигналы» — недостачи, много возвратов, крупные скидки,
// непробитые чеки.

// Пороги сигналов.
const (
	SignalReturns       = 3    // возвратов за период
	SignalDiscountShare = 0.05 // доля скидок от суммы чеков до скидки
	SignalDiscountSale  = 0.15 // скидка на один чек
	fiscalGrace         = time.Hour
)

type ShiftBrief struct {
	ID         string     `json:"id"`
	Number     int64      `json:"number"`
	StoreName  string     `json:"store_name"`
	DeviceName string     `json:"device_name"`
	OpenedAt   time.Time  `json:"opened_at"`
	ClosedAt   *time.Time `json:"closed_at"`
	Diff       *string    `json:"diff"`
}

type CashierStat struct {
	EmployeeID    string       `json:"employee_id"`
	FullName      string       `json:"full_name"`
	SalesCount    int          `json:"sales_count"`
	Revenue       string       `json:"revenue"`
	Discounts     string       `json:"discounts"`
	MaxDiscountPc int          `json:"max_discount_pct"`
	ReturnsCount  int          `json:"returns_count"`
	ReturnsTotal  string       `json:"returns_total"`
	FiscalPending int          `json:"fiscal_pending"`
	Shortage      string       `json:"shortage"` // сумма недостач (положительное число)
	Surplus       string       `json:"surplus"`
	OpenShift     bool         `json:"open_shift"`
	Flags         []string     `json:"flags"`  // shortage, surplus, returns, discounts, fiscal
	Shifts        []ShiftBrief `json:"shifts"` // новые сверху, до 10
}

type Signal struct {
	Kind       string  `json:"kind"`
	Text       string  `json:"text"`
	EmployeeID string  `json:"employee_id"`
	ShiftID    *string `json:"shift_id"`
}

type CashierControl struct {
	From    time.Time     `json:"from"`
	To      time.Time     `json:"to"`
	Signals []Signal      `json:"signals"`
	Items   []CashierStat `json:"items"`
}

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

func (s *Service) Cashiers(ctx context.Context, p *identity.Principal, storeID string, from, to *time.Time) (CashierControl, error) {
	out := CashierControl{Signals: []Signal{}, Items: []CashierStat{}}
	if err := p.RequireAny(identity.PermReportsView, identity.PermFinanceManage); err != nil {
		return out, err
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	now := s.now().In(tashkent)
	out.From = time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
	out.To = out.From.AddDate(0, 0, 1)
	if from != nil {
		out.From = *from
	}
	if to != nil {
		out.To = *to
	}
	if !out.To.After(out.From) {
		return out, apperr.Validation("to: конец периода позже начала").Uz("to: davr oxiri boshidan keyin boʻlsin")
	}
	scope := `network_id = $1 AND ($2 OR store_id = ANY($3::uuid[])) AND ($4 = '' OR store_id::text = $4)`
	args := []any{p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID, out.From, out.To, now.Add(-fiscalGrace)}
	rows, err := s.pool.Query(ctx, `
		WITH sa AS (
			SELECT cashier_id AS emp, count(*) AS n, sum(total) AS revenue, sum(discount) AS disc, sum(subtotal) AS sub,
			       max(CASE WHEN subtotal > 0 THEN discount / subtotal ELSE 0 END) AS maxpc,
			       count(*) FILTER (WHERE fiscal_status = 'pending' AND sold_at < $7) AS pend
			FROM sales WHERE `+scope+` AND sold_at >= $5 AND sold_at < $6 GROUP BY 1),
		     re AS (
			SELECT created_by AS emp, count(*) AS n, sum(total) AS total FROM customer_returns
			WHERE `+scope+` AND created_at >= $5 AND created_at < $6 GROUP BY 1),
		     sh AS (
			SELECT opened_by AS emp, sum(-diff) FILTER (WHERE diff < 0) AS short, sum(diff) FILTER (WHERE diff > 0) AS sur,
			       bool_or(closed_at IS NULL) AS open
			FROM pos_shifts WHERE `+scope+` AND opened_at < $6 AND (closed_at IS NULL OR closed_at >= $5) GROUP BY 1),
		     emps AS (SELECT emp FROM sa UNION SELECT emp FROM re UNION SELECT emp FROM sh)
		SELECT e.id, e.full_name, COALESCE(sa.n, 0)::int, COALESCE(sa.revenue, 0)::numeric(18,2)::text,
		       COALESCE(sa.disc, 0)::numeric(18,2)::text, COALESCE(sa.sub, 0)::numeric(18,2)::text,
		       round(COALESCE(sa.maxpc, 0) * 100)::int, COALESCE(sa.pend, 0)::int,
		       COALESCE(re.n, 0)::int, COALESCE(re.total, 0)::numeric(18,2)::text,
		       COALESCE(sh.short, 0)::numeric(18,2)::text, COALESCE(sh.sur, 0)::numeric(18,2)::text, COALESCE(sh.open, false)
		FROM emps JOIN employees e ON e.id = emps.emp
		LEFT JOIN sa ON sa.emp = e.id LEFT JOIN re ON re.emp = e.id LEFT JOIN sh ON sh.emp = e.id
		ORDER BY COALESCE(sh.short, 0) DESC, COALESCE(sa.revenue, 0) DESC, e.full_name`, args...)
	if err != nil {
		return out, err
	}
	type row struct {
		CashierStat
		subtotal string
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) {
		var c row
		err := r.Scan(&c.EmployeeID, &c.FullName, &c.SalesCount, &c.Revenue, &c.Discounts, &c.subtotal, &c.MaxDiscountPc,
			&c.FiscalPending, &c.ReturnsCount, &c.ReturnsTotal, &c.Shortage, &c.Surplus, &c.OpenShift)
		return c, err
	})
	if err != nil {
		return out, err
	}
	for _, r := range list {
		c := r.CashierStat
		c.Flags = []string{}
		if money.D(c.Shortage).Sign() > 0 {
			c.Flags = append(c.Flags, "shortage")
		}
		if money.D(c.Surplus).Sign() > 0 {
			c.Flags = append(c.Flags, "surplus")
		}
		if c.ReturnsCount >= SignalReturns {
			c.Flags = append(c.Flags, "returns")
		}
		if share(c.Discounts, r.subtotal) >= SignalDiscountShare || float64(c.MaxDiscountPc)/100 >= SignalDiscountSale {
			c.Flags = append(c.Flags, "discounts")
		}
		if c.FiscalPending > 0 {
			c.Flags = append(c.Flags, "fiscal")
		}
		srows, err := s.pool.Query(ctx, `
			SELECT sh.id, sh.number, st.name, d.name, sh.opened_at, sh.closed_at, sh.diff::text
			FROM pos_shifts sh JOIN stores st ON st.id = sh.store_id JOIN pos_devices d ON d.id = sh.device_id
			WHERE sh.network_id = $1 AND ($2 OR sh.store_id = ANY($3::uuid[])) AND ($4 = '' OR sh.store_id::text = $4)
			  AND sh.opened_by = $7 AND sh.opened_at < $6 AND (sh.closed_at IS NULL OR sh.closed_at >= $5)
			ORDER BY sh.opened_at DESC LIMIT 10`, p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID, out.From, out.To, c.EmployeeID)
		if err != nil {
			return out, err
		}
		c.Shifts, err = pgx.CollectRows(srows, pgx.RowToStructByPos[ShiftBrief])
		if err != nil {
			return out, err
		}
		out.Items = append(out.Items, c)
		out.Signals = append(out.Signals, signals(c, i18n.FromContext(ctx))...)
	}
	return out, nil
}

func share(part, whole string) float64 {
	w := money.D(whole)
	if w.Sign() <= 0 {
		return 0
	}
	f, _ := money.D(part).Div(w).Float64()
	return f
}

func short(name string) string {
	parts := []rune(name)
	for i, r := range parts {
		if r == ' ' && i+1 < len(parts) {
			return string(parts[:i+2]) + "."
		}
	}
	return name
}

func signals(c CashierStat, lang string) []Signal {
	var out []Signal
	for _, sh := range c.Shifts {
		if sh.Diff != nil && money.D(*sh.Diff).Sign() < 0 {
			id := sh.ID
			out = append(out, Signal{Kind: "shortage", EmployeeID: c.EmployeeID, ShiftID: &id,
				Text: fmt.Sprintf(i18n.Pick(lang, "Недостача %s сум в смене %s", "%[2]s smenasida %[1]s soʻm kamomad"), money.Group(money.D(*sh.Diff).Neg().Money()), short(c.FullName))})
		}
	}
	var last *string
	if len(c.Shifts) > 0 {
		last = &c.Shifts[0].ID
	}
	for _, f := range c.Flags {
		switch f {
		case "returns":
			out = append(out, Signal{Kind: f, EmployeeID: c.EmployeeID, ShiftID: last,
				Text: fmt.Sprintf(i18n.Pick(lang, "%d возвратов на %s сум — %s", "%d ta qaytarish, %s soʻm — %s"), c.ReturnsCount, money.Group(c.ReturnsTotal), short(c.FullName))})
		case "discounts":
			out = append(out, Signal{Kind: f, EmployeeID: c.EmployeeID, ShiftID: last,
				Text: fmt.Sprintf(i18n.Pick(lang, "Скидки %s сум, самая большая %d%% — %s", "Chegirmalar %s soʻm, eng kattasi %d%% — %s"), money.Group(c.Discounts), c.MaxDiscountPc, short(c.FullName))})
		case "fiscal":
			out = append(out, Signal{Kind: f, EmployeeID: c.EmployeeID, ShiftID: last,
				Text: fmt.Sprintf(i18n.Pick(lang, "%d непробитых чеков — %s", "%d ta chiqarilmagan chek — %s"), c.FiscalPending, short(c.FullName))})
		}
	}
	return out
}

// ---------------------------------------------------------- события смены

type ShiftEvent struct {
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"` // open, return, discount, cash_in, cash_out, close
	Title  string    `json:"title"`
	Note   string    `json:"note"`
	Amount *string   `json:"amount"`
}

// ShiftEvents — что важного было в смене: возвраты, крупные скидки, внесения
// и изъятия, открытие и закрытие. По времени.
func (s *Service) ShiftEvents(ctx context.Context, p *identity.Principal, id string) ([]ShiftEvent, error) {
	sh, err := s.GetShift(ctx, p, id)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT at, kind, title, note, amount FROM (
			SELECT cr.created_at AS at, 'return' AS kind, loc('Возврат ', 'Qaytarish ') || to_char(cr.total, 'FM999999999990') || loc(' · чек № ', ' · chek № ') || sl.number AS title,
			       CASE WHEN cr.reason <> '' THEN loc('Причина: «', 'Sabab: «') || cr.reason || '»' ELSE loc('без причины', 'sababsiz') END AS note, cr.total::text AS amount
			FROM customer_returns cr JOIN sales sl ON sl.id = cr.sale_id WHERE cr.shift_id = $1
			UNION ALL
			SELECT sold_at, 'discount', loc('Скидка ', 'Chegirma ') || round(discount / subtotal * 100) || loc('% на чек № ', '% · chek № ') || number,
			       loc('скидка ', 'chegirma ') || to_char(discount, 'FM999999999990') || loc(' сум', ' soʻm'), discount::text
			FROM sales WHERE shift_id = $1 AND subtotal > 0 AND discount / subtotal >= $2
			UNION ALL
			SELECT created_at, CASE kind WHEN 'in' THEN 'cash_in' ELSE 'cash_out' END,
			       CASE kind WHEN 'in' THEN loc('Внесение ', 'Kiritish ') ELSE loc('Изъятие ', 'Olish ') END || to_char(amount, 'FM999999999990'), reason, amount::text
			FROM pos_cash_moves WHERE shift_id = $1
		) ev ORDER BY at LIMIT 100`, id, SignalDiscountShare*2)
	if err != nil {
		return nil, err
	}
	lang := i18n.FromContext(ctx)
	out := []ShiftEvent{{At: sh.OpenedAt, Kind: "open", Title: i18n.Pick(lang, "Смена открыта", "Smena ochildi"),
		Note: i18n.Pick(lang, "размен "+money.Group(sh.OpeningCash)+" сум", "maydalik "+money.Group(sh.OpeningCash)+" soʻm")}}
	evs, err := pgx.CollectRows(rows, pgx.RowToStructByPos[ShiftEvent])
	if err != nil {
		return nil, err
	}
	for i := range evs {
		evs[i].Title = groupNumbers(evs[i].Title)
		evs[i].Note = groupNumbers(evs[i].Note)
	}
	out = append(out, evs...)
	if sh.ClosedAt != nil {
		ev := ShiftEvent{At: *sh.ClosedAt, Kind: "close", Title: i18n.Pick(lang, "Смена закрыта", "Smena yopildi"), Note: i18n.Pick(lang, "касса сходится", "kassa mos keladi")}
		if sh.Diff != nil {
			d := money.D(*sh.Diff)
			switch d.Sign() {
			case -1:
				ev.Title = i18n.Pick(lang, "Смена закрыта: недостача ", "Smena yopildi: kamomad ") + money.Group(d.Neg().Money())
			case 1:
				ev.Title = i18n.Pick(lang, "Смена закрыта: излишек ", "Smena yopildi: ortiqcha ") + money.Group(d.Money())
			}
			if d.Sign() != 0 {
				ev.Note = sh.DiffReason
				if ev.Note == "" {
					ev.Note = i18n.Pick(lang, "причину кассир не указал", "kassir sababini koʻrsatmagan")
				}
			}
			ev.Amount = sh.Diff
		}
		out = append(out, ev)
	}
	return out, nil
}

// groupNumbers — «Возврат 85000» → «Возврат 85 000» (числа от 4 цифр).
func groupNumbers(s string) string {
	r := []rune(s)
	var b []rune
	for i := 0; i < len(r); {
		if r[i] >= '0' && r[i] <= '9' && (i == 0 || r[i-1] == ' ') {
			j := i
			for j < len(r) && r[j] >= '0' && r[j] <= '9' {
				j++
			}
			// номер чека после «№ » не группируем
			if i >= 2 && r[i-2] == '№' {
				b = append(b, r[i:j]...)
			} else {
				b = append(b, []rune(money.Group(string(r[i:j])))...)
			}
			i = j
			continue
		}
		b = append(b, r[i])
		i++
	}
	return string(b)
}
