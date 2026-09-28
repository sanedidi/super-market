package reports

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
	r.Route("/store/reports", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/cash-flow", m.cashFlow)
		r.Get("/profit-loss", m.profitLoss)
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
