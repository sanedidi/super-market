package start

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Каталог с галочками: дерево «категория → подкатегория → бренд → товар».
// Группы приходят одним списком (путь категории + бренд), товары группы —
// отдельным запросом. Галочка на группе добавляет или убирает все её товары.

// Товары каталога, которые магазин может завести: общий каталог и свои товары сети.
const catalogWhere = `p.is_active AND (p.network_id IS NULL OR p.network_id = $1)
	AND ($2 = '' OR lower(p.name) LIKE '%' || lower($2) || '%'
	     OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $2))`

const categoryPaths = `WITH RECURSIVE cp AS (
		SELECT id, ARRAY[id::text] AS ids, ARRAY[name] AS names FROM categories WHERE parent_id IS NULL
		UNION ALL
		SELECT c.id, cp.ids || c.id::text, cp.names || c.name FROM categories c JOIN cp ON c.parent_id = cp.id)`

type CatalogGroup struct {
	// Путь категории от корня до категории товаров (последняя — сама категория).
	CategoryIDs   []string `json:"category_ids"`
	CategoryNames []string `json:"category_names"`
	// BrandID — null: товары без бренда.
	BrandID   *string `json:"brand_id"`
	BrandName string  `json:"brand_name"`
	Count     int     `json:"count"`
	// Selected — сколько из них уже в черновике.
	Selected int `json:"selected"`
}

type Catalog struct {
	Groups   []CatalogGroup `json:"groups"`
	Total    int            `json:"total"`
	Selected int            `json:"selected"`
}

type CatalogItem struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	UnitShort    string  `json:"unit_short"`
	CurrentPrice string  `json:"current_price"`
	Barcode      *string `json:"barcode"`
	Own          bool    `json:"own"`
	Selected     bool    `json:"selected"`
}

type CatalogFilter struct {
	StoreID string
	Query   string
	// CategoryID — категория товаров (ровно она, без подкатегорий).
	CategoryID string
	// BrandID — uuid или "none".
	BrandID string
	Page    httpx.Page
}

func validBrand(b string) bool { return b == "" || b == "none" || httpx.IsUUID(b) }

// draftID — открытый черновик или пустая строка (выбранных товаров нет).
func (s *Service) draftID(ctx context.Context, q db.Querier, st store) (string, error) {
	id, _, err := openDraft(ctx, q, st.WarehouseID)
	if err != nil || id == nil {
		return "", err
	}
	return *id, nil
}

// Catalog — группы каталога со счётчиками «выбрано из».
func (s *Service) Catalog(ctx context.Context, p *identity.Principal, storeID, query string) (Catalog, error) {
	out := Catalog{Groups: []CatalogGroup{}}
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return out, err
	}
	draft, err := s.draftID(ctx, s.pool, st)
	if err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, categoryPaths+`
		SELECT cp.ids, cp.names, p.brand_id::text, b.name, count(*)::int, count(l.product_id)::int
		FROM products p
		JOIN cp ON cp.id = p.category_id
		LEFT JOIN brands b ON b.id = p.brand_id
		LEFT JOIN start_lines l ON l.draft_id::text = $3 AND l.product_id = p.id
		WHERE `+catalogWhere+`
		GROUP BY cp.ids, cp.names, p.brand_id, b.name
		ORDER BY cp.names, b.name IS NULL, lower(b.name), p.brand_id`,
		p.NetworkID, strings.TrimSpace(query), draft)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var g CatalogGroup
		var brand *string
		if err := rows.Scan(&g.CategoryIDs, &g.CategoryNames, &g.BrandID, &brand, &g.Count, &g.Selected); err != nil {
			return out, err
		}
		g.BrandName = "Без бренда"
		if brand != nil {
			g.BrandName = *brand
		}
		out.Total += g.Count
		out.Selected += g.Selected
		out.Groups = append(out.Groups, g)
	}
	return out, rows.Err()
}

// CatalogItems — товары одной группы (категория + бренд) по названию.
func (s *Service) CatalogItems(ctx context.Context, p *identity.Principal, f CatalogFilter) ([]CatalogItem, error) {
	if !httpx.IsUUID(f.CategoryID) {
		return nil, apperr.Validation("category_id: неверный id")
	}
	if !validBrand(f.BrandID) {
		return nil, apperr.Validation("brand_id: неверный id")
	}
	st, err := s.store(ctx, s.pool, p, f.StoreID)
	if err != nil {
		return nil, err
	}
	draft, err := s.draftID(ctx, s.pool, st)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, p.name, p.images[1], u.short_name, COALESCE(sp.price, np.price, p.base_price)::text,
		       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id),
		       p.network_id IS NOT NULL, l.product_id IS NOT NULL
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $5 AND sp.store_id = $6
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $5 AND np.store_id IS NULL
		LEFT JOIN start_lines l ON l.draft_id::text = $7 AND l.product_id = p.id
		WHERE `+catalogWhere+` AND p.category_id = $3
		  AND ($4 = '' OR ($4 = 'none' AND p.brand_id IS NULL) OR p.brand_id::text = $4)
		ORDER BY p.name, p.id LIMIT $8 OFFSET $9`,
		p.NetworkID, strings.TrimSpace(f.Query), f.CategoryID, f.BrandID, st.PriceTypeID, st.ID, draft, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (CatalogItem, error) {
		var it CatalogItem
		err := row.Scan(&it.ProductID, &it.Name, &it.Image, &it.UnitShort, &it.CurrentPrice, &it.Barcode, &it.Own, &it.Selected)
		return it, err
	})
}

type SelectInput struct {
	StoreID string `json:"store_id"`
	// CategoryID — категория со всеми подкатегориями; BrandID — бренд внутри неё ("none" — без бренда).
	CategoryID string `json:"category_id"`
	BrandID    string `json:"brand_id"`
	// Exact — только сама категория, без подкатегорий (группа «категория + бренд» в дереве).
	Exact    bool   `json:"exact"`
	Query    string `json:"q"`
	Selected bool   `json:"selected"`
}

type SelectResult struct {
	Changed int    `json:"changed"`
	Totals  Totals `json:"totals"`
}

// Сколько товаров можно добавить одной галочкой.
const selectMax = 2000

// Select — отметить или снять группу каталога целиком. Новые строки — по 1 шт.
func (s *Service) Select(ctx context.Context, p *identity.Principal, in SelectInput) (SelectResult, error) {
	var out SelectResult
	if in.CategoryID == "" && in.BrandID == "" {
		return out, apperr.Validation("укажите category_id или brand_id")
	}
	if in.CategoryID != "" && !httpx.IsUUID(in.CategoryID) {
		return out, apperr.Validation("category_id: неверный id")
	}
	if !validBrand(in.BrandID) {
		return out, apperr.Validation("brand_id: неверный id")
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		st, err := s.store(ctx, tx, p, in.StoreID)
		if err != nil {
			return err
		}
		var draft string
		if in.Selected {
			if draft, err = s.ensureDraft(ctx, tx, p, st); err != nil {
				return err
			}
		} else {
			id, status, err := openDraft(ctx, tx, st.WarehouseID)
			if err != nil {
				return err
			}
			if id == nil {
				out.Totals = Totals{Qty: "0", CostTotal: "0.00", PriceTotal: "0.00"}
				return nil
			}
			if status == StatusPosting {
				return apperr.Conflict("draft_posting", "черновик сейчас проводится")
			}
			draft = *id
		}
		match := `SELECT p.id FROM products p WHERE ` + catalogWhere + `
			AND ($3 = '' OR ($5 AND p.category_id::text = $3) OR (NOT $5 AND p.category_id IN (
			        WITH RECURSIVE sub AS (
			            SELECT id FROM categories WHERE id::text = $3
			            UNION SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id)
			        SELECT id FROM sub)))
			AND ($4 = '' OR ($4 = 'none' AND p.brand_id IS NULL) OR p.brand_id::text = $4)`
		args := []any{p.NetworkID, strings.TrimSpace(in.Query), in.CategoryID, in.BrandID, in.Exact, draft}
		if in.Selected {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM (`+match+`) m
				WHERE NOT EXISTS (SELECT 1 FROM start_lines l WHERE l.draft_id = $6 AND l.product_id = m.id)`, args...).Scan(&n); err != nil {
				return err
			}
			if n > selectMax {
				return apperr.Validation("в разделе слишком много товаров — откройте его и отметьте подразделы")
			}
			tag, err := tx.Exec(ctx, `
				INSERT INTO start_lines (draft_id, product_id, qty, source, added_by)
				SELECT $6, m.id, 1, 'catalog', $7 FROM (`+match+`) m
				ON CONFLICT (draft_id, product_id) DO NOTHING`, append(args, p.EmployeeID)...)
			if err != nil {
				return err
			}
			out.Changed = int(tag.RowsAffected())
		} else {
			tag, err := tx.Exec(ctx, `DELETE FROM start_lines WHERE draft_id = $6 AND product_id IN (`+match+`)`, args...)
			if err != nil {
				return err
			}
			out.Changed = int(tag.RowsAffected())
		}
		out.Totals, err = s.totals(ctx, tx, draft, st)
		return err
	})
	return out, err
}
