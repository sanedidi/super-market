package orders

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/delivery"
	"github.com/sanedidi/super-market/backend/internal/finance"
	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/payments"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/showcase"
)

type Module struct {
	svc      *Service
	delivery *delivery.Service
	payments *payments.Service
	auth     *identity.Authenticator
	log      *slog.Logger
}

func NewModule(svc *Service, d *delivery.Service, p *payments.Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, delivery: d, payments: p, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	// Провайдеры оплаты (без нашей авторизации — у каждого своя проверка).
	r.Post("/payments/payme", m.payments.PaymeHandler)
	r.Post("/payments/click/prepare", m.payments.ClickPrepareHandler)
	r.Post("/payments/click/complete", m.payments.ClickCompleteHandler)

	// Приложение покупателя.
	r.Get("/client/stores/nearby", m.nearby)
	r.Get("/client/stores/{id}/categories", m.categories)
	r.Get("/client/stores/{id}/products", m.products)
	r.Get("/client/stores/{id}/products/{pid}", m.product)
	r.Get("/client/stores/{id}/products/{pid}/related", m.related)
	r.Get("/client/home", m.home)
	r.Get("/client/stores/{id}/home", m.storeHome)
	r.With(m.auth.Optional(identity.AppClient)).Post("/client/home/events", m.homeEvents)
	r.Get("/client/stores/{id}/slots", m.slots)
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppClient))
		r.Get("/client/favorites", m.favorites)
		r.Post("/client/favorites", m.addFavorite)
		r.Delete("/client/favorites/{pid}", m.removeFavorite)
		r.Get("/client/addresses", m.listAddresses)
		r.Post("/client/addresses", m.createAddress)
		r.Put("/client/addresses/{id}", m.updateAddress)
		r.Delete("/client/addresses/{id}", m.deleteAddress)
		r.Post("/client/checkout/preview", m.preview)
		r.Post("/client/orders", m.createOrder)
		r.Get("/client/orders", m.clientOrders)
		r.Get("/client/orders/{id}", m.clientOrder)
		r.Post("/client/orders/{id}/cancel", m.clientCancel)
		r.Get("/client/orders/{id}/payment-url", m.paymentURL)
		r.Get("/client/orders/{id}/tracking", m.tracking)
	})

	// Панель магазина.
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		// Курьеры (orders.deliver) работают через /courier/*.
		manage := m.auth.Allow(identity.PermOrdersManage)
		dlv := m.auth.Allow(identity.PermStoresManage, identity.PermOrdersManage)
		r.With(dlv).Get("/store/stores/{id}/delivery", m.getDelivery)
		r.Put("/store/stores/{id}/delivery", m.saveDelivery)
		r.With(dlv).Get("/store/stores/{id}/zones", m.listZones)
		r.Post("/store/stores/{id}/zones", m.createZone)
		r.Patch("/store/stores/{id}/zones/{zone}", m.updateZone)
		r.Delete("/store/stores/{id}/zones/{zone}", m.deleteZone)

		// Витрина приложения: ?store_id= — витрина одного магазина (тариф «Про»).
		showcaseManage := m.auth.Allow(identity.PermShowcaseManage)
		r.With(showcaseManage).Get("/store/home", m.storeShowcase)
		r.With(showcaseManage).Put("/store/home/draft", m.storeSaveDraft)
		r.With(showcaseManage).Delete("/store/home/draft", m.storeLayoutAct(m.svc.DiscardDraft))
		r.With(showcaseManage).Post("/store/home/publish", m.storePublish)
		r.With(showcaseManage).Get("/store/home/versions", m.storeVersions)
		r.With(showcaseManage).Post("/store/home/restore", m.storeRestore)
		r.With(showcaseManage).Delete("/store/home", m.storeLayoutAct(m.svc.ResetLayout))
		r.With(showcaseManage).Get("/store/home/stores", m.storePreviewStores)
		r.With(showcaseManage).Post("/store/home/preview", m.storePreview)
		r.With(showcaseManage).Get("/store/home/stats", m.storeHomeStats)
		r.Post("/store/showcase/plan", m.storeChoosePlan)

		r.With(manage).Get("/store/orders", m.storeList)
		r.With(manage).Get("/store/orders/{id}", m.storeGet)
		r.Post("/store/orders/{id}/accept", m.act(m.svc.Accept))
		r.Post("/store/orders/{id}/start-picking", m.act(m.svc.StartPicking))
		r.Post("/store/orders/{id}/picked", m.picked)
		r.Post("/store/orders/{id}/start-delivery", m.act(m.svc.StartDelivery))
		r.Post("/store/orders/{id}/delivered", m.act(m.svc.Delivered))
		r.Post("/store/orders/{id}/cancel", m.storeCancel)
		r.Post("/store/orders/{id}/fiscal", m.fiscal)
		r.Post("/store/orders/{id}/assign-courier", m.assignCourier)
		r.Get("/store/couriers", m.storeCouriers)
	})

	// Курьер: приложение курьера (логин и пароль) или старый вход сотрудника.
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppCourier, identity.AppStore))
		r.Get("/courier/me", m.courierMe)
		r.Post("/courier/shift", m.courierShift)
		r.Post("/courier/location", m.courierLocation)
		r.Get("/courier/orders", m.courierOrders)
		r.Get("/courier/orders/{id}", m.courierOrder)
		r.Get("/courier/history", m.courierHistory)
		r.Post("/courier/orders/{id}/picked-up", m.courierAct(m.svc.PickUp))
		r.Post("/courier/orders/{id}/delivered", m.courierAct(m.svc.CourierDelivered))
	})

	// Супер-админ.
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/orders", m.adminList)
		r.Get("/admin/orders/{id}", m.adminGet)
		r.Post("/admin/orders/{id}/cancel", m.adminCancel)
		r.Get("/admin/payments", m.adminPayments)
		r.Post("/admin/payments/{id}/refunded", m.adminRefunded)

		// Редактор главной; ?network_id= — витрина сети, без него — шаблон.
		r.Get("/admin/home", m.adminHome)
		r.Put("/admin/home/draft", m.adminSaveDraft)
		r.Delete("/admin/home/draft", m.adminHomeAct(m.svc.DiscardDraft))
		r.Post("/admin/home/publish", m.adminPublish)
		r.Get("/admin/home/versions", m.adminVersions)
		r.Post("/admin/home/restore", m.adminRestore)
		r.Delete("/admin/home", m.adminHomeAct(m.svc.ResetLayout))
		r.Get("/admin/showcase/plans", m.adminPlans)
		r.Get("/admin/home/stats", m.adminHomeStats)
		r.Patch("/admin/showcase/plans/{key}", m.adminSavePlan)
		r.Get("/admin/home/stores", m.adminPreviewStores)
		r.Post("/admin/home/preview", m.adminPreview)
	})
}

func adminScope(r *http.Request) LayoutScope {
	return LayoutScope{NetworkID: r.URL.Query().Get("network_id")}
}

func (m *Module) adminHome(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (LayoutEditor, error) {
		return m.svc.LayoutForEditor(r.Context(), adminScope(r))
	})
}

type blocksInput struct {
	StoreID string      `json:"store_id"`
	Blocks  []HomeBlock `json:"blocks"`
	Version int         `json:"version"`
	Plan    string      `json:"plan"`
}

func (m *Module) adminSaveDraft(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (LayoutEditor, error) {
		return m.svc.SaveDraft(r.Context(), adminScope(r), in.Blocks)
	})
}

func (m *Module) adminHomeAct(fn func(context.Context, LayoutScope) (LayoutEditor, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Respond(w, r, m.log, http.StatusOK, func() (LayoutEditor, error) { return fn(r.Context(), adminScope(r)) })
	}
}

func (m *Module) adminPublish(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (LayoutEditor, error) {
		return m.svc.Publish(r.Context(), adminScope(r), pr(r).UserID, false, nil)
	})
}

func (m *Module) adminVersions(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[LayoutVersion], error) {
		items, err := m.svc.Versions(r.Context(), adminScope(r))
		return httpx.List[LayoutVersion]{Items: items}, err
	})
}

func (m *Module) adminRestore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (LayoutEditor, error) {
		return m.svc.RestoreVersion(r.Context(), adminScope(r), in.Version)
	})
}

func (m *Module) adminPreviewStores(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PreviewStore], error) {
		items, err := m.svc.PreviewStores(r.Context(), r.URL.Query().Get("network_id"), true)
		return httpx.List[PreviewStore]{Items: items}, err
	})
}

func (m *Module) adminPreview(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (StoreHome, error) {
		return m.svc.PreviewHome(r.Context(), "", in.StoreID, in.Blocks)
	})
}

func (m *Module) adminPlans(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[showcase.Plan], error) {
		items, err := showcase.Plans(r.Context(), m.svc.pool)
		return httpx.List[showcase.Plan]{Items: items}, err
	})
}

func (m *Module) adminSavePlan(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in showcase.PlanInput) (showcase.Plan, error) {
		p, err := showcase.SavePlan(r.Context(), m.svc.pool, chi.URLParam(r, "key"), in)
		m.svc.forgetHomes()
		return p, err
	})
}

// ---------------------------------------------------- витрина магазина

func storeParam(r *http.Request) string { return r.URL.Query().Get("store_id") }

func (m *Module) storeShowcase(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ShowcaseEditor, error) {
		return m.svc.StoreShowcase(r.Context(), pr(r), storeParam(r))
	})
}

func (m *Module) storeSaveDraft(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (ShowcaseEditor, error) {
		return m.svc.SaveStoreDraft(r.Context(), pr(r), storeParam(r), in.Blocks)
	})
}

func (m *Module) storePublish(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ShowcaseEditor, error) {
		return m.svc.PublishStore(r.Context(), pr(r), storeParam(r))
	})
}

func (m *Module) storeLayoutAct(fn func(context.Context, LayoutScope) (LayoutEditor, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.Respond(w, r, m.log, http.StatusOK, func() (ShowcaseEditor, error) {
			return m.svc.StoreLayoutAct(r.Context(), pr(r), storeParam(r), func(sc LayoutScope) error {
				_, err := fn(r.Context(), sc)
				return err
			})
		})
	}
}

func (m *Module) storeVersions(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[LayoutVersion], error) {
		sc, err := storeScope(pr(r), storeParam(r))
		if err != nil {
			return httpx.List[LayoutVersion]{}, err
		}
		items, err := m.svc.Versions(r.Context(), sc)
		return httpx.List[LayoutVersion]{Items: items}, err
	})
}

func (m *Module) storeRestore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (ShowcaseEditor, error) {
		return m.svc.StoreLayoutAct(r.Context(), pr(r), storeParam(r), func(sc LayoutScope) error {
			_, err := m.svc.RestoreVersion(r.Context(), sc, in.Version)
			return err
		})
	})
}

func (m *Module) storePreviewStores(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[PreviewStore], error) {
		items, err := m.svc.PreviewStores(r.Context(), pr(r).NetworkID, true)
		return httpx.List[PreviewStore]{Items: items}, err
	})
}

func (m *Module) storePreview(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (StoreHome, error) {
		return m.svc.PreviewHome(r.Context(), pr(r).NetworkID, in.StoreID, in.Blocks)
	})
}

func (m *Module) storeChoosePlan(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in blocksInput) (ShowcaseEditor, error) {
		return m.svc.ChoosePlan(r.Context(), pr(r), in.Plan)
	})
}

func floatParam(r *http.Request, name string) (float64, error) {
	v, err := strconv.ParseFloat(r.URL.Query().Get(name), 64)
	if err != nil {
		return 0, apperr.Validation(name + ": ожидается число")
	}
	return v, nil
}

// ---------------------------------------------------------------- клиент

func (m *Module) nearby(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[delivery.NearbyStore], error) {
		lat, err := floatParam(r, "lat")
		if err != nil {
			return httpx.List[delivery.NearbyStore]{}, err
		}
		lng, err := floatParam(r, "lng")
		if err != nil {
			return httpx.List[delivery.NearbyStore]{}, err
		}
		items, err := m.delivery.Nearby(r.Context(), lat, lng)
		return httpx.List[delivery.NearbyStore]{Items: items}, err
	})
}

func (m *Module) categories(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CatalogCategory], error) {
		items, err := m.svc.StoreCategories(r.Context(), chi.URLParam(r, "id"))
		return httpx.List[CatalogCategory]{Items: items}, err
	})
}

func (m *Module) products(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	flag := func(name string) bool { v := q.Get(name); return v == "1" || v == "true" }
	var ids []string
	if v := strings.TrimSpace(q.Get("ids")); v != "" {
		ids = strings.Split(v, ",")
	}
	f := CatalogFilter{
		Query: q.Get("q"), CategoryID: q.Get("category_id"), BrandID: q.Get("brand_id"), IDs: ids,
		Discount: flag("discount"), New: flag("new"), Hits: flag("hits"), Sort: q.Get("sort"),
	}
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CatalogProduct], error) {
		if len(ids) > 200 {
			return httpx.List[CatalogProduct]{}, apperr.Validation("ids: не больше 200")
		}
		items, err := m.svc.StoreCatalog(r.Context(), chi.URLParam(r, "id"), f, httpx.PageFrom(r))
		return httpx.List[CatalogProduct]{Items: items}, err
	})
}

func (m *Module) product(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ProductDetail, error) {
		return m.svc.StoreProduct(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "pid"))
	})
}

func (m *Module) related(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CatalogProduct], error) {
		items, err := m.svc.RelatedProducts(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "pid"), httpx.PageFrom(r).Limit)
		return httpx.List[CatalogProduct]{Items: items}, err
	})
}

func (m *Module) home(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Home, error) {
		lat, err := floatParam(r, "lat")
		if err != nil {
			return Home{}, err
		}
		lng, err := floatParam(r, "lng")
		if err != nil {
			return Home{}, err
		}
		return m.svc.Home(r.Context(), lat, lng)
	})
}

func (m *Module) storeHome(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (StoreHome, error) {
		return m.svc.StoreHome(r.Context(), chi.URLParam(r, "id"))
	})
}

type favoriteIDs struct {
	ProductIDs []string `json:"product_ids"`
}

func (m *Module) favorites(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (favoriteIDs, error) {
		ids, err := m.svc.FavoriteIDs(r.Context(), pr(r))
		return favoriteIDs{ProductIDs: ids}, err
	})
}

func (m *Module) addFavorite(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in struct {
		ProductID string `json:"product_id"`
	}) (favoriteIDs, error) {
		if err := m.svc.AddFavorite(r.Context(), pr(r), in.ProductID); err != nil {
			return favoriteIDs{}, err
		}
		ids, err := m.svc.FavoriteIDs(r.Context(), pr(r))
		return favoriteIDs{ProductIDs: ids}, err
	})
}

func (m *Module) removeFavorite(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (favoriteIDs, error) {
		if err := m.svc.RemoveFavorite(r.Context(), pr(r), chi.URLParam(r, "pid")); err != nil {
			return favoriteIDs{}, err
		}
		ids, err := m.svc.FavoriteIDs(r.Context(), pr(r))
		return favoriteIDs{ProductIDs: ids}, err
	})
}

func (m *Module) listAddresses(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Address], error) {
		items, err := m.svc.ListAddresses(r.Context(), pr(r))
		return httpx.List[Address]{Items: items}, err
	})
}

func (m *Module) createAddress(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in AddressInput) (Address, error) {
		return m.svc.SaveAddress(r.Context(), pr(r), "", in)
	})
}

func (m *Module) updateAddress(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in AddressInput) (Address, error) {
		return m.svc.SaveAddress(r.Context(), pr(r), id, in)
	})
}

func (m *Module) deleteAddress(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err == nil {
		err = m.svc.DeleteAddress(r.Context(), pr(r), id)
	}
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) preview(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CheckoutInput) (Preview, error) {
		return m.svc.Preview(r.Context(), pr(r), in)
	})
}

func (m *Module) createOrder(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CheckoutInput) (Created, error) {
		return m.svc.CreateOrder(r.Context(), pr(r), in)
	})
}

func (m *Module) clientOrders(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Order], error) {
		items, err := m.svc.ClientListOrders(r.Context(), pr(r), httpx.PageFrom(r))
		return httpx.List[Order]{Items: items}, err
	})
}

func (m *Module) clientOrder(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
		return m.svc.ClientGetOrder(r.Context(), pr(r), id)
	})
}

func (m *Module) clientCancel(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
		return m.svc.ClientCancel(r.Context(), pr(r), id)
	})
}

func (m *Module) paymentURL(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (map[string]string, error) {
		u, err := m.svc.PaymentURL(r.Context(), pr(r), id)
		return map[string]string{"payment_url": u}, err
	})
}

// --------------------------------------------------------------- магазин

func (m *Module) getDelivery(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (delivery.Settings, error) {
		return m.delivery.GetSettings(r.Context(), pr(r), chi.URLParam(r, "id"))
	})
}

func (m *Module) saveDelivery(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in delivery.SettingsInput) (delivery.Settings, error) {
		return m.delivery.SaveSettings(r.Context(), pr(r), chi.URLParam(r, "id"), in)
	})
}

func (m *Module) listZones(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[delivery.Zone], error) {
		items, err := m.delivery.ListZones(r.Context(), pr(r), chi.URLParam(r, "id"))
		return httpx.List[delivery.Zone]{Items: items}, err
	})
}

func (m *Module) createZone(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in delivery.ZoneInput) (delivery.Zone, error) {
		return m.delivery.SaveZone(r.Context(), pr(r), chi.URLParam(r, "id"), "", in)
	})
}

func (m *Module) updateZone(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "zone", func(zone string, in delivery.ZoneInput) (delivery.Zone, error) {
		return m.delivery.SaveZone(r.Context(), pr(r), chi.URLParam(r, "id"), zone, in)
	})
}

func (m *Module) deleteZone(w http.ResponseWriter, r *http.Request) {
	zone, err := httpx.PathID(r, "zone")
	if err == nil {
		err = m.delivery.DeleteZone(r.Context(), pr(r), chi.URLParam(r, "id"), zone)
	}
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// slots — окна доставки ко времени на сегодня и ближайшие дни.
func (m *Module) slots(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (delivery.SlotsView, error) {
		return m.delivery.Slots(r.Context(), id)
	})
}

func (m *Module) storeList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Order], error) {
		from, to, err := finance.ParsePeriod(r)
		if err != nil {
			return httpx.List[Order]{}, err
		}
		items, err := m.svc.StoreList(r.Context(), pr(r), ListFilter{
			StoreID: q.Get("store_id"), Status: q.Get("status"), From: from, To: to, Sort: q.Get("sort"), Query: q.Get("q"),
			Page: httpx.PageFrom(r),
		})
		return httpx.List[Order]{Items: items}, err
	})
}

func (m *Module) storeGet(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
		return m.svc.StoreGet(r.Context(), pr(r), id)
	})
}

func (m *Module) act(fn func(context.Context, *identity.Principal, string) (Order, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
			return fn(r.Context(), pr(r), id)
		})
	}
}

func (m *Module) picked(w http.ResponseWriter, r *http.Request) {
	type body struct {
		Items []PickLine `json:"items"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in body) (Order, error) {
		return m.svc.Picked(r.Context(), pr(r), id, in.Items)
	})
}

type reasonBody struct {
	Reason string `json:"reason"`
}

func (m *Module) storeCancel(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in reasonBody) (Order, error) {
		return m.svc.StoreCancel(r.Context(), pr(r), id, in.Reason)
	})
}

func (m *Module) fiscal(w http.ResponseWriter, r *http.Request) {
	type body struct {
		FiscalNumber string `json:"fiscal_number"`
		FiscalSign   string `json:"fiscal_sign"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in body) (map[string]bool, error) {
		return map[string]bool{"registered": true}, m.svc.RegisterFiscal(r.Context(), pr(r), id, in.FiscalNumber, in.FiscalSign)
	})
}

// ----------------------------------------------------------- супер-админ

func (m *Module) adminList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Order], error) {
		from, to, err := finance.ParsePeriod(r)
		if err != nil {
			return httpx.List[Order]{}, err
		}
		items, err := m.svc.AdminList(r.Context(), AdminFilter{
			Status: q.Get("status"), Stale: q.Get("stale") == "true", Query: q.Get("q"),
			NetworkID: q.Get("network_id"), StoreID: q.Get("store_id"), Provider: q.Get("payment_provider"),
			From: from, To: to, Page: httpx.PageFrom(r),
		})
		return httpx.List[Order]{Items: items}, err
	})
}

func (m *Module) adminGet(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Order, error) {
		return m.svc.AdminGet(r.Context(), id)
	})
}

func (m *Module) adminCancel(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in reasonBody) (Order, error) {
		return m.svc.AdminCancel(r.Context(), id, in.Reason)
	})
}

func (m *Module) adminPayments(w http.ResponseWriter, r *http.Request) {
	page := httpx.PageFrom(r)
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[payments.Payment], error) {
		items, err := m.payments.List(r.Context(), r.URL.Query().Get("status"), page.Limit, page.Offset)
		return httpx.List[payments.Payment]{Items: items}, err
	})
}

func (m *Module) adminRefunded(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (map[string]bool, error) {
		return map[string]bool{"refunded": true}, m.payments.MarkRefunded(r.Context(), id)
	})
}

// ------------------------------------------------------------ курьеры

func (m *Module) storeCouriers(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Courier], error) {
		items, err := m.svc.StoreCouriers(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[Courier]{Items: items}, err
	})
}

func (m *Module) assignCourier(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in AssignInput) (Order, error) {
		return m.svc.AssignCourier(r.Context(), pr(r), id, in)
	})
}

func (m *Module) courierMe(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CourierMe, error) { return m.svc.CourierMe(r.Context(), pr(r)) })
}

func (m *Module) courierShift(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in ShiftInput) (CourierMe, error) {
		return m.svc.SetShift(r.Context(), pr(r), in)
	})
}

func (m *Module) courierLocation(w http.ResponseWriter, r *http.Request) {
	var in LocationInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	if err := m.svc.Location(r.Context(), pr(r), in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) courierOrders(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CourierOrder], error) {
		items, err := m.svc.CourierOrders(r.Context(), pr(r))
		return httpx.List[CourierOrder]{Items: items}, err
	})
}

func (m *Module) courierHistory(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CourierHistory, error) {
		return m.svc.CourierHistory(r.Context(), pr(r), r.URL.Query().Get("period"))
	})
}

func (m *Module) courierOrder(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CourierOrder, error) {
		return m.svc.CourierOrder(r.Context(), pr(r), id)
	})
}

func (m *Module) courierAct(fn func(context.Context, *identity.Principal, string) (CourierOrder, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CourierOrder, error) {
			return fn(r.Context(), pr(r), id)
		})
	}
}

func (m *Module) tracking(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Tracking, error) {
		return m.svc.ClientTracking(r.Context(), pr(r), id)
	})
}
func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func daysParam(r *http.Request) int {
	d, _ := strconv.Atoi(r.URL.Query().Get("days"))
	return d
}

func (m *Module) homeEvents(w http.ResponseWriter, r *http.Request) {
	var in HomeEventsInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	userID := ""
	if p := pr(r); p != nil {
		userID = p.UserID
	}
	if err := m.svc.RecordHomeEvents(r.Context(), in, userID); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) storeHomeStats(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (HomeStats, error) {
		return m.svc.StoreHomeStats(r.Context(), pr(r), storeParam(r), daysParam(r))
	})
}

func (m *Module) adminHomeStats(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (HomeStats, error) {
		return m.svc.AdminHomeStats(r.Context(), r.URL.Query().Get("network_id"), daysParam(r))
	})
}
