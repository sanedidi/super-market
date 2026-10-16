package supply

import (
	"context"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/inventory"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Module struct {
	svc  *Service
	id   *identity.Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, id *identity.Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, id: id, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	// «SM Агент»: вход и регистрация по номеру и коду из SMS.
	r.Route("/auth/agent", func(r chi.Router) {
		r.Post("/otp/request", m.agentRequest)
		r.Post("/otp/verify", m.agentVerify)
		r.Get("/brands", m.agentBrandSearch)
		r.Get("/categories", m.agentCategories)
		r.Post("/register", m.agentRegister)
	})
	// Супер-админ: заявки агентов на новые бренды.
	r.Route("/admin/brand-requests", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/", m.adminBrandRequests)
		r.Get("/{id}", m.adminBrandRequest)
		r.Post("/{id}/approve", m.adminApprove)
		r.Post("/{id}/link", m.adminLink)
		r.Post("/{id}/reject", m.adminReject)
	})
	// Дистрибьютор / агент («SM Агент»).
	r.Route("/store/supply", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/summary", m.summary)
		r.Get("/dashboard", m.dashboard)
		r.Get("/warehouses", m.agentWarehouses)
		r.Post("/warehouses", m.createAgentWarehouse)
		r.Patch("/warehouses/{id}", m.updateAgentWarehouse)
		r.Get("/settings", m.getSettings)
		r.Patch("/settings", m.updateSettings)
		r.Get("/brands", m.myBrands)
		r.Post("/brands", m.addBrands)
		r.Get("/brands/search", m.brandSearch)
		r.Get("/categories", m.categories)
		r.Post("/brand-requests", m.createBrandRequest)
		r.Put("/brand-requests/{id}", m.updateBrandRequest)
		r.Get("/payments", m.agentPayments)
		r.Get("/debtors", m.agentDebtors)
		r.Post("/payments/{id}/confirm", m.confirmPayment)
		r.Post("/payments/{id}/dispute", m.disputePayment)
		// Магазины — когда у сам зарегистрированного агента есть бренд.
		r.Group(func(r chi.Router) {
			r.Use(m.requireVerified)
			r.Get("/stores", m.stores)
			r.Get("/stores/{id}", m.storeDetail)
			r.Get("/stores/{id}/statement", m.storeStatement)
			r.Get("/stores/{id}/warehouses", m.storeWarehouses)
			r.Post("/stores/{id}/code", m.code)
			r.Post("/stores/{id}/request", m.requestStore)
			r.Post("/stores/{id}/shipment", m.shipment)
		})
		r.Post("/stores/{id}/disconnect", m.disconnectStore)
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
		r.Get("/{id}/payments", m.supplierPayments)
		r.Post("/{id}/pay", m.paySupplier)
		r.Post("/payments/{id}/resolve", m.resolvePayment)
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

// ------------------------------------------------------------ агент: вход

func (m *Module) requireVerified(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := m.svc.requireVerified(r.Context(), pr(r)); err != nil {
			httpx.Fail(w, r, m.log, err)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type phoneInput struct {
	Phone string `json:"phone"`
	Code  string `json:"code"`
}

func (m *Module) agentRequest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in phoneInput) (map[string]any, error) {
		expires, channel, err := m.id.RequestCodeVia(r.Context(), in.Phone, identity.AppAgent)
		if err != nil {
			return nil, err
		}
		return map[string]any{"sent": true, "expires_in": expires, "resend_in": identity.ResendIn(), "channel": channel}, nil
	})
}

func (m *Module) agentVerify(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in phoneInput) (identity.AgentVerifyResult, error) {
		return m.id.AgentVerify(r.Context(), in.Phone, in.Code, r.UserAgent())
	})
}

// ticket — билет регистрации из заголовка X-Agent-Ticket или ?ticket=.
func (m *Module) ticket(r *http.Request) error {
	t := r.Header.Get("X-Agent-Ticket")
	if t == "" {
		t = r.URL.Query().Get("ticket")
	}
	_, err := m.id.AgentTicket(t)
	return err
}

func (m *Module) agentCategories(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Category], error) {
		if err := m.ticket(r); err != nil {
			return httpx.List[Category]{}, err
		}
		items, err := m.svc.Categories(r.Context())
		return httpx.List[Category]{Items: items}, err
	})
}

func (m *Module) agentBrandSearch(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[BrandHit], error) {
		// Поиск брендов — до регистрации, по билету регистрации.
		if err := m.ticket(r); err != nil {
			return httpx.List[BrandHit]{}, err
		}
		items, err := m.svc.SearchBrands(r.Context(), r.URL.Query().Get("q"), 30)
		return httpx.List[BrandHit]{Items: items}, err
	})
}

func (m *Module) agentRegister(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in RegisterInput) (identity.Tokens, error) {
		ph, err := m.id.AgentTicket(in.Ticket)
		if err != nil {
			return identity.Tokens{}, err
		}
		userID, err := m.svc.RegisterAgent(r.Context(), ph, in)
		if err != nil {
			return identity.Tokens{}, err
		}
		return m.id.IssueSession(r.Context(), userID, identity.AppStore, r.UserAgent())
	})
}

// ------------------------------------------------------- агент: бренды

func (m *Module) myBrands(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (AgentBrands, error) { return m.svc.MyBrands(r.Context(), pr(r)) })
}

type brandIDsInput struct {
	BrandIDs []string `json:"brand_ids"`
}

func (m *Module) addBrands(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in brandIDsInput) (AgentBrands, error) {
		return m.svc.AddMyBrands(r.Context(), pr(r), in.BrandIDs)
	})
}

func (m *Module) brandSearch(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[BrandHit], error) {
		if err := requireDistributor(pr(r)); err != nil {
			return httpx.List[BrandHit]{}, err
		}
		items, err := m.svc.SearchBrands(r.Context(), r.URL.Query().Get("q"), 30)
		return httpx.List[BrandHit]{Items: items}, err
	})
}

func (m *Module) categories(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Category], error) {
		items, err := m.svc.Categories(r.Context())
		return httpx.List[Category]{Items: items}, err
	})
}

func (m *Module) createBrandRequest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in BrandRequestInput) (BrandRequest, error) {
		return m.svc.CreateBrandRequest(r.Context(), pr(r), in)
	})
}

func (m *Module) updateBrandRequest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in BrandRequestInput) (BrandRequest, error) {
		return m.svc.UpdateBrandRequest(r.Context(), pr(r), id, in)
	})
}

// ------------------------------------------------------ агент: оплаты

func (m *Module) agentPayments(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Payment], error) {
		items, err := m.svc.AgentPayments(r.Context(), pr(r), PaymentsFilter{Status: q.Get("status"), StoreID: q.Get("store_id"), Page: httpx.PageFrom(r)})
		return httpx.List[Payment]{Items: items}, err
	})
}

func (m *Module) agentWarehouses(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[AgentWarehouse], error) {
		items, err := m.svc.AgentWarehouses(r.Context(), pr(r))
		return httpx.List[AgentWarehouse]{Items: items}, err
	})
}

func (m *Module) createAgentWarehouse(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in WarehouseInput) (AgentWarehouse, error) {
		return m.svc.CreateAgentWarehouse(r.Context(), pr(r), in)
	})
}

func (m *Module) updateAgentWarehouse(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in WarehouseInput) (AgentWarehouse, error) {
		return m.svc.UpdateAgentWarehouse(r.Context(), pr(r), id, in)
	})
}

// storeWarehouses — ?products=id,id: склады для расхода магазину {id}.
func (m *Module) storeWarehouses(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[AgentWarehouse], error) {
		var products []string
		if v := strings.TrimSpace(r.URL.Query().Get("products")); v != "" {
			products = strings.Split(v, ",")
		}
		items, err := m.svc.WarehousesForStore(r.Context(), pr(r), id, products)
		return httpx.List[AgentWarehouse]{Items: items}, err
	})
}

func (m *Module) dashboard(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Dashboard, error) {
		return m.svc.AgentDashboard(r.Context(), pr(r), r.URL.Query().Get("period"))
	})
}

func (m *Module) agentDebtors(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Debtor], error) {
		items, err := m.svc.AgentDebtors(r.Context(), pr(r))
		return httpx.List[Debtor]{Items: items}, err
	})
}

func (m *Module) confirmPayment(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Payment, error) {
		return m.svc.ConfirmPayment(r.Context(), pr(r), id)
	})
}

func (m *Module) disputePayment(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in DisputeInput) (Payment, error) {
		return m.svc.DisputePayment(r.Context(), pr(r), id, in)
	})
}

func (m *Module) storeStatement(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (StoreStatement, error) {
		from, to, err := finance.ParsePeriod(r)
		if err != nil {
			return StoreStatement{}, err
		}
		return m.svc.AgentStoreStatement(r.Context(), pr(r), id, from, to)
	})
}

// ---------------------------------------------------- магазин: оплаты

func (m *Module) supplierPayments(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[Payment], error) {
		items, err := m.svc.SupplierPayments(r.Context(), pr(r), id, httpx.PageFrom(r))
		return httpx.List[Payment]{Items: items}, err
	})
}

func (m *Module) paySupplier(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "id", func(id string, in PayInput) (Payment, error) {
		return m.svc.PaySupplier(r.Context(), pr(r), id, in)
	})
}

func (m *Module) resolvePayment(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ResolveInput) (Payment, error) {
		return m.svc.ResolvePayment(r.Context(), pr(r), id, in)
	})
}

// ------------------------------------------------- супер-админ: бренды

func (m *Module) adminBrandRequests(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (BrandRequests, error) {
		return m.svc.ListBrandRequests(r.Context(), pr(r), q.Get("status"), q.Get("q"), httpx.PageFrom(r))
	})
}

func (m *Module) adminBrandRequest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (BrandRequest, error) {
		return m.svc.GetBrandRequest(r.Context(), pr(r), id)
	})
}

func (m *Module) adminApprove(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ApproveInput) (BrandRequest, error) {
		return m.svc.ApproveBrandRequest(r.Context(), pr(r), id, in)
	})
}

type linkBrandInput struct {
	BrandID string `json:"brand_id"`
}

func (m *Module) adminLink(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in linkBrandInput) (BrandRequest, error) {
		return m.svc.LinkBrandRequest(r.Context(), pr(r), id, in.BrandID)
	})
}

type rejectBrandInput struct {
	Reason string `json:"reason"`
}

func (m *Module) adminReject(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in rejectBrandInput) (BrandRequest, error) {
		return m.svc.RejectBrandRequest(r.Context(), pr(r), id, in.Reason)
	})
}
