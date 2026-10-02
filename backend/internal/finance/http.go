package finance

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/money"
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
	r.Route("/store/finance", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		// Чтение разделов: способы оплаты нужны кассе, остальное — по правам.
		fin := m.auth.Allow(identity.PermFinanceManage)
		cps := m.auth.Allow(identity.PermCounterpartiesManage, identity.PermInventoryManage, identity.PermFinanceManage)

		r.With(m.auth.Allow(identity.PermFinanceManage, identity.PermInventoryManage)).Get("/rates", m.listRates)
		r.Post("/rates", m.setRate)

		r.With(cps).Get("/counterparty-types", m.listCounterpartyTypes)
		r.Post("/counterparty-types", m.createCounterpartyType)
		r.Patch("/counterparty-types/{id}", m.updateCounterpartyType)

		r.With(cps).Get("/counterparties", m.listCounterparties)
		r.Post("/counterparties", m.createCounterparty)
		r.With(cps).Get("/counterparties/{id}", m.getCounterparty)
		r.Patch("/counterparties/{id}", m.updateCounterparty)
		r.With(cps).Get("/counterparties/{id}/entries", m.counterpartyEntries)
		r.With(cps).Get("/counterparties/{id}/statement", m.counterpartyStatement)
		r.With(cps).Get("/debts", m.debts)

		r.With(fin).Get("/reasons", m.listReasons)
		r.Post("/reasons", m.createReason)
		r.Patch("/reasons/{id}", m.updateReason)

		r.With(fin).Get("/cashboxes", m.listCashboxes)
		r.Post("/cashboxes", m.createCashbox)
		r.Patch("/cashboxes/{id}", m.updateCashbox)
		r.With(fin).Get("/cashboxes/{id}/entries", m.cashboxEntries)

		r.Get("/payment-methods", m.listPaymentMethods)
		r.Post("/payment-methods", m.createPaymentMethod)
		r.Patch("/payment-methods/{id}", m.updatePaymentMethod)

		r.With(fin).Get("/operations", m.listOperations)
		r.Post("/operations", m.createOperation)

		r.With(fin).Get("/transfers", m.listTransfers("transfer"))
		r.Post("/transfers", m.createTransfer("transfer"))
		r.With(fin).Get("/handovers", m.listTransfers("handover"))
		r.Post("/handovers", m.createTransfer("handover"))
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func list[T any](items []T, err error) (httpx.List[T], error) {
	return httpx.List[T]{Items: items}, err
}

func (m *Module) listRates(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Rate], error) {
		return list(m.svc.ListRates(r.Context(), pr(r), httpx.PageFrom(r)))
	})
}

func (m *Module) setRate(w http.ResponseWriter, r *http.Request) {
	type body struct {
		Rate money.Rate `json:"rate"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in body) (Rate, error) {
		return m.svc.SetRate(r.Context(), pr(r), in.Rate)
	})
}

func (m *Module) listCounterpartyTypes(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CounterpartyType], error) {
		items, err := m.svc.ListCounterpartyTypes(r.Context(), pr(r))
		return list(httpx.PageSlice(r, items), err)
	})
}

func (m *Module) createCounterpartyType(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in NamedInput) (CounterpartyType, error) {
		return m.svc.SaveCounterpartyType(r.Context(), pr(r), "", in)
	})
}

func (m *Module) updateCounterpartyType(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in NamedInput) (CounterpartyType, error) {
		return m.svc.SaveCounterpartyType(r.Context(), pr(r), id, in)
	})
}

func (m *Module) listCounterparties(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Counterparty], error) {
		return list(m.svc.ListCounterparties(r.Context(), pr(r), r.URL.Query().Get("q"), httpx.PageFrom(r)))
	})
}

func (m *Module) createCounterparty(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CounterpartyInput) (Counterparty, error) {
		return m.svc.SaveCounterparty(r.Context(), pr(r), "", in)
	})
}

func (m *Module) getCounterparty(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Counterparty, error) {
		return m.svc.GetCounterparty(r.Context(), pr(r), id)
	})
}

func (m *Module) updateCounterparty(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CounterpartyInput) (Counterparty, error) {
		return m.svc.SaveCounterparty(r.Context(), pr(r), id, in)
	})
}

func (m *Module) counterpartyEntries(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[CashEntry], error) {
		return list(m.svc.CounterpartyEntries(r.Context(), pr(r), id, httpx.PageFrom(r)))
	})
}

func (m *Module) listReasons(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Reason], error) {
		items, err := m.svc.ListReasons(r.Context(), pr(r))
		return list(httpx.PageSlice(r, items), err)
	})
}

func (m *Module) createReason(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in ReasonInput) (Reason, error) {
		return m.svc.SaveReason(r.Context(), pr(r), "", in)
	})
}

func (m *Module) updateReason(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ReasonInput) (Reason, error) {
		return m.svc.SaveReason(r.Context(), pr(r), id, in)
	})
}

func (m *Module) listCashboxes(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Cashbox], error) {
		items, err := m.svc.ListCashboxes(r.Context(), pr(r))
		return list(httpx.PageSlice(r, items), err)
	})
}

func (m *Module) createCashbox(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CashboxInput) (Cashbox, error) {
		return m.svc.SaveCashbox(r.Context(), pr(r), "", in)
	})
}

func (m *Module) updateCashbox(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CashboxInput) (Cashbox, error) {
		return m.svc.SaveCashbox(r.Context(), pr(r), id, in)
	})
}

func (m *Module) cashboxEntries(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[CashEntry], error) {
		return list(m.svc.CashboxEntries(r.Context(), pr(r), id, httpx.PageFrom(r)))
	})
}

func (m *Module) listPaymentMethods(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PaymentMethod], error) {
		items, err := m.svc.ListPaymentMethods(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return list(httpx.PageSlice(r, items), err)
	})
}

func (m *Module) createPaymentMethod(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in PaymentMethodInput) (PaymentMethod, error) {
		return m.svc.SavePaymentMethod(r.Context(), pr(r), "", in)
	})
}

func (m *Module) updatePaymentMethod(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PaymentMethodInput) (PaymentMethod, error) {
		return m.svc.SavePaymentMethod(r.Context(), pr(r), id, in)
	})
}

// ParsePeriod читает ?from=&to= (RFC 3339 или YYYY-MM-DD, to не включается).
func ParsePeriod(r *http.Request) (from, to *time.Time, err error) {
	parse := func(name string) (*time.Time, error) {
		v := r.URL.Query().Get(name)
		if v == "" {
			return nil, nil
		}
		for _, layout := range []string{time.RFC3339, "2006-01-02"} {
			if t, err := time.ParseInLocation(layout, v, tashkent); err == nil {
				return &t, nil
			}
		}
		return nil, apperr.Validation(name + ": ожидается дата YYYY-MM-DD")
	}
	if from, err = parse("from"); err != nil {
		return
	}
	to, err = parse("to")
	return
}

// Отчётные даты считаем по времени Ташкента (UTC+5, без перехода на летнее время).
var tashkent = time.FixedZone("Asia/Tashkent", 5*60*60)

func (m *Module) listOperations(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CashOperation], error) {
		from, to, err := ParsePeriod(r)
		if err != nil {
			return httpx.List[CashOperation]{}, err
		}
		return list(m.svc.ListCashOperations(r.Context(), pr(r), CashOpFilter{
			CashboxID: r.URL.Query().Get("cashbox_id"), From: from, To: to, Page: httpx.PageFrom(r),
		}))
	})
}

func (m *Module) createOperation(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CashOperationInput) (CashOperation, error) {
		return m.svc.CreateCashOperation(r.Context(), pr(r), in)
	})
}

func (m *Module) listTransfers(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CashTransfer], error) {
			return list(m.svc.ListTransfers(r.Context(), pr(r), kind, httpx.PageFrom(r)))
		})
	}
}

func (m *Module) createTransfer(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in TransferInput) (CashTransfer, error) {
			return m.svc.CreateTransfer(r.Context(), pr(r), kind, in)
		})
	}
}

func (m *Module) debts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Debts, error) {
		return m.svc.SupplierDebts(r.Context(), pr(r), r.URL.Query().Get("side"), r.URL.Query().Get("q"))
	})
}

func (m *Module) counterpartyStatement(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Statement, error) {
		from, to, err := ParsePeriod(r)
		if err != nil {
			return Statement{}, err
		}
		return m.svc.CounterpartyStatement(r.Context(), pr(r), id, from, to)
	})
}
