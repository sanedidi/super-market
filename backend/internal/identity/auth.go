package identity

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
	"github.com/sanedidi/super-market/backend/internal/platform/telegram"
	"github.com/sanedidi/super-market/backend/internal/platform/token"
)

const (
	resendCooldown = time.Minute
	maxAttempts    = 5
)

// Sender отправляет сообщения в Telegram. В тестах — подделка.
type Sender interface {
	SendMessage(ctx context.Context, chatID int64, text string, markup *telegram.ReplyMarkup) error
}

// Config — настройки входа.
type Config struct {
	Secret      string
	AccessTTL   time.Duration
	RefreshTTL  time.Duration
	OTPTTL      time.Duration
	DevOTPCode  string
	BotUsername string
}

// Service — вход, сессии, роли и сотрудники.
type Service struct {
	pool   *pgxpool.Pool
	signer *token.Signer
	tg     Sender // nil, если бот не настроен
	cfg    Config
	log    *slog.Logger
	now    func() time.Time
}

func NewService(pool *pgxpool.Pool, tg Sender, cfg Config, log *slog.Logger) *Service {
	return &Service{
		pool:   pool,
		signer: token.NewSigner(cfg.Secret),
		tg:     tg,
		cfg:    cfg,
		log:    log,
		now:    time.Now,
	}
}

// Tokens — ответ на успешный вход или обновление токена.
type Tokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
}

var (
	errCodeInvalid = apperr.Validation("код неверный или устарел")
	errNoAccess    = apperr.Forbidden("нет доступа к этому приложению")
	errRefresh     = apperr.Unauthorized("сессия недействительна, войдите заново")
)

func (s *Service) botURL() string {
	if s.cfg.BotUsername == "" {
		return ""
	}
	return "https://t.me/" + s.cfg.BotUsername
}

// RequestCode создаёт код входа и отправляет его в Telegram.
// Возвращает, через сколько секунд код истечёт.
func (s *Service) RequestCode(ctx context.Context, rawPhone string) (int, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return 0, apperr.Validation("неверный номер телефона")
	}
	now := s.now()

	var sentAt time.Time
	err = s.pool.QueryRow(ctx, `SELECT sent_at FROM auth_codes WHERE phone = $1`, ph).Scan(&sentAt)
	switch {
	case err == nil:
		if wait := resendCooldown - now.Sub(sentAt); wait > 0 {
			return 0, apperr.New(http.StatusTooManyRequests, "too_many_requests", "код уже отправлен, попробуйте позже").
				WithDetails(map[string]any{"retry_after": int(wait.Seconds()) + 1})
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return 0, err
	}

	code := s.cfg.DevOTPCode
	var chatID int64
	if code == "" {
		err := s.pool.QueryRow(ctx, `SELECT chat_id FROM telegram_links WHERE phone = $1`, ph).Scan(&chatID)
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.Conflict("telegram_not_linked",
				"откройте бота в Telegram и поделитесь номером, чтобы получать коды").
				WithDetails(map[string]any{"bot_url": s.botURL()})
		}
		if err != nil {
			return 0, err
		}
		if s.tg == nil {
			return 0, apperr.New(http.StatusServiceUnavailable, "telegram_unavailable", "отправка кодов временно недоступна")
		}
		if code, err = randomCode(); err != nil {
			return 0, err
		}
	}

	if _, err := s.pool.Exec(ctx, `
		INSERT INTO auth_codes (phone, code_hash, attempts, sent_at, expires_at)
		VALUES ($1, $2, 0, $3, $4)
		ON CONFLICT (phone) DO UPDATE
		SET code_hash = EXCLUDED.code_hash, attempts = 0,
		    sent_at = EXCLUDED.sent_at, expires_at = EXCLUDED.expires_at`,
		ph, s.codeHash(ph, code), now, now.Add(s.cfg.OTPTTL)); err != nil {
		return 0, err
	}

	if s.cfg.DevOTPCode == "" {
		text := fmt.Sprintf("Код для входа: %s\n\nНикому не сообщайте этот код.", code)
		if err := s.tg.SendMessage(ctx, chatID, text, nil); err != nil {
			_, _ = s.pool.Exec(ctx, `DELETE FROM auth_codes WHERE phone = $1`, ph)
			s.log.Error("не удалось отправить код в Telegram", "err", err)
			return 0, apperr.New(http.StatusBadGateway, "telegram_send_failed", "не удалось отправить код, попробуйте ещё раз")
		}
	}
	return int(s.cfg.OTPTTL.Seconds()), nil
}

// VerifyCode проверяет код и открывает сессию в приложении app.
func (s *Service) VerifyCode(ctx context.Context, rawPhone, code, app, userAgent string) (Tokens, error) {
	if app != AppClient && app != AppStore && app != AppAdmin {
		return Tokens{}, apperr.Validation("app: ожидается client, store или admin")
	}
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return Tokens{}, apperr.Validation("неверный номер телефона")
	}

	// Шаг 1: проверить код. Отдельная транзакция, чтобы счётчик попыток
	// сохранялся даже при неверном коде.
	var verdict error
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var (
			hash     []byte
			attempts int
			expires  time.Time
		)
		err := tx.QueryRow(ctx, `
			SELECT code_hash, attempts, expires_at FROM auth_codes
			WHERE phone = $1 FOR UPDATE`, ph).Scan(&hash, &attempts, &expires)
		if errors.Is(err, pgx.ErrNoRows) {
			verdict = errCodeInvalid
			return nil
		}
		if err != nil {
			return err
		}
		if !s.now().Before(expires) || attempts >= maxAttempts {
			verdict = errCodeInvalid
			_, err = tx.Exec(ctx, `DELETE FROM auth_codes WHERE phone = $1`, ph)
			return err
		}
		if !hmac.Equal(hash, s.codeHash(ph, code)) {
			verdict = errCodeInvalid
			_, err = tx.Exec(ctx, `UPDATE auth_codes SET attempts = attempts + 1 WHERE phone = $1`, ph)
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM auth_codes WHERE phone = $1`, ph)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	if verdict != nil {
		return Tokens{}, verdict
	}

	// Шаг 2: найти или создать пользователя, проверить доступ, открыть сессию.
	var (
		sessionID string
		refresh   string
		userID    string
	)
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		userID, err = s.userForApp(ctx, tx, ph, app)
		if err != nil {
			return err
		}
		sessionID, refresh, err = s.createSession(ctx, tx, userID, app, userAgent)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	return s.tokens(userID, sessionID, app, refresh)
}

func (s *Service) userForApp(ctx context.Context, tx pgx.Tx, ph, app string) (string, error) {
	var userID string
	if app == AppClient {
		// Покупатель регистрируется при первом входе.
		if err := tx.QueryRow(ctx, `
			INSERT INTO users (phone) VALUES ($1)
			ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
			RETURNING id`, ph).Scan(&userID); err != nil {
			return "", err
		}
		// Удалённый аккаунт сотрудника (номер у него не обезличивается)
		// при новом входе в приложение становится снова активным.
		_, err := tx.Exec(ctx, `
			INSERT INTO customers (user_id) VALUES ($1)
			ON CONFLICT (user_id) DO UPDATE SET deleted_at = NULL WHERE customers.deleted_at IS NOT NULL`, userID)
		return userID, err
	}

	var query string
	switch app {
	case AppAdmin:
		query = `SELECT u.id FROM users u JOIN platform_admins pa ON pa.user_id = u.id WHERE u.phone = $1`
	case AppStore:
		query = `
			SELECT u.id FROM users u
			JOIN employees e ON e.user_id = u.id AND e.status = 'active'
			JOIN networks n ON n.id = e.network_id AND n.status = 'active'
			WHERE u.phone = $1`
	}
	err := tx.QueryRow(ctx, query, ph).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", errNoAccess
	}
	return userID, err
}

func (s *Service) createSession(ctx context.Context, tx pgx.Tx, userID, app, userAgent string) (string, string, error) {
	refresh, hash, err := newRefreshToken()
	if err != nil {
		return "", "", err
	}
	if len(userAgent) > 300 {
		userAgent = userAgent[:300]
	}
	var sessionID string
	err = tx.QueryRow(ctx, `
		INSERT INTO sessions (user_id, app, refresh_hash, user_agent, expires_at)
		VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		userID, app, hash, userAgent, s.now().Add(s.cfg.RefreshTTL)).Scan(&sessionID)
	return sessionID, refresh, err
}

// Refresh выдаёт новую пару токенов по refresh-токену. Старый refresh
// после этого не действует (ротация).
func (s *Service) Refresh(ctx context.Context, refresh string) (Tokens, error) {
	oldHash := hashRefresh(refresh)
	newRefresh, newHash, err := newRefreshToken()
	if err != nil {
		return Tokens{}, err
	}
	var userID, sessionID, app string
	err = s.pool.QueryRow(ctx, `
		UPDATE sessions SET refresh_hash = $2, expires_at = $3
		WHERE refresh_hash = $1 AND revoked_at IS NULL AND expires_at > $4
		RETURNING user_id, id, app`,
		oldHash, newHash, s.now().Add(s.cfg.RefreshTTL), s.now()).Scan(&userID, &sessionID, &app)
	if errors.Is(err, pgx.ErrNoRows) {
		return Tokens{}, errRefresh
	}
	if err != nil {
		return Tokens{}, err
	}
	return s.tokens(userID, sessionID, app, newRefresh)
}

// Logout закрывает сессию.
// Устройство этой сессии больше не получает push.
func (s *Service) Logout(ctx context.Context, sessionID string) error {
	if _, err := s.pool.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL`, sessionID); err != nil {
		return err
	}
	_, err := s.pool.Exec(ctx, `DELETE FROM devices WHERE session_id = $1`, sessionID)
	return err
}

func (s *Service) tokens(userID, sessionID, app, refresh string) (Tokens, error) {
	access, err := s.signer.Sign(token.Claims{UserID: userID, SessionID: sessionID, App: app}, s.cfg.AccessTTL)
	if err != nil {
		return Tokens{}, err
	}
	return Tokens{
		AccessToken:  access,
		RefreshToken: refresh,
		TokenType:    "Bearer",
		ExpiresIn:    int(s.cfg.AccessTTL.Seconds()),
	}, nil
}

// EnsureSuperAdmins выдаёт роль супер-админа номерам из конфига.
func (s *Service) EnsureSuperAdmins(ctx context.Context, phones []string) error {
	for _, raw := range phones {
		ph, err := phone.Normalize(raw)
		if err != nil {
			return fmt.Errorf("SUPER_ADMIN_PHONES: %q: %w", raw, err)
		}
		if _, err := s.pool.Exec(ctx, `
			WITH u AS (
				INSERT INTO users (phone) VALUES ($1)
				ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
				RETURNING id
			)
			INSERT INTO platform_admins (user_id) SELECT id FROM u ON CONFLICT DO NOTHING`, ph); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) codeHash(ph, code string) []byte {
	m := hmac.New(sha256.New, []byte(s.cfg.Secret))
	m.Write([]byte(ph + ":" + code))
	return m.Sum(nil)
}

func randomCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func newRefreshToken() (string, []byte, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", nil, err
	}
	tok := base64.RawURLEncoding.EncodeToString(b)
	return tok, hashRefresh(tok), nil
}

func hashRefresh(tok string) []byte {
	h := sha256.Sum256([]byte(tok))
	return h[:]
}
