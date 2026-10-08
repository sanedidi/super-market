// Package i18nadmin — узбекские переводы данных каталога для супер-админа:
// сколько записей ещё без перевода и массовый автоперевод через ИИ-сервис
// (чтобы заполнить name_uz и т.п. у уже существующих данных).
package i18nadmin

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// field — русская колонка и колонка её перевода.
type field struct{ src, dst string }

// entity — что переводим. Имена таблиц и колонок — только отсюда.
type entity struct {
	name   string
	fields []field
}

var entities = []entity{
	{name: "categories", fields: []field{{"name", "name_uz"}}},
	{name: "units", fields: []field{{"name", "name_uz"}, {"short_name", "short_name_uz"}}},
	{name: "colors", fields: []field{{"name", "name_uz"}}},
	{name: "products", fields: []field{{"name", "name_uz"}, {"description", "description_uz"}}},
}

// missing — условие «у записи есть поле без перевода» (русский текст есть,
// узбекского нет).
func (e entity) missing() string {
	parts := make([]string, len(e.fields))
	for i, f := range e.fields {
		parts[i] = fmt.Sprintf("(btrim(%s) = '' AND btrim(%s) <> '')", f.dst, f.src)
	}
	return "(" + strings.Join(parts, " OR ") + ")"
}

func entityFor(name string) (entity, error) {
	for _, e := range entities {
		if e.name == name {
			return e, nil
		}
	}
	return entity{}, apperr.Validation("entity: categories, units, colors или products").
		Uz("entity: categories, units, colors yoki products")
}

// Пачка для модели — как у POST /translate.
const (
	batchTexts = 50
	batchChars = 4000
	// Лимит записей за один запрос.
	defaultLimit = 50
	maxLimit     = 200
)

// Budget — сколько времени запрос может переводить: HTTP-сервер ждёт ответа
// 30 с, поэтому новые пачки после половины бюджета не начинаются, а
// недоделанное остаётся на следующий вызов (remaining > 0).
var Budget = 27 * time.Second

type Service struct {
	pool *pgxpool.Pool
	ai   *ai.Service
}

func NewService(pool *pgxpool.Pool, aiSvc *ai.Service) *Service {
	return &Service{pool: pool, ai: aiSvc}
}

type Stat struct {
	Entity  string `json:"entity"`
	Total   int    `json:"total"`
	Missing int    `json:"missing"`
}

type Stats struct {
	Items []Stat `json:"items"`
}

// Stats — сколько записей всего и сколько без узбекского перевода.
func (s *Service) Stats(ctx context.Context) (Stats, error) {
	out := Stats{Items: []Stat{}}
	for _, e := range entities {
		st := Stat{Entity: e.name}
		if err := s.pool.QueryRow(ctx, fmt.Sprintf(`SELECT count(*)::int, (count(*) FILTER (WHERE %s))::int FROM %s`,
			e.missing(), e.name)).Scan(&st.Total, &st.Missing); err != nil {
			return out, err
		}
		out.Items = append(out.Items, st)
	}
	return out, nil
}

func (s *Service) remaining(ctx context.Context, e entity) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, fmt.Sprintf(`SELECT count(*)::int FROM %s WHERE %s`, e.name, e.missing())).Scan(&n)
	return n, err
}

type TranslateInput struct {
	Entity string `json:"entity"`
	Limit  int    `json:"limit"`
}

type TranslateResult struct {
	// Translated — сколько записей получили перевод (хотя бы одного поля).
	Translated int `json:"translated"`
	// Remaining — сколько записей ещё без перевода.
	Remaining int `json:"remaining"`
}

// row — запись без перевода: id, русские тексты и текущие переводы.
type row struct {
	id  string
	src []string
	dst []string
}

// job — один текст для перевода: запись и номер поля.
type job struct {
	row, field int
	text       string
}

// TranslateMissing переводит на узбекский до limit записей без перевода.
// Заполняются только пустые поля, поэтому повтор безопасен.
func (s *Service) TranslateMissing(ctx context.Context, in TranslateInput) (TranslateResult, error) {
	var out TranslateResult
	e, err := entityFor(strings.TrimSpace(in.Entity))
	if err != nil {
		return out, err
	}
	limit := in.Limit
	if limit == 0 {
		limit = defaultLimit
	}
	if limit < 1 || limit > maxLimit {
		return out, apperr.Validation(fmt.Sprintf("limit: от 1 до %d", maxLimit)).Uz(fmt.Sprintf("limit: 1 dan %d gacha", maxLimit))
	}
	start := time.Now()
	cols := make([]string, 0, 2*len(e.fields))
	for _, f := range e.fields {
		cols = append(cols, f.src, f.dst)
	}
	rs, err := s.pool.Query(ctx, fmt.Sprintf(`SELECT id::text, %s FROM %s WHERE %s ORDER BY created_at, id LIMIT $1`,
		strings.Join(cols, ", "), e.name, e.missing()), limit)
	if err != nil {
		return out, err
	}
	rows, err := pgx.CollectRows(rs, func(r pgx.CollectableRow) (row, error) {
		vals := make([]string, len(cols))
		dst := make([]any, 0, len(cols)+1)
		var x row
		dst = append(dst, &x.id)
		for i := range vals {
			dst = append(dst, &vals[i])
		}
		if err := r.Scan(dst...); err != nil {
			return x, err
		}
		for i := 0; i < len(vals); i += 2 {
			x.src = append(x.src, vals[i])
			x.dst = append(x.dst, vals[i+1])
		}
		return x, nil
	})
	if err != nil {
		return out, err
	}

	var jobs []job
	for ri, r := range rows {
		for fi := range e.fields {
			if strings.TrimSpace(r.dst[fi]) == "" && strings.TrimSpace(r.src[fi]) != "" {
				jobs = append(jobs, job{row: ri, field: fi, text: r.src[fi]})
			}
		}
	}
	if len(jobs) == 0 {
		return out, nil
	}
	conn, err := s.ai.Conn(ctx)
	if err != nil {
		return out, err
	}

	done := map[int]bool{}
	var firstErr error
	for _, batch := range batches(jobs) {
		// Новую пачку начинаем, только если до конца бюджета ещё далеко.
		left := Budget - time.Since(start)
		if left < Budget/2 {
			break
		}
		texts := make([]string, len(batch))
		for i, j := range batch {
			texts[i] = j.text
		}
		bctx, cancel := context.WithTimeout(ctx, left)
		res, usage, err := conn.Translate(bctx, texts, i18n.UZ)
		cancel()
		if usage.Input+usage.Output > 0 || err == nil {
			_ = s.ai.Record(context.WithoutCancel(ctx), ai.UsageRecord{Kind: "translate", Provider: conn.Provider,
				Model: conn.Model, Usage: usage, OK: err == nil})
		}
		if err != nil {
			firstErr = err
			break
		}
		// Переводы пачки — по записям.
		got := map[int][]string{}
		for i, j := range batch {
			if strings.TrimSpace(res[i]) == "" {
				continue
			}
			if got[j.row] == nil {
				got[j.row] = make([]string, len(e.fields))
			}
			got[j.row][j.field] = res[i]
		}
		for ri, vals := range got {
			ok, err := s.save(ctx, e, rows[ri].id, vals)
			if err != nil {
				return out, err
			}
			if ok {
				done[ri] = true
			}
		}
	}
	out.Translated = len(done)
	if firstErr != nil && out.Translated == 0 {
		return out, ai.AsAppErr(firstErr)
	}
	out.Remaining, err = s.remaining(ctx, e)
	return out, err
}

// save записывает переводы в пустые поля записи (пустое значение — не трогать).
func (s *Service) save(ctx context.Context, e entity, id string, vals []string) (bool, error) {
	sets := make([]string, len(e.fields))
	args := []any{id}
	for i, f := range e.fields {
		args = append(args, vals[i])
		n := len(args)
		sets[i] = fmt.Sprintf("%[1]s = CASE WHEN btrim(%[1]s) = '' AND $%[2]d <> '' THEN $%[2]d ELSE %[1]s END", f.dst, n)
	}
	tag, err := s.pool.Exec(ctx, fmt.Sprintf(`UPDATE %s SET %s WHERE id = $1`, e.name, strings.Join(sets, ", ")), args...)
	return tag.RowsAffected() > 0, err
}

// batches делит тексты на пачки: не больше batchTexts строк и batchChars
// символов. Текст длиннее batchChars идёт отдельной пачкой.
func batches(jobs []job) [][]job {
	var out [][]job
	var cur []job
	chars := 0
	for _, j := range jobs {
		n := len([]rune(j.text))
		if len(cur) > 0 && (len(cur) == batchTexts || chars+n > batchChars) {
			out = append(out, cur)
			cur, chars = nil, 0
		}
		cur = append(cur, j)
		chars += n
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

// ------------------------------------------------------------------ HTTP

type Module struct {
	svc  *Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/i18n/stats", m.stats)
		r.Post("/admin/i18n/translate-missing", m.translateMissing)
	})
}

func (m *Module) stats(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Stats, error) { return m.svc.Stats(r.Context()) })
}

func (m *Module) translateMissing(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in TranslateInput) (TranslateResult, error) {
		return m.svc.TranslateMissing(r.Context(), in)
	})
}
