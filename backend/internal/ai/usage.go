package ai

import (
	"context"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// Расход ИИ (Figma «Админка · ИИ-сервис» → А3): токены каждого запроса
// и их стоимость по цене, которую указал супер-админ.

// Prices — цена за 1 млн токенов в валюте Currency; RateUZS — сумов за 1 единицу валюты.
type Prices struct {
	PriceIn  float64 `json:"price_in"`
	PriceOut float64 `json:"price_out"`
	Currency string  `json:"currency"`
	RateUZS  float64 `json:"rate_uzs"`
}

func (s *Service) prices(ctx context.Context) (Prices, error) {
	var p Prices
	err := s.pool.QueryRow(ctx, `SELECT price_in::float8, price_out::float8, price_currency, rate_uzs::float8 FROM ai_settings`).
		Scan(&p.PriceIn, &p.PriceOut, &p.Currency, &p.RateUZS)
	return p, err
}

// SavePrices — цена токенов. Новые запросы считаются по ней, старые не пересчитываются.
func (s *Service) SavePrices(ctx context.Context, adminID string, in Prices) (Prices, error) {
	if in.Currency == "" {
		in.Currency = "USD"
	}
	if in.Currency == "UZS" {
		in.RateUZS = 1
	}
	switch {
	case in.Currency != "USD" && in.Currency != "RUB" && in.Currency != "UZS":
		return Prices{}, apperr.Validation("currency: USD, RUB или UZS")
	case in.PriceIn < 0 || in.PriceOut < 0 || in.PriceIn > 1e7 || in.PriceOut > 1e7 || math.IsNaN(in.PriceIn) || math.IsNaN(in.PriceOut):
		return Prices{}, apperr.Validation("price: цена за 1 млн токенов — число от 0")
	case !(in.RateUZS > 0) || in.RateUZS > 1e7:
		return Prices{}, apperr.Validation("rate_uzs: курс — сколько сумов в 1 единице валюты")
	}
	_, err := s.pool.Exec(ctx, `UPDATE ai_settings SET price_in = $1, price_out = $2, price_currency = $3, rate_uzs = $4, updated_by = $5, updated_at = now()`,
		in.PriceIn, in.PriceOut, in.Currency, in.RateUZS, adminID)
	if err != nil {
		return Prices{}, err
	}
	return s.prices(ctx)
}

// UsageRecord — один запрос к ИИ.
type UsageRecord struct {
	Kind       string // invoice, test
	NetworkID  *string
	StoreID    *string
	EmployeeID *string
	ScanID     *string
	Provider   string
	Model      string
	Usage      Usage
	OK         bool
}

// Record — записать расход; стоимость — по текущей цене.
func (s *Service) Record(ctx context.Context, r UsageRecord) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO ai_usage (kind, network_id, store_id, employee_id, scan_id, provider, model, input_tokens, output_tokens, ok,
		                      cost, currency, cost_uzs)
		SELECT $1, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6, $7, $8::int, $9::int, $10,
		       ($8::int * p.price_in + $9::int * p.price_out) / 1000000, p.price_currency,
		       round(($8::int * p.price_in + $9::int * p.price_out) / 1000000 * p.rate_uzs, 2)
		FROM ai_settings p`,
		r.Kind, r.NetworkID, r.StoreID, r.EmployeeID, r.ScanID, r.Provider, r.Model, max(r.Usage.Input, 0), max(r.Usage.Output, 0), r.OK)
	return err
}

// UsageFilter — период [From, To) и разрез: network, store, employee.
type UsageFilter struct {
	From      time.Time
	To        time.Time
	Group     string
	NetworkID string
}

type UsageTotals struct {
	Requests int     `json:"requests"`
	Invoices int     `json:"invoices"`
	Errors   int     `json:"errors"`
	Tests    int     `json:"tests"`
	Input    int64   `json:"input_tokens"`
	Output   int64   `json:"output_tokens"`
	CostUZS  float64 `json:"cost_uzs"`
}

type UsageDay struct {
	Date     string  `json:"date"`
	Requests int     `json:"requests"`
	Input    int64   `json:"input_tokens"`
	Output   int64   `json:"output_tokens"`
	CostUZS  float64 `json:"cost_uzs"`
}

// UsageItem — строка «Кто сколько использует». ID пустой — проверки подключения.
type UsageItem struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Sub       string  `json:"sub"`
	NetworkID string  `json:"network_id"`
	Stores    int     `json:"stores"`
	Employees int     `json:"employees"`
	Requests  int     `json:"requests"`
	Invoices  int     `json:"invoices"`
	Errors    int     `json:"errors"`
	Input     int64   `json:"input_tokens"`
	Output    int64   `json:"output_tokens"`
	CostUZS   float64 `json:"cost_uzs"`
	Share     float64 `json:"share"`
}

type UsageReport struct {
	From   time.Time   `json:"from"`
	To     time.Time   `json:"to"`
	Totals UsageTotals `json:"totals"`
	Days   []UsageDay  `json:"days"`
	Items  []UsageItem `json:"items"`
	Prices Prices      `json:"prices"`
	Model  string      `json:"model"`
}

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

// Usage — отчёт о расходе за период.
func (s *Service) Usage(ctx context.Context, f UsageFilter) (UsageReport, error) {
	now := s.now().In(tashkent)
	if f.From.IsZero() {
		f.From = time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, tashkent)
	}
	if f.To.IsZero() || !f.To.After(f.From) {
		f.To = time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent).AddDate(0, 0, 1)
	}
	if f.To.Sub(f.From) > 400*24*time.Hour {
		return UsageReport{}, apperr.Validation("period: не больше года")
	}
	rep := UsageReport{From: f.From, To: f.To, Days: []UsageDay{}, Items: []UsageItem{}}
	var err error
	if rep.Prices, err = s.prices(ctx); err != nil {
		return rep, err
	}
	if err = s.pool.QueryRow(ctx, `SELECT model FROM ai_settings`).Scan(&rep.Model); err != nil {
		return rep, err
	}
	var nf *string
	if f.NetworkID != "" {
		nf = &f.NetworkID
	}
	const where = `u.at >= $1 AND u.at < $2 AND ($3::uuid IS NULL OR u.network_id = $3)`
	t := &rep.Totals
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, (count(*) FILTER (WHERE u.kind = 'invoice'))::int, (count(*) FILTER (WHERE NOT u.ok))::int,
		       (count(*) FILTER (WHERE u.kind = 'test'))::int,
		       COALESCE(sum(u.input_tokens), 0)::int8, COALESCE(sum(u.output_tokens), 0)::int8, COALESCE(sum(u.cost_uzs), 0)::float8
		FROM ai_usage u WHERE `+where, f.From, f.To, nf).
		Scan(&t.Requests, &t.Invoices, &t.Errors, &t.Tests, &t.Input, &t.Output, &t.CostUZS)
	if err != nil {
		return rep, err
	}

	rows, err := s.pool.Query(ctx, `
		SELECT to_char(d, 'YYYY-MM-DD'), count(u.id)::int, COALESCE(sum(u.input_tokens), 0)::int8,
		       COALESCE(sum(u.output_tokens), 0)::int8, COALESCE(sum(u.cost_uzs), 0)::float8
		FROM generate_series(($1::timestamptz AT TIME ZONE 'Asia/Tashkent')::date,
		                     (($2::timestamptz - interval '1 second') AT TIME ZONE 'Asia/Tashkent')::date, interval '1 day') d
		LEFT JOIN ai_usage u ON (u.at AT TIME ZONE 'Asia/Tashkent')::date = d::date
		     AND u.at >= $1 AND u.at < $2 AND ($3::uuid IS NULL OR u.network_id = $3)
		GROUP BY d ORDER BY d`, f.From, f.To, nf)
	if err != nil {
		return rep, err
	}
	rep.Days, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (UsageDay, error) {
		var d UsageDay
		return d, r.Scan(&d.Date, &d.Requests, &d.Input, &d.Output, &d.CostUZS)
	})
	if err != nil {
		return rep, err
	}

	var key, name, sub string
	switch f.Group {
	case "", "network":
		key = "u.network_id"
		name = "COALESCE(n.name, 'Проверки подключения')"
		sub = "CASE WHEN u.network_id IS NULL THEN 'Супер-админ' ELSE '' END"
	case "store":
		key = "u.store_id"
		name = "COALESCE(st.name, 'Проверки подключения')"
		sub = "COALESCE(n.name, 'Супер-админ')"
	case "employee":
		key = "u.employee_id"
		name = "COALESCE(e.full_name, 'Проверки подключения')"
		sub = "COALESCE(n.name, 'Супер-админ')"
	default:
		return rep, apperr.Validation("group: network, store или employee")
	}
	rows, err = s.pool.Query(ctx, `
		SELECT COALESCE(`+key+`::text, ''), min(`+name+`), min(`+sub+`), COALESCE(min(u.network_id::text), ''),
		       count(DISTINCT u.store_id)::int, count(DISTINCT u.employee_id)::int,
		       count(*)::int, (count(*) FILTER (WHERE u.kind = 'invoice'))::int, (count(*) FILTER (WHERE NOT u.ok))::int,
		       sum(u.input_tokens)::int8, sum(u.output_tokens)::int8, sum(u.cost_uzs)::float8
		FROM ai_usage u
		LEFT JOIN networks n ON n.id = u.network_id
		LEFT JOIN stores st ON st.id = u.store_id
		LEFT JOIN employees e ON e.id = u.employee_id
		WHERE `+where+`
		GROUP BY `+key+`
		ORDER BY sum(u.cost_uzs) DESC, sum(u.input_tokens + u.output_tokens) DESC`, f.From, f.To, nf)
	if err != nil {
		return rep, err
	}
	rep.Items, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (UsageItem, error) {
		var it UsageItem
		err := r.Scan(&it.ID, &it.Name, &it.Sub, &it.NetworkID, &it.Stores, &it.Employees, &it.Requests, &it.Invoices, &it.Errors,
			&it.Input, &it.Output, &it.CostUZS)
		return it, err
	})
	if err != nil {
		return rep, err
	}
	// Доля — по деньгам; пока цена не указана — по токенам.
	totalTokens := float64(t.Input + t.Output)
	for i := range rep.Items {
		it := &rep.Items[i]
		switch {
		case t.CostUZS > 0:
			it.Share = math.Round(it.CostUZS/t.CostUZS*1000) / 10
		case totalTokens > 0:
			it.Share = math.Round(float64(it.Input+it.Output)/totalTokens*1000) / 10
		}
	}
	return rep, nil
}
