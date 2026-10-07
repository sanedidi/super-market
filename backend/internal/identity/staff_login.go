package identity

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
)

// Вход сотрудников по логину и паролю (таблица employee_logins).
//
// Владельцу логин и временный пароль выдаёт супер-админ при подключении
// сети, сотрудникам — владелец (или менеджер с правом «Роли и сотрудники»).
// Временный пароль (must_change_password) пускает в панель магазина только
// на экран смены пароля; приложение курьера его не проверяет.
// После 5 неверных паролей подряд вход по логину закрывается на 15 минут.

var (
	errStoreNoAccess = apperr.Forbidden("нет доступа к панели магазина — обратитесь к владельцу или в поддержку Super Market")
	// ErrPasswordChangeRequired — пароль временный: сначала смените его.
	ErrPasswordChangeRequired = apperr.New(http.StatusForbidden, "password_change_required", "придумайте свой пароль — временный пароль нужно сменить")
	errCodeLoginDisabled      = apperr.New(http.StatusForbidden, "password_login_required", "вход в магазин — по логину и паролю")
	errWrongCurrentPassword   = apperr.New(http.StatusUnprocessableEntity, "wrong_password", "текущий пароль неверный")
	errOwnerLogin             = apperr.Forbidden("логин и пароль владельца меняет Super Market — напишите в поддержку")
)

// LoginInfo — логин сотрудника для панели (пароль не показывается).
type LoginInfo struct {
	EmployeeID         string     `json:"employee_id"`
	Login              string     `json:"login"`
	MustChangePassword bool       `json:"must_change_password"`
	PasswordChangedAt  time.Time  `json:"password_changed_at"`
	LastLoginAt        *time.Time `json:"last_login_at"`
	Locked             bool       `json:"locked"`
}

// LoginInput — логин и пароль. Пустой пароль — оставить прежний (только смена логина).
type LoginInput struct {
	Login    string `json:"login"`
	Password string `json:"password"`
}

// validTempPassword — пароль, который задаёт супер-админ или магазин.
func validTempPassword(pw string) error {
	if n := utf8.RuneCountInString(pw); n < 8 || n > 72 {
		return apperr.Validation("password: от 8 до 72 символов")
	}
	return nil
}

// validOwnPassword — пароль, который сотрудник придумывает себе сам.
func validOwnPassword(pw string) error {
	if n := utf8.RuneCountInString(pw); n < 8 || n > 72 {
		return apperr.Validation("new_password: от 8 до 72 символов")
	}
	var letter, digit bool
	for _, r := range pw {
		switch {
		case unicode.IsLetter(r):
			letter = true
		case unicode.IsDigit(r):
			digit = true
		}
	}
	if !letter || !digit {
		return apperr.Validation("new_password: нужны и буквы, и цифры")
	}
	return nil
}

func validLogin(raw string) (string, error) {
	login := NormalizeLogin(raw)
	if !loginRe.MatchString(login) {
		return "", apperr.Validation("login: латиница, цифры, точка, дефис или _ — от 3 до 32 символов, начинается с буквы или цифры")
	}
	return login, nil
}

// upsertLogin создаёт или меняет логин сотрудника. hash == nil — пароль не
// меняется (только логин). Новый пароль сбрасывает счётчик ошибок и
// блокировку; mustChange — временный ли он.
func upsertLogin(ctx context.Context, q db.Querier, employeeID, networkID, login string, hash *string, mustChange bool) error {
	var err error
	if hash == nil {
		tag, e := q.Exec(ctx, `UPDATE employee_logins SET login = $2 WHERE employee_id = $1`, employeeID, login)
		if err = e; err == nil && tag.RowsAffected() == 0 {
			return apperr.Validation("password: обязательное поле")
		}
	} else {
		_, err = q.Exec(ctx, `
			INSERT INTO employee_logins (employee_id, network_id, login, password_hash, must_change_password)
			VALUES ($1, $2, $3, $4, $5)
			ON CONFLICT (employee_id) DO UPDATE SET
				login = EXCLUDED.login, password_hash = EXCLUDED.password_hash,
				must_change_password = EXCLUDED.must_change_password,
				password_changed_at = now(), failed_attempts = 0, locked_until = NULL`,
			employeeID, networkID, login, *hash, mustChange)
	}
	if db.IsUniqueViolation(err, "employee_logins_login_key") {
		return apperr.Conflict("login_taken", "логин уже занят — придумайте другой")
	}
	return err
}

// hashIfSet проверяет и хэширует пароль; пустой — nil, если логин уже есть.
func hashIfSet(password string, exists bool) (*string, error) {
	if password == "" && exists {
		return nil, nil
	}
	if err := validTempPassword(password); err != nil {
		return nil, err
	}
	h, err := HashPassword(password)
	if err != nil {
		return nil, err
	}
	return &h, nil
}

// revokeSessions закрывает сессии сотрудника в панели магазина и в
// приложении курьера (кроме except) и отвязывает их устройства от push.
func revokeSessions(ctx context.Context, q db.Querier, userID, except string) error {
	if _, err := q.Exec(ctx, `
		DELETE FROM devices WHERE session_id IN (
			SELECT id FROM sessions WHERE user_id = $1 AND app IN ('store', 'courier')
			  AND revoked_at IS NULL AND id::text <> $2)`, userID, except); err != nil {
		return err
	}
	_, err := q.Exec(ctx, `
		UPDATE sessions SET revoked_at = now()
		WHERE user_id = $1 AND app IN ('store', 'courier') AND revoked_at IS NULL AND id::text <> $2`, userID, except)
	return err
}

func loginOf(ctx context.Context, q db.Querier, employeeID string) (LoginInfo, error) {
	i := LoginInfo{EmployeeID: employeeID}
	err := q.QueryRow(ctx, `
		SELECT login, must_change_password, password_changed_at, last_login_at, COALESCE(locked_until > now(), false)
		FROM employee_logins WHERE employee_id = $1`, employeeID).Scan(
		&i.Login, &i.MustChangePassword, &i.PasswordChangedAt, &i.LastLoginAt, &i.Locked)
	if errors.Is(err, pgx.ErrNoRows) {
		return i, apperr.NotFound("у сотрудника нет логина")
	}
	return i, err
}

// ------------------------------------------------------------------ вход

// passwordLogin — вход по логину и паролю в приложение app (store или courier).
func (s *Service) passwordLogin(ctx context.Context, rawLogin, password, app, userAgent string) (Tokens, error) {
	login := NormalizeLogin(rawLogin)
	if login == "" || password == "" {
		return Tokens{}, apperr.Validation("введите логин и пароль")
	}
	var (
		employeeID, userID, hash string
		active, courier, temp    bool
	)
	err := s.pool.QueryRow(ctx, `
		SELECT el.employee_id, e.user_id, el.password_hash, el.must_change_password,
		       e.status = 'active' AND n.status = 'active',
		       r.is_owner OR 'orders.deliver' = ANY(r.permissions)
		FROM employee_logins el
		JOIN employees e ON e.id = el.employee_id
		JOIN roles r ON r.id = e.role_id
		JOIN networks n ON n.id = e.network_id
		WHERE el.login = $1`, login).Scan(&employeeID, &userID, &hash, &temp, &active, &courier)
	if errors.Is(err, pgx.ErrNoRows) {
		CheckPassword(dummyHash, password)
		return Tokens{}, errBadCredentials
	}
	if err != nil {
		return Tokens{}, err
	}
	// Попытка засчитывается до проверки пароля и атомарно: параллельные
	// запросы не дадут больше 5 попыток за 15 минут. Истёкшая блокировка
	// начинает счёт заново; на 5-й попытке вход закрывается.
	now := s.now()
	var fails int
	err = s.pool.QueryRow(ctx, `
		UPDATE employee_logins SET
			failed_attempts = CASE WHEN locked_until IS NOT NULL THEN 1 ELSE failed_attempts + 1 END,
			locked_until = CASE WHEN (CASE WHEN locked_until IS NOT NULL THEN 1 ELSE failed_attempts + 1 END) >= $2
			                    THEN $3::timestamptz END
		WHERE employee_id = $1 AND (locked_until IS NULL OR locked_until <= $4)
		RETURNING failed_attempts`, employeeID, courierMaxFails, now.Add(courierLockFor), now).Scan(&fails)
	if errors.Is(err, pgx.ErrNoRows) {
		var until time.Time
		if err := s.pool.QueryRow(ctx, `SELECT COALESCE(locked_until, $2) FROM employee_logins WHERE employee_id = $1`,
			employeeID, now.Add(courierLockFor)).Scan(&until); err != nil {
			return Tokens{}, err
		}
		wait := int(until.Sub(now).Seconds()) + 1
		return Tokens{}, apperr.New(http.StatusTooManyRequests, "too_many_requests",
			fmt.Sprintf("слишком много неверных паролей — попробуйте через %d мин", (wait+59)/60)).
			WithDetails(map[string]any{"retry_after": wait})
	}
	if err != nil {
		return Tokens{}, err
	}
	if !CheckPassword(hash, password) {
		if fails >= courierMaxFails {
			return Tokens{}, apperr.New(http.StatusTooManyRequests, "too_many_requests", "слишком много неверных паролей — вход закрыт на 15 минут").
				WithDetails(map[string]any{"retry_after": int(courierLockFor.Seconds())})
		}
		return Tokens{}, errBadCredentials.WithDetails(map[string]any{"attempts_left": courierMaxFails - fails})
	}
	switch {
	case app == AppCourier && (!active || !courier):
		return Tokens{}, errCourierNoAccess
	case app == AppStore && !active:
		return Tokens{}, errStoreNoAccess
	}
	var sessionID, refresh string
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		// Пароль не сменили, пока проверяли: иначе вход по старому паролю
		// пережил бы сброс (сессия появилась бы уже после закрытия всех сессий).
		tag, err := tx.Exec(ctx, `
			UPDATE employee_logins SET failed_attempts = 0, locked_until = NULL, last_login_at = now()
			WHERE employee_id = $1 AND password_hash = $2`, employeeID, hash)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return errBadCredentials
		}
		sessionID, refresh, err = s.createSession(ctx, tx, userID, app, userAgent)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	s.rememberLang(ctx, userID, app)
	t, err := s.tokens(userID, sessionID, app, refresh)
	t.PasswordChangeRequired = temp && app == AppStore
	return t, err
}

// StoreLogin — вход в панель магазина и в «SM Магазин».
func (s *Service) StoreLogin(ctx context.Context, login, password, userAgent string) (Tokens, error) {
	return s.passwordLogin(ctx, login, password, AppStore, userAgent)
}

// ChangePassword — сотрудник меняет свой пароль. При временном пароле
// текущий не спрашивается (он только что вошёл с ним). Остальные сессии
// сотрудника закрываются.
func (s *Service) ChangePassword(ctx context.Context, p *Principal, current, next string) error {
	if err := validOwnPassword(next); err != nil {
		return err
	}
	newHash, err := HashPassword(next)
	if err != nil {
		return err
	}
	return db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var (
			hash string
			temp bool
		)
		err := tx.QueryRow(ctx, `SELECT password_hash, must_change_password FROM employee_logins WHERE employee_id = $1 FOR UPDATE`,
			p.EmployeeID).Scan(&hash, &temp)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.NotFound("у вас нет логина")
		}
		if err != nil {
			return err
		}
		if !temp && !CheckPassword(hash, current) {
			return errWrongCurrentPassword
		}
		if CheckPassword(hash, next) {
			return apperr.Validation("new_password: совпадает с прежним — придумайте другой")
		}
		if _, err := tx.Exec(ctx, `
			UPDATE employee_logins SET password_hash = $2, must_change_password = false,
			       password_changed_at = now(), failed_attempts = 0, locked_until = NULL
			WHERE employee_id = $1`, p.EmployeeID, newHash); err != nil {
			return err
		}
		return revokeSessions(ctx, tx, p.UserID, p.SessionID)
	})
}

// ----------------------------------------------- логины сотрудников (панель)

// staffEmployee — сотрудник сети, которому можно задать логин из панели.
// Логин владельца меняет только супер-админ.
func (s *Service) staffEmployee(ctx context.Context, p *Principal, employeeID string) (string, error) {
	if err := p.Require(PermStaffManage); err != nil {
		return "", err
	}
	if !httpx.IsUUID(employeeID) {
		return "", apperr.NotFound("сотрудник не найден")
	}
	var (
		userID    string
		owner     bool
		allStores bool
		storeIDs  []string
	)
	err := s.pool.QueryRow(ctx, `
		SELECT e.user_id, r.is_owner, e.all_stores,
		       COALESCE((SELECT array_agg(es.store_id::text) FROM employee_stores es WHERE es.employee_id = e.id), '{}')
		FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1 AND e.network_id = $2 AND e.status = 'active'`, employeeID, p.NetworkID).Scan(&userID, &owner, &allStores, &storeIDs)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("сотрудник не найден")
	}
	if err != nil {
		return "", err
	}
	if owner {
		return "", errOwnerLogin
	}
	if err := checkLoginScope(p, allStores, storeIDs); err != nil {
		return "", err
	}
	return userID, nil
}

// checkLoginScope — вход сотрудника меняет только тот, кто видит все его
// магазины: иначе через сброс пароля менеджер одного магазина вошёл бы под
// сотрудником с доступом ко всем магазинам.
func checkLoginScope(p *Principal, allStores bool, storeIDs []string) error {
	if p.SeesAllStores() {
		return nil
	}
	if allStores {
		return apperr.Forbidden("у сотрудника доступ ко всем магазинам — его вход меняет тот, кто сам видит все магазины")
	}
	for _, id := range storeIDs {
		if !p.CanAccessStore(id) {
			return apperr.Forbidden("сотрудник работает и в магазинах, к которым у вас нет доступа — его вход меняет владелец")
		}
	}
	return nil
}

// EmployeeLogin — логин сотрудника (для панели).
func (s *Service) EmployeeLogin(ctx context.Context, p *Principal, employeeID string) (LoginInfo, error) {
	if !httpx.IsUUID(employeeID) {
		return LoginInfo{}, apperr.NotFound("сотрудник не найден")
	}
	var ok bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees WHERE id = $1 AND network_id = $2)`,
		employeeID, p.NetworkID).Scan(&ok); err != nil {
		return LoginInfo{}, err
	}
	if !ok {
		return LoginInfo{}, apperr.NotFound("сотрудник не найден")
	}
	return loginOf(ctx, s.pool, employeeID)
}

// SetEmployeeLogin задаёт сотруднику логин и временный пароль: при первом
// входе в панель он придумает свой. Старые сессии сотрудника закрываются.
func (s *Service) SetEmployeeLogin(ctx context.Context, p *Principal, employeeID string, in LoginInput) (LoginInfo, error) {
	userID, err := s.staffEmployee(ctx, p, employeeID)
	if err != nil {
		return LoginInfo{}, err
	}
	return s.setLogin(ctx, employeeID, p.NetworkID, userID, in, true)
}

// DeleteEmployeeLogin отключает вход сотрудника и закрывает его сессии.
func (s *Service) DeleteEmployeeLogin(ctx context.Context, p *Principal, employeeID string) error {
	userID, err := s.staffEmployee(ctx, p, employeeID)
	if err != nil {
		return err
	}
	return deleteLogin(ctx, s.pool, employeeID, userID)
}

func deleteLogin(ctx context.Context, pool *pgxpool.Pool, employeeID, userID string) error {
	return db.InTx(ctx, pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM employee_logins WHERE employee_id = $1`, employeeID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.NotFound("у сотрудника нет логина")
		}
		return revokeSessions(ctx, tx, userID, "")
	})
}

func (s *Service) setLogin(ctx context.Context, employeeID, networkID, userID string, in LoginInput, mustChange bool) (LoginInfo, error) {
	return setLogin(ctx, s.pool, employeeID, networkID, userID, in, mustChange)
}

func setLogin(ctx context.Context, pool *pgxpool.Pool, employeeID, networkID, userID string, in LoginInput, mustChange bool) (LoginInfo, error) {
	login, err := validLogin(in.Login)
	if err != nil {
		return LoginInfo{}, err
	}
	var exists bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employee_logins WHERE employee_id = $1)`, employeeID).Scan(&exists); err != nil {
		return LoginInfo{}, err
	}
	hash, err := hashIfSet(in.Password, exists)
	if err != nil {
		return LoginInfo{}, err
	}
	err = db.InTx(ctx, pool, func(tx pgx.Tx) error {
		if err := upsertLogin(ctx, tx, employeeID, networkID, login, hash, mustChange); err != nil {
			return err
		}
		if hash != nil {
			return revokeSessions(ctx, tx, userID, "")
		}
		return nil
	})
	if err != nil {
		return LoginInfo{}, err
	}
	return loginOf(ctx, pool, employeeID)
}

// ------------------------------------------------- владелец (супер-админ)

// PrepareOwnerLogin проверяет логин и пароль владельца новой сети и
// хэширует пароль — до транзакции создания сети (хэш считается долго).
// Пустые логин и пароль — сеть без входа (логин выдадут позже).
func PrepareOwnerLogin(in LoginInput) (login string, hash *string, err error) {
	if in.Login == "" && in.Password == "" {
		return "", nil, nil
	}
	if login, err = validLogin(in.Login); err != nil {
		return "", nil, apperr.Validation("owner_login: латиница, цифры, точка, дефис или _ — от 3 до 32 символов")
	}
	if err := validTempPassword(in.Password); err != nil {
		return "", nil, apperr.Validation("owner_password: от 8 до 72 символов")
	}
	h, err := HashPassword(in.Password)
	if err != nil {
		return "", nil, err
	}
	return login, &h, nil
}

// CreateOwnerLogin сохраняет логин и временный пароль владельца
// (в транзакции создания сети).
func CreateOwnerLogin(ctx context.Context, q db.Querier, employeeID, networkID, login string, hash *string) error {
	if hash == nil {
		return nil
	}
	return upsertLogin(ctx, q, employeeID, networkID, login, hash, true)
}

func ownerOf(ctx context.Context, q db.Querier, networkID string) (employeeID, userID string, err error) {
	err = q.QueryRow(ctx, `
		SELECT e.id, e.user_id FROM employees e JOIN roles r ON r.id = e.role_id AND r.is_owner
		WHERE e.network_id = $1`, networkID).Scan(&employeeID, &userID)
	if errors.Is(err, pgx.ErrNoRows) {
		err = apperr.NotFound("сеть не найдена")
	}
	return
}

// SetOwnerLogin — супер-админ задаёт или меняет логин владельца; с паролем —
// сброс: новый временный пароль, все сессии владельца закрываются.
func SetOwnerLogin(ctx context.Context, pool *pgxpool.Pool, networkID string, in LoginInput) (LoginInfo, error) {
	if !httpx.IsUUID(networkID) {
		return LoginInfo{}, apperr.NotFound("сеть не найдена")
	}
	employeeID, userID, err := ownerOf(ctx, pool, networkID)
	if err != nil {
		return LoginInfo{}, err
	}
	return setLogin(ctx, pool, employeeID, networkID, userID, in, true)
}

// OwnerInput — имя и телефон владельца; nil — не менять.
type OwnerInput struct {
	FullName *string `json:"full_name"`
	Phone    *string `json:"phone"`
}

// UpdateOwner — супер-админ меняет имя или телефон владельца. Телефон
// владельца в панели магазина не меняется — только здесь. Новый номер —
// это другой пользователь (у старого номера остаётся его аккаунт
// покупателя); сессии владельца в панели закрываются, логин сохраняется.
func UpdateOwner(ctx context.Context, pool *pgxpool.Pool, networkID string, in OwnerInput) error {
	if !httpx.IsUUID(networkID) {
		return apperr.NotFound("сеть не найдена")
	}
	var name *string
	if in.FullName != nil {
		n := strings.TrimSpace(*in.FullName)
		if n == "" {
			return apperr.Validation("full_name: не может быть пустым")
		}
		name = &n
	}
	var ph string
	if in.Phone != nil {
		var err error
		if ph, err = phone.Normalize(*in.Phone); err != nil {
			return apperr.Validation("phone: неверный номер телефона")
		}
	}
	return db.InTx(ctx, pool, func(tx pgx.Tx) error {
		employeeID, userID, err := ownerOf(ctx, tx, networkID)
		if err != nil {
			return err
		}
		if name != nil {
			if _, err := tx.Exec(ctx, `UPDATE employees SET full_name = $2 WHERE id = $1`, employeeID, *name); err != nil {
				return err
			}
		}
		if ph == "" {
			return nil
		}
		var fullName string
		if err := tx.QueryRow(ctx, `SELECT full_name FROM employees WHERE id = $1`, employeeID).Scan(&fullName); err != nil {
			return err
		}
		newUser, err := upsertUser(ctx, tx, ph, fullName)
		if err != nil {
			return err
		}
		if newUser == userID {
			return nil
		}
		_, err = tx.Exec(ctx, `UPDATE employees SET user_id = $2 WHERE id = $1`, employeeID, newUser)
		if db.IsUniqueViolation(err, "employees_user_id_key") {
			return apperr.Conflict("employee_exists", "этот номер уже работает в сети — сначала уберите его оттуда")
		}
		if err != nil {
			return err
		}
		// Сессии и старого номера, и нового (если он раньше где-то работал):
		// владелец входит заново по логину и паролю.
		if err := revokeSessions(ctx, tx, newUser, ""); err != nil {
			return err
		}
		return revokeSessions(ctx, tx, userID, "")
	})
}
