package admin

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
		r.Get("/admin/stats", m.stats)
		r.Get("/admin/customers", m.listCustomers)
		r.Get("/admin/customers/{id}", m.getCustomer)
		r.Post("/admin/customers/{id}/block", m.blockCustomer)
		r.Post("/admin/customers/{id}/unblock", m.unblockCustomer)
		r.Get("/admin/notifications", m.listNotifications)
		r.Post("/admin/notifications/{id}/retry", m.retryNotification)
	})
}

func (m *Module) stats(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Stats, error) { return m.svc.Stats(r.Context()) })
}

func (m *Module) listCustomers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Customer], error) {
		items, err := m.svc.ListCustomers(r.Context(), CustomerFilter{
			Query: q.Get("q"), Blocked: q.Get("blocked") == "true", Page: httpx.PageFrom(r),
		})
		return httpx.List[Customer]{Items: items}, err
	})
}

func (m *Module) getCustomer(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CustomerDetail, error) {
		return m.svc.GetCustomer(r.Context(), id)
	})
}

func (m *Module) blockCustomer(w http.ResponseWriter, r *http.Request) {
	type body struct {
		Reason string `json:"reason"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in body) (CustomerDetail, error) {
		return m.svc.BlockCustomer(r.Context(), id, in.Reason)
	})
}

func (m *Module) unblockCustomer(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CustomerDetail, error) {
		return m.svc.UnblockCustomer(r.Context(), id)
	})
}

func (m *Module) listNotifications(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Notification], error) {
		items, err := m.svc.ListNotifications(r.Context(), NotificationFilter{
			Status: q.Get("status"), Kind: q.Get("kind"), Query: q.Get("q"), Page: httpx.PageFrom(r),
		})
		return httpx.List[Notification]{Items: items}, err
	})
}

func (m *Module) retryNotification(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Notification, error) {
		return m.svc.RetryNotification(r.Context(), chi.URLParam(r, "id"))
	})
}
