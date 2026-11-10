package catalognorm

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
		r.Get("/admin/catalog-norm/settings", m.settings)
		r.Put("/admin/catalog-norm/settings", m.saveSettings)
		r.Get("/admin/catalog-norm/runs", m.runs)
		r.Post("/admin/catalog-norm/runs", m.start)
		r.Get("/admin/catalog-norm/runs/{id}", m.run)
		r.Get("/admin/catalog-norm/runs/{id}/changes", m.changes)
		r.Post("/admin/catalog-norm/runs/{id}/apply", m.apply)
		r.Post("/admin/catalog-norm/runs/{id}/rollback", m.rollback)
	})
}

func (m *Module) settings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.Settings(r.Context()) })
}

func (m *Module) saveSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SettingsInput) (Settings, error) {
		return m.svc.SaveSettings(r.Context(), in)
	})
}

func (m *Module) runs(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (RunList, error) { return m.svc.Runs(r.Context(), httpx.PageFrom(r)) })
}

func (m *Module) start(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in StartInput) (Run, error) {
		return m.svc.Start(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}

func (m *Module) run(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Run, error) { return m.svc.Run(r.Context(), id) })
}

func (m *Module) changes(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (ChangeList, error) {
		q := r.URL.Query()
		return m.svc.Changes(r.Context(), id, q.Get("kind"), q.Get("q"), httpx.PageFrom(r))
	})
}

func (m *Module) apply(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusAccepted, "id", func(id string) (Run, error) { return m.svc.Apply(r.Context(), id) })
}

func (m *Module) rollback(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Run, error) { return m.svc.Rollback(r.Context(), id) })
}
