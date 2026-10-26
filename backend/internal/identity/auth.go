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
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
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
	// ReviewPhone/ReviewCode — демо-аккаунт для проверки в магазинах приложений:
	// приложения покупателя и курьера «по пути» (не супер-админа и не магазина:
	// магазин входит по логину и паролю).
	ReviewPhone string
	ReviewCode  string
	// AgentReviewPhone/AgentReviewCode — то же для «SM Агент» (отдельный
	// номер: один номер — один сотрудник, а номер ReviewPhone уже сотрудник
	// демо-магазина).
	AgentReviewPhone string
	AgentReviewCode  string
}

// SMSSender отправляет SMS с кодами входа (Eskiz).
type SMSSender interface {
	Send(ctx context.Context, phone, text string) error
}

// Service — вход, сессии, роли и сотрудники.
type Service struct {
	pool   *pgxpool.Pool
	signer *token.Signer
	tg     Sender    // nil, если бот не настроен
	sms    SMSSender // nil — SMS не настроены (коды только с DevOTPCode / ReviewCode)
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

// WithSMS включает отправку кодов входа по SMS.
func (s *Service) WithSMS(sms SMSSender) *Service {
	s.sms = sms
	return s
}

// Tokens — ответ на успешный вход или обновление токена.
type Tokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	// PasswordChangeRequired — вошли по временному паролю: в панели магазина
	// открыт только экран смены пароля.
	PasswordChangeRequired bool `json:"password_change_required,omitempty"`
}

var (
	errCodeInvalid = apperr.Validation("код неверный или устарел").Uz("kod notoʻgʻri yoki eskirgan")
	errNoAccess    = apperr.Forbidden("нет доступа к этому приложению").Uz("bu ilovaga ruxsat yoʻq")
	// ErrCustomerBlocked — покупателя заблокировал супер-админ.
	ErrCustomerBlocked = apperr.New(http.StatusForbidden, "customer_blocked", "аккаунт заблокирован, обратитесь в поддержку").Uz("akkaunt bloklangan, qoʻllab-quvvatlash xizmatiga murojaat qiling")
	// ErrCrowdBlocked — курьера «по пути» заблокировал супер-админ.
	ErrCrowdBlocked  = apperr.New(http.StatusForbidden, "crowd_blocked", "вход для курьера заблокирован, обратитесь в поддержку").Uz("kuryer uchun kirish bloklangan, qoʻllab-quvvatlash xizmatiga murojaat qiling")
	errTermsRequired = apperr.New(http.StatusUnprocessableEntity, "terms_required", "примите условия для курьеров и политику конфиденциальности").Uz("kuryerlar uchun shartlar va maxfiylik siyosatini qabul qiling")
	errRefresh       = apperr.Unauthorized("сессия недействительна, войдите заново").Uz("sessiya yaroqsiz, qaytadan kiring")
)

func (s *Service) botURL() string {
	if s.cfg.BotUsername == "" {
		return ""
	}
	return "https://t.me/" + s.cfg.BotUsername
}

// RequestCode создаёт код входа и отправляет его по SMS (Eskiz); в панель
// супер-админа — в Telegram-бот. Возвращает, через сколько секунд код истечёт.
func (s *Service) RequestCode(ctx context.Context, rawPhone, app string) (int, error) {
	n, _, err := s.RequestCodeVia(ctx, rawPhone, app)
	return n, err
}

// SMSCodeText — текст SMS с кодом входа. Должен совпадать с шаблоном,
// одобренным в кабинете Eskiz (меняются только цифры кода).
const SMSCodeText = "Super Market ilovasiga kirish uchun kod: %s. Kodni hech kimga bermang."

var (
	errSMSUnavailable = apperr.New(http.StatusServiceUnavailable, "sms_unavailable", "отправка кодов временно недоступна").Uz("kod yuborish vaqtincha ishlamayapti")
	errSMSFailed      = apperr.New(http.StatusBadGateway, "sms_send_failed", "не удалось отправить SMS, попробуйте ещё раз").Uz("SMS yuborib boʻlmadi, qayta urinib koʻring")
)

// RequestCodeVia — то же, что RequestCode, и куда ушёл код: "sms" или "telegram".
// Все приложения (покупатель, курьер, агент) получают код по SMS через Eskiz.
// Telegram-бот остался только для панели супер-админа (app = admin): номер
// должен быть привязан к боту.
func (s *Service) RequestCodeVia(ctx context.Context, rawPhone, app string) (int, string, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return 0, "", apperr.Validation("неверный номер телефона").Uz("telefon raqami notoʻgʻri")
	}
	now := s.now()

	var sentAt time.Time
	err = s.pool.QueryRow(ctx, `SELECT sent_at FROM auth_codes WHERE phone = $1`, ph).Scan(&sentAt)
	switch {
	case err == nil:
		if wait := resendCooldown - now.Sub(sentAt); wait > 0 {
			return 0, "", apperr.New(http.StatusTooManyRequests, "too_many_requests", "код уже отправлен, попробуйте позже").Uz("kod allaqachon yuborilgan, keyinroq urinib koʻring").
				WithDetails(map[string]any{"retry_after": int(wait.Seconds()) + 1})
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return 0, "", err
	}

	code := s.cfg.DevOTPCode
	if s.cfg.ReviewPhone != "" && ph == s.cfg.ReviewPhone {
		code = s.cfg.ReviewCode
	}
	if s.cfg.AgentReviewPhone != "" && ph == s.cfg.AgentReviewPhone {
		code = s.cfg.AgentReviewCode
	}
	channel := "sms"
	var chatID int64
	if app == AppAdmin {
		channel = "telegram"
		err := s.pool.QueryRow(ctx, `SELECT chat_id FROM telegram_links WHERE phone = $1`, ph).Scan(&chatID)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			if code == "" {
				return 0, "", apperr.Conflict("telegram_not_linked",
					"откройте бота в Telegram и поделитесь номером, чтобы получать коды").Uz("kodlarni olish uchun Telegramda botni oching va raqamingizni ulashing").
					WithDetails(map[string]any{"bot_url": s.botURL()})
			}
		case err != nil:
			return 0, "", err
		}
	}
	send := code == ""
	if send {
		switch {
		case channel == "telegram" && s.tg == nil:
			return 0, "", apperr.New(http.StatusServiceUnavailable, "telegram_unavailable", "отправка кодов временно недоступна").Uz("kod yuborish vaqtincha ishlamayapti")
		case channel == "sms" && s.sms == nil:
			return 0, "", errSMSUnavailable
		}
		if code, err = randomCode(); err != nil {
			return 0, "", err
		}
	}

	if _, err := s.pool.Exec(ctx, `
		INSERT INTO auth_codes (phone, code_hash, attempts, sent_at, expires_at)
		VALUES ($1, $2, 0, $3, $4)
		ON CONFLICT (phone) DO UPDATE
		SET code_hash = EXCLUDED.code_hash, attempts = 0,
		    sent_at = EXCLUDED.sent_at, expires_at = EXCLUDED.expires_at`,
		ph, s.codeHash(ph, code), now, now.Add(s.cfg.OTPTTL)); err != nil {
		return 0, "", err
	}

	if send && channel == "sms" {
		if err := s.sms.Send(ctx, ph, fmt.Sprintf(SMSCodeText, code)); err != nil {
			_, _ = s.pool.Exec(ctx, `DELETE FROM auth_codes WHERE phone = $1`, ph)
			s.log.Error("не удалось отправить SMS с кодом", "err", err, "app", app)
			return 0, "", errSMSFailed
		}
	} else if send {
		// Язык — приложения, из которого просят код (Accept-Language).
		text := i18n.T(ctx, fmt.Sprintf("Код для входа: %s\n\nНикому не сообщайте этот код.", code),
			fmt.Sprintf("Kirish kodi: %s\n\nBu kodni hech kimga aytmang.", code))
		if err := s.tg.SendMessage(ctx, chatID, text, nil); err != nil {
			_, _ = s.pool.Exec(ctx, `DELETE FROM auth_codes WHERE phone = $1`, ph)
			s.log.Error("не удалось отправить код в Telegram", "err", err)
			return 0, "", apperr.New(http.StatusBadGateway, "telegram_send_failed", "не удалось отправить код, попробуйте ещё раз").Uz("kodni yuborib boʻlmadi, qayta urinib koʻring")
		}
	}
	return int(s.cfg.OTPTTL.Seconds()), channel, nil
}

// VerifyCode проверяет код и открывает сессию в приложении app.
func (s *Service) VerifyCode(ctx context.Context, rawPhone, code, app, userAgent string) (Tokens, error) {
	return s.VerifyCodeTerms(ctx, rawPhone, code, app, userAgent, false)
}

// VerifyCodeTerms — то же, плюс согласие с условиями: без него курьер «по
// пути» не регистрируется.
func (s *Service) VerifyCodeTerms(ctx context.Context, rawPhone, code, app, userAgent string, terms bool) (Tokens, error) {
	if app != AppClient && app != AppStore && app != AppAdmin && app != AppCrowd {
		return Tokens{}, apperr.Validation("app: ожидается client, store, admin или crowd").Uz("app: client, store, admin yoki crowd boʻlishi kerak")
	}
	// В панель магазина и «SM Магазин» входят по логину и паролю
	// (/auth/store/login); вход по коду для них отключён.
	if app == AppStore {
		return Tokens{}, errCodeLoginDisabled
	}
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return Tokens{}, apperr.Validation("неверный номер телефона").Uz("telefon raqami notoʻgʻri")
	}
	// Демо-номер для проверки в магазинах приложений не открывает панель
	// супер-админа; в приложении курьера — обычная регистрация с согласием.
	if app == AppAdmin && ((s.cfg.ReviewPhone != "" && ph == s.cfg.ReviewPhone) || (s.cfg.AgentReviewPhone != "" && ph == s.cfg.AgentReviewPhone)) {
		return Tokens{}, errCodeInvalid
	}

	// Шаг 1: проверить код.
	if err := s.checkCode(ctx, ph, code); err != nil {
		return Tokens{}, err
	}

	// Шаг 2: найти или создать пользователя, проверить доступ, открыть сессию.
	var (
		sessionID string
		refresh   string
		userID    string
	)
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		userID, err = s.userForApp(ctx, tx, ph, app, terms)
		if err != nil {
			return err
		}
		sessionID, refresh, err = s.createSession(ctx, tx, userID, app, userAgent)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	s.rememberLang(ctx, userID, app)
	return s.tokens(userID, sessionID, app, refresh)
}

// checkCode проверяет и гасит код входа. Отдельная транзакция, чтобы
// счётчик попыток сохранялся даже при неверном коде; после 5 неверных
// попыток код сгорает.
func (s *Service) checkCode(ctx context.Context, ph, code string) error {
	var verdict error
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
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
		return err
	}
	return verdict
}

// ConsumeCode проверяет код, присланный на номер, без входа в приложение
// (удаление аккаунта с сайта). Те же лимиты, что у входа. Возвращает номер
// в формате E.164.
func (s *Service) ConsumeCode(ctx context.Context, rawPhone, code string) (string, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return "", apperr.Validation("неверный номер телефона").Uz("telefon raqami notoʻgʻri")
	}
	return ph, s.checkCode(ctx, ph, code)
}

func (s *Service) userForApp(ctx context.Context, tx pgx.Tx, ph, app string, terms bool) (string, error) {
	var userID string
	if app == AppCrowd {
		return crowdUser(ctx, tx, ph, terms)
	}
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
		if _, err := tx.Exec(ctx, `
			INSERT INTO customers (user_id) VALUES ($1)
			ON CONFLICT (user_id) DO UPDATE SET deleted_at = NULL WHERE customers.deleted_at IS NOT NULL`, userID); err != nil {
			return "", err
		}
		var blocked bool
		if err := tx.QueryRow(ctx, `SELECT blocked_at IS NOT NULL FROM customers WHERE user_id = $1`, userID).Scan(&blocked); err != nil {
			return "", err
		}
		if blocked {
			return "", ErrCustomerBlocked
		}
		return userID, nil
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
	s.rememberLang(ctx, userID, app)
	return s.tokens(userID, sessionID, app, newRefresh)
}

// rememberLang — язык приложения (Accept-Language) становится языком
// пользователя для уведомлений. Панель супер-админа всегда на русском и
// язык не меняет.
func (s *Service) rememberLang(ctx context.Context, userID, app string) {
	lang := i18n.Explicit(ctx)
	if lang == "" || app == AppAdmin {
		return
	}
	if _, err := s.pool.Exec(ctx, `UPDATE users SET language = $2 WHERE id = $1 AND language <> $2`, userID, lang); err != nil {
		s.log.Warn("не удалось сохранить язык пользователя", "user", userID, "err", err)
	}
}

// SetLanguage — язык пользователя из настроек приложения (PUT /me/language).
func (s *Service) SetLanguage(ctx context.Context, userID, lang string) error {
	if lang != i18n.UZ && lang != i18n.RU {
		return apperr.Validation("язык: uz или ru").Uz("til: uz yoki ru")
	}
	_, err := s.pool.Exec(ctx, `UPDATE users SET language = $2 WHERE id = $1`, userID, lang)
	return err
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

// ResendIn — через сколько секунд можно снова запросить код (таймер на экране).
func ResendIn() int { return int(resendCooldown.Seconds()) }

// ServiceToken — короткий токен доступа от имени вошедшего сотрудника: для
// внутренних вызовов API (помощник в панели ходит в /store/* сам).
func (s *Service) ServiceToken(p *Principal, ttl time.Duration) (string, error) {
	return s.signer.Sign(token.Claims{UserID: p.UserID, SessionID: p.SessionID, App: p.App}, ttl)
}
