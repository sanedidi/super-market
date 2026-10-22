// Package appversions — версии приложений в сторах: супер-админ задаёт
// последнюю версию, «Что нового» и ссылку; приложение при запуске спрашивает,
// есть ли обновление (Figma «Обновление приложения», ОБ1 — шторка «Есть
// обновление» с «Обновить» / «Позже»).
package appversions

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Приложения в сторах: покупатель, магазин, курьер, агент (дистрибьютор).
var Apps = []string{"client", "store", "courier", "agent"}

// Platforms — iOS и Android выходят в сторы в разное время, поэтому отдельно.
var Platforms = []string{"ios", "android"}

var versionRe = regexp.MustCompile(`^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$`)

// Version — строка таблицы для супер-админа.
type Version struct {
	App       string     `json:"app"`
	Platform  string     `json:"platform"`
	Latest    string     `json:"latest"`
	StoreURL  string     `json:"store_url"`
	NotesRU   string     `json:"notes_ru"`
	NotesUZ   string     `json:"notes_uz"`
	UpdatedAt *time.Time `json:"updated_at"`
}

// Check — ответ приложению: update — версия приложения старее последней.
type Check struct {
	Update   bool     `json:"update"`
	Latest   string   `json:"latest"`
	StoreURL string   `json:"store_url"`
	Notes    []string `json:"notes"`
}

type Input struct {
	Latest   *string `json:"latest"`
	StoreURL *string `json:"store_url"`
	NotesRU  *string `json:"notes_ru"`
	NotesUZ  *string `json:"notes_uz"`
}

type Service struct{ pool *pgxpool.Pool }

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

func known(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func checkKey(app, platform string) error {
	if !known(Apps, app) {
		return apperr.Validation("app: client, store, courier или agent").Uz("app: client, store, courier yoki agent")
	}
	if !known(Platforms, platform) {
		return apperr.Validation("platform: ios или android").Uz("platform: ios yoki android")
	}
	return nil
}

// Compare — сравнение версий «0.9.2» и «0.10.0» по числам: -1, 0, 1.
// Недостающие части — нули («1.2» = «1.2.0»); сборка «+23» не учитывается.
func Compare(a, b string) int {
	pa, pb := parts(a), parts(b)
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func parts(v string) []int {
	v = strings.TrimSpace(strings.SplitN(v, "+", 2)[0])
	var out []int
	for _, s := range strings.Split(v, ".") {
		n, _ := strconv.Atoi(s)
		out = append(out, n)
	}
	return out
}

// List — все приложения и платформы; ещё не заданные — пустые строки.
func (s *Service) List(ctx context.Context) ([]Version, error) {
	rows, err := s.pool.Query(ctx, `SELECT app, platform, latest, store_url, notes_ru, notes_uz, updated_at FROM app_versions`)
	if err != nil {
		return nil, err
	}
	saved, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Version])
	if err != nil {
		return nil, err
	}
	by := map[string]Version{}
	for _, v := range saved {
		by[v.App+"/"+v.Platform] = v
	}
	out := make([]Version, 0, len(Apps)*len(Platforms))
	for _, a := range Apps {
		for _, p := range Platforms {
			v, ok := by[a+"/"+p]
			if !ok {
				v = Version{App: a, Platform: p}
			}
			out = append(out, v)
		}
	}
	return out, nil
}

// Save — супер-админ вписал версию из стора (поля без ключа не меняются).
func (s *Service) Save(ctx context.Context, app, platform string, in Input) (Version, error) {
	if err := checkKey(app, platform); err != nil {
		return Version{}, err
	}
	trim := func(p *string) *string {
		if p == nil {
			return nil
		}
		v := strings.TrimSpace(*p)
		return &v
	}
	in.Latest, in.StoreURL, in.NotesRU, in.NotesUZ = trim(in.Latest), trim(in.StoreURL), trim(in.NotesRU), trim(in.NotesUZ)
	if in.Latest != nil && *in.Latest != "" && !versionRe.MatchString(*in.Latest) {
		return Version{}, apperr.Validation("latest: версия вида 0.9.2").Uz("latest: 0.9.2 koʻrinishidagi versiya")
	}
	if u := in.StoreURL; u != nil && *u != "" && (!strings.HasPrefix(*u, "https://") || len(*u) > 500) {
		return Version{}, apperr.Validation("store_url: ссылка на App Store или Google Play (https://…)").Uz("store_url: App Store yoki Google Play havolasi (https://…)")
	}
	for _, n := range []*string{in.NotesRU, in.NotesUZ} {
		if n != nil && len(*n) > 2000 {
			return Version{}, apperr.Validation("notes: «Что нового» — до 2000 символов").Uz("notes: «Yangiliklar» — 2000 belgigacha")
		}
	}
	_, err := s.pool.Exec(ctx, `
		INSERT INTO app_versions (app, platform, latest, store_url, notes_ru, notes_uz)
		VALUES ($1, $2, COALESCE($3, ''), COALESCE($4, ''), COALESCE($5, ''), COALESCE($6, ''))
		ON CONFLICT (app, platform) DO UPDATE SET
			latest = COALESCE($3, app_versions.latest), store_url = COALESCE($4, app_versions.store_url),
			notes_ru = COALESCE($5, app_versions.notes_ru), notes_uz = COALESCE($6, app_versions.notes_uz),
			updated_at = now()`, app, platform, in.Latest, in.StoreURL, in.NotesRU, in.NotesUZ)
	if err != nil {
		return Version{}, err
	}
	var v Version
	err = s.pool.QueryRow(ctx, `SELECT app, platform, latest, store_url, notes_ru, notes_uz, updated_at FROM app_versions WHERE app = $1 AND platform = $2`,
		app, platform).Scan(&v.App, &v.Platform, &v.Latest, &v.StoreURL, &v.NotesRU, &v.NotesUZ, &v.UpdatedAt)
	return v, err
}

// Check — есть ли обновление для приложения этой версии. Ничего не задано или
// версия свежая — update: false.
func (s *Service) Check(ctx context.Context, app, platform, version, lang string) (Check, error) {
	if err := checkKey(app, platform); err != nil {
		return Check{}, err
	}
	version = strings.TrimSpace(version)
	if !versionRe.MatchString(strings.SplitN(version, "+", 2)[0]) {
		return Check{}, apperr.Validation("version: версия приложения вида 0.9.2").Uz("version: 0.9.2 koʻrinishidagi ilova versiyasi")
	}
	var v Version
	err := s.pool.QueryRow(ctx, `SELECT latest, store_url, notes_ru, notes_uz FROM app_versions WHERE app = $1 AND platform = $2`,
		app, platform).Scan(&v.Latest, &v.StoreURL, &v.NotesRU, &v.NotesUZ)
	if errors.Is(err, pgx.ErrNoRows) {
		return Check{Notes: []string{}}, nil
	}
	if err != nil {
		return Check{}, err
	}
	out := Check{Latest: v.Latest, StoreURL: v.StoreURL, Notes: []string{}}
	// Без ссылки обновиться некуда — шторку не показываем.
	out.Update = v.Latest != "" && v.StoreURL != "" && Compare(version, v.Latest) < 0
	for _, l := range strings.Split(i18n.Pick(lang, v.NotesRU, v.NotesUZ), "\n") {
		if l = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(l), "•-*")); l != "" {
			out.Notes = append(out.Notes, l)
		}
	}
	return out, nil
}

type Module struct {
	svc  *Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	// Приложения спрашивают при запуске — и до входа, поэтому без токена.
	r.Get("/public/app-version", m.check)

	r.Route("/admin/app-versions", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/", m.list)
		r.Put("/{app}/{platform}", m.save)
	})
}

func (m *Module) check(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Check, error) {
		return m.svc.Check(r.Context(), q.Get("app"), q.Get("platform"), q.Get("version"), i18n.FromRequest(r))
	})
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Version], error) {
		items, err := m.svc.List(r.Context())
		return httpx.List[Version]{Items: items}, err
	})
}

func (m *Module) save(w http.ResponseWriter, r *http.Request) {
	var in Input
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Version, error) {
		return m.svc.Save(r.Context(), chi.URLParam(r, "app"), chi.URLParam(r, "platform"), in)
	})
}
