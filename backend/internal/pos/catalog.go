package pos

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/cafe"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Каталог кассы: всё, что нужно, чтобы продавать без интернета. Первая
// загрузка — целиком, дальше — только изменения с прошлой версии.

type CatalogProduct struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Unit        string   `json:"unit"`
	Fractional  bool     `json:"fractional"`
	Active      bool     `json:"active"`
	Price       string   `json:"price"`
	Barcodes    []string `json:"barcodes"`
	IKPU        string   `json:"ikpu"`
	PackageCode string   `json:"package_code"`
	VATRate     string   `json:"vat_rate"`
	Marked      bool     `json:"marked"`
	PLU         *int     `json:"plu"`
	// Первое фото и раздел верхнего уровня — для быстрых кнопок кассы.
	Image    string `json:"image"`
	Category string `json:"category"`
	// Name — на языке запроса; для поиска на кассе — оба языка как есть.
	// В фискальный чек идёт name_ru (основное название, как и раньше).
	NameRu string `json:"name_ru"`
	NameUz string `json:"name_uz"`
	// Группа вариаций: быстрая кнопка группы открывает выбор веса и вкуса.
	VariantGroupID *string `json:"variant_group_id"`
	VariantGroup   string  `json:"variant_group"`
	VariantWeight  string  `json:"variant_weight"`
	VariantFlavor  string  `json:"variant_flavor"`
	// Порядок внутри группы: вес по возрастанию, затем вкус.
	VariantWeightSort float64 `json:"variant_weight_sort"`
	VariantSort       int     `json:"variant_sort"`
	// Названия переключателей группы: «Вес»/«Объём», «Вкус»/«Цвет»/«Аромат».
	VariantWeightLabel string `json:"variant_weight_label"`
	VariantFlavorLabel string `json:"variant_flavor_label"`
}

type CatalogCashier struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	PinHash     string   `json:"pin_hash"`
	Permissions []string `json:"permissions"`
}

type PaymentMethod struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// cash, card, qr, other — клавиши кассы и подсчёт наличных.
	Kind string `json:"kind"`
}

type Settings struct {
	DeviceID       string   `json:"device_id"`
	DeviceName     string   `json:"device_name"`
	StoreID        string   `json:"store_id"`
	StoreName      string   `json:"store_name"`
	StoreAddress   string   `json:"store_address"`
	NetworkName    string   `json:"network_name"`
	ReceiptHeader  string   `json:"receipt_header"`
	ReceiptFooter  string   `json:"receipt_footer"`
	WeightPrefixes []string `json:"weight_prefixes"`
	// «Даёт в долг»: показывать ли кассиру продажу в долг.
	DebtEnabled bool `json:"debt_enabled"`
	// Вид устройства (pos, kitchen, display) и цех экрана кухни: панель может
	// поменять цех, устройство узнаёт об этом при синхронизации.
	DeviceKind   string  `json:"device_kind"`
	WorkshopID   *string `json:"workshop_id"`
	WorkshopName *string `json:"workshop_name"`
}

type Catalog struct {
	// Передайте в следующий раз как since — придут только изменения.
	Version  time.Time        `json:"version"`
	Full     bool             `json:"full"`
	Epoch    int              `json:"epoch"`
	Products []CatalogProduct `json:"products"`
	// Кассиры, ПИНы, способы оплаты и настройки небольшие — всегда целиком.
	Cashiers       []CatalogCashier `json:"cashiers"`
	PaymentMethods []PaymentMethod  `json:"payment_methods"`
	Settings       Settings         `json:"settings"`
	OpenShiftID    *string          `json:"open_shift_id"`
	// Покупатели сети с долгом в этом магазине — для продажи в долг без связи.
	Debtors []debts.CatalogDebtor `json:"debtors"`
	// Быстрые кнопки: закреплённые владельцем и самые продаваемые — всегда целиком.
	Quick QuickKeys `json:"quick"`
	// Меню кафе (группы, цеха, модификаторы, стоп-лист) — всегда целиком;
	// null — сеть не кафе, касса работает как магазин.
	Cafe *cafe.PosMenu `json:"cafe"`
}

// QuickKeys — товары для плиток на экране продажи.
type QuickKeys struct {
	// Закреплённые на вкладке «Частые», по порядку.
	Pinned []string `json:"pinned"`
	// Самые продаваемые в магазине за 30 дней, по убыванию числа чеков.
	Top []string `json:"top"`
}

// Сколько самых продаваемых товаров отдавать кассе (на «Частые» и вкладки разделов).
const quickTopLimit = 200

// Перекрытие окна: изменения, которые закоммитились чуть позже версии,
// всё равно попадут в следующую выгрузку (повтор товара безвреден).
const catalogOverlap = time.Minute

// CatalogEpoch — поколение каталога кассы. Касса присылает своё (epoch), и если
// оно другое, получает каталог целиком. 2 — после импорта каталога ИКПУ товары
// без цены на кассу больше не идут, а старые копии их ещё хранят.
// 3 — в товарах появились группы вариаций (вес и вкус); 4 — названия
// переключателей группы («Цвет» вместо «Вкус» у посуды и т. п.).
// 5 — на кассу идут только товары магазина («Мои товары»), а не вся
// центральная база с базовой ценой: старые копии надо заменить целиком.
const CatalogEpoch = 5

func (s *Service) Catalog(ctx context.Context, p *identity.Principal, since *time.Time) (Catalog, error) {
	out := Catalog{Full: since == nil, Epoch: CatalogEpoch}
	storeID := p.StoreIDs[0]
	if err := s.pool.QueryRow(ctx, `SELECT now()`).Scan(&out.Version); err != nil {
		return out, err
	}
	out.Version = out.Version.UTC()
	err := s.pool.QueryRow(ctx, `
		SELECT d.id, d.name, st.id, st.name, COALESCE(st.address, ''), n.name, n.receipt_header, n.receipt_footer, n.pos_weight_prefixes,
		       st.debt_enabled AND network_has_feature(n.id, 'debts'), (SELECT sh.id FROM pos_shifts sh WHERE sh.device_id = d.id AND sh.closed_at IS NULL),
		       d.kind, d.workshop_id, (SELECT loc(w.name, w.name_uz) FROM workshops w WHERE w.id = d.workshop_id)
		FROM pos_devices d JOIN stores st ON st.id = d.store_id JOIN networks n ON n.id = d.network_id
		WHERE d.id = $1`, p.DeviceID).Scan(&out.Settings.DeviceID, &out.Settings.DeviceName, &out.Settings.StoreID,
		&out.Settings.StoreName, &out.Settings.StoreAddress, &out.Settings.NetworkName, &out.Settings.ReceiptHeader,
		&out.Settings.ReceiptFooter, &out.Settings.WeightPrefixes, &out.Settings.DebtEnabled, &out.OpenShiftID,
		&out.Settings.DeviceKind, &out.Settings.WorkshopID, &out.Settings.WorkshopName)
	if err != nil {
		return out, err
	}

	priceType, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if err != nil {
		return out, err
	}
	var from *time.Time
	if since != nil {
		t := since.Add(-catalogOverlap)
		from = &t
	}
	rows, err := s.pool.Query(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), loc(u.short_name, u.short_name_uz), u.is_fractional,
		       p.is_active AND (p.moderation_status = 'approved' OR p.network_id = $1),
		       COALESCE(sp.price, np.price, p.base_price)::text,
		       COALESCE((SELECT array_agg(b.barcode ORDER BY b.barcode) FROM product_barcodes b WHERE b.product_id = p.id), '{}'),
		       p.ikpu, p.package_code, p.vat_rate::text, p.is_marked, pl.plu,
		       COALESCE(p.images[1], ''),
		       COALESCE(loc(c2.name, c2.name_uz), loc(c1.name, c1.name_uz), loc(c.name, c.name_uz), ''),
		       p.name, p.name_uz,
		       vg.id, COALESCE(loc(vg.name, vg.name_uz), ''),
		       CASE WHEN vg.id IS NULL THEN '' ELSE loc(p.variant_weight, p.variant_weight_uz) END,
		       CASE WHEN vg.id IS NULL THEN '' ELSE loc(p.variant_flavor, p.variant_flavor_uz) END,
		       p.variant_weight_sort::float8, p.variant_sort,
		       COALESCE(loc(vg.weight_label, vg.weight_label_uz), ''), COALESCE(loc(vg.flavor_label, vg.flavor_label_uz), '')
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN variant_groups vg ON vg.id = p.variant_group_id AND vg.status = 'confirmed'
		LEFT JOIN categories c ON c.id = p.category_id
		LEFT JOIN categories c1 ON c1.id = c.parent_id
		LEFT JOIN categories c2 ON c2.id = c1.parent_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		LEFT JOIN pos_plu pl ON pl.network_id = $1 AND pl.product_id = p.id
		LEFT JOIN store_products mine ON mine.store_id = $2 AND mine.product_id = p.id
		WHERE (p.network_id IS NULL OR p.network_id = $1)
		  -- Только товары магазина («Мои товары»: добавил сам, пришли приходом,
		  -- есть цена магазина; блюда кафе — в выбранных точках), а не вся
		  -- центральная база. Плюс товары с ценой сети и с кодом весов (PLU) —
		  -- их сеть настроила сама. Незнакомый штрихкод касса продаёт как
		  -- «Неизвестный товар».
		  AND (mine.product_id IS NOT NULL OR np.price IS NOT NULL OR pl.plu IS NOT NULL)
		  AND ($4::timestamptz IS NULL OR p.updated_at > $4 OR u.updated_at > $4 OR sp.updated_at > $4
		       OR np.updated_at > $4 OR pl.updated_at > $4 OR vg.updated_at > $4 OR mine.added_at > $4)
		ORDER BY loc(p.name, p.name_uz)`, p.NetworkID, storeID, priceType, from)
	if err != nil {
		return out, err
	}
	if out.Products, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogProduct]); err != nil {
		return out, err
	}

	rows, err = s.pool.Query(ctx, `
		SELECT e.id, e.full_name, e.pin_hash,
		       CASE WHEN r.is_owner THEN $3::text[] ELSE r.permissions END
		FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.network_id = $1 AND e.status = 'active' AND e.pin_hash <> ''
		  AND (r.is_owner OR e.all_stores OR EXISTS (SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id = $2))
		  AND (r.is_owner OR $4 = ANY(r.permissions))
		ORDER BY e.full_name`, p.NetworkID, storeID, allPermissions(), identity.PermSalesPOS)
	if err != nil {
		return out, err
	}
	if out.Cashiers, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogCashier]); err != nil {
		return out, err
	}

	rows, err = s.pool.Query(ctx, `
		SELECT m.id, m.name, m.kind FROM payment_methods m JOIN cashboxes c ON c.id = m.cashbox_id
		WHERE m.network_id = $1 AND c.store_id = $2 AND m.is_active AND c.is_active AND c.currency = 'UZS'
		ORDER BY CASE m.kind WHEN 'cash' THEN 0 WHEN 'card' THEN 1 WHEN 'qr' THEN 2 ELSE 3 END, m.name`, p.NetworkID, storeID)
	if err != nil {
		return out, err
	}
	if out.PaymentMethods, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PaymentMethod]); err != nil {
		return out, err
	}
	if out.Debtors, err = debts.CatalogDebtors(ctx, s.pool, p.NetworkID, storeID); err != nil {
		return out, err
	}
	if out.Quick, err = s.quickKeys(ctx, storeID); err != nil {
		return out, err
	}
	out.Cafe, err = cafe.MenuForPOS(ctx, s.pool, p.NetworkID, storeID)
	return out, err
}

func (s *Service) quickKeys(ctx context.Context, storeID string) (QuickKeys, error) {
	out := QuickKeys{Pinned: []string{}, Top: []string{}}
	rows, err := s.pool.Query(ctx, `
		SELECT product_id::text FROM pos_quick_keys WHERE store_id = $1 ORDER BY position, created_at`, storeID)
	if err != nil {
		return out, err
	}
	if out.Pinned, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
		return out, err
	}
	rows, err = s.pool.Query(ctx, `
		SELECT i.product_id::text
		FROM sales sl JOIN sale_items i ON i.sale_id = sl.id
		WHERE sl.store_id = $1 AND sl.sold_at > now() - interval '30 days'
		GROUP BY i.product_id
		ORDER BY count(DISTINCT sl.id) DESC, sum(i.total) DESC, i.product_id
		LIMIT $2`, storeID, quickTopLimit)
	if err != nil {
		return out, err
	}
	out.Top, err = pgx.CollectRows(rows, pgx.RowTo[string])
	return out, err
}

// Сколько товаров можно закрепить на вкладке «Частые».
const quickPinnedMax = 30

type QuickKeysInput struct {
	ProductIDs []string `json:"product_ids"`
}

// SetQuickKeys заменяет закреплённые товары магазина кассы (порядок — как в списке).
// Нужен кассир с правом «Настройка кассы» (у владельца — всегда).
func (s *Service) SetQuickKeys(ctx context.Context, p *identity.Principal, in QuickKeysInput) (QuickKeys, error) {
	if p.EmployeeID == "" {
		return QuickKeys{}, apperr.New(http.StatusUnauthorized, "cashier_required", "войдите кассиром по ПИНу").Uz("PIN-kod bilan kassir sifatida kiring")
	}
	if err := p.Require(identity.PermPOSSettings); err != nil {
		return QuickKeys{}, err
	}
	if len(in.ProductIDs) > quickPinnedMax {
		return QuickKeys{}, apperr.Validation(fmt.Sprintf("product_ids: не больше %d товаров", quickPinnedMax)).Uz(fmt.Sprintf("product_ids: koʻpi bilan %d ta mahsulot", quickPinnedMax))
	}
	seen := map[string]bool{}
	for _, id := range in.ProductIDs {
		if !httpx.IsUUID(id) {
			return QuickKeys{}, apperr.Validation("product_ids: неверный id товара").Uz("product_ids: mahsulot id notoʻgʻri")
		}
		if seen[id] {
			return QuickKeys{}, apperr.Validation("product_ids: товар указан дважды").Uz("product_ids: mahsulot ikki marta koʻrsatilgan")
		}
		seen[id] = true
	}
	storeID := p.StoreIDs[0]
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var n int
		if err := tx.QueryRow(ctx, `
			SELECT count(*) FROM products WHERE id = ANY($1::uuid[]) AND (network_id IS NULL OR network_id = $2)`,
			in.ProductIDs, p.NetworkID).Scan(&n); err != nil {
			return err
		}
		if n != len(in.ProductIDs) {
			return apperr.Validation("product_ids: товар не найден").Uz("product_ids: mahsulot topilmadi")
		}
		if _, err := tx.Exec(ctx, `DELETE FROM pos_quick_keys WHERE store_id = $1`, storeID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO pos_quick_keys (store_id, product_id, position)
			SELECT $1, id, ord - 1 FROM unnest($2::uuid[]) WITH ORDINALITY AS t(id, ord)`, storeID, in.ProductIDs)
		return err
	})
	if err != nil {
		return QuickKeys{}, err
	}
	return s.quickKeys(ctx, storeID)
}

func allPermissions() []string {
	out := make([]string, len(identity.Permissions))
	for i, x := range identity.Permissions {
		out[i] = x.Code
	}
	return out
}
