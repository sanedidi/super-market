package orders

import (
	"context"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// crowdRoutes — маршруты crowd-доставки: курьер «по пути», магазин, супер-админ.
func (m *Module) crowdRoutes(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppCrowd))
		r.Get("/crowd/me", m.crowdMe)
		r.Put("/crowd/me", m.crowdUpdateMe)
		r.Put("/crowd/route", m.crowdRoute)
		r.Post("/crowd/location", m.crowdLocation)
		r.Get("/crowd/points", m.crowdPoints)
		r.Get("/crowd/offers", m.crowdOffers)
		r.Post("/crowd/offers/{id}/accept", m.crowdAct(m.svc.CrowdAccept))
		r.Get("/crowd/orders", m.crowdOrders)
		r.Get("/crowd/orders/{id}", m.crowdAct(m.svc.CrowdGetOrder))
		r.Post("/crowd/orders/{id}/release", m.crowdAct(m.svc.CrowdRelease))
		r.Post("/crowd/orders/{id}/deliver", m.crowdDeliver)
		r.Post("/crowd/orders/{id}/problem", m.crowdProblem)
		r.Get("/crowd/earnings", m.crowdEarnings)
	})
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Post("/store/crowd/lookup", m.storeCrowdLookup)
		r.Post("/store/crowd/verify", m.storeCrowdVerify)
		r.Get("/store/crowd/bonuses", m.storeCrowdBonuses)
		r.Post("/store/orders/{id}/crowd-handover", m.storeCrowdHandover)
		r.Post("/store/orders/{id}/crowd-release", m.act(m.svc.CrowdStoreRelease))
	})
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/crowd/overview", m.adminCrowdOverview)
		r.Get("/admin/crowd/couriers", m.adminCrowdCouriers)
		r.Post("/admin/crowd/couriers/{id}/block", m.adminCrowdBlock)
		r.Post("/admin/crowd/couriers/{id}/unblock", m.adminCrowdUnblock)
		r.Get("/admin/crowd/incidents", m.adminCrowdIncidents)
		r.Post("/admin/crowd/incidents/{id}/resolve", m.adminCrowdResolve)
		r.Get("/admin/crowd/payouts", m.adminCrowdPayouts)
		r.Post("/admin/crowd/payouts", m.adminCrowdPay)
		r.Get("/admin/crowd/settings", m.adminCrowdSettings)
		r.Put("/admin/crowd/settings", m.adminCrowdSaveSettings)
		r.Get("/admin/crowd/stores", m.adminCrowdStores)
		r.Put("/admin/crowd/stores/{id}", m.adminCrowdSetStore)
	})
}

// floatParams — необязательные lat/lng из строки запроса.
func floatParams(r *http.Request) (*float64, *float64, error) {
	qs := r.URL.Query()
	if qs.Get("lat") == "" && qs.Get("lng") == "" {
		return nil, nil, nil
	}
	lat, err1 := strconv.ParseFloat(qs.Get("lat"), 64)
	lng, err2 := strconv.ParseFloat(qs.Get("lng"), 64)
	if err1 != nil || err2 != nil {
		return nil, nil, apperr.Validation("lat/lng: неверные координаты")
	}
	return &lat, &lng, nil
}

func (m *Module) crowdMe(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CrowdMe, error) { return m.svc.CrowdMe(r.Context(), pr(r)) })
}

func (m *Module) crowdUpdateMe(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CrowdProfileInput) (CrowdMe, error) {
		return m.svc.CrowdUpdateMe(r.Context(), pr(r), in)
	})
}

func (m *Module) crowdRoute(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CrowdRouteInput) (CrowdMe, error) {
		return m.svc.CrowdSetRoute(r.Context(), pr(r), in)
	})
}

func (m *Module) crowdLocation(w http.ResponseWriter, r *http.Request) {
	var in LocationInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	if err := m.svc.CrowdLocation(r.Context(), pr(r), in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) crowdPoints(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CrowdPoint], error) {
		lat, lng, err := floatParams(r)
		if err != nil {
			return httpx.List[CrowdPoint]{}, err
		}
		items, err := m.svc.CrowdPoints(r.Context(), pr(r), lat, lng)
		return httpx.List[CrowdPoint]{Items: items}, err
	})
}

func (m *Module) crowdOffers(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CrowdFeed, error) {
		lat, lng, err := floatParams(r)
		if err != nil {
			return CrowdFeed{}, err
		}
		return m.svc.CrowdOffers(r.Context(), pr(r), lat, lng)
	})
}

func (m *Module) crowdAct(fn func(context.Context, *identity.Principal, string) (CrowdOrder, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CrowdOrder, error) {
			return fn(r.Context(), pr(r), id)
		})
	}
}

func (m *Module) crowdOrders(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CrowdOrder], error) {
		items, err := m.svc.CrowdOrders(r.Context(), pr(r))
		return httpx.List[CrowdOrder]{Items: items}, err
	})
}

func (m *Module) crowdDeliver(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CrowdDeliverInput) (CrowdOrder, error) {
		return m.svc.CrowdDeliver(r.Context(), pr(r), id, in)
	})
}

func (m *Module) crowdProblem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CrowdProblemInput) (CrowdOrder, error) {
		return m.svc.CrowdProblem(r.Context(), pr(r), id, in)
	})
}

func (m *Module) crowdEarnings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CrowdEarnings, error) { return m.svc.CrowdEarnings(r.Context(), pr(r)) })
}

// --------------------------------------------------------------- магазин

func (m *Module) storeCrowdLookup(w http.ResponseWriter, r *http.Request) {
	type body struct {
		Code string `json:"code"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in body) (CrowdCourierCard, error) {
		return m.svc.CrowdLookup(r.Context(), pr(r), in.Code)
	})
}

func (m *Module) storeCrowdVerify(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CrowdVerifyInput) (CrowdCourierCard, error) {
		return m.svc.CrowdVerify(r.Context(), pr(r), in)
	})
}

func (m *Module) storeCrowdBonuses(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (StoreCrowdBonuses, error) {
		return m.svc.StoreCrowdBonuses(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) storeCrowdHandover(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CrowdHandoverInput) (Order, error) {
		return m.svc.CrowdHandover(r.Context(), pr(r), id, in)
	})
}

// ------------------------------------------------------------ супер-админ

func (m *Module) adminCrowdOverview(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CrowdOverview, error) { return m.svc.AdminCrowdOverview(r.Context()) })
}

func (m *Module) adminCrowdCouriers(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[AdminCrowdCourier], error) {
		items, err := m.svc.AdminCrowdCouriers(r.Context(), AdminCrowdFilter{
			Status: r.URL.Query().Get("status"), Query: r.URL.Query().Get("q"), Page: httpx.PageFrom(r)})
		return httpx.List[AdminCrowdCourier]{Items: items}, err
	})
}

func (m *Module) adminCrowdBlock(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CrowdBlockInput) (map[string]bool, error) {
		return map[string]bool{"ok": true}, m.svc.AdminCrowdBlock(r.Context(), pr(r), id, in)
	})
}

func (m *Module) adminCrowdUnblock(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (map[string]bool, error) {
		return map[string]bool{"ok": true}, m.svc.AdminCrowdUnblock(r.Context(), id)
	})
}

func (m *Module) adminCrowdIncidents(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[AdminCrowdIncident], error) {
		items, err := m.svc.AdminCrowdIncidents(r.Context(), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[AdminCrowdIncident]{Items: items}, err
	})
}

func (m *Module) adminCrowdResolve(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CrowdResolveInput) (map[string]bool, error) {
		return map[string]bool{"ok": true}, m.svc.AdminCrowdResolve(r.Context(), pr(r), id, in)
	})
}

func (m *Module) adminCrowdPayouts(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CrowdPayout], error) {
		items, err := m.svc.AdminCrowdPayouts(r.Context())
		return httpx.List[CrowdPayout]{Items: items}, err
	})
}

func (m *Module) adminCrowdPay(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CrowdPayInput) (map[string]int, error) {
		n, err := m.svc.AdminCrowdPay(r.Context(), pr(r), in)
		return map[string]int{"paid": n}, err
	})
}

func (m *Module) adminCrowdSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CrowdSettings, error) { return m.svc.AdminCrowdSettings(r.Context()) })
}

func (m *Module) adminCrowdSaveSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CrowdSettings) (CrowdSettings, error) {
		return m.svc.AdminCrowdSaveSettings(r.Context(), in)
	})
}

func (m *Module) adminCrowdStores(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[AdminCrowdStore], error) {
		items, err := m.svc.AdminCrowdStores(r.Context(), r.URL.Query().Get("q"), httpx.PageFrom(r))
		return httpx.List[AdminCrowdStore]{Items: items}, err
	})
}

func (m *Module) adminCrowdSetStore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CrowdStoreInput) (map[string]bool, error) {
		return map[string]bool{"ok": true}, m.svc.AdminCrowdSetStore(r.Context(), id, in)
	})
}
