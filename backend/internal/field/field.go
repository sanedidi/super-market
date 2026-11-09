// Package field — «SM Продажник»: продажники Super Market ходят по районам,
// телефон во время обхода пишет путь, продажник отмечает магазины (Figma
// «SM Продажник · Обход с записью пути», П1–П7, и «Супер-админ · Продажники»,
// С1–С3).
//
// Путь пишется только между «Начать обход» и «Закончить». Город поделён на
// клетки 100×100 м (grid.go): клетка, через которую прошёл любой продажник,
// обойдена навсегда — другой продажник видит её на карте, а зайдя в неё,
// получает «Здесь уже прошёл …» и путь до ближайшей белой зоны. Отметки
// магазинов (подключить / отказ / закрыт / прийти позже / уже с Super Market)
// видны всем продажникам навсегда; «Подключить» — та же заявка, что у агента
// «SM Агент» (supply), но без начисления 50%.
package field

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/supply"
)

// Результаты визита в магазин.
const (
	ResultLead    = "lead"    // подключить — заявка супер-админу
	ResultRefused = "refused" // отказ (фото витрины и причина)
	ResultClosed  = "closed"  // закрыт / не работает
	ResultLater   = "later"   // прийти позже (день)
	ResultOurs    = "ours"    // уже с Super Market
)

// Статусы обхода.
const (
	WalkActive = "active"
	WalkPaused = "paused"
	WalkEnded  = "ended"
)

const (
	// samePlaceM — ближе этого к отмеченному магазину сначала спрашиваем «Это он?».
	samePlaceM = 50
	// maxAccuracyM — точки с точностью хуже не принимаем.
	maxAccuracyM = 30
	// maxSpeedMS — «прыжок» быстрее 150 км/ч — ошибка GPS.
	maxSpeedMS = 150.0 / 3.6
	// gapSec — между точками дольше: разрыв (нет связи или GPS).
	gapSec = 120
	// movedM — сдвинулся больше — не стоит на месте (автопауза через autoPauseAfter).
	movedM = 50
	// autoPauseAfter — стоит на месте дольше: обход на паузе.
	autoPauseAfter = 30 * time.Minute
	// autoEndHour — в этот час по Ташкенту открытые обходы закрываются.
	autoEndHour = 21
	// maxBatch — точек в одном запросе.
	maxBatch = 1000
)

// tz — день и «сегодня» считаются по Ташкенту.
var tz = func() *time.Location {
	l, err := time.LoadLocation("Asia/Tashkent")
	if err != nil {
		return time.FixedZone("UTC+5", 5*3600)
	}
	return l
}()

// todaySQL — сегодняшняя дата по Ташкенту.
const todaySQL = `(now() AT TIME ZONE 'Asia/Tashkent')::date`

type Service struct {
	pool  *pgxpool.Pool
	leads *supply.Service
	log   *slog.Logger
	now   func() time.Time
}

func NewService(pool *pgxpool.Pool, leads *supply.Service, log *slog.Logger) *Service {
	return &Service{pool: pool, leads: leads, log: log, now: time.Now}
}

func requireRep(p *identity.Principal) error {
	if p == nil || p.App != identity.AppField || p.RepID == "" {
		return apperr.Forbidden("только для продажника Super Market").Uz("faqat Super Market savdo agenti uchun")
	}
	return nil
}

func requireAdmin(p *identity.Principal) error {
	if p == nil || p.App != identity.AppAdmin {
		return apperr.Forbidden("только для супер-админа").Uz("faqat super-admin uchun")
	}
	return nil
}

// ------------------------------------------------------------------ обход

// Results — сколько магазинов отмечено с каждым результатом.
type Results struct {
	Lead    int `json:"lead"`
	Refused int `json:"refused"`
	Closed  int `json:"closed"`
	Later   int `json:"later"`
	Ours    int `json:"ours"`
	Total   int `json:"total"`
}

// Walk — обход.
type Walk struct {
	ID         string     `json:"id"`
	RepID      string     `json:"rep_id"`
	Status     string     `json:"status"`
	StartedAt  time.Time  `json:"started_at"`
	EndedAt    *time.Time `json:"ended_at"`
	EndReason  string     `json:"end_reason"`
	PausedAt   *time.Time `json:"paused_at"`
	AutoPaused bool       `json:"auto_paused"`
	// Время в обходе без пауз, с.
	ActiveSec  int        `json:"active_sec"`
	DistanceM  float64    `json:"distance_m"`
	OtherM     float64    `json:"other_m"`
	NewCells   int        `json:"new_cells"`
	Points     int        `json:"points"`
	MockPoints int        `json:"mock_points"`
	Gaps       int        `json:"gaps"`
	LastLat    *float64   `json:"last_lat"`
	LastLng    *float64   `json:"last_lng"`
	LastAt     *time.Time `json:"last_at"`
	Results    Results    `json:"results"`
}

const walkSelect = `
	SELECT w.id, w.rep_id, w.status, w.started_at, w.ended_at, w.end_reason, w.paused_at, w.auto_paused,
	       GREATEST(0, EXTRACT(EPOCH FROM (COALESCE(w.ended_at, now()) - w.started_at))::int - w.pause_sec
	           - CASE WHEN w.status = 'paused' AND w.paused_at IS NOT NULL
	                  THEN EXTRACT(EPOCH FROM (now() - w.paused_at))::int ELSE 0 END),
	       w.distance_m, w.other_m, w.new_cells, w.points, w.mock_points, w.gaps,
	       w.last_lat, w.last_lng, w.last_at,
	       COALESCE(v.lead, 0), COALESCE(v.refused, 0), COALESCE(v.closed, 0), COALESCE(v.later, 0),
	       COALESCE(v.ours, 0), COALESCE(v.total, 0)
	FROM field_walks w
	LEFT JOIN LATERAL (
		SELECT count(*) FILTER (WHERE result = 'lead')::int AS lead,
		       count(*) FILTER (WHERE result = 'refused')::int AS refused,
		       count(*) FILTER (WHERE result = 'closed')::int AS closed,
		       count(*) FILTER (WHERE result = 'later')::int AS later,
		       count(*) FILTER (WHERE result = 'ours')::int AS ours,
		       count(*)::int AS total
		FROM field_visits WHERE walk_id = w.id) v ON true`

func scanWalk(row pgx.CollectableRow) (Walk, error) {
	var w Walk
	r := &w.Results
	err := row.Scan(&w.ID, &w.RepID, &w.Status, &w.StartedAt, &w.EndedAt, &w.EndReason, &w.PausedAt, &w.AutoPaused,
		&w.ActiveSec, &w.DistanceM, &w.OtherM, &w.NewCells, &w.Points, &w.MockPoints, &w.Gaps,
		&w.LastLat, &w.LastLng, &w.LastAt,
		&r.Lead, &r.Refused, &r.Closed, &r.Later, &r.Ours, &r.Total)
	return w, err
}

func getWalk(ctx context.Context, q interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, id string) (Walk, error) {
	rows, err := q.Query(ctx, walkSelect+` WHERE w.id = $1`, id)
	if err != nil {
		return Walk{}, err
	}
	w, err := pgx.CollectExactlyOneRow(rows, scanWalk)
	if err == pgx.ErrNoRows {
		return Walk{}, errWalkNotFound()
	}
	return w, err
}

func errWalkNotFound() error {
	return apperr.NotFound("обход не найден").Uz("aylanish topilmadi")
}

// ---------------------------------------------------------------- магазины

// Place — магазин, отмеченный продажниками: точка и последний результат.
type Place struct {
	ID          string    `json:"id"`
	Lat         float64   `json:"lat"`
	Lng         float64   `json:"lng"`
	Name        string    `json:"name"`
	Result      string    `json:"result"`
	LastVisitAt time.Time `json:"last_visit_at"`
	RepID       *string   `json:"rep_id"`
	RepName     string    `json:"rep_name"`
	// Последний раз отмечал этот продажник.
	Mine     bool    `json:"mine"`
	RemindOn *string `json:"remind_on"`
	PhotoURL string  `json:"photo_url"`
	Visits   int     `json:"visits"`
	LeadID   *string `json:"lead_id"`
	// Статус заявки: pending, connected, rejected, expired (пусто — заявки нет).
	LeadStatus string `json:"lead_status"`
	DistanceM  *int   `json:"distance_m,omitempty"`
	// История визитов — только в карточке магазина.
	History []Visit `json:"history,omitempty"`
	// Вход владельца магазина, который подключил этот продажник (П15–П17):
	// логин и временный пароль, пока владелец ни разу не вошёл.
	Owner *identity.OwnerLogin `json:"owner,omitempty"`
}

// placeCols — колонки Place; $me — продажник (пустая строка — супер-админ).
func placeCols(me int) string {
	return `p.id, ST_Y(p.location::geometry), ST_X(p.location::geometry), p.name, p.last_result, p.last_visit_at,
	       p.last_rep_id::text, COALESCE(fr.full_name, ''), COALESCE(p.last_rep_id::text = $` + itoa(me) + `, false),
	       to_char(p.remind_on, 'YYYY-MM-DD'), p.photo_url, p.visits, p.lead_id::text,
	       COALESCE(CASE WHEN sl.status = 'pending' AND sl.expires_at <= now() THEN 'expired' ELSE sl.status END, '')`
}

const placeJoins = `
	FROM field_places p
	LEFT JOIN field_reps fr  ON fr.id = p.last_rep_id
	LEFT JOIN store_leads sl ON sl.id = p.lead_id`

func scanPlace(row pgx.CollectableRow) (Place, error) {
	var p Place
	err := row.Scan(&p.ID, &p.Lat, &p.Lng, &p.Name, &p.Result, &p.LastVisitAt, &p.RepID, &p.RepName, &p.Mine,
		&p.RemindOn, &p.PhotoURL, &p.Visits, &p.LeadID, &p.LeadStatus)
	return p, err
}

func scanPlaceDist(row pgx.CollectableRow) (Place, error) {
	var p Place
	var d int
	err := row.Scan(&p.ID, &p.Lat, &p.Lng, &p.Name, &p.Result, &p.LastVisitAt, &p.RepID, &p.RepName, &p.Mine,
		&p.RemindOn, &p.PhotoURL, &p.Visits, &p.LeadID, &p.LeadStatus, &d)
	p.DistanceM = &d
	return p, err
}

// Visit — визит продажника в магазин.
type Visit struct {
	ID        string    `json:"id"`
	PlaceID   string    `json:"place_id"`
	Result    string    `json:"result"`
	RepID     string    `json:"rep_id"`
	RepName   string    `json:"rep_name"`
	Mine      bool      `json:"mine"`
	Lat       float64   `json:"lat"`
	Lng       float64   `json:"lng"`
	Name      string    `json:"name"`
	Reason    string    `json:"reason"`
	Program   string    `json:"program"`
	Comment   string    `json:"comment"`
	PhotoURL  string    `json:"photo_url"`
	RemindOn  *string   `json:"remind_on"`
	LeadID    *string   `json:"lead_id"`
	CreatedAt time.Time `json:"created_at"`
}

func visitCols(me int) string {
	return `v.id, v.place_id, v.result, v.rep_id, fr.full_name, v.rep_id::text = $` + itoa(me) + `,
	       ST_Y(v.location::geometry), ST_X(v.location::geometry), v.name, v.reason, v.program, v.comment,
	       v.photo_url, to_char(v.remind_on, 'YYYY-MM-DD'), v.lead_id::text, v.created_at`
}

func scanVisit(row pgx.CollectableRow) (Visit, error) {
	var v Visit
	err := row.Scan(&v.ID, &v.PlaceID, &v.Result, &v.RepID, &v.RepName, &v.Mine, &v.Lat, &v.Lng, &v.Name, &v.Reason,
		&v.Program, &v.Comment, &v.PhotoURL, &v.RemindOn, &v.LeadID, &v.CreatedAt)
	return v, err
}

func itoa(n int) string {
	const digits = "0123456789"
	if n < 10 {
		return digits[n : n+1]
	}
	return itoa(n/10) + digits[n%10:n%10+1]
}
