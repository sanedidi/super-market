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

	// Курьер (приложение курьера, вход как сотрудник магазина).
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/courier/me", m.courierMe)
		r.Post("/courier/shift", m.courierShift)
		r.Post("/courier/location", m.courierLocation)
		r.Get("/courier/orders", m.courierOrders)
		r.Get("/courier/orders/{id}", m.courierOrder)
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
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

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
