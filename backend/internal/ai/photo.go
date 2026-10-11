package ai

// «ИИ для фото» (Figma «Супер-админ · ИИ для фото товаров»): своё подключение
// к Google Gemini — отдельно от «ИИ-сервиса» (накладные, сопоставление, переводы).
// Gemini генерирует и редактирует фото товаров: «Нормализовать фото» на
// странице товара делает фото квадратным, на однотонном фоне, товар целиком.
//
// Gemini рисует 10–60 секунд, а HTTP-запрос API живёт 30, поэтому обработка
// идёт в фоне: POST отвечает заданием, панель опрашивает GET /admin/ai-photo/jobs/{id}.

import (
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"errors"
	"fmt"
	"image/color"
	"log/slog"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

//go:embed testdata_photo.jpg
var testPhoto []byte

// ErrPhotoNotConfigured — Gemini для фото ещё не подключён.
var ErrPhotoNotConfigured = apperr.Conflict("ai_photo_not_configured", "Подключите ИИ для фото: супер-админ → «ИИ для фото»").Uz("Rasm uchun SIni ulang: super-admin → «Rasm uchun SI»")

const (
	maxPhotoPrompt  = 4000
	maxPhotosPerJob = 10
	photoParallel   = 3
	photoTimeout    = 150 * time.Second
	photoJobTTL     = time.Hour
)

// DefaultPhotoPrompt — стандартная инструкция для Gemini («12 правил»).
// Фон, дорисовка, товар и поиск добавляются к ней из настроек.
const DefaultPhotoPrompt = `You edit product photos for an online grocery catalog. Turn the photo into a clean catalog product shot.
1. Keep exactly the same product: the same package shape, colors, logo, text and label layout. Never invent, translate or change any text on the package.
2. Remove the background completely and put the product on a plain solid background of the color given below.
3. Square 1:1 image, the product centered, level and facing the camera, in its natural orientation: a horizontal package (a butter or cheese brick, a chocolate bar, a flat box) stays horizontal, a tall package (a bottle, a carton) stays vertical. Never rotate the product by 90 degrees to fill the square; empty space above and below is fine.
4. The product fills about 80% of the frame with even margins on all sides; nothing is cut off.
5. Remove hands, fingers, price tags, shelf edges, reflections of the room and any other objects.
6. Remove glare and harsh reflections; soft even studio lighting; correct white balance.
7. Fix perspective and a slight tilt so that the edges of the package are straight; do not change which side of the package is long and which is short.
8. Keep only a subtle natural shadow under the product; no other effects.
9. Do not add props, text, watermarks, borders or extra products.
10. If several identical units are visible, keep only one.
11. Keep the image sharp and photorealistic; no stylization.
12. If there is no product package in the photo, return the photo unchanged.`

// PhotoSettings — для супер-админа; ключ не отдаётся.
type PhotoSettings struct {
	Mode          string     `json:"mode"` // gemini | vertex
	BaseURL       string     `json:"base_url"`
	Model         string     `json:"model"`
	HasKey        bool       `json:"has_key"`
	KeyLast4      string     `json:"key_last4"`
	Configured    bool       `json:"configured"`
	Background    string     `json:"background"` // white | light | transparent
	Size          int        `json:"size"`       // 1000 | 1500 | 2000
	Outpaint      bool       `json:"outpaint"`
	WebSearch     bool       `json:"web_search"`
	BeforeAfter   bool       `json:"before_after"`
	Prompt        string     `json:"prompt"` // своя инструкция; пусто — стандартная
	DefaultPrompt string     `json:"default_prompt"`
	CheckedAt     *time.Time `json:"checked_at"`
	CheckOK       *bool      `json:"check_ok"`
	CheckMessage  string     `json:"check_message"`
	MonthPhotos   int        `json:"month_photos"`
	MonthFailed   int        `json:"month_failed"`
	MonthCostUSD  float64    `json:"month_cost_usd"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

type photoRow struct {
	PhotoSettings
	keyEnc []byte
}

// PhotoService — настройки и задания «ИИ для фото».
type PhotoService struct {
	ai    *Service
	media *media.Service
	log   *slog.Logger

	mu   sync.Mutex
	jobs map[string]*photoJob
	// Sync — обрабатывать задание сразу в запросе (тесты).
	Sync bool
}

func NewPhotoService(ai *Service, m *media.Service, log *slog.Logger) *PhotoService {
	return &PhotoService{ai: ai, media: m, log: log, jobs: map[string]*photoJob{}}
}

func (s *PhotoService) load(ctx context.Context) (photoRow, error) {
	var r photoRow
	err := s.ai.pool.QueryRow(ctx, `
		SELECT mode, base_url, model, api_key_enc, key_last4, background, size, outpaint, web_search, before_after, prompt,
		       checked_at, check_ok, check_message, updated_at
		FROM ai_photo_settings`).Scan(&r.Mode, &r.BaseURL, &r.Model, &r.keyEnc, &r.KeyLast4, &r.Background, &r.Size,
		&r.Outpaint, &r.WebSearch, &r.BeforeAfter, &r.Prompt, &r.CheckedAt, &r.CheckOK, &r.CheckMessage, &r.UpdatedAt)
	r.HasKey = len(r.keyEnc) > 0
	r.Configured = r.HasKey && r.Model != "" && r.BaseURL != ""
	r.DefaultPrompt = DefaultPhotoPrompt
	return r, err
}

// Get — настройки и расход за месяц.
func (s *PhotoService) Get(ctx context.Context) (PhotoSettings, error) {
	r, err := s.load(ctx)
	if err != nil {
		return PhotoSettings{}, err
	}
	err = s.ai.pool.QueryRow(ctx, `
		SELECT count(*)::int, (count(*) FILTER (WHERE NOT ok))::int, COALESCE(sum(cost) FILTER (WHERE currency = 'USD'), 0)::float8
		FROM ai_usage
		WHERE kind = 'photo' AND at >= date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'`).
		Scan(&r.MonthPhotos, &r.MonthFailed, &r.MonthCostUSD)
	return r.PhotoSettings, err
}

// photoProvider — подключение Gemini по способу.
func photoProvider(mode string) string {
	if mode == "vertex" {
		return ProviderVertex
	}
	return ProviderGemini
}

// isGoogleGeminiURL — адрес самого Google для Gemini API.
func isGoogleGeminiURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Port() == "" && strings.EqualFold(u.Hostname(), "generativelanguage.googleapis.com")
}

// PhotoInput — сохранение и проверка. Пустой api_key — оставить сохранённый;
// nil — не менять.
type PhotoInput struct {
	Mode        string  `json:"mode"`
	BaseURL     string  `json:"base_url"`
	APIKey      string  `json:"api_key"`
	Model       string  `json:"model"`
	Background  *string `json:"background"`
	Size        *int    `json:"size"`
	Outpaint    *bool   `json:"outpaint"`
	WebSearch   *bool   `json:"web_search"`
	BeforeAfter *bool   `json:"before_after"`
	Prompt      *string `json:"prompt"`
	// Только проверка: своё фото (ссылка из хранилища); пусто — стандартное.
	Image string `json:"image"`
}

// photoOpts — как делать фото.
type photoOpts struct {
	Background string
	Size       int
	Outpaint   bool
	WebSearch  bool
	Prompt     string
}

// conn — подключение из ввода; недостающее — из сохранённого. Ключ берётся
// сохранённый, только если способ и адрес те же (чтобы не отдать ключ чужому адресу).
func (s *PhotoService) conn(ctx context.Context, in PhotoInput) (Conn, photoOpts, photoRow, error) {
	r, err := s.load(ctx)
	if err != nil {
		return Conn{}, photoOpts{}, r, err
	}
	mode := strings.TrimSpace(in.Mode)
	if mode == "" {
		mode = r.Mode
	}
	if mode != "gemini" && mode != "vertex" {
		return Conn{}, photoOpts{}, r, apperr.Validation("mode: gemini или vertex").Uz("mode: gemini yoki vertex")
	}
	c := Conn{Provider: photoProvider(mode), BaseURL: strings.TrimSpace(in.BaseURL), Key: strings.TrimSpace(in.APIKey), Model: strings.TrimSpace(in.Model)}
	if c.BaseURL == "" {
		switch {
		case mode == r.Mode:
			c.BaseURL = r.BaseURL
		case mode == "vertex":
			if p := vertexProject(c.Key); p != "" {
				c.BaseURL = VertexURL(p, "global")
			} else {
				c.BaseURL = DefaultVertexURL
			}
		default:
			c.BaseURL = DefaultGeminiURL
		}
	}
	if c.BaseURL, err = checkURL(c.BaseURL); err != nil {
		return c, photoOpts{}, r, apperr.Validation("base_url: адрес вида " + DefaultGeminiURL).Uz("base_url: " + DefaultGeminiURL + " koʻrinishidagi manzil")
	}
	if c.Key == "" {
		same := c.BaseURL == r.BaseURL ||
			(mode == "vertex" && isGoogleVertexURL(c.BaseURL) && isGoogleVertexURL(r.BaseURL)) ||
			(mode == "gemini" && isGoogleGeminiURL(c.BaseURL) && isGoogleGeminiURL(r.BaseURL))
		if !r.HasKey || mode != r.Mode || !same {
			return c, photoOpts{}, r, apperr.Validation("api_key: вставьте ключ Gemini").Uz("api_key: Gemini kalitini qoʻying")
		}
		if c.Key, err = s.ai.open(r.keyEnc); err != nil {
			msg := keyErrText(err)
			return c, photoOpts{}, r, apperr.Validation("api_key: " + msg.RU).Uz("api_key: " + msg.UZ)
		}
	}
	switch {
	case mode == "vertex" && isJSONKey(c.Key):
		if len(c.Key) > maxVertexKeyLn {
			return c, photoOpts{}, r, apperr.Validation("api_key: слишком длинный ключ").Uz("api_key: kalit juda uzun")
		}
		if _, err := parseServiceAccount(c.Key); err != nil {
			msg := keyErrText(err)
			return c, photoOpts{}, r, apperr.Validation("api_key: " + msg.RU).Uz("api_key: " + msg.UZ)
		}
	case mode == "gemini" && isJSONKey(c.Key):
		return c, photoOpts{}, r, apperr.Validation("api_key: JSON-ключ сервисного аккаунта — это способ «Vertex AI»; для Gemini API нужен ключ из Google AI Studio").
			Uz("api_key: servis akkaunti JSON kaliti — bu «Vertex AI» usuli; Gemini API uchun Google AI Studio kaliti kerak")
	case len(c.Key) > 500 || strings.ContainsAny(c.Key, " \n\t"):
		return c, photoOpts{}, r, apperr.Validation("api_key: неверный ключ").Uz("api_key: kalit notoʻgʻri")
	}
	if c.Model == "" && mode == r.Mode {
		c.Model = r.Model
	}
	if len(c.Model) > 200 {
		return c, photoOpts{}, r, apperr.Validation("model: слишком длинное название").Uz("model: nomi juda uzun")
	}
	o := photoOpts{Background: r.Background, Size: r.Size, Outpaint: r.Outpaint, WebSearch: r.WebSearch, Prompt: r.Prompt}
	if in.Background != nil {
		o.Background = *in.Background
	}
	if in.Size != nil {
		o.Size = *in.Size
	}
	if in.Outpaint != nil {
		o.Outpaint = *in.Outpaint
	}
	if in.WebSearch != nil {
		o.WebSearch = *in.WebSearch
	}
	if in.Prompt != nil {
		o.Prompt = strings.TrimSpace(*in.Prompt)
	}
	switch {
	case o.Background != "white" && o.Background != "light" && o.Background != "transparent":
		return c, o, r, apperr.Validation("background: white, light или transparent").Uz("background: white, light yoki transparent")
	case o.Size != 1000 && o.Size != 1500 && o.Size != 2000:
		return c, o, r, apperr.Validation("size: 1000, 1500 или 2000").Uz("size: 1000, 1500 yoki 2000")
	case len([]rune(o.Prompt)) > maxPhotoPrompt:
		return c, o, r, apperr.Validation(fmt.Sprintf("prompt: не больше %d символов", maxPhotoPrompt)).Uz(fmt.Sprintf("prompt: %d belgidan oshmasin", maxPhotoPrompt))
	}
	// Стандартная инструкция, присланная как есть, — это «стандартная».
	if o.Prompt == strings.TrimSpace(DefaultPhotoPrompt) {
		o.Prompt = ""
	}
	return c, o, r, nil
}

// SavePhoto — сохранить настройки (без проверки; проверка — TestPhoto).
func (s *PhotoService) Save(ctx context.Context, adminID string, in PhotoInput) (PhotoSettings, error) {
	c, o, r, err := s.conn(ctx, in)
	if err != nil {
		return PhotoSettings{}, err
	}
	if c.Model == "" {
		return PhotoSettings{}, apperr.Validation("model: выберите модель").Uz("model: modelni tanlang")
	}
	beforeAfter := r.BeforeAfter
	if in.BeforeAfter != nil {
		beforeAfter = *in.BeforeAfter
	}
	mode := strings.TrimSpace(in.Mode)
	if mode == "" {
		mode = r.Mode
	}
	changed := mode != r.Mode || c.BaseURL != r.BaseURL || c.Model != r.Model || strings.TrimSpace(in.APIKey) != ""
	_, err = s.ai.pool.Exec(ctx, `
		UPDATE ai_photo_settings SET mode = $1, base_url = $2, model = $3, api_key_enc = $4, key_last4 = $5,
		       background = $6, size = $7, outpaint = $8, web_search = $9, before_after = $10, prompt = $11,
		       checked_at = CASE WHEN $12 THEN NULL ELSE checked_at END,
		       check_ok = CASE WHEN $12 THEN NULL ELSE check_ok END,
		       check_message = CASE WHEN $12 THEN '' ELSE check_message END,
		       updated_by = $13, updated_at = now()`,
		mode, c.BaseURL, c.Model, s.ai.seal(c.Key), keyHint(c.Key), o.Background, o.Size, o.Outpaint, o.WebSearch, beforeAfter, o.Prompt,
		changed, adminID)
	if err != nil {
		return PhotoSettings{}, err
	}
	return s.Get(ctx)
}

// Models — модели ключа, которые рисуют картинки.
func (s *PhotoService) Models(ctx context.Context, in PhotoInput) ([]Model, error) {
	c, _, _, err := s.conn(ctx, in)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	items, err := c.ImageModels(ctx)
	return items, AsAppErr(err)
}

// ------------------------------------------------------------------ задания

// PhotoItem — одно фото задания.
type PhotoItem struct {
	Source string `json:"source"` // исходное фото (ссылка; у стандартного — data:)
	Result string `json:"result"` // готовое: ссылка из хранилища, у проверки — data:
	Error  string `json:"error"`
	Done   bool   `json:"done"`
	Ms     int64  `json:"ms"`
}

// PhotoJob — задание: проверка на фото или «Нормализовать фото» товара.
type PhotoJob struct {
	ID        string      `json:"id"`
	Test      bool        `json:"test"`
	Running   bool        `json:"running"`
	Items     []PhotoItem `json:"items"`
	CostUSD   float64     `json:"cost_usd"`
	OK        bool        `json:"ok"`      // проверка: Gemini вернул фото
	Message   string      `json:"message"` // проверка: итог для человека
	Model     string      `json:"model"`
	StartedAt time.Time   `json:"started_at"`
}

type photoJob struct {
	mu  sync.Mutex
	job PhotoJob
	at  time.Time
}

func (j *photoJob) snapshot() PhotoJob {
	j.mu.Lock()
	defer j.mu.Unlock()
	out := j.job
	out.Items = append([]PhotoItem(nil), j.job.Items...)
	return out
}

// Job — состояние задания.
func (s *PhotoService) Job(id string) (PhotoJob, error) {
	s.mu.Lock()
	j := s.jobs[id]
	s.mu.Unlock()
	if j == nil {
		return PhotoJob{}, apperr.NotFound("задание не найдено — запустите заново").Uz("topshiriq topilmadi — qaytadan ishga tushiring")
	}
	return j.snapshot(), nil
}

// photoTask — что обрабатывает задание.
type photoTask struct {
	conn      Conn
	opts      photoOpts
	productID *string
	product   string // название, бренд и штрихкод — для поиска в Google
	test      bool
	sources   []string // ссылки; у проверки без своего фото — пусто
	mediaBase string   // https://…/api/v1/media/
	lang      string
	saved     bool // проверялись сохранённые настройки — записать итог
}

func (s *PhotoService) start(ctx context.Context, t photoTask) PhotoJob {
	j := &photoJob{at: time.Now(), job: PhotoJob{ID: newJobID(), Test: t.test, Running: true, Model: t.conn.Model, StartedAt: time.Now()}}
	if t.test && len(t.sources) == 0 {
		j.job.Items = []PhotoItem{{Source: "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(testPhoto)}}
	} else {
		for _, src := range t.sources {
			j.job.Items = append(j.job.Items, PhotoItem{Source: src})
		}
	}
	s.mu.Lock()
	for id, old := range s.jobs {
		if time.Since(old.at) > photoJobTTL {
			delete(s.jobs, id)
		}
	}
	s.jobs[j.job.ID] = j
	s.mu.Unlock()
	if s.Sync {
		s.run(ctx, j, t)
		return j.snapshot()
	}
	first := j.snapshot()
	go func() {
		defer func() {
			if p := recover(); p != nil {
				s.log.Error("ai photo: паника", "panic", p)
				j.mu.Lock()
				j.job.Running = false
				for i := range j.job.Items {
					if !j.job.Items[i].Done {
						j.job.Items[i].Done, j.job.Items[i].Error = true, i18n.Pick(t.lang, "внутренняя ошибка", "ichki xato")
					}
				}
				j.mu.Unlock()
			}
		}()
		s.run(context.Background(), j, t)
	}()
	return first
}

func newJobID() string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return fmt.Sprintf("%x", b[:])
}

func (s *PhotoService) run(ctx context.Context, j *photoJob, t photoTask) {
	sem := make(chan struct{}, photoParallel)
	var wg sync.WaitGroup
	n := len(j.snapshot().Items)
	for i := 0; i < n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			start := time.Now()
			result, cost, err := s.one(ctx, t, i)
			j.mu.Lock()
			it := &j.job.Items[i]
			it.Done, it.Ms, it.Result = true, time.Since(start).Milliseconds(), result
			if err != nil {
				it.Error = errText(err, t.lang)
			}
			j.job.CostUSD += cost
			j.mu.Unlock()
		}(i)
	}
	wg.Wait()
	j.mu.Lock()
	j.job.Running = false
	if t.test {
		it := j.job.Items[0]
		j.job.OK = it.Error == ""
		if j.job.OK {
			j.job.Message = i18n.Pick(t.lang, fmt.Sprintf("Gemini работает: фото готово за %.1f с", float64(it.Ms)/1000),
				fmt.Sprintf("Gemini ishlayapti: rasm %.1f soniyada tayyor", float64(it.Ms)/1000))
		} else {
			j.job.Message = it.Error
		}
	}
	res := j.job
	j.mu.Unlock()
	if t.test && t.saved {
		msg := res.Message
		if r := []rune(msg); len(r) > 500 {
			msg = string(r[:500])
		}
		if _, err := s.ai.pool.Exec(context.WithoutCancel(ctx),
			`UPDATE ai_photo_settings SET checked_at = now(), check_ok = $1, check_message = $2`, res.OK, msg); err != nil {
			s.log.Error("ai photo: итог проверки", "err", err)
		}
	}
}

func errText(err error, lang string) string {
	var se *ErrService
	if errors.As(err, &se) {
		if lang == i18n.UZ && se.MsgUz != "" {
			return se.MsgUz
		}
		return se.Msg
	}
	var ae *apperr.Error
	if errors.As(err, &ae) {
		return ae.Text(lang)
	}
	return err.Error()
}

// one — одно фото: прочитать, отдать Gemini, сделать квадрат и сохранить.
func (s *PhotoService) one(ctx context.Context, t photoTask, i int) (string, float64, error) {
	var raw []byte
	var mime string
	if t.test && len(t.sources) == 0 {
		raw, mime = testPhoto, "image/jpeg"
	} else {
		key, ok := media.KeyFromURL(t.sources[i])
		if !ok {
			return "", 0, &ErrService{Msg: "фото не из хранилища Super Market — загрузите его заново", MsgUz: "rasm Super Market omboridan emas — qaytadan yuklang"}
		}
		var err error
		if raw, mime, err = s.media.Read(ctx, key); err != nil {
			return "", 0, &ErrService{Msg: "фото не найдено в хранилище", MsgUz: "rasm omborda topilmadi"}
		}
	}
	in, err := shrinkForModel(raw, mime)
	if err != nil {
		return "", 0, &ErrService{Msg: err.Error(), MsgUz: "rasmni oʻqib boʻlmadi"}
	}
	size := ""
	if t.opts.Size > 1000 {
		size = "2K"
	}
	actx, cancel := context.WithTimeout(ctx, photoTimeout)
	img, u, err := t.conn.GenerateImage(actx, ImageAsk{Prompt: photoPrompt(t.opts, t.product), Images: []Image{in}, Aspect: "1:1", Size: size, Search: t.opts.WebSearch && t.product != ""})
	cancel()
	cost := 0.0
	if u.Input+u.Output > 0 || err == nil {
		cost = ImageCostUSD(t.conn.Model, u, err == nil)
		kind := "photo"
		if t.test {
			kind = "photo_test"
		}
		if rerr := s.ai.Record(context.WithoutCancel(ctx), UsageRecord{Kind: kind, ProductID: t.productID, Provider: t.conn.Provider,
			Model: t.conn.Model, Usage: u, OK: err == nil, CostUSD: &cost}); rerr != nil {
			s.log.Error("ai usage", "kind", kind, "err", rerr)
		}
	}
	if err != nil {
		return "", cost, err
	}
	var out []byte
	outMime := "image/jpeg"
	switch t.opts.Background {
	case "transparent":
		out, err = transparentPhoto(img.Data, t.opts.Size)
		outMime = "image/png"
	case "light":
		out, err = squarePhoto(img.Data, t.opts.Size, color.RGBA{242, 242, 242, 255})
	default:
		out, err = squarePhoto(img.Data, t.opts.Size, color.RGBA{255, 255, 255, 255})
	}
	if err != nil {
		return "", cost, &ErrService{Msg: err.Error(), MsgUz: "Gemini yuborgan rasmni oʻqib boʻlmadi"}
	}
	if t.test {
		return "data:" + outMime + ";base64," + base64.StdEncoding.EncodeToString(out), cost, nil
	}
	key, err := s.media.Upload(ctx, out)
	if err != nil {
		return "", cost, err
	}
	return t.mediaBase + key, cost, nil
}

// photoPrompt — инструкция для Gemini: правила (свои или стандартные) и настройки.
func photoPrompt(o photoOpts, product string) string {
	var b strings.Builder
	if o.Prompt != "" {
		b.WriteString(o.Prompt)
	} else {
		b.WriteString(DefaultPhotoPrompt)
	}
	switch o.Background {
	case "transparent":
		// Прозрачность Gemini не рисует: ровный пурпурный фон вырезается на сервере (cutout.go).
		b.WriteString("\nBackground color: pure flat magenta #FF00FF filling the whole background, perfectly uniform, no gradient, no shadow, no reflections, no vignette. Do not use this magenta color anywhere on the product.")
	case "light":
		b.WriteString("\nBackground color: very light gray #F2F2F2, plain and solid.")
	default:
		b.WriteString("\nBackground color: pure white #FFFFFF, plain and solid.")
	}
	// И для своей инструкции: модель любит ставить всё вертикально под квадрат.
	b.WriteString("\nOrientation: keep the product exactly as it is oriented in reality; the text on the front must read the same way as on the real package. Do not turn a horizontal product into a vertical one.")
	if o.Outpaint {
		b.WriteString("\nIf part of the product is cut off by the edge of the photo (for example the cap, the lid or an edge of the package), complete the missing part realistically so that the whole product is visible.")
	} else {
		b.WriteString("\nDo not draw parts of the product that are not visible in the photo.")
	}
	if product != "" {
		b.WriteString("\nThe product: " + product + ".")
		if o.WebSearch {
			b.WriteString(" Use Google Search to find the official packaging of this product and use it only to restore missing or unreadable parts accurately.")
		}
	}
	b.WriteString("\nReturn only the edited image.")
	return b.String()
}

// TestPhoto — Gemini обрабатывает стандартное фото (сок без крышки в кадре)
// или загруженное. С пустым ключом и теми же способом, адресом и моделью
// проверяет сохранённое и записывает итог.
func (s *PhotoService) TestPhoto(ctx context.Context, in PhotoInput, mediaBase string) (PhotoJob, error) {
	c, o, r, err := s.conn(ctx, in)
	if err != nil {
		return PhotoJob{}, err
	}
	if c.Model == "" {
		return PhotoJob{}, apperr.Validation("model: выберите модель").Uz("model: modelni tanlang")
	}
	t := photoTask{conn: c, opts: o, test: true, mediaBase: mediaBase, lang: i18n.FromContext(ctx),
		saved: c.Provider == photoProvider(r.Mode) && c.BaseURL == r.BaseURL && c.Model == r.Model && strings.TrimSpace(in.APIKey) == ""}
	if img := strings.TrimSpace(in.Image); img != "" {
		if _, ok := media.KeyFromURL(img); !ok {
			return PhotoJob{}, apperr.Validation("image: загрузите фото заново").Uz("image: rasmni qaytadan yuklang")
		}
		t.sources = []string{img}
	} else {
		// Стандартное фото — сок; для поиска в Google нужен реальный товар.
		t.opts.WebSearch = false
	}
	return s.start(ctx, t), nil
}

// NormalizeInput — POST /admin/ai-photo/normalize: фото товара (ссылки из
// формы, в том числе ещё не сохранённые).
type NormalizeInput struct {
	ProductID string   `json:"product_id"`
	Images    []string `json:"images"`
}

// Normalize — «Нормализовать фото»: Gemini делает каждое фото квадратным, на
// однотонном фоне, товар целиком. Готовые фото кладутся в хранилище рядом с
// оригиналами; какие поставить товару, решает супер-админ.
func (s *PhotoService) Normalize(ctx context.Context, in NormalizeInput, mediaBase string) (PhotoJob, error) {
	if len(in.Images) == 0 {
		return PhotoJob{}, apperr.Validation("images: у товара нет фото").Uz("images: mahsulotda rasm yoʻq")
	}
	if len(in.Images) > maxPhotosPerJob {
		return PhotoJob{}, apperr.Validation(fmt.Sprintf("images: не больше %d фото", maxPhotosPerJob)).Uz(fmt.Sprintf("images: %d tadan oshmasin", maxPhotosPerJob))
	}
	r, err := s.load(ctx)
	if err != nil {
		return PhotoJob{}, err
	}
	if !r.Configured {
		return PhotoJob{}, ErrPhotoNotConfigured
	}
	c, o, _, err := s.conn(ctx, PhotoInput{})
	if err != nil {
		var ae *apperr.Error
		if errors.As(err, &ae) {
			return PhotoJob{}, apperr.Conflict("ai_photo_not_configured", "ИИ для фото: "+ae.Text(i18n.RU)).Uz("Rasm uchun SI: " + ae.Text(i18n.UZ))
		}
		return PhotoJob{}, err
	}
	t := photoTask{conn: c, opts: o, mediaBase: mediaBase, lang: i18n.FromContext(ctx), sources: in.Images}
	if in.ProductID != "" {
		if !httpx.IsUUID(in.ProductID) {
			return PhotoJob{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		var name, brand, barcode string
		err := s.ai.pool.QueryRow(ctx, `
			SELECT p.name, COALESCE(b.name, ''), COALESCE((SELECT min(pb.barcode) FROM product_barcodes pb WHERE pb.product_id = p.id), '')
			FROM products p LEFT JOIN brands b ON b.id = p.brand_id WHERE p.id = $1`, in.ProductID).Scan(&name, &brand, &barcode)
		if errors.Is(err, pgx.ErrNoRows) {
			return PhotoJob{}, apperr.NotFound("товар не найден").Uz("mahsulot topilmadi")
		}
		if err != nil {
			return PhotoJob{}, err
		}
		id := in.ProductID
		t.productID = &id
		t.product = productLine(name, brand, barcode)
	}
	return s.start(ctx, t), nil
}

func productLine(name, brand, barcode string) string {
	parts := []string{strings.TrimSpace(name)}
	if brand = strings.TrimSpace(brand); brand != "" && !strings.Contains(strings.ToLower(name), strings.ToLower(brand)) {
		parts = append(parts, "brand "+brand)
	}
	if barcode = strings.TrimSpace(barcode); barcode != "" {
		parts = append(parts, "barcode "+barcode)
	}
	return strings.Join(parts, ", ")
}
