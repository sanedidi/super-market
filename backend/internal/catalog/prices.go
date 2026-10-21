package catalog

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// ------------------------------------------------------------- типы цен

type PriceType struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	IsDefault bool      `json:"is_default"`
	IsActive  bool      `json:"is_active"`
	CreatedAt time.Time `json:"created_at"`
}

// defaultPriceTypeName — название создаётся на языке того, кто создаёт сеть.
var defaultPriceTypeName = i18n.Text{RU: "Розничная", UZ: "Chakana"}

// CreateDefaultPriceType создаёт тип «Розничная» для новой сети.
// Вызывается из tenant в транзакции создания сети.
func CreateDefaultPriceType(ctx context.Context, q db.Querier, networkID string) error {
	_, err := q.Exec(ctx, `INSERT INTO price_types (network_id, name, is_default) VALUES ($1, $2, true)`,
		networkID, defaultPriceTypeName.Ctx(ctx))
	return err
}

func (s *Service) ListPriceTypes(ctx context.Context, pr *identity.Principal) ([]PriceType, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, name, is_default, is_active, created_at FROM price_types
		WHERE network_id = $1 ORDER BY is_default DESC, name`, pr.NetworkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[PriceType])
}

type PriceTypeInput struct {
	Name      *string `json:"name"`
	IsDefault *bool   `json:"is_default"`
	IsActive  *bool   `json:"is_active"`
}

func (s *Service) CreatePriceType(ctx context.Context, pr *identity.Principal, in PriceTypeInput) (PriceType, error) {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return PriceType{}, err
	}
	if in.Name == nil || strings.TrimSpace(*in.Name) == "" {
		return PriceType{}, apperr.Validation("name: обязательное поле").Uz("name: majburiy maydon")
	}
	if in.IsDefault != nil && *in.IsDefault {
		return PriceType{}, apperr.Validation("is_default: назначается изменением существующего типа").Uz("is_default: mavjud turni tahrirlash orqali belgilanadi")
	}
	var id string
	err := s.pool.QueryRow(ctx, `INSERT INTO price_types (network_id, name) VALUES ($1, $2) RETURNING id`,
		pr.NetworkID, strings.TrimSpace(*in.Name)).Scan(&id)
	if db.IsUniqueViolation(err, "") {
		return PriceType{}, apperr.Conflict("already_exists", "тип цены с таким названием уже есть").Uz("bunday nomli narx turi allaqachon bor")
	}
	if err != nil {
		return PriceType{}, err
	}
	return s.getPriceType(ctx, s.pool, pr.NetworkID, id)
}

func (s *Service) UpdatePriceType(ctx context.Context, pr *identity.Principal, id string, in PriceTypeInput) (PriceType, error) {
	if err := pr.Require(identity.PermCatalogManage); err != nil {
		return PriceType{}, err
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return PriceType{}, apperr.Validation("name: не может быть пустым").Uz("name: boʻsh boʻlishi mumkin emas")
	}
	if in.IsDefault != nil && !*in.IsDefault {
		return PriceType{}, apperr.Validation("is_default: чтобы снять, назначьте по умолчанию другой тип").Uz("is_default: olib tashlash uchun boshqa turni asosiy qiling")
	}
	var out PriceType
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		cur, err := s.getPriceType(ctx, tx, pr.NetworkID, id)
		if err != nil {
			return err
		}
		makeDefault := in.IsDefault != nil && *in.IsDefault
		if in.IsActive != nil && !*in.IsActive && (cur.IsDefault || makeDefault) {
			return apperr.Conflict("default_price_type", "тип по умолчанию нельзя отключить").Uz("asosiy turni oʻchirib qoʻyib boʻlmaydi")
		}
		if makeDefault && !cur.IsDefault {
			if _, err := tx.Exec(ctx, `UPDATE price_types SET is_default = false WHERE network_id = $1 AND is_default`, pr.NetworkID); err != nil {
				return err
			}
		}
		var name *string
		if in.Name != nil {
			n := strings.TrimSpace(*in.Name)
			name = &n
		}
		_, err = tx.Exec(ctx, `
			UPDATE price_types SET name = COALESCE($3, name), is_active = COALESCE($4, is_active),
			       is_default = is_default OR $5
			WHERE id = $1 AND network_id = $2`, id, pr.NetworkID, name, in.IsActive, makeDefault)
		if db.IsUniqueViolation(err, "") {
			return apperr.Conflict("already_exists", "тип цены с таким названием уже есть").Uz("bunday nomli narx turi allaqachon bor")
		}
		if err != nil {
			return err
		}
		out, err = s.getPriceType(ctx, tx, pr.NetworkID, id)
		return err
	})
	return out, err
}

func (s *Service) getPriceType(ctx context.Context, q db.Querier, networkID, id string) (PriceType, error) {
	if !httpx.IsUUID(id) {
		return PriceType{}, apperr.NotFound("тип цены не найден").Uz("narx turi topilmadi")
	}
	rows, err := q.Query(ctx, `SELECT id, name, is_default, is_active, created_at FROM price_types
		WHERE id = $1 AND network_id = $2`, id, networkID)
	if err != nil {
		return PriceType{}, err
	}
	pt, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[PriceType])
	if errors.Is(err, pgx.ErrNoRows) {
		return PriceType{}, apperr.NotFound("тип цены не найден").Uz("narx turi topilmadi")
	}
	return pt, err
}

// resolvePriceType: явно указанный тип → тип магазина для приложения → тип по умолчанию.
func (s *Service) resolvePriceType(ctx context.Context, networkID, storeID, explicit string) (string, error) {
	if explicit != "" {
		pt, err := s.getPriceType(ctx, s.pool, networkID, explicit)
		return pt.ID, err
	}
	var id string
	err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(s.online_price_type_id, pt.id)
		FROM stores s
		JOIN price_types pt ON pt.network_id = s.network_id AND pt.is_default
		WHERE s.id = $1 AND s.network_id = $2`, storeID, networkID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return id, err
}

// -------------------------------------------------- документы «Установка цен»

type PriceDocItem struct {
	ProductID     string  `json:"product_id"`
	ProductName   string  `json:"product_name"`
	NewPrice      string  `json:"new_price"`
	PreviousPrice *string `json:"previous_price"`
	// Действующая сейчас цена на уровне документа (магазин → сеть → базовая).
	CurrentPrice string `json:"current_price"`
}

type PriceDocument struct {
	ID            string         `json:"id"`
	Number        int64          `json:"number"`
	PriceTypeID   string         `json:"price_type_id"`
	PriceTypeName string         `json:"price_type_name"`
	StoreID       *string        `json:"store_id"`
	StoreName     *string        `json:"store_name"`
	Status        string         `json:"status"`
	Note          string         `json:"note"`
	CreatedBy     string         `json:"created_by"`
	PostedAt      *time.Time     `json:"posted_at"`
	CreatedAt     time.Time      `json:"created_at"`
	ItemsCount    int            `json:"items_count"`
	Items         []PriceDocItem `json:"items,omitempty"`
}

type PriceDocInput struct {
	PriceTypeID *string `json:"price_type_id"`
	StoreID     *string `json:"store_id"` // null — цены всей сети
	Note        *string `json:"note"`
	Items       *[]struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	} `json:"items"`
}

const priceDocSelect = `
	SELECT d.id, d.number, d.price_type_id, pt.name, d.store_id, s.name, d.status, d.note,
	       e.full_name, d.posted_at, d.created_at,
	       (SELECT count(*) FROM price_document_items i WHERE i.document_id = d.id)::int
	FROM price_documents d
	JOIN price_types pt ON pt.id = d.price_type_id
	JOIN employees e    ON e.id = d.created_by
	LEFT JOIN stores s  ON s.id = d.store_id`

func scanPriceDoc(row pgx.CollectableRow) (PriceDocument, error) {
	var d PriceDocument
	err := row.Scan(&d.ID, &d.Number, &d.PriceTypeID, &d.PriceTypeName, &d.StoreID, &d.StoreName,
		&d.Status, &d.Note, &d.CreatedBy, &d.PostedAt, &d.CreatedAt, &d.ItemsCount)
	return d, err
}

// Документ по всей сети доступен только тем, кто видит все магазины.
func canUseDocStore(pr *identity.Principal, storeID *string) bool {
	if storeID == nil {
		return pr.SeesAllStores()
	}
	return pr.CanAccessStore(*storeID)
}

func (s *Service) ListPriceDocs(ctx context.Context, pr *identity.Principal, page httpx.Page) ([]PriceDocument, error) {
	rows, err := s.pool.Query(ctx, priceDocSelect+`
		WHERE d.network_id = $1 AND ($2 OR d.store_id = ANY($3::uuid[]))
		ORDER BY d.number DESC LIMIT $4 OFFSET $5`,
		pr.NetworkID, pr.SeesAllStores(), pr.StoreIDs, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanPriceDoc)
}

func (s *Service) GetPriceDoc(ctx context.Context, pr *identity.Principal, id string) (PriceDocument, error) {
	return s.getPriceDoc(ctx, s.pool, pr, id)
}

func (s *Service) getPriceDoc(ctx context.Context, q db.Querier, pr *identity.Principal, id string) (PriceDocument, error) {
	rows, err := q.Query(ctx, priceDocSelect+` WHERE d.network_id = $1 AND d.id = $2`, pr.NetworkID, id)
	if err != nil {
		return PriceDocument{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanPriceDoc)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !canUseDocStore(pr, d.StoreID)) {
		return PriceDocument{}, apperr.NotFound("документ не найден").Uz("hujjat topilmadi")
	}
	if err != nil {
		return PriceDocument{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT i.product_id, loc(p.name, p.name_uz), i.new_price::text, i.previous_price::text,
		       COALESCE(sp.price, np.price, p.base_price)::text
		FROM price_document_items i
		JOIN products p ON p.id = i.product_id
		JOIN price_documents d ON d.id = i.document_id
		LEFT JOIN prices sp ON d.store_id IS NOT NULL AND sp.product_id = i.product_id
		                   AND sp.price_type_id = d.price_type_id AND sp.store_id = d.store_id
		LEFT JOIN prices np ON np.product_id = i.product_id AND np.price_type_id = d.price_type_id AND np.store_id IS NULL
		WHERE i.document_id = $1 ORDER BY loc(p.name, p.name_uz)`, id)
	if err != nil {
		return PriceDocument{}, err
	}
	d.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PriceDocItem])
	return d, err
}

// CreatePriceDoc создаёт черновик документа.
func (s *Service) CreatePriceDoc(ctx context.Context, pr *identity.Principal, in PriceDocInput) (PriceDocument, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return PriceDocument{}, err
	}
	if in.PriceTypeID == nil {
		return PriceDocument{}, apperr.Validation("price_type_id: обязательное поле").Uz("price_type_id: majburiy maydon")
	}
	if in.StoreID != nil && !httpx.IsUUID(*in.StoreID) {
		return PriceDocument{}, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	if !canUseDocStore(pr, in.StoreID) {
		return PriceDocument{}, apperr.Forbidden("нет доступа к магазину или ко всей сети").Uz("doʻkonga yoki butun tarmoqqa ruxsat yoʻq")
	}
	note := ""
	if in.Note != nil {
		note = strings.TrimSpace(*in.Note)
	}

	var out PriceDocument
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		pt, err := s.getPriceType(ctx, tx, pr.NetworkID, *in.PriceTypeID)
		if err != nil {
			return apperr.Validation("price_type_id: тип цены не найден").Uz("price_type_id: narx turi topilmadi")
		}
		if !pt.IsActive {
			return apperr.Validation("price_type_id: тип цены отключён").Uz("price_type_id: narx turi oʻchirilgan")
		}
		// Номер документа — следующий в сети. Блокировка сети исключает дубли.
		if _, err := tx.Exec(ctx, `SELECT 1 FROM networks WHERE id = $1 FOR UPDATE`, pr.NetworkID); err != nil {
			return err
		}
		var id string
		err = tx.QueryRow(ctx, `
			INSERT INTO price_documents (network_id, number, price_type_id, store_id, note, created_by)
			VALUES ($1, (SELECT COALESCE(max(number), 0) + 1 FROM price_documents WHERE network_id = $1),
			        $2, $3, $4, $5)
			RETURNING id`, pr.NetworkID, pt.ID, in.StoreID, note, pr.EmployeeID).Scan(&id)
		if db.IsForeignKeyViolation(err) {
			return apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
		}
		if err != nil {
			return err
		}
		if in.Items != nil {
			if err := s.replaceItems(ctx, tx, pr, id, in); err != nil {
				return err
			}
		}
		out, err = s.getPriceDoc(ctx, tx, pr, id)
		return err
	})
	return out, err
}

// UpdatePriceDoc меняет черновик: заметку и/или весь список строк.
func (s *Service) UpdatePriceDoc(ctx context.Context, pr *identity.Principal, id string, in PriceDocInput) (PriceDocument, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return PriceDocument{}, err
	}
	if in.PriceTypeID != nil || in.StoreID != nil {
		return PriceDocument{}, apperr.Validation("тип цены и магазин документа не меняются — создайте новый документ").Uz("hujjatning narx turi va doʻkoni oʻzgarmaydi — yangi hujjat yarating")
	}
	var out PriceDocument
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := s.lockDraft(ctx, tx, pr, id); err != nil {
			return err
		}
		if in.Note != nil {
			if _, err := tx.Exec(ctx, `UPDATE price_documents SET note = $2 WHERE id = $1`, id, strings.TrimSpace(*in.Note)); err != nil {
				return err
			}
		}
		if in.Items != nil {
			if err := s.replaceItems(ctx, tx, pr, id, in); err != nil {
				return err
			}
		}
		var err error
		out, err = s.getPriceDoc(ctx, tx, pr, id)
		return err
	})
	return out, err
}

func (s *Service) lockDraft(ctx context.Context, tx pgx.Tx, pr *identity.Principal, id string) error {
	var status string
	var storeID *string
	err := tx.QueryRow(ctx, `SELECT status, store_id FROM price_documents WHERE id = $1 AND network_id = $2 FOR UPDATE`,
		id, pr.NetworkID).Scan(&status, &storeID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !canUseDocStore(pr, storeID)) {
		return apperr.NotFound("документ не найден").Uz("hujjat topilmadi")
	}
	if err != nil {
		return err
	}
	if status != "draft" {
		return apperr.Conflict("document_posted", "документ уже проведён").Uz("hujjat allaqachon oʻtkazilgan")
	}
	return nil
}

func (s *Service) replaceItems(ctx context.Context, tx pgx.Tx, pr *identity.Principal, docID string, in PriceDocInput) error {
	if _, err := tx.Exec(ctx, `DELETE FROM price_document_items WHERE document_id = $1`, docID); err != nil {
		return err
	}
	seen := map[string]bool{}
	for i, it := range *in.Items {
		if !httpx.IsUUID(it.ProductID) {
			return apperr.Validation("items: неверный product_id в строке " + strconv.Itoa(i+1)).Uz("items: " + strconv.Itoa(i+1) + "-qatorda product_id notoʻgʻri")
		}
		if seen[it.ProductID] {
			return apperr.Validation("items: товар повторяется в строке " + strconv.Itoa(i+1)).Uz("items: " + strconv.Itoa(i+1) + "-qatorda mahsulot takrorlanadi")
		}
		seen[it.ProductID] = true
		if !it.NewPrice.Valid() {
			return apperr.Validation("items: не указана цена в строке " + strconv.Itoa(i+1)).Uz("items: " + strconv.Itoa(i+1) + "-qatorda narx koʻrsatilmagan")
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO price_document_items (document_id, product_id, new_price)
			SELECT $1, p.id, $3::numeric FROM products p
			WHERE p.id = $2 AND (p.network_id IS NULL OR p.network_id = $4)`,
			docID, it.ProductID, string(it.NewPrice), pr.NetworkID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.Validation("items: товар не найден в строке " + strconv.Itoa(i+1)).Uz("items: " + strconv.Itoa(i+1) + "-qatorda mahsulot topilmadi")
		}
	}
	return nil
}

// PostPriceDoc проводит документ: записывает цены и запоминает прежние.
func (s *Service) PostPriceDoc(ctx context.Context, pr *identity.Principal, id string) (PriceDocument, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return PriceDocument{}, err
	}
	var out PriceDocument
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := s.lockDraft(ctx, tx, pr, id); err != nil {
			return err
		}
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM price_document_items WHERE document_id = $1`, id).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return apperr.Validation("в документе нет строк").Uz("hujjatda qator yoʻq")
		}
		// Прежняя цена на уровне документа (сеть или магазин).
		if _, err := tx.Exec(ctx, `
			UPDATE price_document_items i SET previous_price = pr.price
			FROM price_documents d, prices pr
			WHERE i.document_id = $1 AND d.id = i.document_id
			  AND pr.product_id = i.product_id AND pr.price_type_id = d.price_type_id
			  AND pr.store_id IS NOT DISTINCT FROM d.store_id`, id); err != nil {
			return err
		}
		// Новые цены: сначала обновляем существующие, потом добавляем недостающие.
		if _, err := tx.Exec(ctx, `
			UPDATE prices pr SET price = i.new_price, updated_at = now()
			FROM price_document_items i, price_documents d
			WHERE i.document_id = $1 AND d.id = i.document_id
			  AND pr.product_id = i.product_id AND pr.price_type_id = d.price_type_id
			  AND pr.store_id IS NOT DISTINCT FROM d.store_id`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO prices (network_id, price_type_id, store_id, product_id, price)
			SELECT d.network_id, d.price_type_id, d.store_id, i.product_id, i.new_price
			FROM price_document_items i JOIN price_documents d ON d.id = i.document_id
			WHERE i.document_id = $1 AND NOT EXISTS (
				SELECT 1 FROM prices pr WHERE pr.product_id = i.product_id
				  AND pr.price_type_id = d.price_type_id AND pr.store_id IS NOT DISTINCT FROM d.store_id)`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE price_documents SET status = 'posted', posted_by = $2, posted_at = now() WHERE id = $1`,
			id, pr.EmployeeID); err != nil {
			return err
		}
		var err error
		out, err = s.getPriceDoc(ctx, tx, pr, id)
		return err
	})
	return out, err
}

// ResolvePriceType — тип цены магазина: явно указанный, тип магазина для
// приложения или тип по умолчанию.
func (s *Service) ResolvePriceType(ctx context.Context, networkID, storeID, explicit string) (string, error) {
	return s.resolvePriceType(ctx, networkID, storeID, explicit)
}

// SetStorePrices создаёт и сразу проводит «Установку цен» магазина — так
// цена веса группы вариаций попадает в историю цен, как любая другая.
func (s *Service) SetStorePrices(ctx context.Context, pr *identity.Principal, storeID, priceTypeID, note string,
	prices map[string]money.Amount) (PriceDocument, error) {
	ids := make([]string, 0, len(prices))
	for id := range prices {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]struct {
		ProductID string       `json:"product_id"`
		NewPrice  money.Amount `json:"new_price"`
	}, len(ids))
	for i, id := range ids {
		items[i].ProductID, items[i].NewPrice = id, prices[id]
	}
	doc, err := s.CreatePriceDoc(ctx, pr, PriceDocInput{PriceTypeID: &priceTypeID, StoreID: &storeID, Note: &note, Items: &items})
	if err != nil {
		return doc, err
	}
	return s.PostPriceDoc(ctx, pr, doc.ID)
}

// DefaultPriceType — тип цены по умолчанию в сети.
func DefaultPriceType(ctx context.Context, q db.Querier, networkID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `SELECT id FROM price_types WHERE network_id = $1 AND is_default`, networkID).Scan(&id)
	return id, err
}

// CheckPriceType — тип цены есть в сети и активен.
func CheckPriceType(ctx context.Context, q db.Querier, networkID, id string) error {
	var active bool
	err := q.QueryRow(ctx, `SELECT is_active FROM price_types WHERE id = $1 AND network_id = $2`, id, networkID).Scan(&active)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
		return apperr.Validation("price_type_id: тип цены не найден или отключён").Uz("price_type_id: narx turi topilmadi yoki oʻchirilgan")
	}
	return err
}

// ProductForSale — товар, доступный сети, с действующей ценой в магазине.
type ProductForSale struct {
	ID           string
	Name         string
	IsFractional bool
	IsActive     bool
	Price        string
	// Kind — goods (товар), dish (блюдо кафе), prep (заготовка).
	Kind string
}

// EffectivePrice: цена магазина → цена сети → базовая цена товара.
func EffectivePrice(ctx context.Context, q db.Querier, networkID, storeID, priceTypeID, productID string) (ProductForSale, error) {
	var p ProductForSale
	err := q.QueryRow(ctx, `
		SELECT p.id, loc(p.name, p.name_uz), u.is_fractional, p.is_active,
		       COALESCE(sp.price, np.price, p.base_price)::text, p.kind
		FROM products p
		JOIN units u ON u.id = p.unit_id
		LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $2
		LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL
		WHERE p.id = $4 AND (p.network_id IS NULL OR p.network_id = $1)`,
		networkID, storeID, priceTypeID, productID).Scan(&p.ID, &p.Name, &p.IsFractional, &p.IsActive, &p.Price, &p.Kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.Validation("товар не найден").Uz("mahsulot topilmadi")
	}
	return p, err
}
