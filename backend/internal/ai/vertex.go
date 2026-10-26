package ai

// Google Vertex AI (Gemini).
//
//	POST {base}/publishers/google/models/{model}:generateContent
//
// base — https://aiplatform.googleapis.com/v1/projects/PROJECT/locations/global
// (регион: https://REGION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/REGION).
//
// Ключ — JSON сервисного аккаунта (роль «Vertex AI User»): по нему сервер сам
// получает OAuth-токен у Google и кладёт в Authorization: Bearer. Либо API-ключ
// Vertex AI (express mode или ключ, привязанный к сервисному аккаунту) — тогда
// он уходит в заголовке x-goog-api-key, а адрес может быть просто
// https://aiplatform.googleapis.com/v1.

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	ProviderVertex   = "vertex"
	DefaultVertexURL = "https://aiplatform.googleapis.com/v1"

	vertexScope    = "https://www.googleapis.com/auth/cloud-platform"
	vertexMaxOut   = 16384
	maxVertexKeyLn = 20000
)

// googleTokenURL — куда менять подписанный JWT на токен. Всегда Google
// (token_uri из JSON не используем — подпись не должна уйти на чужой адрес);
// переменная — для тестов.
var googleTokenURL = "https://oauth2.googleapis.com/token"

// vertexModels — модели Gemini для списка «Показать доступные» (все видят фото).
// У Vertex нет простого списка моделей проекта, поэтому список свой;
// другую модель можно вписать вручную. Gemini 3.x (preview) — только в регионе global.
var vertexModels = []string{
	"gemini-2.5-flash",
	"gemini-2.5-pro",
	"gemini-2.5-flash-lite",
	"gemini-3.1-pro-preview", // gemini-3-pro-preview Google отключил 9 марта 2026
	"gemini-3-flash-preview",
}

// VertexURL — адрес Vertex AI для проекта и региона.
func VertexURL(project, location string) string {
	if location == "" {
		location = "global"
	}
	host := "aiplatform.googleapis.com"
	if location != "global" {
		host = location + "-" + host
	}
	return "https://" + host + "/v1/projects/" + url.PathEscape(project) + "/locations/" + url.PathEscape(location)
}

// isGoogleVertexURL — адрес самого Google (aiplatform.googleapis.com или REGION-aiplatform.googleapis.com).
func isGoogleVertexURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Port() != "" {
		return false
	}
	h := strings.ToLower(u.Hostname())
	return h == "aiplatform.googleapis.com" || strings.HasSuffix(h, "-aiplatform.googleapis.com")
}

// isJSONKey — ключ похож на JSON сервисного аккаунта.
func isJSONKey(key string) bool { return strings.HasPrefix(strings.TrimSpace(key), "{") }

type serviceAccount struct {
	Type         string `json:"type"`
	ProjectID    string `json:"project_id"`
	PrivateKeyID string `json:"private_key_id"`
	PrivateKey   string `json:"private_key"`
	ClientEmail  string `json:"client_email"`

	rsa *rsa.PrivateKey
}

var errBadServiceAccount = &ErrService{
	Msg:   "это не JSON-ключ сервисного аккаунта Google: скачайте его в Google Cloud → IAM → Сервисные аккаунты → Ключи → Добавить ключ → JSON",
	MsgUz: "bu Google servis akkauntining JSON kaliti emas: uni Google Cloud → IAM → Service accounts → Keys → Add key → JSON orqali yuklab oling",
}

func parseServiceAccount(key string) (*serviceAccount, error) {
	var sa serviceAccount
	if err := json.Unmarshal([]byte(key), &sa); err != nil {
		return nil, errBadServiceAccount
	}
	if sa.Type != "service_account" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errBadServiceAccount
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errBadServiceAccount
	}
	var pk any
	var err error
	if pk, err = x509.ParsePKCS8PrivateKey(block.Bytes); err != nil {
		if pk, err = x509.ParsePKCS1PrivateKey(block.Bytes); err != nil {
			return nil, errBadServiceAccount
		}
	}
	k, ok := pk.(*rsa.PrivateKey)
	if !ok {
		return nil, errBadServiceAccount
	}
	sa.rsa = k
	return &sa, nil
}

// keyHint — что показать вместо ключа: последние 4 символа
// (у JSON-ключа — последние 4 символа его private_key_id).
func keyHint(key string) string {
	if isJSONKey(key) {
		if sa, err := parseServiceAccount(key); err == nil {
			return last4(sa.PrivateKeyID)
		}
		return ""
	}
	return last4(key)
}

type cachedToken struct {
	token string
	exp   time.Time
}

var (
	tokenMu    sync.Mutex
	tokenCache = map[[32]byte]cachedToken{}
)

// googleToken — OAuth-токен по JSON сервисного аккаунта (кэшируется почти на час).
func googleToken(ctx context.Context, key string) (string, error) {
	id := sha256.Sum256([]byte(key))
	tokenMu.Lock()
	if t, ok := tokenCache[id]; ok && time.Now().Before(t.exp) {
		tokenMu.Unlock()
		return t.token, nil
	}
	tokenMu.Unlock()

	sa, err := parseServiceAccount(key)
	if err != nil {
		return "", err
	}
	now := time.Now()
	enc := base64.RawURLEncoding
	head, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": sa.PrivateKeyID})
	claims, _ := json.Marshal(map[string]any{
		"iss": sa.ClientEmail, "scope": vertexScope, "aud": googleTokenURL,
		"iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	unsigned := enc.EncodeToString(head) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(unsigned))
	sig, err := rsa.SignPKCS1v15(rand.Reader, sa.rsa, crypto.SHA256, sum[:])
	if err != nil {
		return "", errBadServiceAccount
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {unsigned + "." + enc.EncodeToString(sig)},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, googleTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return "", &ErrService{Msg: "Google не ответил вовремя", MsgUz: "Google oʻz vaqtida javob bermadi", Temporary: true}
		}
		return "", &ErrService{Msg: "не удалось подключиться к Google за токеном", MsgUz: "token olish uchun Googlega ulanib boʻlmadi", Temporary: true}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	_ = json.Unmarshal(raw, &out)
	if resp.StatusCode/100 != 2 || out.AccessToken == "" {
		detail := out.Description
		if detail == "" {
			detail = out.Error
		}
		if len(detail) > 200 {
			detail = detail[:200]
		}
		msg := &ErrService{Status: resp.StatusCode,
			Msg:   "Google не принял ключ сервисного аккаунта (ключ удалён или аккаунт отключён)",
			MsgUz: "Google servis akkaunti kalitini qabul qilmadi (kalit oʻchirilgan yoki akkaunt oʻchirib qoʻyilgan)"}
		if detail != "" {
			msg.Msg += ": " + detail
			msg.MsgUz += ": " + detail
		}
		return "", msg
	}
	ttl := time.Duration(out.ExpiresIn) * time.Second
	if ttl <= 0 {
		ttl = time.Hour
	}
	tokenMu.Lock()
	tokenCache[id] = cachedToken{token: out.AccessToken, exp: now.Add(ttl - 5*time.Minute)}
	tokenMu.Unlock()
	return out.AccessToken, nil
}

// vertexAuth — заголовок авторизации: Bearer по JSON сервисного аккаунта или API-ключ.
func (c Conn) vertexAuth(ctx context.Context, req *http.Request) error {
	if isJSONKey(c.Key) {
		tok, err := googleToken(ctx, c.Key)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		return nil
	}
	req.Header.Set("x-goog-api-key", c.Key)
	return nil
}

// vertexModelList — свой список моделей; JSON-ключ при этом проверяется
// (получаем токен), чтобы ошибку в ключе было видно сразу.
func (c Conn) vertexModelList(ctx context.Context) ([]Model, error) {
	if isJSONKey(c.Key) {
		if _, err := googleToken(ctx, c.Key); err != nil {
			return nil, err
		}
	}
	items := make([]Model, 0, len(vertexModels))
	for _, id := range vertexModels {
		items = append(items, Model{ID: id, Vision: boolp(true)})
	}
	return items, nil
}

// vertexGenerate — generateContent: фото (inlineData) + текст, ответ — JSON.
func (c Conn) vertexGenerate(ctx context.Context, system, prompt string, images []Image) (string, Usage, error) {
	parts := make([]Part, 0, len(images))
	for _, im := range images {
		parts = append(parts, Part{MIME: im.MIME, Data: im.Data})
	}
	return c.geminiGenerate(ctx, system, prompt, parts)
}

// geminiGenerate — generateContent у Vertex AI или Gemini API: вложения
// (фото, аудио, PDF — inlineData) + текст, ответ — JSON.
func (c Conn) geminiGenerate(ctx context.Context, system, prompt string, attachments []Part) (string, Usage, error) {
	parts := []map[string]any{}
	for _, im := range attachments {
		parts = append(parts, map[string]any{"inlineData": map[string]any{
			"mimeType": im.MIME, "data": base64.StdEncoding.EncodeToString(im.Data)}})
	}
	parts = append(parts, map[string]any{"text": prompt})
	gen := map[string]any{"maxOutputTokens": vertexMaxOut, "responseMimeType": "application/json"}
	// Gemini 3 Google советует не трогать temperature (по умолчанию 1.0).
	if !strings.HasPrefix(strings.ToLower(c.Model), "gemini-3") {
		gen["temperature"] = 0.1
	}
	body := map[string]any{
		"contents":         []map[string]any{{"role": "user", "parts": parts}},
		"generationConfig": gen,
	}
	if system != "" {
		body["systemInstruction"] = map[string]any{"parts": []map[string]any{{"text": system}}}
	}
	var out struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text    string `json:"text"`
					Thought bool   `json:"thought"`
				} `json:"parts"`
			} `json:"content"`
			FinishReason string `json:"finishReason"`
		} `json:"candidates"`
		PromptFeedback struct {
			BlockReason string `json:"blockReason"`
		} `json:"promptFeedback"`
		UsageMetadata struct {
			Prompt     int `json:"promptTokenCount"`
			Candidates int `json:"candidatesTokenCount"`
			Thoughts   int `json:"thoughtsTokenCount"`
		} `json:"usageMetadata"`
	}
	path := "/publishers/google/models/" + url.PathEscape(c.Model) + ":generateContent"
	if c.Provider == ProviderGemini {
		path = "/models/" + url.PathEscape(c.Model) + ":generateContent"
	}
	if err := c.do(ctx, http.MethodPost, path, body, &out); err != nil {
		return "", Usage{}, err
	}
	// «Размышления» Gemini оплачиваются как выходные токены.
	u := Usage{Input: out.UsageMetadata.Prompt, Output: out.UsageMetadata.Candidates + out.UsageMetadata.Thoughts}
	if out.PromptFeedback.BlockReason != "" {
		return "", u, &ErrService{Msg: "Gemini отказался обрабатывать запрос (" + out.PromptFeedback.BlockReason + ")",
			MsgUz: "Gemini soʻrovni qayta ishlashdan bosh tortdi (" + out.PromptFeedback.BlockReason + ")"}
	}
	if len(out.Candidates) == 0 {
		return "", u, &ErrService{Msg: "модель вернула пустой ответ", MsgUz: "model boʻsh javob qaytardi"}
	}
	cand := out.Candidates[0]
	var b strings.Builder
	for _, p := range cand.Content.Parts {
		if !p.Thought {
			b.WriteString(p.Text)
		}
	}
	if b.Len() == 0 {
		switch cand.FinishReason {
		case "MAX_TOKENS":
			return "", u, &ErrService{Msg: "модель не уложилась в лимит ответа", MsgUz: "model javob limitiga sigʻmadi"}
		case "", "STOP":
			return "", u, &ErrService{Msg: "модель вернула пустой ответ", MsgUz: "model boʻsh javob qaytardi"}
		default:
			return "", u, &ErrService{Msg: "Gemini не ответил (" + cand.FinishReason + ")", MsgUz: "Gemini javob bermadi (" + cand.FinishReason + ")"}
		}
	}
	return b.String(), u, nil
}

// vertexProject — project_id из JSON-ключа (для адреса по умолчанию).
func vertexProject(key string) string {
	if !isJSONKey(key) {
		return ""
	}
	sa, err := parseServiceAccount(key)
	if err != nil {
		return ""
	}
	return sa.ProjectID
}
