package supply

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
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
	// Дистрибьютор («SM Дистрибьютор»).
	r.Route("/store/supply", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/summary", m.summary)
		r.Get("/settings", m.getSettings)
		r.Patch("/settings", m.updateSettings)
		r.Get("/stores", m.stores)
		r.Get("/stores/{id}", m.storeDetail)
		r.Post("/stores/{id}/code", m.code)
		r.Post("/stores/{id}/request", m.requestStore)
		r.Post("/stores/{id}/disconnect", m.disconnectStore)
		r.Post("/stores/{id}/shipment", m.shipment)
		r.Get("/links", m.distLinks)
		r.Post("/links/{id}/accept", m.distAnswer(true))
		r.Post("/links/{id}/reject", m.distAnswer(false))
		r.Get("/orders", m.orders)
		r.Get("/orders/{id}", m.order)
		r.Patch("/orders/{id}", m.shipQty)
		r.Post("/orders/{id}/accept", m.orderAction(m.svc.AcceptOrder))
		r.Post("/orders/{id}/assemble", m.orderAction(m.svc.AssembleOrder))
		r.Post("/orders/{id}/deliver", m.orderAction(m.svc.DeliverOrder))
		r.Post("/orders/{id}/reject", m.reject)
	})
	// Магазин («SM Магазин», панель магазина): поставщики и заказы им.
	r.Route("/store/suppliers", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/", m.suppliers)
		r.Get("/search", m.search)
		r.Get("/reorder", m.reorder)
		r.Post("/connect", m.connect)
		r.Post("/links/{id}/accept", m.storeAnswer(true))
		r.Post("/links/{id}/reject", m.storeAnswer(false))
		r.Get("/{id}", m.supplier)
		r.Get("/{id}/catalog", m.catalog)
		r.Post("/{id}/request", m.requestDistributor)
		r.Post("/{id}/disconnect", m.disconnectDistributor)
	})
	r.Route("/store/supplier-orders", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/", m.orders)
		r.Post("/", m.createOrder)
		r.Get("/{id}", m.order)
		r.Post("/{id}/cancel", m.orderAction(m.svc.CancelOrder))
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

// ---------------------------------------------------------- дистрибьютор

func (m *Module) summary(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Summary, error) { return m.svc.Summary(r.Context(), pr(r)) })
}

func (m *Module) getSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.GetSettings(r.Context(), pr(r)) })
}

func (m *Module) updateSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SettingsInput) (Settings, error) {
		return m.svc.UpdateSettings(r.Context(), pr(r), in)
	})
}

func (m *Module) stores(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[StoreCard], error) {
		items, err := m.svc.Stores(r.Context(), pr(r), StoresFilter{Status: q.Get("status"), Query: q.Get("q"), Page: httpx.PageFrom(r)})
		return httpx.List[StoreCard]{Items: items}, err
	})
}

func (m *Module) storeDetail(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (StoreDetail, error) {
		return m.svc.StoreDetail(r.Context(), pr(r), id)
	})
}

func (m *Module) code(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusCreated, "id", func(id string) (LinkCode, error) {
		return m.svc.CreateCode(r.Context(), pr(r), id)
	})
}

func (m *Module) requestStore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in RequestInput) (Link, error) {
		return m.svc.RequestStore(r.Context(), pr(r), id, in)
	})
}

func (m *Module) disconnectStore(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err == nil {
		err = m.svc.DisconnectStore(r.Context(), pr(r), id)
	}
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) shipment(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusCreated, "id", func(id string) (inventory.Document, error) {
		return m.svc.ShipmentForStore(r.Context(), pr(r), id)
	})
}

func (m *Module) distLinks(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Link], error) {
		items, err := m.svc.DistributorLinks(r.Context(), pr(r), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[Link]{Items: items}, err
	})
}

func (m *Module) distAnswer(accept bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Link, error) {
			return m.svc.AnswerAsDistributor(r.Context(), pr(r), id, accept)
		})
	}
}

func (m *Module) orders(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Order], error) {
		items, err := m.svc.Orders(r.Context(), pr(r), OrdersFilter{
			Status: q.Get("status"), StoreID: q.Get("store_id"), DistributorID: q.Get("distributor_id"), Page: httpx.PageFrom(r),
		})
		return httpx.List[Order]{Items: items}, err
	})
}

func (m *Module) order(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
		return m.svc.GetOrder(r.Context(), pr(r), id)
	})
}

func (m *Module) shipQty(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ShipQtyInput) (Order, error) {
		return m.svc.SetShipQty(r.Context(), pr(r), id, in)
	})
}

func (m *Module) orderAction(fn func(context.Context, *identity.Principal, string) (Order, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
			return fn(r.Context(), pr(r), id)
		})
	}
}

func (m *Module) reject(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in RejectInput) (Order, error) {
		return m.svc.RejectOrder(r.Context(), pr(r), id, in)
	})
}

// --------------------------------------------------------------- магазин

func (m *Module) suppliers(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Supplier], error) {
		items, err := m.svc.Suppliers(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[Supplier]{Items: items}, err
	})
}

func (m *Module) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Supplier], error) {
		items, err := m.svc.SearchSuppliers(r.Context(), pr(r), q.Get("store_id"), q.Get("q"), httpx.PageFrom(r))
		return httpx.List[Supplier]{Items: items}, err
	})
}

func (m *Module) reorder(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[ReorderGroup], error) {
		items, err := m.svc.Reorder(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[ReorderGroup]{Items: items}, err
	})
}

func (m *Module) connect(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in ConnectInput) (Link, error) {
		return m.svc.ConnectByCode(r.Context(), pr(r), in)
	})
}

func (m *Module) storeAnswer(accept bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Link, error) {
			return m.svc.AnswerAsStore(r.Context(), pr(r), id, accept)
		})
	}
}

func (m *Module) supplier(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Supplier, error) {
		return m.svc.SupplierDetail(r.Context(), pr(r), r.URL.Query().Get("store_id"), id)
	})
}

func (m *Module) catalog(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[PriceItem], error) {
		items, err := m.svc.Catalog(r.Context(), pr(r), q.Get("store_id"), id, q.Get("q"), httpx.PageFrom(r))
		return httpx.List[PriceItem]{Items: items}, err
	})
}

func (m *Module) requestDistributor(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in RequestInput) (Link, error) {
		return m.svc.RequestDistributor(r.Context(), pr(r), id, in)
	})
}

type disconnectInput struct {
	StoreID string `json:"store_id"`
}

func (m *Module) disconnectDistributor(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	var in disconnectInput
	if err == nil {
		err = httpx.Decode(r, &in)
	}
	if err == nil {
		err = m.svc.DisconnectDistributor(r.Context(), pr(r), id, in.StoreID)
	}
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) createOrder(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in OrderInput) (Order, error) {
		return m.svc.CreateOrder(r.Context(), pr(r), in)
	})
}
