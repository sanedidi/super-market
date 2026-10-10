package variants

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/variants/naming"
)

// Группа вариаций в панели магазина: вес → вкусы, цена на вес (все вкусы
// веса её наследуют), «своя цена» вкуса и остаток по каждому вкусу.

type StoreItem struct {
	ProductID   string  `json:"product_id"`
	Name        string  `json:"name"`
	Flavor      string  `json:"flavor"`
	Barcode     string  `json:"barcode"`
	Image       *string `json:"image"`
	Price       string  `json:"price"`
	PriceSource string  `json:"price_source"` // store | network | base
	OwnPrice    bool    `json:"own_price"`
	Stock       string  `json:"stock"`
}

type StoreWeight struct {
	Weight string `json:"weight"`
	// Price — общая цена вкусов без «своей цены»; null — у них разные цены.
	Price *string     `json:"price"`
	Stock string      `json:"stock"`
	Items []StoreItem `json:"items"`
}

type StoreGroup struct {
	ID          string        `json:"id"`
	Name        string        `json:"name"`
	BrandName   *string       `json:"brand_name"`
	StoreID     string        `json:"store_id"`
	PriceTypeID string        `json:"price_type_id"`
	Stock       string        `json:"stock"`
	Weights     []StoreWeight `json:"weights"`
}

// storeScope — магазин сети и тип цены.
func (s *Service) storeScope(ctx context.Context, pr *identity.Principal, storeID, priceTypeID string) (warehouse *string, typeID string, err error) {
	if !httpx.IsUUID(storeID) || !pr.CanAccessStore(storeID) {
		return nil, "", apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	err = s.pool.QueryRow(ctx, `SELECT default_warehouse_id FROM stores WHERE id = $1 AND network_id = $2`, storeID, pr.NetworkID).Scan(&warehouse)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, "", apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if err != nil {
		return nil, "", err
	}
	typeID, err = s.cat.ResolvePriceType(ctx, pr.NetworkID, storeID, priceTypeID)
	return warehouse, typeID, err
}

// StoreGroup — группа для магазина.
func (s *Service) StoreGroup(ctx context.Context, pr *identity.Principal, groupID, storeID, priceTypeID string) (StoreGroup, error) {
	out := StoreGroup{ID: groupID, StoreID: storeID, Weights: []StoreWeight{}}
	wh, typeID, err := s.storeScope(ctx, pr, storeID, priceTypeID)
	if err != nil {
		return out, err
	}
	out.PriceTypeID = typeID
	err = s.pool.QueryRow(ctx, `
		SELECT loc(g.name, g.name_uz), b.name FROM variant_groups g LEFT JOIN brands b ON b.id = g.brand_id
		WHERE g.id = $1 AND g.status = 'confirmed'`, groupID).Scan(&out.Name, &out.BrandName)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("группа не найдена").Uz("guruh topilmadi")
	}
	if err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), loc(p.variant_weight, p.variant_weight_uz), loc(p.variant_flavor, p.variant_flavor_uz),
		       COALESCE((SELECT min(b.barcode) FROM product_barcodes b WHERE b.product_id = p.id), ''), p.images[1],
		       COALESCE(sp.price, np.price, p.base_price)::text,
		       CASE WHEN sp.price IS NOT NULL THEN 'store' WHEN np.price IS NOT NULL THEN 'network' ELSE 'base' END,
		       EXISTS (SELECT 1 FROM variant_own_prices o WHERE o.store_id = $2 AND o.product_id = p.id),
		       COALESCE((SELECT sum(bt.qty_remaining) FROM batches bt WHERE bt.warehouse_id = $4 AND bt.product_id = p.id AND bt.qty_remaining > 0), 0)::text
		FROM products p
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL
		WHERE p.variant_group_id = $1 AND p.is_active
		ORDER BY p.variant_weight_sort, p.variant_weight, p.variant_sort, p.name`, groupID, storeID, typeID, wh)
	if err != nil {
		return out, err
	}
	type row struct {
		weight string
		item   StoreItem
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) {
		var x row
		err := r.Scan(&x.item.ProductID, &x.item.Name, &x.weight, &x.item.Flavor, &x.item.Barcode, &x.item.Image,
			&x.item.Price, &x.item.PriceSource, &x.item.OwnPrice, &x.item.Stock)
		return x, err
	})
	if err != nil {
		return out, err
	}
	total := 0.0
	for _, x := range items {
		n := len(out.Weights)
		if n == 0 || naming.Fold(out.Weights[n-1].Weight) != naming.Fold(x.weight) {
			out.Weights = append(out.Weights, StoreWeight{Weight: x.weight, Items: []StoreItem{}})
			n++
		}
		w := &out.Weights[n-1]
		x.item.Stock = qty(num(x.item.Stock))
		w.Items = append(w.Items, x.item)
		total += num(x.item.Stock)
	}
	for i := range out.Weights {
		w := &out.Weights[i]
		sum := 0.0
		var common *string
		mixed := false
		for _, it := range w.Items {
			sum += num(it.Stock)
			if it.OwnPrice {
				continue
			}
			if common == nil {
				p := it.Price
				common = &p
			} else if !samePrice(*common, it.Price) {
				mixed = true
			}
		}
		if !mixed {
			w.Price = common
		}
		w.Stock = qty(sum)
	}
	out.Stock = qty(total)
	return out, nil
}

// WeightPriceInput — цена веса для всех его вкусов (кроме «своей цены»).
type WeightPriceInput struct {
	StoreID     string       `json:"store_id"`
	PriceTypeID string       `json:"price_type_id"`
	Weight      string       `json:"weight"`
	Price       money.Amount `json:"price"`
}

// SetWeightPrice — «Установка цен» на все вкусы веса без своей цены.
func (s *Service) SetWeightPrice(ctx context.Context, pr *identity.Principal, groupID string, in WeightPriceInput) (StoreGroup, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return StoreGroup{}, err
	}
	if !in.Price.Valid() {
		return StoreGroup{}, apperr.Validation("price: укажите цену").Uz("price: narxni kiriting")
	}
	g, err := s.StoreGroup(ctx, pr, groupID, in.StoreID, in.PriceTypeID)
	if err != nil {
		return g, err
	}
	prices := map[string]money.Amount{}
	var weight string
	for _, w := range g.Weights {
		if naming.Fold(w.Weight) != naming.Fold(in.Weight) {
			continue
		}
		weight = w.Weight
		for _, it := range w.Items {
			if !it.OwnPrice {
				prices[it.ProductID] = in.Price
			}
		}
	}
	if len(prices) == 0 {
		return g, apperr.Validation("weight: у этого веса нет вкусов без своей цены").Uz("weight: bu vaznda oʻz narxi boʻlmagan taʼm yoʻq")
	}
	note := "Цена веса «" + weight + "» · " + g.Name
	if _, err := s.cat.SetStorePrices(ctx, pr, in.StoreID, g.PriceTypeID, note, prices); err != nil {
		return g, err
	}
	return s.StoreGroup(ctx, pr, groupID, in.StoreID, g.PriceTypeID)
}

// OwnPriceInput — «своя цена» вкуса: включить с ценой или вернуть цену веса.
type OwnPriceInput struct {
	StoreID     string        `json:"store_id"`
	PriceTypeID string        `json:"price_type_id"`
	ProductID   string        `json:"product_id"`
	Own         bool          `json:"own"`
	Price       *money.Amount `json:"price"`
}

func (s *Service) SetOwnPrice(ctx context.Context, pr *identity.Principal, groupID string, in OwnPriceInput) (StoreGroup, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return StoreGroup{}, err
	}
	if in.Price != nil && !in.Price.Valid() {
		return StoreGroup{}, apperr.Validation("price: неверная цена").Uz("price: narx notoʻgʻri")
	}
	g, err := s.StoreGroup(ctx, pr, groupID, in.StoreID, in.PriceTypeID)
	if err != nil {
		return g, err
	}
	var weight *StoreWeight
	var item *StoreItem
	for i := range g.Weights {
		for j := range g.Weights[i].Items {
			if g.Weights[i].Items[j].ProductID == in.ProductID {
				weight, item = &g.Weights[i], &g.Weights[i].Items[j]
			}
		}
	}
	if item == nil {
		return g, apperr.Validation("product_id: товара нет в группе").Uz("product_id: mahsulot guruhda yoʻq")
	}
	if in.Own {
		if _, err := s.pool.Exec(ctx, `INSERT INTO variant_own_prices (store_id, product_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			in.StoreID, in.ProductID); err != nil {
			return g, err
		}
		if in.Price != nil {
			note := "Своя цена · " + item.Name
			if _, err := s.cat.SetStorePrices(ctx, pr, in.StoreID, g.PriceTypeID, note, map[string]money.Amount{in.ProductID: *in.Price}); err != nil {
				return g, err
			}
		}
	} else {
		if _, err := s.pool.Exec(ctx, `DELETE FROM variant_own_prices WHERE store_id = $1 AND product_id = $2`,
			in.StoreID, in.ProductID); err != nil {
			return g, err
		}
		// Цена веса — общая цена остальных вкусов без своей цены.
		var common string
		for _, it := range weight.Items {
			if it.ProductID == in.ProductID || it.OwnPrice {
				continue
			}
			if common == "" {
				common = it.Price
			} else if !samePrice(common, it.Price) {
				common = ""
				break
			}
		}
		if common != "" && !samePrice(common, item.Price) {
			note := "Цена веса «" + weight.Weight + "» · " + item.Name
			if _, err := s.cat.SetStorePrices(ctx, pr, in.StoreID, g.PriceTypeID, note,
				map[string]money.Amount{in.ProductID: money.Amount(common)}); err != nil {
				return g, err
			}
		}
	}
	return s.StoreGroup(ctx, pr, groupID, in.StoreID, g.PriceTypeID)
}

func samePrice(a, b string) bool { return num(a) == num(b) }

func num(s string) float64 {
	var v float64
	var frac, div float64 = 0, 1
	dot := false
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r >= '0' && r <= '9':
			if dot {
				div *= 10
				frac = frac*10 + float64(r-'0')
			} else {
				v = v*10 + float64(r-'0')
			}
		case r == '.':
			dot = true
		}
	}
	return v + frac/div
}

// qty — количество строкой без лишних нулей: 12, 1.5.
func qty(v float64) string {
	s := strings.TrimRight(strings.TrimRight(strconv.FormatFloat(v, 'f', 3, 64), "0"), ".")
	if s == "" || s == "-" {
		return "0"
	}
	return s
}
