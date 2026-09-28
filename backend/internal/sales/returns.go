package sales

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

type ReturnItem struct {
	SaleLine    int    `json:"sale_line"`
	ProductName string `json:"product_name"`
	Qty         string `json:"qty"`
	Total       string `json:"total"`
}

type CustomerReturn struct {
	ID           string       `json:"id"`
	Number       int64        `json:"number"`
	SaleID       string       `json:"sale_id"`
	SaleNumber   int64        `json:"sale_number"`
	StoreID      string       `json:"store_id"`
	Total        string       `json:"total"`
	PaymentName  string       `json:"payment_method"`
	Reason       string       `json:"reason"`
	CreatedBy    string       `json:"created_by"`
	FiscalStatus string       `json:"fiscal_status"`
	CreatedAt    time.Time    `json:"created_at"`
	Items        []ReturnItem `json:"items,omitempty" db:"-"`
}

const returnSelect = `
	SELECT r.id, r.number, r.sale_id, s.number, r.store_id, r.total::text, m.name, r.reason, e.full_name,
	       r.fiscal_status, r.created_at
	FROM customer_returns r
	JOIN sales s ON s.id = r.sale_id
	JOIN payment_methods m ON m.id = r.payment_method_id
	JOIN employees e ON e.id = r.created_by`

func (s *Service) getReturn(ctx context.Context, q db.Querier, p *identity.Principal, id string) (CustomerReturn, error) {
	rows, err := q.Query(ctx, returnSelect+` WHERE r.network_id = $1 AND r.id = $2`, p.NetworkID, id)
	if err != nil {
		return CustomerReturn{}, err
	}
	r, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[CustomerReturn])
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(r.StoreID)) {
		return CustomerReturn{}, apperr.NotFound("возврат не найден")
	}
	if err != nil {
		return CustomerReturn{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT ri.sale_line, p.name, ri.qty::text, ri.total::text
		FROM customer_return_items ri
		JOIN sale_items si ON si.sale_id = $2 AND si.line = ri.sale_line
		JOIN products p ON p.id = si.product_id
		WHERE ri.return_id = $1 ORDER BY ri.sale_line`, id, r.SaleID)
	if err != nil {
		return CustomerReturn{}, err
	}
	r.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[ReturnItem])
	return r, err
}

func (s *Service) GetReturn(ctx context.Context, p *identity.Principal, id string) (CustomerReturn, error) {
	return s.getReturn(ctx, s.pool, p, id)
}

func (s *Service) ListReturns(ctx context.Context, p *identity.Principal, f SaleFilter) ([]CustomerReturn, error) {
	rows, err := s.pool.Query(ctx, returnSelect+`
		WHERE r.network_id = $1 AND ($2 OR r.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR r.store_id::text = $4) AND (NOT $5 OR r.fiscal_status = 'pending')
		  AND ($6::timestamptz IS NULL OR r.created_at >= $6) AND ($7::timestamptz IS NULL OR r.created_at < $7)
		ORDER BY r.created_at DESC LIMIT $8 OFFSET $9`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.StoreID, f.FiscalPending, f.From, f.To, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CustomerReturn])
}

type ReturnInput struct {
	SaleID          string `json:"sale_id"`
	PaymentMethodID string `json:"payment_method_id"`
	Reason          string `json:"reason"`
	Items           []struct {
		SaleLine int       `json:"sale_line"`
		Qty      money.Qty `json:"qty"`
	} `json:"items"`
}

// CreateReturn — возврат по чеку: товар возвращается в те же партии по той же
// себестоимости, деньги выдаются из кассы выбранного способа оплаты.
// Сумма возврата — пропорционально оплаченной сумме строки (с учётом скидки).
func (s *Service) CreateReturn(ctx context.Context, p *identity.Principal, in ReturnInput) (CustomerReturn, error) {
	if err := p.Require(identity.PermSalesReturn); err != nil {
		return CustomerReturn{}, err
	}
	if !httpx.IsUUID(in.SaleID) || !httpx.IsUUID(in.PaymentMethodID) {
		return CustomerReturn{}, apperr.Validation("укажите sale_id и payment_method_id")
	}
	if len(in.Items) == 0 {
		return CustomerReturn{}, apperr.Validation("items: что возвращаем")
	}

	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Блокируем продажу: два параллельных возврата не вернут больше проданного.
		var storeID, warehouseID string
		err := tx.QueryRow(ctx, `SELECT store_id, warehouse_id FROM sales WHERE id = $1 AND network_id = $2 FOR UPDATE`,
			in.SaleID, p.NetworkID).Scan(&storeID, &warehouseID)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(storeID)) {
			return apperr.NotFound("продажа не найдена")
		}
		if err != nil {
			return err
		}
		cashboxID, currency, methodStore, err := finance.PaymentMethodCashbox(ctx, tx, p.NetworkID, in.PaymentMethodID)
		if err != nil {
			return err
		}
		if methodStore == nil || *methodStore != storeID || currency != "UZS" {
			return apperr.Validation("payment_method_id: способ оплаты не относится к кассе этого магазина")
		}
		lockCashboxForReturn(ctx, tx, cashboxID)

		n, err := db.NextNumber(ctx, tx, "customer_returns", p.NetworkID, "")
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO customer_returns (network_id, store_id, sale_id, number, total, cost, payment_method_id, cashbox_id, reason, created_by)
			VALUES ($1, $2, $3, $4, 0, 0, $5, $6, $7, $8) RETURNING id`,
			p.NetworkID, storeID, in.SaleID, n, in.PaymentMethodID, cashboxID, strings.TrimSpace(in.Reason), p.EmployeeID).Scan(&id); err != nil {
			return err
		}

		total, cost := money.D("0"), money.D("0")
		seen := map[int]bool{}
		for _, it := range in.Items {
			ls := strconv.Itoa(it.SaleLine)
			if seen[it.SaleLine] {
				return apperr.Validation("items: строка чека " + ls + " повторяется")
			}
			seen[it.SaleLine] = true
			var productID, soldQty, lineTotal, returned string
			var fractional bool
			err := tx.QueryRow(ctx, `
				SELECT i.product_id, i.qty::text, i.total::text, u.is_fractional,
				       COALESCE((SELECT sum(ri.qty) FROM customer_return_items ri JOIN customer_returns r ON r.id = ri.return_id
				                 WHERE r.sale_id = i.sale_id AND ri.sale_line = i.line), 0)::text
				FROM sale_items i JOIN products p ON p.id = i.product_id JOIN units u ON u.id = p.unit_id
				WHERE i.sale_id = $1 AND i.line = $2`, in.SaleID, it.SaleLine).Scan(&productID, &soldQty, &lineTotal, &fractional, &returned)
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Validation("items: нет строки чека " + ls)
			}
			if err != nil {
				return err
			}
			if !it.Qty.Valid() || money.D(string(it.Qty)).Sign() <= 0 {
				return apperr.Validation("items: количество должно быть больше нуля (строка " + ls + ")")
			}
			qty := money.D(string(it.Qty))
			if !fractional && qty.Cmp(money.D(qty.Fixed(0))) != 0 {
				return apperr.Validation("items: штучный товар возвращается целым количеством (строка " + ls + ")")
			}
			left := money.D(soldQty).Sub(money.D(returned))
			if qty.Cmp(left) > 0 {
				return apperr.Conflict("return_exceeds_sale", "нельзя вернуть больше, чем продано").
					WithDetails(map[string]any{"sale_line": it.SaleLine, "available": left.Fixed(3)})
			}

			// Возвращаем в партии в обратном порядке списания, пропуская то,
			// что уже вернули раньше (оно тоже возвращалось с конца).
			taken, lineCost, err := batchesForReturn(ctx, tx, in.SaleID, it.SaleLine, money.D(returned), qty)
			if err != nil {
				return err
			}
			if err := inventory.ReturnToBatches(ctx, tx, p.NetworkID, taken, warehouseID, productID, inventory.DocCustomerReturn, id); err != nil {
				return err
			}
			refund := money.D(lineTotal).Mul(qty).Div(money.D(soldQty))
			// Последний возврат по строке забирает остаток суммы — без копеечных хвостов.
			if qty.Cmp(left) == 0 {
				var refunded string
				if err := tx.QueryRow(ctx, `
					SELECT COALESCE(sum(ri.total), 0)::text FROM customer_return_items ri
					JOIN customer_returns r ON r.id = ri.return_id WHERE r.sale_id = $1 AND ri.sale_line = $2`,
					in.SaleID, it.SaleLine).Scan(&refunded); err != nil {
					return err
				}
				refund = money.D(lineTotal).Sub(money.D(refunded))
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO customer_return_items (return_id, sale_line, qty, total, cost)
				VALUES ($1, $2, $3::numeric, $4::numeric, $5::numeric)`,
				id, it.SaleLine, qty.Fixed(3), refund.Money(), lineCost.Money()); err != nil {
				return err
			}
			total = total.Add(refund.Round2())
			cost = cost.Add(lineCost)
		}

		if _, err := tx.Exec(ctx, `UPDATE customer_returns SET total = $2::numeric, cost = $3::numeric WHERE id = $1`,
			id, total.Money(), cost.Money()); err != nil {
			return err
		}
		if total.Sign() > 0 {
			return finance.SubtractCash(ctx, tx, p.NetworkID, cashboxID, total.Money(), finance.DocCustomerReturn, id)
		}
		return nil
	})
	if err != nil {
		return CustomerReturn{}, err
	}
	return s.getReturn(ctx, s.pool, p, id)
}

func lockCashboxForReturn(ctx context.Context, tx pgx.Tx, cashboxID string) {
	_, _ = tx.Exec(ctx, `SELECT 1 FROM cashboxes WHERE id = $1 FOR UPDATE`, cashboxID)
}

// batchesForReturn выбирает, в какие партии вернуть qty по строке чека.
func batchesForReturn(ctx context.Context, tx pgx.Tx, saleID string, line int, alreadyReturned, qty money.Dec) ([]inventory.Taken, money.Dec, error) {
	rows, err := tx.Query(ctx, `
		SELECT batch_id, qty::text, unit_cost::text, unit_cost_usd::text
		FROM sale_item_batches WHERE sale_id = $1 AND line = $2 ORDER BY id DESC`, saleID, line)
	if err != nil {
		return nil, money.D("0"), err
	}
	all, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (inventory.Taken, error) {
		var t inventory.Taken
		err := r.Scan(&t.BatchID, &t.Qty, &t.UnitCost, &t.UnitCostUSD)
		return t, err
	})
	if err != nil {
		return nil, money.D("0"), err
	}
	var out []inventory.Taken
	cost := money.D("0")
	skip, need := alreadyReturned, qty
	for _, b := range all {
		avail := money.D(b.Qty)
		s := avail.Min(skip)
		avail, skip = avail.Sub(s), skip.Sub(s)
		if avail.Sign() <= 0 || need.Sign() <= 0 {
			continue
		}
		take := avail.Min(need)
		need = need.Sub(take)
		out = append(out, inventory.Taken{BatchID: b.BatchID, Qty: take.Fixed(3), UnitCost: b.UnitCost, UnitCostUSD: b.UnitCostUSD})
		cost = cost.Add(take.Mul(money.D(b.UnitCost)))
	}
	return out, cost, nil
}
