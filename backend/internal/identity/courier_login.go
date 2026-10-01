package identity

import (
	"context"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Вход курьера по логину и паролю. Логин и пароль задаёт магазин в панели;
// после 5 неверных паролей подряд вход по логину закрывается на 15 минут.

const (
	pbkdf2Iter      = 210_000
	courierMaxFails = 5
	courierLockFor  = 15 * time.Minute
)

var (
	loginRe            = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{2,31}$`)
	errBadCredentials  = apperr.New(http.StatusUnauthorized, "invalid_credentials", "неверный логин или пароль")
	errCourierNoAccess = apperr.Forbidden("вход курьера отключён — обратитесь к менеджеру магазина")
)

// HashPassword — PBKDF2-SHA256: «pbkdf2-sha256$итерации$соль$хэш».
func HashPassword(password string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, pbkdf2Iter, 32)
	if err != nil {
		return "", err
	}
	enc := base64.RawStdEncoding
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iter, enc.EncodeToString(salt), enc.EncodeToString(key)), nil
}

// CheckPassword сравнивает пароль с хэшем за постоянное время.
func CheckPassword(hash, password string) bool {
	parts := strings.Split(hash, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	iter, err := strconv.Atoi(parts[1])
	if err != nil || iter < 1000 {
		return false
	}
	enc := base64.RawStdEncoding
	salt, err1 := enc.DecodeString(parts[2])
	want, err2 := enc.DecodeString(parts[3])
	if err1 != nil || err2 != nil {
		return false
	}
	got, err := pbkdf2.Key(sha256.New, password, salt, iter, len(want))
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}

// dummyHash — чтобы ответ на неизвестный логин шёл так же долго.
var dummyHash, _ = HashPassword("not-a-real-password")

// NormalizeLogin — логин в нижнем регистре без пробелов по краям.
func NormalizeLogin(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

// CourierLogin — вход в приложение курьера.
func (s *Service) CourierLogin(ctx context.Context, rawLogin, password, userAgent string) (Tokens, error) {
	login := NormalizeLogin(rawLogin)
	if login == "" || password == "" {
		return Tokens{}, apperr.Validation("введите логин и пароль")
	}
	var (
		employeeID, userID, hash string
		fails                    int
		locked                   *time.Time
		active, courier          bool
	)
	err := s.pool.QueryRow(ctx, `
		SELECT cl.employee_id, e.user_id, cl.password_hash, cl.failed_attempts, cl.locked_until,
		       e.status = 'active' AND n.status = 'active',
		       r.is_owner OR 'orders.deliver' = ANY(r.permissions)
		FROM courier_logins cl
		JOIN employees e ON e.id = cl.employee_id
		JOIN roles r ON r.id = e.role_id
		JOIN networks n ON n.id = e.network_id
		WHERE cl.login = $1`, login).Scan(&employeeID, &userID, &hash, &fails, &locked, &active, &courier)
	if errors.Is(err, pgx.ErrNoRows) {
		CheckPassword(dummyHash, password)
		return Tokens{}, errBadCredentials
	}
	if err != nil {
		return Tokens{}, err
	}
	now := s.now()
	if locked != nil && now.Before(*locked) {
		wait := int(locked.Sub(now).Seconds()) + 1
		return Tokens{}, apperr.New(http.StatusTooManyRequests, "too_many_requests",
			fmt.Sprintf("слишком много неверных паролей — попробуйте через %d мин", (wait+59)/60)).
			WithDetails(map[string]any{"retry_after": wait})
	}
	if !CheckPassword(hash, password) {
		fails++
		var until *time.Time
		if fails >= courierMaxFails {
			t := now.Add(courierLockFor)
			until = &t
		}
		// После блокировки счётчик начинается заново.
		stored := fails
		if until != nil {
			stored = 0
		}
		if _, err := s.pool.Exec(ctx, `UPDATE courier_logins SET failed_attempts = $2, locked_until = $3 WHERE employee_id = $1`,
			employeeID, stored, until); err != nil {
			return Tokens{}, err
		}
		if until != nil {
			return Tokens{}, apperr.New(http.StatusTooManyRequests, "too_many_requests", "слишком много неверных паролей — вход закрыт на 15 минут").
				WithDetails(map[string]any{"retry_after": int(courierLockFor.Seconds())})
		}
		return Tokens{}, errBadCredentials.WithDetails(map[string]any{"attempts_left": courierMaxFails - fails})
	}
	if !active || !courier {
		return Tokens{}, errCourierNoAccess
	}
	var sessionID, refresh string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE courier_logins SET failed_attempts = 0, locked_until = NULL, last_login_at = now() WHERE employee_id = $1`, employeeID); err != nil {
			return err
		}
		var err error
		sessionID, refresh, err = s.createSession(ctx, tx, userID, AppCourier, userAgent)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	return s.tokens(userID, sessionID, AppCourier, refresh)
}

// CourierLoginInfo — логин курьера для панели (пароль не показывается).
type CourierLoginInfo struct {
	EmployeeID        string     `json:"employee_id"`
	Login             string     `json:"login"`
	PasswordChangedAt time.Time  `json:"password_changed_at"`
	LastLoginAt       *time.Time `json:"last_login_at"`
	Locked            bool       `json:"locked"`
}

type CourierLoginInput struct {
	Login    string `json:"login"`
	Password string `json:"password"` // пусто — оставить прежний (только смена логина)
}

func (s *Service) courierEmployee(ctx context.Context, p *Principal, employeeID string) (string, error) {
	if err := p.RequireAny(PermStaffManage, PermOrdersManage); err != nil {
		return "", err
	}
	if !httpx.IsUUID(employeeID) {
		return "", apperr.NotFound("сотрудник не найден")
	}
	var (
		userID  string
		courier bool
	)
	err := s.pool.QueryRow(ctx, `
		SELECT e.user_id, r.is_owner OR 'orders.deliver' = ANY(r.permissions)
		FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1 AND e.network_id = $2 AND e.status = 'active'`, employeeID, p.NetworkID).Scan(&userID, &courier)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("сотрудник не найден")
	}
	if err != nil {
		return "", err
	}
	if !courier {
		return "", apperr.Validation("у сотрудника нет права «Курьер: доставка заказов» — добавьте его в роли")
	}
	return userID, nil
}

// SetCourierLogin задаёт логин и пароль курьера. Старые сессии курьера
// закрываются — он войдёт заново с новым паролем.
func (s *Service) SetCourierLogin(ctx context.Context, p *Principal, employeeID string, in CourierLoginInput) (CourierLoginInfo, error) {
	userID, err := s.courierEmployee(ctx, p, employeeID)
	if err != nil {
		return CourierLoginInfo{}, err
	}
	login := NormalizeLogin(in.Login)
	if !loginRe.MatchString(login) {
		return CourierLoginInfo{}, apperr.Validation("login: латиница, цифры, точка, дефис или _ — от 3 до 32 символов, начинается с буквы или цифры")
	}
	var exists bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM courier_logins WHERE employee_id = $1)`, employeeID).Scan(&exists); err != nil {
		return CourierLoginInfo{}, err
	}
	var hash *string
	if in.Password != "" || !exists {
		if n := utf8.RuneCountInString(in.Password); n < 8 || n > 72 {
			return CourierLoginInfo{}, apperr.Validation("password: от 8 до 72 символов")
		}
		h, err := HashPassword(in.Password)
		if err != nil {
			return CourierLoginInfo{}, err
		}
		hash = &h
	}
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var err error
		if exists {
			_, err = tx.Exec(ctx, `
				UPDATE courier_logins SET login = $2,
				       password_hash = COALESCE($3::text, password_hash),
				       password_changed_at = CASE WHEN $3::text IS NULL THEN password_changed_at ELSE now() END,
				       failed_attempts = CASE WHEN $3::text IS NULL THEN failed_attempts ELSE 0 END,
				       locked_until = CASE WHEN $3::text IS NULL THEN locked_until END
				WHERE employee_id = $1`, employeeID, login, hash)
		} else {
			_, err = tx.Exec(ctx, `INSERT INTO courier_logins (employee_id, network_id, login, password_hash) VALUES ($1, $2, $3, $4)`,
				employeeID, p.NetworkID, login, *hash)
		}
		if db.IsUniqueViolation(err, "courier_logins_login_key") {
			return apperr.Conflict("login_taken", "логин уже занят — придумайте другой")
		}
		if err != nil {
			return err
		}
		if hash != nil {
			_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND app = 'courier' AND revoked_at IS NULL`, userID)
		}
		return err
	})
	if err != nil {
		return CourierLoginInfo{}, err
	}
	return s.CourierLoginOf(ctx, employeeID)
}

// DeleteCourierLogin отключает вход курьера и закрывает его сессии.
func (s *Service) DeleteCourierLogin(ctx context.Context, p *Principal, employeeID string) error {
	if err := p.RequireAny(PermStaffManage, PermOrdersManage); err != nil {
		return err
	}
	if !httpx.IsUUID(employeeID) {
		return apperr.NotFound("сотрудник не найден")
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var userID string
		err := tx.QueryRow(ctx, `
			DELETE FROM courier_logins cl USING employees e
			WHERE cl.employee_id = $1 AND e.id = cl.employee_id AND e.network_id = $2
			RETURNING e.user_id`, employeeID, p.NetworkID).Scan(&userID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("у курьера нет входа")
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND app = 'courier' AND revoked_at IS NULL`, userID)
		return err
	})
}

func (s *Service) CourierLoginOf(ctx context.Context, employeeID string) (CourierLoginInfo, error) {
	i := CourierLoginInfo{EmployeeID: employeeID}
	err := s.pool.QueryRow(ctx, `
		SELECT login, password_changed_at, last_login_at, COALESCE(locked_until > now(), false)
		FROM courier_logins WHERE employee_id = $1`, employeeID).Scan(&i.Login, &i.PasswordChangedAt, &i.LastLoginAt, &i.Locked)
	if errors.Is(err, pgx.ErrNoRows) {
		return i, apperr.NotFound("у курьера нет входа")
	}
	return i, err
}
