package push

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

const (
	AppClient = "client"
	AppStore  = "store"
)

// RegisterStoreDevice — устройство сотрудника (приложение магазина).
func RegisterStoreDevice(ctx context.Context, q db.Querier, userID, sessionID, token, platform string) error {
	token = strings.TrimSpace(token)
	if len(token) < 20 || len(token) > 4096 {
		return apperr.Validation("token: неверный токен устройства")
	}
	if platform != "ios" && platform != "android" {
		return apperr.Validation("platform: ios или android")
	}
	_, err := q.Exec(ctx, `
		INSERT INTO devices (user_id, session_id, token, platform, app)
		VALUES ($1, $2, $3, $4, 'store')
		ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, session_id = EXCLUDED.session_id,
		       platform = EXCLUDED.platform, app = 'store', last_seen_at = now()`,
		userID, sessionID, token, platform)
	return err
}

// RemoveStoreDevice — выход из приложения магазина.
func RemoveStoreDevice(ctx context.Context, q db.Querier, userID, token string) error {
	_, err := q.Exec(ctx, `DELETE FROM devices WHERE user_id = $1 AND token = $2 AND app = 'store'`, userID, token)
	return err
}

func dataJSON(data map[string]string) (string, error) {
	if data == nil {
		data = map[string]string{}
	}
	b, err := json.Marshal(data)
	return string(b), err
}

// EnqueueStaff — уведомление сотрудникам магазина с правом perm (владельцу —
// всегда), у которых есть приложение магазина. Вызывается в транзакции события.
func EnqueueStaff(ctx context.Context, q db.Querier, storeID, perm, kind, title, body string, data map[string]string) error {
	js, err := dataJSON(data)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `
		INSERT INTO notifications_outbox (user_id, app, kind, title, body, data)
		SELECT DISTINCT e.user_id, 'store', $3, $4, $5, $6::jsonb
		FROM stores s
		JOIN employees e ON e.network_id = s.network_id AND e.status = 'active'
		JOIN roles r     ON r.id = e.role_id
		WHERE s.id = $1
		  AND (r.is_owner OR $2 = ANY(r.permissions))
		  AND (e.all_stores OR EXISTS (SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id = s.id))
		  AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = e.user_id AND d.app = 'store')`,
		storeID, perm, kind, title, body, js)
	return err
}

// EnqueueEmployee — уведомление одному сотруднику (например, тому, кто сфотографировал накладную).
func EnqueueEmployee(ctx context.Context, q db.Querier, employeeID, kind, title, body string, data map[string]string) error {
	js, err := dataJSON(data)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `
		INSERT INTO notifications_outbox (user_id, app, kind, title, body, data)
		SELECT e.user_id, 'store', $2, $3, $4, $5::jsonb FROM employees e
		WHERE e.id = $1 AND e.status = 'active'
		  AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = e.user_id AND d.app = 'store')`,
		employeeID, kind, title, body, js)
	return err
}
