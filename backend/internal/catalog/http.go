package catalog

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

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

type rawObject = map[string]json.RawMessage

func (m *Module) Routes(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/catalog/{kind}", m.listDict(false))
		r.Post("/admin/catalog/{kind}", m.createDict)
		r.Patch("/admin/catalog/{kind}/{id}", m.updateDict)

		r.Get("/admin/products", m.adminListProducts)
		r.Post("/admin/products", m.adminCreateProduct)
		r.Get("/admin/products/{id}", m.adminGetProduct)
		r.Patch("/admin/products/{id}", m.adminUpdateProduct)
		r.Post("/admin/products/{id}/approve", m.approve)
		r.Post("/admin/products/{id}/reject", m.reject)

		r.Get("/admin/banners", m.listBanners)
		r.Post("/admin/banners", m.createBanner)
		r.Patch("/admin/banners/{id}", m.updateBanner)
	})

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/catalog/{kind}", m.listDict(true))

		r.Get("/store/products", m.storeListProducts)
		r.Post("/store/products", m.storeCreateProduct)
		r.Get("/store/products/{id}", m.storeGetProduct)
		r.Patch("/store/products/{id}", m.storeUpdateProduct)

		r.Get("/store/price-types", m.listPriceTypes)
		r.Post("/store/price-types", m.createPriceType)
		r.Patch("/store/price-types/{id}", m.updatePriceType)

		prices := m.auth.Allow(identity.PermPricesManage)
		r.With(prices).Get("/store/price-documents", m.listPriceDocs)
		r.Post("/store/price-documents", m.createPriceDoc)
		r.With(prices).Get("/store/price-documents/{id}", m.getPriceDoc)
		r.Patch("/store/price-documents/{id}", m.updatePriceDoc)
		r.Post("/store/price-documents/{id}/post", m.postPriceDoc)

		r.With(prices).Get("/store/promotions", m.listPromotions)
		r.Post("/store/promotions", m.createPromotion)
		r.With(prices).Get("/store/promotions/{id}", m.getPromotion)
		r.Patch("/store/promotions/{id}", m.updatePromotion)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

// ------------------------------------------------------------ справочники

func (m *Module) listDict(onlyActive bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[map[string]any], error) {
			items, err := m.svc.ListDict(r.Context(), chi.URLParam(r, "kind"), onlyActive)
			return httpx.List[map[string]any]{Items: items}, err
		})
	}
}

func (m *Module) createDict(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in rawObject) (map[string]any, error) {
		return m.svc.CreateDict(r.Context(), chi.URLParam(r, "kind"), in)
	})
}

func (m *Module) updateDict(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in rawObject) (map[string]any, error) {
		return m.svc.UpdateDict(r.Context(), chi.URLParam(r, "kind"), id, in)
	})
}

// ----------------------------------------------------------------- товары

func filterFrom(r *http.Request) ProductFilter {
	q := r.URL.Query()
	return ProductFilter{
		Query:      q.Get("q"),
		CategoryID: q.Get("category_id"),
		Barcode:    q.Get("barcode"),
		Status:     q.Get("status"),
		Page:       httpx.PageFrom(r),
	}
}

func (m *Module) adminListProducts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Product], error) {
		items, err := m.svc.AdminListProducts(r.Context(), filterFrom(r))
		return httpx.List[Product]{Items: items}, err
	})
}

func (m *Module) adminCreateProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in ProductInput) (Product, error) {
		return m.svc.AdminCreateProduct(r.Context(), in)
	})
}

func (m *Module) adminGetProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Product, error) {
		return m.svc.AdminGetProduct(r.Context(), id)
	})
}

func (m *Module) adminUpdateProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ProductInput) (Product, error) {
		return m.svc.AdminUpdateProduct(r.Context(), id, in)
	})
}

func (m *Module) approve(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Product, error) {
		return m.svc.Approve(r.Context(), id)
	})
}

func (m *Module) reject(w http.ResponseWriter, r *http.Request) {
	type body struct {
		Reason string `json:"reason"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in body) (Product, error) {
		return m.svc.Reject(r.Context(), id, in.Reason)
	})
}

func (m *Module) storeListProducts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Product], error) {
		f := filterFrom(r)
		f.Status = ""
		items, err := m.svc.StoreListProducts(r.Context(), pr(r), f,
			r.URL.Query().Get("store_id"), r.URL.Query().Get("price_type_id"))
		return httpx.List[Product]{Items: items}, err
	})
}

func (m *Module) storeCreateProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in ProductInput) (Product, error) {
		return m.svc.StoreCreateProduct(r.Context(), pr(r), in)
	})
}

func (m *Module) storeGetProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Product, error) {
		return m.svc.StoreGetProduct(r.Context(), pr(r), id)
	})
}

func (m *Module) storeUpdateProduct(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ProductInput) (Product, error) {
		return m.svc.StoreUpdateProduct(r.Context(), pr(r), id, in)
	})
}

// ------------------------------------------------------------------- цены

func (m *Module) listPriceTypes(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PriceType], error) {
		items, err := m.svc.ListPriceTypes(r.Context(), pr(r))
		return httpx.List[PriceType]{Items: httpx.PageSlice(r, items)}, err
	})
}

func (m *Module) createPriceType(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in PriceTypeInput) (PriceType, error) {
		return m.svc.CreatePriceType(r.Context(), pr(r), in)
	})
}

func (m *Module) updatePriceType(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PriceTypeInput) (PriceType, error) {
		return m.svc.UpdatePriceType(r.Context(), pr(r), id, in)
	})
}

func (m *Module) listPriceDocs(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PriceDocument], error) {
		items, err := m.svc.ListPriceDocs(r.Context(), pr(r), httpx.PageFrom(r))
		return httpx.List[PriceDocument]{Items: items}, err
	})
}

func (m *Module) createPriceDoc(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in PriceDocInput) (PriceDocument, error) {
		return m.svc.CreatePriceDoc(r.Context(), pr(r), in)
	})
}

func (m *Module) getPriceDoc(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (PriceDocument, error) {
		return m.svc.GetPriceDoc(r.Context(), pr(r), id)
	})
}

func (m *Module) updatePriceDoc(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PriceDocInput) (PriceDocument, error) {
		return m.svc.UpdatePriceDoc(r.Context(), pr(r), id, in)
	})
}

func (m *Module) postPriceDoc(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (PriceDocument, error) {
		return m.svc.PostPriceDoc(r.Context(), pr(r), id)
	})
}

// ---------------------------------------------------------------- акции

func (m *Module) listPromotions(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Promotion], error) {
		items, err := m.svc.ListPromotions(r.Context(), pr(r), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[Promotion]{Items: items}, err
	})
}

func (m *Module) createPromotion(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in PromotionInput) (Promotion, error) {
		return m.svc.CreatePromotion(r.Context(), pr(r), in)
	})
}

func (m *Module) getPromotion(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Promotion, error) {
		return m.svc.GetPromotion(r.Context(), pr(r), id)
	})
}

func (m *Module) updatePromotion(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in PromotionInput) (Promotion, error) {
		return m.svc.UpdatePromotion(r.Context(), pr(r), id, in)
	})
}

// ---------------------------------------------------------------- баннеры

func (m *Module) listBanners(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Banner], error) {
		items, err := m.svc.ListBanners(r.Context())
		return httpx.List[Banner]{Items: items}, err
	})
}

func (m *Module) createBanner(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in BannerInput) (Banner, error) {
		return m.svc.CreateBanner(r.Context(), in)
	})
}

func (m *Module) updateBanner(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in BannerInput) (Banner, error) {
		return m.svc.UpdateBanner(r.Context(), id, in)
	})
}
