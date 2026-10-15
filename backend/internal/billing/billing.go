// Package billing — подписка сетей (тарифы, счета, оплата с баланса) и
// баланс платформы: деньги онлайн-заказов, вывод раз в неделю.
//
// Баланс сети — сумма записей balance_entries: оплаченный заказ даёт запись
// pending, доставленный — available. Вывод и оплата подписки — отрицательные
// записи available.
package billing

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ads"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Tashkent — часовой пояс расчётных периодов.
var Tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

// PayoutInterval — вывод не чаще раза в неделю.
const PayoutInterval = 7 * 24 * time.Hour

type Service struct {
	pool   *pgxpool.Pool
	notify *notify.Notifier
	log    *slog.Logger
	now    func() time.Time
	// planChanged — супер-админ сменил сети тариф (сбросить кэш витрин).
	planChanged func()
}

// OnPlanChange — что сделать, когда супер-админ меняет сети тариф.
func (s *Service) OnPlanChange(fn func()) { s.planChanged = fn }

func NewService(pool *pgxpool.Pool, n *notify.Notifier, log *slog.Logger) *Service {
	return &Service{pool: pool, notify: n, log: log.With("component", "billing"), now: time.Now}
}

// ------------------------------------------------------------- настройки

type Settings struct {
	GraceDays         int  `json:"grace_days"`
	AutoChargeBalance bool `json:"auto_charge_balance"`
	// Пробный период новых сетей: тариф и сколько дней (0 — без пробного).
	TrialPlan string `json:"trial_plan"`
	TrialDays int    `json:"trial_days"`
	// Агенты («SM Агент»): тариф новых агентов и бесплатный срок на нём.
	AgentPlan      string    `json:"agent_plan"`
	AgentTrialDays int       `json:"agent_trial_days"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type SettingsInput struct {
	GraceDays         *int    `json:"grace_days"`
	AutoChargeBalance *bool   `json:"auto_charge_balance"`
	TrialPlan         *string `json:"trial_plan"`
	TrialDays         *int    `json:"trial_days"`
	AgentPlan         *string `json:"agent_plan"`
	AgentTrialDays    *int    `json:"agent_trial_days"`
}

func (s *Service) GetSettings(ctx context.Context) (Settings, error) {
	var st Settings
	err := s.pool.QueryRow(ctx, `SELECT grace_days, auto_charge_balance, trial_plan, trial_days, agent_plan, agent_trial_days, updated_at
		FROM billing_settings WHERE id = 1`).
		Scan(&st.GraceDays, &st.AutoChargeBalance, &st.TrialPlan, &st.TrialDays, &st.AgentPlan, &st.AgentTrialDays, &st.UpdatedAt)
	return st, err
}

func (s *Service) SaveSettings(ctx context.Context, in SettingsInput) (Settings, error) {
	if in.GraceDays != nil && (*in.GraceDays < 0 || *in.GraceDays > 60) {
		return Settings{}, apperr.Validation("grace_days: от 0 до 60 дней").Uz("grace_days: 0 dan 60 kungacha")
	}
	if in.TrialDays != nil && (*in.TrialDays < 0 || *in.TrialDays > 365) {
		return Settings{}, apperr.Validation("trial_days: от 0 до 365 дней").Uz("trial_days: 0 dan 365 kungacha")
	}
	if in.TrialPlan != nil {
		p, err := plans.Get(ctx, s.pool, *in.TrialPlan)
		if err != nil {
			return Settings{}, apperr.Validation("trial_plan: тариф не найден").Uz("trial_plan: tarif topilmadi")
		}
		if !p.IsActive {
			return Settings{}, apperr.Validation("trial_plan: тариф в архиве").Uz("trial_plan: tarif arxivda")
		}
		if p.Audience != plans.AudienceStore {
			return Settings{}, apperr.Validation("trial_plan: нужен тариф магазинов").Uz("trial_plan: doʻkonlar tarifi kerak")
		}
	}
	if in.AgentTrialDays != nil && (*in.AgentTrialDays < 0 || *in.AgentTrialDays > 365) {
		return Settings{}, apperr.Validation("agent_trial_days: от 0 до 365 дней").Uz("agent_trial_days: 0 dan 365 kungacha")
	}
	if in.AgentPlan != nil {
		p, err := plans.Get(ctx, s.pool, *in.AgentPlan)
		if err != nil {
			return Settings{}, apperr.Validation("agent_plan: тариф не найден").Uz("agent_plan: tarif topilmadi")
		}
		if !p.IsActive {
			return Settings{}, apperr.Validation("agent_plan: тариф в архиве").Uz("agent_plan: tarif arxivda")
		}
		if p.Audience != plans.AudienceAgent {
			return Settings{}, apperr.Validation("agent_plan: нужен тариф агентов").Uz("agent_plan: agentlar tarifi kerak")
		}
	}
	if _, err := s.pool.Exec(ctx, `UPDATE billing_settings SET
		grace_days = COALESCE($1, grace_days), auto_charge_balance = COALESCE($2, auto_charge_balance),
		trial_plan = COALESCE($3, trial_plan), trial_days = COALESCE($4, trial_days),
		agent_plan = COALESCE($5, agent_plan), agent_trial_days = COALESCE($6, agent_trial_days), updated_at = now()
		WHERE id = 1`, in.GraceDays, in.AutoChargeBalance, in.TrialPlan, in.TrialDays, in.AgentPlan, in.AgentTrialDays); err != nil {
		return Settings{}, err
	}
	return s.GetSettings(ctx)
}

// ---------------------------------------------------------- сети и цены

// priceSQL — цена за магазин для сети n: индивидуальная или по тарифу.
// Пока идёт пробный период (и пробный тариф выше выбранного), тариф не
// оплачивается. У агента пробный период — просто бесплатный срок.
const priceSQL = `CASE WHEN n.plan_trial_until >= $period::date AND n.kind = 'distributor' THEN 0
	WHEN n.plan_trial_until >= $period::date
	          AND (SELECT tp.sort FROM plans tp JOIN billing_settings bs ON bs.trial_plan = tp.key)
	            > (SELECT cp.sort FROM plans cp WHERE cp.key = n.plan_key) THEN 0
	ELSE COALESCE(n.custom_price_uzs, (SELECT pl.price_uzs FROM plans pl WHERE pl.key = n.plan_key), 0) END`

const storesCountSQL = `(SELECT count(*)::int FROM stores s WHERE s.network_id = n.id AND s.status = 'active')`

// Tashkent-дата «сегодня» в SQL.
const todaySQL = `(now() AT TIME ZONE 'Asia/Tashkent')::date`

// price — priceSQL на дату (SQL-выражение).
func price(period string) string { return strings.ReplaceAll(priceSQL, "$period", period) }

type NetworkBilling struct {
	NetworkID   string `json:"network_id"`
	NetworkName string `json:"network_name"`
	Kind        string `json:"kind"`
	Status      string `json:"status"`
	StoresCount int    `json:"stores_count"`
	// Тариф: выбранный и действующий сейчас (пробный, если идёт).
	PlanKey          string  `json:"plan_key"`
	PlanName         string  `json:"plan_name"`
	EffectivePlanKey string  `json:"effective_plan_key"`
	TrialUntil       *string `json:"trial_until"`
	CustomPriceUZS   *string `json:"custom_price_uzs"`
	// Цена за магазин в месяц и всего в месяц, сум (пробный — 0).
	PricePerStore string `json:"price_per_store"`
	MonthlyUZS    string `json:"monthly_uzs"`
	BillingFrom   string `json:"billing_from"`
	Available     string `json:"balance_available"`
	Pending       string `json:"balance_pending"`
	UnpaidUZS     string `json:"unpaid_uzs"`
	Overdue       bool   `json:"overdue"`
}

var networkBillingSQL = `
	SELECT n.id, n.name, n.kind, n.status, c.cnt, n.plan_key, loc(pl.name, pl.name_uz), network_plan(n.id),
	       to_char(n.plan_trial_until, 'YYYY-MM-DD'), n.custom_price_uzs::text, p.price::numeric(18,2)::text,
	       (p.price * c.cnt)::numeric(18,2)::text, to_char(n.billing_from, 'YYYY-MM-DD'),
	       COALESCE((SELECT sum(amount) FROM balance_entries b WHERE b.network_id = n.id AND b.status = 'available'), 0)::numeric(18,2)::text,
	       COALESCE((SELECT sum(amount) FROM balance_entries b WHERE b.network_id = n.id AND b.status = 'pending'), 0)::numeric(18,2)::text,
	       COALESCE((SELECT sum(amount_uzs) FROM subscription_invoices i WHERE i.network_id = n.id AND i.status = 'unpaid'), 0)::numeric(18,2)::text,
	       EXISTS (SELECT 1 FROM subscription_invoices i WHERE i.network_id = n.id AND i.status = 'unpaid' AND i.due_date < ` + todaySQL + `) AS overdue
	FROM networks n
	JOIN plans pl ON pl.key = n.plan_key
	CROSS JOIN LATERAL (SELECT ` + storesCountSQL + ` AS cnt) c
	CROSS JOIN LATERAL (SELECT ` + price(todaySQL) + ` AS price) p`

func scanNetworkBilling(row pgx.CollectableRow) (NetworkBilling, error) {
	var b NetworkBilling
	err := row.Scan(&b.NetworkID, &b.NetworkName, &b.Kind, &b.Status, &b.StoresCount, &b.PlanKey, &b.PlanName, &b.EffectivePlanKey,
		&b.TrialUntil, &b.CustomPriceUZS, &b.PricePerStore, &b.MonthlyUZS, &b.BillingFrom, &b.Available, &b.Pending, &b.UnpaidUZS, &b.Overdue)
	return b, err
}

func (s *Service) ListNetworks(ctx context.Context, overdueOnly bool, page httpx.Page) ([]NetworkBilling, error) {
	rows, err := s.pool.Query(ctx, `SELECT * FROM (`+networkBillingSQL+`) x
		WHERE NOT $1 OR x.overdue ORDER BY x.name, x.id LIMIT $2 OFFSET $3`, overdueOnly, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanNetworkBilling)
}

func (s *Service) NetworkBilling(ctx context.Context, networkID string) (NetworkBilling, error) {
	if !httpx.IsUUID(networkID) {
		return NetworkBilling{}, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	rows, err := s.pool.Query(ctx, networkBillingSQL+` WHERE n.id = $1`, networkID)
	if err != nil {
		return NetworkBilling{}, err
	}
	b, err := pgx.CollectExactlyOneRow(rows, scanNetworkBilling)
	if errors.Is(err, pgx.ErrNoRows) {
		return b, apperr.NotFound("сеть не найдена").Uz("tarmoq topilmadi")
	}
	return b, err
}

// NetworkBillingInput — супер-админ: тариф сети, пробный период,
// индивидуальная цена и начало оплаты.
type NetworkBillingInput struct {
	plans.AssignInput
	BillingFrom *string `json:"billing_from"` // YYYY-MM-DD, первое число месяца
}

// SaveNetworkBilling — тариф, цена и начало оплаты (бесплатный период) сети.
func (s *Service) SaveNetworkBilling(ctx context.Context, networkID string, in NetworkBillingInput) (NetworkBilling, error) {
	if _, err := s.NetworkBilling(ctx, networkID); err != nil {
		return NetworkBilling{}, err
	}
	var from *time.Time
	if in.BillingFrom != nil {
		t, err := time.Parse("2006-01-02", *in.BillingFrom)
		if err != nil {
			return NetworkBilling{}, apperr.Validation("billing_from: дата YYYY-MM-DD").Uz("billing_from: sana YYYY-MM-DD koʻrinishida boʻlsin")
		}
		t = time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
		from = &t
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := plans.Assign(ctx, tx, networkID, in.AssignInput); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE networks SET billing_from = COALESCE($2::date, billing_from) WHERE id = $1`, networkID, from)
		return err
	})
	if err != nil {
		return NetworkBilling{}, err
	}
	if s.planChanged != nil && (in.PlanKey != nil || in.TrialUntil != nil || in.ClearTrial) {
		s.planChanged()
	}
	return s.NetworkBilling(ctx, networkID)
}

// -------------------------------------------------------------- счета

type Invoice struct {
	ID            string `json:"id"`
	NetworkID     string `json:"network_id"`
	NetworkName   string `json:"network_name"`
	Period        string `json:"period"`
	StoresCount   int    `json:"stores_count"`
	PricePerStore string `json:"price_per_store"`
	// Валюта price_per_store: UZS — счета по тарифам; USD — старые счета
	// (тогда amount_usd и rate заполнены).
	Currency  string     `json:"currency"`
	AmountUSD *string    `json:"amount_usd"`
	Rate      *string    `json:"rate"`
	AmountUZS string     `json:"amount_uzs"`
	PlanKey   *string    `json:"plan_key"`
	PlanName  string     `json:"plan_name"`
	Status    string     `json:"status"`
	DueDate   string     `json:"due_date"`
	Overdue   bool       `json:"overdue"`
	PaidVia   *string    `json:"paid_via"`
	PaidAt    *time.Time `json:"paid_at"`
	Note      string     `json:"note"`
	CreatedAt time.Time  `json:"created_at"`
	// Старые счета: плата за тариф витрины (входит в amount_uzs).
	ShowcasePlan *string `json:"showcase_plan"`
	ShowcaseUZS  string  `json:"showcase_uzs"`
	// Зачтено из доли сети с рекламы брендов (уже вычтено из amount_uzs).
	AdShareUZS string `json:"ad_share_uzs"`
}

const invoiceSelect = `
	SELECT i.id, i.network_id, n.name, to_char(i.period, 'YYYY-MM'), i.stores_count, i.price_per_store::text,
	       i.currency, i.amount_usd::text, i.rate::text, i.amount_uzs::text, i.plan_key, i.plan_name, i.status, to_char(i.due_date, 'YYYY-MM-DD'),
	       i.status = 'unpaid' AND i.due_date < ` + todaySQL + `, i.paid_via, i.paid_at, i.note, i.created_at,
	       i.showcase_plan, i.showcase_uzs::text, i.ad_share_uzs::text
	FROM subscription_invoices i JOIN networks n ON n.id = i.network_id`

func (s *Service) ListInvoices(ctx context.Context, networkID, status string, page httpx.Page) ([]Invoice, error) {
	if status != "" && status != "unpaid" && status != "paid" && status != "cancelled" && status != "overdue" {
		return nil, apperr.Validation("status: unpaid, paid, cancelled или overdue").Uz("status: unpaid, paid, cancelled yoki overdue")
	}
	rows, err := s.pool.Query(ctx, invoiceSelect+`
		WHERE ($1 = '' OR i.network_id::text = $1)
		  AND (CASE WHEN $2 = 'overdue' THEN i.status = 'unpaid' AND i.due_date < `+todaySQL+`
		            ELSE $2 = '' OR i.status = $2 END)
		ORDER BY i.period DESC, n.name, i.id LIMIT $3 OFFSET $4`, networkID, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Invoice])
}

func (s *Service) getInvoice(ctx context.Context, q db.Querier, id string) (Invoice, error) {
	if !httpx.IsUUID(id) {
		return Invoice{}, apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
	}
	rows, err := q.Query(ctx, invoiceSelect+` WHERE i.id = $1`, id)
	if err != nil {
		return Invoice{}, err
	}
	inv, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Invoice])
	if errors.Is(err, pgx.ErrNoRows) {
		return inv, apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
	}
	return inv, err
}

// PeriodOf — первое число месяца (по Ташкенту), в котором находится t.
func PeriodOf(t time.Time) time.Time {
	t = t.In(Tashkent)
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// GenerateInvoices выставляет счета за месяц, в котором находится now, всем
// активным сетям с магазинами, у которых наступил billing_from. Повторный
// вызов ничего не дублирует. Возвращает число новых счетов.
func (s *Service) GenerateInvoices(ctx context.Context, now time.Time) (int, error) {
	period := PeriodOf(now)
	prev := period.AddDate(0, -1, 0)
	// Доля сетей с рекламы за прошлый месяц — до счетов: она их уменьшает.
	if err := ads.ComputeShares(ctx, s.pool, prev); err != nil {
		return 0, err
	}
	rows, err := s.pool.Query(ctx, `
		INSERT INTO subscription_invoices (network_id, period, stores_count, price_per_store, currency, amount_uzs, due_date,
		                                   plan_key, plan_name, ad_share_uzs)
		SELECT n.id, $1::date, c.cnt, p.price, 'UZS', x.base - x.ad, $1::date + bs.grace_days, n.plan_key, pl.name, x.ad
		FROM networks n
		JOIN plans pl ON pl.key = n.plan_key
		CROSS JOIN billing_settings bs
		CROSS JOIN ad_settings ast
		CROSS JOIN LATERAL (SELECT `+storesCountSQL+` AS cnt) c
		CROSS JOIN LATERAL (SELECT `+price("$1")+` AS price) p
		-- Доля с рекламы за прошлый месяц уменьшает счёт (не больше суммы счёта).
		LEFT JOIN network_ad_shares sh ON sh.network_id = n.id AND sh.period = $2::date AND sh.settled_at IS NULL
		CROSS JOIN LATERAL (SELECT round(p.price * c.cnt, 2) AS base) b0
		CROSS JOIN LATERAL (SELECT b0.base,
		       CASE WHEN ast.share_to_subscription THEN LEAST(COALESCE(sh.amount, 0), b0.base) ELSE 0 END AS ad) x
		WHERE n.status = 'active' AND n.billing_from <= $1::date AND c.cnt > 0 AND p.price > 0
		ON CONFLICT (network_id, period) DO NOTHING
		RETURNING network_id, plan_name, amount_uzs::text, to_char(due_date, 'DD.MM.YYYY')`, period, prev)
	if err != nil {
		return 0, err
	}
	type created struct{ network, plan, uzs, due string }
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (created, error) {
		var c created
		err := r.Scan(&c.network, &c.plan, &c.uzs, &c.due)
		return c, err
	})
	if err != nil {
		return 0, err
	}
	if err := s.settleAdShares(ctx, period, prev); err != nil {
		return 0, err
	}
	for _, c := range list {
		s.notify.NetworkOwners(ctx, c.network, identity.PermPayoutsManage, i18n.Text{
			RU: fmt.Sprintf("Счёт за подписку за %s (тариф «%s»): %s сум к оплате. Оплатить до %s. Если на балансе платформы хватает денег, счёт оплатится автоматически.",
				period.Format("01.2006"), c.plan, money.Group(c.uzs), c.due),
			UZ: fmt.Sprintf("%s uchun obuna hisobi («%s» tarifi): toʻlash uchun %s soʻm. %s gacha toʻlang. Platforma balansida pul yetarli boʻlsa, hisob avtomatik toʻlanadi.",
				period.Format("01.2006"), c.plan, money.Group(c.uzs), c.due),
		})
	}
	return len(list), nil
}

// settleAdShares закрывает доли сетей с рекламы за прошлый месяц: что
// зачлось в счёт этого месяца — applied, остаток — на баланс сети. Счёт,
// который доля покрыла целиком, сразу оплачен.
func (s *Service) settleAdShares(ctx context.Context, period, prev time.Time) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT sh.network_id, sh.amount::text, i.id, COALESCE(i.ad_share_uzs, 0)::text
			FROM network_ad_shares sh
			LEFT JOIN subscription_invoices i ON i.network_id = sh.network_id AND i.period = $1::date
			WHERE sh.period = $2::date AND sh.settled_at IS NULL FOR UPDATE OF sh`, period, prev)
		if err != nil {
			return err
		}
		type share struct {
			network, amount, applied string
			invoice                  *string
		}
		list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (share, error) {
			var x share
			err := r.Scan(&x.network, &x.amount, &x.invoice, &x.applied)
			return x, err
		})
		if err != nil {
			return err
		}
		for _, x := range list {
			credited := money.D(x.amount).Sub(money.D(x.applied))
			if credited.Sign() > 0 {
				if _, err := tx.Exec(ctx, `INSERT INTO balance_entries (network_id, kind, status, amount, note)
					VALUES ($1, 'ad_share', 'available', $2::numeric, $3)`,
					x.network, credited.Money(), "Доля с рекламы брендов за "+prev.Format("01.2006")); err != nil {
					return err
				}
			}
			if _, err := tx.Exec(ctx, `UPDATE network_ad_shares SET applied = $3::numeric, credited = $4::numeric, invoice_id = $5,
				settled_at = now() WHERE network_id = $1 AND period = $2::date`,
				x.network, prev, x.applied, credited.Money(), x.invoice); err != nil {
				return err
			}
		}
		// Счета, которые доля покрыла целиком.
		_, err = tx.Exec(ctx, `UPDATE subscription_invoices SET status = 'paid', paid_via = 'balance', paid_at = now(),
			note = 'Оплачено долей с рекламы брендов'
			WHERE period = $1::date AND status = 'unpaid' AND amount_uzs = 0 AND ad_share_uzs > 0`, period)
		return err
	})
}

// AutoCharge оплачивает неоплаченные счета с баланса сети, если денег хватает
// и автосписание включено.
func (s *Service) AutoCharge(ctx context.Context) error {
	st, err := s.GetSettings(ctx)
	if err != nil || !st.AutoChargeBalance {
		return err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT i.id FROM subscription_invoices i
		WHERE i.status = 'unpaid'
		  AND i.amount_uzs <= COALESCE((SELECT sum(amount) FROM balance_entries b
		                                WHERE b.network_id = i.network_id AND b.status = 'available'), 0)
		ORDER BY i.period`)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, id := range ids {
		var ae *apperr.Error
		if err := s.payFromBalance(ctx, id); err != nil && !errors.As(err, &ae) {
			s.log.Error("автосписание подписки", "invoice_id", id, "err", err)
		}
	}
	return nil
}

// Tick — задача worker-а: выставить счета за текущий месяц и списать с баланса.
func (s *Service) Tick(ctx context.Context) error {
	if _, err := s.GenerateInvoices(ctx, s.now()); err != nil {
		return err
	}
	return s.AutoCharge(ctx)
}

// lockNetwork — все операции с балансом сети идут под блокировкой сети.
func lockNetwork(ctx context.Context, tx pgx.Tx, networkID string) error {
	_, err := tx.Exec(ctx, `SELECT 1 FROM networks WHERE id = $1 FOR UPDATE`, networkID)
	return err
}

func available(ctx context.Context, q db.Querier, networkID string) (string, error) {
	var v string
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0)::numeric(18,2)::text FROM balance_entries WHERE network_id = $1 AND status = 'available'`,
		networkID).Scan(&v)
	return v, err
}

func (s *Service) payFromBalance(ctx context.Context, id string) error {
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		inv, err := s.getInvoice(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := lockNetwork(ctx, tx, inv.NetworkID); err != nil {
			return err
		}
		var status string
		if err := tx.QueryRow(ctx, `SELECT status FROM subscription_invoices WHERE id = $1 FOR UPDATE`, id).Scan(&status); err != nil {
			return err
		}
		if status != "unpaid" {
			return apperr.Conflict("not_unpaid", "счёт уже оплачен или отменён").Uz("hisob allaqachon toʻlangan yoki bekor qilingan")
		}
		avail, err := available(ctx, tx, inv.NetworkID)
		if err != nil {
			return err
		}
		if money.D(avail).Cmp(money.D(inv.AmountUZS)) < 0 {
			return apperr.Conflict("insufficient_balance", "на балансе недостаточно денег").Uz("balansda pul yetarli emas").
				WithDetails(map[string]any{"available": avail, "required": inv.AmountUZS})
		}
		if _, err := tx.Exec(ctx, `INSERT INTO balance_entries (network_id, kind, status, amount, invoice_id, note)
			VALUES ($1, 'subscription', 'available', -$2::numeric, $3, $4)`,
			inv.NetworkID, inv.AmountUZS, id, "Подписка за "+inv.Period); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE subscription_invoices SET status = 'paid', paid_via = 'balance', paid_at = now() WHERE id = $1`, id)
		return err
	})
}

// PayInvoice — сеть оплачивает счёт с баланса платформы вручную.
func (s *Service) PayInvoice(ctx context.Context, p *identity.Principal, id string) (Invoice, error) {
	if err := p.Require(identity.PermPayoutsManage); err != nil {
		return Invoice{}, err
	}
	inv, err := s.getInvoice(ctx, s.pool, id)
	if err != nil || inv.NetworkID != p.NetworkID {
		return Invoice{}, apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
	}
	if err := s.payFromBalance(ctx, id); err != nil {
		return Invoice{}, err
	}
	return s.getInvoice(ctx, s.pool, id)
}

// MarkInvoicePaid — супер-админ отмечает оплату (перевод, наличные).
func (s *Service) MarkInvoicePaid(ctx context.Context, id, note string) (Invoice, error) {
	return s.setInvoiceStatus(ctx, id, "paid", note)
}

// CancelInvoice — супер-админ списывает счёт (например, выставлен по ошибке).
func (s *Service) CancelInvoice(ctx context.Context, id, note string) (Invoice, error) {
	return s.setInvoiceStatus(ctx, id, "cancelled", note)
}

func (s *Service) setInvoiceStatus(ctx context.Context, id, status, note string) (Invoice, error) {
	if !httpx.IsUUID(id) {
		return Invoice{}, apperr.NotFound("счёт не найден").Uz("hisob topilmadi")
	}
	tag, err := s.pool.Exec(ctx, `UPDATE subscription_invoices SET status = $2, note = $3,
		paid_via = CASE WHEN $2 = 'paid' THEN 'manual' END, paid_at = CASE WHEN $2 = 'paid' THEN now() END
		WHERE id = $1 AND status = 'unpaid'`, id, status, strings.TrimSpace(note))
	if err != nil {
		return Invoice{}, err
	}
	if tag.RowsAffected() == 0 {
		if _, err := s.getInvoice(ctx, s.pool, id); err != nil {
			return Invoice{}, err
		}
		return Invoice{}, apperr.Conflict("not_unpaid", "счёт уже оплачен или отменён").Uz("hisob allaqachon toʻlangan yoki bekor qilingan")
	}
	return s.getInvoice(ctx, s.pool, id)
}
