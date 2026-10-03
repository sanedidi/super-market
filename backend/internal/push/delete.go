package push

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// DeleteCampaign — запланированная или отменённая рассылка; отправленная
// остаётся в журнале доставки.
func (s *Service) DeleteCampaign(ctx context.Context, id string) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM push_campaigns WHERE id = $1 AND status IN ('scheduled', 'cancelled')`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM push_campaigns WHERE id = $1)`, id).Scan(&exists); err != nil {
			return err
		}
		if exists {
			return apperr.Conflict("campaign_sent", "Рассылка уже отправлена — она остаётся в журнале доставки")
		}
		return apperr.NotFound("рассылка не найдена")
	}
	return nil
}

func (m *Module) deleteCampaign(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteCampaign(r.Context(), id) })
}
