package sales

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
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
	r.Route("/store/sales", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/", m.list)
		r.Post("/", m.create)
		r.Get("/fiscal-control", m.fiscalControl)
		r.Get("/returns", m.listReturns)
		r.Post("/returns", m.createReturn)
		r.Get("/returns/{id}", m.getReturn)
		r.Post("/returns/{id}/fiscal", m.fiscal("customer_returns"))
		r.Get("/{id}", m.get)
		r.Post("/{id}/fiscal", m.fiscal("sales"))
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func filterFrom(r *http.Request) (SaleFilter, error) {
	from, to, err := finance.ParsePeriod(r)
	return SaleFilter{
		StoreID: r.URL.Query().Get("store_id"), SaleID: r.URL.Query().Get("sale_id"), FiscalPending: r.URL.Query().Get("fiscal") == "pending",
		From: from, To: to, Page: httpx.PageFrom(r),
	}, err
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Sale], error) {
		f, err := filterFrom(r)
		if err != nil {
			return httpx.List[Sale]{}, err
		}
		items, err := m.svc.ListSales(r.Context(), pr(r), f)
		return httpx.List[Sale]{Items: items}, err
	})
}

// create: 201 — новая продажа, 200 — повтор с тем же client_uid.
func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	var in SaleInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	sale, created, err := m.svc.CreateSale(r.Context(), pr(r), in)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, sale)
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Sale, error) {
		return m.svc.GetSale(r.Context(), pr(r), id)
	})
}

func (m *Module) fiscal(table string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in FiscalInput) (map[string]bool, error) {
			return map[string]bool{"registered": true}, m.svc.RegisterFiscal(r.Context(), pr(r), table, id, in)
		})
	}
}

func (m *Module) fiscalControl(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (FiscalSummary, error) {
		return m.svc.FiscalControl(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) listReturns(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CustomerReturn], error) {
		f, err := filterFrom(r)
		if err != nil {
			return httpx.List[CustomerReturn]{}, err
		}
		items, err := m.svc.ListReturns(r.Context(), pr(r), f)
		return httpx.List[CustomerReturn]{Items: items}, err
	})
}

func (m *Module) createReturn(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in ReturnInput) (CustomerReturn, error) {
		return m.svc.CreateReturn(r.Context(), pr(r), in)
	})
}

func (m *Module) getReturn(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CustomerReturn, error) {
		return m.svc.GetReturn(r.Context(), pr(r), id)
	})
}
