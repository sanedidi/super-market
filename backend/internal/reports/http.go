package reports

import (
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
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
	r.Route("/store/reports", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		pro := m.auth.Feature(plans.FeatureReportsPro)
		r.With(pro).Get("/cash-flow", m.cashFlow)
		r.With(pro).Get("/profit-loss", m.profitLoss)
		r.With(pro).Get("/no-cost", m.noCost)
		r.With(pro).Post("/no-cost", m.setCost)
		r.With(m.auth.Feature(plans.FeatureABCXYZ)).Get("/abc-xyz", m.abcXyz)
		r.Get("/sales-series", m.salesSeries)
		r.Get("/sales-breakdown", m.salesBreakdown)
	})
}

func filter(r *http.Request) (Filter, error) {
	from, to, err := finance.ParsePeriod(r)
	return Filter{From: from, To: to, StoreID: r.URL.Query().Get("store_id")}, err
}

func (m *Module) cashFlow(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CashFlow, error) {
		f, err := filter(r)
		if err != nil {
			return CashFlow{}, err
		}
		return m.svc.CashFlow(r.Context(), identity.FromContext(r.Context()), f, r.URL.Query().Get("cashbox_id"))
	})
}

func (m *Module) profitLoss(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ProfitLoss, error) {
		f, err := filter(r)
		if err != nil {
			return ProfitLoss{}, err
		}
		return m.svc.ProfitLoss(r.Context(), identity.FromContext(r.Context()), f)
	})
}

func (m *Module) noCost(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[NoCostItem], error) {
		f, err := filter(r)
		if err != nil {
			return httpx.List[NoCostItem]{}, err
		}
		items, err := m.svc.NoCost(r.Context(), identity.FromContext(r.Context()), f)
		return httpx.List[NoCostItem]{Items: items}, err
	})
}

func (m *Module) setCost(w http.ResponseWriter, r *http.Request) {
	var in CostInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CostResult, error) {
		return m.svc.SetCost(r.Context(), identity.FromContext(r.Context()), in)
	})
}

func (m *Module) abcXyz(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (AbcXyz, error) {
		f, err := filter(r)
		if err != nil {
			return AbcXyz{}, err
		}
		q := r.URL.Query()
		return m.svc.AbcXyz(r.Context(), identity.FromContext(r.Context()), AbcFilter{Filter: f, CategoryID: q.Get("category_id"), By: q.Get("by"), Compact: q.Get("compact") == "1"})
	})
}

func (m *Module) salesSeries(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (SalesSeries, error) {
		f, err := filter(r)
		if err != nil {
			return SalesSeries{}, err
		}
		q := r.URL.Query()
		return m.svc.SalesSeries(r.Context(), identity.FromContext(r.Context()), SeriesFilter{Filter: f, Bucket: q.Get("bucket"), Compare: q.Get("compare")})
	})
}

func (m *Module) salesBreakdown(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (SalesBreakdown, error) {
		f, err := filter(r)
		if err != nil {
			return SalesBreakdown{}, err
		}
		q := r.URL.Query()
		limit := 0
		if v := q.Get("limit"); v != "" {
			if limit, err = strconv.Atoi(v); err != nil || limit < 1 {
				return SalesBreakdown{}, apperr.Validation("limit: от 1 до 50").Uz("limit: 1 dan 50 gacha")
			}
		}
		return m.svc.SalesBreakdown(r.Context(), identity.FromContext(r.Context()), BreakdownFilter{
			Filter: f, By: q.Get("by"), ParentID: q.Get("parent_id"), Compare: q.Get("compare"), Limit: limit,
		})
	})
}
