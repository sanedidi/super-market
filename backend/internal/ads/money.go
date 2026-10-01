package ads

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// --------------------------------------------------------- доля сетей

// sharesSQL — доля сетей с рекламы за дни [$1, $2]: оплата бренда за эти
// дни (за период — пропорционально дням, за 1000 показов — по оплачиваемым
// показам) делится между сетями по их оплачиваемым показам и умножается на
// процент сетей. Возвращает network_id, amount, pct, views.
const sharesSQL = `
	WITH m AS (SELECT $1::date AS p0, $2::date AS p9),
	c AS (SELECT c.id, c.pricing, c.price, b.sd, b.ed FROM ad_campaigns c CROSS JOIN LATERAL (SELECT ` + dayBounds + `) b, m
	      WHERE b.sd <= m.p9 AND b.ed >= m.p0),
	v AS (SELECT v.campaign_id, s.network_id, count(*) AS n FROM ad_views v JOIN stores s ON s.id = v.store_id, m
	      WHERE v.day BETWEEN m.p0 AND m.p9 GROUP BY 1, 2),
	t AS (SELECT campaign_id, sum(n) AS n FROM v GROUP BY 1),
	rev AS (SELECT c.id, t.n AS total,
	               CASE WHEN c.pricing = 'period' THEN c.price * GREATEST(0, LEAST(c.ed, m.p9) - GREATEST(c.sd, m.p0) + 1) / (c.ed - c.sd + 1)
	                    ELSE c.price * COALESCE(t.n, 0) / 1000 END AS amount
	        FROM c CROSS JOIN m LEFT JOIN t ON t.campaign_id = c.id)
	SELECT v.network_id, round(sum(r.amount * v.n / r.total) * st.network_share_pct / 100, 2), st.network_share_pct, sum(v.n)::bigint
	FROM rev r JOIN v ON v.campaign_id = r.id CROSS JOIN ad_settings st
	WHERE r.total > 0 AND ($3 = '' OR v.network_id::text = $3)
	GROUP BY v.network_id, st.network_share_pct`

// ComputeShares записывает доли сетей за месяц period (первое число).
// Повторный вызов ничего не меняет.
func ComputeShares(ctx context.Context, q db.Querier, period time.Time) error {
	last := period.AddDate(0, 1, -1)
	_, err := q.Exec(ctx, `INSERT INTO network_ad_shares (network_id, period, amount, pct, views)
		SELECT network_id, $1::date, x.round, x.network_share_pct, x.sum FROM (`+sharesSQL+`) x
		WHERE x.round > 0
		ON CONFLICT (network_id, period) DO NOTHING`, period, last, "")
	return err
}

// ShareEstimate — доля сети за дни [from, to] (текущий месяц до сегодня).
func ShareEstimate(ctx context.Context, q db.Querier, networkID string, from, to time.Time) (amount string, views int64, err error) {
	var pct string
	err = q.QueryRow(ctx, sharesSQL, from, to, networkID).Scan(new(string), &amount, &pct, &views)
	if errors.Is(err, pgx.ErrNoRows) {
		return "0.00", 0, nil
	}
	return amount, views, err
}

// --------------------------------------------------------- счета брендам

type Invoice struct {
	ID             string     `json:"id"`
	Number         int64      `json:"number"`
	CampaignID     string     `json:"campaign_id"`
	CampaignTitle  string     `json:"campaign_title"`
	BrandName      string     `json:"brand_name"`
	AdvertiserID   string     `json:"advertiser_id"`
	AdvertiserName string     `json:"advertiser_name"`
	PeriodFrom     string     `json:"period_from"`
	PeriodTo       string     `json:"period_to"`
	Views          int64      `json:"views"`
	Amount         string     `json:"amount"`
	Status         string     `json:"status"`
	PaidAt         *time.Time `json:"paid_at"`
	ActNumber      *int64     `json:"act_number"`
	ActDate        *string    `json:"act_date"`
	Subject        string     `json:"subject"`
	CreatedAt      time.Time  `json:"created_at"`
}

const invoiceSelect = `
	SELECT i.id, i.number, c.id, c.title, br.name, a.id, a.name, to_char(i.period_from, 'YYYY-MM-DD'), to_char(i.period_to, 'YYYY-MM-DD'),
	       i.views, i.amount::text, i.status, i.paid_at, i.act_number, to_char(i.act_date, 'YYYY-MM-DD'),
	       'Размещение рекламных материалов за ' || to_char(i.period_from, 'DD.MM.YYYY') || '–' || to_char(i.period_to, 'DD.MM.YYYY'),
	       i.created_at
	FROM ad_invoices i JOIN ad_campaigns c ON c.id = i.campaign_id JOIN brands br ON br.id = c.brand_id
	JOIN ad_advertisers a ON a.id = c.advertiser_id`

func (s *Service) Invoices(ctx context.Context, campaignID, status string, page httpx.Page) ([]Invoice, error) {
	rows, err := s.pool.Query(ctx, invoiceSelect+` WHERE ($1 = '' OR c.id::text = $1) AND ($2 = '' OR i.status = $2)
		ORDER BY i.number DESC LIMIT $3 OFFSET $4`, campaignID, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Invoice])
}

func (s *Service) invoice(ctx context.Context, id string) (Invoice, error) {
	if !httpx.IsUUID(id) {
		return Invoice{}, apperr.NotFound("счёт не найден")
	}
	rows, err := s.pool.Query(ctx, invoiceSelect+` WHERE i.id = $1`, id)
	if err != nil {
		return Invoice{}, err
	}
	inv, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Invoice])
	if errors.Is(err, pgx.ErrNoRows) {
		return inv, apperr.NotFound("счёт не найден")
	}
	return inv, err
}

// Estimate — сколько бренд должен по кампании за дни [from, to].
type Estimate struct {
	PeriodFrom string `json:"period_from"`
	PeriodTo   string `json:"period_to"`
	Views      int64  `json:"views"`
	Amount     string `json:"amount"`
}

func parseDay(v string) (time.Time, error) {
	t, err := time.Parse("2006-01-02", v)
	if err != nil {
		return t, apperr.Validation("даты: формат YYYY-MM-DD")
	}
	return t, nil
}

func (s *Service) Estimate(ctx context.Context, campaignID, from, to string) (Estimate, error) {
	if !httpx.IsUUID(campaignID) {
		return Estimate{}, apperr.NotFound("кампания не найдена")
	}
	f, err := parseDay(from)
	if err != nil {
		return Estimate{}, err
	}
	t, err := parseDay(to)
	if err != nil {
		return Estimate{}, err
	}
	if t.Before(f) {
		return Estimate{}, apperr.Validation("даты: конец раньше начала")
	}
	out := Estimate{PeriodFrom: from, PeriodTo: to}
	err = s.pool.QueryRow(ctx, `
		SELECT bv.n, CASE WHEN c.pricing = 'period'
		                  THEN round(c.price * GREATEST(0, LEAST(b.ed, $3::date) - GREATEST(b.sd, $2::date) + 1) / (b.ed - b.sd + 1), 2)
		                  ELSE round(c.price * bv.n / 1000, 2) END::text
		FROM ad_campaigns c CROSS JOIN LATERAL (SELECT `+dayBounds+`) b
		CROSS JOIN LATERAL (SELECT count(*) AS n FROM ad_views v WHERE v.campaign_id = c.id AND v.day BETWEEN $2::date AND $3::date) bv
		WHERE c.id = $1`, campaignID, f, t).Scan(&out.Views, &out.Amount)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("кампания не найдена")
	}
	return out, err
}

type InvoiceInput struct {
	CampaignID string        `json:"campaign_id"`
	PeriodFrom string        `json:"period_from"`
	PeriodTo   string        `json:"period_to"`
	Amount     *money.Amount `json:"amount"` // пусто — по расчёту
}

// CreateInvoice выставляет бренду счёт за период кампании.
func (s *Service) CreateInvoice(ctx context.Context, in InvoiceInput) (Invoice, error) {
	est, err := s.Estimate(ctx, in.CampaignID, in.PeriodFrom, in.PeriodTo)
	if err != nil {
		return Invoice{}, err
	}
	amount := est.Amount
	if in.Amount != nil {
		amount = string(*in.Amount)
	}
	if money.D(amount).Sign() <= 0 {
		return Invoice{}, apperr.Validation("amount: сумма счёта больше нуля")
	}
	var id string
	if err := s.pool.QueryRow(ctx, `INSERT INTO ad_invoices (campaign_id, period_from, period_to, views, amount)
		VALUES ($1, $2, $3, $4, $5::numeric) RETURNING id`, in.CampaignID, in.PeriodFrom, in.PeriodTo, est.Views, amount).Scan(&id); err != nil {
		return Invoice{}, err
	}
	return s.invoice(ctx, id)
}

// SetInvoiceStatus — счёт оплачен (появляется акт) или отменён.
func (s *Service) SetInvoiceStatus(ctx context.Context, id, status string) (Invoice, error) {
	inv, err := s.invoice(ctx, id)
	if err != nil {
		return inv, err
	}
	if inv.Status != "unpaid" {
		return inv, apperr.Conflict("not_unpaid", "счёт уже оплачен или отменён")
	}
	switch status {
	case "paid":
		_, err = s.pool.Exec(ctx, `UPDATE ad_invoices SET status = 'paid', paid_at = now(), act_number = nextval('ad_act_number'),
			act_date = (now() AT TIME ZONE 'Asia/Tashkent')::date WHERE id = $1`, id)
	case "cancelled":
		_, err = s.pool.Exec(ctx, `UPDATE ad_invoices SET status = 'cancelled' WHERE id = $1`, id)
	}
	if err != nil {
		return inv, err
	}
	return s.invoice(ctx, id)
}

// Document — данные для печатной формы счёта или акта: исполнитель
// (платформа), заказчик (бренд), предмет и сумма.
type Document struct {
	Kind       string     `json:"kind"` // invoice | act
	Number     int64      `json:"number"`
	Date       string     `json:"date"`
	Invoice    Invoice    `json:"invoice"`
	Platform   Settings   `json:"platform"`
	Advertiser Advertiser `json:"advertiser"`
	Subject    string     `json:"subject"`
}

func (s *Service) Document(ctx context.Context, id, kind string) (Document, error) {
	inv, err := s.invoice(ctx, id)
	if err != nil {
		return Document{}, err
	}
	doc := Document{Kind: kind, Invoice: inv, Subject: inv.Subject}
	switch kind {
	case "invoice":
		doc.Number, doc.Date = inv.Number, inv.CreatedAt.In(tashkent).Format("2006-01-02")
	case "act":
		if inv.ActNumber == nil || inv.ActDate == nil {
			return Document{}, apperr.Conflict("no_act", "акт появится после оплаты счёта")
		}
		doc.Number, doc.Date = *inv.ActNumber, *inv.ActDate
	default:
		return Document{}, apperr.Validation("kind: invoice или act")
	}
	if doc.Platform, err = GetSettings(ctx, s.pool); err != nil {
		return doc, err
	}
	if doc.Advertiser, err = s.advertiser(ctx, s.pool, inv.AdvertiserID); err != nil {
		return doc, err
	}
	return doc, nil
}

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

// MonthStart — первое число месяца t по Ташкенту.
func MonthStart(t time.Time) time.Time {
	t = t.In(tashkent)
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
}

func periodLabel(p time.Time) string {
	months := []string{"январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"}
	return fmt.Sprintf("%s %d", months[p.Month()-1], p.Year())
}
