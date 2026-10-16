package supply

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
	"github.com/sanedidi/super-market/backend/internal/push"
)

// Статусы заказа поставщику.
const (
	OrderNew       = "new"
	OrderAccepted  = "accepted"
	OrderAssembled = "assembled"
	OrderDelivered = "delivered"
	OrderRejected  = "rejected"
	OrderCancelled = "cancelled"
)

// OrderItem — строка заказа.
type OrderItem struct {
	Line      int    `json:"line"`
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Image     string `json:"image"`
	Unit      string `json:"unit"`
	Qty       string `json:"qty"`
	ShipQty   string `json:"ship_qty"`
	Price     string `json:"price"`
	Sum       string `json:"sum"`
	// Только дистрибьютору: сколько есть на его складе.
	InStock *string `json:"in_stock,omitempty"`
}

// Order — заказ магазина дистрибьютору.
type Order struct {
	ID            string      `json:"id"`
	Number        int64       `json:"number"`       // номер у дистрибьютора
	StoreNumber   int64       `json:"store_number"` // номер у магазина
	Status        string      `json:"status"`
	StoreID       string      `json:"store_id"`
	StoreName     string      `json:"store_name"`
	StoreAddress  string      `json:"store_address"`
	StorePhone    string      `json:"store_phone"`
	DistributorID string      `json:"distributor_id"`
	Distributor   string      `json:"distributor_name"`
	DeliverBy     *string     `json:"deliver_by"`
	Note          string      `json:"note"`
	RejectReason  string      `json:"reject_reason"`
	Total         string      `json:"total"`
	ShipTotal     string      `json:"ship_total"`
	ItemsCount    int         `json:"items_count"`
	QtyTotal      string      `json:"qty_total"`
	ShipmentID    *string     `json:"shipment_id"`
	CreatedBy     string      `json:"created_by"`
	CreatedAt     time.Time   `json:"created_at"`
	AcceptedAt    *time.Time  `json:"accepted_at"`
	AssembledAt   *time.Time  `json:"assembled_at"`
	DeliveredAt   *time.Time  `json:"delivered_at"`
	Items         []OrderItem `json:"items,omitempty"`
}

const orderSelect = `
	SELECT o.id, o.number, o.store_number, o.status, o.store_id, s.name, s.address, s.phone, o.network_id, n.name,
	       to_char(o.deliver_by, 'YYYY-MM-DD'), o.note, o.reject_reason, o.total::text,
	       COALESCE((SELECT sum(round(i.ship_qty * i.price, 2)) FROM supply_order_items i WHERE i.order_id = o.id), 0)::numeric(18,2)::text,
	       (SELECT count(*)::int FROM supply_order_items i WHERE i.order_id = o.id),
	       COALESCE((SELECT sum(i.qty) FROM supply_order_items i WHERE i.order_id = o.id), 0)::text,
	       o.shipment_id, e.full_name, o.created_at, o.accepted_at, o.assembled_at, o.delivered_at
	FROM supply_orders o
	JOIN stores s    ON s.id = o.store_id
	JOIN networks n  ON n.id = o.network_id
	JOIN employees e ON e.id = o.created_by`

func scanOrder(row pgx.CollectableRow) (Order, error) {
	var o Order
	err := row.Scan(&o.ID, &o.Number, &o.StoreNumber, &o.Status, &o.StoreID, &o.StoreName, &o.StoreAddress, &o.StorePhone,
		&o.DistributorID, &o.Distributor, &o.DeliverBy, &o.Note, &o.RejectReason, &o.Total, &o.ShipTotal, &o.ItemsCount,
		&o.QtyTotal, &o.ShipmentID, &o.CreatedBy, &o.CreatedAt, &o.AcceptedAt, &o.AssembledAt, &o.DeliveredAt)
	return o, err
}

// getOrder — заказ с проверкой стороны: дистрибьютор видит свои заказы,
// магазин — заказы своих магазинов.
func (s *Service) getOrder(ctx context.Context, q db.Querier, p *identity.Principal, id string) (Order, error) {
	if !httpx.IsUUID(id) {
		return Order{}, apperr.NotFound("заказ не найден").Uz("buyurtma topilmadi")
	}
	rows, err := q.Query(ctx, orderSelect+` WHERE o.id = $1`, id)
	if err != nil {
		return Order{}, err
	}
	o, err := pgx.CollectExactlyOneRow(rows, scanOrder)
	if errors.Is(err, pgx.ErrNoRows) {
		return Order{}, apperr.NotFound("заказ не найден").Uz("buyurtma topilmadi")
	}
	if err != nil {
		return Order{}, err
	}
	isDist := p.NetworkKind == KindDistributor
	if (isDist && o.DistributorID != p.NetworkID) || (!isDist && !p.CanAccessStore(o.StoreID)) {
		return Order{}, apperr.NotFound("заказ не найден").Uz("buyurtma topilmadi")
	}
	if !isDist {
		var net string
		if err := q.QueryRow(ctx, `SELECT network_id FROM stores WHERE id = $1`, o.StoreID).Scan(&net); err != nil || net != p.NetworkID {
			return Order{}, apperr.NotFound("заказ не найден").Uz("buyurtma topilmadi")
		}
	}
	stock := "NULL::numeric"
	args := []any{id}
	if isDist {
		pt, err := distPoint(ctx, q, p.NetworkID)
		if err != nil {
			return Order{}, err
		}
		stock = stockSQL("$2", "i.product_id")
		args = append(args, pt.StoreID)
	}
	rows, err = q.Query(ctx, `
		SELECT i.line, i.product_id, loc(p.name, p.name_uz), COALESCE(p.images[1], ''), loc(u.short_name, u.short_name_uz),
		       i.qty::text, i.ship_qty::text, i.price::text, round(i.ship_qty * i.price, 2)::text, (`+stock+`)::text
		FROM supply_order_items i
		JOIN products p ON p.id = i.product_id
		JOIN units u    ON u.id = p.unit_id
		WHERE i.order_id = $1 ORDER BY i.line`, args...)
	if err != nil {
		return Order{}, err
	}
	o.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[OrderItem])
	return o, err
}

// GetOrder — заказ (обеим сторонам).
func (s *Service) GetOrder(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	return s.getOrder(ctx, s.pool, p, id)
}

// OrdersFilter — фильтр заказов.
type OrdersFilter struct {
	Status        string
	StoreID       string
	DistributorID string
	Page          httpx.Page
}

// Orders — заказы: дистрибьютору — его, магазину — его магазинов.
func (s *Service) Orders(ctx context.Context, p *identity.Principal, f OrdersFilter) ([]Order, error) {
	if f.StoreID != "" && !httpx.IsUUID(f.StoreID) {
		return nil, apperr.Validation("store_id: неверный id").Uz("store_id: id notoʻgʻri")
	}
	isDist := p.NetworkKind == KindDistributor
	if !isDist {
		if err := p.Require(identity.PermInventoryManage); err != nil {
			return nil, err
		}
	} else if err := p.Require(identity.PermOrdersManage); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, orderSelect+`
		WHERE (($9 AND o.network_id = $1)
		    OR (NOT $9 AND o.store_network_id = $1 AND ($6 OR o.store_id = ANY($7::uuid[])) AND ($8 = '' OR o.network_id::text = $8)))
		  AND ($2 = '' OR o.status = $2 OR ($2 = 'open' AND o.status IN ('new', 'accepted', 'assembled')))
		  AND ($3 = '' OR o.store_id::text = $3)
		ORDER BY CASE o.status WHEN 'new' THEN 0 WHEN 'accepted' THEN 1 WHEN 'assembled' THEN 2 ELSE 3 END, o.created_at DESC
		LIMIT $4 OFFSET $5`,
		p.NetworkID, f.Status, f.StoreID, f.Page.Limit, f.Page.Offset, p.SeesAllStores(), p.StoreIDs, f.DistributorID, isDist)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanOrder)
}

// ------------------------------------------------------------ магазин

// OrderInput — заказ магазина поставщику.
type OrderInput struct {
	StoreID       string  `json:"store_id"`
	DistributorID string  `json:"distributor_id"`
	DeliverBy     *string `json:"deliver_by"`
	Note          string  `json:"note"`
	Items         []struct {
		ProductID string    `json:"product_id"`
		Qty       money.Qty `json:"qty"`
	} `json:"items"`
}

// CreateOrder — магазин отправляет заказ подключённому дистрибьютору.
// Цены — отпускные дистрибьютора на сейчас.
func (s *Service) CreateOrder(ctx context.Context, p *identity.Principal, in OrderInput) (Order, error) {
	if err := requireStoreSide(p); err != nil {
		return Order{}, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Order{}, err
	}
	if len(in.Items) == 0 {
		return Order{}, apperr.Validation("items: добавьте хотя бы один товар").Uz("items: kamida bitta mahsulot qoʻshing")
	}
	if len(in.Items) > 300 {
		return Order{}, apperr.Validation("items: не больше 300 строк").Uz("items: koʻpi bilan 300 ta qator")
	}
	var deliverBy *time.Time
	if in.DeliverBy != nil && strings.TrimSpace(*in.DeliverBy) != "" {
		d, err := time.Parse("2006-01-02", strings.TrimSpace(*in.DeliverBy))
		if err != nil {
			return Order{}, apperr.Validation("deliver_by: дата в формате ГГГГ-ММ-ДД").Uz("deliver_by: sana YYYY-MM-DD koʻrinishida")
		}
		deliverBy = &d
	}
	note := strings.TrimSpace(in.Note)
	if len([]rune(note)) > 500 {
		return Order{}, apperr.Validation("note: не длиннее 500 символов").Uz("note: 500 belgidan oshmasin")
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := storeOfNetwork(ctx, tx, p, in.StoreID); err != nil {
			return err
		}
		if err := checkDistributor(ctx, tx, in.DistributorID); err != nil {
			return err
		}
		linkID, err := activeLink(ctx, tx, in.StoreID, in.DistributorID)
		if err != nil {
			return err
		}
		pt, err := distPoint(ctx, tx, in.DistributorID)
		if err != nil {
			return err
		}
		// Номер у магазина: блокируем сеть магазина, затем номер у дистрибьютора.
		if _, err := tx.Exec(ctx, `SELECT 1 FROM networks WHERE id = $1 FOR UPDATE`, p.NetworkID); err != nil {
			return err
		}
		var storeNumber int64
		if err := tx.QueryRow(ctx, `SELECT COALESCE(max(store_number), 0) + 1 FROM supply_orders WHERE store_network_id = $1`, p.NetworkID).
			Scan(&storeNumber); err != nil {
			return err
		}
		number, err := db.NextNumber(ctx, tx, "supply_orders", in.DistributorID, "")
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO supply_orders (network_id, number, link_id, store_id, store_network_id, store_number, deliver_by, note, created_by)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
			in.DistributorID, number, linkID, in.StoreID, p.NetworkID, storeNumber, deliverBy, note, p.EmployeeID).Scan(&id); err != nil {
			return err
		}
		seen := map[string]bool{}
		for i, it := range in.Items {
			line := strconv.Itoa(i + 1)
			if !httpx.IsUUID(it.ProductID) || seen[it.ProductID] {
				return apperr.Validation("items: неверный или повторный товар в строке " + line).Uz("items: " + line + "-qatorda mahsulot notoʻgʻri yoki takrorlangan")
			}
			seen[it.ProductID] = true
			if !it.Qty.Valid() || strings.Trim(string(it.Qty), "0.") == "" {
				return apperr.Validation("items: количество должно быть больше нуля в строке " + line).Uz("items: " + line + "-qatorda miqdor noldan katta boʻlishi kerak")
			}
			tag, err := tx.Exec(ctx, `
				INSERT INTO supply_order_items (order_id, line, product_id, qty, ship_qty, price)
				SELECT $1, $2, p.id, $3::numeric, $3::numeric, `+priceSQL("p", "$5", "$6")+`
				FROM products p
				JOIN units u ON u.id = p.unit_id
				WHERE p.id = $4 AND p.network_id IS NULL
				  AND EXISTS (SELECT 1 FROM store_products sp WHERE sp.store_id = $6 AND sp.product_id = p.id)
				  AND `+priceSQL("p", "$5", "$6")+` IS NOT NULL
				  AND (u.is_fractional OR $3::numeric = trunc($3::numeric))`,
				id, i+1, string(it.Qty), it.ProductID, pt.PriceTypeID, pt.StoreID)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return apperr.Validation("items: товара нет в прайсе поставщика или количество дробное (строка " + line + ")").Uz("items: mahsulot yetkazib beruvchi narxlarida yoʻq yoki miqdor kasr son (" + line + "-qator)")
			}
		}
		if _, err := tx.Exec(ctx, `
			UPDATE supply_orders SET total = (SELECT COALESCE(sum(round(qty * price, 2)), 0) FROM supply_order_items WHERE order_id = $1)
			WHERE id = $1`, id); err != nil {
			return err
		}
		sn := storeName(ctx, tx, in.StoreID)
		return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_order_new",
			i18n.Text{RU: "Новый заказ № " + strconv.FormatInt(number, 10), UZ: "Yangi buyurtma № " + strconv.FormatInt(number, 10)},
			i18n.Text{RU: sn + " · " + strconv.Itoa(len(in.Items)) + " поз.", UZ: sn + " · " + strconv.Itoa(len(in.Items)) + " ta"},
			map[string]string{"supply_order_id": id})
	})
	if err != nil {
		return Order{}, err
	}
	return s.GetOrder(ctx, p, id)
}

// CancelOrder — магазин отменяет заказ, пока его не собрали.
func (s *Service) CancelOrder(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	if err := requireStoreSide(p); err != nil {
		return Order{}, err
	}
	if err := p.Require(identity.PermInventoryManage); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := s.lockOrder(ctx, tx, p, id)
		if err != nil {
			return err
		}
		if o.Status != OrderNew && o.Status != OrderAccepted {
			return apperr.Conflict("order_status", "заказ уже собран — отменить нельзя, договоритесь с поставщиком").Uz("buyurtma allaqachon yigʻilgan — bekor qilib boʻlmaydi, yetkazib beruvchi bilan kelishing")
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_orders SET status = 'cancelled' WHERE id = $1`, id); err != nil {
			return err
		}
		pt, err := distPoint(ctx, tx, o.DistributorID)
		if err != nil {
			return nil //nolint:nilerr // уведомлять некуда
		}
		return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_order_cancelled",
			i18n.Text{RU: "Заказ № " + strconv.FormatInt(o.Number, 10) + " отменён", UZ: "Buyurtma № " + strconv.FormatInt(o.Number, 10) + " bekor qilindi"},
			i18n.Text{RU: o.StoreName + " отменил заказ", UZ: o.StoreName + " buyurtmani bekor qildi"},
			map[string]string{"supply_order_id": id})
	})
	if err != nil {
		return Order{}, err
	}
	return s.GetOrder(ctx, p, id)
}

func (s *Service) lockOrder(ctx context.Context, tx pgx.Tx, p *identity.Principal, id string) (Order, error) {
	if !httpx.IsUUID(id) {
		return Order{}, apperr.NotFound("заказ не найден").Uz("buyurtma topilmadi")
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM supply_orders WHERE id = $1 FOR UPDATE`, id); err != nil {
		return Order{}, err
	}
	return s.getOrder(ctx, tx, p, id)
}

// ------------------------------------------------------- дистрибьютор

func (s *Service) distOrderTx(ctx context.Context, p *identity.Principal, id string, fn func(tx pgx.Tx, o Order) error) (Order, error) {
	if err := requireDistributor(p); err != nil {
		return Order{}, err
	}
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := s.lockOrder(ctx, tx, p, id)
		if err != nil {
			return err
		}
		return fn(tx, o)
	})
	if err != nil {
		return Order{}, err
	}
	return s.GetOrder(ctx, p, id)
}

func statusConflict() error {
	return apperr.Conflict("order_status", "заказ уже в другом статусе — обновите экран").Uz("buyurtma boshqa holatda — ekranni yangilang")
}

func (s *Service) notifyStore(ctx context.Context, tx pgx.Tx, o Order, kind string, title, body i18n.Text) error {
	return push.EnqueueStaff(ctx, tx, o.StoreID, identity.PermInventoryManage, kind, title, body,
		map[string]string{"supply_order_id": o.ID})
}

// ShipQtyInput — сколько отгрузить по строкам (до «Собран»).
type ShipQtyInput struct {
	Items []struct {
		ProductID string    `json:"product_id"`
		ShipQty   money.Qty `json:"ship_qty"`
	} `json:"items"`
}

// SetShipQty — дистрибьютор отгрузит меньше (нет на складе) или 0.
func (s *Service) SetShipQty(ctx context.Context, p *identity.Principal, id string, in ShipQtyInput) (Order, error) {
	return s.distOrderTx(ctx, p, id, func(tx pgx.Tx, o Order) error {
		if o.Status != OrderNew && o.Status != OrderAccepted {
			return statusConflict()
		}
		for _, it := range in.Items {
			if !it.ShipQty.Valid() {
				return apperr.Validation("items: неверное количество").Uz("items: miqdor notoʻgʻri")
			}
			tag, err := tx.Exec(ctx, `
				UPDATE supply_order_items i SET ship_qty = $3::numeric
				FROM products p JOIN units u ON u.id = p.unit_id
				WHERE i.order_id = $1 AND i.product_id = $2 AND p.id = i.product_id
				  AND $3::numeric <= i.qty AND (u.is_fractional OR $3::numeric = trunc($3::numeric))`,
				id, it.ProductID, string(it.ShipQty))
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return apperr.Validation("items: товара нет в заказе или отгрузка больше заказанного").Uz("items: mahsulot buyurtmada yoʻq yoki joʻnatish buyurtmadan koʻp")
			}
		}
		return nil
	})
}

// AcceptOrder — новый → принят.
func (s *Service) AcceptOrder(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	return s.distOrderTx(ctx, p, id, func(tx pgx.Tx, o Order) error {
		if o.Status != OrderNew {
			return statusConflict()
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_orders SET status = 'accepted', accepted_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		return s.notifyStore(ctx, tx, o, "supply_order_accepted",
			i18n.Text{RU: "Заказ принят", UZ: "Buyurtma qabul qilindi"},
			i18n.Text{RU: o.Distributor + " принял заказ № " + strconv.FormatInt(o.StoreNumber, 10), UZ: o.Distributor + " № " + strconv.FormatInt(o.StoreNumber, 10) + " buyurtmani qabul qildi"})
	})
}

// RejectInput — причина отказа.
type RejectInput struct {
	Reason string `json:"reason"`
}

// RejectOrder — новый или принятый → отклонён.
func (s *Service) RejectOrder(ctx context.Context, p *identity.Principal, id string, in RejectInput) (Order, error) {
	reason := strings.TrimSpace(in.Reason)
	if reason == "" || len([]rune(reason)) > 500 {
		return Order{}, apperr.Validation("reason: укажите причину (до 500 символов)").Uz("reason: sababini kiriting (500 belgigacha)")
	}
	return s.distOrderTx(ctx, p, id, func(tx pgx.Tx, o Order) error {
		if o.Status != OrderNew && o.Status != OrderAccepted {
			return statusConflict()
		}
		if _, err := tx.Exec(ctx, `UPDATE supply_orders SET status = 'rejected', reject_reason = $2 WHERE id = $1`, id, reason); err != nil {
			return err
		}
		return s.notifyStore(ctx, tx, o, "supply_order_rejected",
			i18n.Text{RU: "Заказ отклонён", UZ: "Buyurtma rad etildi"},
			i18n.Text{RU: o.Distributor + ": " + reason, UZ: o.Distributor + ": " + reason})
	})
}

// assemble — черновик расхода по заказу (только строки с ship_qty > 0).
func (s *Service) assemble(ctx context.Context, tx pgx.Tx, p *identity.Principal, o Order) error {
	pt, err := distPoint(ctx, tx, p.NetworkID)
	if err != nil {
		return err
	}
	items := []inventory.ItemInput{}
	for _, it := range o.Items {
		if strings.Trim(it.ShipQty, "0.") == "" {
			continue
		}
		price := money.Price(it.Price)
		items = append(items, inventory.ItemInput{ProductID: it.ProductID, Qty: money.Qty(it.ShipQty), Price: &price})
	}
	if len(items) == 0 {
		return apperr.Conflict("nothing_to_ship", "нечего отгружать — во всех строках 0; отклоните заказ").Uz("joʻnatadigan narsa yoʻq — barcha qatorlarda 0; buyurtmani rad eting")
	}
	note := "Заказ № " + strconv.FormatInt(o.Number, 10)
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.ProductID
	}
	// Склад — ближайший к магазину, где есть весь заказ (А4).
	wh, err := bestWarehouse(ctx, tx, pt, o.StoreID, ids)
	if err != nil {
		return err
	}
	store := o.StoreID
	docID, err := s.inv.CreateTx(ctx, tx, p, inventory.Input{Type: inventory.TypeShipment, WarehouseID: &wh, ToStoreID: &store,
		Note: &note, Items: &items}, &o.ID)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE supply_orders SET status = 'assembled', assembled_at = now(), shipment_id = $2 WHERE id = $1`, o.ID, docID)
	return err
}

// AssembleOrder — принят → собран: создаётся черновик расхода (Д8), его можно поправить.
func (s *Service) AssembleOrder(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	return s.distOrderTx(ctx, p, id, func(tx pgx.Tx, o Order) error {
		if o.Status != OrderAccepted && o.Status != OrderNew {
			return statusConflict()
		}
		if o.Status == OrderNew {
			if _, err := tx.Exec(ctx, `UPDATE supply_orders SET accepted_at = now() WHERE id = $1`, id); err != nil {
				return err
			}
		}
		return s.assemble(ctx, tx, p, o)
	})
}

// DeliverOrder — доставлен: расход проводится (товар уходит со склада),
// у магазина появляется приход. Принятый заказ сначала собирается.
func (s *Service) DeliverOrder(ctx context.Context, p *identity.Principal, id string) (Order, error) {
	var shipmentID string
	_, err := s.distOrderTx(ctx, p, id, func(tx pgx.Tx, o Order) error {
		switch o.Status {
		case OrderNew, OrderAccepted:
			if err := s.assemble(ctx, tx, p, o); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT shipment_id FROM supply_orders WHERE id = $1`, id).Scan(&shipmentID)
		case OrderAssembled:
			if o.ShipmentID == nil {
				return statusConflict()
			}
			shipmentID = *o.ShipmentID
			return nil
		default:
			return statusConflict()
		}
	})
	if err != nil {
		return Order{}, err
	}
	// Проведение — отдельной транзакцией: если товара не хватает, заказ
	// остаётся «Собран» с черновиком расхода, который можно поправить.
	if _, err := s.inv.Post(ctx, p, shipmentID); err != nil {
		return Order{}, err
	}
	return s.GetOrder(ctx, p, id)
}

// ---------------------------------------------- расход → приход магазина

type hooks struct{ s *Service }

// Counterparty — магазин у дистрибьютора: только подключённый.
func (h hooks) Counterparty(ctx context.Context, tx pgx.Tx, p *identity.Principal, storeID string) (string, error) {
	if _, err := checkStore(ctx, tx, storeID); err != nil {
		return "", apperr.Validation("to_store_id: магазин не найден").Uz("to_store_id: doʻkon topilmadi")
	}
	if _, err := activeLink(ctx, tx, storeID, p.NetworkID); err != nil {
		return "", err
	}
	return ensureCounterparty(ctx, tx, p.NetworkID, nil, &storeID)
}

// AfterPost — расход проведён: черновик прихода у магазина, заказ «Доставлен».
func (h hooks) AfterPost(ctx context.Context, tx pgx.Tx, p *identity.Principal, d inventory.Document) error {
	storeID := *d.ToStoreID
	var storeNet string
	var wh *string
	if err := tx.QueryRow(ctx, `SELECT network_id, default_warehouse_id FROM stores WHERE id = $1`, storeID).Scan(&storeNet, &wh); err != nil {
		return err
	}
	if wh == nil {
		return apperr.Conflict("store_no_warehouse", "у магазина нет склада для прихода").Uz("doʻkonda kirim uchun ombor yoʻq")
	}
	distID := p.NetworkID
	cp, err := ensureCounterparty(ctx, tx, storeNet, &distID, nil)
	if err != nil {
		return err
	}
	owner, err := ownerEmployee(ctx, tx, storeNet)
	if err != nil {
		return err
	}
	n, err := db.NextNumber(ctx, tx, "stock_documents", storeNet, "type = 'income'")
	if err != nil {
		return err
	}
	var distName string
	if err := tx.QueryRow(ctx, `SELECT name FROM networks WHERE id = $1`, distID).Scan(&distName); err != nil {
		return err
	}
	note := distName + " · расход № " + strconv.FormatInt(d.Number, 10)
	var incomeID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO stock_documents (network_id, type, number, warehouse_id, counterparty_id, currency, note, created_by,
		                             supply_order_id, source_shipment_id)
		VALUES ($1, 'income', $2, $3, $4, 'UZS', $5, $6, $7, $8) RETURNING id`,
		storeNet, n, *wh, cp, note, owner, d.SupplyOrderID, d.ID).Scan(&incomeID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO stock_document_items (document_id, line, product_id, qty, price)
		SELECT $1, line, product_id, qty, price FROM stock_document_items WHERE document_id = $2`, incomeID, d.ID); err != nil {
		return err
	}
	if d.SupplyOrderID != nil {
		if _, err := tx.Exec(ctx, `
			UPDATE supply_orders SET status = 'delivered', delivered_at = now(), shipment_id = $2,
			       assembled_at = COALESCE(assembled_at, now()), accepted_at = COALESCE(accepted_at, now())
			WHERE id = $1`, *d.SupplyOrderID, d.ID); err != nil {
			return err
		}
	}
	return push.EnqueueStaff(ctx, tx, storeID, identity.PermInventoryManage, "supply_income",
		i18n.Text{RU: "Товар от " + distName, UZ: distName + " dan mahsulot"},
		i18n.Text{RU: "Проверьте приход № " + strconv.FormatInt(n, 10) + " и примите товар", UZ: "№ " + strconv.FormatInt(n, 10) + " kirimni tekshiring va mahsulotni qabul qiling"},
		map[string]string{"document_id": incomeID})
}

// AfterIncome — магазин провёл приход по расходу: расхождение — дистрибьютору.
func (h hooks) AfterIncome(ctx context.Context, tx pgx.Tx, p *identity.Principal, d inventory.Document) error {
	var diff, distNet, shipNumber string
	if err := tx.QueryRow(ctx, `
		UPDATE stock_documents sh SET received_at = now(),
		       received_diff = (SELECT COALESCE(sum(qty), 0) FROM stock_document_items WHERE document_id = $1)
		                     - (SELECT COALESCE(sum(qty), 0) FROM stock_document_items WHERE document_id = sh.id)
		WHERE sh.id = $2
		RETURNING received_diff::text, network_id, number::text`, d.ID, *d.SourceShipmentID).Scan(&diff, &distNet, &shipNumber); err != nil {
		return err
	}
	if strings.Trim(strings.TrimPrefix(diff, "-"), "0.") == "" {
		return nil
	}
	pt, err := distPoint(ctx, tx, distNet)
	if err != nil {
		return nil //nolint:nilerr // уведомлять некуда
	}
	var sn string
	_ = tx.QueryRow(ctx, `SELECT s.name FROM warehouses w JOIN stores s ON s.id = w.store_id WHERE w.id = $1`, d.WarehouseID).Scan(&sn)
	return push.EnqueueStaff(ctx, tx, pt.StoreID, identity.PermOrdersManage, "supply_received_diff",
		i18n.Text{RU: "Расхождение по расходу № " + shipNumber, UZ: "№ " + shipNumber + " chiqim boʻyicha farq"},
		i18n.Text{RU: sn + " принял с расхождением " + diff + " шт", UZ: sn + " " + diff + " dona farq bilan qabul qildi"},
		map[string]string{"document_id": *d.SourceShipmentID})
}
