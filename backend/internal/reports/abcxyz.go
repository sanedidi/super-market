package reports

import (
	"context"
	"math"
	"sort"
	"strconv"
	"time"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// ------------------------------------------------------ ABC/XYZ-анализ
//
// ABC — сколько товар приносит: товары сортируются по выбранному показателю
// (выручка, валовая прибыль или количество) и делятся по накопленной доле:
// A — первые 80%, B — следующие 15%, C — остальные 5%.
//
// XYZ — насколько ровно он продаётся: коэффициент вариации продаж по неделям
// (стандартное отклонение / среднее). X — до 10%, Y — до 25%, Z — больше.
//
// Продажи = чеки POS (по дате продажи) + доставленные онлайн-заказы (по дате
// доставки) − возвраты покупателей (по дате возврата). Доставка не входит.

const (
	abcA = 80.0 // накопленная доля, до которой товар в группе A
	abcB = 95.0
	xyzX = 10.0 // коэффициент вариации, %
	xyzY = 25.0

	// XYZ считается, когда есть хотя бы столько полных недель продаж.
	xyzMinWeeks = 4
	// Период по умолчанию — последние 12 недель.
	abcDefaultDays = 84
	abcMaxDays     = 366
)

const week = 7 * 24 * time.Hour

// AbcFilter — параметры отчёта.
type AbcFilter struct {
	Filter
	CategoryID string // с подкатегориями
	By         string // revenue (по умолчанию) | profit | qty
	// Compact — для главной: без списков товаров, только товары A, которых
	// хватит меньше чем на CoverAttentionDays дней (до пяти, сначала кончающиеся).
	Compact bool
}

type AbcGroup struct {
	Count   int     `json:"count"`
	Share   float64 `json:"share"`   // доля показателя, %
	Revenue string  `json:"revenue"` // выручка группы, сум
	Profit  string  `json:"profit"`
}

type AbcCell struct {
	Cell    string  `json:"cell"` // AX … CZ
	Count   int     `json:"count"`
	Share   float64 `json:"share"` // доля показателя, %
	Revenue string  `json:"revenue"`
}

type AbcItem struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Category  string  `json:"category"`
	Unit      string  `json:"unit"`
	Image     *string `json:"image"`
	ABC       string  `json:"abc"`
	XYZ       *string `json:"xyz"` // null — недостаточно недель
	Revenue   string  `json:"revenue"`
	Profit    string  `json:"profit"`
	Qty       string  `json:"qty"`
	Share     float64 `json:"share"`     // доля показателя, %
	CumShare  float64 `json:"cum_share"` // накопленная доля, %
	// Коэффициент вариации продаж по неделям, %; null — XYZ ещё не считается.
	Variation *float64 `json:"variation"`
	Stock     string   `json:"stock"`
	// На сколько дней хватит остатка при спросе за последние 14 дней (см. DaysCover).
	DaysCover *float64 `json:"days_cover"`
}

type AbcNoSale struct {
	ProductID  string  `json:"product_id"`
	Name       string  `json:"name"`
	Category   string  `json:"category"`
	Unit       string  `json:"unit"`
	Image      *string `json:"image"`
	Stock      string  `json:"stock"`
	StockValue string  `json:"stock_value"` // по себестоимости, сум
}

type AbcTotals struct {
	Revenue  string `json:"revenue"`
	Profit   string `json:"profit"`
	Qty      string `json:"qty"`
	Products int    `json:"products"`
}

type AbcXyz struct {
	From time.Time `json:"from"`
	To   time.Time `json:"to"`
	By   string    `json:"by"`
	// С какого дня считается анализ: начало периода или первая продажа,
	// если магазин начал продавать позже.
	AnalysisFrom time.Time `json:"analysis_from"`
	Weeks        int       `json:"weeks"` // полных недель продаж
	XYZAvailable bool      `json:"xyz_available"`
	// Через сколько дней наберётся xyzMinWeeks недель (0 — уже есть).
	XYZDaysLeft int                 `json:"xyz_days_left"`
	MinWeeks    int                 `json:"min_weeks"`
	Totals      AbcTotals           `json:"totals"`
	Groups      map[string]AbcGroup `json:"groups"`
	Matrix      []AbcCell           `json:"matrix"`
	NoSales     struct {
		Count      int    `json:"count"`
		StockValue string `json:"stock_value"`
	} `json:"no_sales"`
	Items       []AbcItem   `json:"items"`
	NoSaleItems []AbcNoSale `json:"no_sale_items"`
}

// abcScope — период отчёта. Без from — последние 12 недель.
func (s *Service) abcScope(p *identity.Principal, f AbcFilter) (scope, error) {
	if f.From == nil {
		to := f.To
		if to == nil {
			now := s.now().In(tashkent)
			t := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent).AddDate(0, 0, 1)
			to = &t
		}
		from := to.AddDate(0, 0, -abcDefaultDays)
		f.From, f.To = &from, to
	}
	sc, err := s.scope(p, f.Filter)
	if err != nil {
		return sc, err
	}
	if sc.to.Sub(sc.from) > abcMaxDays*24*time.Hour {
		return sc, apperr.Validation("period: не больше года").Uz("period: bir yildan oshmasin")
	}
	return sc, nil
}

type abcRow struct {
	id, name, category, unit string
	image                    *string
	revenue, profit, qty     money.Dec
	sold14                   money.Dec // продано за последние CoverWindowDays дней
	weeks                    map[int]float64
	stock, stockValue        string
	metric                   float64
}

func (s *Service) AbcXyz(ctx context.Context, p *identity.Principal, f AbcFilter) (AbcXyz, error) {
	switch f.By {
	case "":
		f.By = "revenue"
	case "revenue", "profit", "qty":
	default:
		return AbcXyz{}, apperr.Validation("by: revenue, profit или qty").Uz("by: revenue, profit yoki qty")
	}
	if f.CategoryID != "" && !httpx.IsUUID(f.CategoryID) {
		return AbcXyz{}, apperr.Validation("category_id: неверный id").Uz("category_id: id notoʻgʻri")
	}
	sc, err := s.abcScope(p, f)
	if err != nil {
		return AbcXyz{}, err
	}
	out := AbcXyz{From: sc.from, To: sc.to, By: f.By, MinWeeks: xyzMinWeeks,
		Groups: map[string]AbcGroup{}, Matrix: []AbcCell{}, Items: []AbcItem{}, NoSaleItems: []AbcNoSale{}}

	// Первая продажа магазина в периоде: новый магазин не должен получить
	// «пустые» недели до открытия — иначе весь товар уйдёт в Z.
	var first *time.Time
	if err := s.pool.QueryRow(ctx, `
		SELECT LEAST(
			(SELECT min(sold_at) FROM sales WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2)) AND sold_at >= $3 AND sold_at < $4),
			(SELECT min(delivered_at) FROM orders WHERE network_id = $1 AND ($2::uuid[] IS NULL OR store_id = ANY($2))
			    AND status = 'delivered' AND delivered_at >= $3 AND delivered_at < $4))`,
		p.NetworkID, sc.stores, sc.from, sc.to).Scan(&first); err != nil {
		return out, err
	}
	start := sc.from
	if first != nil {
		d := first.In(tashkent)
		if day := time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, tashkent); day.After(start) {
			start = day
		}
	}
	out.AnalysisFrom = start
	if first != nil {
		out.Weeks = int(sc.to.Sub(start) / week)
	}
	out.XYZAvailable = out.Weeks >= xyzMinWeeks
	if first != nil && !out.XYZAvailable {
		left := start.Add(xyzMinWeeks * week).Sub(sc.to)
		out.XYZDaysLeft = int(math.Ceil(left.Hours() / 24))
	}

	// Продажи по товарам и неделям.
	// Продажи по товарам и неделям; sold14 — продано за последние дни для
	// «на сколько дней хватит остатка» (то же окно, что в «Итогах дня»).
	end := s.live(sc)
	rows, err := s.pool.Query(ctx, `
		WITH RECURSIVE cats AS (
			SELECT id FROM categories WHERE $6 <> '' AND id::text = $6
			UNION ALL SELECT c.id FROM categories c JOIN cats ON c.parent_id = cats.id
		), `+salesLinesCTE+`
		SELECT l.product_id, loc(p.name, p.name_uz), COALESCE(loc(c.name, c.name_uz), ''), loc(u.short_name, u.short_name_uz), p.images[1],
		       GREATEST(floor(extract(epoch FROM l.at - $5) / 604800), 0)::int,
		       sum(l.qty)::text, sum(l.revenue)::numeric(18,2)::text, sum(l.revenue - l.cost)::numeric(18,2)::text,
		       COALESCE(sum(l.qty) FILTER (WHERE l.at >= $7), 0)::text
		FROM lines l
		JOIN products p ON p.id = l.product_id
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN categories c ON c.id = p.category_id
		WHERE $6 = '' OR p.category_id IN (SELECT id FROM cats)
		GROUP BY 1, 2, 3, 4, 5, 6`,
		p.NetworkID, sc.stores, sc.from, sc.to, start, f.CategoryID, end.AddDate(0, 0, -CoverWindowDays))
	if err != nil {
		return out, err
	}
	byID := map[string]*abcRow{}
	var order []string
	for rows.Next() {
		var r abcRow
		var wk int
		var qty, rev, profit, sold string
		if err := rows.Scan(&r.id, &r.name, &r.category, &r.unit, &r.image, &wk, &qty, &rev, &profit, &sold); err != nil {
			rows.Close()
			return out, err
		}
		x, ok := byID[r.id]
		if !ok {
			r.revenue, r.profit, r.qty, r.sold14 = money.D("0"), money.D("0"), money.D("0"), money.D("0")
			r.weeks = map[int]float64{}
			x = &r
			byID[r.id] = x
			order = append(order, r.id)
		}
		x.revenue = x.revenue.Add(money.D(rev))
		x.profit = x.profit.Add(money.D(profit))
		x.qty = x.qty.Add(money.D(qty))
		x.sold14 = x.sold14.Add(money.D(sold))
		q, _ := strconv.ParseFloat(qty, 64)
		x.weeks[wk] += q
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}

	// Остатки на складах магазинов из области отчёта.
	stock := map[string][2]string{}
	srows, err := s.pool.Query(ctx, `
		WITH RECURSIVE cats AS (
			SELECT id FROM categories WHERE $3 <> '' AND id::text = $3
			UNION ALL SELECT c.id FROM categories c JOIN cats ON c.parent_id = cats.id
		)
		SELECT b.product_id, sum(b.qty_remaining)::text, round(sum(b.qty_remaining * b.unit_cost), 2)::text
		FROM batches b
		JOIN warehouses w ON w.id = b.warehouse_id
		JOIN products p ON p.id = b.product_id
		WHERE b.network_id = $1 AND ($2::uuid[] IS NULL OR w.store_id = ANY($2)) AND b.qty_remaining > 0
		  AND ($3 = '' OR p.category_id IN (SELECT id FROM cats))
		GROUP BY 1`, p.NetworkID, sc.stores, f.CategoryID)
	if err != nil {
		return out, err
	}
	for srows.Next() {
		var id, q, v string
		if err := srows.Scan(&id, &q, &v); err != nil {
			srows.Close()
			return out, err
		}
		stock[id] = [2]string{q, v}
	}
	srows.Close()
	if err := srows.Err(); err != nil {
		return out, err
	}

	// Товары с продажами: показатель и сортировка.
	items := make([]*abcRow, 0, len(order))
	totRev, totProfit, totQty := money.D("0"), money.D("0"), money.D("0")
	var totMetric float64
	for _, id := range order {
		r := byID[id]
		totRev, totProfit, totQty = totRev.Add(r.revenue), totProfit.Add(r.profit), totQty.Add(r.qty)
		// Всё вернули — продаж за период по сути нет.
		if r.qty.Sign() <= 0 && r.revenue.Sign() <= 0 {
			continue
		}
		var v money.Dec
		switch f.By {
		case "profit":
			v = r.profit
		case "qty":
			v = r.qty
		default:
			v = r.revenue
		}
		r.metric, _ = v.Float64()
		if r.metric > 0 {
			totMetric += r.metric
		}
		items = append(items, r)
	}
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].metric != items[j].metric {
			return items[i].metric > items[j].metric
		}
		return items[i].name < items[j].name
	})
	out.Totals = AbcTotals{Revenue: totRev.Money(), Profit: totProfit.Money(), Qty: totQty.Fixed(3), Products: len(items)}

	groups := map[string]*struct {
		n             int
		share         float64
		revenue, prof money.Dec
	}{}
	cells := map[string]*AbcCell{}
	var cum float64
	for _, r := range items {
		share := 0.0
		if totMetric > 0 && r.metric > 0 {
			share = r.metric / totMetric * 100
		}
		abc := "C"
		switch {
		case r.metric <= 0:
		case cum < abcA:
			abc = "A"
		case cum < abcB:
			abc = "B"
		}
		cum += share
		it := AbcItem{ProductID: r.id, Name: r.name, Category: r.category, Unit: r.unit, Image: r.image, ABC: abc,
			Revenue: r.revenue.Money(), Profit: r.profit.Money(), Qty: r.qty.Fixed(3),
			Share: round2(share), CumShare: round2(math.Min(cum, 100)), Stock: "0.000"}
		if st, ok := stock[r.id]; ok {
			it.Stock = st[0]
		}
		if out.XYZAvailable {
			xyz := "Z"
			if cv, ok := variation(r.weeks, out.Weeks); ok {
				switch {
				case cv <= xyzX:
					xyz = "X"
				case cv <= xyzY:
					xyz = "Y"
				}
				cv = round2(cv)
				it.Variation = &cv
			}
			it.XYZ = &xyz
		}
		st, _ := strconv.ParseFloat(it.Stock, 64)
		sold, _ := r.sold14.Float64()
		it.DaysCover = DaysCover(st, sold)
		out.Items = append(out.Items, it)

		g := groups[abc]
		if g == nil {
			g = &struct {
				n             int
				share         float64
				revenue, prof money.Dec
			}{revenue: money.D("0"), prof: money.D("0")}
			groups[abc] = g
		}
		g.n++
		g.share += share
		g.revenue, g.prof = g.revenue.Add(r.revenue), g.prof.Add(r.profit)
		if it.XYZ != nil {
			k := abc + *it.XYZ
			c := cells[k]
			if c == nil {
				c = &AbcCell{Cell: k, Revenue: "0"}
				cells[k] = c
			}
			c.Count++
			c.Share += share
			c.Revenue = money.D(c.Revenue).Add(r.revenue).Money()
		}
	}
	for _, k := range []string{"A", "B", "C"} {
		g := AbcGroup{Revenue: "0.00", Profit: "0.00"}
		if x := groups[k]; x != nil {
			g = AbcGroup{Count: x.n, Share: round2(x.share), Revenue: x.revenue.Money(), Profit: x.prof.Money()}
		}
		out.Groups[k] = g
	}
	if out.XYZAvailable {
		for _, a := range []string{"A", "B", "C"} {
			for _, x := range []string{"X", "Y", "Z"} {
				c := AbcCell{Cell: a + x, Revenue: "0.00"}
				if v := cells[a+x]; v != nil {
					c = *v
					c.Share = round2(c.Share)
				}
				out.Matrix = append(out.Matrix, c)
			}
		}
	}

	// Без продаж: есть на складе, но за период не продались.
	if len(stock) > 0 {
		ids := make([]string, 0, len(stock))
		for id := range stock {
			if r, ok := byID[id]; !ok || (r.qty.Sign() <= 0 && r.revenue.Sign() <= 0) {
				ids = append(ids, id)
			}
		}
		if len(ids) > 0 {
			prow, err := s.pool.Query(ctx, `
				SELECT p.id, loc(p.name, p.name_uz), COALESCE(loc(c.name, c.name_uz), ''), loc(u.short_name, u.short_name_uz), p.images[1]
				FROM products p JOIN units u ON u.id = p.unit_id LEFT JOIN categories c ON c.id = p.category_id
				WHERE p.id = ANY($1::uuid[])`, ids)
			if err != nil {
				return out, err
			}
			value := money.D("0")
			for prow.Next() {
				var n AbcNoSale
				if err := prow.Scan(&n.ProductID, &n.Name, &n.Category, &n.Unit, &n.Image); err != nil {
					prow.Close()
					return out, err
				}
				n.Stock, n.StockValue = stock[n.ProductID][0], stock[n.ProductID][1]
				value = value.Add(money.D(n.StockValue))
				out.NoSaleItems = append(out.NoSaleItems, n)
			}
			prow.Close()
			if err := prow.Err(); err != nil {
				return out, err
			}
			sort.Slice(out.NoSaleItems, func(i, j int) bool {
				a, _ := strconv.ParseFloat(out.NoSaleItems[i].StockValue, 64)
				b, _ := strconv.ParseFloat(out.NoSaleItems[j].StockValue, 64)
				if a != b {
					return a > b
				}
				return out.NoSaleItems[i].Name < out.NoSaleItems[j].Name
			})
			out.NoSales.StockValue = value.Money()
		}
	}
	out.NoSales.Count = len(out.NoSaleItems)
	if out.NoSales.StockValue == "" {
		out.NoSales.StockValue = "0.00"
	}
	if f.Compact {
		out.Items, out.NoSaleItems = attention(out.Items), []AbcNoSale{}
	}
	return out, nil
}

// variation — коэффициент вариации продаж по полным неделям, %.
// Недели без продаж считаются нулями; неполная последняя неделя не входит.
// false — в полных неделях продаж нет (продался только в последние дни).
func variation(weeks map[int]float64, n int) (float64, bool) {
	if n <= 0 {
		return 0, false
	}
	var sum float64
	for w := 0; w < n; w++ {
		sum += weeks[w]
	}
	mean := sum / float64(n)
	if mean <= 0 {
		return 0, false
	}
	var ss float64
	for w := 0; w < n; w++ {
		d := weeks[w] - mean
		ss += d * d
	}
	return math.Sqrt(ss/float64(n)) / mean * 100, true
}

func round2(v float64) float64 { return math.Round(v*100) / 100 }

// attention — главные товары (A), которые скоро закончатся.
func attention(items []AbcItem) []AbcItem {
	out := []AbcItem{}
	for _, it := range items {
		if it.ABC == "A" && it.DaysCover != nil && *it.DaysCover < CoverAttentionDays {
			out = append(out, it)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return *out[i].DaysCover < *out[j].DaysCover })
	if len(out) > coverAttentionMax {
		out = out[:coverAttentionMax]
	}
	return out
}
