package field

import (
	"context"
	"math"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// Карта обхода (П2, П3; у супер-админа — С1): обойдённые клетки, пройденные
// улицы и отмеченные магазины в видимой области.

const (
	// maxSpanDeg — самая большая область карты (≈ 8 км).
	maxSpanDeg = 0.08
	// maxCells, maxTrackPts — сколько отдаём за раз (дальше — truncated).
	maxCells    = 25000
	maxTrackPts = 25000
	maxPlaces   = 2000
	// trackStepM — линия пути прорежена: точки не чаще чем через столько метров.
	trackStepM = 12.0
	// trackBreakSec — между соседними точками дольше: линия рвётся (вышли из области).
	trackBreakSec = 90
)

// BBox — видимая область карты.
type BBox struct {
	MinLat, MinLng, MaxLat, MaxLng float64
}

// ParseBBox — ?min_lat=&min_lng=&max_lat=&max_lng=.
func ParseBBox(get func(string) string) (BBox, error) {
	var b BBox
	vals := []*float64{&b.MinLat, &b.MinLng, &b.MaxLat, &b.MaxLng}
	for i, k := range []string{"min_lat", "min_lng", "max_lat", "max_lng"} {
		v, err := strconv.ParseFloat(get(k), 64)
		if err != nil {
			return b, apperr.Validation(k + ": укажите область карты").Uz(k + ": xarita hududini koʻrsating")
		}
		*vals[i] = v
	}
	if b.MinLat > b.MaxLat || b.MinLng > b.MaxLng {
		return b, apperr.Validation("область карты: min больше max").Uz("xarita hududi: min max dan katta")
	}
	// Слишком большая область — берём середину.
	if b.MaxLat-b.MinLat > maxSpanDeg {
		c := (b.MinLat + b.MaxLat) / 2
		b.MinLat, b.MaxLat = c-maxSpanDeg/2, c+maxSpanDeg/2
	}
	if b.MaxLng-b.MinLng > maxSpanDeg {
		c := (b.MinLng + b.MaxLng) / 2
		b.MinLng, b.MaxLng = c-maxSpanDeg/2, c+maxSpanDeg/2
	}
	return b, nil
}

// Track — линия пути одного обхода в области.
type Track struct {
	WalkID string `json:"walk_id"`
	RepID  string `json:"rep_id"`
	Color  string `json:"color"`
	// Свой путь (у продажника) и путь сегодняшнего обхода.
	Mine  bool         `json:"mine"`
	Today bool         `json:"today"`
	Pts   [][2]float64 `json:"pts"`
}

// MapData — клетки, линии и магазины в области.
type MapData struct {
	Grid Grid `json:"grid"`
	// Обойдённые клетки: [cx, cy, 1 — был сам / 0 — другие].
	Cells     [][3]int `json:"cells"`
	Tracks    []Track  `json:"tracks"`
	Places    []Place  `json:"places"`
	Truncated bool     `json:"truncated"`
}

// RepMap — карта продажника.
func (s *Service) RepMap(ctx context.Context, p *identity.Principal, b BBox) (MapData, error) {
	if err := requireRep(p); err != nil {
		return MapData{}, err
	}
	return s.mapData(ctx, p.RepID, b)
}

// AdminMap — карта супер-админа.
func (s *Service) AdminMap(ctx context.Context, p *identity.Principal, b BBox) (MapData, error) {
	if err := requireAdmin(p); err != nil {
		return MapData{}, err
	}
	return s.mapData(ctx, "", b)
}

func (s *Service) mapData(ctx context.Context, me string, b BBox) (MapData, error) {
	out := MapData{Grid: grid(), Cells: [][3]int{}, Tracks: []Track{}, Places: []Place{}}
	lo, hi := cellOf(b.MinLat, b.MinLng), cellOf(b.MaxLat, b.MaxLng)
	rows, err := s.pool.Query(ctx, `
		SELECT c.cx, c.cy, (c.rep_id::text = $5 OR EXISTS (
		       SELECT 1 FROM field_rep_cells rc WHERE $5 <> '' AND rc.rep_id::text = $5 AND rc.cx = c.cx AND rc.cy = c.cy))
		FROM field_cells c
		WHERE c.cx BETWEEN $1 AND $2 AND c.cy BETWEEN $3 AND $4
		LIMIT $6`, lo.x, hi.x, lo.y, hi.y, me, maxCells+1)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var (
			c    cell
			mine bool
		)
		if err := rows.Scan(&c.x, &c.y, &mine); err != nil {
			rows.Close()
			return out, err
		}
		m := 0
		if mine {
			m = 1
		}
		out.Cells = append(out.Cells, [3]int{c.x, c.y, m})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	if len(out.Cells) > maxCells {
		out.Cells, out.Truncated = out.Cells[:maxCells], true
	}

	// Пройденные улицы: точки обходов в области, по обходам и по времени.
	rows, err = s.pool.Query(ctx, `
		SELECT pt.walk_id, w.rep_id, fr.color, w.rep_id::text = $5,
		       (w.started_at AT TIME ZONE 'Asia/Tashkent')::date = `+todaySQL+`,
		       pt.at, pt.lat, pt.lng
		FROM field_points pt
		JOIN field_walks w ON w.id = pt.walk_id
		JOIN field_reps fr ON fr.id = w.rep_id
		WHERE pt.lat BETWEEN $1 AND $3 AND pt.lng BETWEEN $2 AND $4 AND NOT pt.mocked
		ORDER BY pt.walk_id, pt.at
		LIMIT $6`, b.MinLat, b.MinLng, b.MaxLat, b.MaxLng, me, maxTrackPts*4)
	if err != nil {
		return out, err
	}
	var (
		cur    *Track
		lastAt time.Time
		total  int
	)
	flush := func() {
		if cur != nil && len(cur.Pts) > 1 {
			out.Tracks = append(out.Tracks, *cur)
			total += len(cur.Pts)
		}
		cur = nil
	}
	n := 0
	for rows.Next() {
		n++
		var (
			t        Track
			at       time.Time
			lat, lng float64
		)
		if err := rows.Scan(&t.WalkID, &t.RepID, &t.Color, &t.Mine, &t.Today, &at, &lat, &lng); err != nil {
			rows.Close()
			return out, err
		}
		if cur == nil || cur.WalkID != t.WalkID || at.Sub(lastAt).Seconds() > trackBreakSec {
			flush()
			t.Pts = [][2]float64{{lat, lng}}
			cur = &t
		} else {
			last := cur.Pts[len(cur.Pts)-1]
			if distM(last[0], last[1], lat, lng) >= trackStepM {
				cur.Pts = append(cur.Pts, [2]float64{round6(lat), round6(lng)})
			}
		}
		lastAt = at
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	flush()
	if n >= maxTrackPts*4 || total > maxTrackPts {
		out.Truncated = true
	}

	rows, err = s.pool.Query(ctx, `SELECT `+placeCols(1)+placeJoins+`
		WHERE ST_Intersects(p.location, ST_MakeEnvelope($2, $3, $4, $5, 4326)::geography)
		ORDER BY p.last_visit_at DESC LIMIT $6`, me, b.MinLng, b.MinLat, b.MaxLng, b.MaxLat, maxPlaces)
	if err != nil {
		return out, err
	}
	out.Places, err = pgx.CollectRows(rows, scanPlace)
	if out.Places == nil {
		out.Places = []Place{}
	}
	return out, err
}

func round6(v float64) float64 { return math.Round(v*1e6) / 1e6 }

// Hint — ближайшая белая зона (клетка, где ещё никто не был).
type Hint struct {
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
	DistanceM int     `json:"distance_m"`
	// Направление: n, ne, e, se, s, sw, w, nw.
	Direction string `json:"direction"`
}

// hintRadius — в скольких клетках ищем белую зону (≈ 2 км).
const hintRadius = 20

// WhiteZone — П3 «Ближайшая белая зона — 160 м на восток». Белая зона —
// клетка, где никто не был, у которой хотя бы ещё одна соседняя тоже белая
// (одна случайная клетка между улицами — не зона). nil — рядом всё обойдено.
func (s *Service) WhiteZone(ctx context.Context, p *identity.Principal, lat, lng float64) (*Hint, error) {
	if err := requireRep(p); err != nil {
		return nil, err
	}
	c0 := cellOf(lat, lng)
	r := hintRadius + 1
	rows, err := s.pool.Query(ctx, `
		SELECT cx, cy FROM field_cells WHERE cx BETWEEN $1 AND $2 AND cy BETWEEN $3 AND $4`,
		c0.x-r, c0.x+r, c0.y-r, c0.y+r)
	if err != nil {
		return nil, err
	}
	covered := map[cell]bool{}
	for rows.Next() {
		var c cell
		if err := rows.Scan(&c.x, &c.y); err != nil {
			rows.Close()
			return nil, err
		}
		covered[c] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	white := func(c cell) bool {
		if covered[c] {
			return false
		}
		for _, d := range [][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
			if !covered[cell{c.x + d[0], c.y + d[1]}] {
				return true
			}
		}
		return false
	}
	var (
		best  *cell
		bestD = math.Inf(1)
	)
	for ring := 0; ring <= hintRadius; ring++ {
		for x := c0.x - ring; x <= c0.x+ring; x++ {
			for y := c0.y - ring; y <= c0.y+ring; y++ {
				if max(abs(x-c0.x), abs(y-c0.y)) != ring {
					continue
				}
				c := cell{x, y}
				if !white(c) {
					continue
				}
				clat, clng := c.center()
				if d := distM(lat, lng, clat, clng); d < bestD {
					bestD, best = d, &c
				}
			}
		}
		// Нашли на этом кольце — ближе уже не будет (с точностью до клетки).
		if best != nil {
			break
		}
	}
	if best == nil {
		return nil, nil
	}
	clat, clng := best.center()
	return &Hint{Lat: round6(clat), Lng: round6(clng), DistanceM: int(math.Round(bestD/10) * 10), Direction: bearing(lat, lng, clat, clng)}, nil
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// NearPlaces — П4: отмеченные магазины ближе samePlaceM м («Это он?»).
func (s *Service) NearPlaces(ctx context.Context, p *identity.Principal, lat, lng float64) ([]Place, error) {
	if err := requireRep(p); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `
		WITH pt AS (SELECT ST_SetSRID(ST_MakePoint($3::float8, $2::float8), 4326)::geography AS g)
		SELECT `+placeCols(1)+`, round(ST_Distance(p.location, pt.g))::int`+placeJoins+`, pt
		WHERE ST_DWithin(p.location, pt.g, $4)
		ORDER BY ST_Distance(p.location, pt.g) LIMIT 5`, p.RepID, lat, lng, samePlaceM)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scanPlaceDist)
	if out == nil {
		out = []Place{}
	}
	return out, err
}
