package httpx

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// maxBody — предел размера JSON-запроса.
const maxBody = 1 << 20

// Decode читает JSON-тело запроса в dst. Неизвестные поля — ошибка,
// чтобы опечатка в названии поля на клиенте не терялась молча.
func Decode(r *http.Request, dst any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		if errors.Is(err, io.EOF) {
			return apperr.Validation("пустое тело запроса")
		}
		return apperr.Validation("неверный JSON: " + err.Error())
	}
	return nil
}

// Fail превращает ошибку в JSON-ответ. *apperr.Error отдаётся как есть,
// любая другая ошибка — 500 без подробностей (подробности уходят в лог).
func Fail(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	if e, ok := apperr.As(err); ok {
		WriteJSON(w, e.Status, ErrorBody{Error: ErrorDetail{Code: e.Code, Message: e.Message, Details: e.Details}})
		return
	}
	log.Error("внутренняя ошибка", "method", r.Method, "path", r.URL.Path, "err", err)
	WriteError(w, http.StatusInternalServerError, "internal", "внутренняя ошибка сервера")
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// IsUUID проверяет формат идентификатора до похода в базу.
func IsUUID(s string) bool { return uuidRe.MatchString(s) }

// PathID берёт UUID из параметра маршрута или возвращает ошибку 404.
func PathID(r *http.Request, name string) (string, error) {
	id := chi.URLParam(r, name)
	if !IsUUID(id) {
		return "", apperr.NotFound("запись не найдена")
	}
	return id, nil
}

// Page — параметры пагинации ?limit=&offset=.
type Page struct {
	Limit  int
	Offset int
}

// PageFrom читает limit (1..200, по умолчанию 50) и offset.
func PageFrom(r *http.Request) Page {
	p := Page{Limit: 50}
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 {
		p.Limit = min(v, 200)
	}
	if v, err := strconv.Atoi(r.URL.Query().Get("offset")); err == nil && v > 0 {
		p.Offset = v
	}
	return p
}
