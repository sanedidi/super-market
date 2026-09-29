package push

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
)

// Sender — отправка на устройство (FCM или подмена в тестах).
type Sender interface {
	Send(ctx context.Context, deviceToken string, m Message) error
}

// TelegramSender — запасной канал.
type TelegramSender interface {
	SendMessage(ctx context.Context, chatID int64, text string, markup *telegram.ReplyMarkup) error
}

const maxAttempts = 6

// Dispatcher отправляет уведомления из очереди.
type Dispatcher struct {
	pool *pgxpool.Pool
	fcm  Sender         // nil — push не настроен
	tg   TelegramSender // nil — бот не настроен
	log  *slog.Logger
}

func NewDispatcher(pool *pgxpool.Pool, fcm Sender, tg TelegramSender, log *slog.Logger) *Dispatcher {
	return &Dispatcher{pool: pool, fcm: fcm, tg: tg, log: log.With("component", "push")}
}

// Run отправляет очередь каждые every, пока не отменён ctx.
func (d *Dispatcher) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		if _, err := d.Tick(ctx); err != nil && ctx.Err() == nil {
			d.log.Error("очередь уведомлений", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

type queued struct {
	id           int64
	userID       string
	title, body  string
	data         map[string]any
	attempts     int
	viaTelegram  bool
	telegramChat *int64
}

// Tick отправляет готовые к отправке уведомления и возвращает их число.
func (d *Dispatcher) Tick(ctx context.Context) (int, error) {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	rows, err := tx.Query(ctx, `
		SELECT n.id, n.user_id, n.title, n.body, n.data, n.attempts,
		       COALESCE(c.notify_telegram, true), tl.chat_id
		FROM notifications_outbox n
		JOIN users u ON u.id = n.user_id
		LEFT JOIN customers c ON c.user_id = n.user_id
		LEFT JOIN telegram_links tl ON tl.phone = u.phone
		WHERE n.status = 'pending' AND n.send_after <= now()
		ORDER BY n.id LIMIT 50
		FOR UPDATE OF n SKIP LOCKED`)
	if err != nil {
		return 0, err
	}
	var batch []queued
	for rows.Next() {
		var q queued
		if err := rows.Scan(&q.id, &q.userID, &q.title, &q.body, &q.data, &q.attempts, &q.viaTelegram, &q.telegramChat); err != nil {
			rows.Close()
			return 0, err
		}
		batch = append(batch, q)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	for _, q := range batch {
		channel, retry, lastErr := d.deliver(ctx, tx, q)
		switch {
		case channel != "":
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET status = 'sent', channel = $2, sent_at = now(),
				attempts = attempts + 1, last_error = '' WHERE id = $1`, q.id, channel)
		case retry && q.attempts+1 < maxAttempts:
			// 30 с, 1, 2, 4, 8 мин.
			delay := time.Duration(30<<q.attempts) * time.Second
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET attempts = attempts + 1, last_error = $2,
				send_after = now() + $3::interval WHERE id = $1`, q.id, errText(lastErr), delay.String())
		case lastErr != nil:
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET status = 'failed', attempts = attempts + 1,
				last_error = $2 WHERE id = $1`, q.id, errText(lastErr))
		default:
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET status = 'skipped', attempts = attempts + 1,
				last_error = 'нет устройств и Telegram' WHERE id = $1`, q.id)
		}
		if err != nil {
			return 0, err
		}
	}
	return len(batch), tx.Commit(ctx)
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if len(s) > 500 {
		s = s[:500]
	}
	return s
}

// deliver: push на все устройства; если ни одно не приняло — Telegram.
func (d *Dispatcher) deliver(ctx context.Context, tx pgx.Tx, q queued) (channel string, retry bool, lastErr error) {
	if d.fcm != nil {
		rows, err := tx.Query(ctx, `SELECT id, token FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC LIMIT 10`, q.userID)
		if err != nil {
			return "", true, err
		}
		type dev struct{ id, token string }
		var devs []dev
		for rows.Next() {
			var x dev
			if err := rows.Scan(&x.id, &x.token); err != nil {
				rows.Close()
				return "", true, err
			}
			devs = append(devs, x)
		}
		rows.Close()

		data := map[string]string{}
		for k, v := range q.data {
			if s, ok := v.(string); ok {
				data[k] = s
			}
		}
		msg := Message{Title: q.title, Body: q.body, Data: data}
		for _, x := range devs {
			err := d.fcm.Send(ctx, x.token, msg)
			switch {
			case err == nil:
				channel = "push"
			case errors.Is(err, ErrUnregistered):
				if _, err := tx.Exec(ctx, `DELETE FROM devices WHERE id = $1`, x.id); err != nil {
					return "", true, err
				}
			case errors.Is(err, ErrPermanent):
				lastErr = err
			default:
				lastErr, retry = err, true
			}
		}
		if channel != "" {
			return channel, false, nil
		}
	}

	if d.tg != nil && q.viaTelegram && q.telegramChat != nil {
		if err := d.tg.SendMessage(ctx, *q.telegramChat, q.title+"\n"+q.body, nil); err != nil {
			return "", true, err
		}
		return "telegram", false, nil
	}
	return "", retry, lastErr
}
