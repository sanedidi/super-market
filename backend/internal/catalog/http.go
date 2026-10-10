package catalog

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
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
		r.Delete("/admin/catalog/{kind}/{id}", m.deleteDict)

		r.Post("/admin/catalog-import", m.importProducts)
		r.Get("/admin/catalog-import/status", m.importStatus)
		r.Post("/admin/catalog-import/retry-photos", m.retryPhotos)

		r.Get("/admin/products", m.adminListProducts)
		r.Get("/admin/products/groups", m.adminProductGroups)
		r.Post("/admin/products", m.adminCreateProduct)
		r.Get("/admin/products/{id}", m.adminGetProduct)
		r.Get("/admin/products/{id}/overview", m.adminProductOverview)
		r.Patch("/admin/products/{id}", m.adminUpdateProduct)
		r.Delete("/admin/products/{id}", m.adminDeleteProduct)
		r.Post("/admin/products/{id}/approve", m.approve)
		r.Post("/admin/products/{id}/reject", m.reject)

		r.Get("/admin/banners", m.listBanners)
		r.Post("/admin/banners", m.createBanner)
		r.Patch("/admin/banners/{id}", m.updateBanner)
		r.Delete("/admin/banners/{id}", m.adminDeleteBanner)
		r.Post("/admin/banners/{id}/approve", m.moderateBanner(true))
		r.Post("/admin/banners/{id}/reject", m.moderateBanner(false))
	})

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/catalog/{kind}", m.listDict(true))

		// Свои баннеры сети для витрины (с модерацией).
		showcaseManage := m.auth.Allow(identity.PermShowcaseManage)
		r.With(showcaseManage).Get("/store/banners", m.storeBanners)
		r.With(showcaseManage).Post("/store/banners", m.storeCreateBanner)
		r.With(showcaseManage).Patch("/store/banners/{id}", m.storeUpdateBanner)
		r.With(showcaseManage).Delete("/store/banners/{id}", m.storeDeleteBanner)

		r.Get("/store/products", m.storeListProducts)
		r.Get("/store/products/groups", m.storeProductGroups)
		r.Post("/store/products", m.storeCreateProduct)
		r.Get("/store/products/{id}", m.storeGetProduct)
		r.Patch("/store/products/{id}", m.storeUpdateProduct)
		r.Delete("/store/products/{id}", m.storeDel(m.svc.StoreDeleteProduct))

		r.Get("/store/price-types", m.listPriceTypes)
		r.Post("/store/price-types", m.createPriceType)
		r.Patch("/store/price-types/{id}", m.updatePriceType)
		r.Delete("/store/price-types/{id}", m.storeDel(m.svc.DeletePriceType))

		prices := m.auth.Allow(identity.PermPricesManage)
		r.With(prices).Get("/store/price-documents", m.listPriceDocs)
		r.Post("/store/price-documents", m.createPriceDoc)
		r.With(prices).Get("/store/price-documents/{id}", m.getPriceDoc)
		r.Patch("/store/price-documents/{id}", m.updatePriceDoc)
		r.Delete("/store/price-documents/{id}", m.storeDel(m.svc.DeletePriceDoc))
		r.Post("/store/price-documents/{id}/post", m.postPriceDoc)

		r.With(prices).Get("/store/promotions", m.listPromotions)
		r.With(m.auth.Feature(plans.FeaturePromotions)).Post("/store/promotions", m.createPromotion)
		r.With(prices).Get("/store/promotions/{id}", m.getPromotion)
		r.With(m.auth.Feature(plans.FeaturePromotions)).Patch("/store/promotions/{id}", m.updatePromotion)
		r.Delete("/store/promotions/{id}", m.storeDel(m.svc.DeletePromotion))
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

// ------------------------------------------------------------ справочники

func (m *Module) listDict(onlyActive bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[map[string]any], error) {
			f := DictFilter{Query: r.URL.Query().Get("q"), ExcludeTree: r.URL.Query().Get("exclude_tree")}
			// Магазину справочник отдаётся целиком (для выпадающих списков),
			// а постранично — только если явно передан limit.
			if !onlyActive || r.URL.Query().Has("limit") {
				page := httpx.PageFrom(r)
				f.Page = &page
			}
			items, err := m.svc.ListDict(r.Context(), chi.URLParam(r, "kind"), onlyActive, f)
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
		Query:          q.Get("q"),
		CategoryID:     q.Get("category_id"),
		Barcode:        q.Get("barcode"),
		Status:         q.Get("status"),
		BrandID:        q.Get("brand_id"),
		LeafCategoryID: q.Get("leaf_category_id"),
		Sort:           q.Get("sort"),
		Photo:          q.Get("photo"),
		Scope:          q.Get("scope"),
		StoreID:        q.Get("store_id"),
		Page:           httpx.PageFrom(r),
	}
}

func (m *Module) importProducts(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in ImportInput) (ImportResult, error) {
		return m.svc.Import(r.Context(), in)
	})
}

func (m *Module) importStatus(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ImportStatus, error) {
		return m.svc.ImportStatus(r.Context())
	})
}

func (m *Module) retryPhotos(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (map[string]int, error) {
		n, err := m.svc.RetryPhotos(r.Context())
		return map[string]int{"requeued": n}, err
	})
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

func (m *Module) adminProductOverview(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (ProductOverview, error) {
		return m.svc.AdminProductOverview(r.Context(), id)
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

func (m *Module) adminProductGroups(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ProductGroups, error) {
		return m.svc.AdminProductGroups(r.Context(), filterFrom(r))
	})
}

func (m *Module) storeProductGroups(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ProductGroups, error) {
		f := filterFrom(r)
		f.Status = ""
		return m.svc.StoreProductGroups(r.Context(), pr(r), f)
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
		items, err := m.svc.ListBanners(r.Context(), r.URL.Query().Get("moderation"), httpx.PageFrom(r))
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

type moderationInput struct {
	Reason string `json:"reason"`
}

func (m *Module) moderateBanner(approve bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if approve {
			httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Banner, error) {
				return m.svc.ModerateBanner(r.Context(), id, true, "")
			})
			return
		}
		httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in moderationInput) (Banner, error) {
			return m.svc.ModerateBanner(r.Context(), id, approve, in.Reason)
		})
	}
}

func (m *Module) storeBanners(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Banner], error) {
		items, err := m.svc.NetworkBanners(r.Context(), pr(r).NetworkID)
		return httpx.List[Banner]{Items: items}, err
	})
}

func (m *Module) storeCreateBanner(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in BannerInput) (Banner, error) {
		return m.svc.CreateNetworkBanner(r.Context(), pr(r).NetworkID, in)
	})
}

func (m *Module) storeUpdateBanner(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in BannerInput) (Banner, error) {
		return m.svc.UpdateNetworkBanner(r.Context(), pr(r).NetworkID, id, in)
	})
}
