package catalog

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Product — карточка товара.
type Product struct {
	ID               string    `json:"id"`
	NetworkID        *string   `json:"network_id"`
	ProposedBy       *string   `json:"proposed_by"`
	Name             string    `json:"name"`
	Description      string    `json:"description"`
	BrandID          *string   `json:"brand_id"`
	BrandName        *string   `json:"brand_name"`
	CategoryID       string    `json:"category_id"`
	CategoryName     string    `json:"category_name"`
	UnitID           string    `json:"unit_id"`
	UnitShort        string    `json:"unit_short"`
	IsFractional     bool      `json:"is_fractional"`
	ColorID          *string   `json:"color_id"`
	BasePrice        string    `json:"base_price"`
	Images           []string  `json:"images"`
	Barcodes         []string  `json:"barcodes"`
	ModerationStatus string    `json:"moderation_status"`
	RejectionReason  string    `json:"rejection_reason"`
	IsActive         bool      `json:"is_active"`
	CreatedAt        time.Time `json:"created_at"`
	// Характеристики для карточки в приложении: nutrition, composition,
	// shelf_life, storage, country, volume и любые другие строки.
	Attributes map[string]any `json:"attributes"`
	// Заполняется, когда в запросе указан магазин.
	Price       *string `json:"price,omitempty"`
	PriceSource *string `json:"price_source,omitempty"` // store | network | base
	PriceTypeID *string `json:"price_type_id,omitempty"`
}

const productCols = `
	p.id, p.network_id, p.proposed_by, p.name, p.description,
	p.brand_id, b.name, p.category_id, c.name, p.unit_id, u.short_name, u.is_fractional,
	p.color_id, p.base_price::text, p.images,
	COALESCE((SELECT array_agg(pb.barcode ORDER BY pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), '{}'),
	p.moderation_status, p.rejection_reason, p.is_active, p.created_at, p.attributes`

const productFrom = `
	FROM products p
	LEFT JOIN brands b ON b.id = p.brand_id
	JOIN categories c  ON c.id = p.category_id
	JOIN units u       ON u.id = p.unit_id`

func scanProduct(row pgx.CollectableRow) (Product, error) {
	var p Product
	err := row.Scan(&p.ID, &p.NetworkID, &p.ProposedBy, &p.Name, &p.Description,
		&p.BrandID, &p.BrandName, &p.CategoryID, &p.CategoryName, &p.UnitID, &p.UnitShort, &p.IsFractional,
		&p.ColorID, &p.BasePrice, &p.Images, &p.Barcodes,
		&p.ModerationStatus, &p.RejectionReason, &p.IsActive, &p.CreatedAt, &p.Attributes)
	return p, err
}

func scanProductWithPrice(row pgx.CollectableRow) (Product, error) {
	var p Product
	err := row.Scan(&p.ID, &p.NetworkID, &p.ProposedBy, &p.Name, &p.Description,
		&p.BrandID, &p.BrandName, &p.CategoryID, &p.CategoryName, &p.UnitID, &p.UnitShort, &p.IsFractional,
		&p.ColorID, &p.BasePrice, &p.Images, &p.Barcodes,
		&p.ModerationStatus, &p.RejectionReason, &p.IsActive, &p.CreatedAt, &p.Attributes,
		&p.Price, &p.PriceSource, &p.PriceTypeID)
	return p, err
}

// ProductInput — поля товара; nil — не менять.
type ProductInput struct {
	Name        *string         `json:"name"`
	Description *string         `json:"description"`
	BrandID     *string         `json:"brand_id"`
	CategoryID  *string         `json:"category_id"`
	UnitID      *string         `json:"unit_id"`
	ColorID     *string         `json:"color_id"`
	BasePrice   *money.Amount   `json:"base_price"`
	Images      *[]string       `json:"images"`
	Barcodes    *[]string       `json:"barcodes"`
	IsActive    *bool           `json:"is_active"`
	Attributes  *map[string]any `json:"attributes"`
}

func (in ProductInput) validate(create bool) error {
	if create {
		if in.Name == nil {
			return apperr.Validation("name: обязательное поле")
		}
		if in.CategoryID == nil {
			return apperr.Validation("category_id: обязательное поле")
		}
		if in.UnitID == nil {
			return apperr.Validation("unit_id: обязательное поле")
		}
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return apperr.Validation("name: не может быть пустым")
	}
	for name, id := range map[string]*string{"brand_id": in.BrandID, "category_id": in.CategoryID, "unit_id": in.UnitID, "color_id": in.ColorID} {
		if id != nil && *id != "" && !httpx.IsUUID(*id) {
			return apperr.Validation(name + ": запись не найдена")
		}
	}
	if in.Attributes != nil {
		if err := validateAttributes(*in.Attributes); err != nil {
			return err
		}
	}
	if in.Images != nil {
		if len(*in.Images) > 10 {
			return apperr.Validation("images: не больше 10 фото")
		}
		for _, u := range *in.Images {
			if !strings.HasPrefix(u, "https://") && !strings.HasPrefix(u, "http://") {
				return apperr.Validation("images: ожидаются ссылки http(s)")
			}
		}
	}
	if in.Barcodes != nil && len(*in.Barcodes) > 10 {
		return apperr.Validation("barcodes: не больше 10 штрихкодов")
	}
	return nil
}

// nullable: пустая строка в brand_id/color_id означает «убрать».
func nullable(p *string) (set bool, val *string) {
	if p == nil {
		return false, nil
	}
	if *p == "" {
		return true, nil
	}
	return true, p
}

func (s *Service) createProduct(ctx context.Context, networkID *string, in ProductInput) (Product, error) {
	if err := in.validate(true); err != nil {
		return Product{}, err
	}
	status := "approved"
	if networkID != nil {
		status = "pending"
	}
	_, brand := nullable(in.BrandID)
	_, color := nullable(in.ColorID)
	price := money.Amount("0")
	if in.BasePrice != nil {
		price = *in.BasePrice
	}
	images := []string{}
	if in.Images != nil {
		images = *in.Images
	}
	desc := ""
	if in.Description != nil {
		desc = strings.TrimSpace(*in.Description)
	}
	attrs := map[string]any{}
	if in.Attributes != nil {
		attrs = *in.Attributes
	}

	var out Product
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := checkRefs(ctx, tx, brand, in.CategoryID, in.UnitID, color); err != nil {
			return err
		}
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO products (network_id, proposed_by, name, description, brand_id, category_id,
			                      unit_id, color_id, base_price, images, moderation_status, attributes)
			VALUES ($1, $1, $2, $3, $4, $5, $6, $7, $8::numeric, $9, $10, $11) RETURNING id`,
			networkID, strings.TrimSpace(*in.Name), desc, brand, *in.CategoryID, *in.UnitID, color,
			string(price), images, status, attrs).Scan(&id); err != nil {
			return err
		}
		if in.Barcodes != nil {
			if err := setBarcodes(ctx, tx, id, *in.Barcodes); err != nil {
				return err
			}
		}
		var err error
		out, err = getProduct(ctx, tx, id)
		return err
	})
	return out, err
}

func (s *Service) updateProduct(ctx context.Context, id string, in ProductInput, resubmit bool) (Product, error) {
	if err := in.validate(false); err != nil {
		return Product{}, err
	}
	setBrand, brand := nullable(in.BrandID)
	setColor, color := nullable(in.ColorID)
	var price *string
	if in.BasePrice != nil {
		p := string(*in.BasePrice)
		price = &p
	}
	var name, desc *string
	if in.Name != nil {
		n := strings.TrimSpace(*in.Name)
		name = &n
	}
	if in.Description != nil {
		d := strings.TrimSpace(*in.Description)
		desc = &d
	}

	var out Product
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := checkRefs(ctx, tx, brand, in.CategoryID, in.UnitID, color); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			UPDATE products SET
				name        = COALESCE($2, name),
				description = COALESCE($3, description),
				brand_id    = CASE WHEN $4 THEN $5::uuid ELSE brand_id END,
				category_id = COALESCE($6, category_id),
				unit_id     = COALESCE($7, unit_id),
				color_id    = CASE WHEN $8 THEN $9::uuid ELSE color_id END,
				base_price  = COALESCE($10::numeric, base_price),
				images      = COALESCE($11, images),
				is_active   = COALESCE($12, is_active),
				attributes  = COALESCE($14, attributes),
				moderation_status = CASE WHEN $13 THEN 'pending' ELSE moderation_status END,
				rejection_reason  = CASE WHEN $13 THEN '' ELSE rejection_reason END
			WHERE id = $1`,
			id, name, desc, setBrand, brand, in.CategoryID, in.UnitID, setColor, color,
			price, in.Images, in.IsActive, resubmit, in.Attributes)
		if err != nil {
			return err
		}
		if in.Barcodes != nil {
			if err := setBarcodes(ctx, tx, id, *in.Barcodes); err != nil {
				return err
			}
		}
		out, err = getProduct(ctx, tx, id)
		return err
	})
	return out, err
}

func checkRefs(ctx context.Context, q db.Querier, brand, category, unit, color *string) error {
	check := func(table, field string, id *string) error {
		if id == nil {
			return nil
		}
		var active bool
		err := q.QueryRow(ctx, `SELECT is_active FROM `+table+` WHERE id = $1`, *id).Scan(&active)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
			return apperr.Validation(field + ": запись не найдена или отключена")
		}
		return err
	}
	for _, c := range []struct {
		table, field string
		id           *string
	}{{"brands", "brand_id", brand}, {"categories", "category_id", category}, {"units", "unit_id", unit}, {"colors", "color_id", color}} {
		if err := check(c.table, c.field, c.id); err != nil {
			return err
		}
	}
	return nil
}

func setBarcodes(ctx context.Context, q db.Querier, productID string, codes []string) error {
	clean := make([]string, 0, len(codes))
	for _, c := range codes {
		c = strings.TrimSpace(c)
		if c != "" && !slices.Contains(clean, c) {
			clean = append(clean, c)
		}
	}
	if _, err := q.Exec(ctx, `DELETE FROM product_barcodes WHERE product_id = $1`, productID); err != nil {
		return err
	}
	for _, c := range clean {
		var owner string
		err := q.QueryRow(ctx, `
			INSERT INTO product_barcodes (barcode, product_id) VALUES ($1, $2)
			ON CONFLICT (barcode) DO UPDATE SET barcode = EXCLUDED.barcode
			RETURNING product_id`, c, productID).Scan(&owner)
		if db.IsCheckViolation(err) {
			return apperr.Validation("barcodes: неверный штрихкод " + c)
		}
		if err != nil {
			return err
		}
		if owner != productID {
			return apperr.Conflict("barcode_exists", "штрихкод "+c+" уже есть у другого товара").
				WithDetails(map[string]any{"barcode": c, "product_id": owner})
		}
	}
	return nil
}

func getProduct(ctx context.Context, q db.Querier, id string) (Product, error) {
	rows, err := q.Query(ctx, `SELECT `+productCols+productFrom+` WHERE p.id = $1`, id)
	if err != nil {
		return Product{}, err
	}
	p, err := pgx.CollectExactlyOneRow(rows, scanProduct)
	if errors.Is(err, pgx.ErrNoRows) {
		return Product{}, apperr.NotFound("товар не найден")
	}
	return p, err
}

// ProductFilter — параметры поиска товаров.
type ProductFilter struct {
	Query      string
	CategoryID string
	Barcode    string
	Status     string // только для супер-админа
	// BrandID — бренд: uuid или "none" (товары без бренда).
	BrandID string
	// LeafCategoryID — ровно эта категория, без подкатегорий (группа в дереве «бренд → категория»).
	LeafCategoryID string
	// Sort — "name" (по названию); по умолчанию у супер-админа — новые сверху.
	Sort string
	// Photo — with (есть фото) или without (нет фото); только у супер-админа.
	Photo string
	Page  httpx.Page
}

func (f ProductFilter) validate() error {
	if f.CategoryID != "" && !httpx.IsUUID(f.CategoryID) {
		return apperr.Validation("category_id: неверный id")
	}
	if f.Status != "" && f.Status != "pending" && f.Status != "approved" && f.Status != "rejected" {
		return apperr.Validation("status: ожидается pending, approved или rejected")
	}
	if f.BrandID != "" && f.BrandID != "none" && !httpx.IsUUID(f.BrandID) {
		return apperr.Validation("brand_id: неверный id")
	}
	if f.LeafCategoryID != "" && !httpx.IsUUID(f.LeafCategoryID) {
		return apperr.Validation("leaf_category_id: неверный id")
	}
	if f.Sort != "" && f.Sort != "name" {
		return apperr.Validation("sort: ожидается name")
	}
	if f.Photo != "" && f.Photo != "with" && f.Photo != "without" {
		return apperr.Validation("photo: ожидается with или without")
	}
	return nil
}

// groupWhere — бренд ($n: uuid, "none" или пусто) и точная категория ($n+1).
func groupWhere(n int) string {
	return fmt.Sprintf(`
	AND ($%[1]d = '' OR ($%[1]d = 'none' AND p.brand_id IS NULL) OR p.brand_id::text = $%[1]d)
	AND ($%[2]d = '' OR p.category_id::text = $%[2]d)`, n, n+1)
}

// Общие условия фильтра: $1 — строка поиска, $2 — категория (включая
// подкатегории), $3 — штрихкод.
const filterWhere = `
	AND ($1 = '' OR lower(p.name) LIKE '%' || lower($1) || '%'
	     OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $1))
	AND ($2 = '' OR p.category_id IN (
	        WITH RECURSIVE sub AS (
	            SELECT id FROM categories WHERE id::text = $2
	            UNION SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id)
	        SELECT id FROM sub))
	AND ($3 = '' OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode = $3))`

// ------------------------------------------------------------ супер-админ

func (s *Service) AdminListProducts(ctx context.Context, f ProductFilter) ([]Product, error) {
	if err := f.validate(); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT `+productCols+productFrom+`
		WHERE ($4 = '' OR p.moderation_status = $4)`+filterWhere+groupWhere(7)+`
		AND ($9 = '' OR ($9 = 'with') = (cardinality(p.images) > 0))
		ORDER BY `+adminOrder(f.Sort)+` LIMIT $5 OFFSET $6`,
		strings.TrimSpace(f.Query), f.CategoryID, f.Barcode, f.Status, f.Page.Limit, f.Page.Offset, f.BrandID, f.LeafCategoryID, f.Photo)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanProduct)
}

func (s *Service) AdminCreateProduct(ctx context.Context, in ProductInput) (Product, error) {
	return s.createProduct(ctx, nil, in)
}

func (s *Service) AdminGetProduct(ctx context.Context, id string) (Product, error) {
	return getProduct(ctx, s.pool, id)
}

func (s *Service) AdminUpdateProduct(ctx context.Context, id string, in ProductInput) (Product, error) {
	if _, err := getProduct(ctx, s.pool, id); err != nil {
		return Product{}, err
	}
	return s.updateProduct(ctx, id, in, false)
}

// Approve одобряет товар сети: он становится частью общего каталога.
func (s *Service) Approve(ctx context.Context, id string) (Product, error) {
	tag, err := s.pool.Exec(ctx, `
		UPDATE products SET moderation_status = 'approved', rejection_reason = '', network_id = NULL
		WHERE id = $1 AND moderation_status = 'pending'`, id)
	if err != nil {
		return Product{}, err
	}
	if tag.RowsAffected() == 0 {
		return Product{}, apperr.Conflict("not_pending", "товар не ждёт модерации")
	}
	return getProduct(ctx, s.pool, id)
}

func (s *Service) Reject(ctx context.Context, id, reason string) (Product, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return Product{}, apperr.Validation("reason: укажите причину отказа")
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE products SET moderation_status = 'rejected', rejection_reason = $2
		WHERE id = $1 AND moderation_status = 'pending'`, id, reason)
	if err != nil {
		return Product{}, err
	}
	if tag.RowsAffected() == 0 {
		return Product{}, apperr.Conflict("not_pending", "товар не ждёт модерации")
	}
	return getProduct(ctx, s.pool, id)
}

// --------------------------------------------------------- панель магазина

// StoreListProducts — товары для панели магазина. Если storeID задан,
// к каждому товару добавляется действующая цена этого магазина.
func (s *Service) StoreListProducts(ctx context.Context, pr *identity.Principal, f ProductFilter, storeID, priceTypeID string) ([]Product, error) {
	if err := f.validate(); err != nil {
		return nil, err
	}
	if storeID == "" {
		rows, err := s.pool.Query(ctx, `SELECT `+productCols+productFrom+`
			WHERE (p.network_id IS NULL OR p.network_id = $4)`+filterWhere+groupWhere(7)+`
			ORDER BY p.name, p.id LIMIT $5 OFFSET $6`,
			strings.TrimSpace(f.Query), f.CategoryID, f.Barcode, pr.NetworkID, f.Page.Limit, f.Page.Offset, f.BrandID, f.LeafCategoryID)
		if err != nil {
			return nil, err
		}
		return pgx.CollectRows(rows, scanProduct)
	}

	if !httpx.IsUUID(storeID) || !pr.CanAccessStore(storeID) {
		return nil, apperr.NotFound("магазин не найден")
	}
	typeID, err := s.resolvePriceType(ctx, pr.NetworkID, storeID, priceTypeID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT `+productCols+`,
			COALESCE(sp.price, np.price, p.base_price)::text,
			CASE WHEN sp.price IS NOT NULL THEN 'store' WHEN np.price IS NOT NULL THEN 'network' ELSE 'base' END,
			$7::text
		`+productFrom+`
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $7 AND sp.store_id = $8
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $7 AND np.store_id IS NULL
		WHERE (p.network_id IS NULL OR p.network_id = $4)`+filterWhere+groupWhere(9)+`
		ORDER BY p.name, p.id LIMIT $5 OFFSET $6`,
		strings.TrimSpace(f.Query), f.CategoryID, f.Barcode, pr.NetworkID, f.Page.Limit, f.Page.Offset, typeID, storeID, f.BrandID, f.LeafCategoryID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanProductWithPrice)
}

func (s *Service) StoreGetProduct(ctx context.Context, pr *identity.Principal, id string) (Product, error) {
	p, err := getProduct(ctx, s.pool, id)
	if err != nil {
		return Product{}, err
	}
	if p.NetworkID != nil && *p.NetworkID != pr.NetworkID {
		return Product{}, apperr.NotFound("товар не найден")
	}
	return p, nil
}

// StoreCreateProduct — сеть предлагает свой товар, он уходит на модерацию.
func (s *Service) StoreCreateProduct(ctx context.Context, pr *identity.Principal, in ProductInput) (Product, error) {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return Product{}, err
	}
	return s.createProduct(ctx, &pr.NetworkID, in)
}

// StoreUpdateProduct — сеть правит свой товар, пока он не одобрен.
// Правка отклонённого товара снова отправляет его на модерацию.
func (s *Service) StoreUpdateProduct(ctx context.Context, pr *identity.Principal, id string, in ProductInput) (Product, error) {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return Product{}, err
	}
	p, err := s.StoreGetProduct(ctx, pr, id)
	if err != nil {
		return Product{}, err
	}
	if p.NetworkID == nil {
		return Product{}, apperr.Forbidden("товар общего каталога меняет только супер-админ")
	}
	return s.updateProduct(ctx, id, in, p.ModerationStatus == "rejected")
}

// Известные характеристики и допустимые ключи пищевой ценности.
var (
	attributeKeys = map[string]bool{
		"nutrition": true, "composition": true, "shelf_life": true, "storage": true,
		"country": true, "volume": true, "manufacturer": true,
	}
	nutritionKeys = map[string]bool{"kcal": true, "protein": true, "fat": true, "carbs": true}
)

// validateAttributes: известные ключи; строки до 500 символов; nutrition —
// объект с числами на 100 г (kcal, protein, fat, carbs).
func validateAttributes(a map[string]any) error {
	if len(a) > 20 {
		return apperr.Validation("attributes: слишком много характеристик")
	}
	for k, v := range a {
		if !attributeKeys[k] {
			return apperr.Validation("attributes: неизвестная характеристика " + k)
		}
		if k == "nutrition" {
			m, ok := v.(map[string]any)
			if !ok {
				return apperr.Validation("attributes.nutrition: ожидается объект {kcal, protein, fat, carbs}")
			}
			for nk, nv := range m {
				f, ok := nv.(float64)
				if !nutritionKeys[nk] || !ok || f < 0 || f > 10000 {
					return apperr.Validation("attributes.nutrition: числа kcal, protein, fat, carbs на 100 г")
				}
			}
			continue
		}
		str, ok := v.(string)
		if !ok || len([]rune(str)) > 500 {
			return apperr.Validation("attributes." + k + ": строка до 500 символов")
		}
	}
	return nil
}
