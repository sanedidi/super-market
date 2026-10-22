package inventory

// «Мои товары и остатки» (Figma «SM Магазин · Мои товары и остатки», О2–О4):
// все товары магазина (store_products) с остатком на основном складе —
// и закончившиеся, и «не посчитан». Статус: out — 0, low — мало (не хватит
// до поставки: продажи в день × 3 дня, как «Что заказать» без поставщика),
// unknown — «Остаток не посчитан», ok — хватает.

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/productsearch"
)

// Статусы остатка товара в магазине.
const (
	MyStatusOK      = "ok"
	MyStatusLow     = "low"
	MyStatusOut     = "out"
	MyStatusUnknown = "unknown"
)

// myLeadDays — на сколько дней вперёд считается «мало» (срок поставки, как
// у «Что заказать» без подключённого поставщика).
const myLeadDays = 2

type MyProduct struct {
	ProductID    string  `json:"product_id"`
	Name         string  `json:"name"`
	Image        *string `json:"image"`
	Barcode      *string `json:"barcode"`
	Category     string  `json:"category"`
	UnitShort    string  `json:"unit_short"`
	IsFractional bool    `json:"is_fractional"`
	// Price — цена продажи в магазине (null — не задана).
	Price *string `json:"price"`
	// Qty — остаток на основном складе магазина; у «не посчитан» — что пришло
	// приходами после старта (сколько на самом деле — неизвестно).
	Qty       string `json:"qty"`
	Uncounted bool   `json:"uncounted"`
	// PerDay — продажи в день за 28 дней; DaysLeft — на сколько дней хватит
	// (null — продаж нет или остаток не посчитан).
	PerDay   string `json:"per_day"`
	DaysLeft *int   `json:"days_left"`
	Status   string `json:"status"`
	// Себестоимость единицы и сумма остатка — только с правом «Склад» или «Отчёты».
	AvgCost   *string `json:"avg_cost,omitempty"`
	StockCost *string `json:"stock_cost,omitempty"`
	// LastCost — цена закупки в последнем проведённом приходе (сум); ручной
	// приход в «SM Магазин» подставляет её в новую строку. Тоже только с
	// правом «Склад» или «Отчёты».
	LastCost *string `json:"last_cost,omitempty"`
}

type MyProductsFilter struct {
	StoreID    string
	Status     string // "", ok, low, out, unknown
	CategoryID string
	ProductID  string
	Query      string
	// Order — attention (по умолчанию: закончились, мало, хватает, не посчитан) или name.
	Order string
	Page  httpx.Page
}

type MyCounts struct {
	All       int `json:"all"`
	OK        int `json:"ok"`
	Low       int `json:"low"`
	Out       int `json:"out"`
	Uncounted int `json:"uncounted"`
}

// MyCategory — категория, в которой есть товары магазина (фильтр списка).
type MyCategory struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Products int    `json:"products"`
}

type MyProducts struct {
	Items []MyProduct `json:"items"`
	// Categories — категории товаров магазина (по всем товарам, без фильтров), больше товаров — выше.
	Categories []MyCategory `json:"categories"`
	// Total — строк с этим фильтром; Counts — по поиску и категории, без фильтра статуса.
	Total  int      `json:"total"`
	Counts MyCounts `json:"counts"`
	// WarehouseID — основной склад: история движения — /store/inventory/movements.
	WarehouseID string `json:"warehouse_id"`
	// StockCost — сумма остатков по себестоимости (с правом «Склад» или «Отчёты»).
	StockCost *string `json:"stock_cost,omitempty"`
}

// MyProducts — товары магазина и сколько их осталось.
func (s *Service) MyProducts(ctx context.Context, p *identity.Principal, f MyProductsFilter) (MyProducts, error) {
	out := MyProducts{Items: []MyProduct{}, Categories: []MyCategory{}}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return out, err
	}
	if !httpx.IsUUID(f.StoreID) || !p.CanAccessStore(f.StoreID) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	var wh, pt *string
	err := s.pool.QueryRow(ctx, `
		SELECT s.default_warehouse_id, COALESCE(s.online_price_type_id, pt.id)
		FROM stores s LEFT JOIN price_types pt ON pt.network_id = s.network_id AND pt.is_default
		WHERE s.id = $1 AND s.network_id = $2`, f.StoreID, p.NetworkID).Scan(&wh, &pt)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	if err != nil {
		return out, err
	}
	if wh == nil {
		return out, apperr.Conflict("no_warehouse", "у магазина нет основного склада — выберите его в настройках магазина").Uz("doʻkonda asosiy ombor yoʻq — uni doʻkon sozlamalarida tanlang")
	}
	out.WarehouseID = *wh
	priceType := ""
	if pt != nil {
		priceType = *pt
	}

	args := []any{f.StoreID, *wh, priceType}
	// Блюда кафе не лежат на складе — в «Мои товары» их нет.
	where := ` WHERE pr.is_active AND pr.kind <> 'dish'`
	if f.CategoryID != "" {
		if !httpx.IsUUID(f.CategoryID) {
			return out, apperr.Validation("category_id: категория не найдена").Uz("category_id: kategoriya topilmadi")
		}
		args = append(args, f.CategoryID)
		where += fmt.Sprintf(` AND (pr.category_id = $%[1]d OR c.parent_id = $%[1]d)`, len(args))
	}
	if f.ProductID != "" {
		if !httpx.IsUUID(f.ProductID) {
			return out, apperr.Validation("product_id: товар не найден").Uz("product_id: mahsulot topilmadi")
		}
		args = append(args, f.ProductID)
		where += fmt.Sprintf(` AND pr.id = $%d`, len(args))
	}
	if f.Query != "" {
		where += ` AND ` + productsearch.Filter("pr", f.Query, &args)
	}
	base := fmt.Sprintf(`
		WITH x AS (
			SELECT pr.id, loc(pr.name, pr.name_uz) AS name, pr.images[1] AS image,
			       (SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = pr.id) AS barcode,
			       loc(c.name, c.name_uz) AS category, loc(u.short_name, u.short_name_uz) AS unit, u.is_fractional,
			       COALESCE((SELECT pp.price FROM prices pp WHERE pp.product_id = pr.id AND pp.price_type_id::text = $3 AND pp.store_id = $1),
			                (SELECT pp.price FROM prices pp WHERE pp.product_id = pr.id AND pp.price_type_id::text = $3 AND pp.store_id IS NULL)) AS price,
			       sp.uncounted_since IS NOT NULL AS uncounted,
			       COALESCE((SELECT sum(b.qty_remaining) FROM batches b WHERE b.warehouse_id = $2 AND b.product_id = pr.id AND b.qty_remaining > 0), 0) AS qty,
			       COALESCE((SELECT sum(b.qty_remaining * b.unit_cost) FROM batches b WHERE b.warehouse_id = $2 AND b.product_id = pr.id AND b.qty_remaining > 0), 0) AS cost,
			       COALESCE((SELECT -sum(m.qty) FROM stock_movements m WHERE m.warehouse_id = $2 AND m.product_id = pr.id
			                 AND m.doc_type IN ('sale', 'order') AND m.qty < 0 AND m.created_at > now() - interval '28 days'), 0) / 28.0 AS per_day
			FROM store_products sp
			JOIN products pr  ON pr.id = sp.product_id
			JOIN units u      ON u.id = pr.unit_id
			JOIN categories c ON c.id = pr.category_id
			%s AND sp.store_id = $1
		), y AS (
			SELECT x.*, CASE WHEN x.uncounted THEN 'unknown' WHEN x.qty <= 0 THEN 'out'
			                 WHEN x.per_day > 0 AND x.qty < x.per_day * %d THEN 'low' ELSE 'ok' END AS status
			FROM x
		)`, where, myLeadDays+1)
	var stockCost string
	if err := s.pool.QueryRow(ctx, base+`
		SELECT count(*)::int, (count(*) FILTER (WHERE status = 'ok'))::int, (count(*) FILTER (WHERE status = 'low'))::int,
		       (count(*) FILTER (WHERE status = 'out'))::int, (count(*) FILTER (WHERE status = 'unknown'))::int,
		       round(COALESCE(sum(cost), 0), 2)::text
		FROM y`, productsearch.Args(args)...).Scan(&out.Counts.All, &out.Counts.OK, &out.Counts.Low, &out.Counts.Out, &out.Counts.Uncounted, &stockCost); err != nil {
		return out, err
	}
	crow, err := s.pool.Query(ctx, `
		SELECT c.id, loc(c.name, c.name_uz), count(*)::int
		FROM store_products sp
		JOIN products pr  ON pr.id = sp.product_id AND pr.is_active AND pr.kind <> 'dish'
		JOIN categories c ON c.id = pr.category_id
		WHERE sp.store_id = $1
		GROUP BY c.id ORDER BY 3 DESC, 2`, f.StoreID)
	if err != nil {
		return out, err
	}
	if out.Categories, err = pgx.CollectRows(crow, pgx.RowToStructByPos[MyCategory]); err != nil {
		return out, err
	}
	sees := SeesCost(p)
	if sees {
		out.StockCost = &stockCost
	}
	switch f.Status {
	case "":
		out.Total = out.Counts.All
	case MyStatusOK:
		out.Total = out.Counts.OK
	case MyStatusLow:
		out.Total = out.Counts.Low
	case MyStatusOut:
		out.Total = out.Counts.Out
	case MyStatusUnknown:
		out.Total = out.Counts.Uncounted
	default:
		return out, apperr.Validation("status: ok, low, out или unknown").Uz("status: ok, low, out yoki unknown")
	}
	order := `CASE status WHEN 'out' THEN 0 WHEN 'low' THEN 1 WHEN 'ok' THEN 2 ELSE 3 END, name, id`
	switch f.Order {
	case "", "attention":
	case "name":
		order = `name, id`
	default:
		return out, apperr.Validation("order: attention или name").Uz("order: attention yoki name")
	}
	args = append(args, p.NetworkID)
	netArg := len(args)
	args = append(args, f.Status)
	statusArg := len(args)
	rows, err := s.pool.Query(ctx, base+fmt.Sprintf(`
		SELECT id, name, image, barcode, category, unit, is_fractional, price::text, uncounted,
		       trim_scale(qty)::text, round(per_day, 1)::text,
		       CASE WHEN NOT uncounted AND per_day > 0 THEN floor(GREATEST(qty, 0) / per_day)::int END,
		       status,
		       CASE WHEN qty > 0 THEN round(cost / qty, 2)::text END, round(cost, 2)::text,
		       (SELECT trim_scale(i.price)::text FROM stock_document_items i JOIN stock_documents d ON d.id = i.document_id
		         WHERE d.network_id = $%d AND d.type = 'income' AND d.status = 'posted' AND d.currency = 'UZS'
		           AND i.product_id = y.id AND i.price IS NOT NULL
		         ORDER BY d.posted_at DESC LIMIT 1)
		FROM y
		WHERE $%d = '' OR status = $%d
		ORDER BY %s
		LIMIT %d OFFSET %d`, netArg, statusArg, statusArg, order, f.Page.Limit, f.Page.Offset), productsearch.Args(args)...)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (MyProduct, error) {
		var it MyProduct
		var avg, last *string
		var cost string
		err := r.Scan(&it.ProductID, &it.Name, &it.Image, &it.Barcode, &it.Category, &it.UnitShort, &it.IsFractional, &it.Price,
			&it.Uncounted, &it.Qty, &it.PerDay, &it.DaysLeft, &it.Status, &avg, &cost, &last)
		if sees {
			it.AvgCost, it.StockCost, it.LastCost = avg, &cost, last
		}
		return it, err
	})
	return out, err
}
