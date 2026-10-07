package catalog

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Акции для приложения: на время действия товар продаётся онлайн по
// акционной цене. Кассовые цены не меняются.

// PromoPriceExpr — SQL-выражение: самая низкая действующая акционная цена
// товара p.id в магазине storeArg (например, "$1"), или NULL.
func PromoPriceExpr(storeArg string) string {
	return `(SELECT min(pi.price) FROM promotion_items pi
		JOIN promotions pr ON pr.id = pi.promotion_id
		WHERE pi.product_id = p.id AND pr.is_active AND now() >= pr.starts_at AND now() < pr.ends_at
		  AND pr.network_id = (SELECT network_id FROM stores WHERE id = ` + storeArg + `)
		  AND (cardinality(pr.store_ids) = 0 OR ` + storeArg + `::uuid = ANY (pr.store_ids)))`
}

// OnlinePrice — цена товара в приложении: обычная цена магазина и,
// если действует акция и она ниже, акционная. RegularPrice — цена до скидки.
type OnlinePriceResult struct {
	ProductForSale
	RegularPrice string
	Discounted   bool
}

func OnlinePrice(ctx context.Context, q db.Querier, networkID, storeID, priceTypeID, productID string) (OnlinePriceResult, error) {
	var out OnlinePriceResult
	p, err := EffectivePrice(ctx, q, networkID, storeID, priceTypeID, productID)
	if err != nil {
		return out, err
	}
	out.ProductForSale = p
	out.RegularPrice = p.Price
	var promo *string
	if err := q.QueryRow(ctx, `SELECT `+PromoPriceExpr("$1")+`::text FROM products p WHERE p.id = $2`,
		storeID, productID).Scan(&promo); err != nil {
		return out, err
	}
	if promo != nil && money.D(*promo).Cmp(money.D(p.Price)) < 0 {
		out.Price = money.D(*promo).Money()
		out.Discounted = true
	}
	return out, nil
}

type PromotionItem struct {
	ProductID    string `json:"product_id"`
	ProductName  string `json:"product_name"`
	Price        string `json:"price"`
	RegularPrice string `json:"regular_price"` // базовая цена товара — для подсказки в форме
}

type Promotion struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	StartsAt  time.Time       `json:"starts_at"`
	EndsAt    time.Time       `json:"ends_at"`
	StoreIDs  []string        `json:"store_ids"`
	IsActive  bool            `json:"is_active"`
	Status    string          `json:"status"` // scheduled | running | ended | disabled
	ItemCount int             `json:"item_count"`
	CreatedAt time.Time       `json:"created_at"`
	Items     []PromotionItem `json:"items,omitempty"`
}

type PromotionItemInput struct {
	ProductID string       `json:"product_id"`
	Price     money.Amount `json:"price"`
}

type PromotionInput struct {
	Name     *string               `json:"name"`
	StartsAt *time.Time            `json:"starts_at"`
	EndsAt   *time.Time            `json:"ends_at"`
	StoreIDs *[]string             `json:"store_ids"`
	IsActive *bool                 `json:"is_active"`
	Items    *[]PromotionItemInput `json:"items"`
}

const promotionSelect = `
	SELECT pr.id, pr.name, pr.starts_at, pr.ends_at, pr.store_ids::text[] AS store_ids, pr.is_active,
	       CASE WHEN NOT pr.is_active THEN 'disabled'
	            WHEN now() < pr.starts_at THEN 'scheduled'
	            WHEN now() >= pr.ends_at THEN 'ended'
	            ELSE 'running' END AS status,
	       (SELECT count(*)::int FROM promotion_items pi WHERE pi.promotion_id = pr.id) AS item_count,
	       pr.created_at
	FROM promotions pr`

func scanPromotion(row pgx.CollectableRow) (Promotion, error) {
	var p Promotion
	err := row.Scan(&p.ID, &p.Name, &p.StartsAt, &p.EndsAt, &p.StoreIDs, &p.IsActive, &p.Status, &p.ItemCount, &p.CreatedAt)
	return p, err
}

// ListPromotions — акции сети; status: running | scheduled | ended | пусто — все.
func (s *Service) ListPromotions(ctx context.Context, pr *identity.Principal, status string, page httpx.Page) ([]Promotion, error) {
	rows, err := s.pool.Query(ctx, `SELECT * FROM (`+promotionSelect+` WHERE pr.network_id = $1) x
		WHERE ($2 = '' OR x.status = $2)
		ORDER BY x.starts_at DESC LIMIT $3 OFFSET $4`, pr.NetworkID, status, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanPromotion)
}

func (s *Service) GetPromotion(ctx context.Context, pr *identity.Principal, id string) (Promotion, error) {
	return getPromotion(ctx, s.pool, pr.NetworkID, id)
}

func getPromotion(ctx context.Context, q db.Querier, networkID, id string) (Promotion, error) {
	rows, err := q.Query(ctx, promotionSelect+` WHERE pr.network_id = $1 AND pr.id = $2`, networkID, id)
	if err != nil {
		return Promotion{}, err
	}
	p, err := pgx.CollectExactlyOneRow(rows, scanPromotion)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.NotFound("акция не найдена").Uz("aksiya topilmadi")
	}
	if err != nil {
		return p, err
	}
	rows, err = q.Query(ctx, `
		SELECT pi.product_id, loc(p.name, p.name_uz), pi.price::text, p.base_price::text
		FROM promotion_items pi JOIN products p ON p.id = pi.product_id
		WHERE pi.promotion_id = $1 ORDER BY loc(p.name, p.name_uz)`, id)
	if err != nil {
		return p, err
	}
	p.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PromotionItem])
	return p, err
}

func (in PromotionInput) validate(create bool) error {
	if create && (in.Name == nil || in.StartsAt == nil || in.EndsAt == nil) {
		return apperr.Validation("name, starts_at и ends_at: обязательные поля").Uz("name, starts_at va ends_at: majburiy maydonlar")
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return apperr.Validation("name: не может быть пустым").Uz("name: boʻsh boʻlishi mumkin emas")
	}
	if in.StoreIDs != nil {
		for _, id := range *in.StoreIDs {
			if !httpx.IsUUID(id) {
				return apperr.Validation("store_ids: магазин не найден").Uz("store_ids: doʻkon topilmadi")
			}
		}
	}
	if in.Items != nil {
		if len(*in.Items) > 1000 {
			return apperr.Validation("items: не больше 1000 товаров в акции").Uz("items: aksiyada koʻpi bilan 1000 ta mahsulot")
		}
		seen := map[string]bool{}
		for _, it := range *in.Items {
			if !httpx.IsUUID(it.ProductID) || seen[it.ProductID] {
				return apperr.Validation("items: неверный или повторяющийся товар").Uz("items: mahsulot notoʻgʻri yoki takrorlangan")
			}
			seen[it.ProductID] = true
			if !it.Price.Valid() || money.D(string(it.Price)).Sign() <= 0 {
				return apperr.Validation("items: цена должна быть больше нуля").Uz("items: narx noldan katta boʻlishi kerak")
			}
		}
	}
	return nil
}

func (s *Service) CreatePromotion(ctx context.Context, pr *identity.Principal, in PromotionInput) (Promotion, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return Promotion{}, err
	}
	if err := in.validate(true); err != nil {
		return Promotion{}, err
	}
	var out Promotion
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		stores := []string{}
		if in.StoreIDs != nil {
			stores = *in.StoreIDs
		}
		if err := checkPromoStores(ctx, tx, pr, stores); err != nil {
			return err
		}
		active := true
		if in.IsActive != nil {
			active = *in.IsActive
		}
		var id string
		err := tx.QueryRow(ctx, `
			INSERT INTO promotions (network_id, name, starts_at, ends_at, store_ids, is_active, created_by)
			VALUES ($1, $2, $3, $4, $5::uuid[], $6, $7) RETURNING id`,
			pr.NetworkID, strings.TrimSpace(*in.Name), *in.StartsAt, *in.EndsAt, stores, active, pr.UserID).Scan(&id)
		if db.IsCheckViolation(err) {
			return apperr.Validation("ends_at: окончание акции должно быть позже начала").Uz("ends_at: aksiya tugashi boshlanishidan keyin boʻlishi kerak")
		}
		if err != nil {
			return err
		}
		if in.Items != nil {
			if err := setPromoItems(ctx, tx, pr.NetworkID, id, *in.Items); err != nil {
				return err
			}
		}
		out, err = getPromotion(ctx, tx, pr.NetworkID, id)
		return err
	})
	return out, err
}

func (s *Service) UpdatePromotion(ctx context.Context, pr *identity.Principal, id string, in PromotionInput) (Promotion, error) {
	if err := pr.Require(identity.PermPricesManage); err != nil {
		return Promotion{}, err
	}
	if err := in.validate(false); err != nil {
		return Promotion{}, err
	}
	var out Promotion
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if in.StoreIDs != nil {
			if err := checkPromoStores(ctx, tx, pr, *in.StoreIDs); err != nil {
				return err
			}
		}
		var name *string
		if in.Name != nil {
			n := strings.TrimSpace(*in.Name)
			name = &n
		}
		tag, err := tx.Exec(ctx, `
			UPDATE promotions SET
				name = COALESCE($3, name),
				starts_at = COALESCE($4, starts_at),
				ends_at = COALESCE($5, ends_at),
				store_ids = COALESCE($6::uuid[], store_ids),
				is_active = COALESCE($7, is_active),
				updated_at = now()
			WHERE id = $1 AND network_id = $2`,
			id, pr.NetworkID, name, in.StartsAt, in.EndsAt, in.StoreIDs, in.IsActive)
		if db.IsCheckViolation(err) {
			return apperr.Validation("ends_at: окончание акции должно быть позже начала").Uz("ends_at: aksiya tugashi boshlanishidan keyin boʻlishi kerak")
		}
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("акция не найдена").Uz("aksiya topilmadi")
		}
		if in.Items != nil {
			if err := setPromoItems(ctx, tx, pr.NetworkID, id, *in.Items); err != nil {
				return err
			}
		}
		out, err = getPromotion(ctx, tx, pr.NetworkID, id)
		return err
	})
	return out, err
}

// checkPromoStores: магазины своей сети и доступные сотруднику. Сотрудник не
// всех магазинов не может создать акцию «на все магазины».
func checkPromoStores(ctx context.Context, q db.Querier, pr *identity.Principal, ids []string) error {
	if len(ids) == 0 {
		if !pr.SeesAllStores() {
			return apperr.Validation("store_ids: выберите свои магазины").Uz("store_ids: oʻz doʻkonlaringizni tanlang")
		}
		return nil
	}
	for _, id := range ids {
		if !pr.CanAccessStore(id) {
			return apperr.Validation("store_ids: магазин не найден").Uz("store_ids: doʻkon topilmadi")
		}
	}
	var n int
	if err := q.QueryRow(ctx, `SELECT count(*) FROM stores WHERE network_id = $1 AND id = ANY($2::uuid[])`,
		pr.NetworkID, ids).Scan(&n); err != nil {
		return err
	}
	if n != len(ids) {
		return apperr.Validation("store_ids: магазин не найден").Uz("store_ids: doʻkon topilmadi")
	}
	return nil
}

func setPromoItems(ctx context.Context, tx pgx.Tx, networkID, promoID string, items []PromotionItemInput) error {
	if _, err := tx.Exec(ctx, `DELETE FROM promotion_items WHERE promotion_id = $1`, promoID); err != nil {
		return err
	}
	for _, it := range items {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM products WHERE id = $1 AND is_active
			AND (network_id IS NULL AND moderation_status = 'approved' OR network_id = $2))`,
			it.ProductID, networkID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return apperr.Validation("items: товар не найден или не активен").Uz("items: mahsulot topilmadi yoki faol emas")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO promotion_items (promotion_id, product_id, price) VALUES ($1, $2, $3::numeric)`,
			promoID, it.ProductID, string(it.Price)); err != nil {
			return err
		}
	}
	return nil
}
