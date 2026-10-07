package i18n

import "errors"

// Error — ошибка с текстом на двух языках. Для ошибок, которые не
// apperr, но доходят до пользователя внутри другого сообщения (например,
// ошибка UnmarshalJSON попадает в «неверный JSON: …»). Error() — по-русски.
type Error struct {
	RU string
	UZ string
}

// NewError — ошибка с текстом по-русски и по-узбекски.
func NewError(ru, uz string) *Error { return &Error{RU: ru, UZ: uz} }

func (e *Error) Error() string { return e.RU }

// In — текст ошибки на языке lang.
func (e *Error) In(lang string) string { return Pick(lang, e.RU, e.UZ) }

// ErrorText — текст err на языке lang: перевод, если в цепочке есть *Error,
// иначе err.Error().
func ErrorText(err error, lang string) string {
	var e *Error
	if errors.As(err, &e) {
		return e.In(lang)
	}
	return err.Error()
}
