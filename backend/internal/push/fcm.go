package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// Message — уведомление на одно устройство.
type Message struct {
	Title string
	Body  string
	Data  map[string]string
}

// ErrUnregistered — токен устройства больше не действует, его надо удалить.
var ErrUnregistered = errors.New("fcm: токен устройства недействителен")

// ErrPermanent — повтор не поможет (например, неверный запрос).
var ErrPermanent = errors.New("fcm: сообщение отклонено")

// FCM — отправка через Firebase Cloud Messaging HTTP v1 с сервисным аккаунтом.
type FCM struct {
	projectID string
	email     string
	key       *rsa.PrivateKey
	tokenURI  string
	sendURL   string
	http      *http.Client

	mu     sync.Mutex
	access string
	exp    time.Time
}

type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// LoadCredentials читает ключ сервисного аккаунта: JSON как есть, путь к
// файлу или JSON в base64 (удобно хранить в .env одной строкой).
func LoadCredentials(v string) ([]byte, error) {
	v = strings.TrimSpace(v)
	switch {
	case v == "":
		return nil, nil
	case strings.HasPrefix(v, "{"):
		return []byte(v), nil
	}
	if b, err := os.ReadFile(v); err == nil {
		return b, nil
	}
	b, err := base64.StdEncoding.DecodeString(v)
	if err != nil {
		return nil, errors.New("FCM_CREDENTIALS: ожидается JSON, путь к файлу или base64")
	}
	return b, nil
}

// NewFCM создаёт отправителя из JSON ключа сервисного аккаунта Firebase.
func NewFCM(credentials []byte) (*FCM, error) {
	var sa serviceAccount
	if err := json.Unmarshal(credentials, &sa); err != nil {
		return nil, fmt.Errorf("FCM: ключ сервисного аккаунта: %w", err)
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errors.New("FCM: в ключе нет project_id, client_email или private_key")
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errors.New("FCM: private_key не в формате PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("FCM: private_key: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("FCM: ожидается RSA-ключ")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &FCM{
		projectID: sa.ProjectID, email: sa.ClientEmail, key: key, tokenURI: sa.TokenURI,
		sendURL: "https://fcm.googleapis.com/v1/projects/" + sa.ProjectID + "/messages:send",
		http:    &http.Client{Timeout: 15 * time.Second},
	}, nil
}

// token — OAuth-токен доступа, кешируется до истечения.
func (f *FCM) token(ctx context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.access != "" && time.Until(f.exp) > time.Minute {
		return f.access, nil
	}
	now := time.Now()
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	unsigned := enc(map[string]string{"alg": "RS256", "typ": "JWT"}) + "." + enc(map[string]any{
		"iss": f.email, "scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud": f.tokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	sum := sha256.Sum256([]byte(unsigned))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {unsigned + "." + base64.RawURLEncoding.EncodeToString(sig)},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.tokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := f.http.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if res.StatusCode != http.StatusOK || json.Unmarshal(body, &out) != nil || out.AccessToken == "" {
		return "", fmt.Errorf("FCM: токен доступа: статус %d: %s", res.StatusCode, strings.TrimSpace(string(body)))
	}
	f.access, f.exp = out.AccessToken, now.Add(time.Duration(out.ExpiresIn)*time.Second)
	return f.access, nil
}

// Send отправляет уведомление на устройство.
func (f *FCM) Send(ctx context.Context, deviceToken string, m Message) error {
	access, err := f.token(ctx)
	if err != nil {
		return err
	}
	payload := map[string]any{"message": map[string]any{
		"token":        deviceToken,
		"notification": map[string]string{"title": m.Title, "body": m.Body},
		"data":         m.Data,
		"android": map[string]any{
			"priority":     "high",
			"notification": map[string]any{"channel_id": "orders", "sound": "default"},
		},
		"apns": map[string]any{"payload": map[string]any{"aps": map[string]any{"sound": "default"}}},
	}}
	b, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.sendURL, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	res, err := f.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusOK {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	var e struct {
		Error struct {
			Status  string `json:"status"`
			Message string `json:"message"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	code := e.Error.Status
	for _, d := range e.Error.Details {
		if d.ErrorCode != "" {
			code = d.ErrorCode
		}
	}
	switch {
	case res.StatusCode == http.StatusNotFound || code == "UNREGISTERED" || code == "NOT_FOUND":
		return ErrUnregistered
	case res.StatusCode == http.StatusUnauthorized:
		f.mu.Lock()
		f.access = ""
		f.mu.Unlock()
		return fmt.Errorf("FCM: доступ отклонён: %s", e.Error.Message)
	case res.StatusCode == http.StatusBadRequest || res.StatusCode == http.StatusForbidden || code == "SENDER_ID_MISMATCH":
		return fmt.Errorf("%w: %s %s", ErrPermanent, code, e.Error.Message)
	}
	return fmt.Errorf("FCM: статус %d: %s", res.StatusCode, strings.TrimSpace(e.Error.Message))
}
