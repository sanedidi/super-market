package pos

import (
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/sales"
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
	// Касса: активация кодом, дальше — токен устройства.
	r.Post("/pos/activate", m.activate)
	r.Group(func(r chi.Router) {
		r.Use(m.deviceAuth)
		r.Get("/pos/catalog", m.catalog)
		r.Post("/pos/login", m.login)
		r.Get("/pos/shifts/current", m.currentShift)
		r.Post("/pos/shifts", m.openShift)
		r.Get("/pos/shifts/{id}", m.shiftReport)
		r.Post("/pos/shifts/{id}/cash-moves", m.cashMove)
		r.Post("/pos/shifts/{id}/close", m.closeShift)
		r.Post("/pos/sales", m.createSale)
		r.Get("/pos/sales", m.findSales)
		r.Get("/pos/sales/{id}", m.getSale)
		r.Post("/pos/returns", m.createReturn)
		r.Post("/pos/returns/{id}/fiscal", m.returnFiscal)
	})
	// Панель магазина: кассы, ПИНы, смены, налоговые поля, коды.
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.With(m.auth.Allow(identity.PermStoresManage)).Get("/store/pos/devices", m.listDevices)
		r.Post("/store/pos/devices", m.createDevice)
		r.Post("/store/pos/devices/{id}/code", m.newCode)
		r.Post("/store/pos/devices/{id}/revoke", m.revoke)
		r.Get("/store/pos/pins", m.listPins)
		r.Put("/store/pos/pins/{id}", m.setPIN)
		r.Delete("/store/pos/pins/{id}", m.clearPIN)
		r.Get("/store/pos/shifts", m.listShifts)
		r.Get("/store/pos/shifts/{id}", m.getShift)
		r.Get("/store/pos/shifts/{id}/events", m.shiftEvents)
		r.Get("/store/pos/cashiers", m.cashiers)
		r.Put("/store/pos/products/{id}/tax", m.setTax)
		r.Put("/store/pos/products/{id}/plu", m.setPLU)
		r.Put("/store/pos/payment-methods/{id}/kind", m.setKind)
		r.Get("/store/pos/settings", m.getSettings)
		r.Put("/store/pos/settings", m.saveSettings)
	})
	// Супер-админ: ИКПУ общих товаров платформы.
	r.With(m.auth.Require(identity.AppAdmin)).Put("/admin/pos/products/{id}/tax", m.setTax)
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

// ------------------------------------------------------------ касса

func (m *Module) activate(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in ActivateInput) (Activation, error) {
		return m.svc.Activate(r.Context(), in)
	})
}

func (m *Module) catalog(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Catalog, error) {
		var since *time.Time
		if v := r.URL.Query().Get("since"); v != "" {
			// «+» в часовом поясе мог превратиться в пробел в строке запроса.
			t, err := time.Parse(time.RFC3339Nano, strings.ReplaceAll(v, " ", "+"))
			if err != nil {
				return Catalog{}, apperr.Validation("since: версия из прошлого ответа (RFC 3339)")
			}
			since = &t
		}
		return m.svc.Catalog(r.Context(), pr(r), since)
	})
}

func (m *Module) login(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in LoginInput) (Cashier, error) {
		return m.svc.Login(r.Context(), pr(r), in)
	})
}

func (m *Module) currentShift(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (map[string]*Shift, error) {
		sh, err := m.svc.CurrentShift(r.Context(), pr(r))
		return map[string]*Shift{"shift": sh}, err
	})
}

// openShift: 201 — новая смена, 200 — повтор с тем же client_uid.
func (m *Module) openShift(w http.ResponseWriter, r *http.Request) {
	var in OpenInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	sh, created, err := m.svc.OpenShift(r.Context(), pr(r), in)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, sh)
}

func (m *Module) shiftReport(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Shift, error) {
		if err := requireCashier(pr(r)); err != nil {
			return Shift{}, err
		}
		return m.svc.ShiftWithReport(r.Context(), pr(r), id)
	})
}

func (m *Module) cashMove(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CashMoveInput) (CashMove, error) {
		return m.svc.CashMove(r.Context(), pr(r), id, in)
	})
}

func (m *Module) closeShift(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CloseInput) (Shift, error) {
		return m.svc.CloseShift(r.Context(), pr(r), id, in)
	})
}

// createSale: 201 — новая продажа, 200 — повтор (касса досылает после офлайна).
func (m *Module) createSale(w http.ResponseWriter, r *http.Request) {
	var in sales.SaleInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	if err := requireCashier(pr(r)); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	sale, created, err := m.svc.sales.CreateSale(r.Context(), pr(r), in)
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

// findSales — поиск чека для возврата: номер с чека или его QR.
func (m *Module) findSales(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[sales.Sale], error) {
		if err := requireCashier(pr(r)); err != nil {
			return httpx.List[sales.Sale]{}, err
		}
		q := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(r.URL.Query().Get("q")), "№"))
		if q == "" {
			return httpx.List[sales.Sale]{Items: []sales.Sale{}}, nil
		}
		items, err := m.svc.sales.ListSales(r.Context(), pr(r), sales.SaleFilter{Query: q, Page: httpx.Page{Limit: 20}})
		return httpx.List[sales.Sale]{Items: items}, err
	})
}

func (m *Module) getSale(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (sales.Sale, error) {
		if err := requireCashier(pr(r)); err != nil {
			return sales.Sale{}, err
		}
		return m.svc.sales.GetSale(r.Context(), pr(r), id)
	})
}

func (m *Module) createReturn(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in sales.ReturnInput) (sales.CustomerReturn, error) {
		if pr(r).EmployeeID == "" {
			return sales.CustomerReturn{}, requireCashier(pr(r))
		}
		return m.svc.sales.CreateReturn(r.Context(), pr(r), in)
	})
}

// returnFiscal — касса пробила чек возврата на фискальном модуле.
func (m *Module) returnFiscal(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in sales.FiscalInput) (map[string]bool, error) {
		if pr(r).EmployeeID == "" {
			return nil, requireCashier(pr(r))
		}
		return map[string]bool{"registered": true}, m.svc.sales.RegisterFiscal(r.Context(), pr(r), "customer_returns", id, in)
	})
}

// ------------------------------------------------------------ панель

func (m *Module) listDevices(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Device], error) {
		items, err := m.svc.ListDevices(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[Device]{Items: items}, err
	})
}

func (m *Module) createDevice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in DeviceInput) (Device, error) {
		return m.svc.CreateDevice(r.Context(), pr(r), in)
	})
}

func (m *Module) newCode(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Device, error) {
		return m.svc.NewCode(r.Context(), pr(r), id)
	})
}

func (m *Module) revoke(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Device, error) {
		return m.svc.RevokeDevice(r.Context(), pr(r), id)
	})
}

func (m *Module) setPIN(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PinInput) (map[string]bool, error) {
		return m.svc.SetPIN(r.Context(), pr(r), id, in)
	})
}

func (m *Module) listPins(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PinRow], error) {
		items, err := m.svc.ListPins(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[PinRow]{Items: items}, err
	})
}

func (m *Module) clearPIN(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (map[string]bool, error) {
		return m.svc.ClearPIN(r.Context(), pr(r), id)
	})
}

func (m *Module) listShifts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Shift], error) {
		items, err := m.svc.ListShifts(r.Context(), pr(r), r.URL.Query().Get("store_id"), httpx.PageFrom(r))
		return httpx.List[Shift]{Items: items}, err
	})
}

func (m *Module) getShift(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Shift, error) {
		return m.svc.GetShift(r.Context(), pr(r), id)
	})
}

func (m *Module) setTax(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in TaxInput) (ProductTax, error) {
		return m.svc.SetProductTax(r.Context(), pr(r), id, in)
	})
}

func (m *Module) setPLU(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PLUInput) (map[string]any, error) {
		return m.svc.SetPLU(r.Context(), pr(r), id, in)
	})
}

func (m *Module) setKind(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in KindInput) (PaymentMethod, error) {
		return m.svc.SetPaymentKind(r.Context(), pr(r), id, in)
	})
}

func (m *Module) getSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (NetworkSettings, error) {
		return m.svc.GetSettings(r.Context(), pr(r))
	})
}

func (m *Module) saveSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in NetworkSettings) (NetworkSettings, error) {
		return m.svc.SaveSettings(r.Context(), pr(r), in)
	})
}

func (m *Module) cashiers(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CashierControl, error) {
		from, to, err := finance.ParsePeriod(r)
		if err != nil {
			return CashierControl{}, err
		}
		return m.svc.Cashiers(r.Context(), pr(r), r.URL.Query().Get("store_id"), from, to)
	})
}

func (m *Module) shiftEvents(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[ShiftEvent], error) {
		items, err := m.svc.ShiftEvents(r.Context(), pr(r), id)
		return httpx.List[ShiftEvent]{Items: items}, err
	})
}
