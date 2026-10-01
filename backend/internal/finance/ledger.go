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
)

// Виды документов в журналах.
const (
	DocCashOperation  = "cash_operation"
	DocCashTransfer   = "cash_transfer"
	DocStockDocument  = "stock_document"
	DocSale           = "sale"
	DocCustomerReturn = "customer_return"
	DocPayout         = "payout"
)

// CreateMainCashbox создаёт главную кассу новой сети.
func CreateMainCashbox(ctx context.Context, q db.Querier, networkID string) error {
	_, err := q.Exec(ctx, `INSERT INTO cashboxes (network_id, store_id, name, is_main) VALUES ($1, NULL, 'Главная касса', true)`, networkID)
	return err
}

// CreateStoreCashbox создаёт кассу нового магазина и способы оплаты
// «Наличные» и «Терминал», которые в неё поступают.
func CreateStoreCashbox(ctx context.Context, q db.Querier, networkID, storeID, storeName string) error {
	var id string
	if err := q.QueryRow(ctx, `INSERT INTO cashboxes (network_id, store_id, name) VALUES ($1, $2, $3) RETURNING id`,
		networkID, storeID, "Касса "+storeName).Scan(&id); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `
		INSERT INTO payment_methods (network_id, name, cashbox_id, kind)
		VALUES ($1, 'Наличные', $2, 'cash'), ($1, 'Терминал', $2, 'card')`, networkID, id)
	return err
}

// CurrentRate — действующий курс (сумов за 1 USD).
func CurrentRate(ctx context.Context, q db.Querier, networkID string) (string, error) {
	var rate string
	err := q.QueryRow(ctx, `SELECT rate::text FROM currency_rates WHERE network_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1`,
		networkID).Scan(&rate)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Conflict("no_currency_rate", "не задан курс валюты — установите его в разделе «Финансы»")
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
}

// lockCashbox блокирует кассу до конца транзакции (защита от ухода в минус
// при параллельных расходах).
func lockCashbox(ctx context.Context, tx pgx.Tx, networkID, id string) (cashboxRef, error) {
	var c cashboxRef
	err := tx.QueryRow(ctx, `SELECT id, store_id, currency, is_main, is_active FROM cashboxes
		WHERE id = $1 AND network_id = $2 FOR UPDATE`, id, networkID).Scan(&c.ID, &c.StoreID, &c.Currency, &c.IsMain, &c.IsActive)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.Validation("cashbox_id: касса не найдена")
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
		return apperr.New(http.StatusConflict, "insufficient_cash", "в кассе недостаточно денег")
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
		return apperr.Validation("counterparty_id: контрагент не найден или отключён")
	}
	return err
}
