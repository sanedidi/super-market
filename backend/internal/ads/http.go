package ads

import (
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

func (m *Module) Routes(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/ads/settings", m.getSettings)
		r.Put("/admin/ads/settings", m.saveSettings)
		r.Get("/admin/ads/summary", m.summary)
		r.Get("/admin/ads/cities", m.cities)
		r.Get("/admin/ads/advertisers", m.advertisers)
		r.Post("/admin/ads/advertisers", m.saveAdvertiser)
		r.Patch("/admin/ads/advertisers/{id}", m.saveAdvertiser)
		r.Get("/admin/ads/campaigns", m.campaigns)
		r.Post("/admin/ads/campaigns", m.saveCampaign)
		r.Get("/admin/ads/campaigns/{id}", m.campaign)
		r.Patch("/admin/ads/campaigns/{id}", m.saveCampaign)
		r.Get("/admin/ads/campaigns/{id}/report", m.report)
		r.Get("/admin/ads/campaigns/{id}/estimate", m.estimate)
		r.Get("/admin/ads/invoices", m.invoices)
		r.Post("/admin/ads/invoices", m.createInvoice)
		r.Post("/admin/ads/invoices/{id}/paid", m.invoiceStatus("paid"))
		r.Post("/admin/ads/invoices/{id}/cancel", m.invoiceStatus("cancelled"))
		r.Get("/admin/ads/invoices/{id}/document", m.document)
	})
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.With(m.auth.Allow(identity.PermShowcaseManage)).Get("/store/ads", m.networkAds)
		r.With(m.auth.Allow(identity.PermShowcaseManage)).Put("/store/ads", m.saveNetworkAds)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) getSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return GetSettings(r.Context(), m.svc.pool) })
}

func (m *Module) saveSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SettingsInput) (Settings, error) {
		return m.svc.SaveSettings(r.Context(), in)
	})
}

func (m *Module) summary(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Summary, error) { return m.svc.Summary(r.Context()) })
}

func (m *Module) advertisers(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Advertiser], error) {
		items, err := m.svc.Advertisers(r.Context(), r.URL.Query().Get("q"), httpx.PageFrom(r))
		return httpx.List[Advertiser]{Items: items}, err
	})
}

func (m *Module) saveAdvertiser(w http.ResponseWriter, r *http.Request) {
	status := http.StatusOK
	if chi.URLParam(r, "id") == "" {
		status = http.StatusCreated
	}
	httpx.RespondBody(w, r, m.log, status, "", func(_ string, in AdvertiserInput) (Advertiser, error) {
		return m.svc.SaveAdvertiser(r.Context(), chi.URLParam(r, "id"), in)
	})
}

func (m *Module) campaigns(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Campaign], error) {
		items, err := m.svc.Campaigns(r.Context(), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[Campaign]{Items: items}, err
	})
}

func (m *Module) campaign(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Campaign, error) { return m.svc.Campaign(r.Context(), id) })
}

func (m *Module) saveCampaign(w http.ResponseWriter, r *http.Request) {
	status := http.StatusOK
	if chi.URLParam(r, "id") == "" {
		status = http.StatusCreated
	}
	httpx.RespondBody(w, r, m.log, status, "", func(_ string, in CampaignInput) (Campaign, error) {
		return m.svc.SaveCampaign(r.Context(), chi.URLParam(r, "id"), in)
	})
}

func (m *Module) report(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[NetworkRow], error) {
		items, err := m.svc.CampaignReport(r.Context(), id)
		return httpx.List[NetworkRow]{Items: items}, err
	})
}

func (m *Module) estimate(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Estimate, error) {
		return m.svc.Estimate(r.Context(), id, r.URL.Query().Get("from"), r.URL.Query().Get("to"))
	})
}

func (m *Module) invoices(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Invoice], error) {
		q := r.URL.Query()
		items, err := m.svc.Invoices(r.Context(), q.Get("campaign_id"), q.Get("status"), httpx.PageFrom(r))
		return httpx.List[Invoice]{Items: items}, err
	})
}

func (m *Module) createInvoice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in InvoiceInput) (Invoice, error) {
		return m.svc.CreateInvoice(r.Context(), in)
	})
}

func (m *Module) invoiceStatus(status string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Invoice, error) {
			return m.svc.SetInvoiceStatus(r.Context(), id, status)
		})
	}
}

func (m *Module) document(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Document, error) {
		return m.svc.Document(r.Context(), id, r.URL.Query().Get("kind"))
	})
}

func (m *Module) networkAds(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (NetworkAds, error) { return m.svc.NetworkAds(r.Context(), pr(r).NetworkID) })
}

func (m *Module) saveNetworkAds(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in NetworkAdsInput) (NetworkAds, error) {
		return m.svc.SaveNetworkAds(r.Context(), pr(r).NetworkID, in)
	})
}

func (m *Module) cities(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[string], error) {
		items, err := m.svc.Cities(r.Context())
		return httpx.List[string]{Items: items}, err
	})
}
