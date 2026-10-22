package pos

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Товар, которого нет в каталоге кассы (Figma «Касса · Цена без связи и
// неизвестный товар», «Панель · Проданы без карточки»).

var barcodeRe = regexp.MustCompile(`^[0-9A-Za-z-]{4,32}$`)

// LookupProduct — товар Super Market по штрихкоду для кассы: в её каталоге
// его нет (нет цены ни в магазине, ни в сети) — касса спросит цену.
type LookupProduct struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	NameRu      string `json:"name_ru"`
	NameUz      string `json:"name_uz"`
	Unit        string `json:"unit"`
	Fractional  bool   `json:"is_fractional"`
	Price       string `json:"price"`
	IKPU        string `json:"ikpu"`
	PackageCode string `json:"package_code"`
	VatRate     string `json:"vat_rate"`
	Marked      bool   `json:"is_marked"`
	Barcode     string `json:"barcode"`
}

func (s *Service) Lookup(ctx context.Context, p *identity.Principal, barcode string) (LookupProduct, error) {
	barcode = strings.TrimSpace(barcode)
	if !barcodeRe.MatchString(barcode) {
		return LookupProduct{}, apperr.Validation("barcode: штрихкод").Uz("barcode: shtrix-kod")
	}
	storeID, err := deviceStoreID(p)
	if err != nil {
		return LookupProduct{}, err
	}
	priceType, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if err != nil {
		return LookupProduct{}, err
	}
	var out LookupProduct
	err = s.pool.QueryRow(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), p.name, p.name_uz, loc(u.short_name, u.short_name_uz), u.is_fractional,
		       COALESCE(sp.price, np.price, p.base_price)::text, p.ikpu, p.package_code, p.vat_rate::text, p.is_marked, b.barcode
		FROM product_barcodes b
		JOIN products p ON p.id = b.product_id
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL AND np.network_id = $1
		WHERE barcode_key(b.barcode) = barcode_key($4) AND p.kind = 'goods' AND p.is_active
		  AND (p.network_id = $1 OR (p.network_id IS NULL AND p.moderation_status = 'approved'))
		ORDER BY (p.network_id IS NOT NULL) DESC LIMIT 1`, p.NetworkID, storeID, priceType, barcode).
		Scan(&out.ID, &out.Name, &out.NameRu, &out.NameUz, &out.Unit, &out.Fractional, &out.Price, &out.IKPU, &out.PackageCode,
			&out.VatRate, &out.Marked, &out.Barcode)
	if errors.Is(err, pgx.ErrNoRows) {
		return LookupProduct{}, apperr.NotFound("товара нет в Super Market").Uz("mahsulot Super Marketda yoʻq")
	}
	return out, err
}

func deviceStoreID(p *identity.Principal) (string, error) {
	if p.DeviceID == "" || len(p.StoreIDs) == 0 {
		return "", apperr.Forbidden("только для кассы").Uz("faqat kassa uchun")
	}
	return p.StoreIDs[0], nil
}

// --------------------------------------------------------------- панель

// UnknownGood — штрихкод, который касса продала «Неизвестным товаром».
type UnknownGood struct {
	Barcode  string    `json:"barcode"`
	Name     string    `json:"name"`
	Cashier  string    `json:"cashier"`
	Device   string    `json:"device"`
	PriceMin string    `json:"price_min"`
	PriceMax string    `json:"price_max"`
	Qty      string    `json:"qty"`
	Total    string    `json:"total"`
	Sales    int       `json:"sales"`
	LastAt   time.Time `json:"last_at"`
	// Товар с этим штрихкодом уже есть в Super Market (но не в магазине):
	// «Завести товар» добавит его с ценой.
	Found *FoundProduct `json:"found"`
}

type FoundProduct struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// UnknownGoods — «Товары → Без карточки»: что касса магазина продала
// неизвестным товаром и чего до сих пор нет в «Моих товарах».
func (s *Service) UnknownGoods(ctx context.Context, p *identity.Principal, storeID string) ([]UnknownGood, error) {
	if err := p.RequireAny(identity.PermCatalogManage, identity.PermPricesManage, identity.PermReportsView); err != nil {
		return nil, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	rows, err := s.pool.Query(ctx, `
		WITH x AS (
			SELECT i.unknown_barcode AS barcode, barcode_key(i.unknown_barcode) AS bk, i.unknown_name AS name, i.price, i.qty, i.total,
			       s.sold_at, COALESCE(e.full_name, '') AS cashier, COALESCE(d.name, '') AS device
			FROM sale_items i
			JOIN sales s ON s.id = i.sale_id
			LEFT JOIN employees e ON e.id = s.cashier_id
			LEFT JOIN pos_devices d ON d.id = s.device_id
			WHERE s.network_id = $1 AND s.store_id = $2 AND i.unknown_barcode <> ''
		), g AS (
			SELECT bk, min(barcode) AS barcode, min(price) AS pmin, max(price) AS pmax, sum(qty) AS qty, sum(total) AS total,
			       count(*)::int AS n, max(sold_at) AS last_at
			FROM x GROUP BY bk
		)
		SELECT g.barcode,
		       COALESCE((SELECT x.name FROM x WHERE x.bk = g.bk AND x.name <> '' ORDER BY x.sold_at DESC LIMIT 1), ''),
		       (SELECT x.cashier FROM x WHERE x.bk = g.bk ORDER BY x.sold_at DESC LIMIT 1),
		       (SELECT x.device FROM x WHERE x.bk = g.bk ORDER BY x.sold_at DESC LIMIT 1),
		       g.pmin::text, g.pmax::text, trim_scale(g.qty)::text, g.total::text, g.n, g.last_at,
		       f.id, f.name
		FROM g
		LEFT JOIN LATERAL (
			SELECT p.id, loc(p.name, p.name_uz) AS name FROM product_barcodes b JOIN products p ON p.id = b.product_id
			WHERE barcode_key(b.barcode) = g.bk AND p.kind = 'goods' AND p.is_active
			  AND (p.network_id = $1 OR (p.network_id IS NULL AND p.moderation_status = 'approved'))
			ORDER BY (p.network_id IS NOT NULL) DESC LIMIT 1
		) f ON true
		WHERE NOT EXISTS (
			SELECT 1 FROM product_barcodes b JOIN store_products sp ON sp.product_id = b.product_id AND sp.store_id = $2
			WHERE barcode_key(b.barcode) = g.bk)
		ORDER BY g.last_at DESC
		LIMIT 500`, p.NetworkID, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (UnknownGood, error) {
		var u UnknownGood
		var fid, fname *string
		err := r.Scan(&u.Barcode, &u.Name, &u.Cashier, &u.Device, &u.PriceMin, &u.PriceMax, &u.Qty, &u.Total, &u.Sales, &u.LastAt, &fid, &fname)
		if fid != nil {
			u.Found = &FoundProduct{ID: *fid, Name: *fname}
		}
		return u, err
	})
}

type AdoptInput struct {
	StoreID   string       `json:"store_id"`
	ProductID string       `json:"product_id"`
	Price     money.Amount `json:"price"`
}

// AdoptUnknown — «Завести товар», когда товар с этим штрихкодом уже есть в
// Super Market: цена магазина (документ цен проводится сразу) — товар
// попадает в «Мои товары», касса пробивает его обычно.
func (s *Service) AdoptUnknown(ctx context.Context, p *identity.Principal, in AdoptInput) (ProductPrice, error) {
	if err := p.Require(identity.PermPricesManage); err != nil {
		return ProductPrice{}, err
	}
	if !httpx.IsUUID(in.StoreID) || !p.CanAccessStore(in.StoreID) {
		return ProductPrice{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if !httpx.IsUUID(in.ProductID) {
		return ProductPrice{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if !in.Price.Valid() || money.D(string(in.Price)).Sign() <= 0 {
		return ProductPrice{}, apperr.Validation("price: цена больше нуля").Uz("price: narx noldan katta boʻlsin")
	}
	var ok bool
	err := s.pool.QueryRow(ctx, `SELECT true FROM products WHERE id = $1 AND kind = 'goods' AND (network_id IS NULL OR network_id = $2)`,
		in.ProductID, p.NetworkID).Scan(&ok)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProductPrice{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
	}
	if err != nil {
		return ProductPrice{}, err
	}
	priceType, err := catalog.DefaultPriceType(ctx, s.pool, p.NetworkID)
	if err != nil {
		return ProductPrice{}, err
	}
	note := "Без карточки → Мои товары"
	items := []struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	}{{ProductID: in.ProductID, NewPrice: in.Price}}
	doc, err := s.cat.CreatePriceDoc(ctx, p, catalog.PriceDocInput{PriceTypeID: &priceType, StoreID: &in.StoreID, Note: &note, Items: &items})
	if err != nil {
		return ProductPrice{}, err
	}
	if _, err := s.cat.PostPriceDoc(ctx, p, doc.ID); err != nil {
		return ProductPrice{}, err
	}
	return ProductPrice{ProductID: in.ProductID, Price: money.D(string(in.Price)).Money()}, nil
}
