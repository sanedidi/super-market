package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
)

// client вызывает обработчик API напрямую, без сети.
type client struct {
	h    http.Handler
	code string
	// Номер и код из REVIEW_LOGIN: для него сервер принимает только этот код.
	reviewPhone, reviewCode string
}

type obj = map[string]any

func (c client) do(method, path, tok string, body any) (int, obj, error) {
	var rdr *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		rdr = bytes.NewReader(b)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, "/api/v1"+path, rdr)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "demo-seed")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	rec := httptest.NewRecorder()
	c.h.ServeHTTP(rec, req)
	out := obj{}
	if rec.Body.Len() > 0 {
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
	}
	return rec.Code, out, nil
}

// call ждёт статус want и возвращает тело ответа.
func (c client) call(method, path, tok string, body any, want int) (obj, error) {
	code, out, err := c.do(method, path, tok, body)
	if err != nil {
		return nil, err
	}
	if code != want {
		return nil, fmt.Errorf("%s %s: статус %d (ожидался %d): %v", method, path, code, want, out)
	}
	return out, nil
}

func (c client) login(phone, app string) (string, error) {
	return c.loginTerms(phone, app, false)
}

// loginTerms — вход с согласием с условиями (регистрация курьера «по пути»).
func (c client) loginTerms(phone, app string, terms bool) (string, error) {
	if _, err := c.call("POST", "/auth/otp/request", "", obj{"phone": phone, "app": app}, http.StatusOK); err != nil {
		return "", err
	}
	code := c.code
	if c.reviewPhone != "" && phone == c.reviewPhone {
		code = c.reviewCode
	}
	out, err := c.call("POST", "/auth/otp/verify", "", obj{"phone": phone, "code": code, "app": app, "terms_accepted": terms}, http.StatusOK)
	if err != nil {
		return "", err
	}
	return str(out, "access_token"), nil
}

func str(o obj, key string) string {
	s, _ := o[key].(string)
	return s
}

func items(o obj) []obj {
	raw, _ := o["items"].([]any)
	out := make([]obj, 0, len(raw))
	for _, x := range raw {
		if m, ok := x.(obj); ok {
			out = append(out, m)
		}
	}
	return out
}
