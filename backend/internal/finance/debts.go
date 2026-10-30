package finance

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Долги поставщикам (приложение магазина): кому и сколько, когда платили,
// акт сверки с остатком после каждой операции.

type Debt struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	Phone         string     `json:"phone"`
	INN           string     `json:"inn"`
	Balance       string     `json:"balance"` // плюс — мы должны, минус — нам должны
	LastPaymentAt *time.Time `json:"last_payment_at"`
	LastIncomeAt  *time.Time `json:"last_income_at"`
	// Дней без оплаты, пока мы должны: от последней оплаты, а если не платили — от первого прихода.
	DaysUnpaid *int `json:"days_unpaid"`
}

type Debts struct {
	WeOwe      string `json:"we_owe"`
	WeOweCount int    `json:"we_owe_count"`
	TheyOwe    string `json:"they_owe"`
	TheyCount  int    `json:"they_owe_count"`
	Items      []Debt `json:"items"`
}

// DebtsLongUnpaid — после скольких дней без оплаты долг подсвечивается.
const DebtsLongUnpaid = 14

const debtsSQL = `
	WITH b AS (
		SELECT c.id, c.name, c.phone, c.inn,
		       COALESCE(sum(e.amount), 0) AS balance,
		       max(e.created_at) FILTER (WHERE e.amount < 0 AND e.doc_type = 'cash_operation') AS paid_at,
		       max(e.created_at) FILTER (WHERE e.amount > 0 AND e.doc_type = 'stock_document') AS income_at,
		       min(e.created_at) FILTER (WHERE e.amount > 0) AS first_at
		FROM counterparties c
		LEFT JOIN counterparty_entries e ON e.counterparty_id = c.id
		WHERE c.network_id = $1 AND c.is_active
		GROUP BY c.id
	)
	SELECT b.id, b.name, b.phone, b.inn, b.balance::numeric(18,2)::text, b.paid_at, b.income_at,
	       CASE WHEN b.balance > 0 THEN (now()::date - COALESCE(b.paid_at, b.first_at)::date) END
	FROM b`

// SupplierDebts — side: we_owe (по умолчанию), they_owe, all.
func (s *Service) SupplierDebts(ctx context.Context, p *identity.Principal, side, q string) (Debts, error) {
	out := Debts{Items: []Debt{}}
	if err := p.RequireAny(identity.PermCounterpartiesManage, identity.PermInventoryManage, identity.PermFinanceManage); err != nil {
		return out, err
	}
	err := s.pool.QueryRow(ctx, `
		WITH b AS (SELECT sum(e.amount) AS v FROM counterparty_entries e JOIN counterparties c ON c.id = e.counterparty_id
		           WHERE e.network_id = $1 AND c.is_active GROUP BY e.counterparty_id)
		SELECT COALESCE(sum(v) FILTER (WHERE v > 0), 0)::numeric(18,2)::text, count(*) FILTER (WHERE v > 0)::int,
		       COALESCE(-sum(v) FILTER (WHERE v < 0), 0)::numeric(18,2)::text, count(*) FILTER (WHERE v < 0)::int
		FROM b`, p.NetworkID).Scan(&out.WeOwe, &out.WeOweCount, &out.TheyOwe, &out.TheyCount)
	if err != nil {
		return out, err
	}
	where := " WHERE b.balance > 0"
	switch side {
	case "", "we_owe":
	case "they_owe":
		where = " WHERE b.balance < 0"
	case "all":
		where = " WHERE b.balance <> 0"
	default:
		return out, apperr.Validation("side: we_owe, they_owe или all").Uz("side: we_owe, they_owe yoki all")
	}
	rows, err := s.pool.Query(ctx, debtsSQL+where+` AND ($2 = '' OR b.name ILIKE '%' || $2 || '%' OR b.phone LIKE '%' || $2 || '%')
		ORDER BY abs(b.balance) DESC, b.name LIMIT 200`, p.NetworkID, strings.TrimSpace(q))
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Debt, error) {
		var d Debt
		err := r.Scan(&d.ID, &d.Name, &d.Phone, &d.INN, &d.Balance, &d.LastPaymentAt, &d.LastIncomeAt, &d.DaysUnpaid)
		return d, err
	})
	return out, err
}

type StatementLine struct {
	At      time.Time `json:"at"`
	Kind    string    `json:"kind"` // income, supplier_return, payment, receipt, other
	Title   string    `json:"title"`
	Note    string    `json:"note"`
	DocID   string    `json:"doc_id"`
	Amount  string    `json:"amount"`  // плюс — наш долг вырос
	Balance string    `json:"balance"` // долг после операции
}

type Statement struct {
	Counterparty Counterparty `json:"counterparty"`
	From         time.Time    `json:"from"`
	To           time.Time    `json:"to"`
	Opening      string       `json:"opening"`
	Closing      string       `json:"closing"`
	// Скидки поставщика в проведённых приходах за период (Figma С3).
	Discount string          `json:"discount"`
	Items    []StatementLine `json:"items"` // новые сверху
}

// CounterpartyStatement — акт сверки за период [from, to).
func (s *Service) CounterpartyStatement(ctx context.Context, p *identity.Principal, id string, from, to *time.Time) (Statement, error) {
	cp, err := s.GetCounterparty(ctx, p, id)
	if err != nil {
		return Statement{}, err
	}
	now := time.Now().In(tashkent)
	st := Statement{Counterparty: cp, Items: []StatementLine{}}
	if from != nil {
		st.From = *from
	} else {
		st.From = time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, tashkent)
	}
	if to != nil {
		st.To = *to
	} else {
		st.To = now.Add(time.Minute)
	}
	if !st.To.After(st.From) {
		return st, apperr.Validation("to: конец периода позже начала").Uz("to: davr oxiri boshidan keyin boʻlsin")
	}
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0)::numeric(18,2)::text FROM counterparty_entries
		WHERE counterparty_id = $1 AND created_at < $2`, id, st.From).Scan(&st.Opening); err != nil {
		return st, err
	}
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(sum(i.qty * (i.list_price - i.price)), 0)::numeric(18,2)::text
		FROM stock_document_items i JOIN stock_documents d ON d.id = i.document_id
		WHERE d.counterparty_id = $1 AND d.type = 'income' AND d.status = 'posted' AND i.list_price IS NOT NULL
		  AND d.posted_at >= $2 AND d.posted_at < $3`, id, st.From, st.To).Scan(&st.Discount); err != nil {
		return st, err
	}
	bal := money.D(st.Opening)
	var lines []StatementLine
	rows, err := s.pool.Query(ctx, `
		SELECT e.created_at, e.amount::text, e.doc_type, e.doc_id::text,
		       COALESCE(d.type, ''), COALESCE(d.number, o.number, 0), COALESCE(d.reason, ''),
		       COALESCE((SELECT count(*) FROM stock_document_items i WHERE i.document_id = d.id), 0)::int,
		       COALESCE(cb.name, ''), COALESCE(o.note, sp.note, '')
		FROM counterparty_entries e
		LEFT JOIN stock_documents d ON e.doc_type = 'stock_document' AND d.id = e.doc_id
		LEFT JOIN supply_payments sp ON e.doc_type IN ('supply_payment', 'supply_payment_fix') AND sp.id = e.doc_id
		LEFT JOIN cash_operations o ON (e.doc_type = 'cash_operation' AND o.id = e.doc_id) OR (e.doc_type = 'supply_payment_fix' AND o.id = sp.cash_operation_id)
		LEFT JOIN cashboxes cb ON cb.id = o.cashbox_id
		WHERE e.counterparty_id = $1 AND e.created_at >= $2 AND e.created_at < $3
		ORDER BY e.created_at, e.id`, id, st.From, st.To)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			l                      StatementLine
			docType, dType, reason string
			cashbox, note          string
			number                 int64
			items                  int
		)
		if err := rows.Scan(&l.At, &l.Amount, &docType, &l.DocID, &dType, &number, &reason, &items, &cashbox, &note); err != nil {
			return st, err
		}
		l.Title, l.Note, l.Kind = statementText(i18n.FromContext(ctx), docType, dType, number, reason, items, cashbox, note, money.D(l.Amount).Sign())
		bal = bal.Add(money.D(l.Amount))
		l.Balance = bal.Money()
		lines = append(lines, l)
	}
	if err := rows.Err(); err != nil {
		return st, err
	}
	st.Closing = bal.Money()
	for i := len(lines) - 1; i >= 0; i-- {
		st.Items = append(st.Items, lines[i])
	}
	return st, nil
}

func statementText(lang, docType, dType string, number int64, reason string, items int, cashbox, note string, sign int) (title, sub, kind string) {
	n := " № " + itoa(number)
	positions := itoa(int64(items)) + " " + plural(items, "позиция", "позиции", "позиций")
	if lang == i18n.UZ {
		positions = itoa(int64(items)) + " ta pozitsiya"
	}
	switch {
	case docType == DocStockDocument && dType == "income":
		return i18n.Pick(lang, "Приход", "Kirim") + n, positions, "income"
	case docType == DocStockDocument && dType == "supplier_return":
		if reason == "" {
			reason = positions
		}
		return i18n.Pick(lang, "Возврат", "Qaytarish") + n, reason, "supplier_return"
	case docType == DocStockDocument && dType == "shipment":
		return i18n.Pick(lang, "Отгрузка", "Joʻnatma") + n, positions, "shipment"
	case docType == DocSupplyPayment:
		return i18n.Pick(lang, "Оплата получена", "Toʻlov olindi"), note, "payment"
	case docType == DocSupplyPaymentFix:
		return i18n.Pick(lang, "Исправление суммы оплаты", "Toʻlov summasi tuzatildi"), note, "payment_fix"
	case docType == DocCashOperation && sign < 0:
		return i18n.Pick(lang, "Оплата", "Toʻlov"), joinNonEmpty(cashbox, note), "payment"
	case docType == DocCashOperation:
		return i18n.Pick(lang, "Получено от поставщика", "Yetkazib beruvchidan olindi"), joinNonEmpty(cashbox, note), "receipt"
	}
	return i18n.Pick(lang, "Операция", "Operatsiya"), "", "other"
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
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

func joinNonEmpty(parts ...string) string {
	out := []string{}
	for _, p := range parts {
		if strings.TrimSpace(p) != "" {
			out = append(out, strings.TrimSpace(p))
		}
	}
	return strings.Join(out, " · ")
}
