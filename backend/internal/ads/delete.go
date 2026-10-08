package ads

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// DeleteAdvertiser — рекламодатель без кампаний.
func (s *Service) DeleteAdvertiser(ctx context.Context, id string) error {
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Рекламодатель", UZ: "Reklama beruvchi"}, false, `DELETE FROM ad_advertisers WHERE id = $1`, id)
}

// DeleteCampaign — кампания, которую ещё не показывали и не выставляли
// по ней счёт; иначе её ставят на паузу (статистика и счета остаются).
func (s *Service) DeleteCampaign(ctx context.Context, id string) error {
	var shown bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM ad_views WHERE campaign_id = $1)`, id).Scan(&shown); err != nil {
		return err
	}
	if shown {
		return apperr.Conflict("in_use", "Кампанию уже показывали — удалить нельзя, чтобы не потерять статистику. Поставьте её на паузу.").Uz("Kampaniya allaqachon koʻrsatilgan — statistika yoʻqolmasligi uchun uni oʻchirib boʻlmaydi. Uni pauzaga qoʻying.").
			WithDetails(map[string]any{"deactivate": true})
	}
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Кампания", UZ: "Kampaniya"}, true, `DELETE FROM ad_campaigns WHERE id = $1`, id)
}

func (m *Module) deleteAdvertiser(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteAdvertiser(r.Context(), id) })
}

func (m *Module) deleteCampaign(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteCampaign(r.Context(), id) })
}
