// Package catalognorm — автонормализация общего каталога. Super Market сам:
//   - чистит названия: у еды и напитков без типа ИКПУ перед брендом
//     («Coca-Cola, 0,15 л»), у непищевых — короткий тип («Телевизор Samsung, …»),
//     без упаковки, вес в конце в одном виде; узбекское название — тоже;
//   - исправляет категорию (перенос в другой раздел — только если второе
//     мнение ИИ согласно);
//   - собирает группы вариаций (линейка → вес → вкус) и сразу подтверждает их;
//   - решает по товарам, которые предложили магазины: одобрить, дубль, отклонить.
//
// Очереди на ручную проверку нет: каждое изменение пишется в журнал
// «было → стало» (catalog_norm_changes), прогон можно откатить. Товары, у
// которых название или категорию правил человек (norm_locked), не трогаются.
// Ручной прогон можно запустить «только посмотреть» (dry_run) и применить
// потом; в режиме auto новые товары обрабатываются сами каждые несколько минут.
package catalognorm

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/ai"
	"github.com/sanedidi/super-market/backend/internal/catalog"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/variants"
)

// Sync — прогон и применение идут прямо в запросе (тесты).
var Sync bool

type Service struct {
	pool *pgxpool.Pool
	ai   *ai.Service
	cat  *catalog.Service
	vars *variants.Service
	log  *slog.Logger
	// Один прогон за раз.
	mu   sync.Mutex
	busy bool
}

func NewService(pool *pgxpool.Pool, aiSvc *ai.Service, cat *catalog.Service, vars *variants.Service, log *slog.Logger) *Service {
	return &Service{pool: pool, ai: aiSvc, cat: cat, vars: vars, log: log}
}

// ---------------------------------------------------------------- настройки

type Settings struct {
	Auto        bool `json:"auto"`
	Concurrency int  `json:"concurrency"`
	BatchSize   int  `json:"batch_size"`
	// Pending — товаров, которые ещё не прошли автонормализацию;
	// Suggestions — исправлений от магазинов ждут решения.
	Pending     int `json:"pending"`
	Suggestions int `json:"suggestions"`
	// Products — товаров, которые проходят автонормализацию.
	Products int `json:"products"`
	// Totals — что сделано за всё время (без откаченного).
	Totals Totals `json:"totals"`
}

// Totals — итоги применённых изменений за всё время.
type Totals struct {
	Names               int     `json:"names"`
	Categories          int     `json:"categories"`
	Moves               int     `json:"moves"`
	MovesKept           int     `json:"moves_kept"`
	Groups              int     `json:"groups"`
	InGroups            int     `json:"in_groups"`
	Approved            int     `json:"approved"`
	Rejected            int     `json:"rejected"`
	Duplicates          int     `json:"duplicates"`
	SuggestionsApproved int     `json:"suggestions_approved"`
	SuggestionsRejected int     `json:"suggestions_rejected"`
	AIRequests          int     `json:"ai_requests"`
	AICostUSD           float64 `json:"ai_cost_usd"`
	AICostUZS           float64 `json:"ai_cost_uzs"`
}

type SettingsInput struct {
	Auto        *bool `json:"auto"`
	Concurrency *int  `json:"concurrency"`
	BatchSize   *int  `json:"batch_size"`
}

func (s *Service) Settings(ctx context.Context) (Settings, error) {
	var st Settings
	err := s.pool.QueryRow(ctx, `SELECT auto, concurrency, batch_size FROM catalog_norm_settings WHERE id = 1`).
		Scan(&st.Auto, &st.Concurrency, &st.BatchSize)
	if errors.Is(err, pgx.ErrNoRows) {
		st = Settings{Concurrency: 4, BatchSize: 30}
		err = nil
	}
	if err != nil {
		return st, err
	}
	if err = s.pool.QueryRow(ctx, `SELECT count(*)::int FROM products p WHERE `+todoWhere).Scan(&st.Pending); err != nil {
		return st, err
	}
	if st.Suggestions, err = s.pendingSuggestions(ctx); err != nil {
		return st, err
	}
	if err = s.pool.QueryRow(ctx, `SELECT count(*)::int FROM products p WHERE `+scopeWhere).Scan(&st.Products); err != nil {
		return st, err
	}
	t := &st.Totals
	if err = s.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE kind = 'name')::int,
		       count(*) FILTER (WHERE kind = 'category')::int,
		       count(*) FILTER (WHERE kind = 'variant_group' AND detail ->> 'action' = 'create')::int,
		       COALESCE(sum(jsonb_array_length(detail -> 'items')) FILTER (WHERE kind = 'variant_group' AND detail ->> 'action' = 'create'), 0)::int,
		       count(*) FILTER (WHERE kind = 'moderation' AND new_value = 'approved')::int,
		       count(*) FILTER (WHERE kind = 'moderation' AND new_value = 'rejected' AND COALESCE(detail ->> 'duplicate_of', '') = '')::int,
		       count(*) FILTER (WHERE kind = 'moderation' AND COALESCE(detail ->> 'duplicate_of', '') <> '')::int,
		       count(*) FILTER (WHERE kind = 'suggestion' AND new_value = 'approved')::int,
		       count(*) FILTER (WHERE kind = 'suggestion' AND new_value = 'rejected')::int
		FROM catalog_norm_changes WHERE applied AND NOT reverted AND kind <> 'norm'`).
		Scan(&t.Names, &t.Categories, &t.Groups, &t.InGroups, &t.Approved, &t.Rejected, &t.Duplicates, &t.SuggestionsApproved, &t.SuggestionsRejected); err != nil {
		return st, err
	}
	if err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum((stats ->> 'moves')::int), 0)::int, COALESCE(sum((stats ->> 'moves_kept')::int), 0)::int
		FROM catalog_norm_runs WHERE applied AND status <> 'rolled_back'`).Scan(&t.Moves, &t.MovesKept); err != nil {
		return st, err
	}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, COALESCE(sum(cost) FILTER (WHERE currency = 'USD'), 0)::float8, COALESCE(sum(cost_uzs), 0)::float8
		FROM ai_usage WHERE kind = 'catalog_norm'`).Scan(&t.AIRequests, &t.AICostUSD, &t.AICostUZS)
	return st, err
}

// Section — раздел каталога для ручного запуска: сколько товаров пройдут.
type Section struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Products int    `json:"products"`
}

// Sections — разделы (корневые категории), где есть товары для автонормализации.
func (s *Service) Sections(ctx context.Context) ([]Section, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT r.id::text, loc(r.name, r.name_uz), count(p.id)::int
		FROM categories r
		JOIN categories c ON c.id = r.id OR c.parent_id = r.id
		JOIN products p ON p.category_id = c.id AND `+scopeWhere+`
		WHERE r.parent_id IS NULL AND r.is_active
		GROUP BY r.id, r.name, r.name_uz, r.sort
		ORDER BY r.sort, r.name`)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Section, error) {
		var x Section
		return x, r.Scan(&x.ID, &x.Name, &x.Products)
	})
	if out == nil {
		out = []Section{}
	}
	return out, err
}

func (s *Service) SaveSettings(ctx context.Context, in SettingsInput) (Settings, error) {
	if in.Concurrency != nil && (*in.Concurrency < 1 || *in.Concurrency > 16) {
		return Settings{}, apperr.Validation("concurrency: от 1 до 16").Uz("concurrency: 1 dan 16 gacha")
	}
	if in.BatchSize != nil && (*in.BatchSize < 5 || *in.BatchSize > 100) {
		return Settings{}, apperr.Validation("batch_size: от 5 до 100").Uz("batch_size: 5 dan 100 gacha")
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO catalog_norm_settings (id, auto, concurrency, batch_size) VALUES (1, COALESCE($1, false), COALESCE($2, 4), COALESCE($3, 30))
		ON CONFLICT (id) DO UPDATE SET auto = COALESCE($1, catalog_norm_settings.auto),
			concurrency = COALESCE($2, catalog_norm_settings.concurrency),
			batch_size = COALESCE($3, catalog_norm_settings.batch_size), updated_at = now()`,
		in.Auto, in.Concurrency, in.BatchSize); err != nil {
		return Settings{}, err
	}
	return s.Settings(ctx)
}

// ---------------------------------------------------------------- прогоны

// Stats — счётчики прогона.
type Stats struct {
	Total      int `json:"total"`     // товаров в прогоне
	Processed  int `json:"processed"` // разобрано
	Names      int `json:"names"`     // изменено названий
	NamesUz    int `json:"names_uz"`
	Categories int `json:"categories"` // изменено категорий
	// Moves — перенос в другой раздел подтверждён вторым мнением;
	// MovesKept — второе мнение не согласилось, категория осталась.
	Moves     int `json:"moves"`
	MovesKept int `json:"moves_kept"`
	Groups    int `json:"groups"` // новых групп вариаций
	Joined    int `json:"joined"` // товаров добавлено в существующие группы
	InGroups  int `json:"in_groups"`
	Approved  int `json:"approved"`
	Rejected  int `json:"rejected"`
	Duplicate int `json:"duplicates"`
	// Исправления карточек от магазинов.
	SuggestionsApproved int `json:"suggestions_approved"`
	SuggestionsRejected int `json:"suggestions_rejected"`
	Failed              int `json:"failed"` // пачек, на которых ИИ ответил ошибкой
	Input               int `json:"input_tokens"`
	Output              int `json:"output_tokens"`
}

type Run struct {
	ID           string     `json:"id"`
	Trigger      string     `json:"trigger"`
	SectionIDs   []string   `json:"section_ids"`
	Sections     []string   `json:"sections"`
	OnlyNew      bool       `json:"only_new"`
	DryRun       bool       `json:"dry_run"`
	Status       string     `json:"status"`
	Applied      bool       `json:"applied"`
	Stats        Stats      `json:"stats"`
	Error        string     `json:"error"`
	StartedAt    time.Time  `json:"started_at"`
	FinishedAt   *time.Time `json:"finished_at"`
	AppliedAt    *time.Time `json:"applied_at"`
	RolledBackAt *time.Time `json:"rolled_back_at"`
}

const runSelect = `
	SELECT r.id, r.trigger, r.section_ids::text[],
	       COALESCE((SELECT array_agg(loc(c.name, c.name_uz) ORDER BY c.sort, c.name) FROM categories c WHERE c.id = ANY (r.section_ids)), '{}'),
	       r.only_new, r.dry_run, r.status, r.applied, r.stats, r.error, r.started_at, r.finished_at, r.applied_at, r.rolled_back_at
	FROM catalog_norm_runs r`

func scanRun(row pgx.CollectableRow) (Run, error) {
	var r Run
	var stats []byte
	err := row.Scan(&r.ID, &r.Trigger, &r.SectionIDs, &r.Sections, &r.OnlyNew, &r.DryRun, &r.Status, &r.Applied, &stats, &r.Error,
		&r.StartedAt, &r.FinishedAt, &r.AppliedAt, &r.RolledBackAt)
	if err == nil && len(stats) > 0 {
		_ = json.Unmarshal(stats, &r.Stats)
	}
	return r, err
}

type RunList struct {
	Items []Run `json:"items"`
	Total int   `json:"total"`
}

// Runs — прогоны, новые сверху. Пустые автоматические (ничего не изменили)
// не показываются.
func (s *Service) Runs(ctx context.Context, trigger string, page httpx.Page) (RunList, error) {
	if trigger != "" && trigger != "manual" && trigger != "auto" {
		return RunList{}, apperr.Validation("trigger: manual или auto").Uz("trigger: manual yoki auto")
	}
	where := ` WHERE ($3 = '' OR r.trigger = $3) AND NOT (r.trigger = 'auto' AND r.status = 'done' AND COALESCE((r.stats ->> 'processed')::int, 0) = 0
		AND COALESCE((r.stats ->> 'suggestions_approved')::int, 0) + COALESCE((r.stats ->> 'suggestions_rejected')::int, 0) = 0)`
	var out RunList
	if err := s.pool.QueryRow(ctx, `SELECT count(*)::int FROM catalog_norm_runs r`+strings.ReplaceAll(where, "$3", "$1"), trigger).Scan(&out.Total); err != nil {
		return out, err
	}
	rows, err := s.pool.Query(ctx, runSelect+where+` ORDER BY r.started_at DESC LIMIT $1 OFFSET $2`, page.Limit, page.Offset, trigger)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, scanRun)
	if out.Items == nil {
		out.Items = []Run{}
	}
	return out, err
}

func errNoRun() error {
	return apperr.NotFound("прогон не найден").Uz("ishga tushirish topilmadi")
}

func (s *Service) Run(ctx context.Context, id string) (Run, error) {
	if !httpx.IsUUID(id) {
		return Run{}, errNoRun()
	}
	rows, err := s.pool.Query(ctx, runSelect+` WHERE r.id = $1`, id)
	if err != nil {
		return Run{}, err
	}
	r, err := pgx.CollectExactlyOneRow(rows, scanRun)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, errNoRun()
	}
	return r, err
}

// ---------------------------------------------------------------- журнал

// Change — строка журнала «было → стало».
type Change struct {
	ID          int64           `json:"id"`
	ProductID   *string         `json:"product_id"`
	ProductName string          `json:"product_name"`
	Image       *string         `json:"image"`
	Kind        string          `json:"kind"`
	Old         string          `json:"old"`
	New         string          `json:"new"`
	Detail      json.RawMessage `json:"detail"`
	Applied     bool            `json:"applied"`
	Reverted    bool            `json:"reverted"`
}

type ChangeList struct {
	Items  []Change       `json:"items"`
	Total  int            `json:"total"`
	Counts map[string]int `json:"counts"`
}

// Changes — журнал прогона. kind: name, name_uz, category, variant_group,
// moderation (по умолчанию — все, кроме служебного norm). Для категорий old и
// new — пути «Раздел / Подкатегория». q — поиск по названию товара.
func (s *Service) Changes(ctx context.Context, runID, kind, q string, page httpx.Page) (ChangeList, error) {
	if _, err := s.Run(ctx, runID); err != nil {
		return ChangeList{}, err
	}
	switch kind {
	case "", "name", "name_uz", "category", "variant_group", "moderation", "suggestion":
	default:
		return ChangeList{}, apperr.Validation("kind: name, name_uz, category, variant_group, moderation или suggestion").
			Uz("kind: name, name_uz, category, variant_group, moderation yoki suggestion")
	}
	out := ChangeList{Counts: map[string]int{}}
	rows, err := s.pool.Query(ctx, `SELECT kind, count(*)::int FROM catalog_norm_changes WHERE run_id = $1 AND kind <> 'norm' GROUP BY kind`, runID)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var k string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			rows.Close()
			return out, err
		}
		out.Counts[k] = n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	const where = `
		FROM catalog_norm_changes ch LEFT JOIN products p ON p.id = ch.product_id
		WHERE ch.run_id = $1 AND ch.kind <> 'norm' AND ($2 = '' OR ch.kind = $2)
		  AND ($3 = '' OR lower(COALESCE(p.name, ch.detail ->> 'name', '')) LIKE '%' || lower($3) || '%'
		       OR lower(ch.old_value) LIKE '%' || lower($3) || '%' OR lower(ch.new_value) LIKE '%' || lower($3) || '%')`
	if err := s.pool.QueryRow(ctx, `SELECT count(*)::int`+where, runID, kind, q).Scan(&out.Total); err != nil {
		return out, err
	}
	rows, err = s.pool.Query(ctx, `
		SELECT ch.id, ch.product_id::text, COALESCE(loc(p.name, p.name_uz), ch.detail ->> 'name', ''), p.images[1], ch.kind,
		       CASE WHEN ch.kind = 'category' THEN COALESCE((SELECT COALESCE(pc.name || ' / ', '') || c.name FROM categories c
		            LEFT JOIN categories pc ON pc.id = c.parent_id WHERE c.id::text = ch.old_value), ch.old_value) ELSE ch.old_value END,
		       CASE WHEN ch.kind = 'category' THEN COALESCE((SELECT COALESCE(pc.name || ' / ', '') || c.name FROM categories c
		            LEFT JOIN categories pc ON pc.id = c.parent_id WHERE c.id::text = ch.new_value), ch.new_value) ELSE ch.new_value END,
		       ch.detail, ch.applied, ch.reverted`+where+`
		ORDER BY ch.id LIMIT $4 OFFSET $5`, runID, kind, q, page.Limit, page.Offset)
	if err != nil {
		return out, err
	}
	out.Items, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Change, error) {
		var c Change
		var detail []byte
		err := r.Scan(&c.ID, &c.ProductID, &c.ProductName, &c.Image, &c.Kind, &c.Old, &c.New, &detail, &c.Applied, &c.Reverted)
		c.Detail = detail
		return c, err
	})
	if out.Items == nil {
		out.Items = []Change{}
	}
	return out, err
}
