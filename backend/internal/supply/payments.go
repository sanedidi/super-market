package supply

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// Оплаты магазина агенту (Figma «Оплаты поставщику»): деньги вносит
// магазин — кассовый расход контрагенту-агенту (в «Поставщиках» или в
// «Долгах»); агент подтверждает «Получил», «Другая сумма» или «Не получал».
// У агента долг магазина уменьшается только после подтверждения.

// Статусы оплаты.
const (
	PayPending   = "pending"
	PayConfirmed = "confirmed"
	PayDisputed  = "disputed"
)

// Payment — оплата магазина агенту.
type Payment struct {
	ID            string     `json:"id"`
	StoreID       string     `json:"store_id"`
	StoreName     string     `json:"store_name"`
	DistributorID string     `json:"distributor_id"`
	Distributor   string     `json:"distributor_name"`
	Amount        string     `json:"amount"`
	Received      *string    `json:"received"`
	Method        string     `json:"method"`
	Status        string     `json:"status"`
	Note          string     `json:"note"`
	AgentComment  string     `json:"agent_comment"`
	PhotoURL      string     `json:"photo_url"`
	Cashbox       string     `json:"cashbox_name"`
	CreatedBy     string     `json:"created_by"`
	CreatedAt     time.Time  `json:"created_at"`
	AnsweredAt    *time.Time `json:"answered_at"`
	ConfirmedAt   *time.Time `json:"confirmed_at"`
}

const paymentSelect = `
	SELECT sp.id, sp.store_id, s.name, sp.distributor_id, n.name, sp.amount::text, sp.received::text, sp.method, sp.status,
	       sp.note, sp.agent_comment, sp.photo_url, COALESCE(cb.name, ''), COALESCE(e.full_name, ''),
	       sp.created_at, sp.answered_at, sp.confirmed_at
	FROM supply_payments sp
	JOIN stores s   ON s.id = sp.store_id
	JOIN networks n ON n.id = sp.distributor_id
	LEFT JOIN cash_operations o ON o.id = sp.cash_operation_id
	LEFT JOIN cashboxes cb ON cb.id = o.cashbox_id
	LEFT JOIN employees e ON e.id = sp.created_by`

func getPayment(ctx context.Context, q db.Querier, id string) (Payment, error) {
	rows, err := q.Query(ctx, paymentSelect+` WHERE sp.id = $1`, id)
	if err != nil {
		return Payment{}, err
	}
	out, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Payment])
	if errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, errPaymentNotFound
	}
	return out, err
}

var errPaymentNotFound = apperr.NotFound("оплата не найдена").Uz("toʻlov topilmadi")

// payMetaKey — способ оплаты и фото чека из «Оплатить» (кассовая операция
// их не хранит).
type payMetaKey struct{}

type payMeta struct {
	method, photo, storeID string
}

// PaymentHook — для finance.Service.Payments.
func (s *Service) PaymentHook() finance.PaymentHook { return paymentHook{s} }

type paymentHook struct{ s *Service }

// AfterCounterpartyPayment — расход из кассы магазина контрагенту-агенту
// становится оплатой, которую ждёт агент.
func (h paymentHook) AfterCounterpartyPayment(ctx context.Context, tx pgx.Tx, p *identity.Principal, ev finance.PaymentEvent) error {
	if p.NetworkKind == KindDistributor {
		return nil
	}
	var distID *string
	if err := tx.QueryRow(ctx, `SELECT distributor_id FROM counterparties WHERE id = $1 AND network_id = $2`,
		ev.CounterpartyID, p.NetworkID).Scan(&distID); err != nil || distID == nil {
		return err
	}
	meta, _ := ctx.Value(payMetaKey{}).(payMeta)
	method := meta.method
	if method == "" {
		method = "cash"
	}
	// Магазин: указанный → касса магазина → первый подключённый.
	var storeID string
	err := tx.QueryRow(ctx, `
		SELECT l.store_id FROM supply_links l
		WHERE l.distributor_id = $1 AND l.store_network_id = $2
		ORDER BY (l.store_id::text = $3) DESC, (l.store_id::text = $4) DESC, (l.status = 'active') DESC, l.accepted_at NULLS LAST
		LIMIT 1`, *distID, p.NetworkID, meta.storeID, strOr(ev.CashboxStoreID)).Scan(&storeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // агент ни разу не был подключён к магазинам сети — обычная оплата
	}
	if err != nil {
		return err
	}
	var id string
	if err := tx.QueryRow(ctx, `
		INSERT INTO supply_payments (distributor_id, store_id, store_network_id, cash_operation_id, amount, method, note, photo_url, created_by)
		VALUES ($1, $2, $3, $4, $5::numeric, $6, $7, $8, $9) RETURNING id`,
		*distID, storeID, p.NetworkID, ev.OperationID, ev.AmountUZS, method, truncate(ev.Note, 500), meta.photo, p.EmployeeID).Scan(&id); err != nil {
		return err
	}
	name := storeName(ctx, tx, storeID)
	sum := money.Group(ev.AmountUZS)
	return h.s.pushAgent(ctx, tx, *distID, "supply_payment",
		i18n.Text{RU: fmt.Sprintf("«%s» отдал %s сум", name, sum), UZ: fmt.Sprintf("«%s» %s soʻm berdi", name, sum)},
		i18n.Text{RU: "Подтвердите, что получили деньги.", UZ: "Pulni olganingizni tasdiqlang."},
		map[string]string{"payment_id": id, "store_id": storeID})
}

func strOr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

// ---------------------------------------------------------------- агент

type PaymentsFilter struct {
	Status  string
	StoreID string
	Page    httpx.Page
}

// AgentPayments — оплаты магазинов агенту (новые сверху).
func (s *Service) AgentPayments(ctx context.Context, p *identity.Principal, f PaymentsFilter) ([]Payment, error) {
	if err := requireDistributor(p); err != nil {
		return nil, err
	}
	if f.Status != "" && f.Status != PayPending && f.Status != PayConfirmed && f.Status != PayDisputed && f.Status != "open" {
		return nil, apperr.Validation("status: pending, confirmed, disputed или open").Uz("status: pending, confirmed, disputed yoki open")
	}
	if f.StoreID != "" && !httpx.IsUUID(f.StoreID) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	rows, err := s.pool.Query(ctx, paymentSelect+`
		WHERE sp.distributor_id = $1
		  AND ($2 = '' OR sp.status = $2 OR ($2 = 'open' AND sp.status IN ('pending', 'disputed')))
		  AND ($3 = '' OR sp.store_id::text = $3)
		ORDER BY (sp.status = 'pending') DESC, sp.created_at DESC LIMIT $4 OFFSET $5`,
		p.NetworkID, f.Status, f.StoreID, f.Page.Limit, f.Page.Offset)
	return collect[Payment](rows, err)
}

// ConfirmPayment — «Получил»: долг магазина у агента уменьшается на сумму оплаты.
func (s *Service) ConfirmPayment(ctx context.Context, p *identity.Principal, id string) (Payment, error) {
	return s.answerPayment(ctx, p, id, nil, "")
}

// DisputeInput — «Другая сумма» (received) или «Не получал» (received = 0).
type DisputeInput struct {
	Received money.Amount `json:"received"`
	Comment  string       `json:"comment"`
}

func (s *Service) DisputePayment(ctx context.Context, p *identity.Principal, id string, in DisputeInput) (Payment, error) {
	r := strings.TrimSpace(string(in.Received))
	if r == "" {
		r = "0"
	}
	if !money.Amount(r).Valid() {
		return Payment{}, apperr.Validation("received: неверная сумма").Uz("received: summa notoʻgʻri")
	}
	if len([]rune(strings.TrimSpace(in.Comment))) > 500 {
		return Payment{}, apperr.Validation("comment: не длиннее 500 символов").Uz("comment: 500 belgidan oshmasin")
	}
	return s.answerPayment(ctx, p, id, &r, strings.TrimSpace(in.Comment))
}

// answerPayment — ответ агента на оплату: received == nil — «Получил».
func (s *Service) answerPayment(ctx context.Context, p *identity.Principal, id string, received *string, comment string) (Payment, error) {
	if err := requireDistributor(p); err != nil {
		return Payment{}, err
	}
	if err := p.RequireAny(identity.PermOrdersManage, identity.PermFinanceManage); err != nil {
		return Payment{}, err
	}
	if !httpx.IsUUID(id) {
		return Payment{}, errPaymentNotFound
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var status, amount, storeID string
		err := tx.QueryRow(ctx, `SELECT status, amount::text, store_id FROM supply_payments WHERE id = $1 AND distributor_id = $2 FOR UPDATE`,
			id, p.NetworkID).Scan(&status, &amount, &storeID)
		if errors.Is(err, pgx.ErrNoRows) {
			return errPaymentNotFound
		}
		if err != nil {
			return err
		}
		if status != PayPending {
			return apperr.Conflict("payment_answered", "вы уже ответили на эту оплату").Uz("bu toʻlovga allaqachon javob bergansiz")
		}
		if received == nil || money.D(*received).Cmp(money.D(amount)) == 0 {
			if err := s.confirm(ctx, tx, p.NetworkID, id, storeID, amount, comment); err != nil {
				return err
			}
			return push.EnqueueStaff(ctx, tx, storeID, identity.PermFinanceManage, "supply_payment_confirmed",
				i18n.Text{RU: "Агент подтвердил оплату", UZ: "Agent toʻlovni tasdiqladi"},
				i18n.Text{RU: fmt.Sprintf("%s сум получены.", money.Group(amount)), UZ: fmt.Sprintf("%s soʻm olindi.", money.Group(amount))},
				map[string]string{"payment_id": id})
		}
		if money.D(*received).Cmp(money.D(amount)) > 0 {
			return apperr.Validation("received: больше, чем отдал магазин — попросите магазин исправить сумму").Uz("received: doʻkon berganidan koʻp — doʻkondan summani tuzatishni soʻrang")
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_payments SET status = 'disputed', received = $2::numeric, agent_comment = $3, answered_at = now() WHERE id = $1`,
			id, *received, comment); err != nil {
			return err
		}
		body := i18n.Text{RU: fmt.Sprintf("Магазин указал %s сум, агент получил %s сум.", money.Group(amount), money.Group(*received)),
			UZ: fmt.Sprintf("Doʻkon %s soʻm koʻrsatdi, agent %s soʻm oldi.", money.Group(amount), money.Group(*received))}
		title := i18n.Text{RU: "Агент получил другую сумму", UZ: "Agent boshqa summa oldi"}
		if money.D(*received).Sign() == 0 {
			title = i18n.Text{RU: "Агент не получил оплату", UZ: "Agent toʻlovni olmadi"}
		}
		return push.EnqueueStaff(ctx, tx, storeID, identity.PermFinanceManage, "supply_payment_disputed", title, body,
			map[string]string{"payment_id": id})
	})
	if err != nil {
		return Payment{}, err
	}
	return getPayment(ctx, s.pool, id)
}

// confirm — оплата подтверждена: в журнале агента долг магазина уменьшается.
func (s *Service) confirm(ctx context.Context, tx pgx.Tx, distID, id, storeID, amount, comment string) error {
	cp, err := ensureCounterparty(ctx, tx, distID, nil, &storeID)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE supply_payments SET status = 'confirmed', received = $2::numeric, agent_comment = $3,
		       answered_at = COALESCE(answered_at, now()), confirmed_at = now() WHERE id = $1`, id, amount, comment); err != nil {
		return err
	}
	return finance.AddCounterparty(ctx, tx, distID, cp, amount, finance.DocSupplyPayment, id)
}

// ---------------------------------------------------------------- магазин

// PayInput — «Оплатить» поставщику-агенту из «SM Магазин».
type PayInput struct {
	Amount    money.Amount `json:"amount"`
	CashboxID string       `json:"cashbox_id"`
	Method    string       `json:"method"` // cash | transfer | card
	Note      string       `json:"note"`
	PhotoURL  string       `json:"photo_url"`
	StoreID   string       `json:"store_id"`
}

// PaySupplier — магазин отдал деньги агенту: расход из кассы контрагенту,
// оплата ждёт подтверждения агента.
func (s *Service) PaySupplier(ctx context.Context, p *identity.Principal, distributorID string, in PayInput) (Payment, error) {
	if err := requireStoreSide(p); err != nil {
		return Payment{}, err
	}
	if s.fin == nil {
		return Payment{}, errors.New("supply: finance не подключён")
	}
	if !httpx.IsUUID(distributorID) {
		return Payment{}, apperr.NotFound("поставщик не найден").Uz("yetkazib beruvchi topilmadi")
	}
	if in.Method == "" {
		in.Method = "cash"
	}
	if in.Method != "cash" && in.Method != "transfer" && in.Method != "card" {
		return Payment{}, apperr.Validation("method: cash, transfer или card").Uz("method: cash, transfer yoki card")
	}
	in.PhotoURL = strings.TrimSpace(in.PhotoURL)
	if len(in.PhotoURL) > 1000 || (in.PhotoURL != "" && !strings.HasPrefix(in.PhotoURL, "http")) {
		return Payment{}, apperr.Validation("photo_url: неверная ссылка").Uz("photo_url: havola notoʻgʻri")
	}
	if in.StoreID != "" && !httpx.IsUUID(in.StoreID) {
		return Payment{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	var linked bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM supply_links WHERE distributor_id = $1 AND store_network_id = $2)`,
		distributorID, p.NetworkID).Scan(&linked); err != nil {
		return Payment{}, err
	}
	if !linked {
		return Payment{}, apperr.NotFound("поставщик не найден").Uz("yetkazib beruvchi topilmadi")
	}
	cp, err := ensureCounterparty(ctx, s.pool, p.NetworkID, &distributorID, nil)
	if err != nil {
		return Payment{}, err
	}
	ctx = context.WithValue(ctx, payMetaKey{}, payMeta{method: in.Method, photo: in.PhotoURL, storeID: in.StoreID})
	op, err := s.fin.CreateCashOperation(ctx, p, finance.CashOperationInput{
		Kind: "expense", CashboxID: in.CashboxID, Amount: in.Amount, CounterpartyID: &cp, Note: in.Note,
	})
	if err != nil {
		return Payment{}, err
	}
	var id string
	if err := s.pool.QueryRow(ctx, `SELECT id FROM supply_payments WHERE cash_operation_id = $1`, op.ID).Scan(&id); err != nil {
		return Payment{}, err
	}
	return getPayment(ctx, s.pool, id)
}

// SupplierPayments — оплаты поставщику-агенту и их статусы (магазин).
func (s *Service) SupplierPayments(ctx context.Context, p *identity.Principal, distributorID string, page httpx.Page) ([]Payment, error) {
	if err := requireStoreSide(p); err != nil {
		return nil, err
	}
	if !httpx.IsUUID(distributorID) {
		return nil, apperr.NotFound("поставщик не найден").Uz("yetkazib beruvchi topilmadi")
	}
	rows, err := s.pool.Query(ctx, paymentSelect+`
		WHERE sp.store_network_id = $1 AND sp.distributor_id = $2 AND ($3 OR sp.store_id = ANY($4::uuid[]))
		ORDER BY (sp.status = 'disputed') DESC, sp.created_at DESC LIMIT $5 OFFSET $6`,
		p.NetworkID, distributorID, p.SeesAllStores(), p.StoreIDs, page.Limit, page.Offset)
	return collect[Payment](rows, err)
}

// ResolveInput — магазин исправляет сумму оплаты (в том числе соглашается с
// суммой агента).
type ResolveInput struct {
	Amount money.Amount `json:"amount"`
}

// ResolvePayment — «Согласиться» (сумма = сколько получил агент) или
// «Исправить сумму». Разница возвращается в кассу и в долг поставщику.
// Сумма совпала с ответом агента — оплата подтверждена, иначе снова ждёт агента.
func (s *Service) ResolvePayment(ctx context.Context, p *identity.Principal, id string, in ResolveInput) (Payment, error) {
	if err := requireStoreSide(p); err != nil {
		return Payment{}, err
	}
	if err := p.Require(identity.PermFinanceManage); err != nil {
		return Payment{}, err
	}
	if !httpx.IsUUID(id) {
		return Payment{}, errPaymentNotFound
	}
	if !in.Amount.Valid() {
		return Payment{}, apperr.Validation("amount: неверная сумма").Uz("amount: summa notoʻgʻri")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var (
			status, amount, distID, storeID, opID, cashboxID, cp string
			received, rate                                       *string
		)
		err := tx.QueryRow(ctx, `
			SELECT sp.status, sp.amount::text, sp.received::text, sp.distributor_id, sp.store_id, sp.cash_operation_id,
			       o.cashbox_id, o.counterparty_id, o.rate::text
			FROM supply_payments sp JOIN cash_operations o ON o.id = sp.cash_operation_id
			WHERE sp.id = $1 AND sp.store_network_id = $2 FOR UPDATE OF sp`, id, p.NetworkID).
			Scan(&status, &amount, &received, &distID, &storeID, &opID, &cashboxID, &cp, &rate)
		if errors.Is(err, pgx.ErrNoRows) {
			return errPaymentNotFound
		}
		if err != nil {
			return err
		}
		if !p.SeesAllStores() && !containsStr(p.StoreIDs, storeID) {
			return errPaymentNotFound
		}
		if status == PayConfirmed {
			return apperr.Conflict("payment_confirmed", "агент уже подтвердил эту оплату").Uz("agent bu toʻlovni allaqachon tasdiqlagan")
		}
		next := money.D(string(in.Amount))
		cur := money.D(amount)
		// «Не получал» и магазин согласен: оплаты не было — деньги в кассу, долг обратно.
		cancel := next.Sign() == 0 && status == PayDisputed && received != nil && money.D(*received).Sign() == 0
		if !cancel && (next.Sign() <= 0 || next.Cmp(cur) > 0) {
			return apperr.Validation(fmt.Sprintf("amount: от 1 до %s сум — чтобы доплатить, создайте новую оплату", money.Group(amount))).
				Uz(fmt.Sprintf("amount: 1 dan %s soʻmgacha — qoʻshimcha toʻlash uchun yangi toʻlov yarating", money.Group(amount)))
		}
		if delta := cur.Sub(next); delta.Sign() > 0 {
			// Магазин отдал меньше, чем записал: деньги — обратно в кассу
			// (в валюте кассы), долг поставщику — обратно.
			cash := delta.Money()
			if rate != nil {
				if err := tx.QueryRow(ctx, `SELECT round($1::numeric / $2::numeric, 2)::text`, delta.Money(), *rate).Scan(&cash); err != nil {
					return err
				}
			}
			if err := finance.AddCash(ctx, tx, p.NetworkID, cashboxID, cash, finance.DocSupplyPaymentFix, id); err != nil {
				return err
			}
			if err := finance.AddCounterparty(ctx, tx, p.NetworkID, cp, delta.Money(), finance.DocSupplyPaymentFix, id); err != nil {
				return err
			}
		}
		if cancel {
			_, err := tx.Exec(ctx, `UPDATE supply_payments SET status = 'cancelled', answered_at = COALESCE(answered_at, now()) WHERE id = $1`, id)
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_payments SET amount = $2::numeric WHERE id = $1`, id, next.Money()); err != nil {
			return err
		}
		if status == PayDisputed && received != nil && money.D(*received).Cmp(next) == 0 {
			return s.confirm(ctx, tx, distID, id, storeID, next.Money(), "")
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_payments SET status = 'pending', received = NULL, answered_at = NULL WHERE id = $1`, id); err != nil {
			return err
		}
		name := storeName(ctx, tx, storeID)
		return s.pushAgent(ctx, tx, distID, "supply_payment",
			i18n.Text{RU: fmt.Sprintf("«%s» исправил оплату: %s сум", name, money.Group(next.Money())), UZ: fmt.Sprintf("«%s» toʻlovni tuzatdi: %s soʻm", name, money.Group(next.Money()))},
			i18n.Text{RU: "Подтвердите, что получили деньги.", UZ: "Pulni olganingizni tasdiqlang."},
			map[string]string{"payment_id": id, "store_id": storeID})
	})
	if err != nil {
		return Payment{}, err
	}
	return getPayment(ctx, s.pool, id)
}

func containsStr(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------ акт сверки

// StoreStatement — акт сверки агента с магазином: отгрузки и подтверждённые
// оплаты; оплаты, которые ждут ответа, — отдельно (в долг ещё не входят).
type StoreStatement struct {
	Statement finance.Statement `json:"statement"`
	// Долг магазина агенту (плюс — магазин должен).
	Debt string `json:"debt"`
	// Оплаты, которые ждут ответа агента или с расхождением.
	Open []Payment `json:"open"`
	// Сумма оплат, которые магазин уже отдал, а агент ещё не подтвердил.
	PendingSum string `json:"pending_sum"`
}

func (s *Service) AgentStoreStatement(ctx context.Context, p *identity.Principal, storeID string, from, to *time.Time) (StoreStatement, error) {
	if err := requireDistributor(p); err != nil {
		return StoreStatement{}, err
	}
	if s.fin == nil {
		return StoreStatement{}, errors.New("supply: finance не подключён")
	}
	if !httpx.IsUUID(storeID) {
		return StoreStatement{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	var seen bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM supply_links WHERE store_id = $1 AND distributor_id = $2)`, storeID, p.NetworkID).Scan(&seen); err != nil {
		return StoreStatement{}, err
	}
	if !seen {
		return StoreStatement{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	cp, err := ensureCounterparty(ctx, s.pool, p.NetworkID, nil, &storeID)
	if err != nil {
		return StoreStatement{}, err
	}
	var out StoreStatement
	if out.Statement, err = s.fin.CounterpartyStatement(ctx, p, cp, from, to); err != nil {
		return out, err
	}
	out.Debt = money.D(out.Statement.Closing).Neg().Money()
	if err := s.pool.QueryRow(ctx, `SELECT (-COALESCE(sum(amount), 0))::numeric(18,2)::text FROM counterparty_entries WHERE counterparty_id = $1`, cp).Scan(&out.Debt); err != nil {
		return out, err
	}
	if out.Open, err = s.AgentPayments(ctx, p, PaymentsFilter{Status: "open", StoreID: storeID, Page: httpx.Page{Limit: 50}}); err != nil {
		return out, err
	}
	err = s.pool.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0)::numeric(18,2)::text FROM supply_payments
		WHERE distributor_id = $1 AND store_id = $2 AND status IN ('pending', 'disputed')`, p.NetworkID, storeID).Scan(&out.PendingSum)
	return out, err
}

// agentMoney — «Вам должны» и оплаты, которые ждут подтверждения (Главная агента).
func agentMoney(ctx context.Context, q db.Querier, networkID string) (owed string, owedStores, pending int, pendingSum string, err error) {
	err = q.QueryRow(ctx, `
		WITH b AS (SELECT c.id, -COALESCE(sum(e.amount), 0) AS v FROM counterparties c
		           LEFT JOIN counterparty_entries e ON e.counterparty_id = c.id
		           WHERE c.network_id = $1 AND c.store_id IS NOT NULL GROUP BY c.id)
		SELECT COALESCE(sum(v) FILTER (WHERE v > 0), 0)::numeric(18,2)::text, count(*) FILTER (WHERE v > 0)::int,
		       (SELECT count(*)::int FROM supply_payments WHERE distributor_id = $1 AND status = 'pending'),
		       (SELECT COALESCE(sum(amount), 0)::numeric(18,2)::text FROM supply_payments WHERE distributor_id = $1 AND status = 'pending')
		FROM b`, networkID).Scan(&owed, &owedStores, &pending, &pendingSum)
	return
}
