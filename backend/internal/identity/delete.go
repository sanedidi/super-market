package identity

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// DeleteRole — роль без сотрудников; роль владельца не удаляется.
func (s *Service) DeleteRole(ctx context.Context, p *Principal, id string) error {
	if err := p.Require(PermStaffManage); err != nil {
		return err
	}
	var owner bool
	var staff int
	err := s.pool.QueryRow(ctx, `
		SELECT r.is_owner, (SELECT count(*) FROM employees e WHERE e.role_id = r.id)::int
		FROM roles r WHERE r.id = $1 AND r.network_id = $2`, id, p.NetworkID).Scan(&owner, &staff)
	switch {
	case err == nil && owner:
		return apperr.Conflict("owner_role", "Роль владельца удалить нельзя")
	case err == nil && staff > 0:
		return apperr.Conflict("in_use", "У роли есть сотрудники — сначала назначьте им другую роль")
	}
	return db.Remove(ctx, s.pool, "Роль", false, `DELETE FROM roles WHERE id = $1 AND network_id = $2 AND NOT is_owner`, id, p.NetworkID)
}

// DeleteEmployee — сотрудник без истории (продаж, смен, документов);
// иначе 409 — его отключают. Владельца и себя удалить нельзя.
func (s *Service) DeleteEmployee(ctx context.Context, p *Principal, id string) error {
	if err := p.Require(PermStaffManage); err != nil {
		return err
	}
	if id == p.EmployeeID {
		return apperr.Conflict("self", "Себя удалить нельзя")
	}
	var owner bool
	err := s.pool.QueryRow(ctx, `
		SELECT r.is_owner FROM employees e JOIN roles r ON r.id = e.role_id
		WHERE e.id = $1 AND e.network_id = $2`, id, p.NetworkID).Scan(&owner)
	if err == nil && owner {
		return apperr.Conflict("owner", "Владельца сети удалить нельзя")
	}
	return db.Remove(ctx, s.pool, "Сотрудник", true, `DELETE FROM employees WHERE id = $1 AND network_id = $2`, id, p.NetworkID)
}

func (m *Module) deleteRole(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteRole(r.Context(), FromContext(r.Context()), id) })
}

func (m *Module) deleteEmployee(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteEmployee(r.Context(), FromContext(r.Context()), id) })
}
