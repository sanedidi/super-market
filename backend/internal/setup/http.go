package setup

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Module struct {
	svc  *Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	r.Route("/store/setup", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/", m.get)
		r.Post("/store", m.saveStore)
		r.Put("/hours", m.saveHours)
		r.Put("/delivery", m.saveDelivery)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (State, error) {
		return m.svc.Get(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) saveStore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in StoreInput) (State, error) {
		return m.svc.SaveStore(r.Context(), pr(r), in)
	})
}

func (m *Module) saveHours(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in HoursInput) (State, error) {
		return m.svc.SaveHours(r.Context(), pr(r), in)
	})
}

func (m *Module) saveDelivery(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in DeliveryInput) (State, error) {
		return m.svc.SaveDelivery(r.Context(), pr(r), in)
	})
}
