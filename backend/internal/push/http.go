package push

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Module — рассылки и тестовый push в супер-админке.
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
		r.Get("/admin/push/overview", m.overview)
		r.Get("/admin/push/campaigns", m.list)
		r.Post("/admin/push/campaigns", m.create)
		r.Post("/admin/push/campaigns/preview", m.preview)
		r.Get("/admin/push/campaigns/{id}", m.get)
		r.Get("/admin/push/campaigns/{id}/recipients", m.recipients)
		r.Post("/admin/push/campaigns/{id}/cancel", m.cancel)
		r.Get("/admin/push/customer", m.customer)
		r.Post("/admin/push/test", m.test)
		r.Get("/admin/push/blocks", m.blocks)
		r.Get("/admin/push/cities", m.cities)
	})
	// Приложение магазина: устройство сотрудника для push.
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Post("/store/devices", m.storeDevice)
		r.Delete("/store/devices/{token}", m.removeStoreDevice)
	})
}

type storeDeviceInput struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

func (m *Module) storeDevice(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	var in storeDeviceInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	if err := RegisterStoreDevice(r.Context(), m.svc.pool, p.UserID, p.SessionID, in.Token, in.Platform); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) removeStoreDevice(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	if err := RemoveStoreDevice(r.Context(), m.svc.pool, p.UserID, chi.URLParam(r, "token")); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func adminID(r *http.Request) string { return identity.FromContext(r.Context()).UserID }

func (m *Module) overview(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Overview, error) { return m.svc.Overview(r.Context()) })
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Campaign], error) {
		items, err := m.svc.List(r.Context(), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[Campaign]{Items: items}, err
	})
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CampaignInput) (Campaign, error) {
		return m.svc.Create(r.Context(), adminID(r), in)
	})
}

func (m *Module) preview(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CampaignInput) (Reach, error) {
		return m.svc.Preview(r.Context(), in)
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Campaign, error) { return m.svc.Get(r.Context(), id) })
}

func (m *Module) recipients(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[Recipient], error) {
		q := r.URL.Query()
		items, err := m.svc.Recipients(r.Context(), id, q.Get("status"), q.Get("q"), httpx.PageFrom(r))
		return httpx.List[Recipient]{Items: items}, err
	})
}

func (m *Module) cancel(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Campaign, error) { return m.svc.Cancel(r.Context(), id) })
}

func (m *Module) customer(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CustomerInfo, error) {
		return m.svc.FindCustomer(r.Context(), r.URL.Query().Get("phone"), adminID(r))
	})
}

func (m *Module) test(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in TestInput) (TestResult, error) {
		return m.svc.Test(r.Context(), adminID(r), in)
	})
}

func (m *Module) blocks(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Block], error) {
		items, err := m.svc.Blocks(r.Context())
		return httpx.List[Block]{Items: items}, err
	})
}

func (m *Module) cities(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[string], error) {
		rows, err := m.svc.pool.Query(r.Context(), `
			SELECT city FROM (
				SELECT btrim(city) AS city FROM stores WHERE status = 'active'
				UNION ALL SELECT btrim(city) FROM customers WHERE deleted_at IS NULL) x
			WHERE city <> '' GROUP BY city ORDER BY count(*) DESC, city LIMIT 100`)
		if err != nil {
			return httpx.List[string]{}, err
		}
		defer rows.Close()
		out := []string{}
		for rows.Next() {
			var c string
			if err := rows.Scan(&c); err != nil {
				return httpx.List[string]{}, err
			}
			out = append(out, c)
		}
		return httpx.List[string]{Items: out}, rows.Err()
	})
}
