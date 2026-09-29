package orders

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/payments"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Статусы заказа.
const (
	StatusAwaitingPayment = "awaiting_payment"
	StatusPaid            = "paid"
	StatusAccepted        = "accepted"
	StatusPicking         = "picking"
	StatusPicked          = "picked"
	StatusDelivering      = "delivering"
	StatusDelivered       = "delivered"
	StatusCancelled       = "cancelled"
	StatusExpired         = "expired"
)

var statusTitles = map[string]string{
	StatusAwaitingPayment: "Ожидает оплаты", StatusPaid: "Оплачен", StatusAccepted: "Принят",
	StatusPicking: "Собирается", StatusPicked: "Собран", StatusDelivering: "В пути",
	StatusDelivered: "Доставлен", StatusCancelled: "Отменён", StatusExpired: "Не оплачен",
}

type OrderItem struct {
	Line               int     `json:"line"`
	ProductID          string  `json:"product_id"`
	ProductName        string  `json:"product_name"`
	UnitShort          string  `json:"unit_short"`
	Qty                string  `json:"qty"`
	Price              string  `json:"price"`
	Total              string  `json:"total"`
	PickedWarehouseID  *string `json:"picked_warehouse_id"`
	FromOtherWarehouse bool    `json:"from_other_warehouse"`
	// Цена до скидки по акции (null — скидки не было).
	OldPrice *string `json:"old_price"`
}

type HistoryEntry struct {
	Status    string    `json:"status"`
	Actor     string    `json:"actor"`
	Note      string    `json:"note"`
	CreatedAt time.Time `json:"created_at"`
}

type Order struct {
	ID              string         `json:"id"`
	Number          int64          `json:"number"`
	NetworkID       string         `json:"network_id"`
	StoreID         string         `json:"store_id"`
	StoreName       string         `json:"store_name"`
	WarehouseID     string         `json:"warehouse_id"`
	Status          string         `json:"status"`
	StatusTitle     string         `json:"status_title"`
	Subtotal        string         `json:"subtotal"`
	Discount        string         `json:"discount"`
	DeliveryFee     string         `json:"delivery_fee"`
	Total           string         `json:"total"`
	Address         string         `json:"address"`
	Entrance        string         `json:"entrance"`
	Floor           string         `json:"floor"`
	Apartment       string         `json:"apartment"`
	AddressComment  string         `json:"address_comment"`
	Lat             float64        `json:"lat"`
	Lng             float64        `json:"lng"`
	DistanceM       int            `json:"distance_m"`
	CustomerPhone   string         `json:"customer_phone"`
	Comment         string         `json:"comment"`
	PaymentProvider string         `json:"payment_provider"`
	PaymentStatus   *string        `json:"payment_status"`
	PaidAt          *time.Time     `json:"paid_at"`
	AcceptedAt      *time.Time     `json:"accepted_at"`
	DeliveredAt     *time.Time     `json:"delivered_at"`
	CancelReason    string         `json:"cancel_reason"`
	FiscalStatus    string         `json:"fiscal_status"`
	CreatedAt       time.Time      `json:"created_at"`
	Items           []OrderItem    `json:"items,omitempty"`
	History         []HistoryEntry `json:"history,omitempty"`
}

const orderSelect = `
	SELECT o.id, o.number, o.network_id, o.store_id, s.name, o.warehouse_id, o.status, o.subtotal::text, o.discount::text,
	       o.delivery_fee::text, o.total::text, o.address, o.entrance, o.floor, o.apartment, o.address_comment,
	       ST_Y(o.location::geometry), ST_X(o.location::geometry), o.distance_m, o.customer_phone, o.comment,
	       o.payment_provider,
	       (SELECT p.status FROM payments p WHERE p.order_id = o.id ORDER BY (p.status IN ('paid', 'refund_pending', 'refunded')) DESC, p.created_at DESC LIMIT 1),
	       o.paid_at, o.accepted_at, o.delivered_at, o.cancel_reason, o.fiscal_status, o.created_at
	FROM orders o JOIN stores s ON s.id = o.store_id`

func scanOrder(row pgx.CollectableRow) (Order, error) {
	var o Order
	err := row.Scan(&o.ID, &o.Number, &o.NetworkID, &o.StoreID, &o.StoreName, &o.WarehouseID, &o.Status, &o.Subtotal, &o.Discount,
		&o.DeliveryFee, &o.Total, &o.Address, &o.Entrance, &o.Floor, &o.Apartment, &o.AddressComment,
		&o.Lat, &o.Lng, &o.DistanceM, &o.CustomerPhone, &o.Comment, &o.PaymentProvider, &o.PaymentStatus,
		&o.PaidAt, &o.AcceptedAt, &o.DeliveredAt, &o.CancelReason, &o.FiscalStatus, &o.CreatedAt)
	o.StatusTitle = statusTitles[o.Status]
	return o, err
}

func (s *Service) getOrder(ctx context.Context, q db.Querier, id string) (Order, error) {
	if !httpx.IsUUID(id) {
		return Order{}, apperr.NotFound("заказ не найден")
	}
	rows, err := q.Query(ctx, orderSelect+` WHERE o.id = $1`, id)
	if err != nil {
		return Order{}, err
	}
	o, err := pgx.CollectExactlyOneRow(rows, scanOrder)
	if errors.Is(err, pgx.ErrNoRows) {
		return Order{}, apperr.NotFound("заказ не найден")
	}
	if err != nil {
		return Order{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT i.line, i.product_id, p.name, u.short_name, i.qty::text, i.price::text, i.total::text,
		       i.picked_warehouse_id, i.from_other_warehouse,
		       CASE WHEN i.regular_price > i.price THEN i.regular_price::text END
		FROM order_items i JOIN products p ON p.id = i.product_id JOIN units u ON u.id = p.unit_id
		WHERE i.order_id = $1 ORDER BY i.line`, id)
	if err != nil {
		return Order{}, err
	}
	if o.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[OrderItem]); err != nil {
		return Order{}, err
	}
	rows, err = q.Query(ctx, `
		SELECT h.status,
		       CASE WHEN h.actor = 'client' THEN 'Покупатель'
		            WHEN h.actor = 'payment' THEN 'Оплата'
		            WHEN h.actor = 'system' THEN 'Система'
		            WHEN h.actor = 'admin' THEN 'Супер-админ'
		            WHEN h.actor LIKE 'store:%' THEN COALESCE(e.full_name, 'Магазин')
		            ELSE h.actor END,
		       h.note, h.created_at
		FROM order_status_history h
		LEFT JOIN employees e ON h.actor LIKE 'store:%' AND e.id::text = substr(h.actor, 7)
		WHERE h.order_id = $1 ORDER BY h.id`, id)
	if err != nil {
		return Order{}, err
	}
	o.History, err = pgx.CollectRows(rows, pgx.RowToStructByPos[HistoryEntry])
	return o, err
}

func addHistory(ctx context.Context, q db.Querier, orderID, status, actor, note string) error {
	_, err := q.Exec(ctx, `INSERT INTO order_status_history (order_id, status, actor, note) VALUES ($1, $2, $3, $4)`,
		orderID, status, actor, note)
	return err
}

// ------------------------------------------------------------ покупатель

type ListFilter struct {
	StoreID string
	Status  string
	From    *time.Time
	To      *time.Time
	Page    httpx.Page
}

func (s *Service) ClientListOrders(ctx context.Context, p *identity.Principal, page httpx.Page) ([]Order, error) {
	rows, err := s.pool.Query(ctx, orderSelect+` WHERE o.customer_id = $1 ORDER BY o.created_at DESC LIMIT $2 OFFSET $3`,
		p.UserID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanOrder)
}

func (s *Service) ClientGetOrder(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	o, err := s.getOrder(ctx, s.pool, id)
	if err != nil {
		return Order{}, err
	}
	var owner string
	if err := s.pool.QueryRow(ctx, `SELECT customer_id FROM orders WHERE id = $1`, id).Scan(&owner); err != nil || owner != p.UserID {
		return Order{}, apperr.NotFound("заказ не найден")
	}
	return o, nil
}

// ClientCancel — покупатель отменяет заказ, пока магазин его не принял.
func (s *Service) ClientCancel(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	if _, err := s.ClientGetOrder(ctx, p, id); err != nil {
		return Order{}, err
	}
	return s.cancel(ctx, id, "client", "Отменён покупателем", []string{StatusAwaitingPayment, StatusPaid})
}

// --------------------------------------------------------------- магазин

func (s *Service) StoreList(ctx context.Context, p *identity.Principal, f ListFilter) ([]Order, error) {
	if f.Status != "" && statusTitles[f.Status] == "" {
		return nil, apperr.Validation("status: неизвестный статус")
	}
	rows, err := s.pool.Query(ctx, orderSelect+`
		WHERE o.network_id = $1 AND ($2 OR o.store_id = ANY($3::uuid[]))
		  AND ($4 = '' OR o.store_id::text = $4)
		  AND (CASE WHEN $5 = '' THEN o.status NOT IN ('awaiting_payment', 'expired') ELSE o.status = $5 END)
		  AND ($6::timestamptz IS NULL OR o.created_at >= $6) AND ($7::timestamptz IS NULL OR o.created_at < $7)
		ORDER BY o.created_at DESC LIMIT $8 OFFSET $9`,
		p.NetworkID, p.SeesAllStores(), p.StoreIDs, f.StoreID, f.Status, f.From, f.To, f.Page.Limit, f.Page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanOrder)
}

func (s *Service) StoreGet(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	o, err := s.getOrder(ctx, s.pool, id)
	if err != nil {
		return Order{}, err
	}
	if o.NetworkID != p.NetworkID || !p.CanAccessStore(o.StoreID) || o.Status == StatusAwaitingPayment || o.Status == StatusExpired {
		return Order{}, apperr.NotFound("заказ не найден")
	}
	return o, nil
}

// lockOrder блокирует заказ и проверяет статус.
func lockOrder(ctx context.Context, tx pgx.Tx, id string, allowed ...string) (Order, error) {
	var o Order
	err := tx.QueryRow(ctx, `SELECT id, network_id, store_id, warehouse_id, status, total::text FROM orders WHERE id = $1 FOR UPDATE`, id).
		Scan(&o.ID, &o.NetworkID, &o.StoreID, &o.WarehouseID, &o.Status, &o.Total)
	if errors.Is(err, pgx.ErrNoRows) {
		return o, apperr.NotFound("заказ не найден")
	}
	if err != nil {
		return o, err
	}
	for _, a := range allowed {
		if o.Status == a {
			return o, nil
		}
	}
	return o, apperr.Conflict("wrong_status", "действие недоступно в статусе «"+statusTitles[o.Status]+"»").
		WithDetails(map[string]any{"status": o.Status})
}

// transition — простой переход статуса магазином.
func (s *Service) transition(ctx context.Context, p *identity.Principal, id, to, timeCol string, from ...string) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, from...); err != nil {
			return err
		}
		set := "status = $2"
		if timeCol != "" {
			set += ", " + timeCol + " = now()"
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET `+set+` WHERE id = $1`, id, to); err != nil {
			return err
		}
		return addHistory(ctx, tx, id, to, "store:"+p.EmployeeID, "")
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

func (s *Service) Accept(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	return s.transition(ctx, p, id, StatusAccepted, "accepted_at", StatusPaid)
}

func (s *Service) StartPicking(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	return s.transition(ctx, p, id, StatusPicking, "", StatusAccepted)
}

func (s *Service) StartDelivery(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	return s.transition(ctx, p, id, StatusDelivering, "", StatusPicked)
}

// Delivered — заказ вручён: деньги в балансе сети становятся доступными к выводу.
func (s *Service) Delivered(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusDelivering, StatusPicked); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'delivered', delivered_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE balance_entries SET status = 'available' WHERE order_id = $1 AND kind = 'order'`, id); err != nil {
			return err
		}
		return addHistory(ctx, tx, id, StatusDelivered, "store:"+p.EmployeeID, "")
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

type PickLine struct {
	Line        int    `json:"line"`
	WarehouseID string `json:"warehouse_id"`
}

// Picked — заказ собран: резерв снимается, товар списывается по FIFO со склада
// по умолчанию или с указанного для строки склада (с отметкой «взят с другого склада»).
func (s *Service) Picked(ctx context.Context, p *identity.Principal, id string, lines []PickLine) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	override := map[int]string{}
	for _, l := range lines {
		if !httpx.IsUUID(l.WarehouseID) {
			return Order{}, apperr.Validation("items: неверный warehouse_id в строке " + strconv.Itoa(l.Line))
		}
		override[l.Line] = l.WarehouseID
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := lockOrder(ctx, tx, id, StatusAccepted, StatusPicking)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM stock_reservations WHERE order_id = $1`, id); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT line, product_id, qty::text FROM order_items WHERE order_id = $1 ORDER BY line`, id)
		if err != nil {
			return err
		}
		type item struct {
			line    int
			product string
			qty     string
		}
		items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (item, error) {
			var it item
			err := r.Scan(&it.line, &it.product, &it.qty)
			return it, err
		})
		if err != nil {
			return err
		}
		totalCost := money.D("0")
		for _, it := range items {
			wh := o.WarehouseID
			if w, ok := override[it.line]; ok {
				var storeID string
				err := tx.QueryRow(ctx, `SELECT store_id FROM warehouses WHERE id = $1 AND network_id = $2 AND is_active`,
					w, o.NetworkID).Scan(&storeID)
				if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanAccessStore(storeID)) {
					return apperr.Validation("items: склад не найден в строке " + strconv.Itoa(it.line))
				}
				if err != nil {
					return err
				}
				wh = w
			}
			// Резерв этого заказа уже снят; TakeFIFO учитывает резервы других заказов.
			taken, err := inventory.TakeFIFO(ctx, tx, o.NetworkID, wh, it.product, it.qty, inventory.DocOrder, id)
			var ae *apperr.Error
			if errors.As(err, &ae) && ae.Code == "insufficient_stock" {
				return apperr.New(409, "insufficient_stock", "недостаточно товара на складе — выберите другой склад для строки").
					WithDetails(map[string]any{"line": it.line, "product_id": it.product, "warehouse_id": wh, "required": it.qty})
			}
			if err != nil {
				return err
			}
			cost := money.D("0")
			for _, t := range taken {
				cost = cost.Add(money.D(t.Qty).Mul(money.D(t.UnitCost)))
			}
			totalCost = totalCost.Add(cost)
			if _, err := tx.Exec(ctx, `UPDATE order_items SET picked_warehouse_id = $3, from_other_warehouse = $4, cost = $5::numeric
				WHERE order_id = $1 AND line = $2`, id, it.line, wh, wh != o.WarehouseID, cost.Money()); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'picked', picked_at = now(), cost = $2::numeric WHERE id = $1`,
			id, totalCost.Money()); err != nil {
			return err
		}
		note := ""
		if len(override) > 0 {
			note = fmt.Sprintf("строк с другого склада: %d", len(override))
		}
		return addHistory(ctx, tx, id, StatusPicked, "store:"+p.EmployeeID, note)
	})
	if err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

// StoreCancel — магазин отменяет заказ до сборки; деньги уходят на возврат.
func (s *Service) StoreCancel(ctx context.Context, p *identity.Principal, id, reason string) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	if strings.TrimSpace(reason) == "" {
		return Order{}, apperr.Validation("reason: укажите причину отмены")
	}
	if _, err := s.StoreGet(ctx, p, id); err != nil {
		return Order{}, err
	}
	if _, err := s.cancel(ctx, id, "store:"+p.EmployeeID, strings.TrimSpace(reason),
		[]string{StatusPaid, StatusAccepted, StatusPicking}); err != nil {
		return Order{}, err
	}
	return s.StoreGet(ctx, p, id)
}

// AdminCancel — супер-админ отменяет зависший заказ.
func (s *Service) AdminCancel(ctx context.Context, id, reason string) (Order, error) {
	if strings.TrimSpace(reason) == "" {
		return Order{}, apperr.Validation("reason: укажите причину отмены")
	}
	return s.cancel(ctx, id, "admin", strings.TrimSpace(reason), []string{StatusAwaitingPayment, StatusPaid, StatusAccepted, StatusPicking})
}

// cancel: снять резерв, закрыть неоплаченные попытки, оплаченное — на возврат,
// убрать деньги заказа из ожидающего баланса сети.
func (s *Service) cancel(ctx context.Context, id, actor, reason string, allowed []string) (Order, error) {
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, allowed...); err != nil {
			return err
		}
		return s.cancelLocked(ctx, tx, id, StatusCancelled, actor, reason)
	})
	if err != nil {
		return Order{}, err
	}
	return s.getOrder(ctx, s.pool, id)
}

func (s *Service) cancelLocked(ctx context.Context, tx pgx.Tx, id, status, actor, reason string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM stock_reservations WHERE order_id = $1`, id); err != nil {
		return err
	}
	if err := payments.CancelOpen(ctx, tx, id); err != nil {
		return err
	}
	refund, err := payments.RequestRefund(ctx, tx, id)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM balance_entries WHERE order_id = $1 AND kind = 'order' AND status = 'pending'`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE orders SET status = $2, cancelled_at = now(), cancel_reason = $3 WHERE id = $1`,
		id, status, reason); err != nil {
		return err
	}
	if refund {
		reason += " (деньги к возврату)"
	}
	return addHistory(ctx, tx, id, status, actor, reason)
}

// RegisterFiscal — магазин пробил чек по онлайн-заказу.
func (s *Service) RegisterFiscal(ctx context.Context, p *identity.Principal, id, number, sign string) error {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return err
	}
	number, sign = strings.TrimSpace(number), strings.TrimSpace(sign)
	if number == "" || sign == "" {
		return apperr.Validation("укажите fiscal_number и fiscal_sign из чека")
	}
	o, err := s.StoreGet(ctx, p, id)
	if err != nil {
		return err
	}
	if o.FiscalStatus == "registered" {
		return apperr.Conflict("already_registered", "чек уже зарегистрирован")
	}
	if o.Status != StatusPicked && o.Status != StatusDelivering && o.Status != StatusDelivered {
		return apperr.Conflict("wrong_status", "чек пробивается после сборки заказа")
	}
	_, err = s.pool.Exec(ctx, `UPDATE orders SET fiscal_status = 'registered', fiscal_number = $2, fiscal_sign = $3, fiscal_at = now()
		WHERE id = $1`, id, number, sign)
	return err
}

// ------------------------------------------------------------ супер-админ

func (s *Service) AdminList(ctx context.Context, status string, stale bool, page httpx.Page) ([]Order, error) {
	rows, err := s.pool.Query(ctx, orderSelect+`
		WHERE ($1 = '' OR o.status = $1)
		  AND (NOT $2 OR (o.status = 'paid' AND o.paid_at < now() - make_interval(secs => $3)))
		ORDER BY o.created_at DESC LIMIT $4 OFFSET $5`,
		status, stale, s.cfg.AcceptTimeout.Seconds(), page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanOrder)
}

func (s *Service) AdminGet(ctx context.Context, id string) (Order, error) {
	return s.getOrder(ctx, s.pool, id)
}

// ------------------------------------------------ хуки для модуля payments

// PayableAmount — сумма к оплате, если заказ ждёт оплаты.
func (s *Service) PayableAmount(ctx context.Context, q db.Querier, orderID string) (string, error) {
	var status, total string
	err := q.QueryRow(ctx, `SELECT status, total::text FROM orders WHERE id = $1`, orderID).Scan(&status, &total)
	if err != nil {
		return "", apperr.NotFound("заказ не найден")
	}
	if status != StatusAwaitingPayment {
		return "", apperr.Conflict("not_awaiting_payment", "заказ не ждёт оплаты")
	}
	return total, nil
}

// MarkPaid — оплата прошла: статус «оплачен», деньги в ожидающий баланс сети,
// уведомление магазину.
func (s *Service) MarkPaid(ctx context.Context, tx pgx.Tx, orderID string) error {
	o, err := lockOrder(ctx, tx, orderID, StatusAwaitingPayment)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'paid', paid_at = now() WHERE id = $1`, orderID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO balance_entries (network_id, store_id, order_id, kind, status, amount)
		VALUES ($1, $2, $3, 'order', 'pending', $4::numeric)`, o.NetworkID, o.StoreID, orderID, o.Total); err != nil {
		return err
	}
	if err := addHistory(ctx, tx, orderID, StatusPaid, "payment", ""); err != nil {
		return err
	}
	storeID, total := o.StoreID, o.Total
	go func() {
		// Уведомление — вне транзакции и без влияния на ответ провайдеру.
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		var number int64
		_ = s.pool.QueryRow(ctx, `SELECT number FROM orders WHERE id = $1`, orderID).Scan(&number)
		s.notify.StoreStaff(ctx, storeID, identity.PermOrdersManage,
			fmt.Sprintf("Новый заказ №%d на %s сум. Примите его в течение %d минут.", number, total, int(s.cfg.AcceptTimeout.Minutes())))
	}()
	return nil
}

// CanRefund — возврат через провайдера возможен, пока заказ не собран.
func (s *Service) CanRefund(ctx context.Context, q db.Querier, orderID string) (bool, error) {
	var status string
	if err := q.QueryRow(ctx, `SELECT status FROM orders WHERE id = $1`, orderID).Scan(&status); err != nil {
		return false, err
	}
	switch status {
	case StatusPaid, StatusAccepted, StatusPicking, StatusCancelled:
		return true, nil
	}
	return false, nil
}

// Refunded — провайдер вернул деньги. Если заказ ещё не отменён — отменяем.
func (s *Service) Refunded(ctx context.Context, tx pgx.Tx, orderID string) error {
	o, err := lockOrder(ctx, tx, orderID, StatusPaid, StatusAccepted, StatusPicking, StatusCancelled)
	if err != nil {
		return err
	}
	if o.Status == StatusCancelled {
		return addHistory(ctx, tx, orderID, StatusCancelled, "payment", "деньги возвращены")
	}
	return s.cancelLocked(ctx, tx, orderID, StatusCancelled, "payment", "возврат оплаты")
}

// --------------------------------------------------------- фоновые задачи

// ExpireUnpaid снимает резерв с заказов, не оплаченных за PaymentTimeout.
func (s *Service) ExpireUnpaid(ctx context.Context) error {
	rows, err := s.pool.Query(ctx, `SELECT id FROM orders WHERE status = 'awaiting_payment'
		AND created_at < now() - make_interval(secs => $1)`, s.cfg.PaymentTimeout.Seconds())
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for _, id := range ids {
		err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
			if _, err := lockOrder(ctx, tx, id, StatusAwaitingPayment); err != nil {
				return nil // уже оплачен или отменён параллельно
			}
			return s.cancelLocked(ctx, tx, id, StatusExpired, "system", "не оплачен вовремя")
		})
		if err != nil {
			s.log.Error("истечение заказа", "order_id", id, "err", err)
		}
	}
	return nil
}

// AlertUnaccepted уведомляет супер-админов о заказах, оплаченных, но не
// принятых магазином за AcceptTimeout. Каждый заказ — один раз.
func (s *Service) AlertUnaccepted(ctx context.Context) error {
	rows, err := s.pool.Query(ctx, `
		UPDATE orders o SET alerted_at = now()
		FROM stores s, networks n
		WHERE o.status = 'paid' AND o.alerted_at IS NULL AND o.paid_at < now() - make_interval(secs => $1)
		  AND s.id = o.store_id AND n.id = o.network_id
		RETURNING o.id, o.number, n.name, s.name, s.phone, o.total::text, o.paid_at`, s.cfg.AcceptTimeout.Seconds())
	if err != nil {
		return err
	}
	type stale struct {
		id, network, store, phone, total string
		number                           int64
		paidAt                           time.Time
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (stale, error) {
		var x stale
		err := r.Scan(&x.id, &x.number, &x.network, &x.store, &x.phone, &x.total, &x.paidAt)
		return x, err
	})
	if err != nil {
		return err
	}
	for _, x := range list {
		mins := int(s.now().Sub(x.paidAt).Minutes())
		text := fmt.Sprintf("⚠️ Заказ №%d не принят уже %d мин.\nСеть: %s\nМагазин: %s %s\nСумма: %s сум\nID: %s",
			x.number, mins, x.network, x.store, x.phone, x.total, x.id)
		s.notify.SuperAdmins(ctx, text)
		if err := addHistory(ctx, s.pool, x.id, StatusPaid, "system", "супер-админ уведомлён: заказ не принят вовремя"); err != nil {
			s.log.Warn("история заказа", "err", err)
		}
	}
	return nil
}
