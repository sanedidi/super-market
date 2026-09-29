package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
)

// BotAPI — то, что боту нужно от Telegram.
type BotAPI interface {
	Sender
	GetUpdates(ctx context.Context, offset int64, timeout time.Duration) ([]telegram.Update, error)
}

// Bot принимает номер телефона от пользователя и связывает его с чатом,
// куда потом приходят коды входа.
type Bot struct {
	svc *Service
	api BotAPI
	log *slog.Logger

	// Deeplinks — обработчики ссылок вида t.me/<bot>?start=<prefix>_<code>
	// по префиксу. Получают номер пользователя и код, возвращают текст ответа.
	Deeplinks map[string]DeeplinkFunc

	mu      sync.Mutex
	pending map[int64]string // tg user → payload, пока номер не привязан
}

// DeeplinkFunc обрабатывает /start с параметром для пользователя с номером phone.
type DeeplinkFunc func(ctx context.Context, phone, code string) (string, error)

func NewBot(svc *Service, api BotAPI, log *slog.Logger) *Bot {
	return &Bot{svc: svc, api: api, log: log.With("component", "telegram_bot"), pending: map[int64]string{}}
}

var shareContactKeyboard = &telegram.ReplyMarkup{
	Keyboard:        [][]telegram.KeyboardButton{{{Text: "Поделиться номером", RequestContact: true}}},
	ResizeKeyboard:  true,
	OneTimeKeyboard: true,
}

// Run читает обновления, пока не отменён ctx. Ошибки сети не
// останавливают бота: пауза и следующая попытка.
func (b *Bot) Run(ctx context.Context) {
	b.log.Info("бот запущен")
	var offset int64
	for ctx.Err() == nil {
		updates, err := b.api.GetUpdates(ctx, offset, 30*time.Second)
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			b.log.Warn("getUpdates", "err", err)
			select {
			case <-ctx.Done():
			case <-time.After(3 * time.Second):
			}
			continue
		}
		for _, u := range updates {
			offset = u.UpdateID + 1
			if err := b.Handle(ctx, u); err != nil {
				b.log.Error("обработка сообщения", "update_id", u.UpdateID, "err", err)
			}
		}
	}
	b.log.Info("бот остановлен")
}

// Handle обрабатывает одно обновление.
func (b *Bot) Handle(ctx context.Context, u telegram.Update) error {
	m := u.Message
	if m == nil || m.From == nil || m.Chat.Type != "private" {
		return nil
	}

	if m.Contact == nil {
		if payload, ok := strings.CutPrefix(m.Text, "/start "); ok {
			if handled, err := b.deeplink(ctx, m.Chat.ID, m.From.ID, strings.TrimSpace(payload)); handled || err != nil {
				return err
			}
		}
		return b.api.SendMessage(ctx, m.Chat.ID,
			"Здравствуйте! Чтобы получать коды для входа, нажмите кнопку «Поделиться номером» ниже.",
			shareContactKeyboard)
	}

	// Принимаем только свой номер: переслать чужой контакт нельзя.
	if m.Contact.UserID != m.From.ID {
		return b.api.SendMessage(ctx, m.Chat.ID,
			"Можно привязать только свой номер. Нажмите кнопку «Поделиться номером».",
			shareContactKeyboard)
	}

	ph, err := phone.Normalize(m.Contact.PhoneNumber)
	if err != nil {
		return b.api.SendMessage(ctx, m.Chat.ID, "Не удалось распознать номер телефона.", nil)
	}
	if err := b.svc.LinkTelegram(ctx, ph, m.Chat.ID, m.From.ID); err != nil {
		return err
	}
	b.log.Info("номер привязан", "tg_user_id", m.From.ID)
	if err := b.api.SendMessage(ctx, m.Chat.ID,
		fmt.Sprintf("Готово! Номер %s привязан. Теперь коды для входа будут приходить сюда.", ph),
		&telegram.ReplyMarkup{RemoveKeyboard: true}); err != nil {
		return err
	}
	b.mu.Lock()
	payload, ok := b.pending[m.From.ID]
	delete(b.pending, m.From.ID)
	b.mu.Unlock()
	if ok {
		_, err := b.runDeeplink(ctx, m.Chat.ID, ph, payload)
		return err
	}
	return nil
}

// deeplink обрабатывает /start <payload>. Если номер ещё не привязан —
// запоминает payload и просит поделиться номером.
func (b *Bot) deeplink(ctx context.Context, chatID, tgUserID int64, payload string) (bool, error) {
	prefix, _, ok := strings.Cut(payload, "_")
	if !ok || b.Deeplinks[prefix] == nil {
		return false, nil
	}
	var ph string
	err := b.svc.pool.QueryRow(ctx, `SELECT phone FROM telegram_links WHERE tg_user_id = $1 ORDER BY linked_at DESC LIMIT 1`, tgUserID).Scan(&ph)
	if err != nil {
		b.mu.Lock()
		if len(b.pending) > 10000 {
			b.pending = map[int64]string{}
		}
		b.pending[tgUserID] = payload
		b.mu.Unlock()
		return true, b.api.SendMessage(ctx, chatID,
			"Здравствуйте! Чтобы продолжить, нажмите кнопку «Поделиться номером» ниже.", shareContactKeyboard)
	}
	return b.runDeeplink(ctx, chatID, ph, payload)
}

func (b *Bot) runDeeplink(ctx context.Context, chatID int64, ph, payload string) (bool, error) {
	prefix, code, _ := strings.Cut(payload, "_")
	h := b.Deeplinks[prefix]
	if h == nil {
		return false, nil
	}
	text, err := h(ctx, ph, code)
	if err != nil {
		b.log.Info("deeplink отклонён", "prefix", prefix, "err", err)
		text = "Не получилось: " + errText(err)
	}
	return true, b.api.SendMessage(ctx, chatID, text, nil)
}

// LinkTelegram запоминает, в какой чат отправлять коды для номера.
func (s *Service) LinkTelegram(ctx context.Context, ph string, chatID, tgUserID int64) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO telegram_links (phone, chat_id, tg_user_id) VALUES ($1, $2, $3)
		ON CONFLICT (phone) DO UPDATE
		SET chat_id = EXCLUDED.chat_id, tg_user_id = EXCLUDED.tg_user_id, linked_at = now()`,
		ph, chatID, tgUserID)
	return err
}

func errText(err error) string {
	var ae *apperr.Error
	if errors.As(err, &ae) {
		return ae.Message
	}
	return "попробуйте позже"
}
