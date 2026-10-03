package pos

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// DeleteDevice — касса, которую ни разу не подключали; работавшую кассу
// отключают (смены и чеки остаются).
func (s *Service) DeleteDevice(ctx context.Context, p *identity.Principal, id string) error {
	if err := p.Require(identity.PermStoresManage); err != nil {
		return err
	}
	var activated bool
	err := s.pool.QueryRow(ctx, `SELECT activated_at IS NOT NULL FROM pos_devices WHERE id = $1 AND network_id = $2`, id, p.NetworkID).Scan(&activated)
	if err == nil && activated {
		return apperr.Conflict("in_use", "Касса уже работала — удалить нельзя, чтобы сохранить смены и чеки. Отключите её.").
			WithDetails(map[string]any{"deactivate": true})
	}
	return db.Remove(ctx, s.pool, "Касса", true, `DELETE FROM pos_devices WHERE id = $1 AND network_id = $2 AND activated_at IS NULL`, id, p.NetworkID)
}

func (m *Module) deleteDevice(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteDevice(r.Context(), pr(r), id) })
}
