package start

// Подсчёт остатков потом (Figma «начало работы v5», Н-W5 / Н5, Н6): товары
// «Остаток не посчитан» после «Только товары и цены» или «Остальное посчитаю
// потом». Магазин досчитывает их по одному — с главной (сначала товары в
// минусе и самые продаваемые), по одной полке (категории) или в приходе
// («Сколько сейчас на полке?»). Подсчёт — обычная инвентаризация основного
// склада: проведённая инвентаризация снимает пометку (inventory.Post).

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// CountSummary — карточка «Посчитано N из M» на главной.
type CountSummary struct {
	// Products — товаров в магазине («Мои товары», активные).
	Products int `json:"products"`
	// Uncounted — с пометкой «Остаток не посчитан».
	Uncounted int `json:"uncounted"`
	Counted   int `json:"counted"`
	// Negative — посчитанных товаров, которые ушли в минус: после подсчёта
	// на кассе продали больше, чем было (за 30 дней).
	Negative int `json:"negative"`
	// Percent — посчитано, % (целое, вниз; 100 — только когда всё посчитано).
	Percent int `json:"percent"`
}

// shortSQL — сколько товара $p продали в магазине $s сверх остатка после
// подсчёта (за 30 дней); sp — строка store_products.
func shortSQL(store, product string) string {
	return fmt.Sprintf(`COALESCE((SELECT sum(i.short_qty) FROM sales x JOIN sale_items i ON i.sale_id = x.id
		WHERE x.store_id = %[1]s AND i.product_id = %[2]s AND i.short_qty > 0
		  AND x.sold_at > GREATEST(now() - interval '30 days', COALESCE(sp.counted_at, '-infinity'::timestamptz))), 0)`, store, product)
}

// CountSummary — сколько товаров магазина посчитано.
func (s *Service) CountSummary(ctx context.Context, p *identity.Principal, storeID string) (CountSummary, error) {
	if _, err := s.store(ctx, s.pool, p, storeID); err != nil {
		return CountSummary{}, err
	}
	var c CountSummary
	err := s.pool.QueryRow(ctx, `
		SELECT count(*)::int, (count(*) FILTER (WHERE sp.uncounted_since IS NOT NULL))::int,
		       (count(*) FILTER (WHERE sp.uncounted_since IS NULL AND `+shortSQL("sp.store_id", "sp.product_id")+` > 0))::int
		FROM store_products sp
		JOIN products pr ON pr.id = sp.product_id AND pr.is_active
		JOIN stores st ON st.id = sp.store_id AND st.network_id = $2
		WHERE sp.store_id = $1`, storeID, p.NetworkID).Scan(&c.Products, &c.Uncounted, &c.Negative)
	if err != nil {
		return c, err
	}
	c.Counted = c.Products - c.Uncounted
	c.Percent = 100
	if c.Products > 0 && c.Uncounted > 0 {
		c.Percent = c.Counted * 100 / c.Products
	}
	return c, nil
}

// CountItem — товар в списке «Посчитать».
type CountItem struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	UnitShort    string  `json:"unit_short"`
	IsFractional bool    `json:"is_fractional"`
	Barcode      *string `json:"barcode"`
	Category     string  `json:"category"`
	// Stock — остаток по учёту на основном складе (у непосчитанного — то,
	// что пришло приходами после старта).
	Stock     string `json:"stock"`
	Uncounted bool   `json:"uncounted"`
	// Sold30 — продано за 30 дней; Short — продано сверх остатка после подсчёта.
	Sold30 string `json:"sold_30d"`
	Short  string `json:"short"`
}

// CountFilter — какой список: top — самые продаваемые непосчитанные,
// negative — ушли в минус, uncounted — все непосчитанные (по категории,
// поиску), product — один товар (ProductID). ProductIDs — только эти товары
// (непосчитанные из прихода: «Сколько сейчас на полке?»).
type CountFilter struct {
	Set        string
	CategoryID string
	ProductID  string
	ProductIDs []string
	Query      string
	Limit      int
	Offset     int
}

type CountItems struct {
	Items []CountItem `json:"items"`
	Total int         `json:"total"`
}

// CountItems — товары, которые пора посчитать.
func (s *Service) CountItems(ctx context.Context, p *identity.Principal, storeID string, f CountFilter) (CountItems, error) {
	out := CountItems{Items: []CountItem{}}
	st, err := s.store(ctx, s.pool, p, storeID)
	if err != nil {
		return out, err
	}
	args := []any{st.ID, st.WarehouseID}
	short := shortSQL("sp.store_id", "sp.product_id")
	// $2 (склад) нужен только в списке — в счётчике тоже упомянут, чтобы
	// Postgres знал его тип.
	where := ` WHERE sp.store_id = $1 AND $2::uuid IS NOT NULL AND pr.is_active`
	order := `loc(pr.name, pr.name_uz), pr.id`
	switch f.Set {
	case "", "uncounted":
		where += ` AND sp.uncounted_since IS NOT NULL`
	case "top":
		where += ` AND sp.uncounted_since IS NOT NULL`
		order = `t.sold_qty DESC, loc(pr.name, pr.name_uz), pr.id`
	case "negative":
		where += ` AND sp.uncounted_since IS NULL AND ` + short + ` > 0`
		order = `t.short_qty DESC, loc(pr.name, pr.name_uz), pr.id`
	case "product":
		if !httpx.IsUUID(f.ProductID) {
			return out, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
		}
		args = append(args, f.ProductID)
		where += fmt.Sprintf(` AND sp.product_id = $%d`, len(args))
	default:
		return out, apperr.Validation("set: top, negative, uncounted или product").Uz("set: top, negative, uncounted yoki product")
	}
	if len(f.ProductIDs) > 0 {
		if len(f.ProductIDs) > 500 {
			return out, apperr.Validation("product_ids: не больше 500").Uz("product_ids: 500 tadan koʻp emas")
		}
		for _, id := range f.ProductIDs {
			if !httpx.IsUUID(id) {
				return out, apperr.Validation("product_ids: товар не найден").Uz("product_ids: mahsulot topilmadi")
			}
		}
		args = append(args, f.ProductIDs)
		where += fmt.Sprintf(` AND sp.product_id = ANY($%d::uuid[])`, len(args))
	}
	if f.CategoryID != "" {
		if !httpx.IsUUID(f.CategoryID) {
			return out, apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
		}
		args = append(args, f.CategoryID)
		where += fmt.Sprintf(` AND pr.category_id = $%d`, len(args))
	}
	if strings.TrimSpace(f.Query) != "" {
		where += ` AND ` + productsearch.Filter("pr", f.Query, &args)
	}
	limit := f.Limit
	if limit <= 0 {
		limit = 50
	}
	from := `
		FROM store_products sp
		JOIN products pr ON pr.id = sp.product_id
		JOIN units u ON u.id = pr.unit_id
		JOIN categories c ON c.id = pr.category_id` + where
	if err := s.pool.QueryRow(ctx, `SELECT count(*)::int`+from, productsearch.Args(args)...).Scan(&out.Total); err != nil {
		return out, err
	}
	order = strings.NewReplacer("loc(pr.name, pr.name_uz)", "t.name", "pr.id", "t.id").Replace(order)
	rows, err := s.pool.Query(ctx, `
		SELECT t.id, t.name, t.image, t.unit, t.fractional, t.barcode, t.category, t.stock, t.uncounted,
		       trim_scale(t.sold_qty)::text, trim_scale(t.short_qty)::text
		FROM (
			SELECT pr.id, loc(pr.name, pr.name_uz) AS name, pr.images[1] AS image, loc(u.short_name, u.short_name_uz) AS unit,
			       u.is_fractional AS fractional,
			       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = pr.id) AS barcode,
			       loc(c.name, c.name_uz) AS category,
			       trim_scale(COALESCE((SELECT sum(b.qty_remaining) FROM batches b WHERE b.warehouse_id = $2 AND b.product_id = pr.id), 0))::text AS stock,
			       sp.uncounted_since IS NOT NULL AS uncounted,
			       COALESCE((SELECT sum(i.qty) FROM sales x JOIN sale_items i ON i.sale_id = x.id
			                 WHERE x.store_id = $1 AND i.product_id = pr.id AND x.sold_at > now() - interval '30 days'), 0)::numeric AS sold_qty,
			       (`+short+`)::numeric AS short_qty`+from+`
		) t ORDER BY `+order+fmt.Sprintf(` LIMIT %d OFFSET %d`, min(limit, 200), max(f.Offset, 0)), productsearch.Args(args)...)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (CountItem, error) {
		var it CountItem
		err := r.Scan(&it.ProductID, &it.Name, &it.Image, &it.UnitShort, &it.IsFractional, &it.Barcode, &it.Category,
			&it.Stock, &it.Uncounted, &it.Sold30, &it.Short)
		return it, err
	})
	return out, err
}

// CountCategory — полка (категория) с непосчитанными товарами.
type CountCategory struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Section   string `json:"section"`
	Uncounted int    `json:"uncounted"`
	Products  int    `json:"products"`
}

// CountCategories — категории, где есть непосчитанные товары, по убыванию.
func (s *Service) CountCategories(ctx context.Context, p *identity.Principal, storeID string) ([]CountCategory, error) {
	if _, err := s.store(ctx, s.pool, p, storeID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT c.id, loc(c.name, c.name_uz), COALESCE(loc(pc.name, pc.name_uz), ''),
		       (count(*) FILTER (WHERE sp.uncounted_since IS NOT NULL))::int, count(*)::int
		FROM store_products sp
		JOIN stores st ON st.id = sp.store_id AND st.network_id = $2
		JOIN products pr ON pr.id = sp.product_id AND pr.is_active
		JOIN categories c ON c.id = pr.category_id
		LEFT JOIN categories pc ON pc.id = c.parent_id
		WHERE sp.store_id = $1
		GROUP BY c.id, pc.id
		HAVING count(*) FILTER (WHERE sp.uncounted_since IS NOT NULL) > 0
		ORDER BY 4 DESC, 2`, storeID, p.NetworkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (CountCategory, error) {
		var c CountCategory
		err := r.Scan(&c.ID, &c.Name, &c.Section, &c.Uncounted, &c.Products)
		return c, err
	})
}

// CountInput — посчитанные товары: сколько сейчас на полке.
type CountInput struct {
	StoreID string `json:"store_id"`
	Items   []struct {
		ProductID string    `json:"product_id"`
		Qty       money.Qty `json:"qty"`
	} `json:"items"`
}

type CountResult struct {
	Document DocRef       `json:"document"`
	Counted  int          `json:"counted"`
	Summary  CountSummary `json:"summary"`
}

// Count — записать подсчёт: инвентаризация основного склада по этим товарам
// (излишек — оприходование, недостача — списание), пометка «Остаток не
// посчитан» снимается.
func (s *Service) Count(ctx context.Context, p *identity.Principal, in CountInput) (CountResult, error) {
	var res CountResult
	if len(in.Items) == 0 || len(in.Items) > 500 {
		return res, apperr.Validation("items: от 1 до 500 товаров").Uz("items: 1 dan 500 tagacha mahsulot")
	}
	st, err := s.store(ctx, s.pool, p, in.StoreID)
	if err != nil {
		return res, err
	}
	items := make([]inventory.ItemInput, 0, len(in.Items))
	for i, it := range in.Items {
		if !it.Qty.Valid() || money.D(string(it.Qty)).Sign() < 0 {
			return res, apperr.Validation(fmt.Sprintf("items: неверное количество (товар %d)", i+1)).Uz(fmt.Sprintf("items: miqdor notoʻgʻri (%d-mahsulot)", i+1))
		}
		items = append(items, inventory.ItemInput{ProductID: it.ProductID, Qty: it.Qty})
	}
	note := "Подсчёт остатков"
	wh := st.WarehouseID
	doc, err := s.inv.Create(ctx, p, inventory.Input{Type: inventory.TypeInventory, WarehouseID: &wh, Note: &note, Items: &items})
	if err != nil {
		return res, err
	}
	if _, err := s.inv.Post(ctx, p, doc.ID); err != nil {
		_ = s.inv.Delete(context.WithoutCancel(ctx), p, doc.ID)
		return res, err
	}
	res.Document = DocRef{ID: doc.ID, Number: doc.Number}
	res.Counted = len(items)
	res.Summary, err = s.CountSummary(ctx, p, st.ID)
	return res, err
}
