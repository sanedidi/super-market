package inventory

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
	r.Route("/store/inventory", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/stock", m.stock)
		r.Get("/stock/summary", m.stockSummary)
		r.Get("/my-products", m.myProducts)
		r.Put("/my-products/{id}/pack", m.setPack)
		r.Delete("/my-products/{id}", m.removeMyProduct)
		r.Get("/movements", m.movements)
		docs := m.auth.Allow(identity.PermInventoryManage)
		r.With(docs).Get("/documents", m.list)
		r.Post("/documents", m.create)
		r.With(docs).Get("/documents/{id}", m.get)
		r.Patch("/documents/{id}", m.update)
		r.Delete("/documents/{id}", m.delete)
		r.Post("/documents/{id}/post", m.post)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) stock(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[StockRow], error) {
		items, err := m.svc.Stock(r.Context(), pr(r), StockFilter{
			WarehouseID: q.Get("warehouse_id"), StoreID: q.Get("store_id"), ProductID: q.Get("product_id"),
			Query: q.Get("q"), Page: httpx.PageFrom(r),
		})
		return httpx.List[StockRow]{Items: items}, err
	})
}

func (m *Module) myProducts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (MyProducts, error) {
		return m.svc.MyProducts(r.Context(), pr(r), MyProductsFilter{
			StoreID: q.Get("store_id"), Status: q.Get("status"), CategoryID: q.Get("category_id"), ProductID: q.Get("product_id"),
			Query: q.Get("q"), Order: q.Get("order"), Page: httpx.PageFrom(r),
		})
	})
}

// setPack — штук в блоке у товара («блок по 6»): помощник и панель.
func (m *Module) removeMyProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (map[string]bool, error) {
		return map[string]bool{"removed": true}, m.svc.RemoveMyProduct(r.Context(), pr(r), r.URL.Query().Get("store_id"), id)
	})
}

func (m *Module) setPack(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PackInput) (MyProduct, error) {
		return m.svc.SetPack(r.Context(), pr(r), id, in)
	})
}

func (m *Module) stockSummary(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (StockSummary, error) {
		return m.svc.StockSummary(r.Context(), pr(r), StockFilter{
			WarehouseID: q.Get("warehouse_id"), StoreID: q.Get("store_id"), ProductID: q.Get("product_id"), Query: q.Get("q"),
		})
	})
}

func (m *Module) movements(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Movement], error) {
		items, err := m.svc.Movements(r.Context(), pr(r), q.Get("warehouse_id"), q.Get("product_id"), httpx.PageFrom(r))
		return httpx.List[Movement]{Items: items}, err
	})
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Document], error) {
		from, to, err := finance.ParsePeriod(r)
		if err != nil {
			return httpx.List[Document]{}, err
		}
		items, err := m.svc.List(r.Context(), pr(r), Filter{
			Type: q.Get("type"), Status: q.Get("status"), WarehouseID: q.Get("warehouse_id"), StoreID: q.Get("store_id"),
			From: from, To: to, Page: httpx.PageFrom(r),
		})
		return httpx.List[Document]{Items: items}, err
	})
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in Input) (Document, error) {
		return m.svc.Create(r.Context(), pr(r), in)
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Document, error) {
		return m.svc.Get(r.Context(), pr(r), id)
	})
}

func (m *Module) update(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in Input) (Document, error) {
		return m.svc.Update(r.Context(), pr(r), id, in)
	})
}

func (m *Module) delete(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err == nil {
		err = m.svc.Delete(r.Context(), pr(r), id)
	}
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) post(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Document, error) {
		return m.svc.Post(r.Context(), pr(r), id)
	})
}
