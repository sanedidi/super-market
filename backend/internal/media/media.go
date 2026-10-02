package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// MaxSize — предел размера одного фото.
const MaxSize = 8 << 20

var types = map[string]string{
	"image/jpeg": "jpg",
	"image/png":  "png",
	"image/webp": "webp",
	"image/gif":  "gif",
}

var keyRe = regexp.MustCompile(`^[0-9]{4}/[0-9]{2}/[0-9a-f]{32}\.(jpg|png|webp|gif)$`)

// Service — загрузка и раздача фото. store == nil — хранилище не настроено.
type Service struct {
	store   *S3
	baseURL string // https://super-market.uz — пусто: из запроса
	now     func() time.Time
	once    sync.Once
	ready   error
}

func NewService(store *S3, baseURL string) *Service {
	return &Service{store: store, baseURL: strings.TrimRight(baseURL, "/"), now: time.Now}
}

var ErrDisabled = apperr.New(http.StatusServiceUnavailable, "media_disabled", "хранилище фото не настроено")

func (s *Service) ensure(ctx context.Context) error {
	if s.store == nil {
		return ErrDisabled
	}
	s.once.Do(func() { s.ready = s.store.EnsureBucket(ctx) })
	if s.ready != nil {
		// Следующая загрузка попробует снова.
		err := s.ready
		s.once = sync.Once{}
		return err
	}
	return nil
}

// Upload сохраняет картинку и возвращает её ключ.
func (s *Service) Upload(ctx context.Context, data []byte) (string, error) {
	if len(data) == 0 {
		return "", apperr.Validation("file: пустой файл")
	}
	if len(data) > MaxSize {
		return "", apperr.Validation("file: не больше 8 МБ")
	}
	ct := http.DetectContentType(data)
	ext, ok := types[ct]
	if !ok {
		return "", apperr.Validation("file: нужна картинка JPG, PNG, WEBP или GIF")
	}
	if err := s.ensure(ctx); err != nil {
		return "", err
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return "", err
	}
	key := s.now().UTC().Format("2006/01") + "/" + hex.EncodeToString(id) + "." + ext
	if err := s.store.Put(ctx, key, ct, data); err != nil {
		return "", err
	}
	return key, nil
}

// KeyFromURL — ключ фото из нашей ссылки (…/api/v1/media/<ключ>) или из самого ключа.
func KeyFromURL(raw string) (string, bool) {
	if i := strings.LastIndex(raw, "/api/v1/media/"); i >= 0 {
		raw = raw[i+len("/api/v1/media/"):]
	}
	return raw, keyRe.MatchString(raw)
}

// Read — содержимое фото и его тип.
func (s *Service) Read(ctx context.Context, key string) ([]byte, string, error) {
	if !keyRe.MatchString(key) {
		return nil, "", ErrNotFound
	}
	if s.store == nil {
		return nil, "", ErrDisabled
	}
	resp, err := s.store.Get(ctx, key)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxSize+1))
	if err != nil {
		return nil, "", err
	}
	return data, http.DetectContentType(data), nil
}

// URL — публичная ссылка на фото.
func (s *Service) URL(r *http.Request, key string) string {
	base := s.baseURL
	if base == "" {
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		if p := r.Header.Get("X-Forwarded-Proto"); p != "" {
			scheme = p
		}
		base = scheme + "://" + r.Host
	}
	return base + "/api/v1/media/" + key
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
	r.Get("/media/*", m.get)
	for _, app := range []string{identity.AppStore, identity.AppAdmin} {
		r.With(m.auth.Require(app)).Post("/"+app+"/uploads", m.upload)
	}
}

type uploadResult struct {
	URL string `json:"url"`
}

func (m *Module) upload(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusCreated, func() (uploadResult, error) {
		r.Body = http.MaxBytesReader(w, r.Body, MaxSize+1<<20)
		f, _, err := r.FormFile("file")
		if err != nil {
			var tooBig *http.MaxBytesError
			if errors.As(err, &tooBig) {
				return uploadResult{}, apperr.Validation("file: не больше 8 МБ")
			}
			return uploadResult{}, apperr.Validation("file: прикрепите картинку (multipart, поле file)")
		}
		defer f.Close()
		data, err := io.ReadAll(io.LimitReader(f, MaxSize+1))
		if err != nil {
			return uploadResult{}, apperr.Validation("file: не удалось прочитать файл")
		}
		key, err := m.svc.Upload(r.Context(), data)
		if err != nil {
			return uploadResult{}, err
		}
		return uploadResult{URL: m.svc.URL(r, key)}, nil
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	key := chi.URLParam(r, "*")
	if !keyRe.MatchString(key) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "файл не найден")
		return
	}
	if m.svc.store == nil {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "файл не найден")
		return
	}
	// Ключ уникален и не меняется — браузер и CDN кэшируют навсегда.
	if r.Header.Get("If-None-Match") == `"`+key+`"` {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	res, err := m.svc.store.Get(r.Context(), key)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "файл не найден")
		return
	}
	if err != nil {
		m.log.Error("media: чтение", "key", key, "err", err)
		httpx.WriteError(w, http.StatusBadGateway, "media_unavailable", "хранилище фото недоступно")
		return
	}
	defer res.Body.Close()
	ext := key[strings.LastIndexByte(key, '.')+1:]
	for ct, e := range types {
		if e == ext {
			w.Header().Set("Content-Type", ct)
		}
	}
	if n := res.Header.Get("Content-Length"); n != "" {
		w.Header().Set("Content-Length", n)
	}
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+key+`"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = io.Copy(w, res.Body)
	}
}
