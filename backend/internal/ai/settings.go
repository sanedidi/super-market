package ai

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"errors"
	"fmt"
	"math"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

//go:embed testdata_invoice.png
var testInvoice []byte

// ErrNotConfigured — ИИ ещё не подключён.
var ErrNotConfigured = apperr.Conflict("ai_not_configured", "ИИ-сервис не подключён: супер-админ настраивает его в разделе «ИИ-сервис»")

type Service struct {
	pool *pgxpool.Pool
	aead cipher.AEAD
	now  func() time.Time
}

// NewService — secret шифрует ключи сервиса (из JWT_SECRET).
func NewService(pool *pgxpool.Pool, secret string) *Service {
	sum := sha256.Sum256([]byte(secret + ":ai-key"))
	block, err := aes.NewCipher(sum[:])
	if err != nil {
		panic(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}
	return &Service{pool: pool, aead: aead, now: time.Now}
}

func (s *Service) seal(key string) []byte {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return s.aead.Seal(nonce, nonce, []byte(key), nil)
}

func (s *Service) open(b []byte) (string, error) {
	n := s.aead.NonceSize()
	if len(b) < n {
		return "", errors.New("ai: повреждённый ключ")
	}
	out, err := s.aead.Open(nil, b[:n], b[n:], nil)
	if err != nil {
		return "", errors.New("ai: ключ не расшифровывается (сменился JWT_SECRET?) — введите ключ заново")
	}
	return string(out), nil
}

// Settings — для супер-админа; ключ не отдаётся.
type Settings struct {
	Provider     string     `json:"provider"`
	BaseURL      string     `json:"base_url"`
	Model        string     `json:"model"`
	HasKey       bool       `json:"has_key"`
	KeyLast4     string     `json:"key_last4"`
	Configured   bool       `json:"configured"`
	CheckedAt    *time.Time `json:"checked_at"`
	CheckOK      *bool      `json:"check_ok"`
	CheckMessage string     `json:"check_message"`
	MonthScans   int        `json:"month_scans"`
	MonthFailed  int        `json:"month_failed"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

type row struct {
	Settings
	keyEnc []byte
}

func (s *Service) load(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, lock bool) (row, error) {
	var r row
	sql := `SELECT provider, base_url, model, api_key_enc, key_last4, checked_at, check_ok, check_message, updated_at FROM ai_settings`
	if lock {
		sql += ` FOR UPDATE`
	}
	err := q.QueryRow(ctx, sql).Scan(&r.Provider, &r.BaseURL, &r.Model, &r.keyEnc, &r.KeyLast4, &r.CheckedAt, &r.CheckOK, &r.CheckMessage, &r.UpdatedAt)
	r.HasKey = len(r.keyEnc) > 0
	r.Configured = r.HasKey && r.Model != "" && r.BaseURL != ""
	return r, err
}

func (s *Service) Get(ctx context.Context) (Settings, error) {
	r, err := s.load(ctx, s.pool, false)
	if err != nil {
		return Settings{}, err
	}
	err = s.pool.QueryRow(ctx, `
		SELECT count(*)::int, (count(*) FILTER (WHERE status = 'failed'))::int
		FROM invoice_scans WHERE created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Tashkent') AT TIME ZONE 'Asia/Tashkent'`).
		Scan(&r.MonthScans, &r.MonthFailed)
	return r.Settings, err
}

// Conn — подключение для работы (распознавание). ErrNotConfigured, если не настроено.
func (s *Service) Conn(ctx context.Context) (Conn, error) {
	r, err := s.load(ctx, s.pool, false)
	if err != nil {
		return Conn{}, err
	}
	if !r.Configured {
		return Conn{}, ErrNotConfigured
	}
	key, err := s.open(r.keyEnc)
	if err != nil {
		return Conn{}, apperr.Conflict("ai_not_configured", err.Error())
	}
	return Conn{Provider: r.Provider, BaseURL: r.BaseURL, Key: key, Model: r.Model}, nil
}

// Input — сохранение и проверка. Пустой api_key — оставить сохранённый.
type Input struct {
	Provider string `json:"provider"`
	BaseURL  string `json:"base_url"`
	APIKey   string `json:"api_key"`
	Model    string `json:"model"`
}

func checkURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", apperr.Validation("base_url: адрес вида https://api.openai.com/v1")
	}
	return strings.TrimRight(u.String(), "/"), nil
}

// conn — подключение из ввода; недостающее берётся из сохранённого,
// но ключ — только если сервис и адрес те же (чтобы не отдать ключ чужому адресу).
func (s *Service) conn(ctx context.Context, in Input) (Conn, row, error) {
	r, err := s.load(ctx, s.pool, false)
	if err != nil {
		return Conn{}, r, err
	}
	c := Conn{Provider: in.Provider, BaseURL: in.BaseURL, Key: strings.TrimSpace(in.APIKey), Model: strings.TrimSpace(in.Model)}
	if c.Provider == "" {
		c.Provider = r.Provider
	}
	if c.Provider != ProviderOpenAI && c.Provider != ProviderAnthropic {
		return c, r, apperr.Validation("provider: openai или anthropic")
	}
	if c.BaseURL == "" {
		switch {
		case c.Provider == r.Provider:
			c.BaseURL = r.BaseURL
		case c.Provider == ProviderAnthropic:
			c.BaseURL = DefaultAnthropicURL
		default:
			c.BaseURL = DefaultOpenAIURL
		}
	}
	if c.BaseURL, err = checkURL(c.BaseURL); err != nil {
		return c, r, err
	}
	if c.Key == "" {
		if !r.HasKey || c.Provider != r.Provider || c.BaseURL != r.BaseURL {
			return c, r, apperr.Validation("api_key: вставьте ключ из личного кабинета сервиса")
		}
		if c.Key, err = s.open(r.keyEnc); err != nil {
			return c, r, apperr.Validation("api_key: " + err.Error())
		}
	}
	if len(c.Key) > 500 || strings.ContainsAny(c.Key, " \n\t") {
		return c, r, apperr.Validation("api_key: неверный ключ")
	}
	if c.Model == "" && c.Provider == r.Provider {
		c.Model = r.Model
	}
	if len(c.Model) > 200 {
		return c, r, apperr.Validation("model: слишком длинное название")
	}
	return c, r, nil
}

func last4(key string) string {
	if len(key) <= 4 {
		return ""
	}
	return key[len(key)-4:]
}

// Save — сохранить настройки (без проверки; проверка — Test).
func (s *Service) Save(ctx context.Context, adminID string, in Input) (Settings, error) {
	c, r, err := s.conn(ctx, in)
	if err != nil {
		return Settings{}, err
	}
	if c.Model == "" {
		return Settings{}, apperr.Validation("model: выберите модель")
	}
	keyEnc := s.seal(c.Key)
	changed := c.Provider != r.Provider || c.BaseURL != r.BaseURL || c.Model != r.Model || strings.TrimSpace(in.APIKey) != ""
	_, err = s.pool.Exec(ctx, `
		UPDATE ai_settings SET provider = $1, base_url = $2, model = $3, api_key_enc = $4, key_last4 = $5,
		       checked_at = CASE WHEN $6 THEN NULL ELSE checked_at END,
		       check_ok = CASE WHEN $6 THEN NULL ELSE check_ok END,
		       check_message = CASE WHEN $6 THEN '' ELSE check_message END,
		       updated_by = $7, updated_at = now()`,
		c.Provider, c.BaseURL, c.Model, keyEnc, last4(c.Key), changed, adminID)
	if err != nil {
		return Settings{}, err
	}
	return s.Get(ctx)
}

// Models — модели ключа (из ввода или сохранённого).
func (s *Service) Models(ctx context.Context, in Input) ([]Model, error) {
	c, _, err := s.conn(ctx, in)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	items, err := c.Models(ctx)
	return items, AsAppErr(err)
}

type TestResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Ms      int64  `json:"ms"`
}

// Test — модель читает тестовую накладную (итог 120 000, 3 строки).
// С пустым вводом проверяет сохранённые настройки и записывает результат.
func (s *Service) Test(ctx context.Context, in Input) (TestResult, error) {
	c, r, err := s.conn(ctx, in)
	if err != nil {
		return TestResult{}, err
	}
	if c.Model == "" {
		return TestResult{}, apperr.Validation("model: выберите модель")
	}
	ctx2, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	start := s.now()
	inv, usage, err := c.ReadInvoice(ctx2, []Image{{MIME: "image/png", Data: testInvoice}})
	res := TestResult{Ms: s.now().Sub(start).Milliseconds()}
	defer func() {
		// Проверка тоже тратит токены — пишем её в расход отдельной строкой.
		if usage.Input+usage.Output > 0 {
			_ = s.Record(context.WithoutCancel(ctx), UsageRecord{Kind: "test", Provider: c.Provider, Model: c.Model, Usage: usage, OK: res.OK})
		}
	}()
	var se *ErrService
	switch {
	case errors.As(err, &se):
		res.Message = se.Msg
	case err != nil:
		return res, err
	case len(inv.Lines) != 3 || inv.Total == nil || math.Abs(*inv.Total-120000) > 0.5:
		res.Message = fmt.Sprintf("модель ответила, но прочитала накладную неверно (строк: %d) — выберите модель, которая видит изображения", len(inv.Lines))
	default:
		res.OK = true
		res.Message = fmt.Sprintf("модель прочитала тестовую накладную за %.1f с", float64(res.Ms)/1000)
	}
	// Результат сохраняем, только если проверялись сохранённые настройки.
	if c.Provider == r.Provider && c.BaseURL == r.BaseURL && c.Model == r.Model && strings.TrimSpace(in.APIKey) == "" {
		_, err = s.pool.Exec(ctx, `UPDATE ai_settings SET checked_at = now(), check_ok = $1, check_message = $2`, res.OK, res.Message)
		if err != nil {
			return res, err
		}
	}
	return res, nil
}
