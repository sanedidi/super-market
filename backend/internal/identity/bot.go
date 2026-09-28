package identity

import (
	"context"
	"fmt"
	"log/slog"
	"time"

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
}

func NewBot(svc *Service, api BotAPI, log *slog.Logger) *Bot {
	return &Bot{svc: svc, api: api, log: log.With("component", "telegram_bot")}
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
	return b.api.SendMessage(ctx, m.Chat.ID,
		fmt.Sprintf("Готово! Номер %s привязан. Теперь коды для входа будут приходить сюда.", ph),
		&telegram.ReplyMarkup{RemoveKeyboard: true})
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
