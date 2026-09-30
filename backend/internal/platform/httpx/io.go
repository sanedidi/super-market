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

// List — стандартная обёртка списка в ответе.
type List[T any] struct {
	Items []T `json:"items"`
}

// Respond вызывает fn и отвечает её результатом со статусом status или ошибкой.
func Respond[T any](w http.ResponseWriter, r *http.Request, log *slog.Logger, status int, fn func() (T, error)) {
	v, err := fn()
	if err != nil {
		Fail(w, r, log, err)
		return
	}
	WriteJSON(w, status, v)
}

// RespondBody читает JSON-тело (и id из пути, если idParam не пуст) и
// вызывает fn с ними.
func RespondBody[In any, T any](w http.ResponseWriter, r *http.Request, log *slog.Logger, status int, idParam string,
	fn func(id string, in In) (T, error)) {
	var id string
	if idParam != "" {
		var err error
		if id, err = PathID(r, idParam); err != nil {
			Fail(w, r, log, err)
			return
		}
	}
	var in In
	if err := Decode(r, &in); err != nil {
		Fail(w, r, log, err)
		return
	}
	Respond(w, r, log, status, func() (T, error) { return fn(id, in) })
}

// RespondID достаёт id из пути и вызывает fn.
func RespondID[T any](w http.ResponseWriter, r *http.Request, log *slog.Logger, status int, idParam string,
	fn func(id string) (T, error)) {
	id, err := PathID(r, idParam)
	if err != nil {
		Fail(w, r, log, err)
		return
	}
	Respond(w, r, log, status, func() (T, error) { return fn(id) })
}

// Optional — поле PATCH-запроса, которое можно очистить:
// ключа нет — не менять (Set == false), null — очистить (Set, Value == nil),
// значение — установить.
type Optional[T any] struct {
	Set   bool
	Value *T
}

func (o *Optional[T]) UnmarshalJSON(b []byte) error {
	o.Set = true
	if string(b) == "null" {
		o.Value = nil
		return nil
	}
	var v T
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	o.Value = &v
	return nil
}

// Or — значение, если оно задано, иначе nil (для INSERT).
func (o Optional[T]) Or() *T {
	if !o.Set {
		return nil
	}
	return o.Value
}
