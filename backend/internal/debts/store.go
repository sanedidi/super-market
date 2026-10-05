package debts

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// ------------------------------------------------------- список и итоги

type ListFilter struct {
	StoreID string
	Q       string
	// all (по умолчанию), overdue, blocked, unverified, disputes
	Status string
	Page   httpx.Page
}

// List — должники: пары «покупатель — магазин» с долгом больше нуля.
func (s *Service) List(ctx context.Context, p *identity.Principal, f ListFilter) ([]Balance, error) {
	if err := p.RequireAny(identity.PermDebtsManage, identity.PermDebtsGive); err != nil {
		return nil, err
	}
	stores, err := storeScope(p, f.StoreID)
	if err != nil {
		return nil, err
	}
	cond := "b.amount > 0"
	switch f.Status {
	case "", "all":
	case "overdue":
		cond += " AND b.since IS NOT NULL AND (now() AT TIME ZONE 'Asia/Tashkent')::date > (b.since AT TIME ZONE 'Asia/Tashkent')::date + $4::int"
	case "blocked":
		cond += " AND d.blocked"
	case "unverified":
		cond += " AND d.verified_at IS NULL"
	case "disputes":
		cond += ` AND EXISTS (SELECT 1 FROM debt_disputes dd JOIN debt_entries de ON de.id = dd.entry_id
		          WHERE dd.status = 'open' AND de.debtor_id = d.id AND de.store_id = st.id)`
	default:
		return nil, apperr.Validation("status: all, overdue, blocked, unverified или disputes")
	}
	q := strings.TrimSpace(f.Q)
	cond += " AND ($5 = '' OR d.full_name ILIKE '%' || $5 || '%' OR regexp_replace(d.phone, '\\D', '', 'g') LIKE '%' || regexp_replace($5, '\\D', '', 'g') || '%' AND regexp_replace($5, '\\D', '', 'g') <> '')"
	cond += " ORDER BY b.amount DESC, d.full_name LIMIT $6 OFFSET $7"
	return s.balances(ctx, s.pool, p.NetworkID, stores, nil, cond, q, f.Page.Limit, f.Page.Offset)
}

type Summary struct {
	Total        string `json:"total"`
	Count        int    `json:"count"`
	Overdue      string `json:"overdue"`
	OverdueCount int    `json:"overdue_count"`
	Unverified   int    `json:"unverified"`
	OpenDisputes int    `json:"open_disputes"`
	GivenToday   string `json:"given_today"`
	GivenCount   int    `json:"given_today_count"`
	PaidToday    string `json:"paid_today"`
	PaidCash     string `json:"paid_today_cash"`
	PaidOther    string `json:"paid_today_other"`
}

func (s *Service) Summary(ctx context.Context, p *identity.Principal, storeID string) (Summary, error) {
	out := Summary{}
	if err := p.RequireAny(identity.PermDebtsManage, identity.PermDebtsGive, identity.PermReportsView); err != nil {
		return out, err
	}
	stores, err := storeScope(p, storeID)
	if err != nil {
		return out, err
	}
	list, err := s.balances(ctx, s.pool, p.NetworkID, stores, nil, "b.amount > 0")
	if err != nil {
		return out, err
	}
	total, overdue := money.D("0"), money.D("0")
	for _, b := range list {
		total = total.Add(money.D(b.Amount))
		out.Count++
		if b.OverdueDays > 0 {
			overdue = overdue.Add(money.D(b.Amount))
			out.OverdueCount++
		}
		if !b.Verified {
			out.Unverified++
		}
		out.OpenDisputes += b.OpenDisputes
	}
	out.Total, out.Overdue = total.Money(), overdue.Money()
	var storeArg any
	if stores != nil {
		storeArg = stores
	}
	now := s.now().In(tashkent)
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(amount) FILTER (WHERE doc_type = 'sale'), 0)::numeric(18,2)::text,
		       count(*) FILTER (WHERE doc_type = 'sale')::int
		FROM debt_entries WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND created_at >= $3`,
		p.NetworkID, storeArg, day).Scan(&out.GivenToday, &out.GivenCount)
	if err != nil {
		return out, err
	}
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(dp.amount), 0)::numeric(18,2)::text,
		       COALESCE(sum(dp.amount) FILTER (WHERE m.kind = 'cash'), 0)::numeric(18,2)::text,
		       COALESCE(sum(dp.amount) FILTER (WHERE m.kind <> 'cash'), 0)::numeric(18,2)::text
		FROM debt_payments dp JOIN payment_methods m ON m.id = dp.payment_method_id
		WHERE dp.network_id = $1 AND ($2::uuid[] IS NULL OR dp.store_id = ANY($2)) AND dp.paid_at >= $3`,
		p.NetworkID, storeArg, day).Scan(&out.PaidToday, &out.PaidCash, &out.PaidOther)
	return out, err
}

// ------------------------------------------------------------- карточка

type Entry struct {
	ID        int64     `json:"id"`
	StoreID   string    `json:"store_id"`
	StoreName string    `json:"store_name"`
	DocType   string    `json:"doc_type"`
	DocID     string    `json:"doc_id"`
	Number    *int64    `json:"number"`
	Amount    string    `json:"amount"`
	Balance   string    `json:"balance"` // долг после записи
	Detail    string    `json:"detail"`  // способ оплаты, причина списания, позиции
	Employee  string    `json:"employee"`
	Disputed  string    `json:"dispute_status"`
	CreatedAt time.Time `json:"created_at"`
}

type DebtorCard struct {
	ID          string    `json:"id"`
	Phone       string    `json:"phone"`
	FullName    string    `json:"full_name"`
	OwnLimit    *string   `json:"credit_limit"`
	Blocked     bool      `json:"blocked"`
	Verified    bool      `json:"verified"`
	Note        string    `json:"note"`
	HasApp      bool      `json:"has_app"`
	CreatedAt   time.Time `json:"created_at"`
	Stores      []Balance `json:"stores"`
	Entries     []Entry   `json:"entries"`
	SalesCount  int       `json:"sales_count"`
	SalesAmount string    `json:"sales_amount"`
}

// entriesSQL — журнал покупателя с остатком после каждой записи. $1 — покупатель, $2 — магазины.
const entriesSQL = `
	SELECT e.id, e.store_id, st.name, e.doc_type, e.doc_id,
	       COALESCE(sl.number, dp.number, cr.number, wo.number),
	       e.amount::text,
	       (sum(e.amount) OVER (PARTITION BY e.store_id ORDER BY e.created_at, e.id))::numeric(18,2)::text,
	       CASE e.doc_type
	            WHEN 'sale' THEN (SELECT count(*) FROM sale_items si WHERE si.sale_id = sl.id)::text || ' поз. · чек ' || sl.total::numeric(18,0)::text
	            WHEN 'payment' THEN COALESCE(pm.name, '')
	            WHEN 'return' THEN 'возврат по чеку № ' || COALESCE((SELECT s2.number FROM sales s2 WHERE s2.id = cr.sale_id)::text, '')
	            WHEN 'writeoff' THEN wo.reason END,
	       COALESCE(es.full_name, ep.full_name, er.full_name, ew.full_name, ''),
	       COALESCE((SELECT dd.status FROM debt_disputes dd WHERE dd.entry_id = e.id ORDER BY dd.created_at DESC LIMIT 1), ''),
	       e.created_at
	FROM debt_entries e
	JOIN stores st ON st.id = e.store_id
	LEFT JOIN sales sl ON e.doc_type = 'sale' AND sl.id = e.doc_id
	LEFT JOIN employees es ON es.id = sl.cashier_id
	LEFT JOIN debt_payments dp ON e.doc_type = 'payment' AND dp.id = e.doc_id
	LEFT JOIN payment_methods pm ON pm.id = dp.payment_method_id
	LEFT JOIN employees ep ON ep.id = dp.created_by
	LEFT JOIN customer_returns cr ON e.doc_type = 'return' AND cr.id = e.doc_id
	LEFT JOIN employees er ON er.id = cr.created_by
	LEFT JOIN debt_writeoffs wo ON e.doc_type = 'writeoff' AND wo.id = e.doc_id
	LEFT JOIN employees ew ON ew.id = wo.created_by
	WHERE e.debtor_id = $1 AND ($2::uuid[] IS NULL OR e.store_id = ANY($2))`

func scanEntry(r pgx.CollectableRow) (Entry, error) {
	var e Entry
	var detail *string
	err := r.Scan(&e.ID, &e.StoreID, &e.StoreName, &e.DocType, &e.DocID, &e.Number, &e.Amount, &e.Balance, &detail,
		&e.Employee, &e.Disputed, &e.CreatedAt)
	if detail != nil {
		e.Detail = *detail
	}
	return e, err
}

func entries(ctx context.Context, q db.Querier, debtorID string, stores []string, limit int) ([]Entry, error) {
	var storeArg any
	if stores != nil {
		storeArg = stores
	}
	rows, err := q.Query(ctx, `SELECT * FROM (`+entriesSQL+`) x ORDER BY created_at DESC, id DESC LIMIT $3`, debtorID, storeArg, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanEntry)
}

func (s *Service) Card(ctx context.Context, p *identity.Principal, id, storeID string) (DebtorCard, error) {
	var c DebtorCard
	if err := p.RequireAny(identity.PermDebtsManage, identity.PermDebtsGive); err != nil {
		return c, err
	}
	stores, err := storeScope(p, storeID)
	if err != nil {
		return c, err
	}
	if !httpx.IsUUID(id) {
		return c, apperr.NotFound("покупатель не найден")
	}
	err = s.pool.QueryRow(ctx, `
		SELECT id, phone, full_name, credit_limit::text, blocked, verified_at IS NOT NULL, note, created_at
		FROM debtors WHERE id = $1 AND network_id = $2`, id, p.NetworkID).
		Scan(&c.ID, &c.Phone, &c.FullName, &c.OwnLimit, &c.Blocked, &c.Verified, &c.Note, &c.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.NotFound("покупатель не найден")
	}
	if err != nil {
		return c, err
	}
	if c.HasApp, err = hasApp(ctx, s.pool, c.Phone); err != nil {
		return c, err
	}
	if c.Stores, err = s.balances(ctx, s.pool, p.NetworkID, stores, &c.ID, ""); err != nil {
		return c, err
	}
	if c.Entries, err = entries(ctx, s.pool, c.ID, stores, 200); err != nil {
		return c, err
	}
	var storeArg any
	if stores != nil {
		storeArg = stores
	}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, COALESCE(sum(debt_amount), 0)::numeric(18,2)::text FROM sales
		WHERE debtor_id = $1 AND debt_amount > 0 AND ($2::uuid[] IS NULL OR store_id = ANY($2))
		  AND sold_at > now() - interval '60 days'`, c.ID, storeArg).Scan(&c.SalesCount, &c.SalesAmount)
	return c, err
}

type DebtorInput struct {
	FullName    *string                      `json:"full_name"`
	CreditLimit httpx.Optional[money.Amount] `json:"credit_limit"`
	Blocked     *bool                        `json:"blocked"`
	Note        *string                      `json:"note"`
}

func (s *Service) Update(ctx context.Context, p *identity.Principal, id string, in DebtorInput) (DebtorCard, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return DebtorCard{}, err
	}
	if !httpx.IsUUID(id) {
		return DebtorCard{}, apperr.NotFound("покупатель не найден")
	}
	if in.FullName != nil {
		n := strings.TrimSpace(*in.FullName)
		if len([]rune(n)) > 120 {
			return DebtorCard{}, apperr.Validation("full_name: не длиннее 120 символов")
		}
		in.FullName = &n
	}
	var limit *string
	if in.CreditLimit.Set && in.CreditLimit.Value != nil {
		v := *in.CreditLimit.Value
		if !v.Valid() || money.D(string(v)).Sign() < 0 {
			return DebtorCard{}, apperr.Validation("credit_limit: неверная сумма")
		}
		sv := string(v)
		limit = &sv
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE debtors SET full_name = COALESCE($3, full_name),
		       credit_limit = CASE WHEN $4 THEN $5::numeric ELSE credit_limit END,
		       blocked = COALESCE($6, blocked), note = COALESCE($7, note)
		WHERE id = $1 AND network_id = $2`,
		id, p.NetworkID, in.FullName, in.CreditLimit.Set, limit, in.Blocked, in.Note)
	if err != nil {
		return DebtorCard{}, err
	}
	if tag.RowsAffected() == 0 {
		return DebtorCard{}, apperr.NotFound("покупатель не найден")
	}
	return s.Card(ctx, p, id, "")
}

// ------------------------------------------------------------- погашение

type PaymentInput struct {
	DebtorID        string       `json:"debtor_id"`
	Phone           string       `json:"phone"` // касса может указать номер вместо id
	StoreID         string       `json:"store_id"`
	Amount          money.Amount `json:"amount"`
	PaymentMethodID string       `json:"payment_method_id"`
	Note            string       `json:"note"`
	// Только касса.
	ClientUID string     `json:"client_uid"`
	ShiftID   *string    `json:"shift_id"`
	PaidAt    *time.Time `json:"paid_at"`
}

type Payment struct {
	ID       string    `json:"id"`
	Number   int64     `json:"number"`
	DebtorID string    `json:"debtor_id"`
	StoreID  string    `json:"store_id"`
	Amount   string    `json:"amount"`
	Method   string    `json:"payment_method"`
	Kind     string    `json:"payment_kind"`
	Balance  string    `json:"balance"` // долг в магазине после оплаты
	PaidAt   time.Time `json:"paid_at"`
	FullName string    `json:"full_name"`
	Phone    string    `json:"phone"`
}

// Pay принимает оплату долга: деньги — в кассу способа оплаты, долг — меньше.
// Больше долга принять нельзя.
func (s *Service) Pay(ctx context.Context, p *identity.Principal, in PaymentInput) (Payment, bool, error) {
	pos := p.DeviceID != ""
	if pos {
		if err := p.RequireAny(identity.PermDebtsGive, identity.PermDebtsManage, identity.PermSalesPOS); err != nil {
			return Payment{}, false, err
		}
		in.StoreID = p.StoreIDs[0]
		in.ClientUID = strings.TrimSpace(in.ClientUID)
		if len(in.ClientUID) < 8 || len(in.ClientUID) > 64 {
			return Payment{}, false, apperr.Validation("client_uid: 8–64 символа")
		}
		if in.ShiftID == nil || !httpx.IsUUID(*in.ShiftID) {
			return Payment{}, false, apperr.Validation("shift_id: погашение с кассы — только в смене")
		}
		var existing string
		err := s.pool.QueryRow(ctx, `SELECT id FROM debt_payments WHERE network_id = $1 AND client_uid = $2`, p.NetworkID, in.ClientUID).Scan(&existing)
		if err == nil {
			pay, err := s.payment(ctx, s.pool, p.NetworkID, existing)
			return pay, false, err
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return Payment{}, false, err
		}
	} else {
		if err := p.Require(identity.PermDebtsManage); err != nil {
			return Payment{}, false, err
		}
		in.ClientUID, in.ShiftID, in.PaidAt = "", nil, nil
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return Payment{}, false, apperr.Validation("store_id: магазин не найден")
	}
	if !in.Amount.Valid() || money.D(string(in.Amount)).Sign() <= 0 {
		return Payment{}, false, apperr.Validation("amount: сумма должна быть больше нуля")
	}
	if !httpx.IsUUID(in.PaymentMethodID) {
		return Payment{}, false, apperr.Validation("payment_method_id: укажите способ оплаты")
	}
	paidAt := s.now()
	if in.PaidAt != nil {
		if in.PaidAt.After(paidAt.Add(5*time.Minute)) || in.PaidAt.Before(paidAt.Add(-7*24*time.Hour)) {
			return Payment{}, false, apperr.Validation("paid_at: время вне допустимого окна")
		}
		paidAt = *in.PaidAt
	}
	amount := money.D(string(in.Amount))
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		debtorID, err := s.resolveDebtor(ctx, tx, p.NetworkID, in.DebtorID, in.Phone)
		if err != nil {
			return err
		}
		if err := lockDebtor(ctx, tx, debtorID); err != nil {
			return err
		}
		if pos {
			if err := s.checkShift(ctx, tx, *in.ShiftID, p.DeviceID, paidAt); err != nil {
				return err
			}
		}
		bal, err := storeBalance(ctx, tx, debtorID, in.StoreID)
		if err != nil {
			return err
		}
		if bal.Sign() <= 0 {
			return apperr.Conflict("no_debt", "у покупателя нет долга в этом магазине")
		}
		if amount.Cmp(bal) > 0 {
			return apperr.Conflict("payment_exceeds_debt", "сумма больше долга: "+money.Group(bal.Money())+" сум").
				WithDetails(map[string]any{"debt": bal.Money()})
		}
		cashboxID, currency, methodStore, err := finance.PaymentMethodCashbox(ctx, tx, p.NetworkID, in.PaymentMethodID)
		if err != nil {
			return err
		}
		if methodStore == nil || *methodStore != in.StoreID || currency != "UZS" {
			return apperr.Validation("payment_method_id: способ оплаты не относится к кассе этого магазина")
		}
		n, err := db.NextNumber(ctx, tx, "debt_payments", p.NetworkID, "")
		if err != nil {
			return err
		}
		var device any
		if pos {
			device = p.DeviceID
		}
		var uid any
		if in.ClientUID != "" {
			uid = in.ClientUID
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO debt_payments (network_id, number, client_uid, debtor_id, store_id, amount, payment_method_id, cashbox_id,
			                           note, created_by, device_id, shift_id, paid_at)
			VALUES ($1, $2, $3, $4, $5, $6::numeric, $7, $8, $9, $10, $11, $12, $13) RETURNING id`,
			p.NetworkID, n, uid, debtorID, in.StoreID, amount.Money(), in.PaymentMethodID, cashboxID,
			strings.TrimSpace(in.Note), p.EmployeeID, device, in.ShiftID, paidAt).Scan(&id); err != nil {
			if db.IsUniqueViolation(err, "debt_payments_client_uid") {
				return errDuplicate
			}
			return err
		}
		if err := finance.AddCash(ctx, tx, p.NetworkID, cashboxID, amount.Money(), DocCashPayment, id); err != nil {
			return err
		}
		if _, err := addEntry(ctx, tx, p.NetworkID, debtorID, in.StoreID, amount.Neg(), DocPayment, id); err != nil {
			return err
		}
		var ph string
		if err := tx.QueryRow(ctx, `SELECT phone FROM debtors WHERE id = $1`, debtorID).Scan(&ph); err != nil {
			return err
		}
		left := bal.Sub(amount)
		body := "−%s сум. Долг в этом магазине погашен"
		if left.Sign() > 0 {
			body = "−%s сум. Осталось " + money.Group(left.Money()) + " сум"
		}
		return notifyBuyer(ctx, tx, ph, in.StoreID, "debt_paid", "Оплата долга принята · %s", body, amount)
	})
	if errors.Is(err, errDuplicate) {
		return s.Pay(ctx, p, in)
	}
	if err != nil {
		return Payment{}, false, err
	}
	pay, err := s.payment(ctx, s.pool, p.NetworkID, id)
	return pay, true, err
}

var errDuplicate = errors.New("duplicate client_uid")

func (s *Service) resolveDebtor(ctx context.Context, q db.Querier, networkID, id, rawPhone string) (string, error) {
	var out string
	var err error
	if id != "" {
		if !httpx.IsUUID(id) {
			return "", apperr.NotFound("покупатель не найден")
		}
		err = q.QueryRow(ctx, `SELECT id FROM debtors WHERE id = $1 AND network_id = $2`, id, networkID).Scan(&out)
	} else {
		ph, perr := normPhone(rawPhone)
		if perr != nil {
			return "", perr
		}
		err = q.QueryRow(ctx, `SELECT id FROM debtors WHERE phone = $1 AND network_id = $2`, ph, networkID).Scan(&out)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("покупатель не найден")
	}
	return out, err
}

func (s *Service) payment(ctx context.Context, q db.Querier, networkID, id string) (Payment, error) {
	var pay Payment
	err := q.QueryRow(ctx, `
		SELECT dp.id, dp.number, dp.debtor_id, dp.store_id, dp.amount::text, m.name, m.kind,
		       (SELECT COALESCE(sum(e.amount), 0) FROM debt_entries e WHERE e.debtor_id = dp.debtor_id AND e.store_id = dp.store_id)::numeric(18,2)::text,
		       dp.paid_at, d.full_name, d.phone
		FROM debt_payments dp JOIN payment_methods m ON m.id = dp.payment_method_id JOIN debtors d ON d.id = dp.debtor_id
		WHERE dp.id = $1 AND dp.network_id = $2`, id, networkID).
		Scan(&pay.ID, &pay.Number, &pay.DebtorID, &pay.StoreID, &pay.Amount, &pay.Method, &pay.Kind, &pay.Balance,
			&pay.PaidAt, &pay.FullName, &pay.Phone)
	return pay, err
}

// --------------------------------------------------------------- списание

type WriteoffInput struct {
	DebtorID string       `json:"debtor_id"`
	StoreID  string       `json:"store_id"`
	Amount   money.Amount `json:"amount"`
	Reason   string       `json:"reason"`
}

type Writeoff struct {
	ID      string `json:"id"`
	Number  int64  `json:"number"`
	Amount  string `json:"amount"`
	Balance string `json:"balance"`
}

// Writeoff списывает безнадёжный долг (в «Прибыли и убытке» — расход).
func (s *Service) Writeoff(ctx context.Context, p *identity.Principal, in WriteoffInput) (Writeoff, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return Writeoff{}, err
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return Writeoff{}, apperr.Validation("store_id: магазин не найден")
	}
	if !in.Amount.Valid() || money.D(string(in.Amount)).Sign() <= 0 {
		return Writeoff{}, apperr.Validation("amount: сумма должна быть больше нуля")
	}
	in.Reason = strings.TrimSpace(in.Reason)
	if in.Reason == "" || len([]rune(in.Reason)) > 300 {
		return Writeoff{}, apperr.Validation("reason: укажите причину (до 300 символов)")
	}
	var out Writeoff
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		out, err = writeoff(ctx, tx, p, in.DebtorID, in.StoreID, money.D(string(in.Amount)), in.Reason)
		return err
	})
	return out, err
}

func writeoff(ctx context.Context, tx pgx.Tx, p *identity.Principal, debtorID, storeID string, amount money.Dec, reason string) (Writeoff, error) {
	var out Writeoff
	var tmp string
	if !httpx.IsUUID(debtorID) {
		return out, apperr.NotFound("покупатель не найден")
	}
	if err := tx.QueryRow(ctx, `SELECT id FROM debtors WHERE id = $1 AND network_id = $2`, debtorID, p.NetworkID).Scan(&tmp); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return out, apperr.NotFound("покупатель не найден")
		}
		return out, err
	}
	if err := lockDebtor(ctx, tx, debtorID); err != nil {
		return out, err
	}
	bal, err := storeBalance(ctx, tx, debtorID, storeID)
	if err != nil {
		return out, err
	}
	if amount.Cmp(bal) > 0 {
		return out, apperr.Conflict("writeoff_exceeds_debt", "сумма больше долга: "+money.Group(bal.Money())+" сум").
			WithDetails(map[string]any{"debt": bal.Money()})
	}
	n, err := db.NextNumber(ctx, tx, "debt_writeoffs", p.NetworkID, "")
	if err != nil {
		return out, err
	}
	if err := tx.QueryRow(ctx, `
		INSERT INTO debt_writeoffs (network_id, number, debtor_id, store_id, amount, reason, created_by)
		VALUES ($1, $2, $3, $4, $5::numeric, $6, $7) RETURNING id`,
		p.NetworkID, n, debtorID, storeID, amount.Money(), reason, p.EmployeeID).Scan(&out.ID); err != nil {
		return out, err
	}
	if _, err := addEntry(ctx, tx, p.NetworkID, debtorID, storeID, amount.Neg(), DocWriteoff, out.ID); err != nil {
		return out, err
	}
	out.Number, out.Amount, out.Balance = n, amount.Money(), bal.Sub(amount).Money()
	return out, nil
}

// ------------------------------------------------------------------ споры

type Dispute struct {
	ID        string     `json:"id"`
	EntryID   int64      `json:"entry_id"`
	DebtorID  string     `json:"debtor_id"`
	FullName  string     `json:"full_name"`
	Phone     string     `json:"phone"`
	StoreID   string     `json:"store_id"`
	StoreName string     `json:"store_name"`
	Amount    string     `json:"amount"`
	DocType   string     `json:"doc_type"`
	Number    *int64     `json:"number"`
	Comment   string     `json:"comment"`
	Status    string     `json:"status"`
	Cashier   string     `json:"cashier"`
	EntryAt   time.Time  `json:"entry_at"`
	CreatedAt time.Time  `json:"created_at"`
	Resolved  *time.Time `json:"resolved_at"`
}

const disputeSelect = `
	SELECT dd.id, e.id, d.id, d.full_name, d.phone, st.id, st.name, e.amount::text, e.doc_type, sl.number, dd.comment, dd.status,
	       COALESCE(emp.full_name, ''), e.created_at, dd.created_at, dd.resolved_at
	FROM debt_disputes dd
	JOIN debt_entries e ON e.id = dd.entry_id
	JOIN debtors d ON d.id = e.debtor_id
	JOIN stores st ON st.id = e.store_id
	LEFT JOIN sales sl ON e.doc_type = 'sale' AND sl.id = e.doc_id
	LEFT JOIN employees emp ON emp.id = sl.cashier_id`

func (s *Service) Disputes(ctx context.Context, p *identity.Principal, storeID, status string) ([]Dispute, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return nil, err
	}
	stores, err := storeScope(p, storeID)
	if err != nil {
		return nil, err
	}
	if status == "" {
		status = "open"
	}
	var storeArg any
	if stores != nil {
		storeArg = stores
	}
	rows, err := s.pool.Query(ctx, disputeSelect+`
		WHERE dd.network_id = $1 AND ($2::uuid[] IS NULL OR e.store_id = ANY($2)) AND ($3 = 'all' OR dd.status = $3)
		ORDER BY dd.created_at DESC LIMIT 200`, p.NetworkID, storeArg, status)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Dispute])
}

type ResolveInput struct {
	Status string `json:"status"` // accepted — запись ошибочна, долг списывается; rejected — запись верна
}

func (s *Service) Resolve(ctx context.Context, p *identity.Principal, id string, in ResolveInput) (Dispute, error) {
	if err := p.Require(identity.PermDebtsManage); err != nil {
		return Dispute{}, err
	}
	if in.Status != "accepted" && in.Status != "rejected" {
		return Dispute{}, apperr.Validation("status: accepted или rejected")
	}
	if !httpx.IsUUID(id) {
		return Dispute{}, apperr.NotFound("спор не найден")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var debtorID, storeID, amount, status string
		err := tx.QueryRow(ctx, `
			SELECT e.debtor_id, e.store_id, e.amount::text, dd.status FROM debt_disputes dd JOIN debt_entries e ON e.id = dd.entry_id
			WHERE dd.id = $1 AND dd.network_id = $2 FOR UPDATE OF dd`, id, p.NetworkID).Scan(&debtorID, &storeID, &amount, &status)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(storeID)) {
			return apperr.NotFound("спор не найден")
		}
		if err != nil {
			return err
		}
		if status != "open" {
			return apperr.Conflict("dispute_resolved", "спор уже рассмотрен")
		}
		if in.Status == "accepted" && money.D(amount).Sign() > 0 {
			bal, err := storeBalance(ctx, tx, debtorID, storeID)
			if err != nil {
				return err
			}
			if part := money.D(amount).Min(bal); part.Sign() > 0 {
				if _, err := writeoff(ctx, tx, p, debtorID, storeID, part, "Спор «Это не я» принят"); err != nil {
					return err
				}
			}
		}
		_, err = tx.Exec(ctx, `UPDATE debt_disputes SET status = $2, resolved_by = $3, resolved_at = now() WHERE id = $1`,
			id, in.Status, p.EmployeeID)
		return err
	})
	if err != nil {
		return Dispute{}, err
	}
	rows, err := s.pool.Query(ctx, disputeSelect+` WHERE dd.id = $1`, id)
	if err != nil {
		return Dispute{}, err
	}
	return pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Dispute])
}
