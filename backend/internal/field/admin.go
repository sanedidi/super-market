package field

import (
	"context"
	"encoding/json"
	"math"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Супер-админ: С1 «Сейчас» — кто в обходе и где; С2 «Маршрут за день».

// noSignalAfter — от продажника в обходе нет точек дольше: «Нет сигнала».
const noSignalAfter = 5 * time.Minute

// LiveRep — продажник на экране «Сейчас».
type LiveRep struct {
	Rep
	// walking — в обходе; paused — пауза; no_signal — в обходе, но точек нет
	// дольше 5 минут; off — не в обходе.
	State string    `json:"state"`
	Walk  *Walk     `json:"walk"`
	Today DayTotals `json:"today"`
	// Последний обход сегодня закончился (для «закончила в 12:10»).
	EndedAt *time.Time `json:"ended_at"`
}

// Live — С1.
type Live struct {
	Reps []LiveRep `json:"reps"`
	// Сейчас в обходе и всего активных продажников.
	Walking int `json:"walking"`
	Total   int `json:"total"`
	// Сегодня по всем продажникам.
	Today    DayTotals `json:"today"`
	OtherPct int       `json:"other_pct"`
	Grid     Grid      `json:"grid"`
}

func (s *Service) Live(ctx context.Context, p *identity.Principal) (Live, error) {
	if err := requireAdmin(p); err != nil {
		return Live{}, err
	}
	reps, err := s.Reps(ctx, p)
	if err != nil {
		return Live{}, err
	}
	out := Live{Reps: []LiveRep{}, Grid: grid()}
	now := s.now()
	for _, r := range reps {
		if r.Status != "active" {
			continue
		}
		lr := LiveRep{Rep: r, State: "off"}
		rows, err := s.pool.Query(ctx, walkSelect+`
			WHERE w.rep_id = $1 AND (w.status <> 'ended' OR (w.started_at AT TIME ZONE 'Asia/Tashkent')::date = `+todaySQL+`)
			ORDER BY w.started_at DESC LIMIT 1`, r.ID)
		if err != nil {
			return out, err
		}
		ws, err := pgx.CollectRows(rows, scanWalk)
		if err != nil {
			return out, err
		}
		if len(ws) > 0 {
			w := ws[0]
			switch {
			case w.Status == WalkPaused:
				lr.State, lr.Walk = "paused", &w
			case w.Status == WalkActive && (w.LastAt == nil || now.Sub(*w.LastAt) > noSignalAfter) && now.Sub(w.StartedAt) > noSignalAfter:
				lr.State, lr.Walk = "no_signal", &w
			case w.Status == WalkActive:
				lr.State, lr.Walk = "walking", &w
			default:
				lr.EndedAt = w.EndedAt
			}
		}
		if lr.Today, err = s.dayTotals(ctx, r.ID, time.Time{}); err != nil {
			return out, err
		}
		out.Total++
		if lr.State != "off" {
			out.Walking++
		}
		out.Today.DistanceM += lr.Today.DistanceM
		out.Today.OtherM += lr.Today.OtherM
		out.Today.Places += lr.Today.Places
		out.Today.Leads += lr.Today.Leads
		out.Today.ActiveSec += lr.Today.ActiveSec
		out.Reps = append(out.Reps, lr)
	}
	if out.Today.DistanceM > 0 {
		out.OtherPct = int(math.Round(out.Today.OtherM / out.Today.DistanceM * 100))
	}
	return out, nil
}

// Event — строка хронологии (С2).
type Event struct {
	At time.Time `json:"at"`
	// start, pause, resume, finish, auto_pause, auto_finish, other, visit.
	Kind string   `json:"kind"`
	Lat  *float64 `json:"lat"`
	Lng  *float64 `json:"lng"`
	// other: rep_name, first_at; resume: auto.
	Data  map[string]any `json:"data,omitempty"`
	Visit *Visit         `json:"visit,omitempty"`
}

// DayWalk — обход дня с путём.
type DayWalk struct {
	Walk
	Pts [][2]float64 `json:"pts"`
}

// Day — С2 «Маршрут за день».
type Day struct {
	Rep      Rep       `json:"rep"`
	Date     string    `json:"date"`
	Walks    []DayWalk `json:"walks"`
	Events   []Event   `json:"events"`
	Totals   DayTotals `json:"totals"`
	OtherPct int       `json:"other_pct"`
	NewCells int       `json:"new_cells"`
	Mock     int       `json:"mock_points"`
	Gaps     int       `json:"gaps"`
	Grid     Grid      `json:"grid"`
}

// RepDay — путь, хронология и итоги продажника за день (date — YYYY-MM-DD, пусто — сегодня).
func (s *Service) RepDay(ctx context.Context, p *identity.Principal, repID, date string) (Day, error) {
	if err := requireAdmin(p); err != nil {
		return Day{}, err
	}
	rep, err := s.rep(ctx, repID)
	if err != nil {
		return Day{}, err
	}
	day := s.now().In(tz)
	if date != "" {
		if day, err = time.ParseInLocation("2006-01-02", date, tz); err != nil {
			return Day{}, apperr.Validation("date: YYYY-MM-DD").Uz("date: YYYY-MM-DD")
		}
	}
	out := Day{Rep: rep, Date: day.Format("2006-01-02"), Walks: []DayWalk{}, Events: []Event{}, Grid: grid()}
	if out.Totals, err = s.dayTotals(ctx, repID, day); err != nil {
		return out, err
	}
	if out.Totals.DistanceM > 0 {
		out.OtherPct = int(math.Round(out.Totals.OtherM / out.Totals.DistanceM * 100))
	}
	rows, err := s.pool.Query(ctx, walkSelect+`
		WHERE w.rep_id = $1 AND (w.started_at AT TIME ZONE 'Asia/Tashkent')::date = $2::date
		ORDER BY w.started_at`, repID, out.Date)
	if err != nil {
		return out, err
	}
	walks, err := pgx.CollectRows(rows, scanWalk)
	if err != nil {
		return out, err
	}
	ids := make([]string, 0, len(walks))
	for _, w := range walks {
		out.NewCells += w.NewCells
		out.Mock += w.MockPoints
		out.Gaps += w.Gaps
		dw := DayWalk{Walk: w, Pts: [][2]float64{}}
		r, err := s.pool.Query(ctx, `SELECT lat, lng FROM field_points WHERE walk_id = $1 AND NOT mocked ORDER BY at`, w.ID)
		if err != nil {
			return out, err
		}
		for r.Next() {
			var lat, lng float64
			if err := r.Scan(&lat, &lng); err != nil {
				r.Close()
				return out, err
			}
			if n := len(dw.Pts); n == 0 || distM(dw.Pts[n-1][0], dw.Pts[n-1][1], lat, lng) >= 5 {
				dw.Pts = append(dw.Pts, [2]float64{round6(lat), round6(lng)})
			}
		}
		r.Close()
		if err := r.Err(); err != nil {
			return out, err
		}
		out.Walks = append(out.Walks, dw)
		ids = append(ids, w.ID)
	}
	if len(ids) > 0 {
		r, err := s.pool.Query(ctx, `
			SELECT at, kind, lat, lng, data FROM field_walk_events WHERE walk_id = ANY($1::uuid[]) ORDER BY at`, ids)
		if err != nil {
			return out, err
		}
		for r.Next() {
			var (
				e   Event
				raw []byte
			)
			if err := r.Scan(&e.At, &e.Kind, &e.Lat, &e.Lng, &raw); err != nil {
				r.Close()
				return out, err
			}
			_ = json.Unmarshal(raw, &e.Data)
			if len(e.Data) == 0 {
				e.Data = nil
			}
			out.Events = append(out.Events, e)
		}
		r.Close()
		if err := r.Err(); err != nil {
			return out, err
		}
	}
	// Визиты дня (и вне обхода).
	rows, err = s.pool.Query(ctx, `SELECT `+visitCols(3)+`
		FROM field_visits v JOIN field_reps fr ON fr.id = v.rep_id
		WHERE v.rep_id = $1 AND (v.created_at AT TIME ZONE 'Asia/Tashkent')::date = $2::date
		ORDER BY v.created_at`, repID, out.Date, repID)
	if err != nil {
		return out, err
	}
	visits, err := pgx.CollectRows(rows, scanVisit)
	if err != nil {
		return out, err
	}
	for i := range visits {
		v := visits[i]
		lat, lng := v.Lat, v.Lng
		out.Events = append(out.Events, Event{At: v.CreatedAt, Kind: "visit", Lat: &lat, Lng: &lng, Visit: &v})
	}
	sortEvents(out.Events)
	return out, nil
}

func sortEvents(ev []Event) {
	for i := 1; i < len(ev); i++ {
		for j := i; j > 0 && ev[j].At.Before(ev[j-1].At); j-- {
			ev[j], ev[j-1] = ev[j-1], ev[j]
		}
	}
}

// AdminPlace — карточка магазина у супер-админа.
func (s *Service) AdminPlace(ctx context.Context, p *identity.Principal, id string) (Place, error) {
	if err := requireAdmin(p); err != nil {
		return Place{}, err
	}
	if !httpx.IsUUID(id) {
		return Place{}, errPlaceNotFound()
	}
	return s.place(ctx, "", id, true)
}
