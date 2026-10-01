package push

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Sender — отправка на устройство (FCM или подмена в тестах).
type Sender interface {
	Send(ctx context.Context, deviceToken string, m Message) error
}

const maxAttempts = 6

// Dispatcher отправляет уведомления из очереди и запускает рассылки,
// у которых подошло время.
type Dispatcher struct {
	pool *pgxpool.Pool
	fcm  Sender // nil — push не настроен
	log  *slog.Logger
}

func NewDispatcher(pool *pgxpool.Pool, fcm Sender, log *slog.Logger) *Dispatcher {
	return &Dispatcher{pool: pool, fcm: fcm, log: log.With("component", "push")}
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
	id       int64
	userID   string
	title    string
	body     string
	data     map[string]any
	attempts int
}

// Tick запускает рассылки, отправляет готовые уведомления и возвращает их число.
func (d *Dispatcher) Tick(ctx context.Context) (int, error) {
	if err := StartDueCampaigns(ctx, d.pool); err != nil {
		return 0, err
	}
	n, err := d.send(ctx)
	if err != nil {
		return n, err
	}
	return n, FinishCampaigns(ctx, d.pool)
}

func (d *Dispatcher) send(ctx context.Context) (int, error) {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	rows, err := tx.Query(ctx, `
		SELECT id, user_id, title, body, data, attempts
		FROM notifications_outbox
		WHERE status = 'pending' AND send_after <= now()
		ORDER BY id LIMIT 100
		FOR UPDATE SKIP LOCKED`)
	if err != nil {
		return 0, err
	}
	var batch []queued
	for rows.Next() {
		var q queued
		if err := rows.Scan(&q.id, &q.userID, &q.title, &q.body, &q.data, &q.attempts); err != nil {
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
		r, err := d.deliver(ctx, tx, q)
		if err != nil {
			return 0, err
		}
		switch {
		case r.delivered != "":
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET status = 'sent', channel = 'push', devices = $2, sent_at = now(),
				attempts = attempts + 1, last_error = $3 WHERE id = $1`, q.id, r.delivered, r.reason)
		case r.retry && q.attempts+1 < maxAttempts:
			// 30 с, 1, 2, 4, 8 мин.
			delay := time.Duration(30<<q.attempts) * time.Second
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET attempts = attempts + 1, last_error = $2,
				send_after = now() + $3::interval WHERE id = $1`, q.id, r.reason, delay.String())
		case r.failed || r.retry:
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET status = 'failed', attempts = attempts + 1,
				last_error = $2 WHERE id = $1`, q.id, r.reason)
		default:
			// Доставлять некуда: нет устройств с разрешёнными уведомлениями.
			_, err = tx.Exec(ctx, `UPDATE notifications_outbox SET status = 'skipped', attempts = attempts + 1,
				last_error = $2 WHERE id = $1`, q.id, r.reason)
		}
		if err != nil {
			return 0, err
		}
	}
	return len(batch), tx.Commit(ctx)
}

type outcome struct {
	delivered string // «iPhone, Android» — куда дошло
	reason    string // почему не дошло (или не везде)
	retry     bool   // временный сбой — повторить позже
	failed    bool   // ошибка, повтор не поможет
}

// Device — устройство покупателя для отправки.
type Device struct {
	ID       string
	Token    string
	Platform string
}

// PlatformName — «iPhone» или «Android».
func PlatformName(p string) string {
	if p == "ios" {
		return "iPhone"
	}
	return "Android"
}

// UserDevices — устройства покупателя, свежие первыми.
func UserDevices(ctx context.Context, q interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, userID string) ([]Device, error) {
	rows, err := q.Query(ctx, `SELECT id, token, platform FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC LIMIT 10`, userID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Device, error) {
		var d Device
		err := r.Scan(&d.ID, &d.Token, &d.Platform)
		return d, err
	})
}

// MessageData — data для FCM: только строки.
func MessageData(data map[string]any) map[string]string {
	out := map[string]string{}
	for k, v := range data {
		if s, ok := v.(string); ok {
			out[k] = s
		}
	}
	return out
}

// deliver: push на все устройства покупателя.
func (d *Dispatcher) deliver(ctx context.Context, tx pgx.Tx, q queued) (outcome, error) {
	devs, err := UserDevices(ctx, tx, q.userID)
	if err != nil {
		return outcome{}, err
	}
	if len(devs) == 0 {
		return outcome{reason: "Нет push: покупатель не разрешил уведомления или не входил в приложение"}, nil
	}
	if d.fcm == nil {
		return outcome{reason: "Push не настроен на сервере (FCM_CREDENTIALS)", failed: true}, nil
	}
	msg := Message{Title: q.title, Body: q.body, Data: MessageData(q.data)}
	var (
		okNames []string
		res     outcome
		gone    int
	)
	for _, x := range devs {
		err := d.fcm.Send(ctx, x.Token, msg)
		switch {
		case err == nil:
			okNames = append(okNames, PlatformName(x.Platform))
		case errors.Is(err, ErrUnregistered):
			gone++
			if _, err := tx.Exec(ctx, `DELETE FROM devices WHERE id = $1`, x.ID); err != nil {
				return outcome{}, err
			}
		case errors.Is(err, ErrPermanent):
			res.failed = true
			res.reason = Reason(err)
		default:
			res.retry = true
			res.reason = Reason(err)
		}
	}
	if len(okNames) > 0 {
		return outcome{delivered: strings.Join(dedupe(okNames), ", "), reason: res.reason}, nil
	}
	if res.retry {
		res.failed = false
		return res, nil
	}
	if res.failed {
		return res, nil
	}
	if gone > 0 {
		return outcome{reason: Reason(ErrUnregistered)}, nil
	}
	return res, nil
}

func dedupe(s []string) []string {
	seen := map[string]bool{}
	out := s[:0]
	for _, x := range s {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out
}
