package invoices

import (
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/media"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Module struct {
	svc   *Service
	media *media.Service
	auth  *identity.Authenticator
	log   *slog.Logger
}

func NewModule(svc *Service, mediaSvc *media.Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, media: mediaSvc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	r.Route("/store/invoice-scans", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore), m.auth.Feature(plans.FeatureInvoiceScans))
		r.Get("/", m.list)
		r.Post("/", m.create)
		r.Get("/{id}", m.get)
		r.Post("/{id}/retry", m.retry)
		r.Put("/{id}/supplier", m.supplier)
		r.Put("/{id}/lines/{line}", m.line)
		r.Get("/{id}/lines/{line}/suggestions", m.suggest)
		r.Post("/{id}/document", m.document)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

// urls — ключи фото → ссылки для приложения.
func (m *Module) urls(r *http.Request) func(Scan, error) (Scan, error) {
	return func(sc Scan, err error) (Scan, error) {
		for i, k := range sc.Images {
			sc.Images[i] = m.media.URL(r, k)
		}
		return sc, err
	}
}

func lineNo(r *http.Request) (int, error) {
	n, err := strconv.Atoi(chi.URLParam(r, "line"))
	if err != nil || n < 1 {
		return 0, apperr.NotFound("строка не найдена").Uz("qator topilmadi")
	}
	return n, nil
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Scan], error) {
		items, err := m.svc.List(r.Context(), pr(r), r.URL.Query().Get("store_id"), httpx.PageFrom(r))
		for i := range items {
			items[i], _ = m.urls(r)(items[i], nil)
		}
		return httpx.List[Scan]{Items: items}, err
	})
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in CreateInput) (Scan, error) {
		return m.urls(r)(m.svc.Create(r.Context(), pr(r), in))
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Scan, error) {
		return m.urls(r)(m.svc.Get(r.Context(), pr(r), id))
	})
}

func (m *Module) retry(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusAccepted, "id", func(id string) (Scan, error) {
		return m.urls(r)(m.svc.Retry(r.Context(), pr(r), id))
	})
}

func (m *Module) supplier(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in SupplierInput) (Scan, error) {
		return m.urls(r)(m.svc.SetSupplier(r.Context(), pr(r), id, in))
	})
}

func (m *Module) line(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in LineInput) (Scan, error) {
		n, err := lineNo(r)
		if err != nil {
			return Scan{}, err
		}
		return m.urls(r)(m.svc.SetLine(r.Context(), pr(r), id, n, in))
	})
}

func (m *Module) suggest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (httpx.List[Suggestion], error) {
		n, err := lineNo(r)
		if err != nil {
			return httpx.List[Suggestion]{}, err
		}
		items, err := m.svc.Suggest(r.Context(), pr(r), id, n, r.URL.Query().Get("q"))
		return httpx.List[Suggestion]{Items: items}, err
	})
}

func (m *Module) document(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "id", func(id string, in DocumentInput) (Scan, error) {
		return m.urls(r)(m.svc.CreateDocument(r.Context(), pr(r), id, in))
	})
}
