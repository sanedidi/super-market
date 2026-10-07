// Package inventory — партии, остатки (FIFO) и складские документы:
// приход, возврат поставщику, перемещение, списание, оприходование,
// инвентаризация.
//
// Функции AddBatch и TakeFIFO — единственный способ изменить остаток.
// Ими же пользуются продажи и онлайн-заказы.
package inventory

import (
	"context"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Виды документов в журнале движений.
const (
	DocStock          = "stock_document"
	DocSale           = "sale"
	DocCustomerReturn = "customer_return"
	DocOrder          = "order"
)

// AddBatch приходует qty товара на склад новой партией.
func AddBatch(ctx context.Context, q db.Querier, networkID, warehouseID, productID, qty, unitCost, unitCostUSD, docType, docID string) error {
	var batchID string
	if err := q.QueryRow(ctx, `
		INSERT INTO batches (network_id, warehouse_id, product_id, doc_type, doc_id, qty_initial, qty_remaining, unit_cost, unit_cost_usd)
		VALUES ($1, $2, $3, $4, $5, $6::numeric, $6::numeric, $7::numeric, $8::numeric) RETURNING id`,
		networkID, warehouseID, productID, docType, docID, qty, unitCost, unitCostUSD).Scan(&batchID); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `
		INSERT INTO stock_movements (network_id, warehouse_id, product_id, batch_id, qty, unit_cost, unit_cost_usd, doc_type, doc_id)
		VALUES ($1, $2, $3, $4, $5::numeric, $6::numeric, $7::numeric, $8, $9)`,
		networkID, warehouseID, productID, batchID, qty, unitCost, unitCostUSD, docType, docID)
	return err
}

// Taken — часть партии, списанная TakeFIFO.
type Taken struct {
	BatchID     string
	Qty         string
	UnitCost    string
	UnitCostUSD string
}

// ErrInsufficient — на складе меньше, чем нужно.
func errInsufficient(productID, available, need string) error {
	return apperr.New(http.StatusConflict, "insufficient_stock", "недостаточно товара на складе").Uz("omborda mahsulot yetarli emas").
		WithDetails(map[string]any{"product_id": productID, "available": available, "required": need})
}

// TakeFIFO списывает qty товара со склада, начиная с самых старых партий.
// Партии блокируются (FOR UPDATE), поэтому параллельные продажи одного
// товара не уведут остаток в минус. Товар, зарезервированный под онлайн-заказы,
// списать нельзя: доступно «остаток − резервы». Возвращает, из каких партий списано.
func TakeFIFO(ctx context.Context, tx pgx.Tx, networkID, warehouseID, productID, qty, docType, docID string) ([]Taken, error) {
	if err := LockProduct(ctx, tx, warehouseID, productID); err != nil {
		return nil, err
	}
	var enough bool
	var available string
	if err := tx.QueryRow(ctx, `
		WITH a AS (
			SELECT COALESCE((SELECT sum(qty_remaining) FROM batches WHERE warehouse_id = $1 AND product_id = $2), 0)
			     - COALESCE((SELECT sum(qty) FROM stock_reservations WHERE warehouse_id = $1 AND product_id = $2), 0) AS v)
		SELECT v >= $3::numeric, GREATEST(v, 0)::text FROM a`, warehouseID, productID, qty).Scan(&enough, &available); err != nil {
		return nil, err
	}
	if !enough {
		return nil, errInsufficient(productID, available, qty)
	}
	return takeFIFO(ctx, tx, networkID, warehouseID, productID, qty, docType, docID)
}

// TakeUpTo списывает по FIFO столько, сколько физически есть (без учёта
// резервов), но не больше qty, и возвращает недостающее количество. Для
// продаж с кассы: покупатель уже ушёл с товаром, отказать в проводке нельзя.
func TakeUpTo(ctx context.Context, tx pgx.Tx, networkID, warehouseID, productID, qty, docType, docID string) ([]Taken, string, error) {
	if err := LockProduct(ctx, tx, warehouseID, productID); err != nil {
		return nil, "", err
	}
	var take, short string
	var hasAny bool
	if err := tx.QueryRow(ctx, `
		WITH a AS (SELECT COALESCE(sum(qty_remaining), 0) AS v FROM batches WHERE warehouse_id = $1 AND product_id = $2 AND qty_remaining > 0)
		SELECT LEAST($3::numeric, v)::numeric(14,3)::text, ($3::numeric - LEAST($3::numeric, v))::numeric(14,3)::text, LEAST($3::numeric, v) > 0 FROM a`,
		warehouseID, productID, qty).Scan(&take, &short, &hasAny); err != nil {
		return nil, "", err
	}
	if !hasAny {
		return nil, short, nil
	}
	taken, err := takeFIFO(ctx, tx, networkID, warehouseID, productID, take, docType, docID)
	return taken, short, err
}

// TakeFIFOPhysical списывает без учёта резервов — для недостачи при
// инвентаризации: фактический остаток важнее резервов (заказ потом соберут
// с другого склада).
func TakeFIFOPhysical(ctx context.Context, tx pgx.Tx, networkID, warehouseID, productID, qty, docType, docID string) ([]Taken, error) {
	return takeFIFO(ctx, tx, networkID, warehouseID, productID, qty, docType, docID)
}

func takeFIFO(ctx context.Context, tx pgx.Tx, networkID, warehouseID, productID, qty, docType, docID string) ([]Taken, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, qty_remaining::text, unit_cost::text, unit_cost_usd::text
		FROM batches
		WHERE warehouse_id = $1 AND product_id = $2 AND qty_remaining > 0
		ORDER BY created_at, id
		FOR UPDATE`, warehouseID, productID)
	if err != nil {
		return nil, err
	}
	type batch struct{ id, remaining, cost, costUSD string }
	batches, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (batch, error) {
		var b batch
		err := r.Scan(&b.id, &b.remaining, &b.cost, &b.costUSD)
		return b, err
	})
	if err != nil {
		return nil, err
	}

	// Хватает ли всего — считаем в SQL, чтобы не терять точность.
	var enough bool
	var available string
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(sum(qty_remaining), 0) >= $3::numeric, COALESCE(sum(qty_remaining), 0)::text
		FROM batches WHERE warehouse_id = $1 AND product_id = $2 AND qty_remaining > 0`,
		warehouseID, productID, qty).Scan(&enough, &available); err != nil {
		return nil, err
	}
	if !enough {
		return nil, errInsufficient(productID, available, qty)
	}

	var taken []Taken
	left := qty
	for _, b := range batches {
		// take = min(left, remaining); left -= take
		var take, rest string
		var done bool
		if err := tx.QueryRow(ctx, `
			SELECT LEAST($1::numeric, $2::numeric)::text,
			       ($1::numeric - LEAST($1::numeric, $2::numeric))::text,
			       $1::numeric - LEAST($1::numeric, $2::numeric) = 0`,
			left, b.remaining).Scan(&take, &rest, &done); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `UPDATE batches SET qty_remaining = qty_remaining - $2::numeric WHERE id = $1`, b.id, take); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO stock_movements (network_id, warehouse_id, product_id, batch_id, qty, unit_cost, unit_cost_usd, doc_type, doc_id)
			VALUES ($1, $2, $3, $4, -($5::numeric), $6::numeric, $7::numeric, $8, $9)`,
			networkID, warehouseID, productID, b.id, take, b.cost, b.costUSD, docType, docID); err != nil {
			return nil, err
		}
		taken = append(taken, Taken{BatchID: b.id, Qty: take, UnitCost: b.cost, UnitCostUSD: b.costUSD})
		left = rest
		if done {
			break
		}
	}
	return taken, nil
}

// ReturnToBatches возвращает товар в те партии, из которых он был списан
// (возврат покупателя, отмена заказа): себестоимость сохраняется.
func ReturnToBatches(ctx context.Context, q db.Querier, networkID string, taken []Taken, warehouseID, productID, docType, docID string) error {
	for _, t := range taken {
		tag, err := q.Exec(ctx, `UPDATE batches SET qty_remaining = qty_remaining + $2::numeric
			WHERE id = $1 AND qty_remaining + $2::numeric <= qty_initial`, t.BatchID, t.Qty)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			// Партия уже полна (не должно случаться) — приходуем новой партией.
			if err := AddBatch(ctx, q, networkID, warehouseID, productID, t.Qty, t.UnitCost, t.UnitCostUSD, docType, docID); err != nil {
				return err
			}
			continue
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO stock_movements (network_id, warehouse_id, product_id, batch_id, qty, unit_cost, unit_cost_usd, doc_type, doc_id)
			VALUES ($1, $2, $3, $4, $5::numeric, $6::numeric, $7::numeric, $8, $9)`,
			networkID, warehouseID, productID, t.BatchID, t.Qty, t.UnitCost, t.UnitCostUSD, docType, docID); err != nil {
			return err
		}
	}
	return nil
}

// LastCost — себестоимость последней партии товара на складе (для излишков
// при инвентаризации). Если партий не было — последняя по сети, иначе ноль.
func LastCost(ctx context.Context, q db.Querier, networkID, warehouseID, productID string) (cost, costUSD string, err error) {
	err = q.QueryRow(ctx, `
		SELECT unit_cost::text, unit_cost_usd::text FROM batches
		WHERE network_id = $1 AND product_id = $3
		ORDER BY (warehouse_id = $2) DESC, created_at DESC LIMIT 1`, networkID, warehouseID, productID).Scan(&cost, &costUSD)
	if errors.Is(err, pgx.ErrNoRows) {
		return "0", "0", nil
	}
	return
}

// StockQty — текущий остаток товара на складе.
func StockQty(ctx context.Context, q db.Querier, warehouseID, productID string) (string, error) {
	var qty string
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(qty_remaining), 0)::text FROM batches
		WHERE warehouse_id = $1 AND product_id = $2`, warehouseID, productID).Scan(&qty)
	return qty, err
}

// Available — остаток за вычетом резервов под онлайн-заказы.
func Available(ctx context.Context, q db.Querier, warehouseID, productID string) (string, error) {
	var qty string
	err := q.QueryRow(ctx, `
		SELECT (COALESCE((SELECT sum(qty_remaining) FROM batches WHERE warehouse_id = $1 AND product_id = $2), 0)
		      - COALESCE((SELECT sum(qty) FROM stock_reservations WHERE warehouse_id = $1 AND product_id = $2), 0))::text`,
		warehouseID, productID).Scan(&qty)
	return qty, err
}

// LockProduct блокирует партии товара на складе до конца транзакции, чтобы
// параллельные заказы не зарезервировали один и тот же остаток.
func LockProduct(ctx context.Context, tx pgx.Tx, warehouseID, productID string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1 || ':' || $2))`, warehouseID, productID)
	return err
}
