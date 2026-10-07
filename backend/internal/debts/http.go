package debts

import (
	"log/slog"
	"net/http"
	"strconv"

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
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/debtors", m.list)
		r.Get("/store/debtors/summary", m.summary)
		r.Get("/store/debtors/{id}", m.card)
		r.Patch("/store/debtors/{id}", m.update)
		r.Post("/store/debtors/{id}/remind", m.remind)
		r.Post("/store/debt-payments", m.pay)
		r.Post("/store/debt-writeoffs", m.writeoff)
		r.Get("/store/debt-disputes", m.disputes)
		r.Post("/store/debt-disputes/{id}/resolve", m.resolve)
		r.Get("/store/debt-settings", m.getSettings)
		r.Put("/store/debt-settings", m.saveSettings)
		r.Put("/store/debt-settings/stores/{id}", m.setStore)
	})
	r.Route("/client/debts", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppClient))
		r.Get("/", m.clientDebts)
		r.Get("/{store_id}", m.clientStore)
		r.Post("/entries/{id}/dispute", m.clientDispute)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Balance], error) {
		q := r.URL.Query()
		items, err := m.svc.List(r.Context(), pr(r), ListFilter{StoreID: q.Get("store_id"), Q: q.Get("q"), Status: q.Get("status"), Page: httpx.PageFrom(r)})
		return httpx.List[Balance]{Items: items}, err
	})
}

func (m *Module) summary(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Summary, error) {
		return m.svc.Summary(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) card(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (DebtorCard, error) {
		return m.svc.Card(r.Context(), pr(r), id, r.URL.Query().Get("store_id"))
	})
}

func (m *Module) update(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in DebtorInput) (DebtorCard, error) {
		return m.svc.Update(r.Context(), pr(r), id, in)
	})
}

func (m *Module) remind(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "id", func(id string, in RemindInput) (Reminded, error) {
		return m.svc.Remind(r.Context(), pr(r), id, in)
	})
}

func (m *Module) pay(w http.ResponseWriter, r *http.Request) {
	var in PaymentInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	pay, _, err := m.svc.Pay(r.Context(), pr(r), in)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, pay)
}

func (m *Module) writeoff(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in WriteoffInput) (Writeoff, error) {
		return m.svc.Writeoff(r.Context(), pr(r), in)
	})
}

func (m *Module) disputes(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Dispute], error) {
		items, err := m.svc.Disputes(r.Context(), pr(r), r.URL.Query().Get("store_id"), r.URL.Query().Get("status"))
		return httpx.List[Dispute]{Items: items}, err
	})
}

func (m *Module) resolve(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ResolveInput) (Dispute, error) {
		return m.svc.Resolve(r.Context(), pr(r), id, in)
	})
}

func (m *Module) getSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.GetSettings(r.Context(), pr(r)) })
}

func (m *Module) saveSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SettingsInput) (Settings, error) {
		return m.svc.SaveSettings(r.Context(), pr(r), in)
	})
}

func (m *Module) setStore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in struct {
		DebtEnabled *bool `json:"debt_enabled"`
	}) (Settings, error) {
		if in.DebtEnabled == nil {
			return Settings{}, apperr.Validation("debt_enabled: true или false").Uz("debt_enabled: true yoki false")
		}
		return m.svc.SetStoreEnabled(r.Context(), pr(r), id, *in.DebtEnabled)
	})
}

func (m *Module) clientDebts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ClientDebts, error) { return m.svc.ClientDebts(r.Context(), pr(r)) })
}

func (m *Module) clientStore(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ClientStoreDebt, error) {
		return m.svc.ClientStoreDebt(r.Context(), pr(r), chi.URLParam(r, "store_id"))
	})
}

func (m *Module) clientDispute(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		httpx.Fail(w, r, m.log, apperr.NotFound("запись не найдена").Uz("yozuv topilmadi"))
		return
	}
	var in DisputeInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	out, err := m.svc.ClientDispute(r.Context(), pr(r), id, in)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, out)
}
