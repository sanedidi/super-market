package ai

// Фото магазинов — результаты для супер-админа (Figma «Супер-админ · Фото
// магазинов — результаты»): счётчики и причины за месяц, список фото с
// фильтрами, «Повторить» неудачное и «Переделать» готовое.

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Виды фото магазина.
const (
	KindNew   = "new"   // новый товар по фото
	KindLines = "lines" // строка «Инвентаризации»
	KindOld   = "old"   // старое фото «Начала работы»
)

// StoreJobLog — запись истории задания.
type StoreJobLog struct {
	At   time.Time `json:"at"`
	Kind string    `json:"kind"` // queued, error, retry, done, failed, skipped
	Text string    `json:"text"`
}

// StoreJobNetwork — сеть задания.
type StoreJobNetwork struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Blocked bool   `json:"blocked"`
}

// StoreJobStore — магазин задания.
type StoreJobStore struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Active bool   `json:"active"`
}

// StoreJobRow — фото магазина в списке супер-админа. Sources и Result —
// ключи хранилища (ссылки подставляет HTTP-слой).
type StoreJobRow struct {
	ID string `json:"id"`
	// Status — queued, processing, done, failed, skipped; retry — не вышло
	// из-за временной ошибки Google, Super Market повторит сам в RetryAt.
	Status string `json:"status"`
	// Reason — текст ошибки (failed, временная ошибка в очереди) или причина
	// skipped: limit, off, cancelled, blocked.
	Reason string `json:"reason"`
	// Code — причина «Не вышло» (CodeRateLimit…); у временной ошибки в
	// очереди — тоже.
	Code      string          `json:"code"`
	Kind      string          `json:"kind"`
	Network   StoreJobNetwork `json:"network"`
	Store     *StoreJobStore  `json:"store"`
	Employee  string          `json:"employee"`
	ProductID *string         `json:"product_id"`
	NewItemID *string         `json:"new_item_id"`
	Name      string          `json:"name"`
	Barcode   string          `json:"barcode"`
	Sources   []string        `json:"sources"`
	Result    *string         `json:"result"`
	MediaBase string          `json:"-"`
	Attempts  int             `json:"attempts"`
	MaxTries  int             `json:"max_attempts"`
	RetryAt   *time.Time      `json:"retry_at"`
	CostUSD   *float64        `json:"cost_usd"`
	Model     string          `json:"model"`
	Redo      bool            `json:"redo"` // «Переделать»
	// Placed — где готовое фото: product — стоит в товаре; card — в карточке
	// «Новых», ждёт проверки магазином; own — в товаре его нет (магазин
	// оставил своё фото или поменял). У неготового — пусто.
	Placed     string        `json:"placed"`
	CreatedAt  time.Time     `json:"created_at"`
	FinishedAt *time.Time    `json:"finished_at"`
	Log        []StoreJobLog `json:"log"`
}

// StoreJobsFilter — фильтры списка. Month — YYYY-MM (Ташкент), пусто — этот месяц.
type StoreJobsFilter struct {
	Month     string
	Status    string // done, failed (с retry), queued (с «делается»), processing, skipped
	NetworkID string
	Kind      string
	Code      string
	Query     string
	Limit     int
	Offset    int
}

// StoreJobsPage — страница списка.
type StoreJobsPage struct {
	Items []StoreJobRow `json:"items"`
	Total int           `json:"total"`
}

// StoreReason — причина «Не вышло» за месяц.
type StoreReason struct {
	Code  string `json:"code"`
	Count int    `json:"count"`
	// Waiting — из них ждут повтора (временная ошибка); Retryable — причина
	// временная: Super Market повторяет сам.
	Waiting   int  `json:"waiting"`
	Retryable bool `json:"retryable"`
}

// Статус задания для супер-админа: временная ошибка в очереди — retry.
const (
	storeRetrySQL     = `(j.status = 'queued' AND j.retry_at IS NOT NULL)`
	storeFailedSQL    = `(j.status = 'failed' OR ` + storeRetrySQL + `)`
	storeWaitingSQL   = `(j.status = 'processing' OR (j.status = 'queued' AND j.retry_at IS NULL))`
	storeJobStatusSQL = `CASE WHEN ` + storeRetrySQL + ` THEN 'retry' ELSE j.status END`
)

// StoreSummaryNetwork — сеть в фильтре и счётчике «Сетей».
type StoreSummaryNetwork struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Blocked bool   `json:"blocked"`
	Photos  int    `json:"photos"`
}

// StoreSummary — счётчики «Фото магазинов» за месяц.
type StoreSummary struct {
	Month      string `json:"month"`
	Total      int    `json:"total"`
	Done       int    `json:"done"`
	Failed     int    `json:"failed"`   // не вышло, вместе с retry
	Retrying   int    `json:"retrying"` // из них Super Market повторит сам
	Queued     int    `json:"queued"`   // ждут, вместе с «делается»
	Processing int    `json:"processing"`
	Skipped    int    `json:"skipped"`
	// SkippedBy — пропущено по причинам: limit, off, cancelled, blocked.
	SkippedBy map[string]int        `json:"skipped_by"`
	CostUSD   float64               `json:"cost_usd"`
	Networks  []StoreSummaryNetwork `json:"networks"`
	Reasons   []StoreReason         `json:"reasons"`
}

// storeMonthRange — начало и конец месяца по Ташкенту; month пусто — этот.
func (s *PhotoService) storeMonthRange(month string) (time.Time, time.Time, string, error) {
	var from time.Time
	if month == "" {
		now := s.ai.now().In(tashkent)
		from = time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, tashkent)
	} else {
		t, err := time.ParseInLocation("2006-01", month, tashkent)
		if err != nil {
			return from, from, "", apperr.Validation("month: ожидается ГГГГ-ММ").Uz("month: YYYY-MM kutilmoqda")
		}
		from = t
	}
	return from, from.AddDate(0, 1, 0), from.Format("2006-01"), nil
}

// storeKindSQL — вид фото задания.
const storeKindSQL = `CASE WHEN j.backfill THEN 'old' WHEN j.new_item_id IS NOT NULL THEN 'new' ELSE 'lines' END`

// StoreSummary — счётчики, причины и сети за месяц.
func (s *PhotoService) StoreSummary(ctx context.Context, month string) (StoreSummary, error) {
	from, to, m, err := s.storeMonthRange(month)
	out := StoreSummary{Month: m, SkippedBy: map[string]int{}, Networks: []StoreSummaryNetwork{}, Reasons: []StoreReason{}}
	if err != nil {
		return out, err
	}
	err = s.ai.pool.QueryRow(ctx, `
		SELECT count(*)::int,
		       (count(*) FILTER (WHERE j.status = 'done'))::int,
		       (count(*) FILTER (WHERE `+storeFailedSQL+`))::int,
		       (count(*) FILTER (WHERE `+storeRetrySQL+`))::int,
		       (count(*) FILTER (WHERE `+storeWaitingSQL+`))::int,
		       (count(*) FILTER (WHERE j.status = 'processing'))::int,
		       (count(*) FILTER (WHERE j.status = 'skipped'))::int
		FROM photo_jobs j WHERE j.created_at >= $1 AND j.created_at < $2`, from, to).
		Scan(&out.Total, &out.Done, &out.Failed, &out.Retrying, &out.Queued, &out.Processing, &out.Skipped)
	if err != nil {
		return out, err
	}
	if err := s.ai.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(cost) FILTER (WHERE currency = 'USD'), 0)::float8 FROM ai_usage
		WHERE kind = 'photo_store' AND at >= $1 AND at < $2`, from, to).Scan(&out.CostUSD); err != nil {
		return out, err
	}
	rows, err := s.ai.pool.Query(ctx, `
		SELECT error, count(*)::int FROM photo_jobs
		WHERE status = 'skipped' AND created_at >= $1 AND created_at < $2 GROUP BY 1`, from, to)
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
		out.SkippedBy[k] = n
	}
	rows.Close()
	if out.Reasons, err = collect(ctx, s.ai.pool, `
		SELECT COALESCE(NULLIF(j.error_code, ''), 'other'), count(*)::int, (count(*) FILTER (WHERE `+storeRetrySQL+`))::int
		FROM photo_jobs j
		WHERE `+storeFailedSQL+` AND j.created_at >= $1 AND j.created_at < $2
		GROUP BY 1 ORDER BY 2 DESC, 1`, func(r pgx.CollectableRow) (StoreReason, error) {
		var x StoreReason
		err := r.Scan(&x.Code, &x.Count, &x.Waiting)
		x.Retryable = Retryable(x.Code)
		return x, err
	}, from, to); err != nil {
		return out, err
	}
	out.Networks, err = collect(ctx, s.ai.pool, `
		SELECT n.id::text, n.name, n.status <> 'active', count(*)::int FROM photo_jobs j JOIN networks n ON n.id = j.network_id
		WHERE j.created_at >= $1 AND j.created_at < $2 GROUP BY n.id ORDER BY 4 DESC, 2`, func(r pgx.CollectableRow) (StoreSummaryNetwork, error) {
		var x StoreSummaryNetwork
		return x, r.Scan(&x.ID, &x.Name, &x.Blocked, &x.Photos)
	}, from, to)
	return out, err
}

func collect[T any](ctx context.Context, q db.Querier, sql string, scan func(pgx.CollectableRow) (T, error), args ...any) ([]T, error) {
	rows, err := q.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scan)
	if out == nil {
		out = []T{}
	}
	return out, err
}

// storeJobSelect — задание с товаром, сетью, магазином и сотрудником.
const storeJobSelect = `
	SELECT j.id::text, ` + storeJobStatusSQL + `, j.error, j.error_code, ` + storeKindSQL + `,
	       n.id::text, n.name, n.status <> 'active',
	       st.id::text, COALESCE(st.name, ''), COALESCE(st.status = 'active', false),
	       COALESCE(e.full_name, ''), j.product_id::text, j.new_item_id::text,
	       COALESCE(p.name, ni.result ->> 'name', ''),
	       COALESCE((SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = j.product_id), ni.barcode, ''),
	       j.sources, NULLIF(j.result, ''), j.media_base, j.attempts, j.retry_at, j.cost_usd::float8, j.model, j.replaces <> '',
	       j.created_at, j.finished_at, j.log,
	       CASE WHEN j.status <> 'done' THEN ''
	            WHEN p.id IS NOT NULL AND EXISTS (SELECT 1 FROM unnest(p.images) u WHERE u LIKE '%/' || j.result OR u = j.result) THEN 'product'
	            WHEN ni.id IS NOT NULL AND ni.status <> 'done' THEN 'card'
	            ELSE 'own' END
	FROM photo_jobs j
	JOIN networks n ON n.id = j.network_id
	LEFT JOIN stores st ON st.id = j.store_id
	LEFT JOIN employees e ON e.id = j.employee_id
	LEFT JOIN products p ON p.id = j.product_id
	LEFT JOIN start_new_items ni ON ni.id = j.new_item_id`

func scanStoreJob(r pgx.CollectableRow) (StoreJobRow, error) {
	var j StoreJobRow
	var storeID *string
	var storeName string
	var storeActive bool
	var log []byte
	err := r.Scan(&j.ID, &j.Status, &j.Reason, &j.Code, &j.Kind, &j.Network.ID, &j.Network.Name, &j.Network.Blocked,
		&storeID, &storeName, &storeActive, &j.Employee, &j.ProductID, &j.NewItemID, &j.Name, &j.Barcode,
		&j.Sources, &j.Result, &j.MediaBase, &j.Attempts, &j.RetryAt, &j.CostUSD, &j.Model, &j.Redo, &j.CreatedAt, &j.FinishedAt, &log, &j.Placed)
	if err != nil {
		return j, err
	}
	if storeID != nil {
		j.Store = &StoreJobStore{ID: *storeID, Name: storeName, Active: storeActive}
	}
	j.MaxTries = storeJobAttempts
	j.Log = []StoreJobLog{}
	_ = json.Unmarshal(log, &j.Log)
	if j.Sources == nil {
		j.Sources = []string{}
	}
	return j, nil
}

// StoreJobs — фото магазинов за месяц, новые сверху.
func (s *PhotoService) StoreJobs(ctx context.Context, f StoreJobsFilter) (StoreJobsPage, error) {
	out := StoreJobsPage{Items: []StoreJobRow{}}
	from, to, _, err := s.storeMonthRange(f.Month)
	if err != nil {
		return out, err
	}
	where := []string{"j.created_at >= $1", "j.created_at < $2"}
	args := []any{from, to}
	arg := func(v any) string {
		args = append(args, v)
		return "$" + strconv.Itoa(len(args))
	}
	switch f.Status {
	case "":
	case JobQueued:
		where = append(where, storeWaitingSQL)
	case JobFailed:
		where = append(where, storeFailedSQL)
	case "retry":
		where = append(where, storeRetrySQL)
	case JobProcessing, JobDone, JobSkipped:
		where = append(where, "j.status = "+arg(f.Status))
	default:
		return out, apperr.Validation("status: done, failed, retry, queued, processing или skipped").Uz("status: done, failed, retry, queued, processing yoki skipped")
	}
	if f.NetworkID != "" {
		where = append(where, "j.network_id::text = "+arg(f.NetworkID))
	}
	switch f.Kind {
	case "":
	case KindNew, KindLines, KindOld:
		where = append(where, storeKindSQL+" = "+arg(f.Kind))
	default:
		return out, apperr.Validation("kind: new, lines или old").Uz("kind: new, lines yoki old")
	}
	if f.Code != "" {
		where = append(where, storeFailedSQL+" AND COALESCE(NULLIF(j.error_code, ''), 'other') = "+arg(f.Code))
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		a := arg("%" + q + "%")
		where = append(where, `(COALESCE(p.name, ni.result ->> 'name', '') ILIKE `+a+` OR ni.barcode ILIKE `+a+`
			OR EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = j.product_id AND pb.barcode ILIKE `+a+`))`)
	}
	cond := " WHERE " + strings.Join(where, " AND ")
	if err := s.ai.pool.QueryRow(ctx, `SELECT count(*)::int FROM photo_jobs j
		LEFT JOIN products p ON p.id = j.product_id LEFT JOIN start_new_items ni ON ni.id = j.new_item_id`+cond, args...).Scan(&out.Total); err != nil {
		return out, err
	}
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	sql := storeJobSelect + cond + " ORDER BY j.created_at DESC, j.id LIMIT " + arg(limit) + " OFFSET " + arg(max(f.Offset, 0))
	out.Items, err = collect(ctx, s.ai.pool, sql, scanStoreJob, args...)
	return out, err
}

// StoreJob — одно фото магазина (карточка фото).
func (s *PhotoService) StoreJob(ctx context.Context, id string) (StoreJobRow, error) {
	items, err := collect(ctx, s.ai.pool, storeJobSelect+" WHERE j.id::text = $1", scanStoreJob, id)
	if err != nil {
		return StoreJobRow{}, err
	}
	if len(items) == 0 {
		return StoreJobRow{}, apperr.NotFound("фото не найдено").Uz("rasm topilmadi")
	}
	return items[0], nil
}

// requeueSQL — неудачное задание (или ждущее повтора) снова в очередь сразу,
// попытки заново.
var requeueSQL = `UPDATE photo_jobs SET status = 'queued', attempts = 0, error = '', error_code = '', retry_at = NULL, finished_at = NULL,
	log = log || ` + logEntrySQL("'retry'", "'супер-админ'") + `
	WHERE (status = 'failed' OR (status = 'queued' AND retry_at IS NOT NULL)) AND NOT ` + inactiveJobSQL + `
	  AND NOT EXISTS (SELECT 1 FROM start_new_items ni WHERE ni.id = photo_jobs.new_item_id AND ni.status = 'done' AND photo_jobs.product_id IS NULL)`

// RetryStoreJob — «Повторить»: неудачное фото снова в очередь.
func (s *PhotoService) RetryStoreJob(ctx context.Context, id string) (StoreJobRow, error) {
	j, err := s.StoreJob(ctx, id)
	if err != nil {
		return j, err
	}
	if j.Status != JobFailed && j.Status != "retry" {
		return j, apperr.Conflict("not_failed", "повторить можно только фото, которое не вышло").Uz("faqat chiqmagan rasmni takrorlash mumkin")
	}
	if j.Network.Blocked || (j.Store != nil && !j.Store.Active) {
		return j, apperr.Conflict("blocked", "сеть заблокирована или магазин выключен").Uz("tarmoq bloklangan yoki doʻkon oʻchirilgan")
	}
	tag, err := s.ai.pool.Exec(ctx, requeueSQL+" AND id::text = $1", id)
	if err != nil {
		return j, err
	}
	if tag.RowsAffected() == 0 {
		return j, apperr.Conflict("own_photo", "магазин уже подтвердил товар со своим фото").Uz("doʻkon mahsulotni oʻz rasmi bilan tasdiqlagan")
	}
	s.resume()
	s.Kick()
	return s.StoreJob(ctx, id)
}

// RetryFailedInput — «Повторить неудачные»: за месяц, по причине и сети.
type RetryFailedInput struct {
	Month     string `json:"month"`
	Code      string `json:"code"`
	NetworkID string `json:"network_id"`
}

// RetryFailedResult — сколько фото снова в очереди.
type RetryFailedResult struct {
	Queued int `json:"queued"`
}

// RetryFailed — все неудачные фото месяца (с фильтром) снова в очередь.
func (s *PhotoService) RetryFailed(ctx context.Context, in RetryFailedInput) (RetryFailedResult, error) {
	from, to, _, err := s.storeMonthRange(in.Month)
	if err != nil {
		return RetryFailedResult{}, err
	}
	tag, err := s.ai.pool.Exec(ctx, requeueSQL+`
		AND created_at >= $1 AND created_at < $2
		AND ($3 = '' OR COALESCE(NULLIF(error_code, ''), 'other') = $3)
		AND ($4 = '' OR network_id::text = $4)`, from, to, in.Code, in.NetworkID)
	if err != nil {
		return RetryFailedResult{}, err
	}
	if tag.RowsAffected() > 0 {
		s.resume()
		s.Kick()
	}
	return RetryFailedResult{Queued: int(tag.RowsAffected())}, nil
}

// RedoStoreJob — «Переделать» готовое фото: новое задание из тех же фото
// магазина, готовое встанет на место прежнего. Идёт в лимит сети.
func (s *PhotoService) RedoStoreJob(ctx context.Context, id string) (StoreJobRow, error) {
	j, err := s.StoreJob(ctx, id)
	if err != nil {
		return j, err
	}
	if j.Status != JobDone || j.Result == nil {
		return j, apperr.Conflict("not_done", "переделать можно только готовое фото").Uz("faqat tayyor rasmni qayta qilish mumkin")
	}
	if j.Network.Blocked || (j.Store != nil && !j.Store.Active) {
		return j, apperr.Conflict("blocked", "сеть заблокирована или магазин выключен").Uz("tarmoq bloklangan yoki doʻkon oʻchirilgan")
	}
	r, err := s.load(ctx)
	if err != nil {
		return j, err
	}
	if !r.storeOn() {
		return j, apperr.Conflict("photo_off", "«Фото для магазинов» выключены").Uz("«Doʻkonlar uchun rasm» oʻchirilgan")
	}
	var newID string
	err = s.ai.pool.QueryRow(ctx, `
		INSERT INTO photo_jobs (network_id, store_id, employee_id, new_item_id, product_id, sources, media_base, backfill, replaces, log)
		SELECT network_id, store_id, employee_id, new_item_id, product_id, sources, media_base, false, result,
		       `+logEntrySQL("'queued'", "'«Переделать» — супер-админ'")+`
		FROM photo_jobs WHERE id::text = $1 RETURNING id::text`, id).Scan(&newID)
	if err != nil {
		return j, err
	}
	s.Kick()
	return s.StoreJob(ctx, newID)
}

// StoreJobURLs — ссылки на фото магазина и готовое фото вместо ключей.
func (s *PhotoService) StoreJobURLs(r *http.Request, j StoreJobRow) StoreJobRow {
	url := func(k string) string {
		if j.MediaBase != "" {
			if u := s.media.URLWithBase(j.MediaBase, k); u != "" {
				return u
			}
		}
		return s.media.URL(r, k)
	}
	src := make([]string, len(j.Sources))
	for i, k := range j.Sources {
		src[i] = url(k)
	}
	j.Sources = src
	if j.Result != nil {
		u := url(*j.Result)
		j.Result = &u
	}
	return j
}
