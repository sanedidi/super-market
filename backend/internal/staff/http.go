package staff

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/reports"
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
	r.Route("/store/staff", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/glance", m.glance)
		r.Get("/tasks", m.tasks)
		r.Get("/price-tags", m.priceTags)
		r.Post("/price-tags", m.markTags)
		r.Post("/write-off", m.writeOff)
		r.Post("/cost", m.setCost)
		r.Get("/day", m.day)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) glance(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Glance, error) {
		return m.svc.Glance(r.Context(), pr(r), GlanceInput{StoreID: q.Get("store_id"), Code: q.Get("code"), ProductID: q.Get("product_id")})
	})
}

func (m *Module) tasks(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Tasks, error) {
		return m.svc.Tasks(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) priceTags(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PriceTag], error) {
		items, err := m.svc.PriceTags(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[PriceTag]{Items: items}, err
	})
}

func (m *Module) markTags(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in MarkTagsInput) (map[string]int, error) {
		return m.svc.MarkTags(r.Context(), pr(r), in)
	})
}

func (m *Module) writeOff(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in WriteOffInput) (WriteOffResult, error) {
		return m.svc.WriteOff(r.Context(), pr(r), in)
	})
}

func (m *Module) day(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Day, error) {
		return m.svc.Day(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) setCost(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in reports.CostInput) (reports.CostResult, error) {
		return m.svc.SetCost(r.Context(), pr(r), in)
	})
}
