package orders

import (
	"context"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Поиск по всем магазинам рядом: товар → в каких магазинах есть, почём и
// привезут ли. Магазины — те же, что на главной: доставляющие и до 10 км.

// SearchOffer — товар в одном магазине.
type SearchOffer struct {
	StoreID         string  `json:"store_id"`
	StoreName       string  `json:"store_name"`
	NetworkName     string  `json:"network_name"`
	Delivers        bool    `json:"delivers"`
	EtaMin          *int    `json:"eta_min"`
	EtaMax          *int    `json:"eta_max"`
	DistanceM       int     `json:"distance_m"`
	IsOpen          bool    `json:"is_open"`
	Reason          string  `json:"reason,omitempty"`
	Price           string  `json:"price"`
	OldPrice        *string `json:"old_price"`
	DiscountPercent *int    `json:"discount_percent"`
	Available       string  `json:"available"`
}

// SearchItem — товар и магазины, где он есть: сначала те, что привезут, дешевле, ближе.
type SearchItem struct {
	Product SearchProduct `json:"product"`
	Offers  []SearchOffer `json:"offers"`
	// MinPrice — самая низкая цена среди магазинов.
	MinPrice string `json:"min_price"`
}

type SearchProduct struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Description  string   `json:"description"`
	BrandName    *string  `json:"brand_name"`
	CategoryID   string   `json:"category_id"`
	UnitShort    string   `json:"unit_short"`
	IsFractional bool     `json:"is_fractional"`
	Images       []string `json:"images"`
	IsNew        bool     `json:"is_new"`
}

type SearchResult struct {
	Items []SearchItem `json:"items"`
	// Stores — в скольких магазинах рядом нашлись товары.
	Stores int `json:"stores"`
}

type searchStore struct {
	name, network, reason string
	delivers, open        bool
	etaMin, etaMax        *int
	dist                  int
}

// Search — товары по названию или штрихкоду во всех магазинах рядом с точкой.
func (s *Service) Search(ctx context.Context, lat, lng float64, q string, onlyDelivering bool, limit int) (SearchResult, error) {
	out := SearchResult{Items: []SearchItem{}}
	q = strings.TrimSpace(q)
	if len([]rune(q)) < 2 {
		return out, nil
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	near, err := s.delivery.Nearby(ctx, lat, lng)
	if err != nil {
		return out, err
	}
	stores := map[string]searchStore{}
	ids := make([]string, 0, len(near))
	for _, st := range near {
		stores[st.ID] = searchStore{name: st.Name, network: st.NetworkName, delivers: true, open: st.Quote.IsOpen,
			etaMin: st.EtaMin, etaMax: st.EtaMax, dist: st.Quote.DistanceM}
		ids = append(ids, st.ID)
	}
	if !onlyDelivering {
		others, err := s.delivery.Others(ctx, lat, lng, ids)
		if err != nil {
			return out, err
		}
		for _, st := range others {
			stores[st.ID] = searchStore{name: st.Name, network: st.NetworkName, open: st.IsOpen, reason: st.Reason, dist: st.DistanceM}
			ids = append(ids, st.ID)
		}
	}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.pool.Query(ctx, `
		WITH st AS (
			SELECT s.id, s.default_warehouse_id AS wh, COALESCE(s.online_price_type_id, pt.id) AS pt
			FROM stores s JOIN price_types pt ON pt.network_id = s.network_id AND pt.is_default
			WHERE s.id = ANY ($1::uuid[]) AND s.default_warehouse_id IS NOT NULL
		), m AS (
			SELECT p.id FROM products p
			WHERE p.network_id IS NULL AND p.is_active
			  AND (lower(p.name) LIKE '%' || lower($2) || '%' OR lower(p.name_uz) LIKE '%' || lower($2) || '%'
			       OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $2))
		), stock AS (
			SELECT st.id AS store_id, b.product_id, sum(b.qty_remaining) AS qty
			FROM st JOIN batches b ON b.warehouse_id = st.wh AND b.qty_remaining > 0
			JOIN m ON m.id = b.product_id
			GROUP BY st.id, b.product_id
		), a AS (
			SELECT k.store_id, k.product_id,
			       k.qty - COALESCE((SELECT sum(r.qty) FROM stock_reservations r JOIN st ON st.wh = r.warehouse_id
			                         WHERE st.id = k.store_id AND r.product_id = k.product_id), 0) AS qty
			FROM stock k
		)
		SELECT a.store_id, p.id, loc(p.name, p.name_uz), loc(p.description, p.description_uz), br.name, p.category_id,
		       loc(u.short_name, u.short_name_uz), u.is_fractional, p.images,
		       p.created_at, a.qty::text,
		       COALESCE(sp.price, np.price, p.base_price) AS regular,
		       `+catalog.PromoPriceExpr("a.store_id")+` AS promo
		FROM a
		JOIN st ON st.id = a.store_id
		JOIN products p ON p.id = a.product_id
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN brands br ON br.id = p.brand_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = st.pt AND sp.store_id = st.id
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = st.pt AND np.store_id IS NULL
		WHERE a.qty > 0
		LIMIT 3000`, ids, q)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	items := map[string]*SearchItem{}
	order := []string{}
	seenStores := map[string]bool{}
	for rows.Next() {
		var (
			storeID   string
			pr        SearchProduct
			created   time.Time
			available string
			regular   string
			promo     *string
		)
		if err := rows.Scan(&storeID, &pr.ID, &pr.Name, &pr.Description, &pr.BrandName, &pr.CategoryID, &pr.UnitShort,
			&pr.IsFractional, &pr.Images, &created, &available, &regular, &promo); err != nil {
			return out, err
		}
		pr.IsNew = created.After(time.Now().Add(-30 * 24 * time.Hour))
		if pr.Images == nil {
			pr.Images = []string{}
		}
		st := stores[storeID]
		off := SearchOffer{StoreID: storeID, StoreName: st.name, NetworkName: st.network, Delivers: st.delivers,
			EtaMin: st.etaMin, EtaMax: st.etaMax, DistanceM: st.dist, IsOpen: st.open, Reason: st.reason,
			Price: money.D(regular).Money(), Available: available}
		if promo != nil && money.D(regular).Sign() > 0 && money.D(*promo).Cmp(money.D(regular)) < 0 {
			old := off.Price
			off.Price = money.D(*promo).Money()
			off.OldPrice = &old
			if pct, err := strconv.Atoi(money.D("1").Sub(money.D(*promo).Div(money.D(regular))).Mul(money.D("100")).Fixed(0)); err == nil {
				off.DiscountPercent = &pct
			}
		}
		it, ok := items[pr.ID]
		if !ok {
			it = &SearchItem{Product: pr}
			items[pr.ID] = it
			order = append(order, pr.ID)
		}
		it.Offers = append(it.Offers, off)
		seenStores[storeID] = true
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	lq := strings.ToLower(q)
	list := make([]*SearchItem, 0, len(order))
	for _, id := range order {
		it := items[id]
		sort.SliceStable(it.Offers, func(i, j int) bool { return offerLess(it.Offers[i], it.Offers[j]) })
		it.MinPrice = it.Offers[0].Price
		for _, o := range it.Offers[1:] {
			if money.D(o.Price).Cmp(money.D(it.MinPrice)) < 0 {
				it.MinPrice = o.Price
			}
		}
		list = append(list, it)
	}
	// Сначала товары, которые привезут; затем название начинается с запроса; больше магазинов; по алфавиту.
	sort.SliceStable(list, func(i, j int) bool {
		a, b := list[i], list[j]
		if a.Offers[0].Delivers != b.Offers[0].Delivers {
			return a.Offers[0].Delivers
		}
		ap, bp := strings.HasPrefix(strings.ToLower(a.Product.Name), lq), strings.HasPrefix(strings.ToLower(b.Product.Name), lq)
		if ap != bp {
			return ap
		}
		if len(a.Offers) != len(b.Offers) {
			return len(a.Offers) > len(b.Offers)
		}
		return a.Product.Name < b.Product.Name
	})
	if len(list) > limit {
		list = list[:limit]
	}
	for _, it := range list {
		out.Items = append(out.Items, *it)
	}
	out.Stores = len(seenStores)
	return out, nil
}

// offerLess: привезут → дешевле → ближе.
func offerLess(a, b SearchOffer) bool {
	if a.Delivers != b.Delivers {
		return a.Delivers
	}
	if c := money.D(a.Price).Cmp(money.D(b.Price)); c != 0 {
		return c < 0
	}
	return a.DistanceM < b.DistanceM
}
