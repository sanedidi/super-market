// Package token выпускает и проверяет access-токены (JWT, HS256).
//
// Реализация своя и короткая, чтобы было видно, что внутри JWT:
// base64url(header).base64url(claims).base64url(HMAC-SHA256(подписи)).
package token

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

var (
	ErrMalformed = errors.New("токен повреждён")
	ErrSignature = errors.New("неверная подпись токена")
	ErrExpired   = errors.New("срок действия токена истёк")
)

// Claims — содержимое access-токена.
type Claims struct {
	UserID    string `json:"sub"`
	SessionID string `json:"sid"`
	App       string `json:"app"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
}

// Signer подписывает и проверяет токены одним секретом.
type Signer struct {
	secret []byte
	now    func() time.Time
}

func NewSigner(secret string) *Signer {
	return &Signer{secret: []byte(secret), now: time.Now}
}

var header = base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))

// Sign выпускает токен со сроком жизни ttl.
func (s *Signer) Sign(c Claims, ttl time.Duration) (string, error) {
	now := s.now()
	c.IssuedAt = now.Unix()
	c.ExpiresAt = now.Add(ttl).Unix()
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	unsigned := header + "." + base64.RawURLEncoding.EncodeToString(payload)
	return unsigned + "." + s.sign(unsigned), nil
}

// Verify проверяет заголовок, подпись и срок и возвращает claims.
func (s *Signer) Verify(tok string) (Claims, error) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 || parts[0] != header {
		// Принимаем только наш заголовок: так нельзя подсунуть alg=none.
		return Claims{}, ErrMalformed
	}
	unsigned := parts[0] + "." + parts[1]
	if !hmac.Equal([]byte(parts[2]), []byte(s.sign(unsigned))) {
		return Claims{}, ErrSignature
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Claims{}, ErrMalformed
	}
	var c Claims
	if err := json.Unmarshal(payload, &c); err != nil {
		return Claims{}, ErrMalformed
	}
	if s.now().Unix() >= c.ExpiresAt {
		return Claims{}, ErrExpired
	}
	return c, nil
}

func (s *Signer) sign(unsigned string) string {
	m := hmac.New(sha256.New, s.secret)
	m.Write([]byte(unsigned))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
