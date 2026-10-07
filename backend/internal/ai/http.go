package ai

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
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
		r.Get("/admin/ai/usage", m.usage)
		r.Put("/admin/ai/prices", m.savePrices)
	})
	// Автоперевод двуязычных полей: панель и приложение магазина, супер-админ.
	r.With(m.auth.Require(identity.AppStore, identity.AppAdmin)).Post("/translate", m.translate)
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

func (m *Module) usage(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (UsageReport, error) {
		q := r.URL.Query()
		f := UsageFilter{Group: q.Get("group"), NetworkID: q.Get("network_id")}
		for _, p := range []struct {
			name string
			dst  *time.Time
		}{{"from", &f.From}, {"to", &f.To}} {
			if v := q.Get(p.name); v != "" {
				t, err := time.ParseInLocation("2006-01-02", v, tashkent)
				if err != nil {
					return UsageReport{}, apperr.Validation(p.name + ": ожидается дата YYYY-MM-DD").Uz(p.name + ": sana YYYY-MM-DD koʻrinishida boʻlsin")
				}
				*p.dst = t
			}
		}
		if f.NetworkID != "" {
			if !httpx.IsUUID(f.NetworkID) {
				return UsageReport{}, apperr.Validation("network_id: неверный id").Uz("network_id: id notoʻgʻri")
			}
		}
		return m.svc.Usage(r.Context(), f)
	})
}

func (m *Module) savePrices(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Prices) (Prices, error) {
		return m.svc.SavePrices(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}
