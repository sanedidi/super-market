package ai

// Фото из сети — страница супер-админа (Figma ФС1 «список», ФС2 «карточка замены»).

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// WebSummary — счётчики ФС1.
type WebSummary struct {
	Configured bool `json:"configured"` // Gemini подключён
	Enabled    bool `json:"enabled"`    // проверка включена
	HasSerper  bool `json:"has_serper"`
	// Total — товары общего каталога с фото; Checked — проверено.
	Total   int `json:"total"`
	Checked int `json:"checked"`
	// Bad — плохих фото; Replaced (по источнику) — заменено.
	Bad            int `json:"bad"`
	Replaced       int `json:"replaced"`
	ReplacedOFF    int `json:"replaced_off"`
	ReplacedGoogle int `json:"replaced_google"`
	ReplacedOwn    int `json:"replaced_own"`
	NotFound       int `json:"not_found"`
	Pending        int `json:"pending"`
	Reverted       int `json:"reverted"`
	Failed         int `json:"failed"`
	// Queued — ещё не проверено (в очереди и не взятые в очередь).
	Queued int `json:"queued"`
	// PerHour — сколько фото проверено за последний час; EtaHours — сколько ещё (nil — неизвестно).
	PerHour  int      `json:"per_hour"`
	EtaHours *float64 `json:"eta_hours"`
	// Расход за месяц, USD.
	MonthCostUSD   float64 `json:"month_cost_usd"`
	MonthSearchUSD float64 `json:"month_search_usd"`
	MonthGeminiUSD float64 `json:"month_gemini_usd"`
	LimitUSD       float64 `json:"limit_usd"`
	// Paused — дошли до лимита месяца.
	Paused bool `json:"paused"`
	// Сначала — товары, которые есть в магазинах: всего с фото, проверено, ещё в очереди.
	StoresTotal   int `json:"stores_total"`
	StoresChecked int `json:"stores_checked"`
	StoresQueued  int `json:"stores_queued"`
	// Остальной каталог: одобрен ли и сколько в нём ещё не проверено.
	Rest       bool `json:"rest"`
	RestQueued int  `json:"rest_queued"`
	// AvgCostUSD — средний расход на одно проверенное фото (для оценки остального каталога).
	AvgCostUSD float64 `json:"avg_cost_usd"`
}

// WebSummary — счётчики страницы «Фото из сети».
func (s *PhotoService) WebSummary(ctx context.Context) (WebSummary, error) {
	var out WebSummary
	r, err := s.load(ctx)
	if err != nil {
		return out, err
	}
	w, err := s.webLoad(ctx)
	if err != nil {
		return out, err
	}
	out.Configured, out.Enabled, out.HasSerper, out.LimitUSD = r.Configured, w.Check, w.HasSerper, w.LimitUSD
	err = s.ai.pool.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM products WHERE network_id IS NULL AND is_active AND cardinality(images) > 0)::int,
		       count(*) FILTER (WHERE reason <> '')::int,
		       count(*) FILTER (WHERE reason NOT IN ('', 'ok'))::int,
		       count(*) FILTER (WHERE status = 'replaced')::int,
		       count(*) FILTER (WHERE status = 'replaced' AND found_source = 'off')::int,
		       count(*) FILTER (WHERE status = 'replaced' AND found_source = 'google')::int,
		       count(*) FILTER (WHERE status = 'replaced' AND found_source = 'own')::int,
		       count(*) FILTER (WHERE status = 'not_found')::int,
		       count(*) FILTER (WHERE status = 'pending')::int,
		       count(*) FILTER (WHERE status = 'reverted')::int,
		       count(*) FILTER (WHERE status = 'failed')::int,
		       count(*) FILTER (WHERE reason <> '' AND finished_at > now() - interval '1 hour')::int
		FROM photo_web_jobs`).Scan(&out.Total, &out.Checked, &out.Bad, &out.Replaced, &out.ReplacedOFF, &out.ReplacedGoogle, &out.ReplacedOwn,
		&out.NotFound, &out.Pending, &out.Reverted, &out.Failed, &out.PerHour)
	if err != nil {
		return out, err
	}
	out.Queued = max(out.Total-out.Checked, 0)
	out.Rest = w.Rest
	var costSum float64
	err = s.ai.pool.QueryRow(ctx, `
		WITH st AS (SELECT DISTINCT product_id FROM store_products)
		SELECT count(*)::int,
		       count(*) FILTER (WHERE j.reason <> '')::int,
		       COALESCE((SELECT sum(cost_usd) FROM photo_web_jobs WHERE reason <> ''), 0)::float8
		FROM products p JOIN st ON st.product_id = p.id
		LEFT JOIN photo_web_jobs j ON j.product_id = p.id
		WHERE p.network_id IS NULL AND p.is_active AND cardinality(p.images) > 0`).Scan(&out.StoresTotal, &out.StoresChecked, &costSum)
	if err != nil {
		return out, err
	}
	out.StoresQueued = max(out.StoresTotal-out.StoresChecked, 0)
	out.RestQueued = max(out.Queued-out.StoresQueued, 0)
	if out.Checked > 0 {
		out.AvgCostUSD = costSum / float64(out.Checked)
	}
	// Пока остальной каталог не одобрен, ждать осталось только товары магазинов.
	if !out.Rest {
		out.Queued = out.StoresQueued
	}
	if out.Queued == 0 {
		z := 0.0
		out.EtaHours = &z
	} else if out.PerHour > 0 {
		h := float64(out.Queued) / float64(out.PerHour)
		out.EtaHours = &h
	}
	err = s.ai.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(cost) FILTER (WHERE kind = 'web_search'), 0)::float8, COALESCE(sum(cost) FILTER (WHERE kind = 'photo_web'), 0)::float8
		FROM ai_usage WHERE kind IN ('photo_web', 'web_search') AND currency = 'USD' AND at >= `+monthStartSQL).
		Scan(&out.MonthSearchUSD, &out.MonthGeminiUSD)
	out.MonthCostUSD = out.MonthSearchUSD + out.MonthGeminiUSD
	out.Paused = out.MonthCostUSD >= out.LimitUSD
	return out, err
}

// WebJobsFilter — список: status bad (по умолчанию — все плохие), replaced,
// not_found, queued, pending, reverted, failed, ok, all; q — название или штрихкод.
type WebJobsFilter struct {
	Status string
	Query  string
	Limit  int
	Offset int
}

// WebJobRow — строка списка и карточка замены.
type WebJobRow struct {
	ID        string `json:"id"`
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Barcode   string `json:"barcode"`
	// Origin — откуда товар: ikpu (каталог ИКПУ), store (от магазина), catalog.
	Origin      string         `json:"origin"`
	Category    string         `json:"category"`
	Status      string         `json:"status"`
	Reason      string         `json:"reason"`
	ReasonText  string         `json:"reason_text"`
	OldImage    string         `json:"old_image"`
	FoundSource string         `json:"found_source"`
	FoundImage  string         `json:"found_image"`
	FoundPage   string         `json:"found_page"`
	ResultImage string         `json:"result_image"`
	Candidates  []webCandidate `json:"candidates"`
	Verdict     map[string]any `json:"verdict"`
	// Placed — готовое фото сейчас стоит у товара.
	Placed      bool       `json:"placed"`
	Attempts    int        `json:"attempts"`
	MaxAttempts int        `json:"max_attempts"`
	NextAt      *time.Time `json:"next_at"`
	Error       string     `json:"error"`
	CostUSD     float64    `json:"cost_usd"`
	Model       string     `json:"model"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	FinishedAt  *time.Time `json:"finished_at"`
	foundKey    string
	resultKey   string
}

type WebJobsPage struct {
	Items []WebJobRow `json:"items"`
	Total int         `json:"total"`
}

const webJobSelect = `
	SELECT j.id::text, j.product_id::text, p.name,
	       COALESCE((SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), ''),
	       CASE WHEN p.attributes ->> 'source' LIKE 'tasnif%' THEN 'ikpu' WHEN p.proposed_by IS NOT NULL THEN 'store' ELSE 'catalog' END,
	       COALESCE(c.name, ''),
	       j.status, j.reason, j.reason_text, j.old_image, j.found_source, j.found_url, j.found_page, j.result, j.candidates, j.verdict,
	       j.result <> '' AND EXISTS (SELECT 1 FROM unnest(p.images) u WHERE u LIKE '%/' || j.result),
	       j.attempts, CASE WHEN j.status = 'not_found' AND j.attempts < ` + "3" + ` THEN j.next_at END, j.error, j.cost_usd::float8, j.model,
	       j.created_at, j.updated_at, j.finished_at
	FROM photo_web_jobs j
	JOIN products p ON p.id = j.product_id
	LEFT JOIN categories c ON c.id = p.category_id`

func scanWebJob(r pgx.CollectableRow) (WebJobRow, error) {
	var j WebJobRow
	var cands, verdict []byte
	err := r.Scan(&j.ID, &j.ProductID, &j.Name, &j.Barcode, &j.Origin, &j.Category, &j.Status, &j.Reason, &j.ReasonText, &j.OldImage,
		&j.FoundSource, &j.foundKey, &j.FoundPage, &j.resultKey, &cands, &verdict, &j.Placed, &j.Attempts, &j.NextAt, &j.Error, &j.CostUSD, &j.Model,
		&j.CreatedAt, &j.UpdatedAt, &j.FinishedAt)
	if err != nil {
		return j, err
	}
	j.MaxAttempts = WebMaxAttempts
	j.Candidates = []webCandidate{}
	_ = json.Unmarshal(cands, &j.Candidates)
	j.Verdict = map[string]any{}
	_ = json.Unmarshal(verdict, &j.Verdict)
	return j, nil
}

// WebJobURLs — ссылки на фото из хранилища для ответа.
func (s *PhotoService) WebJobURLs(r *http.Request, j WebJobRow) WebJobRow {
	u := func(v string) string {
		if v == "" {
			return ""
		}
		if key, ok := media.KeyFromURL(v); ok {
			if b := media.BaseOf(j.OldImage); b != "" {
				return s.media.URLWithBase(b, key)
			}
			return s.media.URL(r, key)
		}
		return v
	}
	j.FoundImage = u(j.foundKey)
	j.ResultImage = u(j.resultKey)
	for i := range j.Candidates {
		j.Candidates[i].URL = u(j.Candidates[i].URL)
	}
	return j
}

// WebJobs — список «Фото из сети», свежие сверху.
func (s *PhotoService) WebJobs(ctx context.Context, f WebJobsFilter) (WebJobsPage, error) {
	out := WebJobsPage{Items: []WebJobRow{}}
	where := []string{}
	args := []any{}
	arg := func(v any) string {
		args = append(args, v)
		return "$" + strconv.Itoa(len(args))
	}
	switch f.Status {
	case "", "bad":
		where = append(where, "j.reason NOT IN ('', 'ok')")
	case "queued":
		where = append(where, "j.status IN ('queued', 'processing')")
	case WebReplaced, WebNotFound, WebPending, WebReverted, WebFailed, WebOK:
		where = append(where, "j.status = "+arg(f.Status))
	case "all":
	default:
		return out, apperr.Validation("status: bad, replaced, not_found, queued, pending, reverted, failed, ok или all").
			Uz("status: bad, replaced, not_found, queued, pending, reverted, failed, ok yoki all")
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		if len([]rune(q)) > 100 {
			return out, apperr.Validation("q: не больше 100 символов").Uz("q: 100 belgidan oshmasin")
		}
		p := arg("%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q) + "%")
		where = append(where, "(p.name ILIKE "+p+" OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = p.id AND pb.barcode LIKE "+p+"))")
	}
	cond := ""
	if len(where) > 0 {
		cond = " WHERE " + strings.Join(where, " AND ")
	}
	if err := s.ai.pool.QueryRow(ctx, `SELECT count(*)::int FROM photo_web_jobs j JOIN products p ON p.id = j.product_id`+cond, args...).Scan(&out.Total); err != nil {
		return out, err
	}
	limit := f.Limit
	if limit <= 0 {
		limit = 50
	}
	items, err := collect(ctx, s.ai.pool, webJobSelect+cond+` ORDER BY j.updated_at DESC, j.id LIMIT `+arg(limit)+` OFFSET `+arg(max(f.Offset, 0)), scanWebJob, args...)
	out.Items = items
	return out, err
}

// WebJob — карточка замены.
func (s *PhotoService) WebJob(ctx context.Context, id string) (WebJobRow, error) {
	items, err := collect(ctx, s.ai.pool, webJobSelect+` WHERE j.id = $1`, scanWebJob, id)
	if err != nil {
		return WebJobRow{}, err
	}
	if len(items) == 0 {
		return WebJobRow{}, apperr.NotFound("задание не найдено").Uz("vazifa topilmadi")
	}
	return items[0], nil
}

var errWebBusy = apperr.Conflict("photo_web_busy", "Фото сейчас ищется — подождите минуту").Uz("Rasm hozir qidirilmoqda — bir daqiqa kuting")

// webLock — задание под блокировкой (не в работе).
func webLock(ctx context.Context, tx pgx.Tx, id string) (status, productID, old, result string, err error) {
	err = tx.QueryRow(ctx, `SELECT status, product_id::text, old_image, result FROM photo_web_jobs WHERE id = $1 FOR UPDATE`, id).
		Scan(&status, &productID, &old, &result)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", "", "", apperr.NotFound("задание не найдено").Uz("vazifa topilmadi")
	}
	if err == nil && status == WebProcessing {
		err = errWebBusy
	}
	return
}

// RevertWeb — «Вернуть старое»: старое фото на место нового. Больше этот товар сами не трогаем.
func (s *PhotoService) RevertWeb(ctx context.Context, id string) (WebJobRow, error) {
	err := s.webTx(ctx, func(tx pgx.Tx) error {
		_, productID, old, result, err := webLock(ctx, tx, id)
		if err != nil {
			return err
		}
		if old == "" {
			return apperr.Conflict("photo_web_no_old", "Старого фото нет").Uz("Eski rasm yoʻq")
		}
		var images []string
		if err := tx.QueryRow(ctx, `SELECT images FROM products WHERE id = $1 FOR UPDATE`, productID).Scan(&images); err != nil {
			return err
		}
		out := make([]string, 0, len(images)+1)
		put := false
		for _, u := range images {
			switch {
			case result != "" && strings.HasSuffix(u, "/"+result) && !put:
				out = append(out, old)
				put = true
			case u == old:
			default:
				out = append(out, u)
			}
		}
		if !put {
			out = append([]string{old}, out...)
		}
		if _, err := tx.Exec(ctx, `UPDATE products SET images = $2, updated_at = now() WHERE id = $1`, productID, out); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE photo_web_jobs SET status = 'reverted', manual = false, pick_key = '', updated_at = now() WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return WebJobRow{}, err
	}
	return s.WebJob(ctx, id)
}

// ApplyWeb — «Поставить» найденное фото (ждало решения или его вернули).
func (s *PhotoService) ApplyWeb(ctx context.Context, id string) (WebJobRow, error) {
	err := s.webTx(ctx, func(tx pgx.Tx) error {
		_, productID, old, result, err := webLock(ctx, tx, id)
		if err != nil {
			return err
		}
		if result == "" {
			return apperr.Conflict("photo_web_no_result", "Готового фото ещё нет").Uz("Tayyor rasm hali yoʻq")
		}
		if err := s.webPut(ctx, tx, productID, old, "", result); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE photo_web_jobs SET status = 'replaced', manual = false, updated_at = now() WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return WebJobRow{}, err
	}
	return s.WebJob(ctx, id)
}

// WebPickInput — «Выбрать другое фото»: номер из найденных (с 0) или своё фото (ссылка из хранилища).
type WebPickInput struct {
	Candidate *int   `json:"candidate"`
	Image     string `json:"image"`
}

// PickWeb — сделать чистое фото из выбранного (в очередь, сразу).
func (s *PhotoService) PickWeb(ctx context.Context, id string, in WebPickInput) (WebJobRow, error) {
	err := s.webTx(ctx, func(tx pgx.Tx) error {
		if _, _, _, _, err := webLock(ctx, tx, id); err != nil {
			return err
		}
		key, source := "", ""
		switch {
		case strings.TrimSpace(in.Image) != "":
			k, ok := media.KeyFromURL(strings.TrimSpace(in.Image))
			if !ok {
				return apperr.Validation("image: загрузите фото в хранилище Super Market").Uz("image: rasmni Super Market omboriga yuklang")
			}
			key, source = k, "own"
		case in.Candidate != nil:
			var cands []webCandidate
			var raw []byte
			if err := tx.QueryRow(ctx, `SELECT candidates FROM photo_web_jobs WHERE id = $1`, id).Scan(&raw); err != nil {
				return err
			}
			_ = json.Unmarshal(raw, &cands)
			if *in.Candidate < 0 || *in.Candidate >= len(cands) {
				return apperr.Validation("candidate: нет такого фото").Uz("candidate: bunday rasm yoʻq")
			}
			key, source = cands[*in.Candidate].URL, cands[*in.Candidate].Source
		default:
			return apperr.Validation("candidate или image: что поставить").Uz("candidate yoki image: nimani qoʻyish")
		}
		_, err := tx.Exec(ctx, `UPDATE photo_web_jobs SET status = 'queued', pick_key = $2, pick_source = $3, manual = true, errors = 0, error = '',
			next_at = now(), updated_at = now() WHERE id = $1`, id, key, source)
		return err
	})
	if err != nil {
		return WebJobRow{}, err
	}
	s.KickWeb()
	return s.WebJob(ctx, id)
}

// ResearchWeb — «Поискать ещё»: следующая страница Google.
func (s *PhotoService) ResearchWeb(ctx context.Context, id string) (WebJobRow, error) {
	err := s.webTx(ctx, func(tx pgx.Tx) error {
		if _, _, _, _, err := webLock(ctx, tx, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE photo_web_jobs SET status = 'queued', pick_key = '', manual = true, errors = 0, error = '',
			reason = CASE WHEN reason IN ('', 'ok') THEN 'wrong' ELSE reason END,
			reason_text = CASE WHEN reason IN ('', 'ok') THEN 'Отмечено вручную' ELSE reason_text END,
			search_page = LEAST(search_page + CASE WHEN status = 'not_found' THEN 0 ELSE 1 END, 10),
			next_at = now(), updated_at = now() WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return WebJobRow{}, err
	}
	s.KickWeb()
	return s.WebJob(ctx, id)
}

// RetryNotFoundResult — сколько «Не нашли» снова в очереди.
type RetryNotFoundResult struct {
	Queued int `json:"queued"`
}

// RetryNotFound — «Повторить «Не нашли»»: все, сразу (и после 3 попыток).
func (s *PhotoService) RetryNotFound(ctx context.Context) (RetryNotFoundResult, error) {
	tag, err := s.ai.pool.Exec(ctx, `UPDATE photo_web_jobs SET status = 'queued', manual = true, attempts = 0, errors = 0, error = '',
		next_at = now(), updated_at = now() WHERE status IN ('not_found', 'failed')`)
	if err != nil {
		return RetryNotFoundResult{}, err
	}
	s.KickWeb()
	return RetryNotFoundResult{Queued: int(tag.RowsAffected())}, nil
}

// CheckProductWeb — проверить фото товара сейчас (кнопка на странице товара и тесты).
func (s *PhotoService) CheckProductWeb(ctx context.Context, productID string) (WebJobRow, error) {
	var id string
	err := s.ai.pool.QueryRow(ctx, `
		INSERT INTO photo_web_jobs (product_id, old_image, manual)
		SELECT p.id, COALESCE(p.images[1], ''), true FROM products p WHERE p.id = $1
		ON CONFLICT (product_id) DO UPDATE SET status = 'queued', reason = '', reason_text = '', old_image = EXCLUDED.old_image,
		       manual = true, pick_key = '', attempts = 0, errors = 0, error = '', search_page = 1, next_at = now(), updated_at = now()
		WHERE photo_web_jobs.status <> 'processing'
		RETURNING id::text`, productID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		var exists bool
		_ = s.ai.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM products WHERE id = $1)`, productID).Scan(&exists)
		if !exists {
			return WebJobRow{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		return WebJobRow{}, errWebBusy
	}
	if err != nil {
		return WebJobRow{}, err
	}
	s.KickWeb()
	return s.WebJob(ctx, id)
}

func (s *PhotoService) webTx(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := s.ai.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
