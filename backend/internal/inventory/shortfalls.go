package inventory

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// «Минус» продуктов кафе (stock_shortfalls). Кафе продаёт блюдо, даже если
// по учёту продуктов не хватило, — недостача ждёт следующего прихода.
// Магазины эту таблицу не пишут: у них всё работает как раньше.

// DocProduction — производство заготовки (документ кафе).
const DocProduction = "production"

// AddShortfall записывает недостачу продукта по документу (продажа — со
// строкой чека, производство — без).
func AddShortfall(ctx context.Context, tx pgx.Tx, networkID, warehouseID, productID, qty, docType, docID string, saleLine *int) error {
	if money.D(qty).Sign() <= 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO stock_shortfalls (network_id, warehouse_id, product_id, qty, doc_type, doc_id, sale_line)
		VALUES ($1, $2, $3, $4::numeric, $5, $6, $7)`,
		networkID, warehouseID, productID, qty, docType, docID, saleLine)
	return err
}

// CloseShortfalls досписывает открытые недостачи продукта на складе из
// только что пришедших партий (по FIFO, самые старые недостачи первыми) и
// уточняет себестоимость продаж и производств, в которых не хватило. Вызывать
// после AddBatch в той же транзакции.
func CloseShortfalls(ctx context.Context, tx pgx.Tx, networkID, warehouseID, productID string) error {
	rows, err := tx.Query(ctx, `
		SELECT id, (qty - qty_closed)::text, doc_type, doc_id, sale_line
		FROM stock_shortfalls
		WHERE warehouse_id = $1 AND product_id = $2 AND closed_at IS NULL
		ORDER BY created_at, id
		FOR UPDATE`, warehouseID, productID)
	if err != nil {
		return err
	}
	type open struct {
		id      int64
		left    string
		docType string
		docID   string
		line    *int
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (open, error) {
		var o open
		err := r.Scan(&o.id, &o.left, &o.docType, &o.docID, &o.line)
		return o, err
	})
	if err != nil || len(list) == 0 {
		return err
	}
	if err := LockProduct(ctx, tx, warehouseID, productID); err != nil {
		return err
	}
	for _, o := range list {
		var have string
		if err := tx.QueryRow(ctx, `SELECT COALESCE(sum(qty_remaining), 0)::text FROM batches
			WHERE warehouse_id = $1 AND product_id = $2 AND qty_remaining > 0`, warehouseID, productID).Scan(&have); err != nil {
			return err
		}
		take := money.D(o.left).Min(money.D(have))
		if take.Sign() <= 0 {
			return nil
		}
		taken, err := takeFIFO(ctx, tx, networkID, warehouseID, productID, take.Fixed(3), o.docType, o.docID)
		if err != nil {
			return err
		}
		cost := money.D("0")
		for _, t := range taken {
			cost = cost.Add(money.D(t.Qty).Mul(money.D(t.UnitCost)))
		}
		if _, err := tx.Exec(ctx, `
			UPDATE stock_shortfalls SET qty_closed = qty_closed + $2::numeric, closed_cost = closed_cost + $3::numeric,
			       closed_at = CASE WHEN qty_closed + $2::numeric >= qty THEN now() END,
			       closed_by = CASE WHEN qty_closed + $2::numeric >= qty THEN 'stock' END
			WHERE id = $1`, o.id, take.Fixed(3), cost.Money()); err != nil {
			return err
		}
		if err := addShortfallCost(ctx, tx, o.docType, o.docID, o.line, productID, taken, take, cost); err != nil {
			return err
		}
	}
	return nil
}

// addShortfallCost — досписанное становится частью себестоимости документа,
// в котором не хватило.
func addShortfallCost(ctx context.Context, tx pgx.Tx, docType, docID string, line *int, productID string, taken []Taken, qty, cost money.Dec) error {
	switch {
	case docType == DocSale && line != nil:
		for _, t := range taken {
			if _, err := tx.Exec(ctx, `
				INSERT INTO sale_item_batches (sale_id, line, batch_id, qty, unit_cost, unit_cost_usd)
				VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric)`,
				docID, *line, t.BatchID, t.Qty, t.UnitCost, t.UnitCostUSD); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE sale_item_ingredients SET short_qty = GREATEST(short_qty - $4::numeric, 0), cost = cost + $5::numeric
			WHERE sale_id = $1 AND line = $2 AND ingredient_id = $3`, docID, *line, productID, qty.Fixed(3), cost.Money()); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE sale_items SET cost = cost + $3::numeric WHERE sale_id = $1 AND line = $2`,
			docID, *line, cost.Money()); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE sales SET cost = cost + $2::numeric WHERE id = $1`, docID, cost.Money())
		return err
	case docType == DocProduction:
		// Заготовка уже на складе по прежней себестоимости; уточняем документ
		// (для отчётов), партии заготовки не трогаем.
		if _, err := tx.Exec(ctx, `UPDATE production_doc_items SET short_qty = GREATEST(short_qty - $3::numeric, 0), cost = cost + $4::numeric
			WHERE doc_id = $1 AND ingredient_id = $2`, docID, productID, qty.Fixed(3), cost.Money()); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE production_docs SET cost = cost + $2::numeric WHERE id = $1`, docID, cost.Money())
		return err
	}
	return nil
}

// CloseShortfallsByCount закрывает недостачи без списания: инвентаризация
// посчитала фактический остаток, долг учёта перед полкой снят.
func CloseShortfallsByCount(ctx context.Context, tx pgx.Tx, warehouseID, productID string) error {
	_, err := tx.Exec(ctx, `
		UPDATE stock_shortfalls SET closed_at = now(), closed_by = 'inventory'
		WHERE warehouse_id = $1 AND product_id = $2 AND closed_at IS NULL`, warehouseID, productID)
	return err
}

// OpenShortfall — сколько продукта на складе ушло в минус и ещё не закрыто.
func OpenShortfall(ctx context.Context, q db.Querier, warehouseID, productID string) (string, error) {
	var v string
	err := q.QueryRow(ctx, `SELECT COALESCE(sum(qty - qty_closed), 0)::text FROM stock_shortfalls
		WHERE warehouse_id = $1 AND product_id = $2 AND closed_at IS NULL`, warehouseID, productID).Scan(&v)
	return v, err
}
