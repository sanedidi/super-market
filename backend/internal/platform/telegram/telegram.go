// Package telegram — минимальный клиент Telegram Bot API:
// отправка сообщений и получение обновлений (long polling).
package telegram

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Client работает с одним ботом.
type Client struct {
	baseURL string
	http    *http.Client
}

// New создаёт клиента. baseURL можно подменить в тестах;
// пустой — настоящий https://api.telegram.org.
func New(botToken, baseURL string) *Client {
	if baseURL == "" {
		baseURL = "https://api.telegram.org"
	}
	return &Client{
		baseURL: fmt.Sprintf("%s/bot%s", baseURL, botToken),
		http:    &http.Client{Timeout: 60 * time.Second},
	}
}

// Update — входящее событие от Telegram. Нам нужны только сообщения.
type Update struct {
	UpdateID int64    `json:"update_id"`
	Message  *Message `json:"message"`
}

type Message struct {
	MessageID int64    `json:"message_id"`
	From      *User    `json:"from"`
	Chat      Chat     `json:"chat"`
	Text      string   `json:"text"`
	Contact   *Contact `json:"contact"`
}

type User struct {
	ID        int64  `json:"id"`
	FirstName string `json:"first_name"`
	Username  string `json:"username"`
}

type Chat struct {
	ID   int64  `json:"id"`
	Type string `json:"type"`
}

type Contact struct {
	PhoneNumber string `json:"phone_number"`
	FirstName   string `json:"first_name"`
	UserID      int64  `json:"user_id"`
}

// ReplyMarkup — клавиатура под полем ввода.
type ReplyMarkup struct {
	Keyboard        [][]KeyboardButton `json:"keyboard,omitempty"`
	ResizeKeyboard  bool               `json:"resize_keyboard,omitempty"`
	OneTimeKeyboard bool               `json:"one_time_keyboard,omitempty"`
	RemoveKeyboard  bool               `json:"remove_keyboard,omitempty"`
}

type KeyboardButton struct {
	Text           string `json:"text"`
	RequestContact bool   `json:"request_contact,omitempty"`
}

// GetMe возвращает данные бота (нужен username для ссылки t.me/...).
func (c *Client) GetMe(ctx context.Context) (User, error) {
	var u User
	err := c.call(ctx, "getMe", map[string]any{}, &u)
	return u, err
}

// SendMessage отправляет текст в чат. markup может быть nil.
func (c *Client) SendMessage(ctx context.Context, chatID int64, text string, markup *ReplyMarkup) error {
	body := map[string]any{"chat_id": chatID, "text": text}
	if markup != nil {
		body["reply_markup"] = markup
	}
	return c.call(ctx, "sendMessage", body, nil)
}

// GetUpdates ждёт новые события до timeout (long polling).
func (c *Client) GetUpdates(ctx context.Context, offset int64, timeout time.Duration) ([]Update, error) {
	var out []Update
	err := c.call(ctx, "getUpdates", map[string]any{
		"offset":          offset,
		"timeout":         int(timeout.Seconds()),
		"allowed_updates": []string{"message"},
	}, &out)
	return out, err
}

type apiResponse struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	Description string          `json:"description"`
}

func (c *Client) call(ctx context.Context, method string, body any, result any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/"+method, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("telegram %s: %w", method, err)
	}
	defer resp.Body.Close()

	var r apiResponse
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return fmt.Errorf("telegram %s: ответ HTTP %d: %w", method, resp.StatusCode, err)
	}
	if !r.OK {
		return fmt.Errorf("telegram %s: %s", method, r.Description)
	}
	if result != nil {
		return json.Unmarshal(r.Result, result)
	}
	return nil
}
