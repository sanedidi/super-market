package orders

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Витрина приложения: каталог магазина с акциями, сортировками и
// фильтрами, карточка товара, «С этим покупают», главная, избранное.

type CatalogProduct struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	Description     string    `json:"description"`
	BrandName       *string   `json:"brand_name"`
	CategoryID      string    `json:"category_id"`
	UnitShort       string    `json:"unit_short"`
	IsFractional    bool      `json:"is_fractional"`
	Images          []string  `json:"images"`
	Price           string    `json:"price"`
	Available       string    `json:"available"`
	OldPrice        *string   `json:"old_price"`        // цена до скидки, если действует акция
	DiscountPercent *int      `json:"discount_percent"` // округлённый процент скидки
	IsNew           bool      `json:"is_new"`           // в каталоге меньше 30 дней
	CreatedAt       time.Time `json:"-"`
}

// catalogBase — товары приложения в магазине $1 (склад $2, тип цены $3):
// общий каталог, активные, с остатком за вычетом резервов; обычная цена,
// акционная цена и популярность за 30 дней.
var catalogBase = `
	WITH stock AS (
		SELECT b.product_id, sum(b.qty_remaining) AS qty FROM batches b
		WHERE b.warehouse_id = $2 AND b.qty_remaining > 0 GROUP BY b.product_id
	), reserved AS (
		SELECT product_id, sum(qty) AS qty FROM stock_reservations WHERE warehouse_id = $2 GROUP BY product_id
	)
	SELECT p.id, loc(p.name, p.name_uz) AS name, loc(p.description, p.description_uz) AS description,
	       br.name AS brand_name, p.brand_id, p.category_id,
	       loc(u.short_name, u.short_name_uz) AS short_name, u.is_fractional, p.images, p.created_at, p.attributes,
	       p.name AS name_ru, p.name_uz,
	       COALESCE(sp.price, np.price, p.base_price) AS regular,
	       ` + catalog.PromoPriceExpr("$1") + ` AS promo,
	       st.qty - COALESCE(r.qty, 0) AS available,
	       COALESCE(pop.qty, 0) AS pop_qty, COALESCE(pop.purchases, 0) AS purchases
	FROM products p
	JOIN stock st ON st.product_id = p.id
	LEFT JOIN reserved r ON r.product_id = p.id
	JOIN units u ON u.id = p.unit_id
	LEFT JOIN brands br ON br.id = p.brand_id
	LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $1
	LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL
	LEFT JOIN product_popularity pop ON pop.store_id = $1 AND pop.product_id = p.id
	WHERE p.network_id IS NULL AND p.is_active AND st.qty - COALESCE(r.qty, 0) > 0`

// catalogCols — поля CatalogProduct из строки c (результат catalogBase).
const catalogCols = `
	c.id, c.name, c.description, c.brand_name, c.category_id, c.short_name, c.is_fractional, c.images,
	(CASE WHEN c.promo < c.regular THEN c.promo ELSE c.regular END)::text,
	c.available::text,
	CASE WHEN c.promo < c.regular THEN c.regular::text END,
	CASE WHEN c.promo < c.regular THEN round((1 - c.promo / NULLIF(c.regular, 0)) * 100)::int END,
	c.created_at > now() - interval '30 days',
	c.created_at`

// hitPurchases — сколько покупок за 30 дней делает товар «хитом».
const hitPurchases = 3

// CatalogFilter — параметры списка товаров магазина.
type CatalogFilter struct {
	Query      string
	CategoryID string
	BrandID    string
	IDs        []string
	Discount   bool   // только со скидкой
	New        bool   // новинки (меньше 30 дней)
	Hits       bool   // хиты продаж
	Sort       string // popular (по умолчанию) | price_asc | price_desc | new | name
}

var catalogSorts = map[string]string{
	"popular":    `c.pop_qty DESC, c.purchases DESC, c.name`,
	"price_asc":  `LEAST(c.regular, COALESCE(c.promo, c.regular)), c.name`,
	"price_desc": `LEAST(c.regular, COALESCE(c.promo, c.regular)) DESC, c.name`,
	"new":        `c.created_at DESC, c.name`,
	"name":       `c.name`,
	"discount":   `(1 - COALESCE(c.promo, c.regular) / NULLIF(c.regular, 0)) DESC, c.pop_qty DESC, c.name`,
}

func (s *Service) StoreCatalog(ctx context.Context, storeID string, f CatalogFilter, page httpx.Page) ([]CatalogProduct, error) {
	st, err := s.storeForBrowse(ctx, s.pool, storeID)
	if err != nil {
		return nil, err
	}
	for _, id := range append([]string{f.CategoryID, f.BrandID}, f.IDs...) {
		if id != "" && !httpx.IsUUID(id) {
			return nil, apperr.Validation("неверный id в фильтре").Uz("filtrda id notoʻgʻri")
		}
	}
	order, ok := catalogSorts[f.Sort]
	if f.Sort == "" {
		order, ok = catalogSorts["popular"], true
	}
	if !ok {
		return nil, apperr.Validation("sort: popular, price_asc, price_desc, new, name или discount").Uz("sort: popular, price_asc, price_desc, new, name yoki discount")
	}
	ids := f.IDs
	if ids == nil {
		ids = []string{}
	}
	rows, err := s.pool.Query(ctx, `SELECT `+catalogCols+` FROM (`+catalogBase+`) c
		WHERE ($4 = '' OR lower(c.name_ru) LIKE '%' || lower($4) || '%' OR lower(c.name_uz) LIKE '%' || lower($4) || '%')
		  AND ($5 = '' OR c.category_id IN (
			WITH RECURSIVE sub AS (SELECT id FROM categories WHERE id::text = $5
			                       UNION SELECT cc.id FROM categories cc JOIN sub ON cc.parent_id = sub.id)
			SELECT id FROM sub))
		  AND ($6 = '' OR c.brand_id::text = $6)
		  AND (cardinality($7::uuid[]) = 0 OR c.id = ANY ($7::uuid[]))
		  AND (NOT $8 OR c.promo < c.regular)
		  AND (NOT $9 OR c.created_at > now() - interval '30 days')
		  AND (NOT $10 OR c.purchases >= `+strconv.Itoa(hitPurchases)+`)
		ORDER BY `+order+` LIMIT $11 OFFSET $12`,
		storeID, st.WarehouseID, st.PriceTypeID, strings.TrimSpace(f.Query), f.CategoryID, f.BrandID, ids,
		f.Discount, f.New, f.Hits, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogProduct])
}

type CatalogCategory struct {
	ID       string  `json:"id"`
	ParentID *string `json:"parent_id"`
	Name     string  `json:"name"`
	Count    int     `json:"products_count"`
	ImageURL string  `json:"image_url"`
}

// StoreCategories — категории, в которых у магазина есть товары в наличии.
func (s *Service) StoreCategories(ctx context.Context, storeID string) ([]CatalogCategory, error) {
	st, err := s.storeForBrowse(ctx, s.pool, storeID)
	if err != nil {
		return nil, err
	}
	// Категории с товарами и все их родители (разделы каталога), count —
	// товары прямо в категории.
	rows, err := s.pool.Query(ctx, `
		WITH RECURSIVE direct AS (
			SELECT i.category_id AS id, count(*)::int AS n FROM (`+catalogBase+`) i GROUP BY i.category_id
		), tree AS (
			SELECT c.id FROM categories c JOIN direct d ON d.id = c.id WHERE c.is_active
			UNION SELECT p.id FROM categories p JOIN categories ch ON ch.parent_id = p.id JOIN tree t ON t.id = ch.id
			WHERE p.is_active
		)
		SELECT cat.id, cat.parent_id, loc(cat.name, cat.name_uz), COALESCE(d.n, 0), cat.image_url
		FROM categories cat JOIN (SELECT DISTINCT id FROM tree) t ON t.id = cat.id
		LEFT JOIN direct d ON d.id = cat.id
		ORDER BY cat.sort, loc(cat.name, cat.name_uz)`,
		storeID, st.WarehouseID, st.PriceTypeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogCategory])
}

// ProductDetail — карточка товара: всё из каталога плюс характеристики.
type ProductDetail struct {
	CatalogProduct
	CategoryName string         `json:"category_name"`
	Attributes   map[string]any `json:"attributes"`
	StoreID      string         `json:"store_id"`
	StoreName    string         `json:"store_name"`
}

func (s *Service) StoreProduct(ctx context.Context, storeID, productID string) (ProductDetail, error) {
	var out ProductDetail
	st, err := s.storeForBrowse(ctx, s.pool, storeID)
	if err != nil {
		return out, err
	}
	if !httpx.IsUUID(productID) {
		return out, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	row := s.pool.QueryRow(ctx, `SELECT `+catalogCols+`, loc(cat.name, cat.name_uz), c.attributes FROM (`+catalogBase+`) c
		JOIN categories cat ON cat.id = c.category_id WHERE c.id = $4`,
		storeID, st.WarehouseID, st.PriceTypeID, productID)
	p := &out.CatalogProduct
	err = row.Scan(&p.ID, &p.Name, &p.Description, &p.BrandName, &p.CategoryID, &p.UnitShort, &p.IsFractional, &p.Images,
		&p.Price, &p.Available, &p.OldPrice, &p.DiscountPercent, &p.IsNew, &p.CreatedAt, &out.CategoryName, &out.Attributes)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("товара нет в наличии в этом магазине").Uz("mahsulot bu doʻkonda mavjud emas")
	}
	out.StoreID, out.StoreName = storeID, st.Name
	return out, err
}

// RelatedProducts — «С этим покупают»: что чаще всего брали вместе с товаром
// в этом магазине за 90 дней (онлайн и на кассе); не хватает — популярное из
// той же категории.
func (s *Service) RelatedProducts(ctx context.Context, storeID, productID string, limit int) ([]CatalogProduct, error) {
	st, err := s.storeForBrowse(ctx, s.pool, storeID)
	if err != nil {
		return nil, err
	}
	if !httpx.IsUUID(productID) {
		return nil, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if limit <= 0 || limit > 30 {
		limit = 10
	}
	rows, err := s.pool.Query(ctx, `SELECT `+catalogCols+` FROM (`+catalogBase+`) c
		JOIN (
			SELECT product_id, sum(n) AS n FROM (
				SELECT oi2.product_id, count(*) AS n
				FROM order_items oi1
				JOIN orders o ON o.id = oi1.order_id AND o.store_id = $1 AND o.created_at > now() - interval '90 days'
				JOIN order_items oi2 ON oi2.order_id = oi1.order_id AND oi2.product_id <> oi1.product_id
				WHERE oi1.product_id = $4 GROUP BY 1
				UNION ALL
				SELECT si2.product_id, count(*)
				FROM sale_items si1
				JOIN sales sa ON sa.id = si1.sale_id AND sa.store_id = $1 AND sa.sold_at > now() - interval '90 days'
				JOIN sale_items si2 ON si2.sale_id = si1.sale_id AND si2.product_id <> si1.product_id
				WHERE si1.product_id = $4 GROUP BY 1
			) x GROUP BY 1
		) co ON co.product_id = c.id
		ORDER BY co.n DESC, c.pop_qty DESC LIMIT $5`,
		storeID, st.WarehouseID, st.PriceTypeID, productID, limit)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogProduct])
	if err != nil || len(items) >= limit {
		return items, err
	}
	exclude := []string{productID}
	for _, it := range items {
		exclude = append(exclude, it.ID)
	}
	rows, err = s.pool.Query(ctx, `SELECT `+catalogCols+` FROM (`+catalogBase+`) c
		WHERE c.category_id = (SELECT category_id FROM products WHERE id = $4) AND NOT (c.id = ANY ($5::uuid[]))
		ORDER BY c.pop_qty DESC, c.name LIMIT $6`,
		storeID, st.WarehouseID, st.PriceTypeID, productID, exclude, limit-len(items))
	if err != nil {
		return nil, err
	}
	more, err := pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogProduct])
	return append(items, more...), err
}

// Home — главная приложения одним запросом.
type Home struct {
	Banners []catalog.Banner       `json:"banners"`
	Stores  []delivery.NearbyStore `json:"stores"`
	// Others — магазины до 10 км, которые по адресу не доставляют: товары можно
	// посмотреть, заказать нельзя, можно нажать «Хочу доставку».
	Others []delivery.OtherStore `json:"others"`
	Deals  *Deals                `json:"deals"`
}

// Deals — «Скидки недели» из ближайшего открытого магазина.
type Deals struct {
	StoreID   string           `json:"store_id"`
	StoreName string           `json:"store_name"`
	Items     []CatalogProduct `json:"items"`
}

func (s *Service) Home(ctx context.Context, lat, lng float64) (Home, error) {
	out := Home{Banners: []catalog.Banner{}, Stores: []delivery.NearbyStore{}, Others: []delivery.OtherStore{}}
	stores, err := s.delivery.Nearby(ctx, lat, lng)
	if err != nil {
		return out, err
	}
	out.Stores = stores
	ids := make([]string, len(stores))
	for i, st := range stores {
		ids[i] = st.ID
	}
	if out.Others, err = s.delivery.Others(ctx, lat, lng, ids); err != nil {
		return out, err
	}
	networks := []string{}
	for _, st := range stores {
		networks = append(networks, st.NetworkID)
	}
	if out.Banners, err = catalog.ActiveBanners(ctx, s.pool, networks); err != nil {
		return out, err
	}
	for _, st := range stores {
		if !st.Quote.IsOpen {
			continue
		}
		items, err := s.StoreCatalog(ctx, st.ID, CatalogFilter{Discount: true, Sort: "discount"}, httpx.Page{Limit: 10})
		if err != nil {
			return out, err
		}
		if len(items) > 0 {
			out.Deals = &Deals{StoreID: st.ID, StoreName: st.Name, Items: items}
			break
		}
	}
	return out, nil
}

// ------------------------------------------------------------- избранное

func (s *Service) FavoriteIDs(ctx context.Context, p *identity.Principal) ([]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT product_id::text FROM favorites WHERE user_id = $1 ORDER BY created_at DESC LIMIT 500`, p.UserID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

func (s *Service) AddFavorite(ctx context.Context, p *identity.Principal, productID string) error {
	if !httpx.IsUUID(productID) {
		return apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM favorites WHERE user_id = $1`, p.UserID).Scan(&n); err != nil {
		return err
	}
	if n >= 500 {
		return apperr.Validation("в избранном не больше 500 товаров").Uz("sevimlilarda koʻpi bilan 500 ta mahsulot")
	}
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO favorites (user_id, product_id)
		SELECT $1, id FROM products WHERE id = $2 AND network_id IS NULL AND is_active
		ON CONFLICT DO NOTHING`, p.UserID, productID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM favorites WHERE user_id = $1 AND product_id = $2)`,
			p.UserID, productID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
		}
	}
	return nil
}

func (s *Service) RemoveFavorite(ctx context.Context, p *identity.Principal, productID string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM favorites WHERE user_id = $1 AND product_id::text = $2`, p.UserID, productID)
	return err
}

// ----------------------------------------------------------- популярность

// RefreshPopularity пересчитывает популярность товаров за 30 дней не чаще
// раза в час (задача воркера).
func (s *Service) RefreshPopularity(ctx context.Context) error {
	var fresh bool
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(max(updated_at) > now() - interval '1 hour', false) FROM product_popularity`).
		Scan(&fresh); err != nil {
		return err
	}
	if fresh {
		return nil
	}
	return s.refreshPopularity(ctx)
}

func (s *Service) refreshPopularity(ctx context.Context) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `DELETE FROM product_popularity`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO product_popularity (store_id, product_id, qty, purchases)
		SELECT store_id, product_id, sum(qty), count(*)::int FROM (
			SELECT sa.store_id, si.product_id, si.qty
			FROM sale_items si JOIN sales sa ON sa.id = si.sale_id
			WHERE sa.sold_at > now() - interval '30 days'
			UNION ALL
			SELECT o.store_id, oi.product_id, oi.qty
			FROM order_items oi JOIN orders o ON o.id = oi.order_id
			WHERE o.created_at > now() - interval '30 days'
			  AND o.status NOT IN ('awaiting_payment', 'cancelled', 'expired')
		) x GROUP BY store_id, product_id`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
