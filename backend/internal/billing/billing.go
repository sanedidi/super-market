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

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
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
}

func NewService(pool *pgxpool.Pool, n *notify.Notifier, log *slog.Logger) *Service {
	return &Service{pool: pool, notify: n, log: log.With("component", "billing"), now: time.Now}
}

// ------------------------------------------------------------- настройки

type Settings struct {
	USDRate           string    `json:"usd_rate"`
	GraceDays         int       `json:"grace_days"`
	AutoChargeBalance bool      `json:"auto_charge_balance"`
	UpdatedAt         time.Time `json:"updated_at"`
}

type SettingsInput struct {
	USDRate           *money.Rate `json:"usd_rate"`
	GraceDays         *int        `json:"grace_days"`
	AutoChargeBalance *bool       `json:"auto_charge_balance"`
}

func (s *Service) GetSettings(ctx context.Context) (Settings, error) {
	var st Settings
	err := s.pool.QueryRow(ctx, `SELECT usd_rate::text, grace_days, auto_charge_balance, updated_at FROM billing_settings WHERE id = 1`).
		Scan(&st.USDRate, &st.GraceDays, &st.AutoChargeBalance, &st.UpdatedAt)
	return st, err
}

func (s *Service) SaveSettings(ctx context.Context, in SettingsInput) (Settings, error) {
	if in.USDRate != nil && money.D(string(*in.USDRate)).Sign() <= 0 {
		return Settings{}, apperr.Validation("usd_rate: курс больше нуля")
	}
	if in.GraceDays != nil && (*in.GraceDays < 0 || *in.GraceDays > 60) {
		return Settings{}, apperr.Validation("grace_days: от 0 до 60 дней")
	}
	var rate *string
	if in.USDRate != nil {
		v := string(*in.USDRate)
		rate = &v
	}
	if _, err := s.pool.Exec(ctx, `UPDATE billing_settings SET usd_rate = COALESCE($1::numeric, usd_rate),
		grace_days = COALESCE($2, grace_days), auto_charge_balance = COALESCE($3, auto_charge_balance), updated_at = now()
		WHERE id = 1`, rate, in.GraceDays, in.AutoChargeBalance); err != nil {
		return Settings{}, err
	}
	return s.GetSettings(ctx)
}

// ---------------------------------------------------------------- тарифы

type Tariff struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	MinStores     int       `json:"min_stores"`
	PricePerStore string    `json:"price_per_store"`
	IsActive      bool      `json:"is_active"`
	CreatedAt     time.Time `json:"created_at"`
}

type TariffInput struct {
	Name          *string       `json:"name"`
	MinStores     *int          `json:"min_stores"`
	PricePerStore *money.Amount `json:"price_per_store"`
	IsActive      *bool         `json:"is_active"`
}

const tariffSelect = `SELECT id, name, min_stores, price_per_store::text, is_active, created_at FROM tariffs`

func (s *Service) ListTariffs(ctx context.Context, page httpx.Page) ([]Tariff, error) {
	rows, err := s.pool.Query(ctx, tariffSelect+` ORDER BY is_active DESC, min_stores, id LIMIT $1 OFFSET $2`, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Tariff])
}

func (s *Service) getTariff(ctx context.Context, id string) (Tariff, error) {
	rows, err := s.pool.Query(ctx, tariffSelect+` WHERE id = $1`, id)
	if err != nil {
		return Tariff{}, err
	}
	t, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Tariff])
	if errors.Is(err, pgx.ErrNoRows) {
		return t, apperr.NotFound("тариф не найден")
	}
	return t, err
}

// SaveTariff создаёт (id == "") или меняет тариф. Цены действуют со
// следующего счёта; выставленные счета не пересчитываются.
func (s *Service) SaveTariff(ctx context.Context, id string, in TariffInput) (Tariff, error) {
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Tariff{}, apperr.Validation("name: обязательное поле")
	}
	if in.MinStores != nil && *in.MinStores < 1 {
		return Tariff{}, apperr.Validation("min_stores: от 1")
	}
	var price *string
	if in.PricePerStore != nil {
		v := string(*in.PricePerStore)
		price = &v
	}
	var err error
	if id == "" {
		if in.Name == nil || in.MinStores == nil || price == nil {
			return Tariff{}, apperr.Validation("name, min_stores и price_per_store обязательны")
		}
		err = s.pool.QueryRow(ctx, `INSERT INTO tariffs (name, min_stores, price_per_store) VALUES ($1, $2, $3::numeric) RETURNING id`,
			strings.TrimSpace(*in.Name), *in.MinStores, *price).Scan(&id)
	} else {
		var name *string
		if in.Name != nil {
			v := strings.TrimSpace(*in.Name)
			name = &v
		}
		var tag interface{ RowsAffected() int64 }
		tag, err = s.pool.Exec(ctx, `UPDATE tariffs SET name = COALESCE($2, name), min_stores = COALESCE($3, min_stores),
			price_per_store = COALESCE($4::numeric, price_per_store), is_active = COALESCE($5, is_active) WHERE id = $1`,
			id, name, in.MinStores, price, in.IsActive)
		if err == nil && tag.RowsAffected() == 0 {
			return Tariff{}, apperr.NotFound("тариф не найден")
		}
	}
	if db.IsUniqueViolation(err, "tariffs_min_stores_active") {
		return Tariff{}, apperr.Conflict("duplicate_tariff", "активный тариф с таким числом магазинов уже есть")
	}
	if err != nil {
		return Tariff{}, err
	}
	return s.getTariff(ctx, id)
}

// ---------------------------------------------------------- сети и цены

// priceSQL — цена за магазин для сети n при числе магазинов cnt.
const priceSQL = `COALESCE(n.custom_price_per_store,
	(SELECT t.price_per_store FROM tariffs t WHERE t.is_active AND t.min_stores <= cnt ORDER BY t.min_stores DESC LIMIT 1), 0)`

const storesCountSQL = `(SELECT count(*)::int FROM stores s WHERE s.network_id = n.id AND s.status = 'active')`

// Tashkent-дата «сегодня» в SQL.
const todaySQL = `(now() AT TIME ZONE 'Asia/Tashkent')::date`

type NetworkBilling struct {
	NetworkID           string  `json:"network_id"`
	NetworkName         string  `json:"network_name"`
	Kind                string  `json:"kind"`
	Status              string  `json:"status"`
	StoresCount         int     `json:"stores_count"`
	CustomPricePerStore *string `json:"custom_price_per_store"`
	PricePerStore       string  `json:"price_per_store"`
	MonthlyUSD          string  `json:"monthly_usd"`
	BillingFrom         string  `json:"billing_from"`
	Available           string  `json:"balance_available"`
	Pending             string  `json:"balance_pending"`
	UnpaidUZS           string  `json:"unpaid_uzs"`
	Overdue             bool    `json:"overdue"`
}

const networkBillingSQL = `
	SELECT n.id, n.name, n.kind, n.status, c.cnt, n.custom_price_per_store::text, p.price::text, (p.price * c.cnt)::text,
	       to_char(n.billing_from, 'YYYY-MM-DD'),
	       COALESCE((SELECT sum(amount) FROM balance_entries b WHERE b.network_id = n.id AND b.status = 'available'), 0)::numeric(18,2)::text,
	       COALESCE((SELECT sum(amount) FROM balance_entries b WHERE b.network_id = n.id AND b.status = 'pending'), 0)::numeric(18,2)::text,
	       COALESCE((SELECT sum(amount_uzs) FROM subscription_invoices i WHERE i.network_id = n.id AND i.status = 'unpaid'), 0)::numeric(18,2)::text,
	       EXISTS (SELECT 1 FROM subscription_invoices i WHERE i.network_id = n.id AND i.status = 'unpaid' AND i.due_date < ` + todaySQL + `) AS overdue
	FROM networks n
	CROSS JOIN LATERAL (SELECT ` + storesCountSQL + ` AS cnt) c
	CROSS JOIN LATERAL (SELECT ` + priceSQL + ` AS price) p`

func scanNetworkBilling(row pgx.CollectableRow) (NetworkBilling, error) {
	var b NetworkBilling
	err := row.Scan(&b.NetworkID, &b.NetworkName, &b.Kind, &b.Status, &b.StoresCount, &b.CustomPricePerStore, &b.PricePerStore,
		&b.MonthlyUSD, &b.BillingFrom, &b.Available, &b.Pending, &b.UnpaidUZS, &b.Overdue)
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
		return NetworkBilling{}, apperr.NotFound("сеть не найдена")
	}
	rows, err := s.pool.Query(ctx, networkBillingSQL+` WHERE n.id = $1`, networkID)
	if err != nil {
		return NetworkBilling{}, err
	}
	b, err := pgx.CollectExactlyOneRow(rows, scanNetworkBilling)
	if errors.Is(err, pgx.ErrNoRows) {
		return b, apperr.NotFound("сеть не найдена")
	}
	return b, err
}

type NetworkBillingInput struct {
	CustomPricePerStore *money.Amount `json:"custom_price_per_store"`
	ClearCustomPrice    bool          `json:"clear_custom_price"`
	BillingFrom         *string       `json:"billing_from"` // YYYY-MM-DD, первое число месяца
}

// SaveNetworkBilling — индивидуальная цена сети и начало оплаты (бесплатный период).
func (s *Service) SaveNetworkBilling(ctx context.Context, networkID string, in NetworkBillingInput) (NetworkBilling, error) {
	if _, err := s.NetworkBilling(ctx, networkID); err != nil {
		return NetworkBilling{}, err
	}
	var from *time.Time
	if in.BillingFrom != nil {
		t, err := time.Parse("2006-01-02", *in.BillingFrom)
		if err != nil {
			return NetworkBilling{}, apperr.Validation("billing_from: дата YYYY-MM-DD")
		}
		t = time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
		from = &t
	}
	var price *string
	if in.CustomPricePerStore != nil {
		v := string(*in.CustomPricePerStore)
		price = &v
	}
	if _, err := s.pool.Exec(ctx, `UPDATE networks SET
		custom_price_per_store = CASE WHEN $2 THEN NULL ELSE COALESCE($3::numeric, custom_price_per_store) END,
		billing_from = COALESCE($4::date, billing_from) WHERE id = $1`, networkID, in.ClearCustomPrice, price, from); err != nil {
		return NetworkBilling{}, err
	}
	return s.NetworkBilling(ctx, networkID)
}

// -------------------------------------------------------------- счета

type Invoice struct {
	ID            string     `json:"id"`
	NetworkID     string     `json:"network_id"`
	NetworkName   string     `json:"network_name"`
	Period        string     `json:"period"`
	StoresCount   int        `json:"stores_count"`
	PricePerStore string     `json:"price_per_store"`
	AmountUSD     string     `json:"amount_usd"`
	Rate          string     `json:"rate"`
	AmountUZS     string     `json:"amount_uzs"`
	Status        string     `json:"status"`
	DueDate       string     `json:"due_date"`
	Overdue       bool       `json:"overdue"`
	PaidVia       *string    `json:"paid_via"`
	PaidAt        *time.Time `json:"paid_at"`
	Note          string     `json:"note"`
	CreatedAt     time.Time  `json:"created_at"`
}

const invoiceSelect = `
	SELECT i.id, i.network_id, n.name, to_char(i.period, 'YYYY-MM'), i.stores_count, i.price_per_store::text,
	       i.amount_usd::text, i.rate::text, i.amount_uzs::text, i.status, to_char(i.due_date, 'YYYY-MM-DD'),
	       i.status = 'unpaid' AND i.due_date < ` + todaySQL + `, i.paid_via, i.paid_at, i.note, i.created_at
	FROM subscription_invoices i JOIN networks n ON n.id = i.network_id`

func (s *Service) ListInvoices(ctx context.Context, networkID, status string, page httpx.Page) ([]Invoice, error) {
	if status != "" && status != "unpaid" && status != "paid" && status != "cancelled" && status != "overdue" {
		return nil, apperr.Validation("status: unpaid, paid, cancelled или overdue")
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
		return Invoice{}, apperr.NotFound("счёт не найден")
	}
	rows, err := q.Query(ctx, invoiceSelect+` WHERE i.id = $1`, id)
	if err != nil {
		return Invoice{}, err
	}
	inv, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Invoice])
	if errors.Is(err, pgx.ErrNoRows) {
		return inv, apperr.NotFound("счёт не найден")
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
	rows, err := s.pool.Query(ctx, `
		INSERT INTO subscription_invoices (network_id, period, stores_count, price_per_store, amount_usd, rate, amount_uzs, due_date)
		SELECT n.id, $1::date, c.cnt, p.price, p.price * c.cnt, bs.usd_rate, round(p.price * c.cnt * bs.usd_rate, 2),
		       $1::date + bs.grace_days
		FROM networks n
		CROSS JOIN billing_settings bs
		CROSS JOIN LATERAL (SELECT `+storesCountSQL+` AS cnt) c
		CROSS JOIN LATERAL (SELECT `+priceSQL+` AS price) p
		WHERE n.status = 'active' AND n.billing_from <= $1::date AND c.cnt > 0 AND p.price > 0
		ON CONFLICT (network_id, period) DO NOTHING
		RETURNING network_id, amount_usd::text, amount_uzs::text, to_char(due_date, 'DD.MM.YYYY')`, period)
	if err != nil {
		return 0, err
	}
	type created struct{ network, usd, uzs, due string }
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (created, error) {
		var c created
		err := r.Scan(&c.network, &c.usd, &c.uzs, &c.due)
		return c, err
	})
	if err != nil {
		return 0, err
	}
	for _, c := range list {
		s.notify.NetworkOwners(ctx, c.network, identity.PermPayoutsManage, fmt.Sprintf(
			"Счёт за подписку за %s: %s $ (%s сум). Оплатить до %s. Если на балансе платформы хватает денег, счёт оплатится автоматически.",
			period.Format("01.2006"), c.usd, c.uzs, c.due))
	}
	return len(list), nil
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
			return apperr.Conflict("not_unpaid", "счёт уже оплачен или отменён")
		}
		avail, err := available(ctx, tx, inv.NetworkID)
		if err != nil {
			return err
		}
		if money.D(avail).Cmp(money.D(inv.AmountUZS)) < 0 {
			return apperr.Conflict("insufficient_balance", "на балансе недостаточно денег").
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
		return Invoice{}, apperr.NotFound("счёт не найден")
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
		return Invoice{}, apperr.NotFound("счёт не найден")
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
		return Invoice{}, apperr.Conflict("not_unpaid", "счёт уже оплачен или отменён")
	}
	return s.getInvoice(ctx, s.pool, id)
}
