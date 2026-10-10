package catalog

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Страница товара супер-админа (Figma «Товар — отдельная страница вместо
// модалки», ТТ1/ТТ2): то, чего нет в самом товаре, — откуда он, налоговые
// поля, группа вариаций и где продаётся.

// ProductOverview — GET /admin/products/{id}/overview.
type ProductOverview struct {
	UpdatedAt   time.Time         `json:"updated_at"`
	Source      string            `json:"source"`
	NetworkName *string           `json:"network_name"`
	Tax         ProductTaxInfo    `json:"tax"`
	Variants    *OverviewVariants `json:"variants"`
	Selling     OverviewSelling   `json:"selling"`
}

type ProductTaxInfo struct {
	IKPU        string `json:"ikpu"`
	IKPUName    string `json:"ikpu_name"`
	PackageCode string `json:"package_code"`
	VATRate     string `json:"vat_rate"`
	Marked      bool   `json:"marked"`
}

// OverviewVariants — подтверждённая группа вариаций товара.
type OverviewVariants struct {
	GroupID     string            `json:"group_id"`
	Name        string            `json:"name"`
	WeightLabel string            `json:"weight_label"`
	FlavorLabel string            `json:"flavor_label"`
	Weight      string            `json:"weight"`
	Flavor      string            `json:"flavor"`
	Count       int               `json:"count"`
	Items       []OverviewVariant `json:"items"` // другие товары группы (до 6)
}

type OverviewVariant struct {
	ProductID string  `json:"product_id"`
	Name      string  `json:"name"`
	Weight    string  `json:"weight"`
	Flavor    string  `json:"flavor"`
	Image     *string `json:"image"`
}

// OverviewSelling — в каких магазинах товар есть: цена в приложении и остаток.
type OverviewSelling struct {
	Stores   int             `json:"stores"`
	Networks int             `json:"networks"`
	MinPrice *string         `json:"min_price"`
	MaxPrice *string         `json:"max_price"`
	Stock    string          `json:"stock"`
	List     []OverviewStore `json:"list"`
}

type OverviewStore struct {
	StoreID     string `json:"store_id"`
	StoreName   string `json:"store_name"`
	NetworkName string `json:"network_name"`
	Price       string `json:"price"`
	Stock       string `json:"stock"`
}

const overviewStoresMax = 300

func (s *Service) AdminProductOverview(ctx context.Context, id string) (ProductOverview, error) {
	var out ProductOverview
	if !httpx.IsUUID(id) {
		return out, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	lang := i18n.FromContext(ctx)
	var src string
	var hasJob bool
	var groupID *string
	err := s.pool.QueryRow(ctx, `
		SELECT p.updated_at, n.name, COALESCE(p.attributes ->> 'source', ''),
		       EXISTS (SELECT 1 FROM product_photo_jobs j WHERE j.product_id = p.id),
		       p.ikpu, COALESCE(p.attributes ->> 'ikpu_name', ''), p.package_code, p.vat_rate::text, p.is_marked,
		       (SELECT g.id::text FROM variant_groups g WHERE g.id = p.variant_group_id AND g.status = 'confirmed')
		FROM products p LEFT JOIN networks n ON n.id = p.network_id
		WHERE p.id = $1`, id).Scan(&out.UpdatedAt, &out.NetworkName, &src, &hasJob,
		&out.Tax.IKPU, &out.Tax.IKPUName, &out.Tax.PackageCode, &out.Tax.VATRate, &out.Tax.Marked, &groupID)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if err != nil {
		return out, err
	}
	out.Source = productSource(lang, out.NetworkName, src, hasJob)

	if groupID != nil {
		v := OverviewVariants{GroupID: *groupID, Items: []OverviewVariant{}}
		err := s.pool.QueryRow(ctx, `
			SELECT loc(g.name, g.name_uz), loc(g.weight_label, g.weight_label_uz), loc(g.flavor_label, g.flavor_label_uz),
			       loc(p.variant_weight, p.variant_weight_uz), loc(p.variant_flavor, p.variant_flavor_uz),
			       (SELECT count(*)::int FROM products x WHERE x.variant_group_id = g.id AND x.is_active)
			FROM variant_groups g JOIN products p ON p.id = $2
			WHERE g.id = $1`, *groupID, id).Scan(&v.Name, &v.WeightLabel, &v.FlavorLabel, &v.Weight, &v.Flavor, &v.Count)
		if err != nil {
			return out, err
		}
		rows, err := s.pool.Query(ctx, `
			SELECT p.id, loc(p.name, p.name_uz), loc(p.variant_weight, p.variant_weight_uz), loc(p.variant_flavor, p.variant_flavor_uz), p.images[1]
			FROM products p
			WHERE p.variant_group_id = $1 AND p.id <> $2 AND p.is_active
			ORDER BY p.variant_weight_sort, p.variant_weight, p.variant_sort, p.name
			LIMIT 6`, *groupID, id)
		if err != nil {
			return out, err
		}
		v.Items, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (OverviewVariant, error) {
			var it OverviewVariant
			return it, r.Scan(&it.ProductID, &it.Name, &it.Weight, &it.Flavor, &it.Image)
		})
		if err != nil {
			return out, err
		}
		out.Variants = &v
	}

	// Магазины, где товар в ассортименте: цена типа, который видит приложение
	// (свой тип магазина или тип сети по умолчанию), и остаток на складах магазина.
	rows, err := s.pool.Query(ctx, `
		WITH st AS (
			SELECT s.id, s.name, n.name AS network, s.network_id,
			       COALESCE(s.online_price_type_id, (SELECT pt.id FROM price_types pt WHERE pt.network_id = s.network_id AND pt.is_default)) AS type_id
			FROM store_products x
			JOIN stores s ON s.id = x.store_id
			JOIN networks n ON n.id = s.network_id
			WHERE x.product_id = $1
		)
		SELECT st.id, st.name, st.network,
		       COALESCE((SELECT pr.price FROM prices pr WHERE pr.product_id = $1 AND pr.price_type_id = st.type_id AND pr.store_id = st.id),
		                (SELECT pr.price FROM prices pr WHERE pr.product_id = $1 AND pr.price_type_id = st.type_id AND pr.store_id IS NULL),
		                (SELECT p.base_price FROM products p WHERE p.id = $1))::text,
		       COALESCE((SELECT sum(b.qty_remaining) FROM batches b JOIN warehouses w ON w.id = b.warehouse_id
		                 WHERE w.store_id = st.id AND b.product_id = $1 AND b.qty_remaining > 0), 0)::text
		FROM st
		ORDER BY st.network, st.name`, id)
	if err != nil {
		return out, err
	}
	stores, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (OverviewStore, error) {
		var x OverviewStore
		return x, r.Scan(&x.StoreID, &x.StoreName, &x.NetworkName, &x.Price, &x.Stock)
	})
	if err != nil {
		return out, err
	}
	sell := OverviewSelling{List: []OverviewStore{}, Stock: "0"}
	networks := map[string]bool{}
	var lo, hi, stock money.Dec
	for i, x := range stores {
		networks[x.NetworkName] = true
		p := money.D(x.Price)
		if i == 0 || p.Cmp(lo) < 0 {
			lo = p
		}
		if i == 0 || p.Cmp(hi) > 0 {
			hi = p
		}
		stock = stock.Add(money.D(x.Stock))
		x.Stock = trimQty(x.Stock)
		if len(sell.List) < overviewStoresMax {
			sell.List = append(sell.List, x)
		}
	}
	sell.Stores, sell.Networks = len(stores), len(networks)
	if len(stores) > 0 {
		a, b := lo.Money(), hi.Money()
		sell.MinPrice, sell.MaxPrice = &a, &b
		sell.Stock = trimQty(stock.Fixed(3))
	}
	out.Selling = sell
	return out, nil
}

// productSource — откуда товар, для человека.
func productSource(lang string, network *string, src string, photoJob bool) string {
	switch {
	case network != nil:
		return i18n.Pick(lang, "Сеть «"+*network+"»", "«"+*network+"» tarmogʻi")
	case src == "tasnif.soliq.uz" || src == "tasnif" || photoJob:
		return i18n.Pick(lang, "Каталог ИКПУ (tasnif)", "MXIK katalogi (tasnif)")
	case strings.Contains(strings.ToLower(src), "lavka") || strings.Contains(strings.ToLower(src), "yandex"):
		return i18n.Pick(lang, "Импорт Яндекс Лавки", "Yandex Lavka importi")
	case src == "photo":
		return i18n.Pick(lang, "Новый товар по фото", "Rasm boʻyicha yangi mahsulot")
	case src != "":
		return src
	}
	return "Super Market"
}

// trimQty — «12.500» → «12.5», «40.000» → «40».
func trimQty(s string) string {
	if !strings.Contains(s, ".") {
		return s
	}
	s = strings.TrimRight(s, "0")
	return strings.TrimSuffix(s, ".")
}
