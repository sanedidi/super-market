package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/platform/token"
)

// client вызывает обработчик API напрямую, без сети.
type client struct {
	h    http.Handler
	code string
	// Номер и код из REVIEW_LOGIN: для него сервер принимает только этот код.
	reviewPhone, reviewCode string
	// В приложение магазина входят по логину и паролю. Инструмент пароли
	// сотрудников не знает и не меняет — сессию сотрудника он открывает
	// напрямую в базе (её удалит seeder.finish).
	pool   *pgxpool.Pool
	secret string
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
// В приложение магазина — сессия сотрудника напрямую (см. storeSession).
func (c client) loginTerms(ph, app string, terms bool) (string, error) {
	if app == identity.AppStore {
		return c.storeSession(ph)
	}
	if _, err := c.call("POST", "/auth/otp/request", "", obj{"phone": ph, "app": app}, http.StatusOK); err != nil {
		return "", err
	}
	code := c.code
	if c.reviewPhone != "" && ph == c.reviewPhone {
		code = c.reviewCode
	}
	out, err := c.call("POST", "/auth/otp/verify", "", obj{"phone": ph, "code": code, "app": app, "terms_accepted": terms}, http.StatusOK)
	if err != nil {
		return "", err
	}
	return str(out, "access_token"), nil
}

// storeSession открывает сессию активного сотрудника с номером ph в
// приложении магазина и выдаёт access-токен на час.
func (c client) storeSession(raw string) (string, error) {
	if c.pool == nil || c.secret == "" {
		return "", errors.New("вход в магазин: нет доступа к базе")
	}
	ph, err := phone.Normalize(raw)
	if err != nil {
		return "", fmt.Errorf("вход в магазин: номер %q: %w", raw, err)
	}
	ctx := context.Background()
	var userID string
	err = c.pool.QueryRow(ctx, `
		SELECT u.id::text FROM users u
		JOIN employees e ON e.user_id = u.id AND e.status = 'active'
		JOIN networks n ON n.id = e.network_id AND n.status = 'active'
		WHERE u.phone = $1`, ph).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("вход в магазин: %s не сотрудник активной сети", ph)
	}
	if err != nil {
		return "", err
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	hash := sha256.Sum256([]byte(base64.RawURLEncoding.EncodeToString(b)))
	var sessionID string
	if err := c.pool.QueryRow(ctx, `
		INSERT INTO sessions (user_id, app, refresh_hash, user_agent, expires_at)
		VALUES ($1, $2, $3, 'demo-seed', now() + interval '1 hour') RETURNING id::text`,
		userID, identity.AppStore, hash[:]).Scan(&sessionID); err != nil {
		return "", err
	}
	return token.NewSigner(c.secret).Sign(token.Claims{UserID: userID, SessionID: sessionID, App: identity.AppStore}, time.Hour)
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
