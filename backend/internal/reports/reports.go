// Package reports — отчёты сети: денежный поток и прибыль/убыток.
// Отчёты только читают журналы (cash_entries, продажи, заказы, движения
// товара), поэтому всегда сходятся с первичными документами.
package reports

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool, now: time.Now} }

// Filter — период [From, To) и магазин (пусто — вся сеть).
type Filter struct {
	From    *time.Time
	To      *time.Time
	StoreID string
}

type scope struct {
	from, to time.Time
	// stores == nil — вся сеть, включая главную кассу и расходы сети.
	stores []string
}

func (s *Service) scope(p *identity.Principal, f Filter) (scope, error) {
	if err := p.Require(identity.PermReportsView); err != nil {
		return scope{}, err
	}
	sc := scope{}
	now := s.now().In(tashkent)
	if f.From != nil {
		sc.from = *f.From
	} else {
		sc.from = time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, tashkent)
	}
	if f.To != nil {
		sc.to = *f.To
	} else {
		sc.to = now
	}
	if !sc.to.After(sc.from) {
		return sc, apperr.Validation("to: конец периода позже начала").Uz("to: davr oxiri boshidan keyin boʻlsin")
	}
	switch {
	case f.StoreID != "":
		if !httpx.IsUUID(f.StoreID) || !p.CanAccessStore(f.StoreID) {
			return sc, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
		}
		sc.stores = []string{f.StoreID}
	case !p.SeesAllStores():
		sc.stores = p.StoreIDs
		if sc.stores == nil {
			sc.stores = []string{}
		}
	}
	return sc, nil
}

// ------------------------------------------------------- денежный поток

type CashboxFlow struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Currency string  `json:"currency"`
	StoreID  *string `json:"store_id"`
	Opening  string  `json:"opening"`
	Income   string  `json:"income"`
	Expense  string  `json:"expense"`
	Closing  string  `json:"closing"`
}

type FlowLine struct {
	Currency string `json:"currency"`
	Category string `json:"category"`
	Title    string `json:"title"`
	Income   string `json:"income"`
	Expense  string `json:"expense"`
}

type CashFlow struct {
	From      time.Time     `json:"from"`
	To        time.Time     `json:"to"`
	Cashboxes []CashboxFlow `json:"cashboxes"`
	Lines     []FlowLine    `json:"lines"`
}

var flowTitles = map[string]i18n.Text{
	"sale":              {RU: "Продажи", UZ: "Sotuvlar"},
	"customer_return":   {RU: "Возвраты покупателям", UZ: "Xaridorlarga qaytarishlar"},
	"debt_payment":      {RU: "Погашение долгов покупателей", UZ: "Xaridorlar qarzlarini toʻlash"},
	"transfer:transfer": {RU: "Из кассы в кассу", UZ: "Kassadan kassaga"},
	"transfer:handover": {RU: "Сдача кассы", UZ: "Kassani topshirish"},
	"counterparty":      {RU: "Расчёты с контрагентами", UZ: "Kontragentlar bilan hisob-kitob"},
}

// cashboxesCTE — кассы в области отчёта ($1 — сеть, $2 — магазины или NULL, $3 — касса или ”).
const cashboxesCTE = `
	WITH cb AS (
		SELECT id, name, currency, store_id FROM cashboxes
		WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND ($3 = '' OR id::text = $3)
	)`

func (s *Service) CashFlow(ctx context.Context, p *identity.Principal, f Filter, cashboxID string) (CashFlow, error) {
	sc, err := s.scope(p, f)
	if err != nil {
		return CashFlow{}, err
	}
	if cashboxID != "" && !httpx.IsUUID(cashboxID) {
		return CashFlow{}, apperr.Validation("cashbox_id: неверный id").Uz("cashbox_id: id notoʻgʻri")
	}
	out := CashFlow{From: sc.from, To: sc.to}
	rows, err := s.pool.Query(ctx, cashboxesCTE+`
		SELECT cb.id, cb.name, cb.currency, cb.store_id,
		       COALESCE(sum(e.amount) FILTER (WHERE e.created_at < $4), 0)::numeric(18,2)::text,
		       COALESCE(sum(e.amount) FILTER (WHERE e.created_at >= $4 AND e.created_at < $5 AND e.amount > 0), 0)::numeric(18,2)::text,
		       COALESCE(-sum(e.amount) FILTER (WHERE e.created_at >= $4 AND e.created_at < $5 AND e.amount < 0), 0)::numeric(18,2)::text,
		       COALESCE(sum(e.amount) FILTER (WHERE e.created_at < $5), 0)::numeric(18,2)::text
		FROM cb LEFT JOIN cash_entries e ON e.cashbox_id = cb.id
		GROUP BY cb.id, cb.name, cb.currency, cb.store_id
		ORDER BY cb.store_id NULLS FIRST, cb.name`, p.NetworkID, sc.stores, cashboxID, sc.from, sc.to)
	if err != nil {
		return out, err
	}
	if out.Cashboxes, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CashboxFlow]); err != nil {
		return out, err
	}
	if cashboxID != "" && len(out.Cashboxes) == 0 {
		return out, apperr.NotFound("касса не найдена").Uz("kassa topilmadi")
	}

	rows, err = s.pool.Query(ctx, cashboxesCTE+`
		SELECT cb.currency,
		       CASE e.doc_type
		            WHEN 'cash_operation' THEN CASE WHEN o.reason_id IS NOT NULL THEN 'reason:' || o.reason_id ELSE 'counterparty' END
		            WHEN 'cash_transfer' THEN 'transfer:' || t.kind
		            ELSE e.doc_type END AS category,
		       COALESCE(fr.name, ''),
		       COALESCE(sum(e.amount) FILTER (WHERE e.amount > 0), 0)::numeric(18,2)::text,
		       COALESCE(-sum(e.amount) FILTER (WHERE e.amount < 0), 0)::numeric(18,2)::text
		FROM cash_entries e
		JOIN cb ON cb.id = e.cashbox_id
		LEFT JOIN cash_operations o ON e.doc_type = 'cash_operation' AND o.id = e.doc_id
		LEFT JOIN financial_reasons fr ON fr.id = o.reason_id
		LEFT JOIN cash_transfers t ON e.doc_type = 'cash_transfer' AND t.id = e.doc_id
		WHERE e.created_at >= $4 AND e.created_at < $5
		GROUP BY 1, 2, 3 ORDER BY 1, 2`, p.NetworkID, sc.stores, cashboxID, sc.from, sc.to)
	if err != nil {
		return out, err
	}
	lang := i18n.FromContext(ctx)
	out.Lines, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (FlowLine, error) {
		var l FlowLine
		var reason string
		err := r.Scan(&l.Currency, &l.Category, &reason, &l.Income, &l.Expense)
		l.Title = flowTitles[l.Category].In(lang)
		if reason != "" {
			l.Title = reason
		}
		if l.Title == "" {
			l.Title = l.Category
		}
		return l, err
	})
	return out, err
}

// ---------------------------------------------------- прибыль и убыток

type Revenue struct {
	POSSales        string `json:"pos_sales"`
	CustomerReturns string `json:"customer_returns"`
	OnlineOrders    string `json:"online_orders"`
	DeliveryFees    string `json:"delivery_fees"`
	Total           string `json:"total"`
}

type COGS struct {
	POS     string `json:"pos"`
	Returns string `json:"returns"`
	Online  string `json:"online"`
	Total   string `json:"total"`
}

type StockAdjustments struct {
	WriteOffs         string `json:"write_offs"`
	InventoryShortage string `json:"inventory_shortage"`
	InventorySurplus  string `json:"inventory_surplus"`
	Total             string `json:"total"`
}

type ReasonAmount struct {
	ReasonID string `json:"reason_id"`
	Name     string `json:"name"`
	Amount   string `json:"amount"`
}

type ProfitLoss struct {
	From             time.Time        `json:"from"`
	To               time.Time        `json:"to"`
	Revenue          Revenue          `json:"revenue"`
	CostOfGoods      COGS             `json:"cost_of_goods"`
	GrossProfit      string           `json:"gross_profit"`
	StockAdjustments StockAdjustments `json:"stock_adjustments"`
	OtherIncome      []ReasonAmount   `json:"other_income"`
	Expenses         []ReasonAmount   `json:"expenses"`
	Subscription     string           `json:"platform_subscription"`
	NetProfit        string           `json:"net_profit"`
	SalesCount       int              `json:"sales_count"`
	OrdersCount      int              `json:"orders_count"`
}

// ProfitLoss — прибыль и убыток в сумах. Выручка POS — по дате продажи,
// онлайн-заказы — по дате доставки. Себестоимость — FIFO из партий.
// Прочие доходы и расходы — кассовые операции с финансовой причиной
// (оплаты контрагентам — это расчёты, а не расходы, и сюда не входят).
func (s *Service) ProfitLoss(ctx context.Context, p *identity.Principal, f Filter) (ProfitLoss, error) {
	sc, err := s.scope(p, f)
	if err != nil {
		return ProfitLoss{}, err
	}
	out := ProfitLoss{From: sc.from, To: sc.to, OtherIncome: []ReasonAmount{}, Expenses: []ReasonAmount{}}
	args := []any{p.NetworkID, sc.stores, sc.from, sc.to}

	var r Revenue
	var c COGS
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(total), 0)::numeric(18,2)::text, COALESCE(sum(cost), 0)::numeric(18,2)::text, count(*)::int FROM sales
		WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND sold_at >= $3 AND sold_at < $4`, args...).
		Scan(&r.POSSales, &c.POS, &out.SalesCount); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(total), 0)::numeric(18,2)::text, COALESCE(sum(cost), 0)::numeric(18,2)::text FROM customer_returns
		WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND created_at >= $3 AND created_at < $4`, args...).
		Scan(&r.CustomerReturns, &c.Returns); err != nil {
		return out, err
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(subtotal), 0)::numeric(18,2)::text, COALESCE(sum(delivery_fee), 0)::numeric(18,2)::text, COALESCE(sum(cost), 0)::numeric(18,2)::text, count(*)::int
		FROM orders
		WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND status = 'delivered'
		  AND delivered_at >= $3 AND delivered_at < $4`, args...).
		Scan(&r.OnlineOrders, &r.DeliveryFees, &c.Online, &out.OrdersCount); err != nil {
		return out, err
	}
	revenue := money.D(r.POSSales).Sub(money.D(r.CustomerReturns)).Add(money.D(r.OnlineOrders)).Add(money.D(r.DeliveryFees))
	r.Total = revenue.Money()
	cogs := money.D(c.POS).Sub(money.D(c.Returns)).Add(money.D(c.Online))
	c.Total = cogs.Money()
	out.Revenue, out.CostOfGoods = r, c
	gross := revenue.Sub(cogs)
	out.GrossProfit = gross.Money()

	var a StockAdjustments
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(-sum(m.qty * m.unit_cost) FILTER (WHERE d.type = 'write_off'), 0)::numeric(18,2)::text,
		       COALESCE(-sum(m.qty * m.unit_cost) FILTER (WHERE d.type = 'inventory' AND m.qty < 0), 0)::numeric(18,2)::text,
		       COALESCE(sum(m.qty * m.unit_cost) FILTER (WHERE d.type = 'inventory' AND m.qty > 0), 0)::numeric(18,2)::text
		FROM stock_movements m
		JOIN stock_documents d ON m.doc_type = 'stock_document' AND d.id = m.doc_id
		JOIN warehouses w ON w.id = m.warehouse_id
		WHERE m.network_id = $1 AND ($2::uuid[] IS NULL OR w.store_id = ANY($2))
		  AND d.type IN ('write_off', 'inventory') AND m.created_at >= $3 AND m.created_at < $4`, args...).
		Scan(&a.WriteOffs, &a.InventoryShortage, &a.InventorySurplus); err != nil {
		return out, err
	}
	adj := money.D(a.InventorySurplus).Sub(money.D(a.WriteOffs)).Sub(money.D(a.InventoryShortage))
	a.Total = adj.Money()
	out.StockAdjustments = a

	rows, err := s.pool.Query(ctx, `
		SELECT o.kind, fr.id, fr.name, sum(o.amount_uzs)::text
		FROM cash_operations o
		JOIN financial_reasons fr ON fr.id = o.reason_id
		JOIN cashboxes cb ON cb.id = o.cashbox_id
		WHERE o.network_id = $1 AND ($2::uuid[] IS NULL OR cb.store_id = ANY($2))
		  AND o.created_at >= $3 AND o.created_at < $4
		GROUP BY o.kind, fr.id, fr.name ORDER BY o.kind, sum(o.amount_uzs) DESC`, args...)
	if err != nil {
		return out, err
	}
	other, expenses := money.D("0"), money.D("0")
	// Списанные долги покупателей — расход.
	var writtenOff string
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(amount), 0)::numeric(18,2)::text FROM debt_writeoffs
		WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND created_at >= $3 AND created_at < $4`, args...).
		Scan(&writtenOff); err != nil {
		return out, err
	}
	for rows.Next() {
		var kind string
		var ra ReasonAmount
		if err := rows.Scan(&kind, &ra.ReasonID, &ra.Name, &ra.Amount); err != nil {
			rows.Close()
			return out, err
		}
		if kind == "income" {
			out.OtherIncome = append(out.OtherIncome, ra)
			other = other.Add(money.D(ra.Amount))
		} else {
			out.Expenses = append(out.Expenses, ra)
			expenses = expenses.Add(money.D(ra.Amount))
		}
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	if money.D(writtenOff).Sign() > 0 {
		out.Expenses = append(out.Expenses, ReasonAmount{Name: i18n.T(ctx, "Списанные долги покупателей", "Hisobdan chiqarilgan xaridor qarzlari"), Amount: writtenOff})
		expenses = expenses.Add(money.D(writtenOff))
	}
	// Комиссия Super Market с онлайн-заказов (по тарифу сети).
	var commission string
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(-sum(amount), 0)::numeric(18,2)::text FROM balance_entries
		WHERE network_id = $1 AND kind = 'commission' AND created_at >= $2 AND created_at < $3
		  AND ($4::uuid[] IS NULL OR store_id = ANY ($4::uuid[]))`, p.NetworkID, sc.from, sc.to, sc.stores).
		Scan(&commission); err != nil {
		return out, err
	}
	if money.D(commission).Sign() > 0 {
		out.Expenses = append(out.Expenses, ReasonAmount{Name: i18n.T(ctx, "Комиссия Super Market с онлайн-заказов", "Onlayn buyurtmalardan Super Market komissiyasi"), Amount: commission})
		expenses = expenses.Add(money.D(commission))
	}

	out.Subscription = "0.00"
	if sc.stores == nil {
		if err := s.pool.QueryRow(ctx, `
			SELECT COALESCE(sum(amount_uzs), 0)::numeric(18,2)::text FROM subscription_invoices
			WHERE network_id = $1 AND status = 'paid' AND paid_at >= $2 AND paid_at < $3`, p.NetworkID, sc.from, sc.to).
			Scan(&out.Subscription); err != nil {
			return out, err
		}
	}
	net := gross.Add(adj).Add(other).Sub(expenses).Sub(money.D(out.Subscription))
	out.NetProfit = net.Money()
	return out, nil
}
