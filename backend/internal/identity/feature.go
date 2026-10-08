package identity

import (
	"log/slog"
	"net/http"

	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/db"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Feature пускает запрос, только если функция входит в действующий тариф
// сети (403 plan_feature иначе). Ставится после Require(AppStore).
func (a *Authenticator) Feature(feature string) func(http.Handler) http.Handler {
	return RequireFeature(a.svc.pool, a.log, feature)
}

// RequireFeature — то же для модулей со своей авторизацией (касса).
func RequireFeature(q db.Querier, log *slog.Logger, feature string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p := FromContext(r.Context())
			if p == nil {
				httpx.Fail(w, r, log, apperr.Unauthorized("нужен токен авторизации").Uz("avtorizatsiya tokeni kerak"))
				return
			}
			if p.NetworkID != "" {
				if err := plans.Require(r.Context(), q, p.NetworkID, feature); err != nil {
					httpx.Fail(w, r, log, err)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
