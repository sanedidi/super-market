package ai

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
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/ai", m.get)
		r.Put("/admin/ai", m.save)
		r.Post("/admin/ai/models", m.models)
		r.Post("/admin/ai/test", m.test)
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.Get(r.Context()) })
}

func (m *Module) save(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Input) (Settings, error) {
		return m.svc.Save(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}

func (m *Module) models(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Input) (httpx.List[Model], error) {
		items, err := m.svc.Models(r.Context(), in)
		return httpx.List[Model]{Items: items}, err
	})
}

func (m *Module) test(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Input) (TestResult, error) {
		return m.svc.Test(r.Context(), in)
	})
}
