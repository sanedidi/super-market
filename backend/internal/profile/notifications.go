package profile

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Уведомления в приложении (колокольчик на главной): те же записи, что
// уходят push'ем или в Telegram, плюс отметка «прочитано».

type Notification struct {
	ID        int64          `json:"id"`
	Kind      string         `json:"kind"`
	Title     string         `json:"title"`
	Body      string         `json:"body"`
	Data      map[string]any `json:"data"`
	CreatedAt time.Time      `json:"created_at"`
	Read      bool           `json:"read"`
}

// visible — уже отправленные или ожидающие повтора; запланированные на
// будущее (напоминания) ещё не показываем.
const visible = `user_id = $1 AND (status <> 'pending' OR attempts > 0 OR send_after <= now())`

func (s *Service) Notifications(ctx context.Context, userID string, page httpx.Page) ([]Notification, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, kind, title, body, data, created_at, read_at IS NOT NULL FROM notifications_outbox
		WHERE `+visible+` ORDER BY created_at DESC, id DESC LIMIT $2 OFFSET $3`, userID, page.Limit, page.Offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Notification])
}

func (s *Service) UnreadCount(ctx context.Context, userID string) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `SELECT count(*)::int FROM notifications_outbox WHERE `+visible+` AND read_at IS NULL`, userID).Scan(&n)
	return n, err
}

type ReadInput struct {
	IDs []int64 `json:"ids"`
	All bool    `json:"all"`
}

// MarkRead отмечает прочитанными выбранные уведомления или все сразу.
func (s *Service) MarkRead(ctx context.Context, userID string, in ReadInput) (int, error) {
	if !in.All && len(in.IDs) == 0 {
		return 0, apperr.Validation("ids или all: true")
	}
	if len(in.IDs) > 200 {
		return 0, apperr.Validation("ids: не больше 200")
	}
	ids := in.IDs
	if ids == nil {
		ids = []int64{}
	}
	if _, err := s.pool.Exec(ctx, `
		UPDATE notifications_outbox SET read_at = $4
		WHERE `+visible+` AND read_at IS NULL AND ($2 OR id = ANY ($3::bigint[]))`, userID, in.All, ids, s.now()); err != nil {
		return 0, err
	}
	return s.UnreadCount(ctx, userID)
}
