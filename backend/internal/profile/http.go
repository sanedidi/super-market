package profile

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
	r.Get("/client/config", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, m.svc.Config())
	})
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppClient))
		r.Get("/client/me", m.get)
		r.Patch("/client/me", m.update)
		r.Delete("/client/me", m.delete)
		r.Get("/client/me/stats", m.stats)
		r.Post("/client/devices", m.registerDevice)
		r.Delete("/client/devices/{token}", m.removeDevice)
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Profile, error) { return m.svc.Get(r.Context(), p.UserID) })
}

func (m *Module) update(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in UpdateInput) (Profile, error) {
		return m.svc.Update(r.Context(), p.UserID, in)
	})
}

func (m *Module) stats(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Stats, error) { return m.svc.Stats(r.Context(), p.UserID) })
}

func (m *Module) delete(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	if err := m.svc.Delete(r.Context(), p.UserID); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) registerDevice(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	var in DeviceInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	if err := m.svc.RegisterDevice(r.Context(), p.UserID, p.SessionID, in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) removeDevice(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	if err := m.svc.RemoveDevice(r.Context(), p.UserID, chi.URLParam(r, "token")); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
