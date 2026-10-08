// Package httpx — общий HTTP-слой: роутер, middleware, JSON-ответы
// и служебные эндпоинты /healthz и /readyz.
package httpx

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Pinger — всё, что нужно /readyz от базы. *pgxpool.Pool подходит.
type Pinger interface {
	Ping(ctx context.Context) error
}

// Module — модуль бизнес-логики, который регистрирует свои маршруты.
// Каждый модуль из internal/ (catalog, orders, ...) реализует этот интерфейс.
type Module interface {
	Routes(r chi.Router)
}

// NewRouter собирает роутер: middleware, служебные эндпоинты
// и маршруты модулей под префиксом /api/v1.
func NewRouter(log *slog.Logger, db Pinger, modules ...Module) http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(i18n.Middleware)
	r.Use(middleware.RealIP)
	r.Use(requestLogger(log))
	r.Use(middleware.Recoverer)

	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	r.Get("/readyz", func(w http.ResponseWriter, req *http.Request) {
		ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
		defer cancel()
		if err := db.Ping(ctx); err != nil {
			log.Warn("readyz: база недоступна", "err", err)
			WriteError(w, http.StatusServiceUnavailable, "db_unavailable", "база данных недоступна")
			return
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	})

	r.Route("/api/v1", func(api chi.Router) {
		for _, m := range modules {
			m.Routes(api)
		}
	})

	r.NotFound(func(w http.ResponseWriter, req *http.Request) {
		WriteError(w, http.StatusNotFound, "not_found", i18n.T(req.Context(), "маршрут не найден", "yoʻnalish topilmadi"))
	})
	r.MethodNotAllowed(func(w http.ResponseWriter, req *http.Request) {
		WriteError(w, http.StatusMethodNotAllowed, "method_not_allowed", i18n.T(req.Context(), "метод не поддерживается", "usul qoʻllab-quvvatlanmaydi"))
	})
	return r
}

// ErrorBody — единый формат ошибки для всех клиентов (Flutter и web).
type ErrorBody struct {
	Error ErrorDetail `json:"error"`
}

type ErrorDetail struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

// WriteJSON отправляет v как JSON с указанным статусом.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError отправляет ошибку в формате {"error":{"code":..., "message":...}}.
// code — стабильный машинный код, message — текст для человека.
func WriteError(w http.ResponseWriter, status int, code, message string) {
	WriteJSON(w, status, ErrorBody{Error: ErrorDetail{Code: code, Message: message}})
}

func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			next.ServeHTTP(ww, r)
			if r.URL.Path == "/healthz" {
				return // пробы здоровья не засоряют лог
			}
			log.Info("http",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"bytes", ww.BytesWritten(),
				"duration_ms", time.Since(start).Milliseconds(),
				"request_id", middleware.GetReqID(r.Context()),
			)
		})
	}
}
