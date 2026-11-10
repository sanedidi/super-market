package ai

// Фото из сети (Figma «Супер-админ · Фото из сети — «чужие» фото каталога
// заменяются настоящими», ФС1–ФС3).
//
// В общем каталоге много фото не того товара: из каталога ИКПУ приходят
// чертежи из сертификации, крышка банки, оборот со штрихкодом. Super Market
// сам проверяет первое фото каждого товара общего каталога:
//
//  1. Проверка — Gemini (текстовая модель, дёшево): тот ли товар на фото и
//     лицевая ли сторона. Ответ: ok / back / top / drawing / wrong / blurry / none.
//  2. Поиск — Open Food Facts по штрихкоду (бесплатно), потом картинки Google
//     через Serper (ключ супер-админа). До webMaxCandidates кандидатов.
//  3. Сверка — Gemini сравнивает кандидатов с названием, брендом, объёмом.
//     Совпало — лучший; нет — оборот и крышку делаем из своего фото
//     (правило «лицевая сторона»), остальное — «Не нашли».
//  4. Чистое фото — обычная нормализация («Настройки»: фон, размер).
//     web_auto — ставится товару вместо плохого сразу, иначе ждёт решения.
//
// Задания — в photo_web_jobs (одна строка на товар). Новые товары идут
// первыми (вся база — по webBackfillBatch за проход). Расход — ai_usage:
// photo_web (Gemini) и web_search (Serper); дошли до лимита месяца — пауза.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// Статусы photo_web_jobs.
const (
	WebQueued     = "queued"
	WebProcessing = "processing"
	WebOK         = "ok"
	WebReplaced   = "replaced"
	WebPending    = "pending"
	WebNotFound   = "not_found"
	WebFailed     = "failed"
	WebReverted   = "reverted"
)

const (
	DefaultOFFURL    = "https://world.openfoodfacts.org"
	DefaultSerperURL = "https://google.serper.dev"

	// SerperCostUSD — цена одного поиска картинок у Serper.
	SerperCostUSD = 0.001

	webPoll          = 20 * time.Second
	webBackfillBatch = 30
	webParallel      = 3
	webStale         = 15 * time.Minute
	// WebMaxAttempts — сколько раз искать («Не нашли» — раз в сутки).
	WebMaxAttempts   = 3
	webRetryNotFound = 24 * time.Hour
	webMaxErrors     = 5
	webErrorPause    = 2 * time.Minute
	webMaxCandidates = 5
	webFetchTimeout  = 15 * time.Second
	webModelTTL      = 6 * time.Hour
)

// webBadReasons — фото плохое: ищем замену.
var webBadReasons = map[string]bool{"back": true, "top": true, "drawing": true, "wrong": true, "blurry": true, "none": true}

// webOwnReasons — товар на фото есть, только не той стороной: если в сети не
// нашли, делаем лицевую сторону из своего фото.
var webOwnReasons = map[string]bool{"back": true, "top": true, "blurry": true}

// webReasonText — подпись по умолчанию (Gemini присылает свою).
var webReasonText = map[string]string{
	"ok":      "Фото в порядке",
	"back":    "Оборот: штрихкод и состав",
	"top":     "Видна только крышка",
	"drawing": "Чертёж, а не фото",
	"wrong":   "Не тот товар",
	"blurry":  "Не разобрать: размыто или темно",
	"none":    "Товара нет на фото",
}

// WebSettings — блок 6 «Фото из сети» (в PhotoSettings.Web).
type WebSettings struct {
	Check       bool    `json:"check"`
	Auto        bool    `json:"auto"`
	LimitUSD    float64 `json:"limit_usd"`
	HasSerper   bool    `json:"has_serper"`
	SerperLast4 string  `json:"serper_last4"`
	// CheckModel — модель для проверки, если задана вручную; пусто — подбирается.
	CheckModel string `json:"check_model"`
	// Rest — остальной каталог (товары, которых нет ни в одном магазине) одобрен;
	// пока false — проверяются только товары магазинов.
	Rest bool `json:"rest"`
}

// WebSettingsInput — PUT /admin/ai-photo/web; nil — не менять.
// serper_key: новый ключ; пустая строка — убрать ключ.
type WebSettingsInput struct {
	Check      *bool    `json:"check"`
	Auto       *bool    `json:"auto"`
	LimitUSD   *float64 `json:"limit_usd"`
	SerperKey  *string  `json:"serper_key"`
	CheckModel *string  `json:"check_model"`
	Rest       *bool    `json:"rest"`
}

// webWorker — состояние воркера «Фото из сети» (в PhotoService).
type webWorker struct {
	once  sync.Once
	wake  chan struct{}
	runMu sync.Mutex

	modelMu sync.Mutex
	model   string // подобранная модель проверки
	modelAt time.Time
	modelOf string // для какого подключения подбирали
}

type webRow struct {
	WebSettings
	serperEnc []byte
}

func (s *PhotoService) webLoad(ctx context.Context) (webRow, error) {
	var r webRow
	err := s.ai.pool.QueryRow(ctx, `
		SELECT web_check, web_auto, web_limit_usd::float8, serper_key_enc, serper_last4, web_check_model, web_rest FROM ai_photo_settings`).
		Scan(&r.Check, &r.Auto, &r.LimitUSD, &r.serperEnc, &r.SerperLast4, &r.CheckModel, &r.Rest)
	r.HasSerper = len(r.serperEnc) > 0
	return r, err
}

// SaveWeb — блок «Фото из сети».
func (s *PhotoService) SaveWeb(ctx context.Context, adminID string, in WebSettingsInput) (PhotoSettings, error) {
	r, err := s.webLoad(ctx)
	if err != nil {
		return PhotoSettings{}, err
	}
	if in.Check != nil {
		r.Check = *in.Check
	}
	if in.Auto != nil {
		r.Auto = *in.Auto
	}
	if in.LimitUSD != nil {
		if *in.LimitUSD < 0 || *in.LimitUSD > 100000 || *in.LimitUSD != *in.LimitUSD {
			return PhotoSettings{}, apperr.Validation("limit_usd: от 0 до 100 000 $").Uz("limit_usd: 0 dan 100 000 $ gacha")
		}
		r.LimitUSD = *in.LimitUSD
	}
	if in.Rest != nil {
		r.Rest = *in.Rest
	}
	if in.CheckModel != nil {
		m := strings.TrimSpace(*in.CheckModel)
		if len(m) > 200 {
			return PhotoSettings{}, apperr.Validation("check_model: слишком длинное название").Uz("check_model: nomi juda uzun")
		}
		r.CheckModel = m
	}
	if in.SerperKey != nil {
		k := strings.TrimSpace(*in.SerperKey)
		switch {
		case k == "":
			r.serperEnc, r.SerperLast4 = nil, ""
		case len(k) > 200 || strings.ContainsAny(k, " \n\t"):
			return PhotoSettings{}, apperr.Validation("serper_key: неверный ключ").Uz("serper_key: kalit notoʻgʻri")
		default:
			r.serperEnc, r.SerperLast4 = s.ai.seal(k), last4(k)
		}
	}
	_, err = s.ai.pool.Exec(ctx, `
		UPDATE ai_photo_settings SET web_check = $1, web_auto = $2, web_limit_usd = $3, serper_key_enc = $4, serper_last4 = $5,
		       web_check_model = $6, web_rest = $8, updated_by = $7, updated_at = now()`,
		r.Check, r.Auto, r.LimitUSD, r.serperEnc, r.SerperLast4, r.CheckModel, adminID, r.Rest)
	if err != nil {
		return PhotoSettings{}, err
	}
	s.webWorker.modelMu.Lock()
	s.webWorker.model = ""
	s.webWorker.modelMu.Unlock()
	s.KickWeb()
	return s.Get(ctx)
}

// ------------------------------------------------------------------ воркер

// KickWeb — разбудить воркер; в тестах (Sync) — пройти очередь сразу.
func (s *PhotoService) KickWeb() {
	if s.Sync {
		s.RunWeb(context.Background())
		return
	}
	s.webWorker.once.Do(s.initWebWorker)
	select {
	case s.webWorker.wake <- struct{}{}:
	default:
	}
}

func (s *PhotoService) initWebWorker() { s.webWorker.wake = make(chan struct{}, 1) }

// StartWebWorker — фоновый воркер «Фото из сети»: раз в webPoll и по KickWeb.
func (s *PhotoService) StartWebWorker(ctx context.Context) {
	s.webWorker.once.Do(s.initWebWorker)
	go func() {
		t := time.NewTicker(webPoll)
		defer t.Stop()
		for {
			s.RunWeb(ctx)
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			case <-s.webWorker.wake:
			}
		}
	}()
}

// RunWeb — один проход: новые товары в очередь, очередь — до конца (или до лимита).
func (s *PhotoService) RunWeb(ctx context.Context) {
	defer func() {
		if p := recover(); p != nil {
			s.log.Error("фото из сети: паника", "panic", p)
		}
	}()
	s.webWorker.runMu.Lock()
	defer s.webWorker.runMu.Unlock()
	r, err := s.load(ctx)
	if err != nil || !r.Configured {
		return
	}
	w, err := s.webLoad(ctx)
	if err != nil {
		s.log.Error("фото из сети: настройки", "err", err)
		return
	}
	if w.Check {
		if err := s.webBackfill(ctx); err != nil {
			s.log.Error("фото из сети: очередь", "err", err)
		}
	}
	done := make(chan struct{}, webParallel)
	running := 0
	for {
		for running < webParallel && ctx.Err() == nil {
			if spent, err := s.webMonthCost(ctx); err != nil || spent >= w.LimitUSD {
				break
			}
			j, ok, err := s.webClaim(ctx, w.Check, w.Rest)
			if err != nil {
				s.log.Error("фото из сети: очередь", "err", err)
				break
			}
			if !ok {
				break
			}
			running++
			go func(j webJob) {
				defer func() { done <- struct{}{} }()
				defer func() {
					if p := recover(); p != nil {
						s.log.Error("фото из сети: паника", "id", j.ID, "panic", p)
						s.webError(context.Background(), j, errors.New("внутренняя ошибка"))
					}
				}()
				s.webRun(ctx, r, w, j)
			}(j)
		}
		if running == 0 {
			return
		}
		<-done
		running--
		// Новые товары, пока шла очередь, — следующим проходом.
	}
}

// webBackfill — товары общего каталога с фото, которых ещё не проверяли:
// сначала те, что есть в магазинах, среди них — новые первыми.
func (s *PhotoService) webBackfill(ctx context.Context) error {
	_, err := s.ai.pool.Exec(ctx, `
		INSERT INTO photo_web_jobs (product_id, old_image)
		SELECT p.id, p.images[1] FROM products p
		WHERE p.network_id IS NULL AND p.is_active AND cardinality(p.images) > 0
		  AND NOT EXISTS (SELECT 1 FROM photo_web_jobs j WHERE j.product_id = p.id)
		ORDER BY EXISTS (SELECT 1 FROM store_products sp WHERE sp.product_id = p.id) DESC, p.created_at DESC, p.id
		LIMIT $1
		ON CONFLICT (product_id) DO NOTHING`, webBackfillBatch)
	return err
}

// webMonthCost — расход «Фото из сети» в этом месяце, USD.
func (s *PhotoService) webMonthCost(ctx context.Context) (float64, error) {
	var v float64
	err := s.ai.pool.QueryRow(ctx, `SELECT COALESCE(sum(cost), 0)::float8 FROM ai_usage
		WHERE kind IN ('photo_web', 'web_search') AND currency = 'USD' AND at >= `+monthStartSQL).Scan(&v)
	return v, err
}

// webJob — задание в работе.
type webJob struct {
	ID         string
	ProductID  string
	Reason     string
	ReasonText string
	OldImage   string
	PickKey    string
	PickSource string
	SearchPage int
	Attempts   int
	Errors     int
}

// webClaim — взять одно задание. Выключенная проверка — только то, что
// поставил супер-админ. «Не нашли» — снова, когда подошло время.
// Порядок: что поставил супер-админ, потом товары, которые есть в магазинах;
// остальной каталог — только когда он одобрен (rest).
func (s *PhotoService) webClaim(ctx context.Context, check, rest bool) (webJob, bool, error) {
	var j webJob
	err := s.ai.pool.QueryRow(ctx, `
		UPDATE photo_web_jobs SET status = 'processing', started_at = now(), updated_at = now()
		WHERE id = (
			SELECT id FROM photo_web_jobs
			WHERE next_at <= now() AND ($2 OR manual)
			  AND (status = 'queued'
			       OR (status = 'not_found' AND attempts < $3)
			       OR (status = 'processing' AND started_at < now() - $1::interval))
			  AND ($4 OR manual OR EXISTS (SELECT 1 FROM store_products sp WHERE sp.product_id = photo_web_jobs.product_id))
			ORDER BY manual DESC, EXISTS (SELECT 1 FROM store_products sp WHERE sp.product_id = photo_web_jobs.product_id) DESC,
			         (status = 'queued') DESC, created_at DESC, id
			LIMIT 1 FOR UPDATE SKIP LOCKED)
		RETURNING id::text, product_id::text, reason, reason_text, old_image, pick_key, pick_source, search_page, attempts, errors`,
		webStale.String(), check, WebMaxAttempts, rest).
		Scan(&j.ID, &j.ProductID, &j.Reason, &j.ReasonText, &j.OldImage, &j.PickKey, &j.PickSource, &j.SearchPage, &j.Attempts, &j.Errors)
	if errors.Is(err, pgx.ErrNoRows) {
		return j, false, nil
	}
	return j, err == nil, err
}

// webError — ошибка: временная — повторим через webErrorPause (до webMaxErrors), иначе failed.
func (s *PhotoService) webError(ctx context.Context, j webJob, err error) {
	msg := cut(err.Error())
	var se *ErrService
	temporary := errors.As(err, &se) && (se.Temporary || se.Status == http.StatusTooManyRequests || se.Status >= 500)
	if temporary && j.Errors+1 < webMaxErrors {
		_, e := s.ai.pool.Exec(ctx, `UPDATE photo_web_jobs SET status = 'queued', errors = errors + 1, error = $2,
			next_at = now() + $3::interval, updated_at = now() WHERE id = $1`, j.ID, msg, webErrorPause.String())
		if e != nil {
			s.log.Error("фото из сети: ошибка", "id", j.ID, "err", e)
		}
		return
	}
	_, e := s.ai.pool.Exec(ctx, `UPDATE photo_web_jobs SET status = 'failed', errors = errors + 1, error = $2, manual = false,
		finished_at = now(), updated_at = now() WHERE id = $1`, j.ID, msg)
	if e != nil {
		s.log.Error("фото из сети: ошибка", "id", j.ID, "err", e)
	}
}

// webProduct — товар для проверки.
type webProduct struct {
	Name, Brand, Barcode, Volume string
	Images                       []string
}

func (p webProduct) line() string { return productLine(p.Name, p.Brand, p.Barcode) }

func (s *PhotoService) webProductOf(ctx context.Context, id string) (webProduct, error) {
	var p webProduct
	err := s.ai.pool.QueryRow(ctx, `
		SELECT p.name, COALESCE(b.name, ''), COALESCE((SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), ''), p.images
		FROM products p LEFT JOIN brands b ON b.id = p.brand_id WHERE p.id = $1`, id).Scan(&p.Name, &p.Brand, &p.Barcode, &p.Images)
	return p, err
}

// webRun — одно задание от проверки до готового фото.
func (s *PhotoService) webRun(ctx context.Context, r photoRow, w webRow, j webJob) {
	p, err := s.webProductOf(ctx, j.ProductID)
	if errors.Is(err, pgx.ErrNoRows) {
		return // товар удалили — строка ушла каскадом
	}
	if err != nil {
		s.webError(ctx, j, err)
		return
	}
	if j.OldImage == "" || !contains(p.Images, j.OldImage) {
		if len(p.Images) == 0 && j.PickKey == "" {
			s.webFinish(ctx, j.ID, WebOK, "", nil)
			return
		}
		if len(p.Images) > 0 && j.Reason == "" {
			j.OldImage = p.Images[0]
		}
	}
	c, o, _, err := s.conn(ctx, PhotoInput{})
	if err != nil {
		s.webError(ctx, j, err)
		return
	}
	cost := 0.0
	defer func() {
		if cost > 0 {
			_, _ = s.ai.pool.Exec(context.WithoutCancel(ctx), `UPDATE photo_web_jobs SET cost_usd = cost_usd + $2, model = $3 WHERE id = $1`, j.ID, cost, c.Model)
		}
	}()
	record := func(kind, provider, model string, u Usage, ok bool, usd float64) {
		cost += usd
		rec := UsageRecord{Kind: kind, ProductID: &j.ProductID, Provider: provider, Model: model, Usage: u, OK: ok, CostUSD: &usd}
		if e := s.ai.Record(context.WithoutCancel(ctx), rec); e != nil {
			s.log.Error("ai usage", "kind", kind, "err", e)
		}
	}

	// Выбранное супер-админом (из найденных или своё) — сразу в чистое фото.
	if j.PickKey != "" {
		src, err := s.webImage(ctx, j.PickKey)
		if err != nil {
			s.webError(ctx, j, err)
			return
		}
		found, ours := media.KeyFromURL(j.PickKey)
		if !ours {
			if found, err = s.media.Upload(ctx, src.Data); err != nil {
				s.webError(ctx, j, err)
				return
			}
		}
		s.webFinal(ctx, c, o, w, j, p, src, j.PickSource, found, "", nil, record)
		return
	}

	var old Image
	oldErr := errors.New("нет фото")
	if j.OldImage != "" {
		old, oldErr = s.webImage(ctx, j.OldImage)
	}
	// 1. Проверка.
	if j.Reason == "" {
		if oldErr != nil {
			// Старое фото не читается — считаем, что его нет.
			j.Reason, j.ReasonText = "none", "Фото не открывается"
		} else {
			tc := s.webCheckConn(ctx, c, w)
			reason, text, u, err := tc.webCheck(ctx, p, old)
			if u.Input+u.Output > 0 || err == nil {
				record("photo_web", tc.Provider, tc.Model, u, err == nil, textCostUSD(tc.Model, u))
			}
			if err != nil {
				var se *ErrService
				if errors.As(err, &se) && se.Status == http.StatusNotFound && tc.Model != c.Model {
					s.webForgetModel()
				}
				s.webError(ctx, j, err)
				return
			}
			j.Reason, j.ReasonText = reason, text
		}
		if _, err := s.ai.pool.Exec(ctx, `UPDATE photo_web_jobs SET reason = $2, reason_text = $3, old_image = $4, error = '', updated_at = now() WHERE id = $1`,
			j.ID, j.Reason, j.ReasonText, j.OldImage); err != nil {
			s.webError(ctx, j, err)
			return
		}
	}
	if !webBadReasons[j.Reason] {
		s.webFinish(ctx, j.ID, WebOK, "", nil)
		return
	}

	// 2. Поиск.
	cands, searchErr := s.webSearch(ctx, w, p, j.SearchPage, record)
	// 3. Сверка.
	best := -1
	verdict := map[string]any{}
	if len(cands) > 0 {
		tc := s.webCheckConn(ctx, c, w)
		var u Usage
		best, verdict, u, err = tc.webVerify(ctx, p, cands)
		if u.Input+u.Output > 0 || err == nil {
			record("photo_web", tc.Provider, tc.Model, u, err == nil, textCostUSD(tc.Model, u))
		}
		if err != nil {
			s.webError(ctx, j, err)
			return
		}
		if best >= 0 && cands[best].Source == "off" {
			verdict["barcode"] = true
		}
	}
	candJSON := webCandidatesJSON(cands, best)
	if best >= 0 {
		key, err := s.media.Upload(ctx, cands[best].img.Data)
		if err != nil {
			s.webError(ctx, j, err)
			return
		}
		s.webFinal(ctx, c, o, w, j, p, cands[best].img, cands[best].Source, key, cands[best].Page, map[string]any{"candidates": candJSON, "verdict": verdict}, record)
		return
	}
	if webOwnReasons[j.Reason] && oldErr == nil {
		s.webFinal(ctx, c, o, w, j, p, old, "own", "", "", map[string]any{"candidates": candJSON, "verdict": verdict}, record)
		return
	}
	// Не нашли: ещё раз через сутки (до WebMaxAttempts).
	note := "Не нашли ни по штрихкоду, ни в Google"
	if searchErr != nil {
		note = searchErr.Error()
	}
	_, err = s.ai.pool.Exec(ctx, `
		UPDATE photo_web_jobs SET status = 'not_found', attempts = attempts + 1, manual = false, candidates = $2, verdict = $3,
		       search_page = LEAST(search_page + 1, 10),
		       error = $4, next_at = now() + $5::interval, finished_at = now(), updated_at = now()
		WHERE id = $1`, j.ID, candJSON, verdict, cut(note), webRetryNotFound.String())
	if err != nil {
		s.log.Error("фото из сети: не нашли", "id", j.ID, "err", err)
	}
}

// webFinal — чистое фото из src и замена (или «ждёт решения»).
func (s *PhotoService) webFinal(ctx context.Context, c Conn, o photoOpts, w webRow, j webJob, p webProduct, src Image, source, found, page string,
	extra map[string]any, record func(kind, provider, model string, u Usage, ok bool, usd float64)) {
	in, err := shrinkForModel(src.Data, src.MIME)
	if err != nil {
		s.webError(ctx, j, &ErrService{Msg: "найденное фото не читается"})
		return
	}
	size := ""
	if o.Size > 1000 {
		size = "2K"
	}
	prompt := photoPrompt(o, p.line())
	if source != "own" {
		prompt += "\nThe photo was found on the internet: remove any text overlays, watermarks, price tags, other products and the background; keep only the product itself."
	}
	actx, cancel := context.WithTimeout(ctx, photoTimeout)
	img, u, err := c.GenerateImage(actx, ImageAsk{Prompt: prompt, Images: []Image{in}, Aspect: "1:1", Size: size, Search: o.WebSearch && p.Name != "", Quality: o.Quality})
	cancel()
	if u.Input+u.Output > 0 || err == nil {
		record("photo_web", c.Provider, c.Model, u, err == nil, ImageCostUSD(c.Model, u, err == nil))
	}
	if err != nil {
		s.webError(ctx, j, err)
		return
	}
	out, _, err := render(img.Data, o)
	if err != nil {
		s.webError(ctx, j, &ErrService{Msg: err.Error()})
		return
	}
	key, err := s.media.Upload(ctx, out)
	if err != nil {
		s.webError(ctx, j, err)
		return
	}
	set := map[string]any{"found_source": source, "found_url": found, "found_page": page, "result": key}
	for k, v := range extra {
		set[k] = v
	}
	status := WebPending
	// Выбор супер-админа ставится сразу; прежнее готовое фото этого задания — заменяется.
	if w.Auto || j.PickKey != "" {
		status = WebReplaced
	}
	var prev string
	_ = s.ai.pool.QueryRow(ctx, `SELECT result FROM photo_web_jobs WHERE id = $1`, j.ID).Scan(&prev)
	err = s.webSave(ctx, j.ID, status, set, func(tx pgx.Tx) error {
		if status != WebReplaced {
			return nil
		}
		return s.webPut(ctx, tx, j.ProductID, j.OldImage, prev, key)
	})
	if err != nil {
		s.log.Error("фото из сети: готовое фото", "id", j.ID, "err", err)
		s.webError(ctx, j, err)
	}
}

// webPut — новое фото товару вместо старого или прежнего готового (их уже нет — первым).
func (s *PhotoService) webPut(ctx context.Context, tx pgx.Tx, productID, old, prev, key string) error {
	var images []string
	if err := tx.QueryRow(ctx, `SELECT images FROM products WHERE id = $1 FOR UPDATE`, productID).Scan(&images); err != nil {
		return err
	}
	newURL := s.webURL(media.BaseOf(old), key)
	out := make([]string, 0, len(images)+1)
	replaced := false
	for _, u := range images {
		switch {
		case !replaced && ((old != "" && u == old) || (prev != "" && strings.HasSuffix(u, "/"+prev))):
			out = append(out, newURL)
			replaced = true
		case u == newURL, old != "" && u == old, prev != "" && strings.HasSuffix(u, "/"+prev):
		default:
			out = append(out, u)
		}
	}
	if !replaced {
		out = append([]string{newURL}, out...)
	}
	_, err := tx.Exec(ctx, `UPDATE products SET images = $2, updated_at = now() WHERE id = $1`, productID, out)
	return err
}

// webURL — ссылка на фото из хранилища.
func (s *PhotoService) webURL(base, key string) string {
	if u := s.media.URLWithBase(base, key); u != "" {
		return u
	}
	return "/api/v1/media/" + key
}

// webSave — записать итог задания (и что-то ещё в той же транзакции).
func (s *PhotoService) webSave(ctx context.Context, id, status string, set map[string]any, also func(pgx.Tx) error) error {
	tx, err := s.ai.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	cols := []string{"status = $2", "manual = false", "pick_key = ''", "pick_source = ''", "error = ''", "finished_at = now()", "updated_at = now()"}
	args := []any{id, status}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		args = append(args, set[k])
		cols = append(cols, k+" = $"+strconv.Itoa(len(args)))
	}
	if _, err := tx.Exec(ctx, `UPDATE photo_web_jobs SET `+strings.Join(cols, ", ")+` WHERE id = $1`, args...); err != nil {
		return err
	}
	if also != nil {
		if err := also(tx); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func (s *PhotoService) webFinish(ctx context.Context, id, status, reason string, set map[string]any) {
	if set == nil {
		set = map[string]any{}
	}
	if reason != "" {
		set["reason"] = reason
	}
	if err := s.webSave(ctx, id, status, set, nil); err != nil {
		s.log.Error("фото из сети: итог", "id", id, "err", err)
	}
}

// webImage — фото по ссылке: наше — из хранилища, чужое — скачать.
func (s *PhotoService) webImage(ctx context.Context, raw string) (Image, error) {
	if key, ok := media.KeyFromURL(raw); ok {
		data, mime, err := s.media.Read(ctx, key)
		if err != nil {
			return Image{}, &ErrService{Msg: "фото не найдено в хранилище"}
		}
		return Image{MIME: mime, Data: data}, nil
	}
	return s.webFetch(ctx, raw)
}

// ------------------------------------------------------------------ Gemini

// webCheckConn — подключение для проверки и сверки: текстовая модель Gemini
// (дешевле картинок). Задана вручную — она; иначе подбирается по списку
// моделей ключа; не нашлась — та же модель, что рисует фото.
func (s *PhotoService) webCheckConn(ctx context.Context, c Conn, w webRow) Conn {
	tc := c
	if w.CheckModel != "" {
		tc.Model = w.CheckModel
		return tc
	}
	of := c.Provider + "|" + c.BaseURL
	s.webWorker.modelMu.Lock()
	defer s.webWorker.modelMu.Unlock()
	if s.webWorker.model != "" && s.webWorker.modelOf == of && time.Since(s.webWorker.modelAt) < webModelTTL {
		tc.Model = s.webWorker.model
		return tc
	}
	m := ""
	switch c.Provider {
	case ProviderVertex:
		m = "gemini-2.5-flash"
	case ProviderOpenAI:
		ids, err := c.openaiModelIDs(ctx)
		if err != nil {
			s.log.Warn("фото из сети: список моделей", "err", err)
		}
		m = pickOpenAICheckModel(ids)
		if m == "" {
			m = "gpt-4o-mini"
		}
	default:
		ids, err := c.geminiModelIDs(ctx)
		if err != nil {
			s.log.Warn("фото из сети: список моделей", "err", err)
		}
		m = pickCheckModel(ids)
	}
	if m == "" {
		m = c.Model
	}
	s.webWorker.model, s.webWorker.modelOf, s.webWorker.modelAt = m, of, time.Now()
	tc.Model = m
	return tc
}

func (s *PhotoService) webForgetModel() {
	s.webWorker.modelMu.Lock()
	s.webWorker.model = ""
	s.webWorker.modelMu.Unlock()
}

// geminiModelIDs — модели Gemini API с generateContent.
func (c Conn) geminiModelIDs(ctx context.Context) ([]string, error) {
	var out struct {
		Models []struct {
			Name    string   `json:"name"`
			Methods []string `json:"supportedGenerationMethods"`
		} `json:"models"`
	}
	if err := c.do(ctx, http.MethodGet, "/models?pageSize=1000", nil, &out); err != nil {
		return nil, err
	}
	ids := []string{}
	for _, m := range out.Models {
		gen := len(m.Methods) == 0
		for _, x := range m.Methods {
			gen = gen || x == "generateContent"
		}
		if gen {
			ids = append(ids, strings.TrimPrefix(m.Name, "models/"))
		}
	}
	return ids, nil
}

var geminiVersionRe = regexp.MustCompile(`^gemini-(\d+(?:\.\d+)?)-flash`)

// pickCheckModel — самая новая стабильная Gemini Flash (не Lite, не картинки, не голос).
func pickCheckModel(ids []string) string {
	best, bestScore := "", -1.0
	for _, id := range ids {
		l := strings.ToLower(id)
		m := geminiVersionRe.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		bad := false
		for _, x := range []string{"image", "lite", "tts", "audio", "live", "embedding", "thinking", "exp", "8b"} {
			bad = bad || strings.Contains(l, x)
		}
		if bad {
			continue
		}
		v, _ := strconv.ParseFloat(m[1], 64)
		score := v
		if strings.Contains(l, "preview") {
			score -= 0.6
		}
		if score > bestScore || (score == bestScore && len(id) < len(best)) {
			best, bestScore = id, score
		}
	}
	return best
}

// textPrices — прайс Google для текстовых моделей (USD за 1 млн токенов).
var textPrices = []struct {
	match   string
	in, out float64
}{
	// OpenAI (проверка фото при способе openai).
	{"gpt-4o-mini", 0.15, 0.6},
	{"nano", 0.05, 0.4},
	{"-mini", 0.25, 2},
	{"2.5-flash-lite", 0.1, 0.4},
	{"2.5-flash", 0.3, 2.5},
	{"flash", 0.5, 3},
	{"pro", 2, 12},
}

// textCostUSD — цена проверки или сверки; модель, которая рисует, — по прайсу картинок.
func textCostUSD(model string, u Usage) float64 {
	if IsImageModel(model) {
		return ImageCostUSD(model, Usage{Input: u.Input, Output: u.Output}, false)
	}
	m := strings.ToLower(model)
	in, out := 0.5, 3.0
	for _, p := range textPrices {
		if strings.Contains(m, p.match) {
			in, out = p.in, p.out
			break
		}
	}
	return (float64(max(u.Input, 0))*in + float64(max(u.Output, 0))*out) / 1e6
}

const webCheckPrompt = `You check product photos of an online grocery catalog.
The product: %s.
Look at the photo and answer only JSON: {"verdict": "...", "note": "..."}.
verdict:
"ok" — a real photo of this product (its package) where the front side with the brand or product name is clearly visible;
"back" — the package is shown from the back or a side: barcode, ingredients or a nutrition table instead of the front;
"top" — only the lid, the cap, the top or the bottom of the package is visible;
"drawing" — a technical drawing, a sketch, line art, a scheme, a label layout or a certificate instead of a photo;
"wrong" — a clearly different product or brand, or not a product at all (a document, a person, a shelf, only a logo);
"blurry" — the product is there but too blurry, dark or small to recognize;
"none" — there is no product in the photo.
If the product name is generic, judge only whether this is a real photo of a packaged product of that kind, front side.
note — a short reason in Russian, up to 50 characters, for example «Оборот: штрихкод и состав», «Видна только крышка», «Чертёж, а не фото».`

// webCheck — проверка фото товара.
func (c Conn) webCheck(ctx context.Context, p webProduct, old Image) (string, string, Usage, error) {
	if len(old.Data) == 0 {
		return "none", webReasonText["none"], Usage{}, nil
	}
	in, err := shrinkForModel(old.Data, old.MIME)
	if err != nil {
		return "none", "Фото не открывается", Usage{}, nil
	}
	text, u, err := c.Vision(ctx, "", fmt.Sprintf(webCheckPrompt, p.line()), []Image{in})
	if err != nil {
		return "", "", u, err
	}
	var out struct {
		Verdict string `json:"verdict"`
		Note    string `json:"note"`
	}
	raw, err := ExtractJSON(text)
	if err == nil {
		err = json.Unmarshal(raw, &out)
	}
	if err != nil {
		return "", "", u, &ErrService{Msg: "Gemini ответил не по форме при проверке фото", Temporary: true}
	}
	v := strings.ToLower(strings.TrimSpace(out.Verdict))
	if _, ok := webReasonText[v]; !ok {
		return "", "", u, &ErrService{Msg: "Gemini ответил не по форме при проверке фото: " + cut(v), Temporary: true}
	}
	note := strings.TrimSpace(out.Note)
	if r := []rune(note); len(r) > 60 || len(r) == 0 {
		note = webReasonText[v]
	}
	return v, note, u, nil
}

const webVerifyPrompt = `You pick a catalog photo for a product of an online grocery store.
The product: %s.
Photos 1..%d are candidates found on the internet. For each one decide whether it shows exactly this product: the same brand, the same product and flavor, the same package type, and the same size (volume or weight) when it is visible.
Reject: multipacks and boxes of several units (unless the product itself is a pack), different flavors or sizes, advertising banners and collages, photos with people or hands, drawings, very small or blurry photos.
Prefer a clean photo of one unit with its front side clearly visible.
Answer only JSON: {"best": <number of the best photo, 0 if none fits>, "seen_name": "<product name as printed on the best photo>", "name": true|false, "brand": true|false, "volume": true|false|null, "items": [{"n": 1, "ok": true|false, "note": "<short reason in Russian, up to 50 characters>"}]}`

// webVerify — сверка найденных фото с товаром: номер лучшего (−1 — ни одно).
func (c Conn) webVerify(ctx context.Context, p webProduct, cands []webCandidate) (int, map[string]any, Usage, error) {
	imgs := make([]Image, 0, len(cands))
	for _, cd := range cands {
		imgs = append(imgs, cd.img)
	}
	text, u, err := c.Vision(ctx, "", fmt.Sprintf(webVerifyPrompt, p.line(), len(cands)), imgs)
	if err != nil {
		return -1, nil, u, err
	}
	var out struct {
		Best     int    `json:"best"`
		SeenName string `json:"seen_name"`
		Name     *bool  `json:"name"`
		Brand    *bool  `json:"brand"`
		Volume   *bool  `json:"volume"`
		Items    []struct {
			N    int    `json:"n"`
			OK   bool   `json:"ok"`
			Note string `json:"note"`
		} `json:"items"`
	}
	raw, err := ExtractJSON(text)
	if err == nil {
		err = json.Unmarshal(raw, &out)
	}
	if err != nil {
		return -1, nil, u, &ErrService{Msg: "Gemini ответил не по форме при сверке фото", Temporary: true}
	}
	for _, it := range out.Items {
		if it.N >= 1 && it.N <= len(cands) {
			cands[it.N-1].OK = it.OK
			if n := []rune(strings.TrimSpace(it.Note)); len(n) > 0 {
				cands[it.N-1].Note = string(n[:min(len(n), 80)])
			}
		}
	}
	best := out.Best - 1
	if best < 0 || best >= len(cands) || (out.Name != nil && !*out.Name) || (out.Brand != nil && !*out.Brand && p.Brand != "") {
		best = -1
	}
	if best >= 0 {
		cands[best].OK = true
	}
	verdict := map[string]any{"seen_name": cutRunes(out.SeenName, 120), "name": out.Name, "brand": out.Brand, "volume": out.Volume, "barcode": nil}
	return best, verdict, u, nil
}

// ------------------------------------------------------------------ поиск

// webCandidate — найденное фото.
type webCandidate struct {
	URL    string `json:"url"`
	Source string `json:"source"` // off | google
	Page   string `json:"page"`
	Title  string `json:"title"`
	OK     bool   `json:"ok"`
	Note   string `json:"note"`
	Best   bool   `json:"best"`
	img    Image
}

func webCandidatesJSON(cands []webCandidate, best int) []webCandidate {
	out := make([]webCandidate, len(cands))
	copy(out, cands)
	for i := range out {
		out[i].Best = i == best
		out[i].img = Image{}
	}
	return out
}

// webSearch — Open Food Facts по штрихкоду, потом картинки Google (Serper).
func (s *PhotoService) webSearch(ctx context.Context, w webRow, p webProduct, page int,
	record func(kind, provider, model string, u Usage, ok bool, usd float64)) ([]webCandidate, error) {
	cands := []webCandidate{}
	if page <= 1 && barcodeRe.MatchString(p.Barcode) {
		if c, ok := s.offLookup(ctx, p.Barcode); ok {
			cands = append(cands, c)
		}
	}
	// Нашли по штрихкоду — это тот самый товар, Google не нужен.
	if len(cands) > 0 {
		return cands, nil
	}
	if !w.HasSerper {
		if len(cands) == 0 {
			return cands, errors.New("Не нашли в Open Food Facts; поиск в Google выключен — нет ключа Serper")
		}
		return cands, nil
	}
	key, err := s.ai.open(w.serperEnc)
	if err != nil {
		return cands, errors.New("ключ Serper не открывается — сохраните заново")
	}
	found, err := s.serperImages(ctx, key, webQuery(p), page)
	record("web_search", "serper", "images", Usage{}, err == nil, SerperCostUSD)
	if err != nil {
		if len(cands) == 0 {
			return cands, err
		}
		return cands, nil
	}
	// Скачиваем параллельно, порядок выдачи сохраняем.
	type got struct {
		i   int
		img Image
		err error
	}
	ch := make(chan got, len(found))
	for i, f := range found {
		go func(i int, u string) {
			img, err := s.webFetch(ctx, u)
			ch <- got{i, img, err}
		}(i, f.URL)
	}
	imgs := make([]Image, len(found))
	for range found {
		g := <-ch
		if g.err == nil {
			imgs[g.i] = g.img
		}
	}
	for i, f := range found {
		if len(cands) >= webMaxCandidates {
			break
		}
		if len(imgs[i].Data) == 0 {
			continue
		}
		f.img = imgs[i]
		cands = append(cands, f)
	}
	return cands, nil
}

var barcodeRe = regexp.MustCompile(`^\d{8,14}$`)

// webQuery — запрос в Google: бренд и название (бренд, если его нет в названии).
func webQuery(p webProduct) string {
	q := strings.TrimSpace(p.Name)
	if p.Brand != "" && !strings.Contains(strings.ToLower(q), strings.ToLower(p.Brand)) {
		q = p.Brand + " " + q
	}
	return cutRunes(q, 120)
}

func cutRunes(s string, n int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) > n {
		return string(r[:n])
	}
	return string(r)
}

// offLookup — Open Food Facts: фото лицевой стороны по штрихкоду.
func (s *PhotoService) offLookup(ctx context.Context, barcode string) (webCandidate, bool) {
	base := strings.TrimRight(s.OFFURL, "/")
	if base == "" {
		base = DefaultOFFURL
	}
	var out struct {
		Status  int `json:"status"`
		Product struct {
			Name  string `json:"product_name"`
			Brand string `json:"brands"`
			Front string `json:"image_front_url"`
			Image string `json:"image_url"`
		} `json:"product"`
	}
	if err := s.webJSON(ctx, http.MethodGet, base+"/api/v2/product/"+url.PathEscape(barcode)+".json?fields=product_name,brands,image_front_url,image_url", nil, nil, &out); err != nil {
		return webCandidate{}, false
	}
	u := out.Product.Front
	if u == "" {
		u = out.Product.Image
	}
	if out.Status != 1 || u == "" {
		return webCandidate{}, false
	}
	img, err := s.webFetch(ctx, u)
	if err != nil {
		return webCandidate{}, false
	}
	title := strings.TrimSpace(strings.TrimSpace(out.Product.Brand) + " " + strings.TrimSpace(out.Product.Name))
	return webCandidate{URL: u, Source: "off", Page: base + "/product/" + barcode, Title: cutRunes(title, 120), img: img}, true
}

// serperImages — картинки Google через Serper (до 10, без фото меньше 200 px).
func (s *PhotoService) serperImages(ctx context.Context, key, q string, page int) ([]webCandidate, error) {
	base := strings.TrimRight(s.SerperURL, "/")
	if base == "" {
		base = DefaultSerperURL
	}
	var out struct {
		Images []struct {
			Title  string `json:"title"`
			URL    string `json:"imageUrl"`
			Width  int    `json:"imageWidth"`
			Height int    `json:"imageHeight"`
			Link   string `json:"link"`
		} `json:"images"`
	}
	body := map[string]any{"q": q, "num": 10, "page": max(page, 1)}
	err := s.webJSON(ctx, http.MethodPost, base+"/images", map[string]string{"X-API-KEY": key}, body, &out)
	if err != nil {
		return nil, err
	}
	res := []webCandidate{}
	for _, im := range out.Images {
		if !strings.HasPrefix(im.URL, "https://") && !strings.HasPrefix(im.URL, "http://") {
			continue
		}
		if (im.Width > 0 && im.Width < 200) || (im.Height > 0 && im.Height < 200) || strings.HasSuffix(strings.ToLower(im.URL), ".svg") {
			continue
		}
		res = append(res, webCandidate{URL: im.URL, Source: "google", Page: im.Link, Title: cutRunes(im.Title, 120)})
		if len(res) >= webMaxCandidates+3 {
			break
		}
	}
	return res, nil
}

// webJSON — запрос к Open Food Facts или Serper.
func (s *PhotoService) webJSON(ctx context.Context, method, u string, hdr map[string]string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	ctx, cancel := context.WithTimeout(ctx, webFetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, u, rd)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "SuperMarket/1.0 (+https://super-market.uz)")
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := s.webClient().Do(req)
	if err != nil {
		return &ErrService{Msg: "поиск фото не ответил", Temporary: true}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return &ErrService{Status: resp.StatusCode, Msg: "поиск в Google: ключ Serper не подходит"}
	case resp.StatusCode == http.StatusTooManyRequests:
		return &ErrService{Status: resp.StatusCode, Msg: "поиск в Google: лимит запросов Serper", Temporary: true}
	case resp.StatusCode/100 != 2:
		return &ErrService{Status: resp.StatusCode, Msg: fmt.Sprintf("поиск фото ответил ошибкой %d", resp.StatusCode), Temporary: resp.StatusCode >= 500}
	}
	return json.Unmarshal(raw, out)
}

// webFetch — скачать фото из интернета: до 8 МБ, только картинка.
func (s *PhotoService) webFetch(ctx context.Context, u string) (Image, error) {
	pu, err := url.Parse(u)
	if err != nil || (pu.Scheme != "https" && pu.Scheme != "http") || pu.Host == "" {
		return Image{}, errors.New("неверная ссылка на фото")
	}
	ctx, cancel := context.WithTimeout(ctx, webFetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return Image{}, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; SuperMarket/1.0; +https://super-market.uz)")
	req.Header.Set("Accept", "image/avif,image/webp,image/png,image/jpeg,*/*;q=0.5")
	resp, err := s.webClient().Do(req)
	if err != nil {
		return Image{}, errors.New("фото не скачалось")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Image{}, fmt.Errorf("фото не скачалось: %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, media.MaxSize+1))
	if err != nil || len(data) == 0 || len(data) > media.MaxSize {
		return Image{}, errors.New("фото слишком большое или пустое")
	}
	mime := http.DetectContentType(data)
	if !geminiReads[mime] {
		return Image{}, errors.New("это не фото JPG, PNG или WEBP")
	}
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err == nil && (cfg.Width < 150 || cfg.Height < 150) {
		return Image{}, errors.New("фото слишком маленькое")
	}
	return Image{MIME: mime, Data: data}, nil
}

// webClient — HTTP-клиент для чужих адресов: не ходит во внутреннюю сеть
// (ссылки на фото приходят из поиска — их выбираем не мы).
func (s *PhotoService) webClient() *http.Client {
	s.webClientOnce.Do(func() {
		d := &net.Dialer{Timeout: 10 * time.Second}
		if !s.WebAllowPrivate {
			d.Control = func(_, address string, _ syscall.RawConn) error {
				host, _, err := net.SplitHostPort(address)
				if err != nil {
					return err
				}
				ip := net.ParseIP(host)
				if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
					ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() {
					return errors.New("адрес во внутренней сети")
				}
				return nil
			}
		}
		tr := &http.Transport{DialContext: d.DialContext, TLSHandshakeTimeout: 10 * time.Second,
			ResponseHeaderTimeout: webFetchTimeout, MaxIdleConnsPerHost: 4}
		s.webHTTP = &http.Client{Transport: tr, Timeout: webFetchTimeout + 5*time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("слишком много переадресаций")
			}
			return nil
		}}
	})
	return s.webHTTP
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}
