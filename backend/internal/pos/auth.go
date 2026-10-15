package pos

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Заголовок с кассиром: касса проверяет ПИН сама (в том числе без
// интернета) и присылает, от чьего имени действует.
const cashierHeader = "X-Cashier-ID"

// deviceAuth пускает запросы с токеном кассы. Кассир из заголовка
// проверяется по базе на каждый запрос: уволенный или без доступа к
// магазину — отказ, даже если касса помнит его ПИН.
func (m *Module) deviceAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, err := m.svc.authenticate(r)
		if err != nil {
			httpx.Fail(w, r, m.log, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(identity.WithPrincipal(r.Context(), p)))
	})
}

func (s *Service) authenticate(r *http.Request) (*identity.Principal, error) {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || !strings.HasPrefix(raw, tokenPrefix) {
		return nil, apperr.Unauthorized("нужен токен кассы").Uz("kassa tokeni kerak")
	}
	ctx := r.Context()
	p := &identity.Principal{App: identity.AppPOS}
	var storeID string
	var lastSeen *time.Time
	var phoneOwner *string
	err := s.pool.QueryRow(ctx, `
		SELECT d.id, d.network_id, n.kind, d.store_id, d.last_seen_at, d.employee_id
		FROM pos_devices d JOIN networks n ON n.id = d.network_id AND n.status = 'active'
		WHERE d.token_hash = $1 AND d.revoked_at IS NULL`, hashSecret(raw)).Scan(
		&p.DeviceID, &p.NetworkID, &p.NetworkKind, &storeID, &lastSeen, &phoneOwner)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.New(http.StatusUnauthorized, "device_revoked", "касса отключена или активирована заново — введите новый код").Uz("kassa oʻchirilgan yoki qayta faollashtirilgan — yangi kodni kiriting")
	}
	if err != nil {
		return nil, err
	}
	p.StoreIDs = []string{storeID}
	if lastSeen == nil || s.now().Sub(*lastSeen) > time.Minute {
		_, _ = s.pool.Exec(ctx, `UPDATE pos_devices SET last_seen_at = now() WHERE id = $1`, p.DeviceID)
	}
	id := strings.TrimSpace(r.Header.Get(cashierHeader))
	if phoneOwner != nil {
		// Касса в телефоне продаёт только от имени своего сотрудника.
		if id != "" && id != *phoneOwner {
			return nil, errCashier
		}
		id = *phoneOwner
	}
	if id != "" {
		if err := s.loadCashier(ctx, p, id); err != nil {
			return nil, err
		}
	}
	return p, nil
}

// loadCashier подставляет права кассира. Владельцу на кассе даются все
// права, но только в магазине этой кассы.
func (s *Service) loadCashier(ctx context.Context, p *identity.Principal, id string) error {
	if !httpx.IsUUID(id) {
		return errCashier
	}
	var perms []string
	var owner bool
	err := s.pool.QueryRow(ctx, `
		SELECT r.permissions, r.is_owner FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1 AND e.network_id = $2 AND e.status = 'active'
		  AND (r.is_owner OR e.all_stores OR EXISTS (SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id = $3))`,
		id, p.NetworkID, p.StoreIDs[0]).Scan(&perms, &owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return errCashier
	}
	if err != nil {
		return err
	}
	if owner {
		perms = perms[:0]
		for _, x := range identity.Permissions {
			perms = append(perms, x.Code)
		}
	}
	p.EmployeeID, p.Permissions = id, perms
	return nil
}

var errCashier = apperr.New(http.StatusUnauthorized, "cashier_invalid", "кассир не найден или нет доступа к этому магазину").Uz("kassir topilmadi yoki bu doʻkonga ruxsati yoʻq")

func requireCashier(p *identity.Principal) error {
	if p.EmployeeID == "" {
		return apperr.New(http.StatusUnauthorized, "cashier_required", "войдите кассиром по ПИНу").Uz("PIN-kod bilan kassir sifatida kiring")
	}
	return p.Require(identity.PermSalesPOS)
}

// --------------------------------------------------------------- ПИН

var pinRe = regexp.MustCompile(`^[0-9]{4,6}$`)

// PinHash — хеш ПИНа, который знает и сервер, и касса (для входа без
// интернета). Привязан к сотруднику, чтобы одинаковые ПИНы не совпадали.
func PinHash(employeeID, pin string) string {
	h := sha256.Sum256([]byte("sm-pos-pin:" + employeeID + ":" + pin))
	return hex.EncodeToString(h[:])
}

type PinInput struct {
	PIN string `json:"pin"`
}

// SetPIN — владелец или менеджер задаёт кассиру ПИН (4–6 цифр).
func (s *Service) SetPIN(ctx context.Context, p *identity.Principal, employeeID string, in PinInput) (map[string]bool, error) {
	if err := p.Require(identity.PermStaffManage); err != nil {
		return nil, err
	}
	if !pinRe.MatchString(in.PIN) {
		return nil, apperr.Validation("pin: 4–6 цифр").Uz("pin: 4–6 ta raqam")
	}
	if !httpx.IsUUID(employeeID) {
		return nil, apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	// Одинаковые ПИНы у двух кассиров одного магазина запутают вход — запрещаем в сети.
	var dup bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees WHERE network_id = $1 AND id <> $2 AND status = 'active'
		AND pin_hash <> '' AND pin_hash = encode(sha256(convert_to('sm-pos-pin:' || id::text || ':' || $3, 'UTF8')), 'hex'))`,
		p.NetworkID, employeeID, in.PIN).Scan(&dup); err != nil {
		return nil, err
	}
	if dup {
		return nil, apperr.Conflict("pin_taken", "такой ПИН уже у другого сотрудника — выберите другой").Uz("bunday PIN-kod boshqa xodimda bor — boshqasini tanlang")
	}
	tag, err := s.pool.Exec(ctx, `UPDATE employees SET pin_hash = $3, pin_failed = 0, pin_locked_until = NULL
		WHERE id = $1 AND network_id = $2`, employeeID, p.NetworkID, PinHash(employeeID, in.PIN))
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	return map[string]bool{"pin_set": true}, nil
}

type LoginInput struct {
	EmployeeID string `json:"employee_id"`
	PIN        string `json:"pin"`
}

type Cashier struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Permissions []string `json:"permissions"`
}

const (
	pinAttempts = 5
	pinLockFor  = 5 * time.Minute
)

// Login проверяет ПИН на сервере (когда касса онлайн). После 5 ошибок подряд
// вход блокируется на 5 минут.
func (s *Service) Login(ctx context.Context, p *identity.Principal, in LoginInput) (Cashier, error) {
	if !httpx.IsUUID(in.EmployeeID) || !pinRe.MatchString(in.PIN) {
		return Cashier{}, apperr.Validation("выберите кассира и введите ПИН").Uz("kassirni tanlang va PIN-kodni kiriting")
	}
	var out Cashier
	var fail error
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		var hash string
		var failed int
		var locked *time.Time
		err := tx.QueryRow(ctx, `SELECT full_name, pin_hash, pin_failed, pin_locked_until FROM employees
			WHERE id = $1 AND network_id = $2 AND status = 'active' FOR UPDATE`, in.EmployeeID, p.NetworkID).Scan(
			&out.Name, &hash, &failed, &locked)
		if errors.Is(err, pgx.ErrNoRows) {
			fail = errCashier
			return nil
		}
		if err != nil {
			return err
		}
		now := s.now()
		switch {
		case locked != nil && locked.After(now):
			fail = apperr.New(http.StatusTooManyRequests, "pin_locked", "много неверных попыток — подождите несколько минут").Uz("notoʻgʻri urinishlar koʻp — bir necha daqiqa kuting").
				WithDetails(map[string]any{"locked_until": locked})
			return nil
		case hash == "":
			fail = apperr.Conflict("pin_not_set", "ПИН не задан — попросите владельца задать его в панели магазина").Uz("PIN-kod oʻrnatilmagan — egasidan uni doʻkon panelida oʻrnatishni soʻrang")
			return nil
		case subtle.ConstantTimeCompare([]byte(hash), []byte(PinHash(in.EmployeeID, in.PIN))) != 1:
			failed++
			var until *time.Time
			if failed >= pinAttempts {
				t := now.Add(pinLockFor)
				until, failed = &t, 0
			}
			if _, err := tx.Exec(ctx, `UPDATE employees SET pin_failed = $2, pin_locked_until = $3 WHERE id = $1`,
				in.EmployeeID, failed, until); err != nil {
				return err
			}
			left := pinAttempts - failed
			if until != nil {
				left = 0
			}
			fail = apperr.New(http.StatusUnauthorized, "wrong_pin", "неверный ПИН").Uz("PIN-kod notoʻgʻri").WithDetails(map[string]any{"attempts_left": left})
			return nil
		}
		_, err = tx.Exec(ctx, `UPDATE employees SET pin_failed = 0, pin_locked_until = NULL WHERE id = $1`, in.EmployeeID)
		return err
	})
	if err != nil {
		return Cashier{}, err
	}
	if fail != nil {
		return Cashier{}, fail
	}
	if err := s.loadCashier(ctx, p, in.EmployeeID); err != nil {
		return Cashier{}, err
	}
	if err := p.Require(identity.PermSalesPOS); err != nil {
		return Cashier{}, apperr.Forbidden("у сотрудника нет права продавать на кассе").Uz("xodimda kassada sotish huquqi yoʻq")
	}
	out.ID, out.Permissions = in.EmployeeID, p.Permissions
	return out, nil
}

// PinRow — сотрудник в списке «ПИНы кассиров» панели.
type PinRow struct {
	EmployeeID string `json:"employee_id"`
	Name       string `json:"name"`
	RoleName   string `json:"role_name"`
	IsOwner    bool   `json:"is_owner"`
	HasPIN     bool   `json:"has_pin"`
	Locked     bool   `json:"locked"`
	// Права на кассе: продавать, скидки, возвраты (старший кассир).
	CanPOS      bool `json:"can_pos"`
	CanDiscount bool `json:"can_discount"`
	CanReturn   bool `json:"can_return"`
}

// ListPins — активные сотрудники магазина и есть ли у них ПИН. На кассе
// в списке «Кто на кассе?» будут те, у кого есть ПИН и право продавать.
func (s *Service) ListPins(ctx context.Context, p *identity.Principal, storeID string) ([]PinRow, error) {
	if err := p.Require(identity.PermStaffManage); err != nil {
		return nil, err
	}
	if storeID != "" && (!httpx.IsUUID(storeID) || !p.CanAccessStore(storeID)) {
		return nil, apperr.Validation("store_id: магазин не найден").Uz("store_id: doʻkon topilmadi")
	}
	rows, err := s.pool.Query(ctx, `
		SELECT e.id, e.full_name, r.name, r.is_owner, e.pin_hash <> '', COALESCE(e.pin_locked_until > now(), false),
		       r.is_owner OR $3 = ANY(r.permissions), r.is_owner OR $4 = ANY(r.permissions), r.is_owner OR $5 = ANY(r.permissions)
		FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.network_id = $1 AND e.status = 'active'
		  AND ($2 = '' OR r.is_owner OR e.all_stores OR EXISTS (
		       SELECT 1 FROM employee_stores es WHERE es.employee_id = e.id AND es.store_id::text = $2))
		ORDER BY NOT (r.is_owner OR $3 = ANY(r.permissions)), e.full_name`,
		p.NetworkID, storeID, identity.PermSalesPOS, identity.PermSalesDiscount, identity.PermSalesReturn)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[PinRow])
}

// ClearPIN — убрать ПИН: сотрудник пропадёт из списка на кассе.
func (s *Service) ClearPIN(ctx context.Context, p *identity.Principal, employeeID string) (map[string]bool, error) {
	if err := p.Require(identity.PermStaffManage); err != nil {
		return nil, err
	}
	if !httpx.IsUUID(employeeID) {
		return nil, apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	tag, err := s.pool.Exec(ctx, `UPDATE employees SET pin_hash = '', pin_failed = 0, pin_locked_until = NULL
		WHERE id = $1 AND network_id = $2`, employeeID, p.NetworkID)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, apperr.NotFound("сотрудник не найден").Uz("xodim topilmadi")
	}
	return map[string]bool{"pin_set": false}, nil
}
