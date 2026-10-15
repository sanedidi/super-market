// Package notify — уведомления: супер-админам — в Telegram-бот (туда же, куда
// приходят их коды входа), сотрудникам сетей — push в приложение магазина.
package notify

import (
	"context"
	"log/slog"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
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

// send — query отдаёт chat_id и язык получателя (users.language); текст
// уходит каждому на его языке.
func (n *Notifier) send(ctx context.Context, query string, args []any, text i18n.Text) int {
	rows, err := n.pool.Query(ctx, query, args...)
	if err != nil {
		n.log.Error("выборка получателей", "err", err)
		return 0
	}
	type chat struct {
		id   int64
		lang string
	}
	var chats []chat
	for rows.Next() {
		var c chat
		if rows.Scan(&c.id, &c.lang) == nil {
			chats = append(chats, c)
		}
	}
	rows.Close()
	if n.tg == nil {
		n.log.Info("уведомление (бот не настроен)", "text", text.RU, "recipients", len(chats))
		return 0
	}
	sent := 0
	for _, c := range chats {
		if err := n.tg.SendMessage(ctx, c.id, text.In(c.lang), nil); err != nil {
			n.log.Warn("не удалось отправить уведомление", "chat_id", c, "err", err)
			continue
		}
		sent++
	}
	return sent
}

// SuperAdmins — всем супер-админам, чей номер привязан к боту. Супер-админам —
// всегда по-русски.
func (n *Notifier) SuperAdmins(ctx context.Context, text string) int {
	return n.send(ctx, `
		SELECT tl.chat_id, 'ru' FROM platform_admins pa
		JOIN users u ON u.id = pa.user_id
		JOIN telegram_links tl ON tl.phone = u.phone`, nil, i18n.Text{RU: text})
}

// StoreStaff — сотрудникам магазина с правом permission. Раньше уходило в
// Telegram; теперь Telegram только у супер-админов, а сотрудники получают
// push в приложение магазина: о новых заказах — из очереди заказов
// (push.EnqueueOrderStatus), поэтому здесь ничего не отправляется.
func (n *Notifier) StoreStaff(ctx context.Context, storeID, permission string, text i18n.Text) int {
	n.log.Debug("уведомление сотрудникам магазина — push из очереди заказов", "store_id", storeID, "text", text.RU)
	return 0
}

// staffPush ставит push в приложение магазина каждому, кого вернул query
// (user_id, language), если у него есть устройство с приложением.
func (n *Notifier) staffPush(ctx context.Context, query string, args []any, text i18n.Text) int {
	title := i18n.Text{RU: "Super Market", UZ: "Super Market"}
	body := text
	// Первая строка — заголовок, остальное — текст.
	if i := strings.Index(text.RU, "\n"); i > 0 {
		title.RU, body.RU = strings.TrimSpace(text.RU[:i]), strings.TrimSpace(text.RU[i+1:])
	}
	if i := strings.Index(text.UZ, "\n"); i > 0 {
		title.UZ, body.UZ = strings.TrimSpace(text.UZ[:i]), strings.TrimSpace(text.UZ[i+1:])
	}
	if body.UZ == "" {
		body.UZ = body.RU
	}
	if title.UZ == "" {
		title.UZ = title.RU
	}
	tag, err := n.pool.Exec(ctx, `
		WITH r AS (`+query+`)
		INSERT INTO notifications_outbox (user_id, app, kind, title, body, data)
		SELECT DISTINCT r.user_id, 'store', 'staff_notice',
		       CASE WHEN r.language = 'uz' THEN $`+itoa(len(args)+3)+` ELSE $`+itoa(len(args)+1)+` END,
		       CASE WHEN r.language = 'uz' THEN $`+itoa(len(args)+4)+` ELSE $`+itoa(len(args)+2)+` END, '{}'::jsonb
		FROM r WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = r.user_id AND d.app = 'store')`,
		append(args, title.RU, body.RU, title.UZ, body.UZ)...)
	if err != nil {
		n.log.Error("push сотрудникам", "err", err)
		return 0
	}
	return int(tag.RowsAffected())
}

func itoa(i int) string { return strconv.Itoa(i) }

// NetworkOwners — владельцам сети и сотрудникам с правом permission (все
// магазины): push в приложение магазина, каждому на его языке.
func (n *Notifier) NetworkOwners(ctx context.Context, networkID, permission string, text i18n.Text) int {
	return n.staffPush(ctx, `
		SELECT e.user_id, u.language
		FROM employees e
		JOIN roles r ON r.id = e.role_id
		JOIN users u ON u.id = e.user_id
		WHERE e.network_id = $1 AND e.status = 'active'
		  AND (r.is_owner OR ($2 = ANY(r.permissions) AND e.all_stores))`,
		[]any{networkID, permission}, text)
}

// Employee — одному сотруднику (например, курьеру о назначенном заказе):
// push в приложение, на его языке.
func (n *Notifier) Employee(ctx context.Context, employeeID string, text i18n.Text) int {
	return n.staffPush(ctx, `
		SELECT e.user_id, u.language FROM employees e
		JOIN users u ON u.id = e.user_id
		WHERE e.id = $1 AND e.status = 'active'`, []any{employeeID}, text)
}
