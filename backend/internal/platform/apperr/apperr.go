// Package apperr — ошибки бизнес-логики, которые знают свой HTTP-статус
// и машинный код. Сервисы возвращают их, а httpx превращает в JSON.
package apperr

import (
	"errors"
	"fmt"
	"net/http"
)

// Error — ошибка, которую можно показать клиенту.
type Error struct {
	Status  int
	Code    string
	Message string // по-русски
	// MessageUz — тот же текст по-узбекски (латиница); пусто — отдаётся Message.
	MessageUz string
	Details   map[string]any
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Message) }

// Uz возвращает копию ошибки с текстом по-узбекски:
//
//	apperr.Validation("укажите название").Uz("nomini kiriting")
func (e *Error) Uz(message string) *Error {
	c := *e
	c.MessageUz = message
	return &c
}

// Text — текст ошибки на языке lang ("uz" или "ru").
func (e *Error) Text(lang string) string {
	if lang == "uz" && e.MessageUz != "" {
		return e.MessageUz
	}
	return e.Message
}

// WithDetails возвращает копию ошибки с дополнительными полями.
func (e *Error) WithDetails(d map[string]any) *Error {
	c := *e
	c.Details = d
	return &c
}

func New(status int, code, message string) *Error {
	return &Error{Status: status, Code: code, Message: message}
}

func Validation(message string) *Error {
	return New(http.StatusBadRequest, "validation", message)
}

func NotFound(message string) *Error {
	return New(http.StatusNotFound, "not_found", message)
}

func Forbidden(message string) *Error {
	return New(http.StatusForbidden, "forbidden", message)
}

func Unauthorized(message string) *Error {
	return New(http.StatusUnauthorized, "unauthorized", message)
}

func Conflict(code, message string) *Error {
	return New(http.StatusConflict, code, message)
}

// As достаёт *Error из цепочки ошибок.
func As(err error) (*Error, bool) {
	var e *Error
	ok := errors.As(err, &e)
	return e, ok
}
