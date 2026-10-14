package ai

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Module struct {
	svc   *Service
	photo *PhotoService
	auth  *identity.Authenticator
	log   *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

// WithPhoto — маршруты «ИИ для фото» (Gemini).
func (m *Module) WithPhoto(p *PhotoService) *Module {
	m.photo = p
	return m
}

func (m *Module) Routes(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/ai", m.get)
		r.Put("/admin/ai", m.save)
		r.Post("/admin/ai/models", m.models)
		r.Post("/admin/ai/test", m.test)
		r.Get("/admin/ai/usage", m.usage)
		r.Put("/admin/ai/prices", m.savePrices)
		if m.photo != nil {
			r.Get("/admin/ai-photo", m.photoGet)
			r.Put("/admin/ai-photo", m.photoSave)
			r.Put("/admin/ai-photo/store", m.photoSaveStore)
			r.Post("/admin/ai-photo/models", m.photoModels)
			r.Post("/admin/ai-photo/test", m.photoTest)
			r.Post("/admin/ai-photo/normalize", m.photoNormalize)
			r.Get("/admin/ai-photo/jobs/{id}", m.photoJob)
			// Фото магазинов — результаты.
			r.Get("/admin/ai-photo/store/summary", m.storeSummary)
			r.Get("/admin/ai-photo/store/jobs", m.storeJobs)
			r.Get("/admin/ai-photo/store/jobs/{id}", m.storeJob)
			r.Post("/admin/ai-photo/store/jobs/{id}/retry", m.storeJobRetry)
			r.Post("/admin/ai-photo/store/jobs/{id}/redo", m.storeJobRedo)
			r.Post("/admin/ai-photo/store/retry-failed", m.storeRetryFailed)
		}
	})
	// Автоперевод двуязычных полей: панель и приложение магазина, супер-админ.
	r.With(m.auth.Require(identity.AppStore, identity.AppAdmin)).Post("/translate", m.translate)
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.Get(r.Context()) })
}

func (m *Module) save(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Input) (Settings, error) {
		return m.svc.Save(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}

func (m *Module) models(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Input) (httpx.List[Model], error) {
		items, err := m.svc.Models(r.Context(), in)
		return httpx.List[Model]{Items: items}, err
	})
}

func (m *Module) test(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Input) (TestResult, error) {
		return m.svc.Test(r.Context(), in)
	})
}

func (m *Module) usage(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (UsageReport, error) {
		q := r.URL.Query()
		f := UsageFilter{Group: q.Get("group"), NetworkID: q.Get("network_id")}
		for _, p := range []struct {
			name string
			dst  *time.Time
		}{{"from", &f.From}, {"to", &f.To}} {
			if v := q.Get(p.name); v != "" {
				t, err := time.ParseInLocation("2006-01-02", v, tashkent)
				if err != nil {
					return UsageReport{}, apperr.Validation(p.name + ": ожидается дата YYYY-MM-DD").Uz(p.name + ": sana YYYY-MM-DD koʻrinishida boʻlsin")
				}
				*p.dst = t
			}
		}
		if f.NetworkID != "" {
			if !httpx.IsUUID(f.NetworkID) {
				return UsageReport{}, apperr.Validation("network_id: неверный id").Uz("network_id: id notoʻgʻri")
			}
		}
		return m.svc.Usage(r.Context(), f)
	})
}

func (m *Module) savePrices(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in Prices) (Prices, error) {
		return m.svc.SavePrices(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}

// ------------------------------------------------------------ ИИ для фото

func (m *Module) photoGet(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (PhotoSettings, error) { return m.photo.Get(r.Context()) })
}

func (m *Module) photoSave(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in PhotoInput) (PhotoSettings, error) {
		return m.photo.Save(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}

// photoSaveStore — блок «Фото для магазинов».
func (m *Module) photoSaveStore(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in StoreSettingsInput) (PhotoSettings, error) {
		return m.photo.SaveStore(r.Context(), identity.FromContext(r.Context()).UserID, in)
	})
}

func (m *Module) photoModels(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in PhotoInput) (httpx.List[Model], error) {
		items, err := m.photo.Models(r.Context(), in)
		return httpx.List[Model]{Items: items}, err
	})
}

// photoTest и photoNormalize отвечают заданием сразу; готово — GET /admin/ai-photo/jobs/{id}.
func (m *Module) photoTest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in PhotoInput) (PhotoJob, error) {
		return m.photo.TestPhoto(r.Context(), in, m.photo.media.URL(r, ""))
	})
}

func (m *Module) photoNormalize(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in NormalizeInput) (PhotoJob, error) {
		return m.photo.Normalize(r.Context(), in, m.photo.media.URL(r, ""))
	})
}

func (m *Module) photoJob(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (PhotoJob, error) { return m.photo.Job(chi.URLParam(r, "id")) })
}

// ------------------------------------------------------------ Фото магазинов

func (m *Module) storeSummary(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (StoreSummary, error) {
		return m.photo.StoreSummary(r.Context(), r.URL.Query().Get("month"))
	})
}

func (m *Module) storeJobs(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (StoreJobsPage, error) {
		q := r.URL.Query()
		p := httpx.PageFrom(r)
		f := StoreJobsFilter{Month: q.Get("month"), Status: q.Get("status"), NetworkID: q.Get("network_id"), Kind: q.Get("kind"),
			Code: q.Get("code"), Query: q.Get("q"), Limit: p.Limit, Offset: p.Offset}
		if f.NetworkID != "" && !httpx.IsUUID(f.NetworkID) {
			return StoreJobsPage{}, apperr.Validation("network_id: неверный id").Uz("network_id: id notoʻgʻri")
		}
		page, err := m.photo.StoreJobs(r.Context(), f)
		for i := range page.Items {
			page.Items[i] = m.photo.StoreJobURLs(r, page.Items[i])
		}
		return page, err
	})
}

func (m *Module) storeJob(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (StoreJobRow, error) {
		j, err := m.photo.StoreJob(r.Context(), id)
		return m.photo.StoreJobURLs(r, j), err
	})
}

// storeJobRetry — «Повторить»: неудачное фото снова в очередь.
func (m *Module) storeJobRetry(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (StoreJobRow, error) {
		j, err := m.photo.RetryStoreJob(r.Context(), id)
		return m.photo.StoreJobURLs(r, j), err
	})
}

// storeJobRedo — «Переделать» готовое фото (новое задание, идёт в лимит сети).
func (m *Module) storeJobRedo(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusAccepted, "id", func(id string) (StoreJobRow, error) {
		j, err := m.photo.RedoStoreJob(r.Context(), id)
		return m.photo.StoreJobURLs(r, j), err
	})
}

// storeRetryFailed — «Повторить неудачные» за месяц (по причине, сети).
func (m *Module) storeRetryFailed(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in RetryFailedInput) (RetryFailedResult, error) {
		if in.NetworkID != "" && !httpx.IsUUID(in.NetworkID) {
			return RetryFailedResult{}, apperr.Validation("network_id: неверный id").Uz("network_id: id notoʻgʻri")
		}
		return m.photo.RetryFailed(r.Context(), in)
	})
}
