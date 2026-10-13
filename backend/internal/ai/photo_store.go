package ai

// Нормализация фото для магазина (Figma «Нормализация фото для магазина»):
// та же «Нормализовать фото», что у супер-админа, но запускает её сам Super
// Market — после распознавания нового товара по фото и после фото строки на
// «Инвентаризации». Магазину ничего нажимать не нужно.
//
// Задания лежат в таблице photo_jobs, а не в памяти: перезапуск сервера их не
// теряет. Воркер берёт по photoParallel заданий; на вход Gemini идут все фото
// магазина (лицо и этикетка), на выходе — одно фото лицевой стороны. Куда
// положить готовое фото (карточка «Новых» или товар), решает OnStoreDone —
// это знает модуль «Начало работы».

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Статусы заданий photo_jobs.
const (
	JobQueued     = "queued"
	JobProcessing = "processing"
	JobDone       = "done"
	JobFailed     = "failed"
	JobSkipped    = "skipped"

	// Причины skipped.
	SkipLimit     = "limit"
	SkipOff       = "off"
	SkipCancelled = "cancelled"

	maxStoreSources = 6
	// Задание «processing» дольше этого — сервер перезапускали: взять снова.
	storeJobStale = 10 * time.Minute
	// Столько раз задание берётся в работу, потом — failed.
	storeJobAttempts = 3
	storeJobPoll     = 20 * time.Second
)

// StoreJob — задание магазина: для карточки «Новых» или для товара.
type StoreJob struct {
	NetworkID  string
	StoreID    string
	EmployeeID string
	NewItemID  *string
	ProductID  *string
	// Sources — ключи хранилища (не ссылки); MediaBase — начало ссылки, с
	// которой магазин их загрузил (см. media.BaseOf).
	Sources   []string
	MediaBase string
	// Lines — фото строки на «Инвентаризации» (иначе — новый товар по фото).
	Lines bool
}

// StoreDone — готовое задание для OnStoreDone.
type StoreDone struct {
	ID        string
	NetworkID string
	StoreID   *string
	NewItemID *string
	ProductID *string
	Sources   []string
	MediaBase string
	Result    string // ключ готового фото
}

// StoreQuota — фото Super Market в этом месяце для сети.
type StoreQuota struct {
	// Enabled — Super Market сейчас делает фото магазинам (подключено и
	// включено у супер-админа).
	Enabled bool `json:"enabled"`
	Used    int  `json:"used"`
	// Limit — лимит тарифа в месяц; nil — без лимита.
	Limit *int `json:"limit"`
	// ResetsOn — с какого числа счётчик снова полный (YYYY-MM-DD, Ташкент).
	ResetsOn string `json:"resets_on"`
}

// StoreTop — сеть в расходе «Фото для магазинов».
type StoreTop struct {
	NetworkID string `json:"network_id"`
	Name      string `json:"name"`
	// Photos — сделано фото; Used — сколько ушло из лимита (с «делается»).
	Photos  int     `json:"photos"`
	Used    int     `json:"used"`
	Limit   *int    `json:"limit"`
	CostUSD float64 `json:"cost_usd"`
}

// StoreSettingsInput — PUT /admin/ai-photo/store; nil — не менять.
type StoreSettingsInput struct {
	Enabled  *bool   `json:"store_enabled"`
	NewItems *bool   `json:"store_new_items"`
	Lines    *bool   `json:"store_lines"`
	Model    *string `json:"store_model"`
}

// storeWorker — состояние воркера (в PhotoService).
type storeWorker struct {
	once sync.Once
	wake chan struct{}
	// runMu — один проход очереди за раз (Sync в тестах — тоже).
	runMu sync.Mutex
}

// monthStart — начало месяца по Ташкенту (SQL).
const monthStartSQL = `date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'`

// storeJobCounted — какие задания идут в лимит месяца: не сделанные по
// ошибке Gemini и пропущенные не считаются, «Переделать» — считается.
const storeJobCounted = `status IN ('queued', 'processing', 'done')`

// StoreUsedSQL — счётчик лимита тарифа «Фото от Super Market» ($1 — сеть).
const StoreUsedSQL = `SELECT count(*) FROM photo_jobs WHERE network_id = $1 AND ` + storeJobCounted + ` AND created_at >= ` + monthStartSQL

// SaveStore — блок «Фото для магазинов».
func (s *PhotoService) SaveStore(ctx context.Context, adminID string, in StoreSettingsInput) (PhotoSettings, error) {
	if in.Model != nil {
		m := strings.TrimSpace(*in.Model)
		if len(m) > 200 {
			return PhotoSettings{}, apperr.Validation("store_model: слишком длинное название").Uz("store_model: nomi juda uzun")
		}
		in.Model = &m
	}
	_, err := s.ai.pool.Exec(ctx, `
		UPDATE ai_photo_settings SET store_enabled = COALESCE($1, store_enabled), store_new_items = COALESCE($2, store_new_items),
		       store_lines = COALESCE($3, store_lines), store_model = COALESCE($4, store_model), updated_by = $5, updated_at = now()`,
		in.Enabled, in.NewItems, in.Lines, in.Model, adminID)
	if err != nil {
		return PhotoSettings{}, err
	}
	return s.Get(ctx)
}

// storeOn — Super Market делает фото магазинам: подключено и включено.
func (r photoRow) storeOn() bool { return r.Configured && r.StoreEnabled }

// Enqueue — поставить задание магазина (в транзакции вызывающего). Выключено
// или не подключено — задания нет (""), лимит месяца кончился — задание
// skipped/limit (магазин видит «ваше фото · лимит месяца»). После коммита —
// Kick.
func (s *PhotoService) Enqueue(ctx context.Context, q db.Querier, j StoreJob) (string, error) {
	if len(j.Sources) == 0 {
		return "", nil
	}
	if len(j.Sources) > maxStoreSources {
		j.Sources = j.Sources[:maxStoreSources]
	}
	r, err := s.loadQ(ctx, q)
	if err != nil {
		return "", err
	}
	if !r.storeOn() || (j.Lines && !r.StoreLines) || (!j.Lines && !r.StoreNewItems) {
		return "", nil
	}
	status, reason := JobQueued, ""
	if s.Limit != nil {
		limit, err := s.Limit(ctx, q, j.NetworkID)
		if err != nil {
			return "", err
		}
		if limit != nil {
			var used int
			if err := q.QueryRow(ctx, StoreUsedSQL, j.NetworkID).Scan(&used); err != nil {
				return "", err
			}
			if used >= *limit {
				status, reason = JobSkipped, SkipLimit
			}
		}
	}
	var id string
	err = q.QueryRow(ctx, `
		INSERT INTO photo_jobs (network_id, store_id, employee_id, new_item_id, product_id, sources, media_base, status, error)
		VALUES ($1, NULLIF($2, '')::uuid, NULLIF($3, '')::uuid, $4, $5, $6, $7, $8, $9) RETURNING id`,
		j.NetworkID, j.StoreID, j.EmployeeID, j.NewItemID, j.ProductID, j.Sources, trimBase(j.MediaBase), status, reason).Scan(&id)
	if err != nil {
		return "", err
	}
	return status, nil
}

func trimBase(b string) string {
	if len(b) > 300 {
		return ""
	}
	return b
}

// Kick — после коммита задания: в тестах (Sync) очередь проходится сразу,
// иначе будит воркер.
func (s *PhotoService) Kick() {
	if s.Sync {
		s.RunQueued(context.Background())
		return
	}
	s.worker.once.Do(s.initWorker)
	select {
	case s.worker.wake <- struct{}{}:
	default:
	}
}

func (s *PhotoService) initWorker() { s.worker.wake = make(chan struct{}, 1) }

// StartWorker — фоновый воркер очереди: по сигналу Kick и раз в storeJobPoll
// (задания, взятые до перезапуска сервера, подхватываются тоже).
func (s *PhotoService) StartWorker(ctx context.Context) {
	s.worker.once.Do(s.initWorker)
	go func() {
		t := time.NewTicker(storeJobPoll)
		defer t.Stop()
		for {
			s.safeRun(ctx)
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			case <-s.worker.wake:
			}
		}
	}()
}

func (s *PhotoService) safeRun(ctx context.Context) {
	defer func() {
		if p := recover(); p != nil {
			s.log.Error("фото магазинов: паника", "panic", p)
		}
	}()
	s.RunQueued(ctx)
}

// storeJob — задание из очереди.
type storeJob struct {
	StoreDone
	employeeID *string
	attempts   int
}

// RunQueued — пройти очередь до конца: до photoParallel заданий сразу; как
// только одно готово — берётся следующее (долгое задание не держит очередь).
func (s *PhotoService) RunQueued(ctx context.Context) {
	s.worker.runMu.Lock()
	defer s.worker.runMu.Unlock()
	done := make(chan struct{}, photoParallel)
	running := 0
	for {
		for running < photoParallel && ctx.Err() == nil {
			jobs, err := s.claim(ctx, 1)
			if err != nil {
				s.log.Error("фото магазинов: очередь", "err", err)
				break
			}
			if len(jobs) == 0 {
				break
			}
			running++
			go func(j storeJob) {
				defer func() { done <- struct{}{} }()
				defer func() {
					if p := recover(); p != nil {
						s.log.Error("фото магазинов: паника", "id", j.ID, "panic", p)
						s.fail(context.Background(), j.ID, "внутренняя ошибка")
					}
				}()
				s.runStore(ctx, j)
			}(jobs[0])
		}
		if running == 0 {
			return
		}
		// Ждём, пока освободится место или появится новое задание.
		select {
		case <-done:
			running--
		case <-s.worker.wake:
		}
	}
}

// claim — взять задания в работу. Зависшие «processing» (сервер
// перезапускали) берутся снова, пока не кончатся попытки.
func (s *PhotoService) claim(ctx context.Context, n int) ([]storeJob, error) {
	if _, err := s.ai.pool.Exec(ctx, `
		UPDATE photo_jobs SET status = 'failed', error = 'не успели сделать фото'
		WHERE status = 'processing' AND started_at < now() - $1::interval AND attempts >= $2`,
		storeJobStale.String(), storeJobAttempts); err != nil {
		return nil, err
	}
	rows, err := s.ai.pool.Query(ctx, `
		UPDATE photo_jobs SET status = 'processing', started_at = now(), attempts = attempts + 1
		WHERE id IN (
			SELECT id FROM photo_jobs
			WHERE status = 'queued' OR (status = 'processing' AND started_at < now() - $1::interval)
			ORDER BY created_at LIMIT $2 FOR UPDATE SKIP LOCKED)
		RETURNING id, network_id, store_id, employee_id, new_item_id, product_id, sources, media_base, attempts`,
		storeJobStale.String(), n)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (storeJob, error) {
		var j storeJob
		err := r.Scan(&j.ID, &j.NetworkID, &j.StoreID, &j.employeeID, &j.NewItemID, &j.ProductID, &j.Sources, &j.MediaBase, &j.attempts)
		return j, err
	})
}

func (s *PhotoService) fail(ctx context.Context, id, msg string) {
	if r := []rune(msg); len(r) > 500 {
		msg = string(r[:500])
	}
	if _, err := s.ai.pool.Exec(ctx, `UPDATE photo_jobs SET status = 'failed', error = $2 WHERE id = $1 AND status = 'processing'`, id, msg); err != nil {
		s.log.Error("фото магазинов: ошибка задания", "id", id, "err", err)
	}
}

// runStore — одно задание: Gemini, квадрат, хранилище, OnStoreDone.
func (s *PhotoService) runStore(ctx context.Context, j storeJob) {
	r, err := s.load(ctx)
	if err != nil {
		s.log.Error("фото магазинов: настройки", "err", err)
		return
	}
	if !r.storeOn() {
		if _, err := s.ai.pool.Exec(ctx, `UPDATE photo_jobs SET status = 'skipped', error = $2 WHERE id = $1 AND status = 'processing'`, j.ID, SkipOff); err != nil {
			s.log.Error("фото магазинов", "id", j.ID, "err", err)
		}
		return
	}
	key, err := s.storePhoto(ctx, r, j)
	if err != nil {
		s.fail(context.WithoutCancel(ctx), j.ID, errText(err, i18n.RU))
		return
	}
	done := j.StoreDone
	done.Result = key
	if s.OnStoreDone != nil {
		err = s.OnStoreDone(context.WithoutCancel(ctx), done)
	} else {
		_, err = s.ai.pool.Exec(context.WithoutCancel(ctx), `UPDATE photo_jobs SET status = 'done', result = $2, error = '' WHERE id = $1 AND status = 'processing'`, j.ID, key)
	}
	if err != nil {
		s.log.Error("фото магазинов: готовое фото", "id", j.ID, "err", err)
		s.fail(context.WithoutCancel(ctx), j.ID, "не удалось сохранить фото")
	}
}

// storePhoto — Gemini делает из фото магазина одно чистое фото; ключ в хранилище.
func (s *PhotoService) storePhoto(ctx context.Context, r photoRow, j storeJob) (string, error) {
	c, o, _, err := s.conn(ctx, PhotoInput{Model: r.StoreModel})
	if err != nil {
		return "", err
	}
	if c.Model == "" {
		return "", &ErrService{Msg: "не выбрана модель для фото", MsgUz: "rasm uchun model tanlanmagan"}
	}
	product, err := s.storeProduct(ctx, j)
	if err != nil {
		return "", err
	}
	images := make([]Image, 0, len(j.Sources))
	for _, k := range j.Sources {
		raw, mime, err := s.media.Read(ctx, k)
		if err != nil {
			if errors.Is(err, media.ErrNotFound) {
				continue
			}
			return "", &ErrService{Msg: "фото не найдено в хранилище", MsgUz: "rasm omborda topilmadi"}
		}
		img, err := shrinkForModel(raw, mime)
		if err != nil {
			continue
		}
		images = append(images, img)
	}
	if len(images) == 0 {
		return "", &ErrService{Msg: "фото магазина не читается", MsgUz: "doʻkon rasmi oʻqilmadi"}
	}
	size := ""
	if o.Size > 1000 {
		size = "2K"
	}
	prompt := photoPrompt(o, product)
	if len(images) > 1 {
		prompt += fmt.Sprintf("\nThese %d photos show the same product from different sides (for example the front and the label). Use them together and return ONE photo of the front side of the product.", len(images))
	}
	actx, cancel := context.WithTimeout(ctx, photoTimeout)
	img, u, err := c.GenerateImage(actx, ImageAsk{Prompt: prompt, Images: images, Aspect: "1:1", Size: size, Search: o.WebSearch && product != ""})
	cancel()
	if u.Input+u.Output > 0 || err == nil {
		cost := ImageCostUSD(c.Model, u, err == nil)
		rec := UsageRecord{Kind: "photo_store", NetworkID: &j.NetworkID, StoreID: j.StoreID, EmployeeID: j.employeeID, ProductID: j.ProductID,
			Provider: c.Provider, Model: c.Model, Usage: u, OK: err == nil, CostUSD: &cost}
		if rerr := s.ai.Record(context.WithoutCancel(ctx), rec); rerr != nil {
			s.log.Error("ai usage", "kind", rec.Kind, "err", rerr)
		}
	}
	if err != nil {
		return "", err
	}
	out, _, err := render(img.Data, o)
	if err != nil {
		return "", &ErrService{Msg: err.Error(), MsgUz: "Gemini yuborgan rasmni oʻqib boʻlmadi"}
	}
	return s.media.Upload(ctx, out)
}

// storeProduct — название, бренд и штрихкод для подсказки Gemini.
func (s *PhotoService) storeProduct(ctx context.Context, j storeJob) (string, error) {
	var name, brand, barcode string
	var err error
	switch {
	case j.ProductID != nil:
		err = s.ai.pool.QueryRow(ctx, `
			SELECT p.name, COALESCE(b.name, ''), COALESCE((SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), '')
			FROM products p LEFT JOIN brands b ON b.id = p.brand_id WHERE p.id = $1`, *j.ProductID).Scan(&name, &brand, &barcode)
	case j.NewItemID != nil:
		err = s.ai.pool.QueryRow(ctx, `SELECT COALESCE(result->>'name', ''), COALESCE(result->>'brand', ''), barcode FROM start_new_items WHERE id = $1`,
			*j.NewItemID).Scan(&name, &brand, &barcode)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return "", &ErrService{Msg: "товар удалён", MsgUz: "mahsulot oʻchirilgan"}
	}
	if err != nil || strings.TrimSpace(name) == "" {
		return "", err
	}
	return productLine(name, brand, barcode), nil
}

// Quota — фото Super Market в этом месяце для сети.
func (s *PhotoService) Quota(ctx context.Context, networkID string) (StoreQuota, error) {
	var q StoreQuota
	r, err := s.load(ctx)
	if err != nil {
		return q, err
	}
	q.Enabled = r.storeOn()
	if err := s.ai.pool.QueryRow(ctx, StoreUsedSQL, networkID).Scan(&q.Used); err != nil {
		return q, err
	}
	if s.Limit != nil {
		if q.Limit, err = s.Limit(ctx, s.ai.pool, networkID); err != nil {
			return q, err
		}
	}
	now := s.ai.now().In(tashkent)
	q.ResetsOn = time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, tashkent).AddDate(0, 1, 0).Format("2006-01-02")
	return q, nil
}

// storeMonth — расход «Фото для магазинов» в этом месяце и топ сетей.
func (s *PhotoService) storeMonth(ctx context.Context, out *PhotoSettings) error {
	// Не вышло — по заданиям: Gemini, упавший без ответа, в расход не попадает.
	err := s.ai.pool.QueryRow(ctx, `
		SELECT (count(*) FILTER (WHERE ok))::int, COALESCE(sum(cost) FILTER (WHERE currency = 'USD'), 0)::float8,
		       (SELECT count(*) FROM photo_jobs WHERE status = 'failed' AND created_at >= `+monthStartSQL+`)::int,
		       (SELECT count(DISTINCT network_id) FROM photo_jobs WHERE `+storeJobCounted+` AND created_at >= `+monthStartSQL+`)::int
		FROM ai_usage WHERE kind = 'photo_store' AND at >= `+monthStartSQL).
		Scan(&out.StorePhotos, &out.StoreCostUSD, &out.StoreFailed, &out.StoreNetworks)
	if err != nil {
		return err
	}
	rows, err := s.ai.pool.Query(ctx, `
		SELECT u.network_id::text, min(n.name), (count(*) FILTER (WHERE u.ok))::int, COALESCE(sum(u.cost) FILTER (WHERE u.currency = 'USD'), 0)::float8
		FROM ai_usage u JOIN networks n ON n.id = u.network_id
		WHERE u.kind = 'photo_store' AND u.at >= `+monthStartSQL+`
		GROUP BY u.network_id ORDER BY count(*) DESC, 1 LIMIT 5`)
	if err != nil {
		return err
	}
	if out.StoreTop, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (StoreTop, error) {
		var t StoreTop
		return t, r.Scan(&t.NetworkID, &t.Name, &t.Photos, &t.CostUSD)
	}); err != nil {
		return err
	}
	for i := range out.StoreTop {
		t := &out.StoreTop[i]
		if err := s.ai.pool.QueryRow(ctx, StoreUsedSQL, t.NetworkID).Scan(&t.Used); err != nil {
			return err
		}
		if s.Limit != nil {
			if t.Limit, err = s.Limit(ctx, s.ai.pool, t.NetworkID); err != nil {
				return err
			}
		}
	}
	return nil
}

// JobState — задание для магазина: что показать на миниатюре.
//   - processing — Super Market делает фото (queued и processing);
//   - done — готово (Image — ключ готового фото);
//   - failed — не вышло, осталось фото магазина;
//   - limit — лимит тарифа на месяц кончился, осталось фото магазина.
//
// Пропущенные по другим причинам не показываются ("").
func JobState(status, errText string) string {
	switch status {
	case JobQueued, JobProcessing:
		return JobProcessing
	case JobDone:
		return JobDone
	case JobFailed:
		return JobFailed
	case JobSkipped:
		if errText == SkipLimit {
			return SkipLimit
		}
	}
	return ""
}
