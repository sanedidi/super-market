package catalog

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// Дерево «бренд → категория» для списка товаров в панелях: сколько товаров
// в каждой группе с учётом поиска и фильтров. Сами товары группы — обычным
// списком с brand_id и leaf_category_id.

type GroupCategory struct {
	CategoryID   string `json:"category_id"`
	CategoryName string `json:"category_name"`
	Count        int    `json:"count"`
	// Pending — на модерации (у магазина — свои товары сети).
	Pending int `json:"pending"`
}

type GroupBrand struct {
	// BrandID — null: товары без бренда (в списке товаров — brand_id=none).
	BrandID    *string         `json:"brand_id"`
	BrandName  string          `json:"brand_name"`
	Count      int             `json:"count"`
	Pending    int             `json:"pending"`
	Categories []GroupCategory `json:"categories"`
}

type ProductGroups struct {
	// Brands — страница брендов (limit/offset), если клиент передал limit;
	// без limit — все бренды, как раньше.
	Brands []GroupBrand `json:"brands"`
	// BrandsTotal — сколько всего брендов под фильтром (для пагинации).
	BrandsTotal int `json:"brands_total"`
	// Total — товаров под фильтром во всех брендах, не только на странице.
	Total int `json:"total"`
}

func collectGroups(ctx context.Context, rows pgx.Rows) (ProductGroups, error) {
	defer rows.Close()
	g := ProductGroups{Brands: []GroupBrand{}}
	for rows.Next() {
		var (
			brandID *string
			brand   *string
			c       GroupCategory
		)
		if err := rows.Scan(&brandID, &brand, &c.CategoryID, &c.CategoryName, &c.Count, &c.Pending); err != nil {
			return g, err
		}
		n := len(g.Brands)
		same := n > 0 && ((g.Brands[n-1].BrandID == nil && brandID == nil) ||
			(g.Brands[n-1].BrandID != nil && brandID != nil && *g.Brands[n-1].BrandID == *brandID))
		if !same {
			name := i18n.T(ctx, "Без бренда", "Brendsiz")
			if brand != nil {
				name = *brand
			}
			g.Brands = append(g.Brands, GroupBrand{BrandID: brandID, BrandName: name, Categories: []GroupCategory{}})
			n++
		}
		b := &g.Brands[n-1]
		b.Categories = append(b.Categories, c)
		b.Count += c.Count
		b.Pending += c.Pending
		g.Total += c.Count
	}
	g.BrandsTotal = len(g.Brands)
	return g, rows.Err()
}

// Бренды по алфавиту, «Без бренда» — в конце; категории внутри — по алфавиту.
const groupSelect = `SELECT p.brand_id, b.name, p.category_id, loc(c.name, c.name_uz), count(*)::int, %s
	FROM products p
	LEFT JOIN brands b ON b.id = p.brand_id
	JOIN categories c  ON c.id = p.category_id`

const groupOrder = `
	GROUP BY p.brand_id, b.name, p.category_id, c.name, c.name_uz
	ORDER BY b.name IS NULL, lower(b.name), p.brand_id, lower(loc(c.name, c.name_uz)), p.category_id`

func (s *Service) AdminProductGroups(ctx context.Context, f ProductFilter) (ProductGroups, error) {
	if err := f.validate(); err != nil {
		return ProductGroups{}, err
	}
	args := []any{strings.TrimSpace(f.Query), f.CategoryID, f.Barcode, f.Status, f.Photo}
	search, err := s.searchWhere(ctx, f.Query, productsearch.Scope{AllNetworks: true, Inactive: true}, &args)
	if err != nil {
		return ProductGroups{}, err
	}
	rows, err := s.pool.Query(ctx, strings.Replace(groupSelect, "%s", `(count(*) FILTER (WHERE p.moderation_status = 'pending'))::int`, 1)+`
		WHERE ($4 = '' OR p.moderation_status = $4)`+filterWhere(search)+`
		AND ($5 = '' OR ($5 = 'with') = (cardinality(p.images) > 0))`+groupOrder, productsearch.Args(args)...)
	if err != nil {
		return ProductGroups{}, err
	}
	return collectGroups(ctx, rows)
}

func (s *Service) StoreProductGroups(ctx context.Context, pr *identity.Principal, f ProductFilter) (ProductGroups, error) {
	if err := f.validate(); err != nil {
		return ProductGroups{}, err
	}
	if f.StoreID != "" {
		if err := s.checkStore(ctx, pr, f.StoreID); err != nil {
			return ProductGroups{}, err
		}
	}
	args := []any{strings.TrimSpace(f.Query), f.CategoryID, f.Barcode, pr.NetworkID, f.mineArg(f.StoreID)}
	search, err := s.searchWhere(ctx, f.Query, productsearch.Scope{NetworkID: pr.NetworkID, Inactive: true}, &args)
	if err != nil {
		return ProductGroups{}, err
	}
	rows, err := s.pool.Query(ctx, strings.Replace(groupSelect, "%s", `(count(*) FILTER (WHERE p.network_id IS NOT NULL AND p.moderation_status = 'pending'))::int`, 1)+`
		WHERE (p.network_id IS NULL OR p.network_id = $4)`+filterWhere(search)+mineWhere(5, 4)+groupOrder, productsearch.Args(args)...)
	if err != nil {
		return ProductGroups{}, err
	}
	return collectGroups(ctx, rows)
}

func adminOrder(sort string) string {
	if sort == "name" {
		return "p.name, p.id"
	}
	return "p.created_at DESC, p.id"
}
