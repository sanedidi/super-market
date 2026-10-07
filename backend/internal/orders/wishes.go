package orders

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// «Хочу доставку»: покупатель отмечает магазин, который ему не доставляет.
// Это не заказ, а голос — один на магазин; точка адреса нужна, чтобы магазин
// видел, далеко ли до тех, кто ждёт доставку.

type WishInput struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

type WishState struct {
	StoreID string `json:"store_id"`
	Wished  bool   `json:"wished"`
}

// Wish — «Хочу доставку» (повторно — обновляет точку адреса).
func (s *Service) Wish(ctx context.Context, p *identity.Principal, storeID string, in WishInput) (WishState, error) {
	if in.Lat < -90 || in.Lat > 90 || in.Lng < -180 || in.Lng > 180 || (in.Lat == 0 && in.Lng == 0) {
		return WishState{}, apperr.Validation("lat/lng: укажите адрес").Uz("lat/lng: manzilni kiriting")
	}
	if _, err := s.storeForBrowse(ctx, s.pool, storeID); err != nil {
		return WishState{}, err
	}
	_, err := s.pool.Exec(ctx, `
		INSERT INTO delivery_wishes (store_id, user_id, location)
		VALUES ($1, $2, ST_SetSRID(ST_MakePoint($4, $3), 4326)::geography)
		ON CONFLICT (store_id, user_id) DO UPDATE SET location = EXCLUDED.location, updated_at = now()`,
		storeID, p.UserID, in.Lat, in.Lng)
	return WishState{StoreID: storeID, Wished: true}, err
}

// Unwish — снять «Хочу доставку».
func (s *Service) Unwish(ctx context.Context, p *identity.Principal, storeID string) (WishState, error) {
	if !httpx.IsUUID(storeID) {
		return WishState{}, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	_, err := s.pool.Exec(ctx, `DELETE FROM delivery_wishes WHERE store_id = $1 AND user_id = $2`, storeID, p.UserID)
	return WishState{StoreID: storeID, Wished: false}, err
}

// MyWishes — магазины, у которых покупатель просил доставку.
func (s *Service) MyWishes(ctx context.Context, p *identity.Principal) ([]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT store_id::text FROM delivery_wishes WHERE user_id = $1 ORDER BY created_at DESC LIMIT 500`, p.UserID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// ------------------------------------------------------- панель магазина

// WishStats — сколько покупателей ждут доставку из магазина.
type WishStats struct {
	StoreID       string `json:"store_id"`
	AcceptsOnline bool   `json:"accepts_online"`
	Total         int    `json:"total"`
	Week          int    `json:"week"`
	Month         int    `json:"month"`
	// Ближайший и самый дальний из ждущих, метры (null — никого).
	NearestM  *int `json:"nearest_m"`
	FarthestM *int `json:"farthest_m"`
	// Вне зоны доставки (имеет смысл, когда онлайн-заказы включены).
	OutOfZone     int `json:"out_of_zone"`
	OutOfZoneWeek int `json:"out_of_zone_week"`
}

// coveredSQL — точка w.location внутри зоны доставки магазина s (зоны или радиус).
const coveredSQL = `(EXISTS (SELECT 1 FROM delivery_zones z WHERE z.store_id = s.id AND z.is_active AND ST_Covers(z.area, w.location))
	OR (NOT EXISTS (SELECT 1 FROM delivery_zones z WHERE z.store_id = s.id AND z.is_active)
	    AND s.location IS NOT NULL AND ST_DWithin(s.location, w.location, s.delivery_radius_m)))`

func (s *Service) StoreWishStats(ctx context.Context, p *identity.Principal, storeID string) (WishStats, error) {
	out := WishStats{StoreID: storeID}
	if err := p.RequireAny(identity.PermStoresManage, identity.PermOrdersManage); err != nil {
		return out, err
	}
	if !httpx.IsUUID(storeID) || !p.CanAccessStore(storeID) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	err := s.pool.QueryRow(ctx, `
		SELECT s.accepts_online,
		       count(w.user_id)::int,
		       (count(w.user_id) FILTER (WHERE w.created_at > now() - interval '7 days'))::int,
		       (count(w.user_id) FILTER (WHERE w.created_at > now() - interval '30 days'))::int,
		       round(min(ST_Distance(s.location, w.location)))::int,
		       round(max(ST_Distance(s.location, w.location)))::int,
		       (count(w.user_id) FILTER (WHERE NOT `+coveredSQL+`))::int,
		       (count(w.user_id) FILTER (WHERE NOT `+coveredSQL+` AND w.created_at > now() - interval '7 days'))::int
		FROM stores s
		LEFT JOIN delivery_wishes w ON w.store_id = s.id
		WHERE s.id = $1 AND s.network_id = $2
		GROUP BY s.id`, storeID, p.NetworkID).
		Scan(&out.AcceptsOnline, &out.Total, &out.Week, &out.Month, &out.NearestM, &out.FarthestM, &out.OutOfZone, &out.OutOfZoneWeek)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, apperr.NotFound("магазин не найден").Uz("doʻkon topilmadi")
	}
	return out, err
}

// ------------------------------------------------------------ супер-админ

type WishTotals struct {
	Total  int `json:"total"`
	Week   int `json:"week"`
	Stores int `json:"stores"`
}

type WishStore struct {
	StoreID       string `json:"store_id"`
	StoreName     string `json:"store_name"`
	NetworkID     string `json:"network_id"`
	NetworkName   string `json:"network_name"`
	Total         int    `json:"total"`
	Week          int    `json:"week"`
	AcceptsOnline bool   `json:"accepts_online"`
	OutOfZone     int    `json:"out_of_zone"`
	// Магазин или сеть не активны, или просрочена подписка — покупатели магазин сейчас не видят.
	Hidden bool `json:"hidden"`
}

type WishReport struct {
	Totals WishTotals  `json:"totals"`
	Items  []WishStore `json:"items"`
}

func (s *Service) AdminWishes(ctx context.Context, page httpx.Page) (WishReport, error) {
	out := WishReport{Items: []WishStore{}}
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*)::int, (count(*) FILTER (WHERE created_at > now() - interval '7 days'))::int, count(DISTINCT store_id)::int
		FROM delivery_wishes`).Scan(&out.Totals.Total, &out.Totals.Week, &out.Totals.Stores); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, `
		SELECT s.id, s.name, n.id, n.name, count(*)::int,
		       (count(*) FILTER (WHERE w.created_at > now() - interval '7 days'))::int,
		       s.accepts_online,
		       (count(*) FILTER (WHERE NOT `+coveredSQL+`))::int,
		       NOT (s.status = 'active' AND n.status = 'active' AND s.location IS NOT NULL AND s.default_warehouse_id IS NOT NULL
		            AND `+delivery.ActiveSubscriptionSQL+`)
		FROM delivery_wishes w
		JOIN stores s ON s.id = w.store_id
		JOIN networks n ON n.id = s.network_id
		GROUP BY s.id, n.id
		ORDER BY count(*) DESC, s.name
		LIMIT $1 OFFSET $2`, page.Limit, page.Offset)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[WishStore])
	return out, err
}
