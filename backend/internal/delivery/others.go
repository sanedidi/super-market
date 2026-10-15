package delivery

import (
	"context"
	"math"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// OthersRadiusM — до какого расстояния покупатель видит магазины, которые ему
// не доставляют (их товары можно посмотреть и попросить доставку).
const OthersRadiusM = 10000

// OtherStore — магазин рядом, который не доставляет по адресу покупателя.
type OtherStore struct {
	ID          string  `json:"id"`
	NetworkID   string  `json:"network_id"`
	NetworkName string  `json:"network_name"`
	Name        string  `json:"name"`
	Address     string  `json:"address"`
	Lat         float64 `json:"lat"`
	Lng         float64 `json:"lng"`
	LogoURL     string  `json:"logo_url"`
	DistanceM   int     `json:"distance_m"`
	IsOpen      bool    `json:"is_open"`
	// Reason: not_online — магазин не принимает онлайн-заказы; out_of_zone — адрес вне зоны доставки.
	Reason string `json:"reason"`
}

// Others — активные магазины до OthersRadiusM от точки, кроме exclude (те, что доставляют),
// ближайшие первыми. Магазины без основного склада и должники по подписке не показываются.
func (s *Service) Others(ctx context.Context, lat, lng float64, exclude []string) ([]OtherStore, error) {
	if lat < -90 || lat > 90 || lng < -180 || lng > 180 {
		return nil, apperr.Validation("lat/lng: координаты вне диапазона").Uz("lat/lng: koordinatalar ruxsat etilgan oraliqdan tashqarida")
	}
	if exclude == nil {
		exclude = []string{}
	}
	rows, err := s.pool.Query(ctx, `
		WITH pt AS (SELECT ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography AS g)
		SELECT s.id, s.network_id, n.name, s.name, s.address, ST_Y(s.location::geometry), ST_X(s.location::geometry),
		       s.logo_url, ST_Distance(s.location, pt.g),
		       CASE WHEN s.accepts_online THEN 'out_of_zone' ELSE 'not_online' END
		FROM stores s JOIN networks n ON n.id = s.network_id, pt
		WHERE s.status = 'active' AND n.status = 'active' AND s.location IS NOT NULL
		  AND n.kind <> 'distributor' -- точки дистрибьюторов покупателям не видны
		  AND s.default_warehouse_id IS NOT NULL
		  AND `+ActiveSubscriptionSQL+`
		  AND ST_DWithin(s.location, pt.g, $3)
		  AND NOT (s.id = ANY ($4::uuid[]))
		ORDER BY ST_Distance(s.location, pt.g)
		LIMIT 50`, lat, lng, OthersRadiusM, exclude)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (OtherStore, error) {
		var st OtherStore
		var dist float64
		err := r.Scan(&st.ID, &st.NetworkID, &st.NetworkName, &st.Name, &st.Address, &st.Lat, &st.Lng, &st.LogoURL, &dist, &st.Reason)
		st.DistanceM = int(math.Round(dist))
		return st, err
	})
	if err != nil || len(out) == 0 {
		return out, err
	}
	ids := make([]string, len(out))
	for i, st := range out {
		ids[i] = st.ID
	}
	hours := map[string][]WorkingHours{}
	hrows, err := s.pool.Query(ctx, `SELECT store_id, weekday, to_char(opens, 'HH24:MI'), to_char(closes, 'HH24:MI')
		FROM store_working_hours WHERE store_id = ANY ($1::uuid[]) ORDER BY store_id, weekday`, ids)
	if err != nil {
		return nil, err
	}
	defer hrows.Close()
	for hrows.Next() {
		var id string
		var h WorkingHours
		if err := hrows.Scan(&id, &h.Weekday, &h.Opens, &h.Closes); err != nil {
			return nil, err
		}
		hours[id] = append(hours[id], h)
	}
	if err := hrows.Err(); err != nil {
		return nil, err
	}
	now := s.now()
	for i := range out {
		out[i].IsOpen = isOpen(hours[out[i].ID], now)
	}
	return out, nil
}
