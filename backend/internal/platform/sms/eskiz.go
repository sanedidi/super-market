// Package sms — отправка SMS через Eskiz (notify.eskiz.uz).
//
// Eskiz пропускает только тексты по шаблонам, одобренным в кабинете
// (раздел «Шаблоны»), поэтому текст кода входа должен совпадать с шаблоном.
package sms

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Eskiz — клиент Eskiz: токен берётся по логину и обновляется при 401.
type Eskiz struct {
	BaseURL  string // по умолчанию https://notify.eskiz.uz/api
	Email    string
	Password string
	From     string // имя отправителя; по умолчанию 4546
	HTTP     *http.Client

	mu    sync.Mutex
	token string
}

func NewEskiz(baseURL, email, password, from string) *Eskiz {
	if baseURL == "" {
		baseURL = "https://notify.eskiz.uz/api"
	}
	if from == "" {
		from = "4546"
	}
	return &Eskiz{BaseURL: strings.TrimRight(baseURL, "/"), Email: email, Password: password, From: from,
		HTTP: &http.Client{Timeout: 15 * time.Second}}
}

func (e *Eskiz) login(ctx context.Context) (string, error) {
	form := url.Values{"email": {e.Email}, "password": {e.Password}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.BaseURL+"/auth/login", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := e.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var body struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
		Message string `json:"message"`
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err := json.Unmarshal(raw, &body); err != nil || resp.StatusCode != http.StatusOK || body.Data.Token == "" {
		return "", fmt.Errorf("eskiz: вход не удался: %d %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return body.Data.Token, nil
}

// Send отправляет SMS на номер в формате +998XXXXXXXXX.
func (e *Eskiz) Send(ctx context.Context, phone, text string) error {
	for attempt := 0; attempt < 2; attempt++ {
		e.mu.Lock()
		tok := e.token
		e.mu.Unlock()
		if tok == "" {
			t, err := e.login(ctx)
			if err != nil {
				return err
			}
			e.mu.Lock()
			e.token = t
			e.mu.Unlock()
			tok = t
		}
		form := url.Values{"mobile_phone": {strings.TrimPrefix(phone, "+")}, "message": {text}, "from": {e.From}}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.BaseURL+"/message/sms/send", strings.NewReader(form.Encode()))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := e.HTTP.Do(req)
		if err != nil {
			return err
		}
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		resp.Body.Close()
		if resp.StatusCode == http.StatusUnauthorized {
			e.mu.Lock()
			e.token = ""
			e.mu.Unlock()
			continue
		}
		if resp.StatusCode/100 != 2 {
			return fmt.Errorf("eskiz: отправка не удалась: %d %s", resp.StatusCode, strings.TrimSpace(string(raw)))
		}
		return nil
	}
	return fmt.Errorf("eskiz: токен не принят")
}
