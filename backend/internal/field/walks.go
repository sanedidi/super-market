package field

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// П1 «Начать обход» → П2 идёт обход (точки пачками) → «Пауза» / «Закончить» → П6 итог.

// StartInput — где продажник нажал «Начать обход» (необязательно).
type StartInput struct {
	Lat *float64 `json:"lat"`
	Lng *float64 `json:"lng"`
}

// StartWalk начинает обход. Открытый обход уже есть — возвращается он
// (продажник мог закрыть приложение посреди обхода).
func (s *Service) StartWalk(ctx context.Context, p *identity.Principal, in StartInput) (Walk, error) {
	if err := requireRep(p); err != nil {
		return Walk{}, err
	}
	var id string
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT id FROM field_walks WHERE rep_id = $1 AND status <> 'ended' FOR UPDATE`, p.RepID).Scan(&id)
		if err == nil {
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO field_walks (rep_id, last_moved_at) VALUES ($1, now()) RETURNING id`, p.RepID).Scan(&id); err != nil {
			if db.IsUniqueViolation(err, "field_walks_open_uq") {
				return apperr.Conflict("walk_open", "обход уже начат — обновите экран").Uz("aylanish allaqachon boshlangan — ekranni yangilang")
			}
			return err
		}
		return addEvent(ctx, tx, id, s.now(), "start", in.Lat, in.Lng, nil)
	})
	if err != nil {
		return Walk{}, err
	}
	return getWalk(ctx, s.pool, id)
}

// myWalk — обход продажника (чужой — 404) под блокировкой.
type walkRow struct {
	status             string
	autoPaused         bool
	startedAt          time.Time
	pausedAt           *time.Time
	lastLat, lastLng   *float64
	lastAt             *time.Time
	movedLat, movedLng *float64
}

func lockWalk(ctx context.Context, tx pgx.Tx, repID, id string) (walkRow, error) {
	var w walkRow
	if !httpx.IsUUID(id) {
		return w, errWalkNotFound()
	}
	err := tx.QueryRow(ctx, `
		SELECT status, auto_paused, started_at, paused_at, last_lat, last_lng, last_at, moved_lat, moved_lng
		FROM field_walks WHERE id = $1 AND rep_id = $2 FOR UPDATE`, id, repID).Scan(
		&w.status, &w.autoPaused, &w.startedAt, &w.pausedAt, &w.lastLat, &w.lastLng, &w.lastAt, &w.movedLat, &w.movedLng)
	if errors.Is(err, pgx.ErrNoRows) {
		return w, errWalkNotFound()
	}
	return w, err
}

var errWalkEnded = apperr.Conflict("walk_ended", "обход уже закончен — начните новый").Uz("aylanish tugagan — yangisini boshlang")

func addEvent(ctx context.Context, q db.Querier, walkID string, at time.Time, kind string, lat, lng *float64, data map[string]any) error {
	b := []byte("{}")
	if data != nil {
		var err error
		if b, err = json.Marshal(data); err != nil {
			return err
		}
	}
	_, err := q.Exec(ctx, `INSERT INTO field_walk_events (walk_id, at, kind, lat, lng, data) VALUES ($1, $2, $3, $4, $5, $6)`,
		walkID, at, kind, lat, lng, b)
	return err
}

// PauseWalk — «Пауза»: путь не пишется, время паузы не считается.
func (s *Service) PauseWalk(ctx context.Context, p *identity.Principal, id string) (Walk, error) {
	return s.walkAction(ctx, p, id, func(tx pgx.Tx, w walkRow) error {
		if w.status != WalkActive {
			return nil
		}
		if _, err := tx.Exec(ctx, `UPDATE field_walks SET status = 'paused', paused_at = now(), auto_paused = false WHERE id = $1`, id); err != nil {
			return err
		}
		return addEvent(ctx, tx, id, s.now(), "pause", w.lastLat, w.lastLng, nil)
	})
}

// ResumeWalk — «Продолжить».
func (s *Service) ResumeWalk(ctx context.Context, p *identity.Principal, id string) (Walk, error) {
	return s.walkAction(ctx, p, id, func(tx pgx.Tx, w walkRow) error {
		if w.status != WalkPaused {
			return nil
		}
		if _, err := tx.Exec(ctx, `
			UPDATE field_walks SET status = 'active', auto_paused = false, last_moved_at = now(),
			       pause_sec = pause_sec + GREATEST(0, EXTRACT(EPOCH FROM (now() - COALESCE(paused_at, now())))::int),
			       paused_at = NULL
			WHERE id = $1`, id); err != nil {
			return err
		}
		return addEvent(ctx, tx, id, s.now(), "resume", w.lastLat, w.lastLng, nil)
	})
}

// FinishWalk — «Закончить» (П6 итог обхода).
func (s *Service) FinishWalk(ctx context.Context, p *identity.Principal, id string) (Summary, error) {
	w, err := s.walkAction(ctx, p, id, func(tx pgx.Tx, w walkRow) error {
		if w.status == WalkEnded {
			return nil
		}
		return endWalk(ctx, tx, id, "manual", s.now(), w)
	})
	if err != nil {
		return Summary{}, err
	}
	return s.summary(ctx, p.RepID, w)
}

func endWalk(ctx context.Context, tx pgx.Tx, id, reason string, at time.Time, w walkRow) error {
	if _, err := tx.Exec(ctx, `
		UPDATE field_walks SET status = 'ended', ended_at = now(), end_reason = $2,
		       pause_sec = pause_sec + CASE WHEN status = 'paused'
		           THEN GREATEST(0, EXTRACT(EPOCH FROM (now() - COALESCE(paused_at, now())))::int) ELSE 0 END,
		       paused_at = NULL
		WHERE id = $1`, id, reason); err != nil {
		return err
	}
	kind := "finish"
	if reason == "auto" {
		kind = "auto_finish"
	}
	return addEvent(ctx, tx, id, at, kind, w.lastLat, w.lastLng, nil)
}

func (s *Service) walkAction(ctx context.Context, p *identity.Principal, id string, fn func(pgx.Tx, walkRow) error) (Walk, error) {
	if err := requireRep(p); err != nil {
		return Walk{}, err
	}
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		w, err := lockWalk(ctx, tx, p.RepID, id)
		if err != nil {
			return err
		}
		return fn(tx, w)
	})
	if err != nil {
		return Walk{}, err
	}
	return getWalk(ctx, s.pool, id)
}

// GetWalk — обход продажника.
func (s *Service) GetWalk(ctx context.Context, p *identity.Principal, id string) (Walk, error) {
	if err := requireRep(p); err != nil {
		return Walk{}, err
	}
	if !httpx.IsUUID(id) {
		return Walk{}, errWalkNotFound()
	}
	w, err := getWalk(ctx, s.pool, id)
	if err != nil {
		return w, err
	}
	if w.RepID != p.RepID {
		return Walk{}, errWalkNotFound()
	}
	return w, nil
}

// Summary — П6 «Обход завершён»: обход и покрытие района до и после.
type Summary struct {
	Walk
	// Доля пути по чужим клеткам, %.
	OtherPct int `json:"other_pct"`
	// Район продажника: покрытие до обхода и сейчас (null — граница не задана).
	District       *string  `json:"district"`
	CoverageBefore *float64 `json:"coverage_before"`
	CoverageAfter  *float64 `json:"coverage_after"`
}

func (s *Service) summary(ctx context.Context, repID string, w Walk) (Summary, error) {
	out := Summary{Walk: w}
	if w.DistanceM > 0 {
		out.OtherPct = int(math.Round(w.OtherM / w.DistanceM * 100))
	}
	d, err := s.repDistrict(ctx, repID)
	if err != nil || d == nil {
		return out, err
	}
	out.District = &d.Name
	if d.TotalCells == 0 {
		return out, nil
	}
	covered, err := s.coveredIn(ctx, d.poly, "")
	if err != nil {
		return out, err
	}
	mine, err := s.coveredIn(ctx, d.poly, w.ID)
	if err != nil {
		return out, err
	}
	after := pct(covered, d.TotalCells)
	before := pct(covered-mine, d.TotalCells)
	out.CoverageAfter, out.CoverageBefore = &after, &before
	return out, nil
}

func pct(n, total int) float64 {
	if total == 0 {
		return 0
	}
	return math.Round(float64(n)/float64(total)*1000) / 10
}

// ------------------------------------------------------------------ точки

// PointIn — точка пути из телефона.
type PointIn struct {
	At       time.Time `json:"at"`
	Lat      float64   `json:"lat"`
	Lng      float64   `json:"lng"`
	Accuracy float64   `json:"accuracy"`
	// Геопозиция подделана (приложение-«фейк GPS»): точка сохраняется с
	// пометкой, но путь и клетки по ней не считаются.
	Mocked bool `json:"mocked"`
}

type PointsInput struct {
	Points []PointIn `json:"points"`
}

// Here — клетка, где сейчас продажник (П3 «Здесь уже прошёл …»).
type Here struct {
	// new — тут ещё никто не был; mine — был сам; other — первым тут прошёл другой продажник.
	State   string     `json:"state"`
	CX      int        `json:"cx"`
	CY      int        `json:"cy"`
	RepName string     `json:"rep_name,omitempty"`
	FirstAt *time.Time `json:"first_at,omitempty"`
	// Сколько магазинов отмечено рядом (в квартале — до 150 м).
	Places int `json:"places"`
}

type PointsResult struct {
	Walk     Walk  `json:"walk"`
	Accepted int   `json:"accepted"`
	Here     *Here `json:"here"`
}

type segment struct {
	end cell
	d   float64
	at  time.Time
	lat float64
	lng float64
}

// AddPoints — точки пути пачкой (раз в 30 с; без интернета копятся в телефоне).
func (s *Service) AddPoints(ctx context.Context, p *identity.Principal, id string, in PointsInput) (PointsResult, error) {
	if err := requireRep(p); err != nil {
		return PointsResult{}, err
	}
	if len(in.Points) > maxBatch {
		return PointsResult{}, apperr.Validation("points: не больше 1000 точек за раз").Uz("points: bir martada 1000 tadan koʻp emas")
	}
	pts := append([]PointIn(nil), in.Points...)
	sort.SliceStable(pts, func(i, j int) bool { return pts[i].At.Before(pts[j].At) })
	var out PointsResult
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		w, err := lockWalk(ctx, tx, p.RepID, id)
		if err != nil {
			return err
		}
		if w.status == WalkEnded {
			return errWalkEnded
		}
		if w.status == WalkPaused && !w.autoPaused {
			// Ручная пауза: путь не пишем.
			return nil
		}
		now := s.now()
		var (
			rows               [][]any
			segs               []segment
			cand               = map[cell]struct{}{}
			dist               float64
			gaps, mock         int
			resumed            bool
			lastLat, lastLng   = w.lastLat, w.lastLng
			lastAt             = w.lastAt
			movedLat, movedLng = w.movedLat, w.movedLng
			movedAt            *time.Time
			hereLat, hereLng   *float64
		)
		add := func(c cell) { cand[c] = struct{}{} }
		seen := map[int64]bool{}
		for _, pt := range pts {
			if seen[pt.At.UnixMicro()] {
				continue
			}
			if pt.Lat < -90 || pt.Lat > 90 || pt.Lng < -180 || pt.Lng > 180 || (pt.Lat == 0 && pt.Lng == 0) {
				continue
			}
			if pt.Accuracy > maxAccuracyM || pt.At.IsZero() {
				continue
			}
			if pt.At.Before(w.startedAt.Add(-time.Minute)) || pt.At.After(now.Add(2*time.Minute)) {
				continue
			}
			if lastAt != nil && !pt.At.After(*lastAt) {
				continue
			}
			seen[pt.At.UnixMicro()] = true
			if pt.Mocked {
				mock++
				rows = append(rows, []any{id, pt.At, pt.Lat, pt.Lng, float32(pt.Accuracy), true})
				continue
			}
			if lastAt != nil && lastLat != nil {
				d := distM(*lastLat, *lastLng, pt.Lat, pt.Lng)
				dt := pt.At.Sub(*lastAt).Seconds()
				if dt > 0 && d/dt > maxSpeedMS {
					continue // прыжок GPS
				}
				if dt > gapSec {
					gaps++
				}
				if d <= maxStepM {
					dist += d
				}
				cellsAlong(*lastLat, *lastLng, pt.Lat, pt.Lng, add)
				segs = append(segs, segment{end: cellOf(pt.Lat, pt.Lng), d: math.Min(d, maxStepM), at: pt.At, lat: pt.Lat, lng: pt.Lng})
			} else {
				cellsAround(pt.Lat, pt.Lng, add)
				segs = append(segs, segment{end: cellOf(pt.Lat, pt.Lng), at: pt.At, lat: pt.Lat, lng: pt.Lng})
			}
			rows = append(rows, []any{id, pt.At, pt.Lat, pt.Lng, float32(pt.Accuracy), false})
			la, ln, at := pt.Lat, pt.Lng, pt.At
			lastLat, lastLng, lastAt = &la, &ln, &at
			hereLat, hereLng = &la, &ln
			if movedLat == nil || distM(*movedLat, *movedLng, la, ln) >= movedM {
				movedLat, movedLng, movedAt = &la, &ln, &at
				if w.status == WalkPaused && w.autoPaused && !resumed {
					resumed = true
				}
			}
		}
		if len(rows) == 0 {
			return nil
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"field_points"},
			[]string{"walk_id", "at", "lat", "lng", "accuracy", "mocked"}, pgx.CopyFromRows(rows)); err != nil {
			return err
		}
		out.Accepted = len(rows)

		// Кто первым обошёл клетки (до этой пачки).
		xs, ys := make([]int, 0, len(cand)), make([]int, 0, len(cand))
		for c := range cand {
			xs, ys = append(xs, c.x), append(ys, c.y)
		}
		type owner struct {
			rep, name string
			at        time.Time
		}
		owners := map[cell]owner{}
		mine := map[cell]bool{}
		if len(xs) > 0 {
			r, err := tx.Query(ctx, `
				SELECT c.cx, c.cy, c.rep_id, fr.full_name, c.first_at,
				       EXISTS (SELECT 1 FROM field_rep_cells rc WHERE rc.rep_id = $3 AND rc.cx = c.cx AND rc.cy = c.cy)
				FROM field_cells c JOIN field_reps fr ON fr.id = c.rep_id
				WHERE (c.cx, c.cy) IN (SELECT * FROM unnest($1::int[], $2::int[]))`, xs, ys, p.RepID)
			if err != nil {
				return err
			}
			for r.Next() {
				var (
					c  cell
					o  owner
					me bool
				)
				if err := r.Scan(&c.x, &c.y, &o.rep, &o.name, &o.at, &me); err != nil {
					r.Close()
					return err
				}
				owners[c], mine[c] = o, me
			}
			r.Close()
			if err := r.Err(); err != nil {
				return err
			}
		}
		// Путь по клеткам, которые первым обошёл другой продажник; заход в
		// такую клетку — событие для хронологии супер-админа.
		var other float64
		prevOther := false
		for _, sg := range segs {
			o, ok := owners[sg.end]
			isOther := ok && o.rep != p.RepID && !mine[sg.end]
			if isOther {
				other += sg.d
				if !prevOther {
					la, ln := sg.lat, sg.lng
					if err := addEvent(ctx, tx, id, sg.at, "other", &la, &ln, map[string]any{"rep_name": o.name, "first_at": o.at}); err != nil {
						return err
					}
				}
			}
			prevOther = isOther
		}
		// Где продажник сейчас.
		if hereLat != nil {
			c := cellOf(*hereLat, *hereLng)
			h := &Here{State: "new", CX: c.x, CY: c.y}
			if o, ok := owners[c]; ok {
				if o.rep == p.RepID || mine[c] {
					h.State = "mine"
				} else {
					h.State, h.RepName = "other", o.name
					at := o.at
					h.FirstAt = &at
				}
			}
			if h.State == "other" {
				if err := tx.QueryRow(ctx, `
					SELECT count(*)::int FROM field_places
					WHERE ST_DWithin(location, ST_SetSRID(ST_MakePoint($2::float8, $1::float8), 4326)::geography, 150)`,
					*hereLat, *hereLng).Scan(&h.Places); err != nil {
					return err
				}
			}
			out.Here = h
		}
		var newCells int64
		if len(xs) > 0 {
			tag, err := tx.Exec(ctx, `
				INSERT INTO field_cells (cx, cy, rep_id, walk_id, first_at)
				SELECT x, y, $3, $4, $5 FROM unnest($1::int[], $2::int[]) AS t(x, y)
				ON CONFLICT DO NOTHING`, xs, ys, p.RepID, id, *lastAt)
			if err != nil {
				return err
			}
			newCells = tag.RowsAffected()
			if _, err := tx.Exec(ctx, `
				INSERT INTO field_rep_cells (rep_id, cx, cy, first_at)
				SELECT $3, x, y, $4 FROM unnest($1::int[], $2::int[]) AS t(x, y)
				ON CONFLICT DO NOTHING`, xs, ys, p.RepID, *lastAt); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `
			UPDATE field_walks SET
				distance_m = distance_m + $2, other_m = other_m + $3, new_cells = new_cells + $4,
				points = points + $5, mock_points = mock_points + $6, gaps = gaps + $7,
				last_lat = $8, last_lng = $9, last_at = $10,
				moved_lat = $11, moved_lng = $12, last_moved_at = COALESCE($13, last_moved_at)
			WHERE id = $1`,
			id, dist, other, newCells, len(rows)-mock, mock, gaps, lastLat, lastLng, lastAt, movedLat, movedLng, movedAt); err != nil {
			return err
		}
		if resumed {
			// Стоял больше 30 минут (сервер поставил паузу) и снова пошёл.
			if _, err := tx.Exec(ctx, `
				UPDATE field_walks SET status = 'active', auto_paused = false,
				       pause_sec = pause_sec + GREATEST(0, EXTRACT(EPOCH FROM ($2::timestamptz - COALESCE(paused_at, $2)))::int),
				       paused_at = NULL
				WHERE id = $1`, id, *movedAt); err != nil {
				return err
			}
			if err := addEvent(ctx, tx, id, *movedAt, "resume", movedLat, movedLng, map[string]any{"auto": true}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return out, err
	}
	out.Walk, err = getWalk(ctx, s.pool, id)
	return out, err
}
