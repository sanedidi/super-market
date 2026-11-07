package field

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Районы Ташкента и покрытие (С3 «Покрытие районов»): доля клеток района,
// через которые прошёл хоть один продажник. Границу района супер-админ рисует
// на карте один раз.

// District — район и его покрытие.
type District struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	NameUz   string  `json:"name_uz"`
	Boundary Polygon `json:"boundary"`
	// Клеток в районе и сколько из них обойдено.
	TotalCells   int      `json:"total_cells"`
	CoveredCells int      `json:"covered_cells"`
	CoveragePct  *float64 `json:"coverage_pct"`
	// Продажники района.
	Reps []string `json:"reps"`
	// Отмечено магазинов в районе и сколько из них подключено.
	Places    int        `json:"places"`
	Connected int        `json:"connected"`
	LastWalk  *time.Time `json:"last_walk_at"`
	// Кто-то из продажников района сейчас в обходе.
	Walking bool `json:"walking"`

	poly Polygon
}

const districtSelect = `SELECT d.id, d.name, d.name_uz, d.boundary, d.total_cells FROM field_districts d`

func scanDistrict(row pgx.CollectableRow) (District, error) {
	var (
		d   District
		raw []byte
	)
	if err := row.Scan(&d.ID, &d.Name, &d.NameUz, &raw, &d.TotalCells); err != nil {
		return d, err
	}
	if err := json.Unmarshal(raw, &d.Boundary); err != nil {
		d.Boundary = Polygon{}
	}
	if d.Boundary == nil {
		d.Boundary = Polygon{}
	}
	d.poly = d.Boundary
	d.Reps = []string{}
	return d, nil
}

func (s *Service) repDistrict(ctx context.Context, repID string) (*District, error) {
	rows, err := s.pool.Query(ctx, districtSelect+` JOIN field_reps r ON r.district_id = d.id WHERE r.id = $1`, repID)
	if err != nil {
		return nil, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanDistrict)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// coveredIn — сколько обойдённых клеток внутри района (walkID — только
// впервые обойдённые этим обходом).
func (s *Service) coveredIn(ctx context.Context, poly Polygon, walkID string) (int, error) {
	if len(poly) < 3 {
		return 0, nil
	}
	a, b := poly.bounds()
	rows, err := s.pool.Query(ctx, `
		SELECT cx, cy FROM field_cells
		WHERE cx BETWEEN $1 AND $2 AND cy BETWEEN $3 AND $4 AND ($5 = '' OR walk_id::text = $5)`,
		a.x, b.x, a.y, b.y, walkID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var c cell
		if err := rows.Scan(&c.x, &c.y); err != nil {
			return 0, err
		}
		if poly.hasCell(c) {
			n++
		}
	}
	return n, rows.Err()
}

// fill — покрытие и статистика района.
func (s *Service) fill(ctx context.Context, d *District) error {
	if d.TotalCells > 0 {
		n, err := s.coveredIn(ctx, d.poly, "")
		if err != nil {
			return err
		}
		d.CoveredCells = n
		v := pct(n, d.TotalCells)
		d.CoveragePct = &v
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(array_agg(r.full_name ORDER BY r.full_name) FILTER (WHERE r.status = 'active'), '{}'),
		       max(w.last_at), COALESCE(bool_or(w.status <> 'ended'), false)
		FROM field_reps r
		LEFT JOIN LATERAL (SELECT status, COALESCE(last_at, started_at) AS last_at FROM field_walks
		                   WHERE rep_id = r.id ORDER BY started_at DESC LIMIT 1) w ON true
		WHERE r.district_id = $1`, d.ID).Scan(&d.Reps, &d.LastWalk, &d.Walking); err != nil {
		return err
	}
	if len(d.poly) < 3 {
		return nil
	}
	a, b := d.poly.bounds()
	minLat, minLng := float64(a.y)*cellLat, float64(a.x)*cellLng
	maxLat, maxLng := float64(b.y+1)*cellLat, float64(b.x+1)*cellLng
	rows, err := s.pool.Query(ctx, `
		SELECT ST_Y(p.location::geometry), ST_X(p.location::geometry), COALESCE(sl.status = 'connected', false)
		FROM field_places p LEFT JOIN store_leads sl ON sl.id = p.lead_id
		WHERE ST_Intersects(p.location, ST_MakeEnvelope($1, $2, $3, $4, 4326)::geography)`, minLng, minLat, maxLng, maxLat)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			lat, lng float64
			conn     bool
		)
		if err := rows.Scan(&lat, &lng, &conn); err != nil {
			return err
		}
		if d.poly.contains(lat, lng) {
			d.Places++
			if conn {
				d.Connected++
			}
		}
	}
	return rows.Err()
}

// Districts — С3 «Покрытие районов» (и районы для выбора у продажника).
type Districts struct {
	Items []District `json:"items"`
	// По всем районам с границей.
	TotalCells   int      `json:"total_cells"`
	CoveredCells int      `json:"covered_cells"`
	CoveragePct  *float64 `json:"coverage_pct"`
	Grid         Grid     `json:"grid"`
}

func (s *Service) Districts(ctx context.Context, p *identity.Principal) (Districts, error) {
	if err := requireAdmin(p); err != nil {
		return Districts{}, err
	}
	rows, err := s.pool.Query(ctx, districtSelect+` ORDER BY d.sort, d.name`)
	if err != nil {
		return Districts{}, err
	}
	items, err := pgx.CollectRows(rows, scanDistrict)
	if err != nil {
		return Districts{}, err
	}
	out := Districts{Items: items, Grid: grid()}
	if out.Items == nil {
		out.Items = []District{}
	}
	for i := range out.Items {
		if err := s.fill(ctx, &out.Items[i]); err != nil {
			return out, err
		}
		out.TotalCells += out.Items[i].TotalCells
		out.CoveredCells += out.Items[i].CoveredCells
	}
	if out.TotalCells > 0 {
		v := pct(out.CoveredCells, out.TotalCells)
		out.CoveragePct = &v
	}
	return out, nil
}

func (s *Service) district(ctx context.Context, id string) (District, error) {
	if !httpx.IsUUID(id) {
		return District{}, errDistrictNotFound()
	}
	rows, err := s.pool.Query(ctx, districtSelect+` WHERE d.id = $1`, id)
	if err != nil {
		return District{}, err
	}
	d, err := pgx.CollectExactlyOneRow(rows, scanDistrict)
	if errors.Is(err, pgx.ErrNoRows) {
		return District{}, errDistrictNotFound()
	}
	if err != nil {
		return d, err
	}
	return d, s.fill(ctx, &d)
}

func errDistrictNotFound() error {
	return apperr.NotFound("район не найден").Uz("tuman topilmadi")
}

// BoundaryInput — граница района, нарисованная на карте.
type BoundaryInput struct {
	Boundary Polygon `json:"boundary"`
}

// SetBoundary сохраняет границу района и пересчитывает число клеток.
func (s *Service) SetBoundary(ctx context.Context, p *identity.Principal, id string, in BoundaryInput) (District, error) {
	if err := requireAdmin(p); err != nil {
		return District{}, err
	}
	poly := in.Boundary
	if poly == nil {
		poly = Polygon{}
	}
	if len(poly) > 0 && len(poly) < 3 {
		return District{}, apperr.Validation("boundary: нужно хотя бы 3 точки").Uz("boundary: kamida 3 ta nuqta kerak")
	}
	if len(poly) > 500 {
		return District{}, apperr.Validation("boundary: не больше 500 точек").Uz("boundary: 500 tadan koʻp nuqta boʻlmasin")
	}
	for _, v := range poly {
		// Только Ташкент и окрестности.
		if v[0] < 40.5 || v[0] > 42 || v[1] < 68.5 || v[1] > 70.5 {
			return District{}, apperr.Validation("boundary: точки вне Ташкента").Uz("boundary: nuqtalar Toshkentdan tashqarida")
		}
	}
	total := poly.cellCount()
	if total > 200000 {
		return District{}, apperr.Validation("boundary: слишком большой район").Uz("boundary: tuman juda katta")
	}
	b, err := json.Marshal(poly)
	if err != nil {
		return District{}, err
	}
	if !httpx.IsUUID(id) {
		return District{}, errDistrictNotFound()
	}
	tag, err := s.pool.Exec(ctx, `UPDATE field_districts SET boundary = $2, total_cells = $3 WHERE id = $1`, id, b, total)
	if err != nil {
		return District{}, err
	}
	if tag.RowsAffected() == 0 {
		return District{}, errDistrictNotFound()
	}
	return s.district(ctx, id)
}

// ResetCoverage — «Сбросить покрытие района»: обойдённые клетки района
// снова белые (район обходят заново). Путь и отметки магазинов остаются.
func (s *Service) ResetCoverage(ctx context.Context, p *identity.Principal, id string) (District, error) {
	if err := requireAdmin(p); err != nil {
		return District{}, err
	}
	d, err := s.district(ctx, id)
	if err != nil {
		return d, err
	}
	if len(d.poly) < 3 {
		return District{}, apperr.Validation("сначала нарисуйте границу района").Uz("avval tuman chegarasini chizing")
	}
	a, b := d.poly.bounds()
	var xs, ys []int
	for x := a.x; x <= b.x; x++ {
		for y := a.y; y <= b.y; y++ {
			if d.poly.hasCell(cell{x, y}) {
				xs, ys = append(xs, x), append(ys, y)
			}
		}
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM field_cells WHERE (cx, cy) IN (SELECT * FROM unnest($1::int[], $2::int[]))`, xs, ys); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM field_rep_cells WHERE (cx, cy) IN (SELECT * FROM unnest($1::int[], $2::int[]))`, xs, ys)
		return err
	})
	if err != nil {
		return District{}, err
	}
	return s.district(ctx, id)
}
