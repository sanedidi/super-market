package cafe

import (
	"context"
	"errors"
	"sort"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Need — сколько продукта списать.
type Need struct {
	IngredientID string
	Qty          money.Dec
}

// Explode раскладывает qty блюда (или заготовки) на продукты по техкарте с
// учётом модификаторов: «0,5 порции» умножает техкарту, «без лука» убирает
// строку, «+ сыр» добавляет продукт. Порядок — по id продукта (одинаковый
// порядок блокировок у параллельных продаж).
func Explode(ctx context.Context, q db.Querier, productID string, qty money.Dec, mods []ResolvedModifier) ([]Need, error) {
	var yield string
	if err := q.QueryRow(ctx, `SELECT yield_qty::text FROM products WHERE id = $1`, productID).Scan(&yield); err != nil {
		return nil, err
	}
	rows, err := q.Query(ctx, `SELECT ingredient_id, qty::text FROM recipe_items WHERE product_id = $1 ORDER BY line`, productID)
	if err != nil {
		return nil, err
	}
	type line struct {
		id  string
		qty string
	}
	lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (line, error) {
		var l line
		err := r.Scan(&l.id, &l.qty)
		return l, err
	})
	if err != nil {
		return nil, err
	}
	factor := money.D("1")
	removed := map[string]bool{}
	for _, m := range mods {
		switch m.Action {
		case ActionFactor:
			factor = factor.Mul(m.Factor)
		case ActionRemove:
			removed[m.ProductID] = true
		}
	}
	need := map[string]money.Dec{}
	add := func(id string, v money.Dec) {
		if cur, ok := need[id]; ok {
			need[id] = cur.Add(v)
		} else {
			need[id] = v
		}
	}
	perUnit := factor.Div(money.D(yield))
	for _, l := range lines {
		if removed[l.id] {
			continue
		}
		add(l.id, money.D(l.qty).Mul(perUnit).Mul(qty))
	}
	for _, m := range mods {
		if m.Action == ActionAdd {
			add(m.ProductID, m.AddQty.Mul(money.D(strconv.Itoa(m.Qty))).Mul(qty))
		}
	}
	out := make([]Need, 0, len(need))
	for id, v := range need {
		v = money.D(v.Fixed(3))
		if v.Sign() > 0 {
			out = append(out, Need{IngredientID: id, Qty: v})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].IngredientID < out[j].IngredientID })
	return out, nil
}

// TakenIngredient — что списано по одному продукту.
type TakenIngredient struct {
	IngredientID string
	Qty          money.Dec
	Short        money.Dec
	Taken        []inventory.Taken
	Cost         money.Dec
}

// TakeIngredients списывает продукты со склада по FIFO столько, сколько есть;
// чего не хватило — Short (вызывающий записывает «минус»). Продажа и
// производство в кафе не останавливаются из-за учёта.
func TakeIngredients(ctx context.Context, tx pgx.Tx, networkID, warehouseID string, needs []Need, docType, docID string) ([]TakenIngredient, error) {
	out := make([]TakenIngredient, 0, len(needs))
	for _, n := range needs {
		taken, short, err := inventory.TakeUpTo(ctx, tx, networkID, warehouseID, n.IngredientID, n.Qty.Fixed(3), docType, docID)
		if err != nil {
			return nil, err
		}
		cost := money.D("0")
		for _, t := range taken {
			cost = cost.Add(money.D(t.Qty).Mul(money.D(t.UnitCost)))
		}
		out = append(out, TakenIngredient{IngredientID: n.IngredientID, Qty: n.Qty, Short: money.D(short), Taken: taken, Cost: cost})
	}
	return out, nil
}

// RecordSaleLine записывает списание по строке чека с блюдом: партии,
// продукты, модификаторы и «минус». Строка sale_items уже должна быть.
func RecordSaleLine(ctx context.Context, tx pgx.Tx, networkID, warehouseID, saleID string, line int, taken []TakenIngredient, mods []ResolvedModifier) error {
	for _, ti := range taken {
		for _, t := range ti.Taken {
			if _, err := tx.Exec(ctx, `
				INSERT INTO sale_item_batches (sale_id, line, batch_id, qty, unit_cost, unit_cost_usd)
				VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric)`,
				saleID, line, t.BatchID, t.Qty, t.UnitCost, t.UnitCostUSD); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO sale_item_ingredients (sale_id, line, ingredient_id, qty, short_qty, cost)
			VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric)`,
			saleID, line, ti.IngredientID, ti.Qty.Fixed(3), ti.Short.Fixed(3), ti.Cost.Money()); err != nil {
			return err
		}
		if ti.Short.Sign() > 0 {
			l := line
			if err := inventory.AddShortfall(ctx, tx, networkID, warehouseID, ti.IngredientID, ti.Short.Fixed(3), inventory.DocSale, saleID, &l); err != nil {
				return err
			}
		}
	}
	for _, m := range mods {
		if _, err := tx.Exec(ctx, `
			INSERT INTO sale_item_modifiers (sale_id, line, option_id, name, qty, price)
			VALUES ($1, $2, $3, $4, $5, $6::numeric)`, saleID, line, m.OptionID, m.Name, m.Qty, m.Price.Money()); err != nil {
			return err
		}
	}
	return nil
}

// isCheckViolation — нарушено ограничение CHECK.
func isCheckViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23514"
}
