package reports

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Прибыль без цен закупки (Figma «Финансы понятно», Ф1, Ф4). Товар продан
// без себестоимости, если строка чека не взяла ни одной партии с ценой:
// остаток не посчитан («Только товары и цены») или партия заведена без цены
// закупки. Тогда себестоимость считается нулём и «прибыль» = выручке —
// такую прибыль приложение не показывает числом.

// noCostLine — строка чека без себестоимости (si — sale_items).
const noCostLine = `si.total > 0 AND si.unknown_barcode = '' AND (si.cost = 0
	OR EXISTS (SELECT 1 FROM sale_item_batches z WHERE z.sale_id = si.sale_id AND z.line = si.line AND z.unit_cost = 0))`

// costCoverage — сколько разных товаров продано за период и у скольких нет
// себестоимости.
func (s *Service) costCoverage(ctx context.Context, args []any) (sold, noCost int, err error) {
	err = s.pool.QueryRow(ctx, `
		SELECT count(DISTINCT si.product_id) FILTER (WHERE si.unknown_barcode = '')::int,
		       count(DISTINCT si.product_id) FILTER (WHERE `+noCostLine+`)::int
		FROM sale_items si JOIN sales sl ON sl.id = si.sale_id
		WHERE sl.network_id = $1 AND ($2::uuid[] IS NULL OR sl.store_id = ANY($2)) AND sl.sold_at >= $3 AND sl.sold_at < $4`, args...).
		Scan(&sold, &noCost)
	return sold, noCost, err
}

type NoCostItem struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	UnitShort string `json:"unit_short"`
	Qty       string `json:"qty"`
	Revenue   string `json:"revenue"`
}

// NoCost — товары, проданные за период без себестоимости (Ф4).
func (s *Service) NoCost(ctx context.Context, p *identity.Principal, f Filter) ([]NoCostItem, error) {
	sc, err := s.scope(p, f)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT si.product_id, loc(pr.name, pr.name_uz), loc(u.short_name, u.short_name_uz),
		       sum(si.qty)::numeric(14,3)::text, sum(si.total)::numeric(18,2)::text
		FROM sale_items si JOIN sales sl ON sl.id = si.sale_id
		JOIN products pr ON pr.id = si.product_id JOIN units u ON u.id = pr.unit_id
		WHERE sl.network_id = $1 AND ($2::uuid[] IS NULL OR sl.store_id = ANY($2)) AND sl.sold_at >= $3 AND sl.sold_at < $4
		  AND `+noCostLine+`
		GROUP BY si.product_id, pr.name, pr.name_uz, u.short_name, u.short_name_uz
		ORDER BY sum(si.total) DESC, pr.name LIMIT 300`, p.NetworkID, sc.stores, sc.from, sc.to)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[NoCostItem])
}

type CostInput struct {
	StoreID   string      `json:"store_id"`
	ProductID string      `json:"product_id"`
	Cost      money.Price `json:"cost"`
}

type CostResult struct {
	ProductID string `json:"product_id"`
	// Сколько строк проданных чеков получили себестоимость.
	Lines int `json:"lines"`
}

// SetCost — цена закупки товара, проданного без себестоимости: её получают
// партии магазина без цены (остаток с «Начала работы») и уже проданные
// строки — прибыль за прошлые дни пересчитывается.
func (s *Service) SetCost(ctx context.Context, p *identity.Principal, in CostInput) (CostResult, error) {
	out := CostResult{ProductID: in.ProductID}
	if err := p.RequireAny(identity.PermInventoryManage, identity.PermPricesManage); err != nil {
		return out, err
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if !httpx.IsUUID(in.ProductID) {
		return out, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if !in.Cost.Valid() || money.D(string(in.Cost)).Sign() <= 0 {
		return out, apperr.Validation("cost: цена закупки больше нуля").Uz("cost: xarid narxi noldan katta boʻlsin")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM stores WHERE id = $1 AND network_id = $2)`, in.StoreID, p.NetworkID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
		}
		usd := "0"
		if rate, err := finance.CurrentRate(ctx, tx, p.NetworkID); err == nil {
			usd = money.D(string(in.Cost)).Div(money.D(rate)).Fixed(6)
		} else if !errors.As(err, new(*apperr.Error)) {
			return err
		}
		// Строки чеков без себестоимости — до правки партий.
		rows, err := tx.Query(ctx, `
			SELECT si.sale_id, si.line FROM sale_items si JOIN sales sl ON sl.id = si.sale_id
			WHERE sl.network_id = $1 AND sl.store_id = $2 AND si.product_id = $3 AND `+noCostLine+` FOR UPDATE OF si`,
			p.NetworkID, in.StoreID, in.ProductID)
		if err != nil {
			return err
		}
		type key struct {
			sale string
			line int
		}
		lines, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (key, error) {
			var k key
			return k, r.Scan(&k.sale, &k.line)
		})
		if err != nil {
			return err
		}
		const wh = `(SELECT id FROM warehouses WHERE store_id = $4)`
		if _, err := tx.Exec(ctx, `UPDATE sale_item_batches z SET unit_cost = $2::numeric, unit_cost_usd = $3::numeric
			FROM batches b WHERE z.batch_id = b.id AND b.product_id = $1 AND b.warehouse_id IN `+wh+` AND z.unit_cost = 0`,
			in.ProductID, string(in.Cost), usd, in.StoreID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE batches SET unit_cost = $2::numeric, unit_cost_usd = $3::numeric
			WHERE product_id = $1 AND warehouse_id IN `+wh+` AND unit_cost = 0`, in.ProductID, string(in.Cost), usd, in.StoreID); err != nil {
			return err
		}
		sales := map[string]bool{}
		for _, k := range lines {
			if _, err := tx.Exec(ctx, `UPDATE sale_items si SET cost = round(
				  COALESCE((SELECT sum(z.qty * z.unit_cost) FROM sale_item_batches z WHERE z.sale_id = si.sale_id AND z.line = si.line), 0)
				  + si.short_qty * $3::numeric, 2)
				WHERE si.sale_id = $1 AND si.line = $2`, k.sale, k.line, string(in.Cost)); err != nil {
				return err
			}
			sales[k.sale] = true
		}
		for id := range sales {
			if _, err := tx.Exec(ctx, `UPDATE sales SET cost = (SELECT COALESCE(sum(cost), 0) FROM sale_items WHERE sale_id = $1) WHERE id = $1`, id); err != nil {
				return err
			}
		}
		out.Lines = len(lines)
		return nil
	})
	return out, err
}

// MissingCost — сколько товара в магазине без цены закупки: остаток в партиях
// без цены и продано без себестоимости (шторка сканера «SM Сотрудник», С5б).
// Нули — цена закупки есть везде, ставить нечего.
func (s *Service) MissingCost(ctx context.Context, networkID, storeID, productID string) (stock, sold string, err error) {
	err = s.pool.QueryRow(ctx, `
		SELECT trim_scale(COALESCE((SELECT sum(b.qty_remaining) FROM batches b
		         WHERE b.product_id = $3 AND b.unit_cost = 0 AND b.qty_remaining > 0
		           AND b.warehouse_id IN (SELECT id FROM warehouses WHERE store_id = $2)), 0))::text,
		       trim_scale(COALESCE((SELECT sum(si.qty) FROM sale_items si JOIN sales sl ON sl.id = si.sale_id
		         WHERE sl.network_id = $1 AND sl.store_id = $2 AND si.product_id = $3 AND `+noCostLine+`), 0))::text`,
		networkID, storeID, productID).Scan(&stock, &sold)
	return stock, sold, err
}
