package billing

import (
	"context"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// DeleteTariff — ступень тарифа подписки: счета хранят сумму, а не ссылку.
func (s *Service) DeleteTariff(ctx context.Context, id string) error {
	return db.Remove(ctx, s.pool, i18n.Text{RU: "Тариф", UZ: "Tarif"}, true, `DELETE FROM tariffs WHERE id = $1`, id)
}

func (m *Module) deleteTariff(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteTariff(r.Context(), id) })
}
