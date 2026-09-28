// Package orders — онлайн-заказы: каталог магазина для приложения,
// корзина, оформление с резервом товара, статусы, сборка, доставка,
// отмена с возвратом, таймеры (неоплаченные и непринятые заказы).
package orders

import (
	"context"
	"errors"
	"log/slog"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/notify"
	"github.com/sanedidi/super-market/backend/internal/payments"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

type Config struct {
	PaymentTimeout time.Duration // неоплаченный заказ истекает
	AcceptTimeout  time.Duration // оплаченный заказ не принят — уведомить супер-админа
}

type Service struct {
	pool     *pgxpool.Pool
	delivery *delivery.Service
	payments *payments.Service
	notify   *notify.Notifier
	cfg      Config
	log      *slog.Logger
	now      func() time.Time
}

func NewService(pool *pgxpool.Pool, d *delivery.Service, p *payments.Service, n *notify.Notifier, cfg Config, log *slog.Logger) *Service {
	s := &Service{pool: pool, delivery: d, payments: p, notify: n, cfg: cfg, log: log.With("component", "orders"), now: time.Now}
	p.SetOrders(s)
	return s
}

// ---------------------------------------------------------------- адреса

type Address struct {
	ID        string  `json:"id"`
	Label     string  `json:"label"`
	Address   string  `json:"address"`
	Entrance  string  `json:"entrance"`
	Floor     string  `json:"floor"`
	Apartment string  `json:"apartment"`
	Comment   string  `json:"comment"`
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
}

type AddressInput struct {
	Label     string  `json:"label"`
	Address   string  `json:"address"`
	Entrance  string  `json:"entrance"`
	Floor     string  `json:"floor"`
	Apartment string  `json:"apartment"`
	Comment   string  `json:"comment"`
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
}

const addressSelect = `SELECT id, label, address, entrance, floor, apartment, comment,
	ST_Y(location::geometry), ST_X(location::geometry) FROM customer_addresses`

func (s *Service) ListAddresses(ctx context.Context, p *identity.Principal) ([]Address, error) {
	rows, err := s.pool.Query(ctx, addressSelect+` WHERE user_id = $1 ORDER BY created_at DESC`, p.UserID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Address])
}

func (s *Service) getAddress(ctx context.Context, p *identity.Principal, id string) (Address, error) {
	if !httpx.IsUUID(id) {
		return Address{}, apperr.Validation("address_id: адрес не найден")
	}
	rows, err := s.pool.Query(ctx, addressSelect+` WHERE user_id = $1 AND id = $2`, p.UserID, id)
	if err != nil {
		return Address{}, err
	}
	a, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Address])
	if errors.Is(err, pgx.ErrNoRows) {
		return Address{}, apperr.Validation("address_id: адрес не найден")
	}
	return a, err
}

func validCoords(lat, lng float64) bool {
	return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 && !(lat == 0 && lng == 0)
}

func (s *Service) SaveAddress(ctx context.Context, p *identity.Principal, id string, in AddressInput) (Address, error) {
	if strings.TrimSpace(in.Address) == "" {
		return Address{}, apperr.Validation("address: обязательное поле")
	}
	if !validCoords(in.Lat, in.Lng) {
		return Address{}, apperr.Validation("lat/lng: укажите точку на карте")
	}
	var err error
	if id == "" {
		var n int
		if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM customer_addresses WHERE user_id = $1`, p.UserID).Scan(&n); err != nil {
			return Address{}, err
		}
		if n >= 20 {
			return Address{}, apperr.Validation("не больше 20 адресов")
		}
		err = s.pool.QueryRow(ctx, `
			INSERT INTO customer_addresses (user_id, label, address, entrance, floor, apartment, comment, location)
			VALUES ($1, $2, $3, $4, $5, $6, $7, ST_SetSRID(ST_MakePoint($9, $8), 4326)::geography) RETURNING id`,
			p.UserID, strings.TrimSpace(in.Label), strings.TrimSpace(in.Address), in.Entrance, in.Floor, in.Apartment,
			in.Comment, in.Lat, in.Lng).Scan(&id)
	} else {
		var tag interface{ RowsAffected() int64 }
		tag, err = s.pool.Exec(ctx, `
			UPDATE customer_addresses SET label = $3, address = $4, entrance = $5, floor = $6, apartment = $7, comment = $8,
			       location = ST_SetSRID(ST_MakePoint($10, $9), 4326)::geography
			WHERE id = $1 AND user_id = $2`,
			id, p.UserID, strings.TrimSpace(in.Label), strings.TrimSpace(in.Address), in.Entrance, in.Floor, in.Apartment,
			in.Comment, in.Lat, in.Lng)
		if err == nil && tag.RowsAffected() == 0 {
			return Address{}, apperr.NotFound("адрес не найден")
		}
	}
	if err != nil {
		return Address{}, err
	}
	return s.getAddress(ctx, p, id)
}

func (s *Service) DeleteAddress(ctx context.Context, p *identity.Principal, id string) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM customer_addresses WHERE id = $1 AND user_id = $2`, id, p.UserID)
	if err == nil && tag.RowsAffected() == 0 {
		return apperr.NotFound("адрес не найден")
	}
	return err
}

// ------------------------------------------------- каталог магазина в приложении

type storeInfo struct {
	NetworkID   string
	WarehouseID string
	PriceTypeID string
	Name        string
}

// storeForClient — магазин, открытый для онлайн-заказов.
func (s *Service) storeForClient(ctx context.Context, q db.Querier, storeID string) (storeInfo, error) {
	var st storeInfo
	if !httpx.IsUUID(storeID) {
		return st, apperr.NotFound("магазин не найден")
	}
	err := q.QueryRow(ctx, `
		SELECT s.network_id, s.default_warehouse_id, COALESCE(s.online_price_type_id, pt.id), s.name
		FROM stores s
		JOIN networks n ON n.id = s.network_id
		JOIN price_types pt ON pt.network_id = s.network_id AND pt.is_default
		WHERE s.id = $1 AND s.accepts_online AND s.status = 'active' AND n.status = 'active'
		  AND `+delivery.ActiveSubscriptionSQL, storeID).
		Scan(&st.NetworkID, &st.WarehouseID, &st.PriceTypeID, &st.Name)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, apperr.NotFound("магазин не найден или не принимает заказы")
	}
	return st, err
}

type CatalogProduct struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Description  string   `json:"description"`
	BrandName    *string  `json:"brand_name"`
	CategoryID   string   `json:"category_id"`
	UnitShort    string   `json:"unit_short"`
	IsFractional bool     `json:"is_fractional"`
	Images       []string `json:"images"`
	Price        string   `json:"price"`
	Available    string   `json:"available"`
}

// Товары приложения: общий каталог (одобренные), активные, с остатком на
// складе магазина по умолчанию (за вычетом резервов), по цене приложения.
const catalogSQL = `
	WITH stock AS (
		SELECT b.product_id, sum(b.qty_remaining) AS qty FROM batches b
		WHERE b.warehouse_id = $2 AND b.qty_remaining > 0 GROUP BY b.product_id
	), reserved AS (
		SELECT product_id, sum(qty) AS qty FROM stock_reservations WHERE warehouse_id = $2 GROUP BY product_id
	)
	SELECT p.id, p.name, p.description, br.name, p.category_id, u.short_name, u.is_fractional, p.images,
	       COALESCE(sp.price, np.price, p.base_price)::text,
	       (st.qty - COALESCE(r.qty, 0))::text
	FROM products p
	JOIN stock st ON st.product_id = p.id
	LEFT JOIN reserved r ON r.product_id = p.id
	JOIN units u ON u.id = p.unit_id
	LEFT JOIN brands br ON br.id = p.brand_id
	LEFT JOIN prices sp ON sp.product_id = p.id AND sp.price_type_id = $3 AND sp.store_id = $1
	LEFT JOIN prices np ON np.product_id = p.id AND np.price_type_id = $3 AND np.store_id IS NULL
	WHERE p.network_id IS NULL AND p.is_active AND st.qty - COALESCE(r.qty, 0) > 0`

func (s *Service) StoreCatalog(ctx context.Context, storeID, query, categoryID string, page httpx.Page) ([]CatalogProduct, error) {
	st, err := s.storeForClient(ctx, s.pool, storeID)
	if err != nil {
		return nil, err
	}
	if categoryID != "" && !httpx.IsUUID(categoryID) {
		return nil, apperr.Validation("category_id: неверный id")
	}
	rows, err := s.pool.Query(ctx, catalogSQL+`
		AND ($4 = '' OR lower(p.name) LIKE '%' || lower($4) || '%')
		AND ($5 = '' OR p.category_id IN (
			WITH RECURSIVE sub AS (SELECT id FROM categories WHERE id::text = $5
			                       UNION ALL SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id)
			SELECT id FROM sub))
		ORDER BY p.name LIMIT $6 OFFSET $7`,
		storeID, st.WarehouseID, st.PriceTypeID, strings.TrimSpace(query), categoryID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogProduct])
}

type CatalogCategory struct {
	ID       string  `json:"id"`
	ParentID *string `json:"parent_id"`
	Name     string  `json:"name"`
	Count    int     `json:"products_count"`
}

// StoreCategories — категории, в которых у магазина есть товары в наличии.
func (s *Service) StoreCategories(ctx context.Context, storeID string) ([]CatalogCategory, error) {
	st, err := s.storeForClient(ctx, s.pool, storeID)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		WITH items AS (`+catalogSQL+`)
		SELECT c.id, c.parent_id, c.name, count(*)::int
		FROM items i JOIN categories c ON c.id = i.category_id
		WHERE c.is_active
		GROUP BY c.id, c.parent_id, c.name, c.sort ORDER BY c.sort, c.name`,
		storeID, st.WarehouseID, st.PriceTypeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CatalogCategory])
}

// ------------------------------------------------------------- корзина

type CartItem struct {
	ProductID string    `json:"product_id"`
	Qty       money.Qty `json:"qty"`
}

type CheckoutInput struct {
	StoreID         string     `json:"store_id"`
	AddressID       string     `json:"address_id"`
	Items           []CartItem `json:"items"`
	PaymentProvider string     `json:"payment_provider"`
	Comment         string     `json:"comment"`
}

type PreviewLine struct {
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Qty       string `json:"qty"`
	Price     string `json:"price"`
	Total     string `json:"total"`
	Available string `json:"available"`
	// Проблема со строкой: out_of_stock, not_enough, fractional, unavailable.
	Problem string `json:"problem,omitempty"`
}

type Preview struct {
	StoreID     string         `json:"store_id"`
	Lines       []PreviewLine  `json:"lines"`
	Subtotal    string         `json:"subtotal"`
	Delivery    delivery.Quote `json:"delivery"`
	Total       string         `json:"total"`
	CanOrder    bool           `json:"can_order"`
	Problems    []string       `json:"problems"`
	warehouseID string
	priceTypeID string
	networkID   string
}

// Preview считает корзину: цены, наличие, доставку, минимальную сумму.
func (s *Service) Preview(ctx context.Context, p *identity.Principal, in CheckoutInput) (Preview, error) {
	return s.preview(ctx, s.pool, p, in)
}

func (s *Service) preview(ctx context.Context, q db.Querier, p *identity.Principal, in CheckoutInput) (Preview, error) {
	out := Preview{StoreID: in.StoreID, Problems: []string{}}
	st, err := s.storeForClient(ctx, q, in.StoreID)
	if err != nil {
		return out, err
	}
	out.warehouseID, out.priceTypeID, out.networkID = st.WarehouseID, st.PriceTypeID, st.NetworkID
	addr, err := s.getAddress(ctx, p, in.AddressID)
	if err != nil {
		return out, err
	}
	if len(in.Items) == 0 || len(in.Items) > 200 {
		return out, apperr.Validation("items: от 1 до 200 товаров")
	}

	subtotal := money.D("0")
	seen := map[string]bool{}
	for i, it := range in.Items {
		ls := strconv.Itoa(i + 1)
		if !httpx.IsUUID(it.ProductID) || seen[it.ProductID] {
			return out, apperr.Validation("items: неверный или повторяющийся товар в строке " + ls)
		}
		seen[it.ProductID] = true
		if !it.Qty.Valid() || money.D(string(it.Qty)).Sign() <= 0 {
			return out, apperr.Validation("items: количество должно быть больше нуля в строке " + ls)
		}
		qty := money.D(string(it.Qty))
		line := PreviewLine{ProductID: it.ProductID, Qty: qty.Fixed(3)}
		prod, err := catalog.EffectivePrice(ctx, q, st.NetworkID, in.StoreID, st.PriceTypeID, it.ProductID)
		var global bool
		if err == nil {
			_ = q.QueryRow(ctx, `SELECT network_id IS NULL FROM products WHERE id = $1`, it.ProductID).Scan(&global)
		}
		if err != nil || !prod.IsActive || !global {
			line.Problem = "unavailable"
			out.Lines = append(out.Lines, line)
			continue
		}
		line.Name, line.Price = prod.Name, prod.Price
		avail, err := inventory.Available(ctx, q, st.WarehouseID, it.ProductID)
		if err != nil {
			return out, err
		}
		line.Available = avail
		switch {
		case !prod.IsFractional && qty.Cmp(money.D(qty.Fixed(0))) != 0:
			line.Problem = "fractional"
		case money.D(avail).Sign() <= 0:
			line.Problem = "out_of_stock"
		case qty.Cmp(money.D(avail)) > 0:
			line.Problem = "not_enough"
		}
		total := money.D(prod.Price).Mul(qty).Round2()
		line.Total = total.Money()
		if line.Problem == "" {
			subtotal = subtotal.Add(total)
		}
		out.Lines = append(out.Lines, line)
	}
	out.Subtotal = subtotal.Money()

	quote, err := s.delivery.QuoteFor(ctx, q, in.StoreID, addr.Lat, addr.Lng, out.Subtotal)
	if err != nil {
		var ae *apperr.Error
		if errors.As(err, &ae) {
			out.Problems = append(out.Problems, ae.Code)
			out.Total = out.Subtotal
			return out, nil
		}
		return out, err
	}
	out.Delivery = quote
	out.Total = subtotal.Add(money.D(quote.DeliveryFee)).Money()
	for _, l := range out.Lines {
		if l.Problem != "" {
			out.Problems = append(out.Problems, "items")
			break
		}
	}
	if !quote.IsOpen {
		out.Problems = append(out.Problems, "store_closed")
	}
	if subtotal.Cmp(money.D(quote.MinOrderAmount)) < 0 {
		out.Problems = append(out.Problems, "min_order_amount")
	}
	out.CanOrder = len(out.Problems) == 0
	return out, nil
}

// --------------------------------------------------------------- оформление

type Created struct {
	Order      Order  `json:"order"`
	PaymentURL string `json:"payment_url"`
}

var problemMessages = map[string]string{
	"items":               "часть товаров недоступна или закончилась",
	"store_closed":        "магазин сейчас закрыт",
	"min_order_amount":    "сумма меньше минимального заказа",
	"not_deliverable":     "магазин не доставляет по этому адресу",
	"store_not_accepting": "магазин не принимает онлайн-заказы",
}

// CreateOrder оформляет заказ: пересчитывает корзину, резервирует товар,
// создаёт заказ в статусе «ожидает оплаты» и отдаёт ссылку на оплату.
func (s *Service) CreateOrder(ctx context.Context, p *identity.Principal, in CheckoutInput) (Created, error) {
	if in.PaymentProvider != payments.ProviderPayme && in.PaymentProvider != payments.ProviderClick {
		return Created{}, apperr.Validation("payment_provider: ожидается payme или click")
	}
	if !s.payments.Enabled(in.PaymentProvider) {
		return Created{}, apperr.Validation("payment_provider: способ оплаты временно недоступен")
	}
	var phone string
	if err := s.pool.QueryRow(ctx, `SELECT phone FROM users WHERE id = $1`, p.UserID).Scan(&phone); err != nil {
		return Created{}, err
	}

	var id, total string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Блокируем товары в порядке id, затем пересчитываем корзину уже под блокировкой.
		st, err := s.storeForClient(ctx, tx, in.StoreID)
		if err != nil {
			return err
		}
		ids := make([]string, 0, len(in.Items))
		for _, it := range in.Items {
			if httpx.IsUUID(it.ProductID) {
				ids = append(ids, it.ProductID)
			}
		}
		slices.Sort(ids)
		for _, pid := range ids {
			if err := inventory.LockProduct(ctx, tx, st.WarehouseID, pid); err != nil {
				return err
			}
		}
		pv, err := s.preview(ctx, tx, p, in)
		if err != nil {
			return err
		}
		if !pv.CanOrder {
			msgs := make([]string, 0, len(pv.Problems))
			for _, pr := range pv.Problems {
				msgs = append(msgs, problemMessages[pr])
			}
			return apperr.Conflict("cannot_order", "нельзя оформить заказ: "+strings.Join(msgs, "; ")).
				WithDetails(map[string]any{"problems": pv.Problems, "preview": pv})
		}
		addr, err := s.getAddress(ctx, p, in.AddressID)
		if err != nil {
			return err
		}
		n, err := db.NextNumber(ctx, tx, "orders", pv.networkID, "")
		if err != nil {
			return err
		}
		total = pv.Total
		if err := tx.QueryRow(ctx, `
			INSERT INTO orders (network_id, store_id, warehouse_id, number, customer_id, status, price_type_id,
			                    subtotal, delivery_fee, total, address, entrance, floor, apartment, address_comment,
			                    location, distance_m, customer_phone, comment, payment_provider)
			VALUES ($1, $2, $3, $4, $5, 'awaiting_payment', $6, $7::numeric, $8::numeric, $9::numeric,
			        $10, $11, $12, $13, $14, ST_SetSRID(ST_MakePoint($16, $15), 4326)::geography, $17, $18, $19, $20)
			RETURNING id`,
			pv.networkID, in.StoreID, pv.warehouseID, n, p.UserID, pv.priceTypeID,
			pv.Subtotal, pv.Delivery.DeliveryFee, pv.Total,
			addr.Address, addr.Entrance, addr.Floor, addr.Apartment, addr.Comment, addr.Lat, addr.Lng,
			pv.Delivery.DistanceM, phone, strings.TrimSpace(in.Comment), in.PaymentProvider).Scan(&id); err != nil {
			return err
		}
		for i, l := range pv.Lines {
			if _, err := tx.Exec(ctx, `
				INSERT INTO order_items (order_id, line, product_id, qty, price, total)
				VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6::numeric)`,
				id, i+1, l.ProductID, l.Qty, l.Price, l.Total); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO stock_reservations (order_id, warehouse_id, product_id, qty) VALUES ($1, $2, $3, $4::numeric)`,
				id, pv.warehouseID, l.ProductID, l.Qty); err != nil {
				return err
			}
		}
		return addHistory(ctx, tx, id, StatusAwaitingPayment, "client", "")
	})
	if err != nil {
		return Created{}, err
	}
	url, err := s.payments.CheckoutURL(in.PaymentProvider, id, total)
	if err != nil {
		return Created{}, err
	}
	o, err := s.getOrder(ctx, s.pool, id)
	return Created{Order: o, PaymentURL: url}, err
}

// PaymentURL — ссылка на оплату ещё не оплаченного заказа (если клиент закрыл страницу).
func (s *Service) PaymentURL(ctx context.Context, p *identity.Principal, id string) (string, error) {
	o, err := s.ClientGetOrder(ctx, p, id)
	if err != nil {
		return "", err
	}
	if o.Status != StatusAwaitingPayment {
		return "", apperr.Conflict("not_awaiting_payment", "заказ не ждёт оплаты")
	}
	return s.payments.CheckoutURL(o.PaymentProvider, o.ID, o.Total)
}
