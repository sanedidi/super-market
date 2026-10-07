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

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
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
	errBadCredentials  = apperr.New(http.StatusUnauthorized, "invalid_credentials", "неверный логин или пароль").Uz("login yoki parol notoʻgʻri")
	errCourierNoAccess = apperr.Forbidden("вход курьера отключён — обратитесь к менеджеру магазина").Uz("kuryer kirishi oʻchirilgan — doʻkon menejeriga murojaat qiling")
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
	return s.passwordLogin(ctx, rawLogin, password, AppCourier, userAgent)
}

// CourierLoginInfo — логин курьера для панели (пароль не показывается).
type CourierLoginInfo = LoginInfo

// CourierLoginInput — логин и пароль курьера.
type CourierLoginInput = LoginInput

// courierEmployee — курьер сети, которому можно задать вход из раздела
// «Курьеры». Логин владельца меняет только супер-админ; с одним правом
// «Онлайн-заказы» можно менять вход только тем, у кого в роли нет ничего,
// кроме доставки, — иначе через логин курьера можно было бы войти в чужую
// панель с бо́льшими правами.
func (s *Service) courierEmployee(ctx context.Context, p *Principal, employeeID string) (string, error) {
	if err := p.RequireAny(PermStaffManage, PermOrdersManage); err != nil {
		return "", err
	}
	if !httpx.IsUUID(employeeID) {
		return "", apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	var (
		userID                          string
		owner, courier, only, allStores bool
		storeIDs                        []string
	)
	err := s.pool.QueryRow(ctx, `
		SELECT e.user_id, r.is_owner, 'orders.deliver' = ANY(r.permissions),
		       r.permissions <@ ARRAY['orders.deliver']::text[], e.all_stores,
		       COALESCE((SELECT array_agg(es.store_id::text) FROM employee_stores es WHERE es.employee_id = e.id), '{}')
		FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1 AND e.network_id = $2 AND e.status = 'active'`, employeeID, p.NetworkID).Scan(&userID, &owner, &courier, &only, &allStores, &storeIDs)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	if err != nil {
		return "", err
	}
	if owner {
		return "", errOwnerLogin
	}
	if !courier {
		return "", apperr.Validation("у сотрудника нет права «Курьер: доставка заказов» — добавьте его в роли").Uz("xodimda «Kuryer: buyurtmalarni yetkazish» huquqi yoʻq — uni rolga qoʻshing")
	}
	if !only && !p.Can(PermStaffManage) {
		return "", apperr.Forbidden("у сотрудника есть доступ к панели — вход ему меняет тот, у кого право «Роли и сотрудники»").Uz("xodimda panelga ruxsat bor — uning kirish maʼlumotlarini «Rollar va xodimlar» huquqiga ega xodim oʻzgartiradi")
	}
	if err := checkLoginScope(p, allStores, storeIDs); err != nil {
		return "", err
	}
	return userID, nil
}

// SetCourierLogin задаёт логин и пароль курьера. Старые сессии курьера
// закрываются — он войдёт заново с новым паролем. В приложении курьера
// пароль постоянный, а в панель магазина с ним пустят только после смены
// (временный): этот логин мог выдать менеджер заказов, а не владелец.
func (s *Service) SetCourierLogin(ctx context.Context, p *Principal, employeeID string, in CourierLoginInput) (CourierLoginInfo, error) {
	userID, err := s.courierEmployee(ctx, p, employeeID)
	if err != nil {
		return CourierLoginInfo{}, err
	}
	return s.setLogin(ctx, employeeID, p.NetworkID, userID, in, true)
}

// DeleteCourierLogin отключает вход курьера и закрывает его сессии.
func (s *Service) DeleteCourierLogin(ctx context.Context, p *Principal, employeeID string) error {
	userID, err := s.courierEmployee(ctx, p, employeeID)
	if err != nil {
		return err
	}
	return deleteLogin(ctx, s.pool, employeeID, userID)
}

func (s *Service) CourierLoginOf(ctx context.Context, employeeID string) (CourierLoginInfo, error) {
	return loginOf(ctx, s.pool, employeeID)
}
