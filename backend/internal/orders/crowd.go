package orders

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// Crowd-доставка: курьеры «по пути». Обычный пользователь входит в
// приложение курьера по телефону, личность подтверждает продавец в любом
// подключённом магазине, затем курьер берёт собранные заказы, которые ему
// по дороге. Заказ выдаётся по коду (QR курьера), вручается по коду,
// который называет покупатель.

// CrowdSettings — правила crowd-доставки (меняет супер-админ).
type CrowdSettings struct {
	CourierFee         string `json:"courier_fee"`
	PlatformFee        string `json:"platform_fee"`
	LongWaitBonus      string `json:"long_wait_bonus"`
	LongWaitMinutes    int    `json:"long_wait_minutes"`
	WaitMinutes        int    `json:"wait_minutes"`
	PickupMinutes      int    `json:"pickup_minutes"`
	RadiusM            int    `json:"radius_m"`
	DetourM            int    `json:"detour_m"`
	StoreBonus         string `json:"store_bonus"`
	StoreBonusCount    int    `json:"store_bonus_count"`
	StoreBonusHoldDays int    `json:"store_bonus_hold_days"`
	NewbieLimit        string `json:"newbie_limit"`
	NewbieParallel     int    `json:"newbie_parallel"`
	ReliableAfter      int    `json:"reliable_after"`
	ReliableOntime     int    `json:"reliable_ontime"`
	ReliableLimit      string `json:"reliable_limit"`
	ReliableParallel   int    `json:"reliable_parallel"`
	TrustedAfter       int    `json:"trusted_after"`
	TrustedOntime      int    `json:"trusted_ontime"`
	TrustedLimit       string `json:"trusted_limit"`
	TrustedParallel    int    `json:"trusted_parallel"`
}

const crowdSettingsCols = `courier_fee::text, platform_fee::text, long_wait_bonus::text, long_wait_minutes, wait_minutes,
	pickup_minutes, radius_m, detour_m, store_bonus::text, store_bonus_count, store_bonus_hold_days,
	newbie_limit::text, newbie_parallel, reliable_after, reliable_ontime, reliable_limit::text, reliable_parallel,
	trusted_after, trusted_ontime, trusted_limit::text, trusted_parallel`

func (s *Service) crowdSettings(ctx context.Context, q db.Querier) (CrowdSettings, error) {
	var c CrowdSettings
	err := q.QueryRow(ctx, `SELECT `+crowdSettingsCols+` FROM crowd_settings`).Scan(
		&c.CourierFee, &c.PlatformFee, &c.LongWaitBonus, &c.LongWaitMinutes, &c.WaitMinutes,
		&c.PickupMinutes, &c.RadiusM, &c.DetourM, &c.StoreBonus, &c.StoreBonusCount, &c.StoreBonusHoldDays,
		&c.NewbieLimit, &c.NewbieParallel, &c.ReliableAfter, &c.ReliableOntime, &c.ReliableLimit, &c.ReliableParallel,
		&c.TrustedAfter, &c.TrustedOntime, &c.TrustedLimit, &c.TrustedParallel)
	return c, err
}

// CrowdLevel — уровень доверия: от него зависят лимит суммы и число заказов сразу.
type CrowdLevel struct {
	Key      string `json:"key"` // none, newbie, reliable, trusted
	Title    string `json:"title"`
	Limit    string `json:"limit"`
	Parallel int    `json:"parallel"`
	// Следующий уровень: сколько ещё доставок и с каким процентом вовремя.
	Next *CrowdNextLevel `json:"next"`
}

type CrowdNextLevel struct {
	Title     string `json:"title"`
	After     int    `json:"after"`
	Ontime    int    `json:"ontime"`
	Remaining int    `json:"remaining"`
	Limit     string `json:"limit"`
	Parallel  int    `json:"parallel"`
}

// CrowdStats — история курьера.
type CrowdStats struct {
	Delivered  int `json:"delivered"`
	OntimePct  int `json:"ontime_pct"`
	Cancels    int `json:"cancels"`
	Violations int `json:"violations"`
	// Нарушения за 30 дней: с ними уровень не повышается.
	RecentViolations int `json:"recent_violations"`
}

func crowdLevel(cs CrowdSettings, status string, st CrowdStats) CrowdLevel {
	if status != "active" {
		return CrowdLevel{Key: "none", Title: "Не проверен", Limit: "0.00"}
	}
	clean := st.RecentViolations == 0
	trusted := st.Delivered >= cs.TrustedAfter && st.OntimePct >= cs.TrustedOntime && clean
	reliable := st.Delivered >= cs.ReliableAfter && st.OntimePct >= cs.ReliableOntime && clean
	switch {
	case trusted:
		return CrowdLevel{Key: "trusted", Title: "Проверенный", Limit: cs.TrustedLimit, Parallel: cs.TrustedParallel}
	case reliable:
		return CrowdLevel{Key: "reliable", Title: "Надёжный", Limit: cs.ReliableLimit, Parallel: cs.ReliableParallel,
			Next: &CrowdNextLevel{Title: "Проверенный", After: cs.TrustedAfter, Ontime: cs.TrustedOntime,
				Remaining: max(0, cs.TrustedAfter-st.Delivered), Limit: cs.TrustedLimit, Parallel: cs.TrustedParallel}}
	default:
		return CrowdLevel{Key: "newbie", Title: "Новичок", Limit: cs.NewbieLimit, Parallel: cs.NewbieParallel,
			Next: &CrowdNextLevel{Title: "Надёжный", After: cs.ReliableAfter, Ontime: cs.ReliableOntime,
				Remaining: max(0, cs.ReliableAfter-st.Delivered), Limit: cs.ReliableLimit, Parallel: cs.ReliableParallel}}
	}
}

// onTimeSQL — доставлен вовремя: до конца окна, а «как можно скорее» — за час после принятия.
const onTimeSQL = `o.delivered_at <= COALESCE(o.delivery_to, o.crowd_accepted_at + interval '60 minutes')`

func crowdStats(ctx context.Context, q db.Querier, courierID string) (CrowdStats, error) {
	var st CrowdStats
	var ontime int
	err := q.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE o.status = 'delivered')::int,
		       count(*) FILTER (WHERE o.status = 'delivered' AND `+onTimeSQL+`)::int,
		       (SELECT count(*) FROM courier_incidents i WHERE i.courier_id = $1 AND i.kind IN ('released', 'pickup_timeout'))::int,
		       (SELECT count(*) FROM courier_incidents i WHERE i.courier_id = $1 AND i.violation)::int,
		       (SELECT count(*) FROM courier_incidents i WHERE i.courier_id = $1 AND i.violation AND i.created_at > now() - interval '30 days')::int
		FROM orders o WHERE o.crowd_courier_id = $1`, courierID).Scan(&st.Delivered, &ontime, &st.Cancels, &st.Violations, &st.RecentViolations)
	if st.Delivered > 0 {
		st.OntimePct = int(math.Round(float64(ontime) * 100 / float64(st.Delivered)))
	} else {
		st.OntimePct = 100
	}
	return st, err
}

// ------------------------------------------------------------ курьер

type CrowdDest struct {
	Lat   float64 `json:"lat"`
	Lng   float64 `json:"lng"`
	Title string  `json:"title"`
}

type CrowdVerification struct {
	StoreName string    `json:"store_name"`
	DocType   string    `json:"doc_type"`
	At        time.Time `json:"at"`
}

type CrowdMe struct {
	UserID        string             `json:"user_id"`
	Code          string             `json:"code"`
	Status        string             `json:"status"` // unverified, active, blocked
	FullName      string             `json:"full_name"`
	Phone         string             `json:"phone"`
	Vehicle       string             `json:"vehicle"`
	Online        bool               `json:"online"`
	Dest          *CrowdDest         `json:"dest"`
	Level         CrowdLevel         `json:"level"`
	Stats         CrowdStats         `json:"stats"`
	Verification  *CrowdVerification `json:"verification"`
	Balance       string             `json:"balance"`
	NextPayoutOn  string             `json:"next_payout_on"` // дата ближайшего понедельника
	BlockedReason string             `json:"blocked_reason"`
	ActiveOrders  int                `json:"active_orders"`
}

func crowdOnly(p *identity.Principal) error {
	if p == nil || p.App != identity.AppCrowd {
		return apperr.Forbidden("только для курьеров «по пути»")
	}
	return nil
}

// nextMonday — ближайший понедельник (по Ташкенту), день выплаты.
func nextMonday(now time.Time) string {
	d := now.In(tashkent)
	days := (8 - int(d.Weekday())) % 7
	if days == 0 {
		days = 7
	}
	return d.AddDate(0, 0, days).Format("2006-01-02")
}

func (s *Service) CrowdMe(ctx context.Context, p *identity.Principal) (CrowdMe, error) {
	if err := crowdOnly(p); err != nil {
		return CrowdMe{}, err
	}
	me := CrowdMe{UserID: p.UserID}
	var dlat, dlng *float64
	var dtitle string
	err := s.pool.QueryRow(ctx, `
		SELECT cc.code, cc.status, cc.full_name, u.phone, cc.vehicle, cc.online,
		       ST_Y(cc.dest::geometry), ST_X(cc.dest::geometry), cc.dest_title, cc.blocked_reason,
		       COALESCE((SELECT sum(amount) FROM crowd_ledger l WHERE l.courier_id = cc.user_id), 0)::numeric(18,2)::text,
		       (SELECT count(*) FROM orders o WHERE o.crowd_courier_id = cc.user_id AND o.status IN ('picked', 'delivering'))::int
		FROM crowd_couriers cc JOIN users u ON u.id = cc.user_id WHERE cc.user_id = $1`, p.UserID).Scan(
		&me.Code, &me.Status, &me.FullName, &me.Phone, &me.Vehicle, &me.Online, &dlat, &dlng, &dtitle, &me.BlockedReason,
		&me.Balance, &me.ActiveOrders)
	if errors.Is(err, pgx.ErrNoRows) {
		return me, apperr.NotFound("профиль курьера не найден")
	}
	if err != nil {
		return me, err
	}
	if dlat != nil && dlng != nil {
		me.Dest = &CrowdDest{Lat: *dlat, Lng: *dlng, Title: dtitle}
	}
	var v CrowdVerification
	err = s.pool.QueryRow(ctx, `
		SELECT s.name, v.doc_type, v.created_at FROM courier_verifications v JOIN stores s ON s.id = v.store_id
		WHERE v.courier_id = $1 AND v.result = 'approved' ORDER BY v.created_at DESC LIMIT 1`, p.UserID).Scan(&v.StoreName, &v.DocType, &v.At)
	switch {
	case err == nil:
		me.Verification = &v
	case !errors.Is(err, pgx.ErrNoRows):
		return me, err
	}
	if me.Stats, err = crowdStats(ctx, s.pool, p.UserID); err != nil {
		return me, err
	}
	cs, err := s.crowdSettings(ctx, s.pool)
	if err != nil {
		return me, err
	}
	me.Level = crowdLevel(cs, me.Status, me.Stats)
	me.NextPayoutOn = nextMonday(s.now())
	return me, nil
}

type CrowdProfileInput struct {
	Vehicle *string `json:"vehicle"`
}

func (s *Service) CrowdUpdateMe(ctx context.Context, p *identity.Principal, in CrowdProfileInput) (CrowdMe, error) {
	if err := crowdOnly(p); err != nil {
		return CrowdMe{}, err
	}
	if in.Vehicle != nil && vehicleSpeed[*in.Vehicle] == 0 {
		return CrowdMe{}, apperr.Validation("vehicle: foot, bike, scooter или car")
	}
	if _, err := s.pool.Exec(ctx, `UPDATE crowd_couriers SET vehicle = COALESCE($2, vehicle) WHERE user_id = $1`, p.UserID, in.Vehicle); err != nil {
		return CrowdMe{}, err
	}
	return s.CrowdMe(ctx, p)
}

// CrowdRouteInput — «ищу заказы» и куда иду. Dest: null — убрать точку
// (заказы просто рядом), ключа нет — не менять.
type CrowdRouteInput struct {
	Online *bool                     `json:"online"`
	Dest   httpx.Optional[CrowdDest] `json:"dest"`
}

func (s *Service) CrowdSetRoute(ctx context.Context, p *identity.Principal, in CrowdRouteInput) (CrowdMe, error) {
	if err := crowdOnly(p); err != nil {
		return CrowdMe{}, err
	}
	setDest, clearDest := false, false
	var lat, lng float64
	var title string
	if in.Dest.Set {
		if in.Dest.Value == nil {
			clearDest = true
		} else {
			d := *in.Dest.Value
			if !validCoords(d.Lat, d.Lng) {
				return CrowdMe{}, apperr.Validation("dest: неверные координаты")
			}
			title = strings.TrimSpace(d.Title)
			if len([]rune(title)) > 120 {
				return CrowdMe{}, apperr.Validation("dest.title: не длиннее 120 символов")
			}
			setDest, lat, lng = true, d.Lat, d.Lng
		}
	}
	if _, err := s.pool.Exec(ctx, `
		UPDATE crowd_couriers SET online = COALESCE($2, online),
		       dest = CASE WHEN $3 THEN ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography WHEN $6 THEN NULL ELSE dest END,
		       dest_title = CASE WHEN $3 THEN $7 WHEN $6 THEN '' ELSE dest_title END
		WHERE user_id = $1`, p.UserID, in.Online, setDest, lat, lng, clearDest, title); err != nil {
		return CrowdMe{}, err
	}
	return s.CrowdMe(ctx, p)
}

// CrowdLocation — точка курьера: для ленты и для покупателя, пока заказ в пути.
func (s *Service) CrowdLocation(ctx context.Context, p *identity.Principal, in LocationInput) error {
	if err := crowdOnly(p); err != nil {
		return err
	}
	if !validCoords(in.Lat, in.Lng) {
		return apperr.Validation("lat/lng: неверные координаты")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			UPDATE crowd_couriers SET location = ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, located_at = now()
			WHERE user_id = $1`, p.UserID, in.Lat, in.Lng); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id FROM orders WHERE crowd_courier_id = $1 AND status = 'delivering'`, p.UserID)
		if err != nil {
			return err
		}
		ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		for _, id := range ids {
			if err := updateCrowdETA(ctx, tx, id); err != nil {
				return err
			}
		}
		return nil
	})
}

// updateCrowdETA: от свежей точки курьера «по пути» (или от магазина) до покупателя.
func updateCrowdETA(ctx context.Context, q db.Querier, orderID string) error {
	var dist float64
	var vehicle string
	err := q.QueryRow(ctx, `
		SELECT ST_Distance(o.location, CASE WHEN cc.location IS NOT NULL AND cc.located_at > now() - make_interval(secs => $2)
		                                    THEN cc.location ELSE s.location END), cc.vehicle
		FROM orders o JOIN stores s ON s.id = o.store_id JOIN crowd_couriers cc ON cc.user_id = o.crowd_courier_id
		WHERE o.id = $1`, orderID, locationFresh.Seconds()).Scan(&dist, &vehicle)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `UPDATE orders SET eta_at = now() + make_interval(secs => $2) WHERE id = $1`,
		orderID, etaFor(dist, vehicle).Seconds())
	return err
}

// CrowdPoint — магазин, где можно пройти проверку.
type CrowdPoint struct {
	StoreID   string   `json:"store_id"`
	Name      string   `json:"name"`
	Address   string   `json:"address"`
	Phone     string   `json:"phone"`
	Lat       *float64 `json:"lat"`
	Lng       *float64 `json:"lng"`
	DistanceM *int     `json:"distance_m"`
}

// CrowdPoints — ближайшие магазины, подключённые к crowd-доставке.
func (s *Service) CrowdPoints(ctx context.Context, p *identity.Principal, lat, lng *float64) ([]CrowdPoint, error) {
	if err := crowdOnly(p); err != nil {
		return nil, err
	}
	if lat != nil && lng != nil && !validCoords(*lat, *lng) {
		return nil, apperr.Validation("lat/lng: неверные координаты")
	}
	rows, err := s.pool.Query(ctx, `
		WITH me AS (SELECT COALESCE(CASE WHEN $1::float8 IS NOT NULL THEN ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography END,
		                            (SELECT location FROM crowd_couriers WHERE user_id = $3)) AS pt)
		SELECT s.id, s.name, s.address, s.phone, ST_Y(s.location::geometry), ST_X(s.location::geometry),
		       CASE WHEN me.pt IS NOT NULL AND s.location IS NOT NULL THEN ST_Distance(s.location, me.pt)::int END
		FROM stores s CROSS JOIN me
		JOIN networks n ON n.id = s.network_id AND n.status = 'active'
		WHERE s.crowd_enabled AND s.status = 'active'
		ORDER BY CASE WHEN me.pt IS NOT NULL AND s.location IS NOT NULL THEN ST_Distance(s.location, me.pt) END NULLS LAST, s.name
		LIMIT 10`, lat, lng, p.UserID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[CrowdPoint])
}

// CrowdOffer — заказ в ленте курьера. Адрес покупателя — только после принятия.
type CrowdOffer struct {
	OrderID      string   `json:"order_id"`
	Number       int64    `json:"number"`
	StoreName    string   `json:"store_name"`
	StoreAddress string   `json:"store_address"`
	StoreLat     *float64 `json:"store_lat"`
	StoreLng     *float64 `json:"store_lng"`
	ToStoreM     *int     `json:"to_store_m"`
	ToCustomerM  int      `json:"to_customer_m"`
	DetourM      *int     `json:"detour_m"`
	Minutes      int      `json:"minutes"`
	Reward       string   `json:"reward"`
	ItemsCount   int      `json:"items_count"`
	Total        string   `json:"total"`
	WaitingMin   int      `json:"waiting_min"`
	// Примерная точка покупателя (округлена до ~300 м) — для карты в ленте.
	AreaLat float64 `json:"area_lat"`
	AreaLng float64 `json:"area_lng"`
}

type CrowdFeed struct {
	// ok, unverified, offline, busy, no_location — почему лента пуста.
	State string       `json:"state"`
	Items []CrowdOffer `json:"items"`
	Level CrowdLevel   `json:"level"`
}

func crowdReward(cs CrowdSettings, waitingMin int) string {
	r := money.D(cs.CourierFee)
	if waitingMin >= cs.LongWaitMinutes {
		r = r.Add(money.D(cs.LongWaitBonus))
	}
	return r.Money()
}

// openOfferSQL — условия, при которых собранный заказ предлагается курьерам «по пути».
const openOfferSQL = `o.status = 'picked' AND o.courier_id IS NULL AND o.crowd_courier_id IS NULL
	AND s.crowd_enabled AND o.payment_provider <> 'cash'
	AND o.picked_at > now() - make_interval(mins => cs.wait_minutes)`

// CrowdOffers — лента: собранные заказы рядом и по пути.
func (s *Service) CrowdOffers(ctx context.Context, p *identity.Principal, lat, lng *float64) (CrowdFeed, error) {
	feed := CrowdFeed{State: "ok", Items: []CrowdOffer{}}
	me, err := s.CrowdMe(ctx, p)
	if err != nil {
		return feed, err
	}
	feed.Level = me.Level
	switch {
	case me.Status != "active":
		feed.State = "unverified"
		return feed, nil
	case !me.Online:
		feed.State = "offline"
		return feed, nil
	case me.ActiveOrders >= me.Level.Parallel:
		feed.State = "busy"
		return feed, nil
	}
	if lat != nil && lng != nil {
		if !validCoords(*lat, *lng) {
			return feed, apperr.Validation("lat/lng: неверные координаты")
		}
		if _, err := s.pool.Exec(ctx, `UPDATE crowd_couriers SET location = ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, located_at = now()
			WHERE user_id = $1`, p.UserID, *lat, *lng); err != nil {
			return feed, err
		}
	}
	cs, err := s.crowdSettings(ctx, s.pool)
	if err != nil {
		return feed, err
	}
	rows, err := s.pool.Query(ctx, `
		WITH c AS (SELECT location AS pt, dest FROM crowd_couriers WHERE user_id = $1 AND location IS NOT NULL
		           AND located_at > now() - interval '30 minutes')
		SELECT o.id, o.number, s.name, s.address, ST_Y(s.location::geometry), ST_X(s.location::geometry),
		       ST_Distance(s.location, c.pt)::int, ST_Distance(s.location, o.location)::int,
		       CASE WHEN c.dest IS NOT NULL THEN GREATEST(0, ST_Distance(c.pt, s.location) + ST_Distance(s.location, o.location)
		            + ST_Distance(o.location, c.dest) - ST_Distance(c.pt, c.dest))::int END,
		       (SELECT count(*) FROM order_items i WHERE i.order_id = o.id)::int, o.total::text,
		       GREATEST(0, EXTRACT(EPOCH FROM now() - o.picked_at) / 60)::int,
		       round(ST_Y(o.location::geometry)::numeric, 3)::float8, round(ST_X(o.location::geometry)::numeric, 3)::float8
		FROM orders o JOIN stores s ON s.id = o.store_id CROSS JOIN c CROSS JOIN crowd_settings cs
		WHERE `+openOfferSQL+`
		  AND o.customer_id <> $1 AND o.total <= $2::numeric
		  AND ST_DWithin(s.location, c.pt, cs.radius_m)
		  AND (c.dest IS NULL OR ST_Distance(c.pt, s.location) + ST_Distance(s.location, o.location)
		       + ST_Distance(o.location, c.dest) - ST_Distance(c.pt, c.dest) <= cs.detour_m)
		ORDER BY 9 NULLS LAST, 7
		LIMIT 20`, p.UserID, me.Level.Limit)
	if err != nil {
		return feed, err
	}
	feed.Items, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (CrowdOffer, error) {
		var o CrowdOffer
		err := row.Scan(&o.OrderID, &o.Number, &o.StoreName, &o.StoreAddress, &o.StoreLat, &o.StoreLng,
			&o.ToStoreM, &o.ToCustomerM, &o.DetourM, &o.ItemsCount, &o.Total, &o.WaitingMin, &o.AreaLat, &o.AreaLng)
		o.Reward = crowdReward(cs, o.WaitingMin)
		dist := float64(o.ToCustomerM)
		if o.ToStoreM != nil {
			dist += float64(*o.ToStoreM)
		}
		o.Minutes = int(etaFor(dist, me.Vehicle).Minutes())
		return o, err
	})
	if err != nil {
		return feed, err
	}
	if len(feed.Items) == 0 {
		var located bool
		if err := s.pool.QueryRow(ctx, `SELECT location IS NOT NULL AND located_at > now() - interval '30 minutes' FROM crowd_couriers WHERE user_id = $1`,
			p.UserID).Scan(&located); err != nil {
			return feed, err
		}
		if !located {
			feed.State = "no_location"
		}
	}
	return feed, nil
}

func randomDigits(n int) (string, error) {
	max := big.NewInt(int64(math.Pow10(n)))
	v, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%0*d", n, v.Int64()), nil
}

// pickupAlphabet — без похожих символов (0/O, 1/I).
const pickupAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

func randomPickup() (string, error) {
	b := make([]byte, 3)
	for i := range b {
		v, err := rand.Int(rand.Reader, big.NewInt(int64(len(pickupAlphabet))))
		if err != nil {
			return "", err
		}
		b[i] = pickupAlphabet[v.Int64()]
	}
	return string(b), nil
}

var errOfferGone = apperr.Conflict("offer_gone", "заказ уже взяли или он больше недоступен")

// CrowdAccept — курьер берёт заказ из ленты.
func (s *Service) CrowdAccept(ctx context.Context, p *identity.Principal, id string) (CrowdOrder, error) {
	me, err := s.CrowdMe(ctx, p)
	if err != nil {
		return CrowdOrder{}, err
	}
	if me.Status != "active" {
		return CrowdOrder{}, apperr.Forbidden("сначала подтвердите личность в магазине")
	}
	if me.ActiveOrders >= me.Level.Parallel {
		return CrowdOrder{}, apperr.Conflict("too_many_orders",
			fmt.Sprintf("на вашем уровне можно везти не больше %d заказ(а) сразу", me.Level.Parallel))
	}
	if _, err := s.getOrder(ctx, s.pool, id); err != nil {
		return CrowdOrder{}, err
	}
	cs, err := s.crowdSettings(ctx, s.pool)
	if err != nil {
		return CrowdOrder{}, err
	}
	pickup, err := randomPickup()
	if err != nil {
		return CrowdOrder{}, err
	}
	handoff, err := randomDigits(4)
	if err != nil {
		return CrowdOrder{}, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusPicked); err != nil {
			if e, ok := apperr.As(err); ok && e.Code == "wrong_status" {
				return errOfferGone
			}
			return err
		}
		var waiting int
		err := tx.QueryRow(ctx, `
			SELECT GREATEST(0, EXTRACT(EPOCH FROM now() - o.picked_at) / 60)::int
			FROM orders o JOIN stores s ON s.id = o.store_id CROSS JOIN crowd_settings cs
			WHERE o.id = $1 AND `+openOfferSQL+` AND o.customer_id <> $2 AND o.total <= $3::numeric`,
			id, p.UserID, me.Level.Limit).Scan(&waiting)
		if errors.Is(err, pgx.ErrNoRows) {
			return errOfferGone
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE orders SET crowd_courier_id = $2, crowd_accepted_at = now(),
			       crowd_pickup_until = now() + make_interval(mins => $3), crowd_fee = $4::numeric,
			       pickup_code = $5, handoff_code = $6, handoff_attempts = 0
			WHERE id = $1`, id, p.UserID, cs.PickupMinutes, crowdReward(cs, waiting), pickup, handoff); err != nil {
			return err
		}
		name := me.FullName
		if name == "" {
			name = me.Code
		}
		_, err = tx.Exec(ctx, `INSERT INTO order_status_history (order_id, status, actor, note) VALUES ($1, 'picked', 'crowd', $2)`,
			id, "Взял курьер по пути: "+name)
		return err
	})
	if err != nil {
		return CrowdOrder{}, err
	}
	return s.crowdOrder(ctx, p, id)
}

// CrowdOrder — заказ у курьера «по пути».
type CrowdOrder struct {
	Order        Order      `json:"order"`
	Store        StoreInfo  `json:"store"`
	CustomerName string     `json:"customer_name"`
	ItemsCount   int        `json:"items_count"`
	PickedUpAt   *time.Time `json:"picked_up_at"`
	// Код выдачи: курьер показывает его QR продавцу.
	PickupCode  string     `json:"pickup_code"`
	PickupUntil *time.Time `json:"pickup_until"`
	Fee         string     `json:"fee"`
}

func (s *Service) crowdOrder(ctx context.Context, p *identity.Principal, id string) (CrowdOrder, error) {
	if err := crowdOnly(p); err != nil {
		return CrowdOrder{}, err
	}
	o, err := s.getOrder(ctx, s.pool, id)
	if err != nil {
		return CrowdOrder{}, err
	}
	if o.CrowdCourierID == nil || *o.CrowdCourierID != p.UserID {
		return CrowdOrder{}, apperr.NotFound("заказ не найден")
	}
	si, err := s.storeInfo(ctx, o.StoreID)
	if err != nil {
		return CrowdOrder{}, err
	}
	c := CrowdOrder{Order: o, Store: si}
	var fee *string
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(NULLIF(btrim(cu.first_name), ''), u.full_name, ''),
		       (SELECT count(*) FROM order_items i WHERE i.order_id = o.id)::int, o.picked_up_at,
		       COALESCE(o.pickup_code, ''), o.crowd_pickup_until, o.crowd_fee::text
		FROM orders o JOIN users u ON u.id = o.customer_id
		LEFT JOIN customers cu ON cu.user_id = o.customer_id
		WHERE o.id = $1`, id).Scan(&c.CustomerName, &c.ItemsCount, &c.PickedUpAt, &c.PickupCode, &c.PickupUntil, &fee)
	if fee != nil {
		c.Fee = *fee
	}
	// Телефон покупателя — только когда заказ у курьера на руках.
	if o.Status != StatusDelivering {
		c.Order.CustomerPhone = ""
	}
	if o.Status != StatusPicked {
		c.PickupCode = ""
	}
	return c, err
}

func (s *Service) CrowdGetOrder(ctx context.Context, p *identity.Principal, id string) (CrowdOrder, error) {
	return s.crowdOrder(ctx, p, id)
}

// CrowdOrders — заказы курьера: активные и доставленные за 12 часов.
func (s *Service) CrowdOrders(ctx context.Context, p *identity.Principal) ([]CrowdOrder, error) {
	if err := crowdOnly(p); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id FROM orders WHERE crowd_courier_id = $1 AND (status IN ('picked', 'delivering')
		       OR (status = 'delivered' AND delivered_at > now() - interval '12 hours'))
		ORDER BY status = 'delivered', crowd_accepted_at`, p.UserID)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	out := make([]CrowdOrder, 0, len(ids))
	for _, id := range ids {
		c, err := s.crowdOrder(ctx, p, id)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

// clearCrowd снимает курьера «по пути» с заказа (статус остаётся «Собран»).
func clearCrowd(ctx context.Context, tx pgx.Tx, id, actor, note string) error {
	if _, err := tx.Exec(ctx, `
		UPDATE orders SET crowd_courier_id = NULL, crowd_accepted_at = NULL, crowd_pickup_until = NULL,
		       crowd_fee = NULL, pickup_code = NULL, handoff_code = NULL, handoff_attempts = 0,
		       picked_at = now()
		WHERE id = $1`, id); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO order_status_history (order_id, status, actor, note) VALUES ($1, 'picked', $2, $3)`, id, actor, note)
	return err
}

// CrowdRelease — курьер отказывается от заказа, пока не забрал его в магазине.
func (s *Service) CrowdRelease(ctx context.Context, p *identity.Principal, id string) (CrowdOrder, error) {
	c, err := s.crowdOrder(ctx, p, id)
	if err != nil {
		return CrowdOrder{}, err
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		o, err := lockOrder(ctx, tx, id, StatusPicked)
		if err != nil {
			return err
		}
		_ = o
		if err := clearCrowd(ctx, tx, id, "crowd", "Курьер по пути отказался — заказ снова в ленте"); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO courier_incidents (courier_id, order_id, kind, note, status) VALUES ($1, $2, 'released', 'Отказался до магазина', 'resolved')`,
			p.UserID, id)
		return err
	})
	if err != nil {
		return CrowdOrder{}, err
	}
	c.Order.Status = StatusPicked
	c.Order.CrowdCourierID = nil
	c.PickupCode = ""
	return c, nil
}

type CrowdDeliverInput struct {
	Code string `json:"code"`
}

const maxHandoffAttempts = 5

// CrowdDeliver — курьер вручил заказ: покупатель назвал код. Курьеру —
// вознаграждение, магазину, который его проверил, — бонус за первые доставки.
func (s *Service) CrowdDeliver(ctx context.Context, p *identity.Principal, id string, in CrowdDeliverInput) (CrowdOrder, error) {
	if _, err := s.crowdOrder(ctx, p, id); err != nil {
		return CrowdOrder{}, err
	}
	code := strings.TrimSpace(in.Code)
	var verdict error
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := lockOrder(ctx, tx, id, StatusDelivering); err != nil {
			return err
		}
		var want *string
		var attempts int
		if err := tx.QueryRow(ctx, `SELECT handoff_code, handoff_attempts FROM orders WHERE id = $1`, id).Scan(&want, &attempts); err != nil {
			return err
		}
		if attempts >= maxHandoffAttempts {
			verdict = apperr.New(429, "too_many_attempts", "слишком много неверных кодов — позвоните в поддержку")
			return nil
		}
		if want == nil || code != *want {
			left := maxHandoffAttempts - attempts - 1
			verdict = apperr.Validation(fmt.Sprintf("неверный код, осталось попыток: %d", left)).
				WithDetails(map[string]any{"attempts_left": left})
			_, err := tx.Exec(ctx, `UPDATE orders SET handoff_attempts = handoff_attempts + 1 WHERE id = $1`, id)
			return err
		}
		if err := markDelivered(ctx, tx, id, "crowd", StatusDelivering); err != nil {
			return err
		}
		return s.crowdCredit(ctx, tx, id)
	})
	if err != nil {
		return CrowdOrder{}, err
	}
	if verdict != nil {
		return CrowdOrder{}, verdict
	}
	return s.crowdOrder(ctx, p, id)
}

// crowdCredit — вознаграждение курьеру и бонус магазину после вручения.
func (s *Service) crowdCredit(ctx context.Context, tx pgx.Tx, orderID string) error {
	var courierID, customerID string
	var number int64
	var fee *string
	var verifiedStore *string
	if err := tx.QueryRow(ctx, `
		SELECT o.crowd_courier_id, o.customer_id, o.number, o.crowd_fee::text, cc.verified_store_id
		FROM orders o JOIN crowd_couriers cc ON cc.user_id = o.crowd_courier_id WHERE o.id = $1`, orderID).
		Scan(&courierID, &customerID, &number, &fee, &verifiedStore); err != nil {
		return err
	}
	if fee != nil && money.D(*fee).Sign() > 0 {
		if _, err := tx.Exec(ctx, `
			INSERT INTO crowd_ledger (courier_id, order_id, kind, amount, note) VALUES ($1, $2, 'delivery', $3::numeric, $4)
			ON CONFLICT DO NOTHING`, courierID, orderID, *fee, fmt.Sprintf("Заказ № %d", number)); err != nil {
			return err
		}
	}
	if verifiedStore == nil {
		return nil
	}
	cs, err := s.crowdSettings(ctx, tx)
	if err != nil {
		return err
	}
	// Бонус — за первые N доставок курьера и только разным покупателям.
	var bonuses int
	var sameCustomer bool
	if err := tx.QueryRow(ctx, `
		SELECT count(*)::int, COALESCE(bool_or(o.customer_id = $2), false)
		FROM store_crowd_bonuses b JOIN orders o ON o.id = b.order_id
		WHERE b.courier_id = $1 AND b.status <> 'cancelled'`, courierID, customerID).Scan(&bonuses, &sameCustomer); err != nil {
		return err
	}
	if bonuses >= cs.StoreBonusCount || sameCustomer || money.D(cs.StoreBonus).Sign() <= 0 {
		return nil
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO store_crowd_bonuses (network_id, store_id, courier_id, order_id, amount, available_at)
		SELECT s.network_id, s.id, $2, $3, $4::numeric, now() + make_interval(days => $5)
		FROM stores s WHERE s.id = $1
		ON CONFLICT (order_id) DO NOTHING`, *verifiedStore, courierID, orderID, cs.StoreBonus, cs.StoreBonusHoldDays)
	return err
}

type CrowdProblemInput struct {
	Kind string `json:"kind"` // no_handoff — покупатель не отвечает
	Note string `json:"note"`
}

// CrowdProblem — курьер сообщает о проблеме (покупатель не отвечает).
func (s *Service) CrowdProblem(ctx context.Context, p *identity.Principal, id string, in CrowdProblemInput) (CrowdOrder, error) {
	c, err := s.crowdOrder(ctx, p, id)
	if err != nil {
		return CrowdOrder{}, err
	}
	if in.Kind != "no_handoff" && in.Kind != "other" {
		return CrowdOrder{}, apperr.Validation("kind: no_handoff или other")
	}
	note := strings.TrimSpace(in.Note)
	if len([]rune(note)) > 500 {
		return CrowdOrder{}, apperr.Validation("note: не длиннее 500 символов")
	}
	var open bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM courier_incidents WHERE order_id = $1 AND kind = $2 AND status = 'open')`,
		id, in.Kind).Scan(&open); err != nil {
		return CrowdOrder{}, err
	}
	if !open {
		if _, err := s.pool.Exec(ctx, `INSERT INTO courier_incidents (courier_id, order_id, kind, note) VALUES ($1, $2, $3, $4)`,
			p.UserID, id, in.Kind, note); err != nil {
			return CrowdOrder{}, err
		}
	}
	return c, nil
}

// CrowdLedgerEntry — начисление или выплата.
type CrowdLedgerEntry struct {
	ID        int64     `json:"id"`
	Kind      string    `json:"kind"`
	Amount    string    `json:"amount"`
	Note      string    `json:"note"`
	OrderID   *string   `json:"order_id"`
	CreatedAt time.Time `json:"created_at"`
}

type CrowdEarnings struct {
	Balance       string             `json:"balance"`
	NextPayoutOn  string             `json:"next_payout_on"`
	WeekDelivered int                `json:"week_delivered"`
	WeekEarned    string             `json:"week_earned"`
	AvgMinutes    int                `json:"avg_minutes"` // от выдачи до вручения, за 7 дней
	Items         []CrowdLedgerEntry `json:"items"`
}

func (s *Service) CrowdEarnings(ctx context.Context, p *identity.Principal) (CrowdEarnings, error) {
	e := CrowdEarnings{Items: []CrowdLedgerEntry{}, NextPayoutOn: nextMonday(s.now())}
	if err := crowdOnly(p); err != nil {
		return e, err
	}
	var avg *float64
	err := s.pool.QueryRow(ctx, `
		SELECT COALESCE((SELECT sum(amount) FROM crowd_ledger WHERE courier_id = $1), 0)::numeric(18,2)::text,
		       COALESCE((SELECT sum(amount) FROM crowd_ledger WHERE courier_id = $1 AND amount > 0 AND created_at > now() - interval '7 days'), 0)::numeric(18,2)::text,
		       count(*)::int,
		       avg(EXTRACT(EPOCH FROM o.delivered_at - o.picked_up_at) / 60) FILTER (WHERE o.picked_up_at IS NOT NULL)
		FROM orders o WHERE o.crowd_courier_id = $1 AND o.status = 'delivered' AND o.delivered_at > now() - interval '7 days'`,
		p.UserID).Scan(&e.Balance, &e.WeekEarned, &e.WeekDelivered, &avg)
	if err != nil {
		return e, err
	}
	if avg != nil {
		e.AvgMinutes = int(*avg + 0.5)
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, kind, amount::text, note, order_id, created_at FROM crowd_ledger
		WHERE courier_id = $1 ORDER BY created_at DESC, id DESC LIMIT 100`, p.UserID)
	if err != nil {
		return e, err
	}
	e.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[CrowdLedgerEntry])
	return e, err
}

// notCrowd — у заказа курьер «по пути»: магазин не отмечает «в пути» и
// «доставлен» сам — только выдача по коду и вручение по коду покупателя.
func (s *Service) notCrowd(ctx context.Context, id string) error {
	var crowd bool
	if err := s.pool.QueryRow(ctx, `SELECT crowd_courier_id IS NOT NULL FROM orders WHERE id = $1`, id).Scan(&crowd); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("заказ не найден")
		}
		return err
	}
	if crowd {
		return apperr.Conflict("crowd_courier", "заказ везёт курьер «по пути»: выдайте его по коду курьера")
	}
	return nil
}
