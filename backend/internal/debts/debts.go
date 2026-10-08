// Package debts — долги покупателей (насия): продажа в долг на кассе,
// погашение, списание, лимиты и стоп-лист, напоминания, спор «Это не я».
//
// Долг ведётся по магазину, покупатель — номер телефона внутри сети.
// Баланс — сумма записей журнала debt_entries (плюс — долг вырос).
package debts

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
)

// Виды записей журнала.
const (
	DocSale     = "sale"
	DocPayment  = "payment"
	DocReturn   = "return"
	DocWriteoff = "writeoff"
)

// DocCashPayment — вид записи в журнале кассы для погашения долга.
const DocCashPayment = "debt_payment"

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

// ShiftChecker — проверка смены кассы (sales.CheckShiftTime; передаётся
// снаружи, чтобы пакет не зависел от продаж).
type ShiftChecker func(ctx context.Context, q db.Querier, shiftID, deviceID string, at time.Time) error

type Service struct {
	pool       *pgxpool.Pool
	tg         identity.Sender
	devCode    string
	secret     string
	checkShift ShiftChecker
	log        *slog.Logger
	now        func() time.Time
}

func NewService(pool *pgxpool.Pool, tg identity.Sender, devCode, secret string, checkShift ShiftChecker, log *slog.Logger) *Service {
	return &Service{pool: pool, tg: tg, devCode: devCode, secret: secret, checkShift: checkShift, log: log, now: time.Now}
}

// ------------------------------------------------------------- настройки

type StoreToggle struct {
	StoreID     string `json:"store_id"`
	Name        string `json:"name"`
	DebtEnabled bool   `json:"debt_enabled"`
}

type Settings struct {
	DefaultLimit    string        `json:"default_limit"`
	UnverifiedLimit string        `json:"unverified_limit"`
	TermDays        int           `json:"term_days"`
	RequireCode     bool          `json:"require_code"`
	ExtraReminders  bool          `json:"extra_reminders"`
	Stores          []StoreToggle `json:"stores"`
}

func loadSettings(ctx context.Context, q db.Querier, networkID string) (Settings, error) {
	st := Settings{DefaultLimit: "500000.00", UnverifiedLimit: "100000.00", TermDays: 30, RequireCode: true, ExtraReminders: true, Stores: []StoreToggle{}}
	err := q.QueryRow(ctx, `
		SELECT default_limit::text, unverified_limit::text, term_days, require_code, extra_reminders
		FROM debt_settings WHERE network_id = $1`, networkID).
		Scan(&st.DefaultLimit, &st.UnverifiedLimit, &st.TermDays, &st.RequireCode, &st.ExtraReminders)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return st, err
	}
	return st, nil
}

func (s *Service) GetSettings(ctx context.Context, p *identity.Principal) (Settings, error) {
	if err := p.RequireAny(identity.PermDebtsManage, identity.PermDebtsGive); err != nil {
		return Settings{}, err
	}
	st, err := loadSettings(ctx, s.pool, p.NetworkID)
	if err != nil {
		return st, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, name, debt_enabled FROM stores
		WHERE network_id = $1 AND ($2 OR id = ANY($3::uuid[])) ORDER BY name`, p.NetworkID, p.SeesAllStores(), p.StoreIDs)
	if err != nil {
		return st, err
	}
	st.Stores, err = pgx.CollectRows(rows, pgx.RowToStructByPos[StoreToggle])
	return st, err
}

type SettingsInput struct {
	DefaultLimit    *money.Amount `json:"default_limit"`
	UnverifiedLimit *money.Amount `json:"unverified_limit"`
	TermDays        *int          `json:"term_days"`
	RequireCode     *bool         `json:"require_code"`
	ExtraReminders  *bool         `json:"extra_reminders"`
}

func (s *Service) SaveSettings(ctx context.Context, p *identity.Principal, in SettingsInput) (Settings, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return Settings{}, err
	}
	cur, err := loadSettings(ctx, s.pool, p.NetworkID)
	if err != nil {
		return cur, err
	}
	if in.DefaultLimit != nil {
		if !in.DefaultLimit.Valid() || money.D(string(*in.DefaultLimit)).Sign() < 0 {
			return cur, apperr.Validation("default_limit: неверная сумма").Uz("default_limit: summa notoʻgʻri")
		}
		cur.DefaultLimit = string(*in.DefaultLimit)
	}
	if in.UnverifiedLimit != nil {
		if !in.UnverifiedLimit.Valid() || money.D(string(*in.UnverifiedLimit)).Sign() < 0 {
			return cur, apperr.Validation("unverified_limit: неверная сумма").Uz("unverified_limit: summa notoʻgʻri")
		}
		cur.UnverifiedLimit = string(*in.UnverifiedLimit)
	}
	if in.TermDays != nil {
		if *in.TermDays < 1 || *in.TermDays > 365 {
			return cur, apperr.Validation("term_days: от 1 до 365 дней").Uz("term_days: 1 dan 365 kungacha")
		}
		cur.TermDays = *in.TermDays
	}
	if in.RequireCode != nil {
		cur.RequireCode = *in.RequireCode
	}
	if in.ExtraReminders != nil {
		cur.ExtraReminders = *in.ExtraReminders
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO debt_settings (network_id, default_limit, unverified_limit, term_days, require_code, extra_reminders)
		VALUES ($1, $2::numeric, $3::numeric, $4, $5, $6)
		ON CONFLICT (network_id) DO UPDATE SET default_limit = EXCLUDED.default_limit, unverified_limit = EXCLUDED.unverified_limit,
		    term_days = EXCLUDED.term_days, require_code = EXCLUDED.require_code, extra_reminders = EXCLUDED.extra_reminders,
		    updated_at = now()`,
		p.NetworkID, cur.DefaultLimit, cur.UnverifiedLimit, cur.TermDays, cur.RequireCode, cur.ExtraReminders); err != nil {
		return cur, err
	}
	return s.GetSettings(ctx, p)
}

// SetStoreEnabled — переключатель «Даёт в долг» магазина.
func (s *Service) SetStoreEnabled(ctx context.Context, p *identity.Principal, storeID string, enabled bool) (Settings, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return Settings{}, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return Settings{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	tag, err := s.pool.Exec(ctx, `UPDATE stores SET debt_enabled = $3 WHERE id = $1 AND network_id = $2`, storeID, p.NetworkID, enabled)
	if err != nil {
		return Settings{}, err
	}
	if tag.RowsAffected() == 0 {
		return Settings{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return s.GetSettings(ctx, p)
}

// ---------------------------------------------------------------- балансы

// Balance — долг покупателя в одном магазине.
type Balance struct {
	DebtorID       string     `json:"debtor_id"`
	Phone          string     `json:"phone"`
	FullName       string     `json:"full_name"`
	StoreID        string     `json:"store_id"`
	StoreName      string     `json:"store_name"`
	Amount         string     `json:"amount"`
	Limit          string     `json:"limit"`
	Available      string     `json:"available"`
	Blocked        bool       `json:"blocked"`
	Verified       bool       `json:"verified"`
	Since          *time.Time `json:"since"`
	DueDate        *string    `json:"due_date"`
	OverdueDays    int        `json:"overdue_days"`
	LastPaidAt     *time.Time `json:"last_paid_at"`
	LastReminderAt *time.Time `json:"last_reminder_at"`
	OpenDisputes   int        `json:"open_disputes"`
}

// balancesSQL — долги по парам «покупатель — магазин». since — первая
// покупка в долг после того, как долг в последний раз был погашен до нуля.
// $1 — сеть, $2 — магазины (NULL — все), $3 — покупатель (NULL — все), $4 — срок в днях.
const balancesSQL = `
	WITH e AS (
		SELECT debtor_id, store_id, amount, doc_type, created_at,
		       row_number() OVER w AS rn, sum(amount) OVER w AS run
		FROM debt_entries
		WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND ($3::uuid IS NULL OR debtor_id = $3)
		WINDOW w AS (PARTITION BY debtor_id, store_id ORDER BY created_at, id)
	), z AS (
		SELECT *, max(CASE WHEN run <= 0 THEN rn END) OVER (PARTITION BY debtor_id, store_id) AS zero_rn FROM e
	), b AS (
		SELECT debtor_id, store_id, sum(amount) AS amount,
		       min(created_at) FILTER (WHERE amount > 0 AND rn > COALESCE(zero_rn, 0)) AS since,
		       max(created_at) FILTER (WHERE doc_type = 'payment') AS paid_at
		FROM z GROUP BY debtor_id, store_id
	)
	SELECT d.id, d.phone, d.full_name, st.id, st.name, b.amount::numeric(18,2)::text,
	       COALESCE(d.credit_limit, CASE WHEN d.verified_at IS NULL THEN ds.unverified_limit ELSE ds.default_limit END,
	                CASE WHEN d.verified_at IS NULL THEN 100000 ELSE 500000 END)::numeric(18,2)::text,
	       d.blocked, d.verified_at IS NOT NULL,
	       CASE WHEN b.amount > 0 THEN b.since END,
	       CASE WHEN b.amount > 0 AND b.since IS NOT NULL
	            THEN to_char((b.since AT TIME ZONE 'Asia/Tashkent')::date + $4::int, 'YYYY-MM-DD') END,
	       CASE WHEN b.amount > 0 AND b.since IS NOT NULL
	            THEN GREATEST(0, (now() AT TIME ZONE 'Asia/Tashkent')::date - ((b.since AT TIME ZONE 'Asia/Tashkent')::date + $4::int)) ELSE 0 END,
	       b.paid_at,
	       (SELECT max(r.created_at) FROM debt_reminders r WHERE r.debtor_id = d.id AND r.store_id = st.id),
	       (SELECT count(*) FROM debt_disputes dd JOIN debt_entries de ON de.id = dd.entry_id
	         WHERE dd.status = 'open' AND de.debtor_id = d.id AND de.store_id = st.id)::int
	FROM b
	JOIN debtors d ON d.id = b.debtor_id
	JOIN stores st ON st.id = b.store_id
	LEFT JOIN debt_settings ds ON ds.network_id = d.network_id`

func scanBalance(r pgx.CollectableRow) (Balance, error) {
	var b Balance
	err := r.Scan(&b.DebtorID, &b.Phone, &b.FullName, &b.StoreID, &b.StoreName, &b.Amount, &b.Limit, &b.Blocked, &b.Verified,
		&b.Since, &b.DueDate, &b.OverdueDays, &b.LastPaidAt, &b.LastReminderAt, &b.OpenDisputes)
	if err != nil {
		return b, err
	}
	avail := money.D(b.Limit).Sub(money.D(b.Amount))
	if avail.Sign() < 0 {
		avail = money.D("0")
	}
	b.Available = avail.Money()
	return b, nil
}

func termDays(ctx context.Context, q db.Querier, networkID string) (int, error) {
	st, err := loadSettings(ctx, q, networkID)
	return st.TermDays, err
}

// storeScope — магазины для запроса: указанный (если доступен) или все доступные.
func storeScope(p *identity.Principal, storeID string) ([]string, error) {
	if storeID != "" {
		if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
			return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
		}
		return []string{storeID}, nil
	}
	if p.SeesAllStores() {
		return nil, nil
	}
	if len(p.StoreIDs) == 0 {
		return []string{}, nil
	}
	return p.StoreIDs, nil
}

func (s *Service) balances(ctx context.Context, q db.Querier, networkID string, stores []string, debtorID *string, extra string, args ...any) ([]Balance, error) {
	days, err := termDays(ctx, q, networkID)
	if err != nil {
		return nil, err
	}
	var storeArg any
	if stores != nil {
		storeArg = stores
	}
	sql := balancesSQL
	if extra != "" {
		sql += " WHERE " + extra
	}
	rows, err := q.Query(ctx, sql, append([]any{networkID, storeArg, debtorID, days}, args...)...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanBalance)
}

// ------------------------------------------------------------ покупатели

func normPhone(raw string) (string, error) {
	ph, err := phone.Normalize(raw)
	if err != nil {
		return "", apperr.Validation("phone: неверный номер телефона").Uz("phone: telefon raqami notoʻgʻri")
	}
	return ph, nil
}

// upsertDebtor находит покупателя по номеру или заводит нового.
func upsertDebtor(ctx context.Context, q db.Querier, networkID, ph, name string) (string, error) {
	name = strings.TrimSpace(name)
	if len([]rune(name)) > 120 {
		return "", apperr.Validation("full_name: не длиннее 120 символов").Uz("full_name: 120 belgidan oshmasin")
	}
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO debtors (network_id, phone, full_name) VALUES ($1, $2, $3)
		ON CONFLICT (network_id, phone) DO UPDATE
		SET full_name = CASE WHEN EXCLUDED.full_name <> '' AND debtors.full_name = '' THEN EXCLUDED.full_name ELSE debtors.full_name END
		RETURNING id`, networkID, ph, name).Scan(&id)
	return id, err
}

// lockDebtor — один долг за раз: продажа и погашение по одному покупателю
// не обгоняют друг друга при проверке лимита.
func lockDebtor(ctx context.Context, tx pgx.Tx, id string) error {
	_, err := tx.Exec(ctx, `SELECT 1 FROM debtors WHERE id = $1 FOR UPDATE`, id)
	return err
}

// storeBalance — текущий долг покупателя в магазине.
func storeBalance(ctx context.Context, q db.Querier, debtorID, storeID string) (money.Dec, error) {
	var v string
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0)::text FROM debt_entries WHERE debtor_id = $1 AND store_id = $2`,
		debtorID, storeID).Scan(&v)
	return money.D(v), err
}

func addEntry(ctx context.Context, q db.Querier, networkID, debtorID, storeID string, amount money.Dec, docType, docID string) (int64, error) {
	var id int64
	err := q.QueryRow(ctx, `
		INSERT INTO debt_entries (network_id, debtor_id, store_id, amount, doc_type, doc_id)
		VALUES ($1, $2, $3, $4::numeric, $5, $6) RETURNING id`,
		networkID, debtorID, storeID, amount.Money(), docType, docID).Scan(&id)
	return id, err
}

// effectiveLimit — лимит покупателя: свой, иначе из настроек (для
// неподтверждённого номера — меньший).
func effectiveLimit(ctx context.Context, q db.Querier, networkID, debtorID string) (money.Dec, bool, bool, error) {
	st, err := loadSettings(ctx, q, networkID)
	if err != nil {
		return money.D("0"), false, false, err
	}
	var own *string
	var blocked, verified bool
	if err := q.QueryRow(ctx, `SELECT credit_limit::text, blocked, verified_at IS NOT NULL FROM debtors WHERE id = $1`, debtorID).
		Scan(&own, &blocked, &verified); err != nil {
		return money.D("0"), false, false, err
	}
	switch {
	case own != nil:
		return money.D(*own), blocked, verified, nil
	case verified:
		return money.D(st.DefaultLimit), blocked, verified, nil
	default:
		return money.D(st.UnverifiedLimit), blocked, verified, nil
	}
}

// ----------------------------------------------------- продажа в долг

// ChargeInput — часть продажи в долг (вызывается из продаж в той же транзакции).
type ChargeInput struct {
	Phone   string
	Name    string
	Amount  money.Dec
	StoreID string
	SaleID  string
	// Продажа с кассы: она уже случилась, поэтому сверх лимита и в
	// стоп-лист не отклоняем, а помечаем (касса проверяет лимит сама).
	POS bool
}

type ChargeResult struct {
	DebtorID  string
	OverLimit bool
}

var (
	ErrDisabled = apperr.Conflict("debt_disabled", "магазин не продаёт в долг").Uz("doʻkon qarzga sotmaydi")
	ErrBlocked  = apperr.Conflict("debtor_blocked", "покупатель в стоп-листе — в долг не давать").Uz("xaridor stop-roʻyxatda — qarzga bermang")
)

// Charge записывает долг по продаже.
func Charge(ctx context.Context, tx pgx.Tx, p *identity.Principal, in ChargeInput) (ChargeResult, error) {
	var res ChargeResult
	if err := p.Require(identity.PermDebtsGive); err != nil {
		return res, err
	}
	if in.Amount.Sign() <= 0 {
		return res, apperr.Validation("debt.amount: сумма в долг должна быть больше нуля").Uz("debt.amount: qarz summasi noldan katta boʻlishi kerak")
	}
	ph, err := normPhone(in.Phone)
	if err != nil {
		return res, apperr.Validation("debt.phone: неверный номер телефона").Uz("debt.phone: telefon raqami notoʻgʻri")
	}
	// Касса, которая продала в долг без связи, не теряет продажу: долг
	// записывается с отметкой «сверх лимита». Остальным — ошибка тарифа.
	if !in.POS {
		if err := plans.Require(ctx, tx, p.NetworkID, plans.FeatureDebts); err != nil {
			return res, err
		}
	}
	var enabled bool
	if err := tx.QueryRow(ctx, `SELECT debt_enabled AND network_has_feature(network_id, 'debts') FROM stores WHERE id = $1 AND network_id = $2`, in.StoreID, p.NetworkID).Scan(&enabled); err != nil {
		return res, err
	}
	if !enabled {
		if !in.POS {
			return res, ErrDisabled
		}
		res.OverLimit = true // выключили, пока касса была без связи
	}
	if res.DebtorID, err = upsertDebtor(ctx, tx, p.NetworkID, ph, in.Name); err != nil {
		return res, err
	}
	if err := lockDebtor(ctx, tx, res.DebtorID); err != nil {
		return res, err
	}
	limit, blocked, _, err := effectiveLimit(ctx, tx, p.NetworkID, res.DebtorID)
	if err != nil {
		return res, err
	}
	bal, err := storeBalance(ctx, tx, res.DebtorID, in.StoreID)
	if err != nil {
		return res, err
	}
	if blocked {
		if !in.POS {
			return res, ErrBlocked
		}
		res.OverLimit = true
	}
	if bal.Add(in.Amount).Cmp(limit) > 0 {
		if !in.POS {
			avail := limit.Sub(bal)
			if avail.Sign() < 0 {
				avail = money.D("0")
			}
			return res, apperr.Conflict("debt_limit", "не хватает лимита: в долг можно "+money.Group(avail.Money())+" сум").Uz("limit yetmaydi: qarzga " + money.Group(avail.Money()) + " soʻmgacha berish mumkin").
				WithDetails(map[string]any{"available": avail.Money(), "limit": limit.Money(), "debt": bal.Money()})
		}
		res.OverLimit = true
	}
	if _, err := addEntry(ctx, tx, p.NetworkID, res.DebtorID, in.StoreID, in.Amount, DocSale, in.SaleID); err != nil {
		return res, err
	}
	total := bal.Add(in.Amount)
	all := money.Group(total.Money())
	err = notifyBuyer(ctx, tx, ph, in.StoreID, "debt_added",
		i18n.Text{RU: "Записали в долг · %s", UZ: "Qarzga yozildi · %s"},
		i18n.Text{RU: "%s сум. Всего в этом магазине: " + all + " сум", UZ: "%s soʻm. Bu doʻkonda jami: " + all + " soʻm"}, in.Amount)
	return res, err
}

// ReduceForReturn — возврат по чеку с долгом: сначала уменьшаем долг по
// этой продаже (не больше остатка долга по ней и текущего долга в магазине).
// Возвращает, сколько ушло в счёт долга.
func ReduceForReturn(ctx context.Context, tx pgx.Tx, networkID, saleID, returnID string, refund money.Dec) (money.Dec, error) {
	zero := money.D("0")
	var debtorID *string
	var storeID, saleDebt, returned string
	err := tx.QueryRow(ctx, `
		SELECT s.debtor_id, s.store_id, s.debt_amount::text,
		       COALESCE((SELECT sum(r.debt_amount) FROM customer_returns r WHERE r.sale_id = s.id), 0)::text
		FROM sales s WHERE s.id = $1 AND s.network_id = $2`, saleID, networkID).Scan(&debtorID, &storeID, &saleDebt, &returned)
	if err != nil || debtorID == nil {
		return zero, err
	}
	if err := lockDebtor(ctx, tx, *debtorID); err != nil {
		return zero, err
	}
	left := money.D(saleDebt).Sub(money.D(returned))
	bal, err := storeBalance(ctx, tx, *debtorID, storeID)
	if err != nil {
		return zero, err
	}
	part := refund.Min(left).Min(bal)
	if part.Sign() <= 0 {
		return zero, nil
	}
	part = part.Round2()
	if _, err := addEntry(ctx, tx, networkID, *debtorID, storeID, part.Neg(), DocReturn, returnID); err != nil {
		return zero, err
	}
	if _, err := tx.Exec(ctx, `UPDATE customer_returns SET debt_amount = $2::numeric WHERE id = $1`, returnID, part.Money()); err != nil {
		return zero, err
	}
	return part, nil
}

// codeHash — HMAC кода подтверждения.
func (s *Service) codeHash(networkID, ph, code string) []byte {
	m := hmac.New(sha256.New, []byte(s.secret))
	m.Write([]byte("debt:" + networkID + ":" + ph + ":" + code))
	return m.Sum(nil)
}

// WithClock подменяет часы (тесты напоминаний).
func (s *Service) WithClock(now func() time.Time) *Service {
	s.now = now
	return s
}
