package debts

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
)

// quietSendAfter — ночью (22:00–08:00 по Ташкенту) push уходит утром.
func quietSendAfter(now time.Time) time.Time {
	t := now.In(tashkent)
	switch {
	case t.Hour() >= 22:
		next := t.AddDate(0, 0, 1)
		return time.Date(next.Year(), next.Month(), next.Day(), 8, 0, 0, 0, tashkent)
	case t.Hour() < 8:
		return time.Date(t.Year(), t.Month(), t.Day(), 8, 0, 0, 0, tashkent)
	}
	return now
}

// notifyBuyer ставит push покупателю с этим номером, если у него есть
// аккаунт в приложении. titleFmt получает название магазина, bodyFmt — сумму.
// Нажатие открывает долг в этом магазине.
func notifyBuyer(ctx context.Context, q db.Querier, ph, storeID, kind, titleFmt, bodyFmt string, amount money.Dec) error {
	data, _ := json.Marshal(map[string]string{"type": "debt", "store_id": storeID})
	var storeName string
	if err := q.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, storeID).Scan(&storeName); err != nil {
		return err
	}
	title := fmt.Sprintf(titleFmt, storeName)
	body := fmt.Sprintf(bodyFmt, money.Group(amount.Money()))
	_, err := q.Exec(ctx, `
		INSERT INTO notifications_outbox (user_id, kind, title, body, data, send_after)
		SELECT c.user_id, $2, $3, $4, $5::jsonb, $6
		FROM users u JOIN customers c ON c.user_id = u.id AND c.deleted_at IS NULL
		WHERE u.phone = $1`, ph, kind, title, body, string(data), quietSendAfter(time.Now()))
	return err
}

// hasApp — есть ли у покупателя с этим номером приложение (устройство для push).
func hasApp(ctx context.Context, q db.Querier, ph string) (bool, error) {
	var ok bool
	err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM users u JOIN customers c ON c.user_id = u.id AND c.deleted_at IS NULL
		               JOIN devices d ON d.user_id = u.id AND d.app = 'client'
		               WHERE u.phone = $1)`, ph).Scan(&ok)
	return ok, err
}
