// Package delivery — настройки доставки магазина (часы работы, радиус,
// зоны на карте, правила стоимости), расчёт доставки и поиск магазинов,
// которые доставляют по адресу.
package delivery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Tashkent — часовой пояс часов работы (UTC+5, без летнего времени).
var Tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool, now: time.Now} }

// -------------------------------------------------------------- настройки

type WorkingHours struct {
	Weekday int    `json:"weekday"` // 0 — воскресенье … 6 — суббота
	Opens   string `json:"opens"`   // "09:00"
	Closes  string `json:"closes"`  // "22:00"; меньше opens — работа после полуночи
}

type Rule struct {
	Type   string          `json:"type"`
	Params json.RawMessage `json:"params"`
	Sort   int             `json:"sort"`
}

type Settings struct {
	AcceptsOnline   bool           `json:"accepts_online"`
	MinOrderAmount  string         `json:"min_order_amount"`
	DeliveryRadiusM int            `json:"delivery_radius_m"`
	WorkingHours    []WorkingHours `json:"working_hours"`
	Rules           []Rule         `json:"rules"`
	// Обещанное время доставки в минутах («25–35 мин»); null — не показывать.
	EtaMin *int `json:"eta_min"`
	EtaMax *int `json:"eta_max"`
	// Доставка ко времени.
	Slots SlotSettings `json:"slots"`
}

type SettingsInput struct {
	AcceptsOnline   *bool              `json:"accepts_online"`
	MinOrderAmount  *money.Amount      `json:"min_order_amount"`
	DeliveryRadiusM *int               `json:"delivery_radius_m"`
	WorkingHours    *[]WorkingHours    `json:"working_hours"`
	Rules           *[]Rule            `json:"rules"`
	EtaMin          OptInt             `json:"eta_min"` // null — убрать обещанное время
	EtaMax          OptInt             `json:"eta_max"`
	Slots           *SlotSettingsInput `json:"slots"`
}

// OptInt — число, которое можно явно сбросить: поле не передано — не
// менять, null — очистить, число — записать.
type OptInt struct {
	Set   bool
	Value *int
}

func (o *OptInt) UnmarshalJSON(b []byte) error {
	o.Set = true
	if string(b) == "null" {
		o.Value = nil
		return nil
	}
	var v int
	if err := json.Unmarshal(b, &v); err != nil {
		return errors.New("ожидается целое число или null")
	}
	o.Value = &v
	return nil
}

func checkStore(p *identity.Principal, storeID string) error {
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return apperr.NotFound("магазин не найден")
	}
	return nil
}

func (s *Service) GetSettings(ctx context.Context, p *identity.Principal, storeID string) (Settings, error) {
	if err := checkStore(p, storeID); err != nil {
		return Settings{}, err
	}
	return getSettings(ctx, s.pool, p.NetworkID, storeID)
}

func getSettings(ctx context.Context, q db.Querier, networkID, storeID string) (Settings, error) {
	var st Settings
	err := q.QueryRow(ctx, `SELECT accepts_online, min_order_amount::text, delivery_radius_m, eta_min, eta_max FROM stores
		WHERE id = $1 AND network_id = $2`, storeID, networkID).Scan(&st.AcceptsOnline, &st.MinOrderAmount, &st.DeliveryRadiusM, &st.EtaMin, &st.EtaMax)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, apperr.NotFound("магазин не найден")
	}
	if err != nil {
		return st, err
	}
	rows, err := q.Query(ctx, `SELECT weekday, to_char(opens, 'HH24:MI'), to_char(closes, 'HH24:MI')
		FROM store_working_hours WHERE store_id = $1 ORDER BY weekday`, storeID)
	if err != nil {
		return st, err
	}
	if st.WorkingHours, err = pgx.CollectRows(rows, pgx.RowToStructByPos[WorkingHours]); err != nil {
		return st, err
	}
	rows, err = q.Query(ctx, `SELECT type, params, sort FROM delivery_rules WHERE store_id = $1 ORDER BY sort, id`, storeID)
	if err != nil {
		return st, err
	}
	if st.Rules, err = pgx.CollectRows(rows, pgx.RowToStructByPos[Rule]); err != nil {
		return st, err
	}
	st.Slots, err = getSlotSettings(ctx, q, storeID, false)
	return st, err
}

// ruleParams — параметры правил доставки.
type ruleParams struct {
	Price  *money.Amount `json:"price"`
	Base   *money.Amount `json:"base"`
	PerKm  *money.Amount `json:"per_km"`
	Amount *money.Amount `json:"amount"`
}

func parseRule(r Rule) (ruleParams, error) {
	var p ruleParams
	if len(r.Params) > 0 {
		dec := json.NewDecoder(strings.NewReader(string(r.Params)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&p); err != nil {
			return p, fmt.Errorf("неверные параметры правила %s: %w", r.Type, err)
		}
	}
	switch r.Type {
	case "fixed":
		if p.Price == nil {
			return p, errors.New("fixed: нужен price")
		}
	case "distance":
		if p.Base == nil || p.PerKm == nil {
			return p, errors.New("distance: нужны base и per_km")
		}
	case "zone":
	case "free_from":
		if p.Amount == nil {
			return p, errors.New("free_from: нужен amount")
		}
	default:
		return p, errors.New("type: ожидается fixed, distance, zone или free_from")
	}
	return p, nil
}

func parseClock(s string) (time.Duration, error) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, errors.New("время в формате ЧЧ:ММ")
	}
	return time.Duration(t.Hour())*time.Hour + time.Duration(t.Minute())*time.Minute, nil
}

// SaveSettings меняет настройки доставки. working_hours и rules заменяются целиком.
func (s *Service) SaveSettings(ctx context.Context, p *identity.Principal, storeID string, in SettingsInput) (Settings, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Settings{}, err
	}
	if err := checkStore(p, storeID); err != nil {
		return Settings{}, err
	}
	if in.DeliveryRadiusM != nil && (*in.DeliveryRadiusM < 0 || *in.DeliveryRadiusM > 100_000) {
		return Settings{}, apperr.Validation("delivery_radius_m: от 0 до 100 000 метров")
	}
	for _, v := range []*int{in.EtaMin.Value, in.EtaMax.Value} {
		if v != nil && (*v < 5 || *v > 600) {
			return Settings{}, apperr.Validation("eta_min/eta_max: от 5 до 600 минут")
		}
	}
	if in.EtaMin.Value != nil && in.EtaMax.Value != nil && *in.EtaMin.Value > *in.EtaMax.Value {
		return Settings{}, apperr.Validation("eta_min: не больше eta_max")
	}
	if in.WorkingHours != nil {
		days := map[int]bool{}
		for _, h := range *in.WorkingHours {
			if h.Weekday < 0 || h.Weekday > 6 || days[h.Weekday] {
				return Settings{}, apperr.Validation("working_hours: день недели 0–6, без повторов")
			}
			days[h.Weekday] = true
			o, err1 := parseClock(h.Opens)
			c, err2 := parseClock(h.Closes)
			if err1 != nil || err2 != nil || o == c {
				return Settings{}, apperr.Validation("working_hours: время ЧЧ:ММ, открытие и закрытие различаются")
			}
		}
	}
	if in.Slots != nil {
		if err := in.Slots.validate(); err != nil {
			return Settings{}, err
		}
	}
	if in.Rules != nil {
		for _, r := range *in.Rules {
			if _, err := parseRule(r); err != nil {
				return Settings{}, apperr.Validation("rules: " + err.Error())
			}
		}
	}

	var out Settings
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var minOrder *string
		if in.MinOrderAmount != nil {
			v := string(*in.MinOrderAmount)
			minOrder = &v
		}
		if in.AcceptsOnline != nil && *in.AcceptsOnline {
			var hasLocation bool
			if err := tx.QueryRow(ctx, `SELECT location IS NOT NULL FROM stores WHERE id = $1`, storeID).Scan(&hasLocation); err != nil {
				return err
			}
			if !hasLocation {
				return apperr.Validation("accepts_online: сначала укажите точку магазина на карте (lat, lng)")
			}
		}
		if _, err := tx.Exec(ctx, `
			UPDATE stores SET accepts_online = COALESCE($3, accepts_online),
			       min_order_amount = COALESCE($4::numeric, min_order_amount),
			       delivery_radius_m = COALESCE($5, delivery_radius_m),
			       eta_min = CASE WHEN $6 THEN $7::int ELSE eta_min END,
			       eta_max = CASE WHEN $8 THEN $9::int ELSE eta_max END
			WHERE id = $1 AND network_id = $2`, storeID, p.NetworkID, in.AcceptsOnline, minOrder, in.DeliveryRadiusM,
			in.EtaMin.Set, in.EtaMin.Value, in.EtaMax.Set, in.EtaMax.Value); err != nil {
			if db.IsCheckViolation(err) {
				return apperr.Validation("eta_min: не больше eta_max")
			}
			return err
		}
		if in.WorkingHours != nil {
			if _, err := tx.Exec(ctx, `DELETE FROM store_working_hours WHERE store_id = $1`, storeID); err != nil {
				return err
			}
			for _, h := range *in.WorkingHours {
				if _, err := tx.Exec(ctx, `INSERT INTO store_working_hours (store_id, weekday, opens, closes) VALUES ($1, $2, $3::time, $4::time)`,
					storeID, h.Weekday, h.Opens, h.Closes); err != nil {
					return err
				}
			}
		}
		if in.Rules != nil {
			if _, err := tx.Exec(ctx, `DELETE FROM delivery_rules WHERE store_id = $1`, storeID); err != nil {
				return err
			}
			for _, r := range *in.Rules {
				params := r.Params
				if len(params) == 0 {
					params = json.RawMessage(`{}`)
				}
				if _, err := tx.Exec(ctx, `INSERT INTO delivery_rules (network_id, store_id, type, params, sort) VALUES ($1, $2, $3, $4, $5)`,
					p.NetworkID, storeID, r.Type, params, r.Sort); err != nil {
					return err
				}
			}
		}
		if in.Slots != nil {
			if err := saveSlotSettings(ctx, tx, storeID, *in.Slots); err != nil {
				return err
			}
		}
		var err error
		out, err = getSettings(ctx, tx, p.NetworkID, storeID)
		return err
	})
	return out, err
}

// ------------------------------------------------------------------- зоны

type Zone struct {
	ID       string       `json:"id"`
	Name     string       `json:"name"`
	Price    string       `json:"price"`
	IsActive bool         `json:"is_active"`
	Polygon  [][2]float64 `json:"polygon"` // [[lng, lat], ...]
}

type ZoneInput struct {
	Name     *string       `json:"name"`
	Price    *money.Amount `json:"price"`
	IsActive *bool         `json:"is_active"`
	Polygon  *[][2]float64 `json:"polygon"`
}

func polygonWKT(pts [][2]float64) (string, error) {
	if len(pts) < 3 || len(pts) > 500 {
		return "", errors.New("polygon: от 3 до 500 точек [lng, lat]")
	}
	ring := append([][2]float64{}, pts...)
	if ring[0] != ring[len(ring)-1] {
		ring = append(ring, ring[0])
	}
	parts := make([]string, len(ring))
	for i, p := range ring {
		if p[0] < -180 || p[0] > 180 || p[1] < -90 || p[1] > 90 {
			return "", errors.New("polygon: координаты вне диапазона")
		}
		parts[i] = fmt.Sprintf("%f %f", p[0], p[1])
	}
	return "POLYGON((" + strings.Join(parts, ", ") + "))", nil
}

const zoneSelect = `SELECT id, name, price::text, is_active, ST_AsGeoJSON(area)::jsonb -> 'coordinates' -> 0 FROM delivery_zones`

func scanZone(row pgx.CollectableRow) (Zone, error) {
	var z Zone
	var coords []byte
	if err := row.Scan(&z.ID, &z.Name, &z.Price, &z.IsActive, &coords); err != nil {
		return z, err
	}
	err := json.Unmarshal(coords, &z.Polygon)
	return z, err
}

func (s *Service) ListZones(ctx context.Context, p *identity.Principal, storeID string) ([]Zone, error) {
	if err := checkStore(p, storeID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, zoneSelect+` WHERE store_id = $1 AND network_id = $2 ORDER BY name`, storeID, p.NetworkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanZone)
}

func (s *Service) SaveZone(ctx context.Context, p *identity.Principal, storeID, id string, in ZoneInput) (Zone, error) {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return Zone{}, err
	}
	if err := checkStore(p, storeID); err != nil {
		return Zone{}, err
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) == "" {
		return Zone{}, apperr.Validation("name: не может быть пустым")
	}
	var wkt *string
	if in.Polygon != nil {
		w, err := polygonWKT(*in.Polygon)
		if err != nil {
			return Zone{}, apperr.Validation(err.Error())
		}
		wkt = &w
	}
	var price *string
	if in.Price != nil {
		v := string(*in.Price)
		price = &v
	}
	var err error
	if id == "" {
		if in.Name == nil || wkt == nil {
			return Zone{}, apperr.Validation("name и polygon обязательны")
		}
		err = s.pool.QueryRow(ctx, `
			INSERT INTO delivery_zones (network_id, store_id, name, area, price)
			VALUES ($1, $2, $3, ST_GeogFromText($4), COALESCE($5::numeric, 0)) RETURNING id`,
			p.NetworkID, storeID, strings.TrimSpace(*in.Name), *wkt, price).Scan(&id)
	} else {
		var tag interface{ RowsAffected() int64 }
		tag, err = s.pool.Exec(ctx, `
			UPDATE delivery_zones SET name = COALESCE($4, name), price = COALESCE($5::numeric, price),
			       is_active = COALESCE($6, is_active),
			       area = CASE WHEN $7::text IS NULL THEN area ELSE ST_GeogFromText($7) END
			WHERE id = $1 AND store_id = $2 AND network_id = $3`,
			id, storeID, p.NetworkID, trimPtr(in.Name), price, in.IsActive, wkt)
		if err == nil && tag.RowsAffected() == 0 {
			return Zone{}, apperr.NotFound("зона не найдена")
		}
	}
	if err != nil {
		if strings.Contains(err.Error(), "geometry") || strings.Contains(err.Error(), "parse") {
			return Zone{}, apperr.Validation("polygon: неверный многоугольник")
		}
		return Zone{}, err
	}
	rows, err := s.pool.Query(ctx, zoneSelect+` WHERE id = $1`, id)
	if err != nil {
		return Zone{}, err
	}
	return pgx.CollectExactlyOneRow(rows, scanZone)
}

func (s *Service) DeleteZone(ctx context.Context, p *identity.Principal, storeID, id string) error {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return err
	}
	if err := checkStore(p, storeID); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, `DELETE FROM delivery_zones WHERE id = $1 AND store_id = $2 AND network_id = $3`, id, storeID, p.NetworkID)
	if err == nil && tag.RowsAffected() == 0 {
		return apperr.NotFound("зона не найдена")
	}
	return err
}

func trimPtr(p *string) *string {
	if p == nil {
		return nil
	}
	t := strings.TrimSpace(*p)
	return &t
}

// --------------------------------------------------------- расчёт доставки

// Quote — можно ли доставить по адресу и сколько это стоит.
type Quote struct {
	DistanceM      int    `json:"distance_m"`
	DeliveryFee    string `json:"delivery_fee"`
	MinOrderAmount string `json:"min_order_amount"`
	// Сколько осталось до бесплатной доставки (null — такого правила нет).
	FreeFrom *string `json:"free_from"`
	IsOpen   bool    `json:"is_open"`
}

var ErrNotDeliverable = apperr.Conflict("not_deliverable", "магазин не доставляет по этому адресу")

// QuoteFor считает доставку из магазина в точку для суммы товаров subtotal.
func (s *Service) QuoteFor(ctx context.Context, q db.Querier, storeID string, lat, lng float64, subtotal string) (Quote, error) {
	var out Quote
	var radius int
	var hasZones, inRadius, accepts bool
	var dist float64
	var zonePrice *string
	err := q.QueryRow(ctx, `
		WITH pt AS (SELECT ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography AS g)
		SELECT s.accepts_online AND s.status = 'active' AND n.status = 'active' AND s.location IS NOT NULL,
		       s.min_order_amount::text, s.delivery_radius_m,
		       COALESCE(ST_Distance(s.location, pt.g), 0),
		       EXISTS (SELECT 1 FROM delivery_zones z WHERE z.store_id = s.id AND z.is_active),
		       COALESCE(ST_DWithin(s.location, pt.g, s.delivery_radius_m), false),
		       (SELECT z.price::text FROM delivery_zones z
		        WHERE z.store_id = s.id AND z.is_active AND ST_Covers(z.area, pt.g) ORDER BY z.price LIMIT 1)
		FROM stores s JOIN networks n ON n.id = s.network_id, pt
		WHERE s.id = $1`, storeID, lat, lng).Scan(&accepts, &out.MinOrderAmount, &radius, &dist, &hasZones, &inRadius, &zonePrice)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("магазин не найден")
	}
	if err != nil {
		return out, err
	}
	if !accepts {
		return out, apperr.Conflict("store_not_accepting", "магазин сейчас не принимает онлайн-заказы")
	}
	if (hasZones && zonePrice == nil) || (!hasZones && !inRadius) {
		return out, ErrNotDeliverable
	}
	out.DistanceM = int(math.Round(dist))

	settings, err := getSettings(ctx, q, networkOf(ctx, q, storeID), storeID)
	if err != nil {
		return out, err
	}
	out.IsOpen = isOpen(settings.WorkingHours, s.now())

	fee := money.D("0")
	feeSet := false
	sub := money.D(subtotal)
	for _, r := range settings.Rules {
		p, err := parseRule(r)
		if err != nil {
			continue
		}
		switch r.Type {
		case "free_from":
			amount := money.D(string(*p.Amount))
			left := amount.Sub(sub)
			if left.Sign() < 0 {
				left = money.D("0")
			}
			v := left.Money()
			out.FreeFrom = &v
		case "fixed":
			if !feeSet {
				fee, feeSet = money.D(string(*p.Price)), true
			}
		case "distance":
			if !feeSet {
				km := money.D(fmt.Sprintf("%d", int(math.Ceil(dist/1000))))
				fee, feeSet = money.D(string(*p.Base)).Add(money.D(string(*p.PerKm)).Mul(km)), true
			}
		case "zone":
			if !feeSet && zonePrice != nil {
				fee, feeSet = money.D(*zonePrice), true
			}
		}
	}
	if out.FreeFrom != nil && *out.FreeFrom == "0.00" {
		fee = money.D("0")
	}
	out.DeliveryFee = fee.Money()
	return out, nil
}

func networkOf(ctx context.Context, q db.Querier, storeID string) string {
	var id string
	_ = q.QueryRow(ctx, `SELECT network_id FROM stores WHERE id = $1`, storeID).Scan(&id)
	return id
}

// isOpen: нет расписания — круглосуточно; интервал через полночь поддерживается.
func isOpen(hours []WorkingHours, now time.Time) bool {
	if len(hours) == 0 {
		return true
	}
	t := now.In(Tashkent)
	minute := time.Duration(t.Hour())*time.Hour + time.Duration(t.Minute())*time.Minute
	today := int(t.Weekday())
	yesterday := (today + 6) % 7
	for _, h := range hours {
		o, _ := parseClock(h.Opens)
		c, _ := parseClock(h.Closes)
		switch {
		case h.Weekday == today && o < c && minute >= o && minute < c:
			return true
		case h.Weekday == today && o > c && minute >= o: // работает после полуночи, до полуночи
			return true
		case h.Weekday == yesterday && o > c && minute < c: // хвост вчерашней смены
			return true
		}
	}
	return false
}

// ------------------------------------------------------ магазины рядом

type NearbyStore struct {
	ID          string   `json:"id"`
	NetworkID   string   `json:"network_id"`
	NetworkName string   `json:"network_name"`
	Name        string   `json:"name"`
	Address     string   `json:"address"`
	Lat         float64  `json:"lat"`
	Lng         float64  `json:"lng"`
	Quote       Quote    `json:"delivery"`
	Recommended bool     `json:"recommended"`
	Tags        []string `json:"tags,omitempty"`
	LogoURL     string   `json:"logo_url"`
	EtaMin      *int     `json:"eta_min"`
	EtaMax      *int     `json:"eta_max"`
}

// Nearby — магазины, которые доставляют в точку, ближайшие первыми.
// Три ближайших открытых отмечены recommended.
func (s *Service) Nearby(ctx context.Context, lat, lng float64) ([]NearbyStore, error) {
	if lat < -90 || lat > 90 || lng < -180 || lng > 180 {
		return nil, apperr.Validation("lat/lng: координаты вне диапазона")
	}
	rows, err := s.pool.Query(ctx, `
		WITH pt AS (SELECT ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography AS g)
		SELECT s.id, s.network_id, n.name, s.name, s.address, ST_Y(s.location::geometry), ST_X(s.location::geometry),
		       s.logo_url, s.eta_min, s.eta_max
		FROM stores s JOIN networks n ON n.id = s.network_id, pt
		WHERE s.accepts_online AND s.status = 'active' AND n.status = 'active' AND s.location IS NOT NULL
		  AND `+ActiveSubscriptionSQL+`
		  AND (EXISTS (SELECT 1 FROM delivery_zones z WHERE z.store_id = s.id AND z.is_active AND ST_Covers(z.area, pt.g))
		       OR (NOT EXISTS (SELECT 1 FROM delivery_zones z WHERE z.store_id = s.id AND z.is_active)
		           AND ST_DWithin(s.location, pt.g, s.delivery_radius_m)))
		ORDER BY ST_Distance(s.location, pt.g)
		LIMIT 50`, lat, lng)
	if err != nil {
		return nil, err
	}
	stores, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (NearbyStore, error) {
		var st NearbyStore
		err := r.Scan(&st.ID, &st.NetworkID, &st.NetworkName, &st.Name, &st.Address, &st.Lat, &st.Lng,
			&st.LogoURL, &st.EtaMin, &st.EtaMax)
		return st, err
	})
	if err != nil {
		return nil, err
	}
	out := make([]NearbyStore, 0, len(stores))
	recommended := 0
	for _, st := range stores {
		q, err := s.QuoteFor(ctx, s.pool, st.ID, lat, lng, "0")
		if err != nil {
			continue
		}
		st.Quote = q
		if q.IsOpen && recommended < 3 {
			st.Recommended = true
			recommended++
		}
		out = append(out, st)
	}
	return out, nil
}

// ActiveSubscriptionSQL — условие «у сети магазина нет просроченного счёта
// за подписку» (модуль billing). Магазины должников не показываются в
// приложении. Использует алиас s (stores).
const ActiveSubscriptionSQL = `NOT EXISTS (SELECT 1 FROM subscription_invoices si
	WHERE si.network_id = s.network_id AND si.status = 'unpaid' AND si.due_date < (now() AT TIME ZONE 'Asia/Tashkent')::date)`
