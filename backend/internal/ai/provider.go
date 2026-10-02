// Package ai — подключение к ИИ-сервису, который выбрал супер-админ:
// OpenAI и совместимые (OpenRouter, DeepSeek, Groq, своя модель) или Anthropic.
// Ключ хранится зашифрованным, наружу не отдаётся.
package ai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

const (
	ProviderOpenAI    = "openai"
	ProviderAnthropic = "anthropic"

	DefaultOpenAIURL    = "https://api.openai.com/v1"
	DefaultAnthropicURL = "https://api.anthropic.com"

	anthropicVersion = "2023-06-01"
)

// Conn — куда и с чем ходить.
type Conn struct {
	Provider string
	BaseURL  string
	Key      string
	Model    string
}

// Image — фото для модели.
type Image struct {
	MIME string
	Data []byte
}

// Model — модель из списка ключа. Vision — видит ли изображения
// (по названию; nil — неизвестно).
type Model struct {
	ID     string `json:"id"`
	Vision *bool  `json:"vision"`
}

var client = &http.Client{Timeout: 150 * time.Second}

// ErrService — сервис ответил ошибкой; текст — для человека.
type ErrService struct {
	Status int
	Msg    string
}

func (e *ErrService) Error() string { return e.Msg }

func (c Conn) base() string { return strings.TrimRight(strings.TrimSpace(c.BaseURL), "/") }

func (c Conn) do(ctx context.Context, method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base()+path, rd)
	if err != nil {
		return &ErrService{Msg: "неверный адрес сервиса"}
	}
	req.Header.Set("Content-Type", "application/json")
	if c.Provider == ProviderAnthropic {
		req.Header.Set("x-api-key", c.Key)
		req.Header.Set("anthropic-version", anthropicVersion)
	} else {
		req.Header.Set("Authorization", "Bearer "+c.Key)
	}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return &ErrService{Msg: "сервис не ответил вовремя"}
		}
		return &ErrService{Msg: "не удалось подключиться к сервису: проверьте адрес"}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode/100 != 2 {
		return &ErrService{Status: resp.StatusCode, Msg: serviceError(resp.StatusCode, raw)}
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return &ErrService{Msg: "сервис вернул непонятный ответ — это точно API с протоколом " + protoName(c.Provider) + "?"}
	}
	return nil
}

func protoName(p string) string {
	if p == ProviderAnthropic {
		return "Anthropic"
	}
	return "OpenAI"
}

// serviceError — понятная причина вместо кода ответа.
func serviceError(status int, raw []byte) string {
	var e struct {
		Error any `json:"error"`
	}
	detail := ""
	if json.Unmarshal(raw, &e) == nil {
		switch v := e.Error.(type) {
		case string:
			detail = v
		case map[string]any:
			if m, ok := v["message"].(string); ok {
				detail = m
			}
		}
	}
	if len(detail) > 200 {
		detail = detail[:200]
	}
	var msg string
	switch status {
	case 401, 403:
		msg = "ключ не подходит к этому сервису"
	case 404:
		msg = "сервис не найден по этому адресу или модель недоступна"
	case 402, 429:
		msg = "сервис отказал: закончились средства или превышен лимит"
	default:
		if status >= 500 {
			msg = fmt.Sprintf("сервис временно недоступен (%d)", status)
		} else {
			msg = fmt.Sprintf("сервис отклонил запрос (%d)", status)
		}
	}
	if detail != "" {
		msg += ": " + detail
	}
	return msg
}

// Models — модели, доступные ключу.
func (c Conn) Models(ctx context.Context) ([]Model, error) {
	var out struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	path := "/models"
	if c.Provider == ProviderAnthropic {
		path = "/v1/models?limit=1000"
	}
	if err := c.do(ctx, http.MethodGet, path, nil, &out); err != nil {
		return nil, err
	}
	items := make([]Model, 0, len(out.Data))
	for _, m := range out.Data {
		if m.ID == "" {
			continue
		}
		items = append(items, Model{ID: m.ID, Vision: visionGuess(c.Provider, m.ID)})
	}
	sort.SliceStable(items, func(i, j int) bool {
		vi, vj := items[i].Vision != nil && *items[i].Vision, items[j].Vision != nil && *items[j].Vision
		if vi != vj {
			return vi
		}
		return items[i].ID < items[j].ID
	})
	return items, nil
}

func boolp(b bool) *bool { return &b }

// visionGuess — видит ли модель фото, по названию. Для незнакомых — nil.
func visionGuess(provider, id string) *bool {
	s := strings.ToLower(id)
	if provider == ProviderAnthropic {
		return boolp(!strings.Contains(s, "claude-2") && !strings.Contains(s, "instant"))
	}
	for _, no := range []string{"embedding", "whisper", "tts", "dall-e", "moderation", "gpt-3.5", "davinci", "babbage", "audio", "realtime", "transcribe", "search"} {
		if strings.Contains(s, no) {
			return boolp(false)
		}
	}
	for _, yes := range []string{"gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "o1", "o3", "o4", "vision", "-vl", "vl-", "gemini", "claude", "llava", "pixtral", "llama-4", "llama-3.2-11b", "llama-3.2-90b", "qwen2.5-vl", "qwen-vl", "grok-2-vision", "grok-4", "mistral-medium", "mistral-small-3"} {
		if strings.Contains(s, yes) {
			return boolp(true)
		}
	}
	return nil
}

// Vision — запрос к модели с фото; ответ — текст модели.
func (c Conn) Vision(ctx context.Context, system, prompt string, images []Image) (string, error) {
	if c.Model == "" {
		return "", &ErrService{Msg: "не выбрана модель"}
	}
	if c.Provider == ProviderAnthropic {
		content := []map[string]any{}
		for _, im := range images {
			content = append(content, map[string]any{"type": "image", "source": map[string]any{
				"type": "base64", "media_type": im.MIME, "data": base64.StdEncoding.EncodeToString(im.Data)}})
		}
		content = append(content, map[string]any{"type": "text", "text": prompt})
		var out struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		}
		err := c.do(ctx, http.MethodPost, "/v1/messages", map[string]any{
			"model": c.Model, "max_tokens": 8000, "system": system,
			"messages": []map[string]any{{"role": "user", "content": content}},
		}, &out)
		if err != nil {
			return "", err
		}
		var b strings.Builder
		for _, p := range out.Content {
			if p.Type == "text" {
				b.WriteString(p.Text)
			}
		}
		return b.String(), nil
	}
	content := []map[string]any{{"type": "text", "text": prompt}}
	for _, im := range images {
		content = append(content, map[string]any{"type": "image_url", "image_url": map[string]any{
			"url": "data:" + im.MIME + ";base64," + base64.StdEncoding.EncodeToString(im.Data)}})
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	err := c.do(ctx, http.MethodPost, "/chat/completions", map[string]any{
		"model": c.Model,
		"messages": []map[string]any{
			{"role": "system", "content": system},
			{"role": "user", "content": content},
		},
	}, &out)
	if err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", &ErrService{Msg: "модель вернула пустой ответ"}
	}
	return out.Choices[0].Message.Content, nil
}

// ExtractJSON — первый JSON-объект из ответа модели (модели любят обёртки ```json).
func ExtractJSON(s string) ([]byte, error) {
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end <= start {
		return nil, errors.New("в ответе модели нет JSON")
	}
	return []byte(s[start : end+1]), nil
}

// AsAppErr — ошибка сервиса как 502 с понятным текстом.
func AsAppErr(err error) error {
	var se *ErrService
	if errors.As(err, &se) {
		return apperr.New(http.StatusBadGateway, "ai_error", se.Msg)
	}
	return err
}
