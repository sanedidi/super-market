package tenant

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// DeleteWarehouse — склад без остатков и документов; склад по умолчанию
// магазина удалить нельзя (на него ссылается магазин) — 409.
func (s *Service) DeleteWarehouse(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return err
	}
	return db.Remove(ctx, s.pool, "Склад", true, `DELETE FROM warehouses WHERE id = $1 AND network_id = $2`, id, p.NetworkID)
}

func (m *Module) deleteWarehouse(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error {
		return m.svc.DeleteWarehouse(r.Context(), identity.FromContext(r.Context()), id)
	})
}
