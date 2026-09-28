// Package notify — уведомления сотрудникам и супер-админам в Telegram-бот
// (в тот же чат, куда приходят коды входа).
package notify

import (
	"context"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
)

// Sender — отправка сообщения в Telegram.
type Sender interface {
	SendMessage(ctx context.Context, chatID int64, text string, markup *telegram.ReplyMarkup) error
}

type Notifier struct {
	pool *pgxpool.Pool
	tg   Sender // nil — бот не настроен, уведомления только в лог
	log  *slog.Logger
}

func New(pool *pgxpool.Pool, tg Sender, log *slog.Logger) *Notifier {
	return &Notifier{pool: pool, tg: tg, log: log.With("component", "notify")}
}

func (n *Notifier) send(ctx context.Context, query string, args []any, text string) int {
	rows, err := n.pool.Query(ctx, query, args...)
	if err != nil {
		n.log.Error("выборка получателей", "err", err)
		return 0
	}
	var chats []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			chats = append(chats, id)
		}
	}
	rows.Close()
	if n.tg == nil {
		n.log.Info("уведомление (бот не настроен)", "text", text, "recipients", len(chats))
		return 0
	}
	sent := 0
	for _, c := range chats {
		if err := n.tg.SendMessage(ctx, c, text, nil); err != nil {
			n.log.Warn("не удалось отправить уведомление", "chat_id", c, "err", err)
			continue
		}
		sent++
	}
	return sent
}

// SuperAdmins — всем супер-админам, чей номер привязан к боту.
func (n *Notifier) SuperAdmins(ctx context.Context, text string) int {
	return n.send(ctx, `
		SELECT tl.chat_id FROM platform_admins pa
		JOIN users u ON u.id = pa.user_id
		JOIN telegram_links tl ON tl.phone = u.phone`, nil, text)
}

// StoreStaff — сотрудникам с доступом к магазину и правом permission
// (владельцу — всегда).
func (n *Notifier) StoreStaff(ctx context.Context, storeID, permission, text string) int {
	return n.send(ctx, `
		SELECT DISTINCT tl.chat_id
		FROM stores s
		JOIN employees e ON e.network_id = s.network_id AND e.status = 'active'
		JOIN roles r ON r.id = e.role_id
		JOIN users u ON u.id = e.user_id
		JOIN telegram_links tl ON tl.phone = u.phone
		WHERE s.id = $1
		  AND (r.is_owner OR $2 = ANY(r.permissions))
		  AND (r.is_owner OR e.all_stores OR EXISTS (
		       SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id = s.id))`,
		[]any{storeID, permission}, text)
}
