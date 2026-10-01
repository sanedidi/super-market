package orders

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Курьеры магазина: смена и транспорт, назначение на заказ, геопозиция и
// время прибытия для покупателя.

// Средняя скорость по городу, км/ч, и поправка «по прямой → по дорогам».
var vehicleSpeed = map[string]float64{"foot": 5, "bike": 14, "scooter": 22, "car": 25}

const routeFactor = 1.35

// Точка курьера старше этого не показывается покупателю.
const locationFresh = 10 * time.Minute

// etaFor — время в пути от точки до покупателя.
func etaFor(distM float64, vehicle string) time.Duration {
	speed := vehicleSpeed[vehicle]
	if speed == 0 {
		speed = vehicleSpeed["foot"]
	}
	mins := distM * routeFactor / 1000 / speed * 60
	return time.Duration(math.Ceil(mins+2)) * time.Minute // +2 мин — передать заказ
}

type Courier struct {
	EmployeeID   string     `json:"employee_id"`
	FullName     string     `json:"full_name"`
	Phone        string     `json:"phone"`
	Vehicle      string     `json:"vehicle"`
	OnShift      bool       `json:"on_shift"`
	Lat          *float64   `json:"lat"`
	Lng          *float64   `json:"lng"`
	LocatedAt    *time.Time `json:"located_at"`
	ActiveOrders int        `json:"active_orders"`
	// Логин для приложения курьера; null — входа нет.
	Login       *string    `json:"login"`
	LastLoginAt *time.Time `json:"last_login_at"`
}

// courierQuery — курьеры сети: право orders.deliver или уже выходили на смену.
const courierQuery = `
	SELECT e.id, e.full_name, u.phone, COALESCE(c.vehicle, 'foot'), COALESCE(c.on_shift, false),
	       ST_Y(c.location::geometry), ST_X(c.location::geometry), c.located_at,
	       (SELECT count(*) FROM orders o WHERE o.courier_id = e.id AND o.status IN ('accepted', 'picking', 'picked', 'delivering'))::int,
	       cl.login, cl.last_login_at
	FROM employees e
	JOIN roles r ON r.id = e.role_id
	JOIN users u ON u.id = e.user_id
	LEFT JOIN couriers c ON c.employee_id = e.id
	LEFT JOIN courier_logins cl ON cl.employee_id = e.id
	WHERE e.network_id = $1 AND e.status = 'active'
	  AND ('orders.deliver' = ANY(r.permissions) OR c.employee_id IS NOT NULL)
	  AND ($2 = '' OR r.is_owner OR e.all_stores OR EXISTS (
	       SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id::text = $2))`

// StoreCouriers — курьеры магазина: сначала на смене.
func (s *Service) StoreCouriers(ctx context.Context, p *identity.Principal, storeID string) ([]Courier, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return nil, err
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return nil, apperr.NotFound("магазин не найден")
	}
	rows, err := s.pool.Query(ctx, courierQuery+` ORDER BY COALESCE(c.on_shift, false) DESC, e.full_name`, p.NetworkID, storeID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Courier])
}

type AssignInput struct {
	CourierID *string `json:"courier_id"` // null — снять курьера
}

// AssignCourier назначает курьера на заказ (или снимает). Курьеру уходит
// сообщение в Telegram.
func (s *Service) AssignCourier(ctx context.Context, p *identity.Principal, id string, in AssignInput) (Order, error) {
	if err := p.Require(identity.PermOrdersManage); err != nil {
		return Order{}, err
	}
	o, err := s.StoreGet(ctx, p, id)
	if err != nil {
		return Order{}, err
	}
	var name string
	if in.CourierID != nil {
		if !httpx.IsUUID(*in.CourierID) {
			return Order{}, apperr.Validation("courier_id: курьер не найден")
		}
		err := s.pool.QueryRow(ctx, `SELECT full_name FROM (`+courierQuery+`) x (id, full_name, phone, vehicle, on_shift, lat, lng, located_at, active)
			WHERE id = $3`, p.NetworkID, o.StoreID, *in.CourierID).Scan(&name)
		if errors.Is(err, pgx.ErrNoRows) {
			return Order{}, apperr.Validation("courier_id: это не курьер магазина")
		}
		if err != nil {
			return Order{}, err
		}
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusAccepted, StatusPicking, StatusPicked, StatusDelivering); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET courier_id = $2, assigned_at = CASE WHEN $2::uuid IS NULL THEN NULL ELSE now() END
			WHERE id = $1`, id, in.CourierID); err != nil {
			return err
		}
		note := "Курьер снят"
		if in.CourierID != nil {
			note = "Назначен курьер: " + name
		}
		// Статус не меняется — только отметка в истории, без уведомления покупателю.
		_, err := tx.Exec(ctx, `INSERT INTO order_status_history (order_id, status, actor, note) VALUES ($1, $2, $3, $4)`,
			id, o.Status, "store:"+p.EmployeeID, note)
		return err
	})
	if err != nil {
		return Order{}, err
	}
	if in.CourierID != nil {
		courier, number, store, addr := *in.CourierID, o.Number, o.StoreName, o.Address
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			s.notify.Employee(ctx, courier, fmt.Sprintf("🛵 Вам назначен заказ №%d\nМагазин: %s\nАдрес: %s", number, store, addr))
		}()
	}
	return s.StoreGet(ctx, p, id)
}

// ------------------------------------------------------------ курьер

type CourierMe struct {
	EmployeeID string `json:"employee_id"`
	FullName   string `json:"full_name"`
	Phone      string `json:"phone"`
	Login      string `json:"login"`
	Network    string `json:"network_name"`
	Vehicle    string `json:"vehicle"`
	OnShift    bool   `json:"on_shift"`
	// Магазины курьера — позвонить или посмотреть адрес.
	Stores []CourierStore `json:"stores"`
}

type CourierStore struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address"`
	Phone   string `json:"phone"`
}

func (s *Service) CourierMe(ctx context.Context, p *identity.Principal) (CourierMe, error) {
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return CourierMe{}, err
	}
	me := CourierMe{EmployeeID: p.EmployeeID}
	err := s.pool.QueryRow(ctx, `
		SELECT e.full_name, u.phone, COALESCE(cl.login, ''), n.name, COALESCE(c.vehicle, 'foot'), COALESCE(c.on_shift, false)
		FROM employees e JOIN networks n ON n.id = e.network_id JOIN users u ON u.id = e.user_id
		LEFT JOIN couriers c ON c.employee_id = e.id
		LEFT JOIN courier_logins cl ON cl.employee_id = e.id
		WHERE e.id = $1`, p.EmployeeID).Scan(&me.FullName, &me.Phone, &me.Login, &me.Network, &me.Vehicle, &me.OnShift)
	if err != nil {
		return me, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT s.id, s.name, s.address, s.phone FROM stores s
		WHERE s.network_id = $1 AND s.status = 'active'
		  AND ($2 OR s.id::text = ANY($3::text[]))
		ORDER BY s.name LIMIT 20`, p.NetworkID, p.SeesAllStores(), p.StoreIDs)
	if err != nil {
		return me, err
	}
	me.Stores, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CourierStore])
	return me, err
}

// CourierHistoryItem — доставленный заказ в истории курьера.
type CourierHistoryItem struct {
	ID          string     `json:"id"`
	Number      int64      `json:"number"`
	StoreName   string     `json:"store_name"`
	Address     string     `json:"address"`
	Total       string     `json:"total"`
	Cash        bool       `json:"cash"`
	PickedUpAt  *time.Time `json:"picked_up_at"`
	DeliveredAt *time.Time `json:"delivered_at"`
}

type CourierHistory struct {
	Items      []CourierHistoryItem `json:"items"`
	Delivered  int                  `json:"delivered"`
	CashTotal  string               `json:"cash_total"`
	AvgMinutes int                  `json:"avg_minutes"` // от «забрал» до «доставил»
}

var tashkent = time.FixedZone("Asia/Tashkent", 5*3600)

// CourierHistory — доставленные заказы за период: today, yesterday, week (по Ташкенту).
func (s *Service) CourierHistory(ctx context.Context, p *identity.Principal, period string) (CourierHistory, error) {
	h := CourierHistory{Items: []CourierHistoryItem{}, CashTotal: "0.00"}
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return h, err
	}
	now := time.Now().In(tashkent)
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tashkent)
	from, to := day, day.AddDate(0, 0, 1)
	switch period {
	case "", "today":
	case "yesterday":
		from, to = day.AddDate(0, 0, -1), day
	case "week":
		from = day.AddDate(0, 0, -6)
	default:
		return h, apperr.Validation("period: today, yesterday или week")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT o.id, o.number, s.name, o.address, o.total::text, o.payment_provider = $4, o.picked_up_at, o.delivered_at
		FROM orders o JOIN stores s ON s.id = o.store_id
		WHERE o.courier_id = $1 AND o.status = 'delivered' AND o.delivered_at >= $2 AND o.delivered_at < $3
		ORDER BY o.delivered_at DESC LIMIT 300`, p.EmployeeID, from, to, CashOnDelivery)
	if err != nil {
		return h, err
	}
	h.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CourierHistoryItem])
	if err != nil {
		return h, err
	}
	var avg *float64
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, COALESCE(sum(o.total) FILTER (WHERE o.payment_provider = $4), 0)::numeric(18,2)::text,
		       avg(EXTRACT(EPOCH FROM o.delivered_at - o.picked_up_at) / 60) FILTER (WHERE o.picked_up_at IS NOT NULL)
		FROM orders o
		WHERE o.courier_id = $1 AND o.status = 'delivered' AND o.delivered_at >= $2 AND o.delivered_at < $3`,
		p.EmployeeID, from, to, CashOnDelivery).Scan(&h.Delivered, &h.CashTotal, &avg)
	if avg != nil {
		h.AvgMinutes = int(*avg + 0.5)
	}
	return h, err
}

type ShiftInput struct {
	OnShift *bool   `json:"on_shift"`
	Vehicle *string `json:"vehicle"`
}

// SetShift — курьер выходит на смену или уходит с неё, меняет транспорт.
func (s *Service) SetShift(ctx context.Context, p *identity.Principal, in ShiftInput) (CourierMe, error) {
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return CourierMe{}, err
	}
	if in.Vehicle != nil && vehicleSpeed[*in.Vehicle] == 0 {
		return CourierMe{}, apperr.Validation("vehicle: foot, bike, scooter или car")
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO couriers (employee_id, network_id, vehicle, on_shift)
		VALUES ($1, $2, COALESCE($3, 'foot'), COALESCE($4, false))
		ON CONFLICT (employee_id) DO UPDATE SET vehicle = COALESCE($3, couriers.vehicle),
		       on_shift = COALESCE($4, couriers.on_shift), updated_at = now(),
		       location = CASE WHEN $4 = false THEN NULL ELSE couriers.location END`,
		p.EmployeeID, p.NetworkID, in.Vehicle, in.OnShift); err != nil {
		return CourierMe{}, err
	}
	return s.CourierMe(ctx, p)
}

// StoreInfo — откуда забрать заказ.
type StoreInfo struct {
	Name    string   `json:"name"`
	Address string   `json:"address"`
	Phone   string   `json:"phone"`
	Lat     *float64 `json:"lat"`
	Lng     *float64 `json:"lng"`
}

type CourierOrder struct {
	Order Order     `json:"order"`
	Store StoreInfo `json:"store"`
	// Имя покупателя, сколько позиций, когда забран, брать ли наличные.
	CustomerName string     `json:"customer_name"`
	ItemsCount   int        `json:"items_count"`
	PickedUpAt   *time.Time `json:"picked_up_at"`
	Cash         bool       `json:"cash"`
}

func (s *Service) courierExtra(ctx context.Context, c *CourierOrder) error {
	c.Cash = c.Order.PaymentProvider == CashOnDelivery
	return s.pool.QueryRow(ctx, `
		SELECT COALESCE(NULLIF(btrim(cu.first_name), ''), u.full_name, ''),
		       (SELECT count(*) FROM order_items i WHERE i.order_id = o.id)::int, o.picked_up_at
		FROM orders o JOIN users u ON u.id = o.customer_id
		LEFT JOIN customers cu ON cu.user_id = o.customer_id
		WHERE o.id = $1`, c.Order.ID).Scan(&c.CustomerName, &c.ItemsCount, &c.PickedUpAt)
}

func (s *Service) storeInfo(ctx context.Context, storeID string) (StoreInfo, error) {
	var si StoreInfo
	err := s.pool.QueryRow(ctx, `SELECT name, address, phone, ST_Y(location::geometry), ST_X(location::geometry) FROM stores WHERE id = $1`, storeID).
		Scan(&si.Name, &si.Address, &si.Phone, &si.Lat, &si.Lng)
	return si, err
}

// CourierOrders — заказы курьера: активные и доставленные сегодня.
func (s *Service) CourierOrders(ctx context.Context, p *identity.Principal) ([]CourierOrder, error) {
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, orderSelect+`
		WHERE o.courier_id = $1 AND (o.status IN ('accepted', 'picking', 'picked', 'delivering')
		      OR (o.status = 'delivered' AND o.delivered_at > now() - interval '12 hours'))
		ORDER BY o.status = 'delivered', COALESCE(o.delivery_from, o.paid_at, o.created_at)`, p.EmployeeID)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, scanOrder)
	if err != nil {
		return nil, err
	}
	out := make([]CourierOrder, 0, len(list))
	for _, o := range list {
		si, err := s.storeInfo(ctx, o.StoreID)
		if err != nil {
			return nil, err
		}
		c := CourierOrder{Order: o, Store: si}
		if err := s.courierExtra(ctx, &c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

func (s *Service) courierOrder(ctx context.Context, p *identity.Principal, id string) (CourierOrder, error) {
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return CourierOrder{}, err
	}
	o, err := s.getOrder(ctx, s.pool, id)
	if err != nil {
		return CourierOrder{}, err
	}
	if o.CourierID == nil || *o.CourierID != p.EmployeeID {
		return CourierOrder{}, apperr.NotFound("заказ не найден")
	}
	si, err := s.storeInfo(ctx, o.StoreID)
	if err != nil {
		return CourierOrder{}, err
	}
	c := CourierOrder{Order: o, Store: si}
	return c, s.courierExtra(ctx, &c)
}

func (s *Service) CourierOrder(ctx context.Context, p *identity.Principal, id string) (CourierOrder, error) {
	return s.courierOrder(ctx, p, id)
}

// PickUp — курьер забрал собранный заказ: «в пути», считаем время прибытия.
func (s *Service) PickUp(ctx context.Context, p *identity.Principal, id string) (CourierOrder, error) {
	if _, err := s.courierOrder(ctx, p, id); err != nil {
		return CourierOrder{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusPicked); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE orders SET status = 'delivering', picked_up_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		if err := updateETA(ctx, tx, p.EmployeeID, id); err != nil {
			return err
		}
		return addHistory(ctx, tx, id, StatusDelivering, "store:"+p.EmployeeID, "")
	})
	if err != nil {
		return CourierOrder{}, err
	}
	return s.courierOrder(ctx, p, id)
}

// CourierDelivered — курьер вручил заказ.
func (s *Service) CourierDelivered(ctx context.Context, p *identity.Principal, id string) (CourierOrder, error) {
	if _, err := s.courierOrder(ctx, p, id); err != nil {
		return CourierOrder{}, err
	}
	if err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		return markDelivered(ctx, tx, id, "store:"+p.EmployeeID, StatusDelivering)
	}); err != nil {
		return CourierOrder{}, err
	}
	return s.courierOrder(ctx, p, id)
}

type LocationInput struct {
	Lat      float64 `json:"lat"`
	Lng      float64 `json:"lng"`
	Accuracy *int    `json:"accuracy"`
	Heading  *int    `json:"heading"`
}

// Location — точка курьера (раз в 10–15 секунд, пока он на смене). Заодно
// пересчитывается время прибытия заказов «в пути».
func (s *Service) Location(ctx context.Context, p *identity.Principal, in LocationInput) error {
	if err := p.Require(identity.PermOrdersDeliver); err != nil {
		return err
	}
	if !validCoords(in.Lat, in.Lng) {
		return apperr.Validation("lat/lng: неверные координаты")
	}
	if in.Heading != nil && (*in.Heading < 0 || *in.Heading > 359) {
		in.Heading = nil
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			INSERT INTO couriers (employee_id, network_id, on_shift, location, accuracy_m, heading, located_at)
			VALUES ($1, $2, true, ST_SetSRID(ST_MakePoint($4, $3), 4326)::geography, $5, $6, now())
			ON CONFLICT (employee_id) DO UPDATE SET location = EXCLUDED.location, accuracy_m = EXCLUDED.accuracy_m,
			       heading = EXCLUDED.heading, located_at = now(), updated_at = now()`,
			p.EmployeeID, p.NetworkID, in.Lat, in.Lng, in.Accuracy, in.Heading); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id FROM orders WHERE courier_id = $1 AND status = 'delivering'`, p.EmployeeID)
		if err != nil {
			return err
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		for _, id := range ids {
			if err := updateETA(ctx, tx, p.EmployeeID, id); err != nil {
				return err
			}
		}
		return nil
	})
}

// updateETA: от свежей точки курьера (или от магазина) до покупателя.
func updateETA(ctx context.Context, q db.Querier, courierID, orderID string) error {
	var dist float64
	var vehicle string
	err := q.QueryRow(ctx, `
		SELECT ST_Distance(o.location, CASE WHEN c.location IS NOT NULL AND c.located_at > now() - make_interval(secs => $3)
		                                    THEN c.location ELSE s.location END),
		       COALESCE(c.vehicle, 'foot')
		FROM orders o JOIN stores s ON s.id = o.store_id
		LEFT JOIN couriers c ON c.employee_id = $2
		WHERE o.id = $1`, orderID, courierID, locationFresh.Seconds()).Scan(&dist, &vehicle)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `UPDATE orders SET eta_at = now() + make_interval(secs => $2) WHERE id = $1`,
		orderID, etaFor(dist, vehicle).Seconds())
	return err
}

// ------------------------------------------------------------ покупатель

type Point struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

type TrackingCourier struct {
	Name      string     `json:"name"`
	Vehicle   string     `json:"vehicle"`
	Phone     *string    `json:"phone"` // только пока заказ в пути
	Location  *Point     `json:"location"`
	LocatedAt *time.Time `json:"located_at"`
}

type Tracking struct {
	Status      string           `json:"status"`
	StatusTitle string           `json:"status_title"`
	EtaAt       *time.Time       `json:"eta_at"`
	EtaMinutes  *int             `json:"eta_minutes"`
	Courier     *TrackingCourier `json:"courier"`
	Store       Point            `json:"store"`
	StoreName   string           `json:"store_name"`
	Destination Point            `json:"destination"`
}

// ClientTracking — где заказ: курьер, его точка и время прибытия.
func (s *Service) ClientTracking(ctx context.Context, p *identity.Principal, id string) (Tracking, error) {
	o, err := s.ClientGetOrder(ctx, p, id)
	if err != nil {
		return Tracking{}, err
	}
	t := Tracking{Status: o.Status, StatusTitle: o.StatusTitle, Destination: Point{o.Lat, o.Lng}, StoreName: o.StoreName}
	si, err := s.storeInfo(ctx, o.StoreID)
	if err != nil {
		return t, err
	}
	if si.Lat != nil && si.Lng != nil {
		t.Store = Point{*si.Lat, *si.Lng}
	}
	if o.Status == StatusDelivering && o.EtaAt != nil {
		t.EtaAt = o.EtaAt
		m := int(math.Max(1, math.Ceil(time.Until(*o.EtaAt).Minutes())))
		t.EtaMinutes = &m
	}
	if o.CourierID == nil || o.CourierName == nil || o.Status == StatusDelivered || o.Status == StatusCancelled {
		return t, nil
	}
	c := TrackingCourier{Name: *o.CourierName}
	var phone string
	var lat, lng *float64
	var at *time.Time
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(c.vehicle, 'foot'), u.phone, ST_Y(c.location::geometry), ST_X(c.location::geometry), c.located_at
		FROM employees e JOIN users u ON u.id = e.user_id LEFT JOIN couriers c ON c.employee_id = e.id
		WHERE e.id = $1`, *o.CourierID).Scan(&c.Vehicle, &phone, &lat, &lng, &at); err != nil {
		return t, err
	}
	if o.Status == StatusDelivering {
		c.Phone = &phone
		if lat != nil && lng != nil && at != nil && time.Since(*at) < locationFresh {
			c.Location, c.LocatedAt = &Point{*lat, *lng}, at
		}
	}
	t.Courier = &c
	return t, nil
}
