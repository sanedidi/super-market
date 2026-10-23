// Package finance — кассы, способы оплаты, курс валют, контрагенты,
// финансовые причины, кассовые операции, перемещения и сдача кассы.
//
// Деньги хранятся журналами (cash_entries, counterparty_entries):
// баланс — сумма записей, отдельного поля «остаток» нет, поэтому
// расхождение между документами и балансом невозможно.
package finance

import (
	"context"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Виды документов в журналах.
const (
	DocCashOperation  = "cash_operation"
	DocCashTransfer   = "cash_transfer"
	DocStockDocument  = "stock_document"
	DocSale           = "sale"
	DocCustomerReturn = "customer_return"
	DocPayout         = "payout"
	// Оплата магазина агенту, подтверждённая агентом (журнал агента).
	DocSupplyPayment = "supply_payment"
	// Магазин исправил сумму оплаты агенту (журнал и касса магазина).
	DocSupplyPaymentFix = "supply_payment_fix"
	// Внесение и изъятие наличных на кассе POS (pos_cash_moves).
	DocPOSCashMove = "pos_cash_move"
	// Пересчёт при закрытии смены разошёлся с расчётом.
	DocShiftClose = "pos_shift_close"
	// Сдача кассы: учёт выровнен по ящику смены и недостача при пересчёте.
	DocDrawerSync       = "drawer_sync"
	DocHandoverShortage = "handover_shortage"
)

// CreateMainCashbox создаёт главную кассу новой сети.
func CreateMainCashbox(ctx context.Context, q db.Querier, networkID string) error {
	_, err := q.Exec(ctx, `INSERT INTO cashboxes (network_id, store_id, name, is_main) VALUES ($1, NULL, loc('Главная касса', 'Asosiy kassa'), true)`, networkID)
	return err
}

// CreateStoreCashbox создаёт кассы нового магазина: наличные (ящик) и
// «Терминал (банк)» — деньги по карте уходят на счёт и в ящик не попадают.
func CreateStoreCashbox(ctx context.Context, q db.Querier, networkID, storeID, storeName string) error {
	var id, bank string
	if err := q.QueryRow(ctx, `INSERT INTO cashboxes (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
		networkID, storeID, i18n.T(ctx, "Касса ", "Kassa ")+storeName).Scan(&id); err != nil {
		return err
	}
	if err := q.QueryRow(ctx, `INSERT INTO cashboxes (network_id, store_id, name, kind) VALUES ($1, $2, $3, 'bank') RETURNING id`,
		networkID, storeID, i18n.T(ctx, "Терминал (банк) · ", "Terminal (bank) · ")+storeName).Scan(&bank); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `
		INSERT INTO payment_methods (network_id, name, cashbox_id, kind)
		VALUES ($1, loc('Наличные', 'Naqd pul'), $2, 'cash'), ($1, loc('Терминал', 'Terminal'), $3, 'card')`, networkID, id, bank)
	return err
}

// StoreCashbox — касса наличных магазина (ящик), в сумах; "" — нет.
func StoreCashbox(ctx context.Context, q db.Querier, networkID, storeID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT c.id FROM cashboxes c
		LEFT JOIN payment_methods pm ON pm.cashbox_id = c.id AND pm.kind = 'cash' AND pm.is_active
		WHERE c.store_id = $1 AND c.network_id = $2 AND c.is_active AND c.currency = 'UZS' AND c.kind = 'cash'
		ORDER BY pm.id IS NULL, c.created_at LIMIT 1`, storeID, networkID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// CashBalance — остаток кассы по журналу.
func CashBalance(ctx context.Context, q db.Querier, cashboxID string) (money.Dec, error) {
	var b string
	if err := q.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0)::text FROM cash_entries WHERE cashbox_id = $1`, cashboxID).Scan(&b); err != nil {
		return money.D("0"), err
	}
	return money.D(b), nil
}

// OpenShiftCash — открытые смены магазина и сколько наличных должно быть в
// ящике каждой: размен + наличные продажи − наличные возвраты + внесения −
// изъятия + наличные погашения долгов (как X-отчёт смены).
type OpenShiftCash struct {
	ID       string
	Expected money.Dec
}

func OpenShiftsCash(ctx context.Context, q db.Querier, networkID, storeID string) ([]OpenShiftCash, error) {
	rows, err := q.Query(ctx, `
		SELECT sh.id,
		       (sh.opening_cash
		        + (SELECT COALESCE(sum(sp.amount), 0) FROM sale_payments sp JOIN sales sl ON sl.id = sp.sale_id
		            JOIN payment_methods m ON m.id = sp.payment_method_id WHERE sl.shift_id = sh.id AND m.kind = 'cash')
		        - (SELECT COALESCE(sum(cr.total - cr.debt_amount), 0) FROM customer_returns cr JOIN payment_methods m ON m.id = cr.payment_method_id
		            WHERE cr.shift_id = sh.id AND m.kind = 'cash')
		        + (SELECT COALESCE(sum(CASE kind WHEN 'in' THEN amount ELSE -amount END), 0) FROM pos_cash_moves WHERE shift_id = sh.id)
		        + (SELECT COALESCE(sum(dp.amount), 0) FROM debt_payments dp JOIN payment_methods m ON m.id = dp.payment_method_id
		            WHERE dp.shift_id = sh.id AND m.kind = 'cash'))::text
		FROM pos_shifts sh WHERE sh.network_id = $1 AND sh.store_id = $2 AND sh.closed_at IS NULL
		ORDER BY sh.opened_at`, networkID, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (OpenShiftCash, error) {
		var o OpenShiftCash
		var v string
		err := r.Scan(&o.ID, &v)
		o.Expected = money.D(v)
		return o, err
	})
}

// DrawerCash — сколько наличных должно быть в ящике магазина: идёт смена —
// по сменам (как «Должно быть» в X-отчёте), нет — остаток кассы по журналу
// (то, что оставили на размен при сдаче).
func DrawerCash(ctx context.Context, q db.Querier, networkID, storeID, cashboxID string) (money.Dec, []OpenShiftCash, error) {
	shifts, err := OpenShiftsCash(ctx, q, networkID, storeID)
	if err != nil || len(shifts) > 0 {
		sum := money.D("0")
		for _, s := range shifts {
			sum = sum.Add(s.Expected)
		}
		return sum, shifts, err
	}
	b, err := CashBalance(ctx, q, cashboxID)
	return b, nil, err
}

// CurrentRate — действующий курс (сумов за 1 USD).
func CurrentRate(ctx context.Context, q db.Querier, networkID string) (string, error) {
	var rate string
	err := q.QueryRow(ctx, `SELECT rate::text FROM currency_rates WHERE network_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1`,
		networkID).Scan(&rate)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Conflict("no_currency_rate", "не задан курс валюты — установите его в разделе «Финансы»").Uz("valyuta kursi belgilanmagan — uni «Moliya» boʻlimida belgilang")
	}
	return rate, err
}

// Cashbox — касса, достаточно для проводок.
type cashboxRef struct {
	ID       string
	StoreID  *string
	Currency string
	IsMain   bool
	IsActive bool
	Kind     string
}

// lockCashbox блокирует кассу до конца транзакции (защита от ухода в минус
// при параллельных расходах).
func lockCashbox(ctx context.Context, tx pgx.Tx, networkID, id string) (cashboxRef, error) {
	var c cashboxRef
	err := tx.QueryRow(ctx, `SELECT id, store_id, currency, is_main, is_active, kind FROM cashboxes
		WHERE id = $1 AND network_id = $2 FOR UPDATE`, id, networkID).Scan(&c.ID, &c.StoreID, &c.Currency, &c.IsMain, &c.IsActive, &c.Kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.Validation("cashbox_id: касса не найдена").Uz("cashbox_id: kassa topilmadi")
	}
	return c, err
}

// AddCash записывает движение денег по кассе (amount со знаком).
func AddCash(ctx context.Context, q db.Querier, networkID, cashboxID, amount, docType, docID string) error {
	_, err := q.Exec(ctx, `INSERT INTO cash_entries (network_id, cashbox_id, amount, doc_type, doc_id)
		VALUES ($1, $2, $3::numeric, $4, $5)`, networkID, cashboxID, amount, docType, docID)
	return err
}

// SubtractCash списывает деньги, проверяя, что в кассе их хватает.
// Касса должна быть заблокирована lockCashbox в этой же транзакции.
func SubtractCash(ctx context.Context, tx pgx.Tx, networkID, cashboxID, amount, docType, docID string) error {
	var enough bool
	if err := tx.QueryRow(ctx, `SELECT COALESCE(sum(amount), 0) >= $2::numeric FROM cash_entries WHERE cashbox_id = $1`,
		cashboxID, amount).Scan(&enough); err != nil {
		return err
	}
	if !enough {
		return apperr.New(http.StatusConflict, "insufficient_cash", "в кассе недостаточно денег").Uz("kassada pul yetarli emas")
	}
	_, err := tx.Exec(ctx, `INSERT INTO cash_entries (network_id, cashbox_id, amount, doc_type, doc_id)
		VALUES ($1, $2, -($3::numeric), $4, $5)`, networkID, cashboxID, amount, docType, docID)
	return err
}

// AddCounterparty записывает взаиморасчёт (UZS, со знаком):
// плюс — мы должны контрагенту, минус — контрагент должен нам.
func AddCounterparty(ctx context.Context, q db.Querier, networkID, counterpartyID, amountUZS, docType, docID string) error {
	_, err := q.Exec(ctx, `INSERT INTO counterparty_entries (network_id, counterparty_id, amount, doc_type, doc_id)
		VALUES ($1, $2, $3::numeric, $4, $5)`, networkID, counterpartyID, amountUZS, docType, docID)
	return err
}

// CheckCounterparty — контрагент есть в сети и активен.
func CheckCounterparty(ctx context.Context, q db.Querier, networkID, id string) error {
	var active bool
	err := q.QueryRow(ctx, `SELECT is_active FROM counterparties WHERE id = $1 AND network_id = $2`, id, networkID).Scan(&active)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
		return apperr.Validation("counterparty_id: контрагент не найден или отключён").Uz("counterparty_id: kontragent topilmadi yoki oʻchirilgan")
	}
	return err
}
