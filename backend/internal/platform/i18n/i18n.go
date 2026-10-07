// Package i18n — язык ответа: узбекский (латиница) или русский.
//
// Язык запроса приходит в заголовке Accept-Language (приложения и
// веб-панель магазина шлют его всегда; панель супер-админа — "ru").
// Middleware кладёт язык в контекст; дальше:
//   - ошибки: apperr.Validation("…").Uz("…") — httpx.Fail отдаёт нужный текст;
//   - любые строки: i18n.T(ctx, "по-русски", "oʻzbekcha");
//   - данные из базы: SQL-функция loc(ru, uz) (миграция 0039) берёт язык
//     из настройки соединения app.lang, которую ставит пул (db.Connect).
//
// Запрос без заголовка (старые версии приложений, curl) получает русский —
// как было до появления языков. Узбекский — язык по умолчанию в самих
// приложениях: они шлют "uz", пока пользователь не выбрал русский.
package i18n

import (
	"context"
	"net/http"
	"strings"
)

const (
	UZ = "uz"
	RU = "ru"
)

// Default — язык, если запрос его не указал (совместимость со старыми клиентами).
const Default = RU

type ctxKey struct{}

// WithLang — контекст с языком (для воркеров и уведомлений: язык получателя).
func WithLang(ctx context.Context, lang string) context.Context {
	return context.WithValue(ctx, ctxKey{}, Normalize(lang))
}

// FromContext — язык из контекста; Default, если не задан.
func FromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKey{}).(string); ok && v != "" {
		return v
	}
	return Default
}

// Explicit — язык, только если он задан в контексте явно ("" — нет).
func Explicit(ctx context.Context) string {
	v, _ := ctx.Value(ctxKey{}).(string)
	return v
}

// Normalize — "uz", "uz-Latn", "uz_UZ" → "uz"; "ru-RU" → "ru"; иное → Default.
func Normalize(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	switch {
	case strings.HasPrefix(s, UZ):
		return UZ
	case strings.HasPrefix(s, RU):
		return RU
	}
	return Default
}

// FromRequest — язык запроса: ?lang= или Accept-Language (первый язык из
// списка). "" — запрос язык не указал.
func FromRequest(r *http.Request) string {
	if v := r.URL.Query().Get("lang"); v != "" {
		return Normalize(v)
	}
	h := strings.TrimSpace(r.Header.Get("Accept-Language"))
	if h == "" {
		return ""
	}
	first := strings.TrimSpace(strings.SplitN(strings.SplitN(h, ",", 2)[0], ";", 2)[0])
	if first == "" || first == "*" {
		return ""
	}
	return Normalize(first)
}

// Middleware — кладёт язык запроса в контекст.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if lang := FromRequest(r); lang != "" {
			r = r.WithContext(WithLang(r.Context(), lang))
		}
		next.ServeHTTP(w, r)
	})
}

// Pick — ru или uz по языку; пустой uz — ru.
func Pick(lang, ru, uz string) string {
	if lang == UZ && uz != "" {
		return uz
	}
	return ru
}

// T — строка на языке контекста.
func T(ctx context.Context, ru, uz string) string { return Pick(FromContext(ctx), ru, uz) }

// Text — пара строк, когда текст выбирается позже (списки, справочники).
type Text struct {
	RU string
	UZ string
}

// In — текст на языке lang.
func (t Text) In(lang string) string { return Pick(lang, t.RU, t.UZ) }

// Ctx — текст на языке контекста.
func (t Text) Ctx(ctx context.Context) string { return t.In(FromContext(ctx)) }
