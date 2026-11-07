package identity

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
)

// Вход продажника в «SM Продажник» по логину и паролю (таблица field_reps).
// Логин и пароль выдаёт супер-админ («Продажники»). Как у курьера: после
// 5 неверных паролей подряд вход закрывается на 15 минут.

var errFieldBlocked = apperr.Forbidden("вход отключён — обратитесь к менеджеру Super Market").Uz("kirish oʻchirilgan — Super Market menejeriga murojaat qiling")

// FieldLogin — вход в «SM Продажник».
func (s *Service) FieldLogin(ctx context.Context, rawLogin, password, userAgent string) (Tokens, error) {
	login := NormalizeLogin(rawLogin)
	if login == "" || password == "" {
		return Tokens{}, apperr.Validation("введите логин и пароль").Uz("login va parolni kiriting")
	}
	var (
		repID, userID, hash, status string
	)
	err := s.pool.QueryRow(ctx, `SELECT id, user_id, password_hash, status FROM field_reps WHERE login = $1`, login).
		Scan(&repID, &userID, &hash, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		CheckPassword(dummyHash, password)
		return Tokens{}, errBadCredentials
	}
	if err != nil {
		return Tokens{}, err
	}
	now := s.now()
	var fails int
	err = s.pool.QueryRow(ctx, `
		UPDATE field_reps SET
			failed_attempts = CASE WHEN locked_until IS NOT NULL THEN 1 ELSE failed_attempts + 1 END,
			locked_until = CASE WHEN (CASE WHEN locked_until IS NOT NULL THEN 1 ELSE failed_attempts + 1 END) >= $2
			                    THEN $3::timestamptz END
		WHERE id = $1 AND (locked_until IS NULL OR locked_until <= $4)
		RETURNING failed_attempts`, repID, courierMaxFails, now.Add(courierLockFor), now).Scan(&fails)
	if errors.Is(err, pgx.ErrNoRows) {
		var until time.Time
		if err := s.pool.QueryRow(ctx, `SELECT COALESCE(locked_until, $2) FROM field_reps WHERE id = $1`,
			repID, now.Add(courierLockFor)).Scan(&until); err != nil {
			return Tokens{}, err
		}
		wait := int(until.Sub(now).Seconds()) + 1
		return Tokens{}, apperr.New(http.StatusTooManyRequests, "too_many_requests",
			fmt.Sprintf("слишком много неверных паролей — попробуйте через %d мин", (wait+59)/60)).Uz(fmt.Sprintf("notoʻgʻri parol juda koʻp kiritildi — %d daqiqadan keyin urinib koʻring", (wait+59)/60)).
			WithDetails(map[string]any{"retry_after": wait})
	}
	if err != nil {
		return Tokens{}, err
	}
	if !CheckPassword(hash, password) {
		if fails >= courierMaxFails {
			return Tokens{}, apperr.New(http.StatusTooManyRequests, "too_many_requests", "слишком много неверных паролей — вход закрыт на 15 минут").Uz("notoʻgʻri parol juda koʻp kiritildi — kirish 15 daqiqaga yopildi").
				WithDetails(map[string]any{"retry_after": int(courierLockFor.Seconds())})
		}
		return Tokens{}, errBadCredentials.WithDetails(map[string]any{"attempts_left": courierMaxFails - fails})
	}
	if status != "active" {
		return Tokens{}, errFieldBlocked
	}
	var sessionID, refresh string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE field_reps SET failed_attempts = 0, locked_until = NULL, last_login_at = now()
			WHERE id = $1 AND password_hash = $2`, repID, hash)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return errBadCredentials
		}
		sessionID, refresh, err = s.createSession(ctx, tx, userID, AppField, userAgent)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	s.rememberLang(ctx, userID, AppField)
	return s.tokens(userID, sessionID, AppField, refresh)
}

// RevokeUserSessions закрывает сессии пользователя в приложении app
// (продажника заблокировали или сменили ему пароль).
func RevokeUserSessions(ctx context.Context, q db.Querier, userID, app string) error {
	_, err := q.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND app = $2 AND revoked_at IS NULL`, userID, app)
	return err
}
