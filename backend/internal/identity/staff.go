package identity

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/phone"
)

// Role — набор прав внутри сети.
type Role struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Permissions []string  `json:"permissions"`
	IsOwner     bool      `json:"is_owner"`
	CreatedAt   time.Time `json:"created_at"`
}

// Employee — сотрудник сети.
type Employee struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	Phone     string    `json:"phone"`
	FullName  string    `json:"full_name"`
	RoleID    string    `json:"role_id"`
	RoleName  string    `json:"role_name"`
	IsOwner   bool      `json:"is_owner"`
	Status    string    `json:"status"`
	AllStores bool      `json:"all_stores"`
	StoreIDs  []string  `json:"store_ids"`
	CreatedAt time.Time `json:"created_at"`
}

const ownerRoleName = "Владелец"

// CreateOwner создаёт роль «Владелец» и сотрудника-владельца новой сети.
// Вызывается модулем tenant внутри транзакции создания сети.
func CreateOwner(ctx context.Context, q db.Querier, networkID, rawPhone, fullName string) (string, error) {
	ph, err := phone.Normalize(rawPhone)
	if err != nil {
		return "", apperr.Validation("owner_phone: неверный номер телефона")
	}
	fullName = strings.TrimSpace(fullName)
	if fullName == "" {
		return "", apperr.Validation("owner_name: обязательное поле")
	}

	var roleID string
	if err := q.QueryRow(ctx, `
		INSERT INTO roles (network_id, name, is_owner) VALUES ($1, $2, true) RETURNING id`,
		networkID, ownerRoleName).Scan(&roleID); err != nil {
		return "", err
	}
	userID, err := upsertUser(ctx, q, ph, fullName)
	if err != nil {
		return "", err
	}
	var employeeID string
	err = q.QueryRow(ctx, `
		INSERT INTO employees (network_id, user_id, role_id, full_name, all_stores)
		VALUES ($1, $2, $3, $4, true) RETURNING id`,
		networkID, userID, roleID, fullName).Scan(&employeeID)
	if db.IsUniqueViolation(err, "employees_user_id_key") {
		return "", apperr.Conflict("employee_exists", "этот номер уже работает в другой сети")
	}
	return employeeID, err
}

func upsertUser(ctx context.Context, q db.Querier, ph, fullName string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO users (phone, full_name) VALUES ($1, $2)
		ON CONFLICT (phone) DO UPDATE
		SET full_name = CASE WHEN users.full_name = '' THEN EXCLUDED.full_name ELSE users.full_name END
		RETURNING id`, ph, fullName).Scan(&id)
	return id, err
}

// ---------------------------------------------------------------- роли

func (s *Service) ListRoles(ctx context.Context, p *Principal) ([]Role, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, name, permissions, is_owner, created_at FROM roles
		WHERE network_id = $1 ORDER BY is_owner DESC, name`, p.NetworkID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Role])
}

// RoleInput — поля роли; nil — не менять.
type RoleInput struct {
	Name        *string   `json:"name"`
	Permissions *[]string `json:"permissions"`
}

func validPermissions(perms []string) ([]string, error) {
	out := make([]string, 0, len(perms))
	for _, code := range perms {
		if !knownPermission(code) {
			return nil, apperr.Validation("permissions: неизвестное право " + code)
		}
		if !slices.Contains(out, code) {
			out = append(out, code)
		}
	}
	slices.Sort(out)
	return out, nil
}

func (s *Service) CreateRole(ctx context.Context, p *Principal, in RoleInput) (Role, error) {
	if err := p.Require(PermStaffManage); err != nil {
		return Role{}, err
	}
	if in.Name == nil || strings.TrimSpace(*in.Name) == "" {
		return Role{}, apperr.Validation("name: обязательное поле")
	}
	perms := []string{}
	if in.Permissions != nil {
		var err error
		if perms, err = validPermissions(*in.Permissions); err != nil {
			return Role{}, err
		}
	}
	var r Role
	err := s.pool.QueryRow(ctx, `
		INSERT INTO roles (network_id, name, permissions) VALUES ($1, $2, $3)
		RETURNING id, name, permissions, is_owner, created_at`,
		p.NetworkID, strings.TrimSpace(*in.Name), perms).Scan(&r.ID, &r.Name, &r.Permissions, &r.IsOwner, &r.CreatedAt)
	if db.IsUniqueViolation(err, "roles_network_id_name_key") {
		return Role{}, apperr.Conflict("role_exists", "роль с таким названием уже есть")
	}
	return r, err
}

func (s *Service) UpdateRole(ctx context.Context, p *Principal, id string, in RoleInput) (Role, error) {
	if err := p.Require(PermStaffManage); err != nil {
		return Role{}, err
	}
	var name *string
	if in.Name != nil {
		n := strings.TrimSpace(*in.Name)
		if n == "" {
			return Role{}, apperr.Validation("name: не может быть пустым")
		}
		name = &n
	}
	var perms []string
	if in.Permissions != nil {
		var err error
		if perms, err = validPermissions(*in.Permissions); err != nil {
			return Role{}, err
		}
	}

	var r Role
	err := s.pool.QueryRow(ctx, `
		UPDATE roles SET
			name        = COALESCE($3, name),
			permissions = CASE WHEN $4::boolean THEN $5::text[] ELSE permissions END
		WHERE id = $1 AND network_id = $2 AND NOT is_owner
		RETURNING id, name, permissions, is_owner, created_at`,
		id, p.NetworkID, name, in.Permissions != nil, perms).Scan(&r.ID, &r.Name, &r.Permissions, &r.IsOwner, &r.CreatedAt)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return Role{}, apperr.NotFound("роль не найдена или это роль владельца")
	case db.IsUniqueViolation(err, "roles_network_id_name_key"):
		return Role{}, apperr.Conflict("role_exists", "роль с таким названием уже есть")
	}
	return r, err
}

// ------------------------------------------------------------ сотрудники

const employeeSelect = `
	SELECT e.id, e.user_id, u.phone, e.full_name, e.role_id, r.name, r.is_owner, e.status, e.all_stores,
	       COALESCE((SELECT array_agg(es.store_id::text ORDER BY es.store_id) FROM employee_stores es
	                 WHERE es.employee_id = e.id), '{}'),
	       e.created_at
	FROM employees e
	JOIN users u ON u.id = e.user_id
	JOIN roles r ON r.id = e.role_id`

func (s *Service) ListEmployees(ctx context.Context, p *Principal, limit, offset int) ([]Employee, error) {
	rows, err := s.pool.Query(ctx, employeeSelect+`
		WHERE e.network_id = $1 ORDER BY r.is_owner DESC, e.full_name LIMIT $2 OFFSET $3`,
		p.NetworkID, limit, offset)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Employee])
}

func (s *Service) getEmployee(ctx context.Context, q db.Querier, networkID, id string) (Employee, error) {
	rows, err := q.Query(ctx, employeeSelect+` WHERE e.network_id = $1 AND e.id = $2`, networkID, id)
	if err != nil {
		return Employee{}, err
	}
	e, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[Employee])
	if errors.Is(err, pgx.ErrNoRows) {
		return Employee{}, apperr.NotFound("сотрудник не найден")
	}
	return e, err
}

// EmployeeInput — поля сотрудника; nil — не менять. Phone задаётся только при создании.
type EmployeeInput struct {
	Phone     *string   `json:"phone"`
	FullName  *string   `json:"full_name"`
	RoleID    *string   `json:"role_id"`
	Status    *string   `json:"status"`
	AllStores *bool     `json:"all_stores"`
	StoreIDs  *[]string `json:"store_ids"`
}

func (s *Service) CreateEmployee(ctx context.Context, p *Principal, in EmployeeInput) (Employee, error) {
	if err := p.Require(PermStaffManage); err != nil {
		return Employee{}, err
	}
	if in.Phone == nil {
		return Employee{}, apperr.Validation("phone: обязательное поле")
	}
	ph, err := phone.Normalize(*in.Phone)
	if err != nil {
		return Employee{}, apperr.Validation("phone: неверный номер телефона")
	}
	if in.FullName == nil || strings.TrimSpace(*in.FullName) == "" {
		return Employee{}, apperr.Validation("full_name: обязательное поле")
	}
	if in.RoleID == nil {
		return Employee{}, apperr.Validation("role_id: обязательное поле")
	}
	fullName := strings.TrimSpace(*in.FullName)
	allStores := in.AllStores != nil && *in.AllStores

	var out Employee
	err = db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		if err := s.checkAssignableRole(ctx, tx, p.NetworkID, *in.RoleID); err != nil {
			return err
		}
		userID, err := upsertUser(ctx, tx, ph, fullName)
		if err != nil {
			return err
		}
		var id string
		err = tx.QueryRow(ctx, `
			INSERT INTO employees (network_id, user_id, role_id, full_name, all_stores)
			VALUES ($1, $2, $3, $4, $5) RETURNING id`,
			p.NetworkID, userID, *in.RoleID, fullName, allStores).Scan(&id)
		if db.IsUniqueViolation(err, "employees_user_id_key") {
			return apperr.Conflict("employee_exists", "этот номер уже работает в сети")
		}
		if err != nil {
			return err
		}
		if in.StoreIDs != nil {
			if err := setEmployeeStores(ctx, tx, p.NetworkID, id, *in.StoreIDs); err != nil {
				return err
			}
		}
		out, err = s.getEmployee(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func (s *Service) UpdateEmployee(ctx context.Context, p *Principal, id string, in EmployeeInput) (Employee, error) {
	if err := p.Require(PermStaffManage); err != nil {
		return Employee{}, err
	}
	if in.Phone != nil {
		return Employee{}, apperr.Validation("phone: номер сотрудника менять нельзя")
	}
	if in.Status != nil && *in.Status != "active" && *in.Status != "inactive" {
		return Employee{}, apperr.Validation("status: ожидается active или inactive")
	}
	var fullName *string
	if in.FullName != nil {
		n := strings.TrimSpace(*in.FullName)
		if n == "" {
			return Employee{}, apperr.Validation("full_name: не может быть пустым")
		}
		fullName = &n
	}

	var out Employee
	err := db.InTx(ctx, s.pool, func(tx pgx.Tx) error {
		cur, err := s.getEmployee(ctx, tx, p.NetworkID, id)
		if err != nil {
			return err
		}
		if cur.IsOwner && (in.RoleID != nil || in.Status != nil || in.AllStores != nil || in.StoreIDs != nil) {
			return apperr.Forbidden("у владельца можно менять только имя")
		}
		if in.RoleID != nil {
			if err := s.checkAssignableRole(ctx, tx, p.NetworkID, *in.RoleID); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `
			UPDATE employees SET
				full_name  = COALESCE($3, full_name),
				role_id    = COALESCE($4, role_id),
				status     = COALESCE($5, status),
				all_stores = COALESCE($6, all_stores)
			WHERE id = $1 AND network_id = $2`,
			id, p.NetworkID, fullName, in.RoleID, in.Status, in.AllStores); err != nil {
			return err
		}
		if in.StoreIDs != nil {
			if err := setEmployeeStores(ctx, tx, p.NetworkID, id, *in.StoreIDs); err != nil {
				return err
			}
		}
		if in.Status != nil && *in.Status == "inactive" {
			// Заблокированный сотрудник сразу теряет все сессии.
			if _, err := tx.Exec(ctx, `
				UPDATE sessions SET revoked_at = now()
				WHERE user_id = $1 AND app = 'store' AND revoked_at IS NULL`, cur.UserID); err != nil {
				return err
			}
		}
		out, err = s.getEmployee(ctx, tx, p.NetworkID, id)
		return err
	})
	return out, err
}

func (s *Service) checkAssignableRole(ctx context.Context, q db.Querier, networkID, roleID string) error {
	if !httpx.IsUUID(roleID) {
		return apperr.Validation("role_id: роль не найдена")
	}
	var isOwner bool
	err := q.QueryRow(ctx, `SELECT is_owner FROM roles WHERE id = $1 AND network_id = $2`, roleID, networkID).Scan(&isOwner)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Validation("role_id: роль не найдена")
	}
	if err != nil {
		return err
	}
	if isOwner {
		return apperr.Validation("role_id: роль владельца назначить нельзя")
	}
	return nil
}

func setEmployeeStores(ctx context.Context, q db.Querier, networkID, employeeID string, storeIDs []string) error {
	if _, err := q.Exec(ctx, `DELETE FROM employee_stores WHERE employee_id = $1`, employeeID); err != nil {
		return err
	}
	if len(storeIDs) == 0 {
		return nil
	}
	for _, id := range storeIDs {
		if !httpx.IsUUID(id) {
			return apperr.Validation("store_ids: магазин не найден в сети")
		}
	}
	tag, err := q.Exec(ctx, `
		INSERT INTO employee_stores (employee_id, store_id, network_id)
		SELECT $1, s.id, s.network_id FROM stores s
		WHERE s.network_id = $2 AND s.id = ANY($3::uuid[])`,
		employeeID, networkID, storeIDs)
	if err != nil {
		return err
	}
	if int(tag.RowsAffected()) != len(uniq(storeIDs)) {
		return apperr.Validation("store_ids: магазин не найден в сети")
	}
	return nil
}

func uniq(ids []string) []string {
	out := slices.Clone(ids)
	slices.Sort(out)
	return slices.Compact(out)
}
