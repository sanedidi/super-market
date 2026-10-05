package pos

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/debts"
	"github.com/sanedidi/super-market/backend/internal/identity"
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
}

type Catalog struct {
	// Передайте в следующий раз как since — придут только изменения.
	Version  time.Time        `json:"version"`
	Full     bool             `json:"full"`
	Products []CatalogProduct `json:"products"`
	// Кассиры, ПИНы, способы оплаты и настройки небольшие — всегда целиком.
	Cashiers       []CatalogCashier `json:"cashiers"`
	PaymentMethods []PaymentMethod  `json:"payment_methods"`
	Settings       Settings         `json:"settings"`
	OpenShiftID    *string          `json:"open_shift_id"`
	// Покупатели сети с долгом в этом магазине — для продажи в долг без связи.
	Debtors []debts.CatalogDebtor `json:"debtors"`
}

// Перекрытие окна: изменения, которые закоммитились чуть позже версии,
// всё равно попадут в следующую выгрузку (повтор товара безвреден).
const catalogOverlap = time.Minute

func (s *Service) Catalog(ctx context.Context, p *identity.Principal, since *time.Time) (Catalog, error) {
	out := Catalog{Full: since == nil}
	storeID := p.StoreIDs[0]
	if err := s.pool.QueryRow(ctx, `SELECT now()`).Scan(&out.Version); err != nil {
		return out, err
	}
	out.Version = out.Version.UTC()
	err := s.pool.QueryRow(ctx, `
		SELECT d.id, d.name, st.id, st.name, COALESCE(st.address, ''), n.name, n.receipt_header, n.receipt_footer, n.pos_weight_prefixes,
		       st.debt_enabled, (SELECT sh.id FROM pos_shifts sh WHERE sh.device_id = d.id AND sh.closed_at IS NULL)
		FROM pos_devices d JOIN stores st ON st.id = d.store_id JOIN networks n ON n.id = d.network_id
		WHERE d.id = $1`, p.DeviceID).Scan(&out.Settings.DeviceID, &out.Settings.DeviceName, &out.Settings.StoreID,
		&out.Settings.StoreName, &out.Settings.StoreAddress, &out.Settings.NetworkName, &out.Settings.ReceiptHeader,
		&out.Settings.ReceiptFooter, &out.Settings.WeightPrefixes, &out.Settings.DebtEnabled, &out.OpenShiftID)
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
		SELECT p.id, p.name, u.short_name, u.is_fractional,
		       p.is_active AND (p.moderation_status = 'approved' OR p.network_id = $1),
		       COALESCE(sp.price, np.price, p.base_price)::text,
		       COALESCE((SELECT array_agg(b.barcode ORDER BY b.barcode) FROM product_barcodes b WHERE b.product_id = p.id), '{}'),
		       p.ikpu, p.package_code, p.vat_rate::text, p.is_marked, pl.plu
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		LEFT JOIN pos_plu pl ON pl.network_id = $1 AND pl.product_id = p.id
		WHERE (p.network_id IS NULL OR p.network_id = $1)
		  AND ($4::timestamptz IS NULL OR p.updated_at > $4 OR u.updated_at > $4 OR sp.updated_at > $4
		       OR np.updated_at > $4 OR pl.updated_at > $4)
		ORDER BY p.name`, p.NetworkID, storeID, priceType, from)
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
	out.Debtors, err = debts.CatalogDebtors(ctx, s.pool, p.NetworkID, storeID)
	return out, err
}

func allPermissions() []string {
	out := make([]string, len(identity.Permissions))
	for i, x := range identity.Permissions {
		out[i] = x.Code
	}
	return out
}
