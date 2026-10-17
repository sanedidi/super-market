// Package invest — посетители страницы invest.super-market.uz (калькулятор
// окупаемости для инвесторов). Figma «Супер-админ · Инвест-страница».
//
// Страница сама шлёт сигнал при открытии и каждые 15 секунд, пока вкладка
// видна. Посетитель — браузер со случайным номером (vid) в localStorage:
// имени, телефона и адреса не собираем. Визит заканчивается, если 30 минут
// не было сигналов. «Сейчас на странице» — сигнал за последние 60 секунд.
package invest

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

const (
	// Сколько секунд без сигнала посетитель ещё считается «на странице».
	onlineSeconds = 60
	// После скольких минут тишины следующий сигнал — новый визит.
	visitGapMinutes = 30
	// Часовой пояс для «сегодня» и графика по дням.
	tz = "Asia/Tashkent"
)

var vidRe = regexp.MustCompile(`^[A-Za-z0-9]{8,64}$`)

// Service — запись сигналов и статистика.
type Service struct {
	pool *pgxpool.Pool
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

// PingInput — сигнал со страницы.
type PingInput struct {
	VID string `json:"vid"`
	Src string `json:"src"`
}

// Ping записывает сигнал: новый посетитель, новый визит или продолжение визита.
func (s *Service) Ping(ctx context.Context, in PingInput, userAgent string) error {
	if !vidRe.MatchString(in.VID) {
		return apperr.Validation("неверный номер посетителя").Uz("tashrifchi raqami notoʻgʻri")
	}
	kind, device := Device(userAgent)
	source := SourceName(in.Src)
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var inserted bool
		if err := tx.QueryRow(ctx, `
			INSERT INTO invest_visitors (id) VALUES ($1)
			ON CONFLICT (id) DO UPDATE SET last_seen = now()
			RETURNING (xmax = 0)`, in.VID).Scan(&inserted); err != nil {
			return err
		}
		var visitID int64
		err := tx.QueryRow(ctx, `
			SELECT id FROM invest_visits
			WHERE visitor_id = $1 AND last_seen > now() - make_interval(mins => $2)
			ORDER BY last_seen DESC LIMIT 1 FOR UPDATE`, in.VID, visitGapMinutes).Scan(&visitID)
		switch {
		case err == nil:
			_, err = tx.Exec(ctx, `UPDATE invest_visits SET last_seen = now(), pings = pings + 1 WHERE id = $1`, visitID)
			return err
		case errors.Is(err, pgx.ErrNoRows):
			if !inserted {
				if _, err := tx.Exec(ctx, `UPDATE invest_visitors SET visits = visits + 1 WHERE id = $1`, in.VID); err != nil {
					return err
				}
			}
			_, err = tx.Exec(ctx, `
				INSERT INTO invest_visits (visitor_id, is_new, kind, device, source)
				VALUES ($1, $2, $3, $4, $5)`, in.VID, inserted, kind, device, source)
			return err
		default:
			return err
		}
	})
}

// Device — тип устройства (phone / tablet / computer) и подпись «iPhone · Safari».
func Device(ua string) (string, string) {
	has := func(s string) bool { return strings.Contains(ua, s) }
	osName, kind := "", "computer"
	switch {
	case has("iPhone"):
		osName, kind = "iPhone", "phone"
	case has("iPad"):
		osName, kind = "iPad", "tablet"
	case has("Android"):
		osName, kind = "Android", "phone"
		if !has("Mobile") {
			kind = "tablet"
		}
	case has("Windows"):
		osName = "Windows"
	case has("Macintosh"), has("Mac OS X"):
		osName = "Mac"
	case has("Linux"):
		osName = "Linux"
	}
	browser := ""
	switch {
	case has("Instagram"):
		browser = "Instagram"
	case has("FBAN"), has("FBAV"):
		browser = "Facebook"
	case has("Telegram"):
		browser = "Telegram"
	case has("YaBrowser"):
		browser = "Яндекс Браузер"
	case has("Edg/"), has("EdgA/"), has("EdgiOS/"):
		browser = "Edge"
	case has("OPR/"), has("Opera"):
		browser = "Opera"
	case has("SamsungBrowser"):
		browser = "Samsung Internet"
	case has("CriOS"), has("Chrome/"):
		browser = "Chrome"
	case has("FxiOS"), has("Firefox/"):
		browser = "Firefox"
	case has("Safari/"):
		browser = "Safari"
	}
	parts := []string{}
	for _, p := range []string{osName, browser} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) == 0 {
		return kind, "Неизвестно"
	}
	return kind, strings.Join(parts, " · ")
}

// SourceName — откуда пришли: utm_source или сайт, с которого перешли.
func SourceName(src string) string {
	s := strings.ToLower(strings.TrimSpace(src))
	if len(s) > 200 {
		s = s[:200]
	}
	if s == "" {
		return "Прямая ссылка"
	}
	if u, err := url.Parse(s); err == nil && u.Host != "" {
		s = u.Host
	}
	s = strings.TrimPrefix(s, "www.")
	switch {
	case strings.Contains(s, "telegram"), s == "t.me", strings.HasSuffix(s, ".t.me"), s == "tg":
		return "Telegram"
	case strings.Contains(s, "whatsapp"), s == "wa.me":
		return "WhatsApp"
	case strings.Contains(s, "instagram"):
		return "Instagram"
	case strings.Contains(s, "facebook"), s == "fb", s == "m.facebook.com":
		return "Facebook"
	case strings.Contains(s, "google"):
		return "Google"
	case strings.Contains(s, "yandex"), strings.Contains(s, "ya.ru"):
		return "Яндекс"
	case strings.Contains(s, "super-market.uz"):
		return "Сайт Super Market"
	}
	return s
}

// Stats — ответ для экрана «Инвест-страница».
type Stats struct {
	Period      string     `json:"period"`
	Since       time.Time  `json:"since"`
	Now         int        `json:"now"`
	NowList     []Visit    `json:"now_list"`
	NewVisitors int        `json:"new_visitors"`
	PrevNew     *int       `json:"prev_new"`
	Returned    int        `json:"returned"`
	Visits      int        `json:"visits"`
	AvgSeconds  int        `json:"avg_seconds"`
	MedianSecs  int        `json:"median_seconds"`
	TotalUnique int        `json:"total_unique"`
	FirstSeen   *time.Time `json:"first_seen"`
	Days        []Day      `json:"days"`
	Sources     []Source   `json:"sources"`
	Recent      []Visit    `json:"recent"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

type Day struct {
	Date     string `json:"date"`
	New      int    `json:"new"`
	Returned int    `json:"returned"`
}

type Source struct {
	Source   string `json:"source"`
	Visitors int    `json:"visitors"`
}

type Visit struct {
	Visitor   string    `json:"visitor"`
	StartedAt time.Time `json:"started_at"`
	LastSeen  time.Time `json:"last_seen"`
	Seconds   int       `json:"seconds"`
	IsNew     bool      `json:"is_new"`
	Kind      string    `json:"kind"`
	Device    string    `json:"device"`
	Source    string    `json:"source"`
	Visits    int       `json:"visits"`
}

// periodDays — сколько дней назад от начала сегодняшнего дня начинается период.
func periodDays(p string) (int, bool) {
	switch p {
	case "today":
		return 0, true
	case "7d":
		return 6, true
	case "30d", "":
		return 29, true
	case "all":
		return -1, true
	}
	return 0, false
}

const visitCols = `upper(substr(md5(v.visitor_id), 1, 4)), v.started_at, v.last_seen,
	extract(epoch FROM v.last_seen - v.started_at)::int, v.is_new, v.kind, v.device, v.source, iv.visits`

func scanVisits(rows pgx.Rows) ([]Visit, error) {
	defer rows.Close()
	out := []Visit{}
	for rows.Next() {
		var v Visit
		if err := rows.Scan(&v.Visitor, &v.StartedAt, &v.LastSeen, &v.Seconds, &v.IsNew, &v.Kind, &v.Device, &v.Source, &v.Visits); err != nil {
			return nil, err
		}
		v.Visitor = "Посетитель " + v.Visitor
		out = append(out, v)
	}
	return out, rows.Err()
}

// OnlineNow — сколько посетителей сейчас на странице (для значка в меню).
func (s *Service) OnlineNow(ctx context.Context) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `
		SELECT count(DISTINCT visitor_id)::int FROM invest_visits
		WHERE last_seen > now() - make_interval(secs => $1::int)`, onlineSeconds).Scan(&n)
	return n, err
}

// Stats — цифры за период: today, 7d, 30d, all.
func (s *Service) Stats(ctx context.Context, period string) (*Stats, error) {
	back, ok := periodDays(period)
	if !ok {
		return nil, apperr.Validation("неизвестный период").Uz("nomaʼlum davr")
	}
	if period == "" {
		period = "30d"
	}
	out := &Stats{Period: period, NowList: []Visit{}, Days: []Day{}, Sources: []Source{}, Recent: []Visit{}, UpdatedAt: time.Now()}
	q := s.pool

	// Начало периода — полночь по Ташкенту; «всё время» — первый посетитель.
	if err := q.QueryRow(ctx, `SELECT count(*)::int, min(first_seen) FROM invest_visitors`).Scan(&out.TotalUnique, &out.FirstSeen); err != nil {
		return nil, err
	}
	if back < 0 {
		if out.FirstSeen != nil {
			if err := q.QueryRow(ctx, `SELECT date_trunc('day', $1::timestamptz AT TIME ZONE $2) AT TIME ZONE $2`, *out.FirstSeen, tz).Scan(&out.Since); err != nil {
				return nil, err
			}
		} else if err := q.QueryRow(ctx, `SELECT date_trunc('day', now() AT TIME ZONE $1) AT TIME ZONE $1`, tz).Scan(&out.Since); err != nil {
			return nil, err
		}
	} else if err := q.QueryRow(ctx, `
		SELECT (date_trunc('day', now() AT TIME ZONE $1) - make_interval(days => $2)) AT TIME ZONE $1`, tz, back).Scan(&out.Since); err != nil {
		return nil, err
	}

	// Сейчас на странице.
	rows, err := q.Query(ctx, `
		SELECT DISTINCT ON (v.visitor_id) `+visitCols+`
		FROM invest_visits v JOIN invest_visitors iv ON iv.id = v.visitor_id
		WHERE v.last_seen > now() - make_interval(secs => $1::int)
		ORDER BY v.visitor_id, v.last_seen DESC`, onlineSeconds)
	if err != nil {
		return nil, err
	}
	if out.NowList, err = scanVisits(rows); err != nil {
		return nil, err
	}
	out.Now = len(out.NowList)

	// Новые, вернувшиеся, визиты и время на странице.
	if err := q.QueryRow(ctx, `SELECT count(*)::int FROM invest_visitors WHERE first_seen >= $1`, out.Since).Scan(&out.NewVisitors); err != nil {
		return nil, err
	}
	if back >= 0 {
		var prev int
		if err := q.QueryRow(ctx, `
			SELECT count(*)::int FROM invest_visitors
			WHERE first_seen >= $1::timestamptz - make_interval(days => $2) AND first_seen < $1`, out.Since, back+1).Scan(&prev); err != nil {
			return nil, err
		}
		out.PrevNew = &prev
	}
	if err := q.QueryRow(ctx, `
		SELECT count(DISTINCT v.visitor_id) FILTER (WHERE iv.first_seen < $1)::int,
		       count(*)::int,
		       coalesce(avg(extract(epoch FROM v.last_seen - v.started_at)), 0)::int,
		       coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM v.last_seen - v.started_at)::float8), 0)::int
		FROM invest_visits v JOIN invest_visitors iv ON iv.id = v.visitor_id
		WHERE v.started_at >= $1`, out.Since).Scan(&out.Returned, &out.Visits, &out.AvgSeconds, &out.MedianSecs); err != nil {
		return nil, err
	}

	// По дням: новые — первый визит посетителя, вернулись — остальные посетители дня.
	rows, err = q.Query(ctx, `
		WITH d AS (
			SELECT gs::date AS day
			FROM generate_series(($1::timestamptz AT TIME ZONE $2)::date::timestamp, (now() AT TIME ZONE $2)::date::timestamp, interval '1 day') gs
		), v AS (
			SELECT (started_at AT TIME ZONE $2)::date AS day, visitor_id, bool_or(is_new) AS is_new
			FROM invest_visits WHERE started_at >= $1
			GROUP BY 1, 2
		)
		SELECT to_char(d.day, 'YYYY-MM-DD'),
		       count(v.visitor_id) FILTER (WHERE v.is_new)::int,
		       count(v.visitor_id) FILTER (WHERE NOT v.is_new)::int
		FROM d LEFT JOIN v ON v.day = d.day
		GROUP BY d.day ORDER BY d.day DESC LIMIT 366`, out.Since, tz)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var d Day
		if err := rows.Scan(&d.Date, &d.New, &d.Returned); err != nil {
			rows.Close()
			return nil, err
		}
		out.Days = append(out.Days, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out.Days)-1; i < j; i, j = i+1, j-1 {
		out.Days[i], out.Days[j] = out.Days[j], out.Days[i]
	}

	// Откуда пришли — уникальные посетители по источнику.
	rows, err = q.Query(ctx, `
		SELECT source, count(DISTINCT visitor_id)::int FROM invest_visits
		WHERE started_at >= $1 GROUP BY source ORDER BY 2 DESC, 1 LIMIT 12`, out.Since)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var src Source
		if err := rows.Scan(&src.Source, &src.Visitors); err != nil {
			rows.Close()
			return nil, err
		}
		out.Sources = append(out.Sources, src)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Последние визиты.
	rows, err = q.Query(ctx, `
		SELECT `+visitCols+`
		FROM invest_visits v JOIN invest_visitors iv ON iv.id = v.visitor_id
		WHERE v.started_at >= $1
		ORDER BY v.started_at DESC LIMIT 30`, out.Since)
	if err != nil {
		return nil, err
	}
	if out.Recent, err = scanVisits(rows); err != nil {
		return nil, err
	}
	return out, nil
}

// Module — HTTP-маршруты.
type Module struct {
	svc  *Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	// Без входа: сигнал со страницы invest.super-market.uz.
	r.Post("/public/invest/ping", m.ping)

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/invest/stats", m.stats)
		r.Get("/admin/invest/now", m.now)
	})
}

func (m *Module) ping(w http.ResponseWriter, r *http.Request) {
	var in PingInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	if err := m.svc.Ping(r.Context(), in, r.UserAgent()); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) stats(w http.ResponseWriter, r *http.Request) {
	st, err := m.svc.Stats(r.Context(), r.URL.Query().Get("period"))
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}

func (m *Module) now(w http.ResponseWriter, r *http.Request) {
	n, err := m.svc.OnlineNow(r.Context())
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]int{"now": n})
}
