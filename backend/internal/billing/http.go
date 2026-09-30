package billing

import (
	"context"
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
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/balance", m.balance)
		r.Get("/store/balance/entries", m.balanceEntries)
		r.Get("/store/payouts", m.storePayouts)
		r.Post("/store/payouts", m.requestPayout)
		r.Get("/store/billing", m.storeBilling)
		r.Get("/store/billing/invoices", m.storeInvoices)
		r.Post("/store/billing/invoices/{id}/pay", m.payInvoice)
	})

	r.Route("/admin/billing", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/settings", m.getSettings)
		r.Put("/settings", m.saveSettings)
		r.Get("/tariffs", m.listTariffs)
		r.Post("/tariffs", m.createTariff)
		r.Patch("/tariffs/{id}", m.updateTariff)
		r.Get("/networks", m.listNetworks)
		r.Get("/networks/{id}", m.getNetwork)
		r.Patch("/networks/{id}", m.updateNetwork)
		r.Get("/invoices", m.adminInvoices)
		r.Post("/invoices/generate", m.generate)
		r.Post("/invoices/{id}/paid", m.invoiceStatus(m.svc.MarkInvoicePaid))
		r.Post("/invoices/{id}/cancel", m.invoiceStatus(m.svc.CancelInvoice))
	})
	r.Route("/admin/payouts", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/", m.adminPayouts)
		r.Post("/{id}/paid", m.processPayout("paid"))
		r.Post("/{id}/reject", m.processPayout("rejected"))
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

type noteBody struct {
	Note string `json:"note"`
}

// ------------------------------------------------------------- магазин

func (m *Module) balance(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Balance, error) {
		return m.svc.GetBalance(r.Context(), pr(r))
	})
}

func (m *Module) balanceEntries(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[BalanceEntry], error) {
		from, to, err := finance.ParsePeriod(r)
		if err != nil {
			return httpx.List[BalanceEntry]{}, err
		}
		items, err := m.svc.BalanceEntries(r.Context(), pr(r), from, to, httpx.PageFrom(r))
		return httpx.List[BalanceEntry]{Items: items}, err
	})
}

func (m *Module) storePayouts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Payout], error) {
		items, err := m.svc.StorePayouts(r.Context(), pr(r), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[Payout]{Items: items}, err
	})
}

func (m *Module) requestPayout(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in PayoutInput) (Payout, error) {
		return m.svc.RequestPayout(r.Context(), pr(r), in)
	})
}

func (m *Module) storeBilling(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (NetworkBilling, error) {
		p := pr(r)
		if err := p.Require(identity.PermPayoutsManage); err != nil {
			return NetworkBilling{}, err
		}
		return m.svc.NetworkBilling(r.Context(), p.NetworkID)
	})
}

func (m *Module) storeInvoices(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Invoice], error) {
		p := pr(r)
		if err := p.Require(identity.PermPayoutsManage); err != nil {
			return httpx.List[Invoice]{}, err
		}
		items, err := m.svc.ListInvoices(r.Context(), p.NetworkID, r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[Invoice]{Items: items}, err
	})
}

func (m *Module) payInvoice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Invoice, error) {
		return m.svc.PayInvoice(r.Context(), pr(r), id)
	})
}

// --------------------------------------------------------- супер-админ

func (m *Module) getSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.GetSettings(r.Context()) })
}

func (m *Module) saveSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SettingsInput) (Settings, error) {
		return m.svc.SaveSettings(r.Context(), in)
	})
}

func (m *Module) listTariffs(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Tariff], error) {
		items, err := m.svc.ListTariffs(r.Context(), httpx.PageFrom(r))
		return httpx.List[Tariff]{Items: items}, err
	})
}

func (m *Module) createTariff(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in TariffInput) (Tariff, error) {
		return m.svc.SaveTariff(r.Context(), "", in)
	})
}

func (m *Module) updateTariff(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in TariffInput) (Tariff, error) {
		return m.svc.SaveTariff(r.Context(), id, in)
	})
}

func (m *Module) listNetworks(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[NetworkBilling], error) {
		items, err := m.svc.ListNetworks(r.Context(), r.URL.Query().Get("overdue") == "true", httpx.PageFrom(r))
		return httpx.List[NetworkBilling]{Items: items}, err
	})
}

func (m *Module) getNetwork(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (NetworkBilling, error) {
		return m.svc.NetworkBilling(r.Context(), id)
	})
}

func (m *Module) updateNetwork(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in NetworkBillingInput) (NetworkBilling, error) {
		return m.svc.SaveNetworkBilling(r.Context(), id, in)
	})
}

func (m *Module) adminInvoices(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Invoice], error) {
		items, err := m.svc.ListInvoices(r.Context(), q.Get("network_id"), q.Get("status"), httpx.PageFrom(r))
		return httpx.List[Invoice]{Items: items}, err
	})
}

func (m *Module) generate(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (map[string]int, error) {
		n, err := m.svc.GenerateInvoices(r.Context(), m.svc.now())
		return map[string]int{"created": n}, err
	})
}

func (m *Module) invoiceStatus(fn func(context.Context, string, string) (Invoice, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in noteBody) (Invoice, error) {
			return fn(r.Context(), id, in.Note)
		})
	}
}

func (m *Module) adminPayouts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Payout], error) {
		items, err := m.svc.AdminPayouts(r.Context(), q.Get("network_id"), q.Get("status"), httpx.PageFrom(r))
		return httpx.List[Payout]{Items: items}, err
	})
}

func (m *Module) processPayout(status string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in noteBody) (Payout, error) {
			return m.svc.ProcessPayout(r.Context(), id, status, in.Note)
		})
	}
}
