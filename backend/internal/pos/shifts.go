package pos

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Смена кассы: размен на начало, продажи и возвраты, внесения и изъятия,
// пересчёт наличных на закрытии. Все действия идемпотентны по client_uid —
// касса досылает их после работы без интернета.

type Shift struct {
	ID           string     `json:"id"`
	Number       int64      `json:"number"`
	StoreID      string     `json:"store_id"`
	StoreName    string     `json:"store_name"`
	DeviceID     string     `json:"device_id"`
	DeviceName   string     `json:"device_name"`
	OpenedBy     string     `json:"opened_by"`
	OpenedByName string     `json:"opened_by_name"`
	OpenedAt     time.Time  `json:"opened_at"`
	OpeningCash  string     `json:"opening_cash"`
	ClosedBy     *string    `json:"closed_by"`
	ClosedByName *string    `json:"closed_by_name"`
	ClosedAt     *time.Time `json:"closed_at"`
	ExpectedCash *string    `json:"expected_cash"`
	CountedCash  *string    `json:"counted_cash"`
	Diff         *string    `json:"diff"`
	DiffReason   string     `json:"diff_reason"`
	// Откуда закрыта: pos — на кассе, pos_stale — касса закрыла свою старую
	// смену, оставшуюся открытой на сервере, panel — в панели магазина.
	ClosedVia *string `json:"closed_via"`
	// Чеков и выручка смены — для списков («Продажи сегодня» по сменам).
	SalesCount int     `json:"sales_count"`
	SalesTotal string  `json:"sales_total"`
	Report     *Report `json:"report,omitempty"`
}

const shiftSelect = `
	SELECT sh.id, sh.number, sh.store_id, st.name, sh.device_id, d.name, sh.opened_by, oe.full_name, sh.opened_at,
	       sh.opening_cash::text, sh.closed_by, ce.full_name, sh.closed_at, sh.expected_cash::text, sh.counted_cash::text,
	       sh.diff::text, sh.diff_reason, sh.closed_via,
	       (SELECT count(*) FROM sales WHERE shift_id = sh.id)::int,
	       (SELECT COALESCE(sum(total), 0) FROM sales WHERE shift_id = sh.id)::numeric(18,2)::text
	FROM pos_shifts sh
	JOIN stores st ON st.id = sh.store_id
	JOIN pos_devices d ON d.id = sh.device_id
	JOIN employees oe ON oe.id = sh.opened_by
	LEFT JOIN employees ce ON ce.id = sh.closed_by`

func scanShift(r pgx.CollectableRow) (Shift, error) {
	var s Shift
	err := r.Scan(&s.ID, &s.Number, &s.StoreID, &s.StoreName, &s.DeviceID, &s.DeviceName, &s.OpenedBy, &s.OpenedByName,
		&s.OpenedAt, &s.OpeningCash, &s.ClosedBy, &s.ClosedByName, &s.ClosedAt, &s.ExpectedCash, &s.CountedCash,
		&s.Diff, &s.DiffReason, &s.ClosedVia, &s.SalesCount, &s.SalesTotal)
	return s, err
}

// MethodTotal — продажи и возвраты одним способом оплаты.
type MethodTotal struct {
	PaymentMethodID string `json:"payment_method_id"`
	Name            string `json:"name"`
	Kind            string `json:"kind"`
	Sales           string `json:"sales"`
	Returns         string `json:"returns"`
}

// Report — X-отчёт смены (на закрытии он же Z-отчёт).
type Report struct {
	SalesCount   int           `json:"sales_count"`
	SalesTotal   string        `json:"sales_total"`
	Discounts    string        `json:"discounts"`
	ReturnsCount int           `json:"returns_count"`
	ReturnsTotal string        `json:"returns_total"`
	ByMethod     []MethodTotal `json:"by_method"`
	CashIn       string        `json:"cash_in"`
	CashOut      string        `json:"cash_out"`
	CashSales    string        `json:"cash_sales"`
	CashReturns  string        `json:"cash_returns"`
	// Размен + наличные продажи − наличные возвраты + внесения − изъятия.
	ExpectedCash string `json:"expected_cash"`
	// Чеки без фискального признака — их касса ещё не досылала.
	FiscalPending int `json:"fiscal_pending"`
	// Долги покупателей: отпущено в долг и погашено за смену.
	debts.ShiftDebt
}

func (s *Service) shift(ctx context.Context, q db.Querier, p *identity.Principal, id string) (Shift, error) {
	if !httpx.IsUUID(id) {
		return Shift{}, apperr.NotFound("смена не найдена").Uz("smena topilmadi")
	}
	rows, err := q.Query(ctx, shiftSelect+` WHERE sh.id = $1 AND sh.network_id = $2`, id, p.NetworkID)
	if err != nil {
		return Shift{}, err
	}
	sh, err := pgx.CollectExactlyOneRow(rows, scanShift)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (!p.CanAccessStore(sh.StoreID) || (p.DeviceID != "" && sh.DeviceID != p.DeviceID))) {
		return Shift{}, apperr.NotFound("смена не найдена").Uz("smena topilmadi")
	}
	return sh, err
}

func (s *Service) report(ctx context.Context, q db.Querier, sh Shift) (Report, error) {
	r := Report{ByMethod: []MethodTotal{}}
	err := q.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM sales WHERE shift_id = $1)::int,
		       (SELECT COALESCE(sum(total), 0) FROM sales WHERE shift_id = $1)::numeric(18,2)::text,
		       (SELECT COALESCE(sum(discount), 0) FROM sales WHERE shift_id = $1)::numeric(18,2)::text,
		       (SELECT count(*) FROM customer_returns WHERE shift_id = $1)::int,
		       (SELECT COALESCE(sum(total), 0) FROM customer_returns WHERE shift_id = $1)::numeric(18,2)::text,
		       (SELECT COALESCE(sum(amount), 0) FROM pos_cash_moves WHERE shift_id = $1 AND kind = 'in')::numeric(18,2)::text,
		       (SELECT COALESCE(sum(amount), 0) FROM pos_cash_moves WHERE shift_id = $1 AND kind = 'out')::numeric(18,2)::text,
		       (SELECT COALESCE(sum(sp.amount), 0) FROM sale_payments sp JOIN sales sl ON sl.id = sp.sale_id
		          JOIN payment_methods m ON m.id = sp.payment_method_id WHERE sl.shift_id = $1 AND m.kind = 'cash')::numeric(18,2)::text,
		       (SELECT COALESCE(sum(cr.total - cr.debt_amount), 0) FROM customer_returns cr JOIN payment_methods m ON m.id = cr.payment_method_id
		          WHERE cr.shift_id = $1 AND m.kind = 'cash')::numeric(18,2)::text,
		       (SELECT count(*) FROM sales WHERE shift_id = $1 AND fiscal_status = 'pending')::int`, sh.ID).Scan(
		&r.SalesCount, &r.SalesTotal, &r.Discounts, &r.ReturnsCount, &r.ReturnsTotal, &r.CashIn, &r.CashOut,
		&r.CashSales, &r.CashReturns, &r.FiscalPending)
	if err != nil {
		return r, err
	}
	if r.ShiftDebt, err = debts.ShiftTotals(ctx, q, sh.ID); err != nil {
		return r, err
	}
	// Наличные погашения долгов тоже лежат в ящике.
	r.ExpectedCash = money.D(sh.OpeningCash).Add(money.D(r.CashSales)).Sub(money.D(r.CashReturns)).
		Add(money.D(r.CashIn)).Sub(money.D(r.CashOut)).Add(money.D(r.PaidCash)).Money()
	rows, err := q.Query(ctx, `
		WITH s AS (SELECT sp.payment_method_id AS m, sum(sp.amount) AS v FROM sale_payments sp JOIN sales sl ON sl.id = sp.sale_id
		           WHERE sl.shift_id = $1 GROUP BY 1),
		     r AS (SELECT payment_method_id AS m, sum(total - debt_amount) AS v FROM customer_returns WHERE shift_id = $1 GROUP BY 1)
		SELECT pm.id, pm.name, pm.kind, COALESCE(s.v, 0)::numeric(18,2)::text, COALESCE(r.v, 0)::numeric(18,2)::text
		FROM payment_methods pm LEFT JOIN s ON s.m = pm.id LEFT JOIN r ON r.m = pm.id
		WHERE s.m IS NOT NULL OR r.m IS NOT NULL
		ORDER BY CASE pm.kind WHEN 'cash' THEN 0 WHEN 'card' THEN 1 WHEN 'qr' THEN 2 ELSE 3 END, pm.name`, sh.ID)
	if err != nil {
		return r, err
	}
	r.ByMethod, err = pgx.CollectRows(rows, pgx.RowToStructByPos[MethodTotal])
	return r, err
}

func (s *Service) ShiftWithReport(ctx context.Context, p *identity.Principal, id string) (Shift, error) {
	sh, err := s.shift(ctx, s.pool, p, id)
	if err != nil {
		return sh, err
	}
	r, err := s.report(ctx, s.pool, sh)
	sh.Report = &r
	return sh, err
}

// eventTime — время действия на кассе (может быть в прошлом после офлайна).
func (s *Service) eventTime(at *time.Time) (time.Time, error) {
	now := s.now()
	if at == nil {
		return now, nil
	}
	if at.After(now.Add(5*time.Minute)) || at.Before(now.Add(-7*24*time.Hour)) {
		return time.Time{}, apperr.Validation("время действия на кассе вне допустимого окна").Uz("kassadagi amal vaqti ruxsat etilgan oraliqdan tashqarida")
	}
	return *at, nil
}

type OpenInput struct {
	ClientUID   string       `json:"client_uid"`
	OpenedAt    *time.Time   `json:"opened_at"`
	OpeningCash money.Amount `json:"opening_cash"`
}

// OpenShift открывает смену. Повтор с тем же client_uid возвращает её же.
func (s *Service) OpenShift(ctx context.Context, p *identity.Principal, in OpenInput) (Shift, bool, error) {
	if err := requireCashier(p); err != nil {
		return Shift{}, false, err
	}
	in.ClientUID = strings.TrimSpace(in.ClientUID)
	if len(in.ClientUID) < 8 || len(in.ClientUID) > 64 {
		return Shift{}, false, apperr.Validation("client_uid: 8–64 символа").Uz("client_uid: 8–64 belgi")
	}
	if in.OpeningCash == "" {
		in.OpeningCash = "0"
	}
	if !in.OpeningCash.Valid() || money.D(string(in.OpeningCash)).Sign() < 0 {
		return Shift{}, false, apperr.Validation("opening_cash: размен не может быть отрицательным").Uz("opening_cash: maydalik manfiy boʻlishi mumkin emas")
	}
	at, err := s.eventTime(in.OpenedAt)
	if err != nil {
		return Shift{}, false, err
	}
	var id string
	created := false
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT id FROM pos_shifts WHERE network_id = $1 AND client_uid = $2`, p.NetworkID, in.ClientUID).Scan(&id)
		if err == nil {
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var open string
		err = tx.QueryRow(ctx, `SELECT id FROM pos_shifts WHERE device_id = $1 AND closed_at IS NULL`, p.DeviceID).Scan(&open)
		if err == nil {
			return apperr.Conflict("shift_open", "на кассе уже открыта смена — закройте её").Uz("kassada smena allaqachon ochiq — uni yoping").WithDetails(map[string]any{"shift_id": open})
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		n, err := db.NextNumber(ctx, tx, "pos_shifts", p.NetworkID, "")
		if err != nil {
			return err
		}
		created = true
		return tx.QueryRow(ctx, `
			INSERT INTO pos_shifts (network_id, store_id, device_id, number, client_uid, opened_by, opened_at, opening_cash)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8::numeric) RETURNING id`,
			p.NetworkID, p.StoreIDs[0], p.DeviceID, n, in.ClientUID, p.EmployeeID, at, string(in.OpeningCash)).Scan(&id)
	})
	if err != nil {
		return Shift{}, false, err
	}
	sh, err := s.shift(ctx, s.pool, p, id)
	return sh, created, err
}

type CashMoveInput struct {
	ClientUID string       `json:"client_uid"`
	Kind      string       `json:"kind"` // in — внесение, out — изъятие
	Amount    money.Amount `json:"amount"`
	Reason    string       `json:"reason"`
	At        *time.Time   `json:"at"`
}

type CashMove struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Amount    string    `json:"amount"`
	Reason    string    `json:"reason"`
	CreatedAt time.Time `json:"created_at"`
}

// CashMove — внесение или изъятие наличных в смене (инкассация, размен).
func (s *Service) CashMove(ctx context.Context, p *identity.Principal, shiftID string, in CashMoveInput) (CashMove, error) {
	if err := requireCashier(p); err != nil {
		return CashMove{}, err
	}
	in.ClientUID, in.Reason = strings.TrimSpace(in.ClientUID), strings.TrimSpace(in.Reason)
	if len(in.ClientUID) < 8 || len(in.ClientUID) > 64 {
		return CashMove{}, apperr.Validation("client_uid: 8–64 символа").Uz("client_uid: 8–64 belgi")
	}
	if in.Kind != "in" && in.Kind != "out" {
		return CashMove{}, apperr.Validation("kind: in — внесение, out — изъятие").Uz("kind: in — kiritish, out — olish")
	}
	if !in.Amount.Valid() || money.D(string(in.Amount)).Sign() <= 0 {
		return CashMove{}, apperr.Validation("amount: сумма больше нуля").Uz("amount: summa noldan katta boʻlsin")
	}
	if len([]rune(in.Reason)) > 200 {
		return CashMove{}, apperr.Validation("reason: до 200 символов").Uz("reason: 200 belgigacha")
	}
	at, err := s.eventTime(in.At)
	if err != nil {
		return CashMove{}, err
	}
	sh, err := s.shift(ctx, s.pool, p, shiftID)
	if err != nil {
		return CashMove{}, err
	}
	var m CashMove
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var created bool
		err := tx.QueryRow(ctx, `
			WITH ins AS (
				INSERT INTO pos_cash_moves (network_id, shift_id, client_uid, kind, amount, reason, created_by, created_at)
				SELECT $1, $2, $3, $4, $5::numeric, $6, $7, $8
				WHERE NOT EXISTS (SELECT 1 FROM pos_cash_moves WHERE network_id = $1 AND client_uid = $3)
				RETURNING id, kind, amount, reason, created_at)
			SELECT id, kind, amount::text, reason, created_at, true FROM ins
			UNION ALL
			SELECT id, kind, amount::text, reason, created_at, false FROM pos_cash_moves WHERE network_id = $1 AND client_uid = $3`,
			p.NetworkID, sh.ID, in.ClientUID, in.Kind, string(in.Amount), in.Reason, p.EmployeeID, at).Scan(
			&m.ID, &m.Kind, &m.Amount, &m.Reason, &m.CreatedAt, &created)
		if err != nil || !created {
			return err
		}
		// Внесение и изъятие — это наличные ящика: касса магазина тоже.
		amount := money.D(m.Amount)
		if m.Kind == "out" {
			amount = amount.Neg()
		}
		return toDrawer(ctx, tx, p.NetworkID, sh.StoreID, amount, finance.DocPOSCashMove, m.ID)
	})
	return m, err
}

type CloseInput struct {
	CountedCash money.Amount `json:"counted_cash"`
	DiffReason  string       `json:"diff_reason"`
	ClosedAt    *time.Time   `json:"closed_at"`
	// Stale — касса закрывает свою старую смену, которая осталась открытой на
	// сервере (Z-отчёт не дошёл, сервер не принимает новую смену). Пересчёта
	// нет: без counted_cash сумма в ящике — по расчёту, расхождение 0.
	Stale bool `json:"stale"`
}

// CloseShift закрывает смену: кассир пересчитал наличные, сервер сравнивает
// с ожидаемым. Расхождение без причины не принимается. Повтор — та же смена.
func (s *Service) CloseShift(ctx context.Context, p *identity.Principal, shiftID string, in CloseInput) (Shift, error) {
	if err := requireCashier(p); err != nil {
		return Shift{}, err
	}
	via := "pos"
	if in.Stale {
		via = "pos_stale"
	}
	return s.closeShift(ctx, p, shiftID, in, via)
}

// StoreCloseShift — владелец закрывает в панели смену, которая осталась
// открытой (касса недоступна или Z-отчёт не дошёл). Право «Финансы».
func (s *Service) StoreCloseShift(ctx context.Context, p *identity.Principal, shiftID string, in CloseInput) (Shift, error) {
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return Shift{}, err
	}
	if p.EmployeeID == "" {
		return Shift{}, apperr.Forbidden("закрыть смену может только сотрудник сети").Uz("smenani faqat tarmoq xodimi yopishi mumkin")
	}
	in.Stale = false
	in.ClosedAt = nil
	return s.closeShift(ctx, p, shiftID, in, "panel")
}

func (s *Service) closeShift(ctx context.Context, p *identity.Principal, shiftID string, in CloseInput, via string) (Shift, error) {
	byExpected := in.Stale && strings.TrimSpace(string(in.CountedCash)) == ""
	if !byExpected && (!in.CountedCash.Valid() || money.D(string(in.CountedCash)).Sign() < 0) {
		return Shift{}, apperr.Validation("counted_cash: посчитанная сумма в ящике").Uz("counted_cash: qutidagi sanalgan summa")
	}
	in.DiffReason = strings.TrimSpace(in.DiffReason)
	if len([]rune(in.DiffReason)) > 300 {
		return Shift{}, apperr.Validation("diff_reason: до 300 символов").Uz("diff_reason: 300 belgigacha")
	}
	at, err := s.eventTime(in.ClosedAt)
	if err != nil {
		return Shift{}, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		sh, err := s.shift(ctx, tx, p, shiftID)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SELECT 1 FROM pos_shifts WHERE id = $1 FOR UPDATE`, sh.ID); err != nil {
			return err
		}
		if sh.ClosedAt != nil {
			return nil
		}
		if at.Before(sh.OpenedAt) {
			at = sh.OpenedAt
		}
		r, err := s.report(ctx, tx, sh)
		if err != nil {
			return err
		}
		counted := string(in.CountedCash)
		if byExpected {
			counted = r.ExpectedCash
		}
		diff := money.D(counted).Sub(money.D(r.ExpectedCash))
		if diff.Sign() != 0 && in.DiffReason == "" {
			return apperr.Validation("diff_reason: укажите причину расхождения").Uz("diff_reason: farq sababini kiriting").
				WithDetails(map[string]any{"expected_cash": r.ExpectedCash, "diff": diff.Money()})
		}
		if _, err = tx.Exec(ctx, `UPDATE pos_shifts SET closed_by = $2, closed_at = $3, expected_cash = $4::numeric,
			counted_cash = $5::numeric, diff = $6::numeric, diff_reason = $7, closed_via = $8 WHERE id = $1`,
			sh.ID, p.EmployeeID, at, r.ExpectedCash, counted, diff.Money(), in.DiffReason, via); err != nil {
			return err
		}
		// Пересчитали больше или меньше — касса магазина (ящик) тоже.
		return toDrawer(ctx, tx, p.NetworkID, sh.StoreID, diff, finance.DocShiftClose, sh.ID)
	})
	if err != nil {
		return Shift{}, err
	}
	return s.ShiftWithReport(ctx, p, shiftID)
}

// CurrentShift — открытая смена этой кассы (nil — смены нет).
func (s *Service) CurrentShift(ctx context.Context, p *identity.Principal) (*Shift, error) {
	var id string
	err := s.pool.QueryRow(ctx, `SELECT id FROM pos_shifts WHERE device_id = $1 AND closed_at IS NULL`, p.DeviceID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sh, err := s.ShiftWithReport(ctx, p, id)
	return &sh, err
}

// ListShifts — смены в панели магазина: расхождения видны сразу.
func (s *Service) ListShifts(ctx context.Context, p *identity.Principal, storeID string, page httpx.Page) ([]Shift, error) {
	if err := p.RequireAny(identity.PermReportsView, identity.PermFinanceManage); err != nil {
		return nil, err
	}
	if storeID != "" && !httpx.IsUUID(storeID) {
		return nil, apperr.Validation("store_id: неверный id").Uz("store_id: id notoʻgʻri")
	}
	rows, err := s.pool.Query(ctx, shiftSelect+`
		WHERE sh.network_id = $1 AND ($2 OR sh.store_id = ANY($3::uuid[])) AND ($4 = '' OR sh.store_id::text = $4)
		ORDER BY sh.opened_at DESC LIMIT $5 OFFSET $6`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, storeID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanShift)
}

func (s *Service) GetShift(ctx context.Context, p *identity.Principal, id string) (Shift, error) {
	if err := p.RequireAny(identity.PermReportsView, identity.PermFinanceManage); err != nil {
		return Shift{}, err
	}
	return s.ShiftWithReport(ctx, p, id)
}

// toDrawer — движение наличных ящика в кассе магазина (без проверки остатка:
// касса досылает то, что уже случилось). Нет кассы наличных — пропускаем.
func toDrawer(ctx context.Context, tx pgx.Tx, networkID, storeID string, amount money.Dec, docType, docID string) error {
	if amount.IsZero() {
		return nil
	}
	cb, err := finance.StoreCashbox(ctx, tx, networkID, storeID)
	if err != nil || cb == "" {
		return err
	}
	return finance.AddCash(ctx, tx, networkID, cb, amount.Money(), docType, docID)
}

// LeftInDrawer — сколько оставили в ящике магазина на размен (остаток кассы
// наличных), пока на кассах магазина нет открытых смен. nil — смена уже идёт
// или кассы нет: касса спрашивает размен как раньше.
func (s *Service) LeftInDrawer(ctx context.Context, p *identity.Principal) (*string, error) {
	if len(p.StoreIDs) == 0 {
		return nil, nil
	}
	storeID := p.StoreIDs[0]
	var open bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pos_shifts WHERE store_id = $1 AND closed_at IS NULL)`, storeID).Scan(&open); err != nil || open {
		return nil, err
	}
	cb, err := finance.StoreCashbox(ctx, s.pool, p.NetworkID, storeID)
	if err != nil || cb == "" {
		return nil, err
	}
	bal, err := finance.CashBalance(ctx, s.pool, cb)
	if err != nil || bal.Sign() <= 0 {
		return nil, err
	}
	v := bal.Fixed(0)
	return &v, nil
}
