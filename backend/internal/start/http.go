package start

import (
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/media"
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
	r.Route("/store/start", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/", m.get)
		r.Post("/lines", m.lines)
		r.Delete("/lines/{product_id}", m.deleteLine)
		r.Post("/post", m.post)
		r.Get("/catalog", m.catalog)
		r.Get("/catalog/items", m.catalogItems)
		r.Post("/catalog/select", m.selectGroup)
		r.Post("/photos", m.createPhoto)
		r.Get("/photos/{id}", m.getPhoto)
		r.Post("/photos/{id}/retry", m.retryPhoto)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) urls(r *http.Request) func(Photo, error) (Photo, error) {
	return func(ph Photo, err error) (Photo, error) {
		for i, k := range ph.Images {
			ph.Images[i] = m.media.URL(r, k)
		}
		return ph, err
	}
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Draft, error) {
		q := r.URL.Query()
		f := Filter{Query: q.Get("q"), Only: q.Get("only")}
		f.Limit, _ = strconv.Atoi(q.Get("limit"))
		f.Offset, _ = strconv.Atoi(q.Get("offset"))
		return m.svc.Get(r.Context(), pr(r), q.Get("store_id"), f)
	})
}

func (m *Module) lines(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in LinesInput) (LinesResult, error) {
		return m.svc.SetLines(r.Context(), pr(r), in)
	})
}

func (m *Module) deleteLine(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "product_id", func(id string) (Totals, error) {
		return m.svc.DeleteLine(r.Context(), pr(r), r.URL.Query().Get("store_id"), id)
	})
}

type storeInput struct {
	StoreID string `json:"store_id"`
}

func (m *Module) post(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in storeInput) (PostResult, error) {
		return m.svc.Post(r.Context(), pr(r), in.StoreID)
	})
}

func (m *Module) createPhoto(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in PhotoInput) (Photo, error) {
		return m.urls(r)(m.svc.CreatePhoto(r.Context(), pr(r), in))
	})
}

func (m *Module) getPhoto(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Photo, error) {
		return m.urls(r)(m.svc.GetPhoto(r.Context(), pr(r), id))
	})
}

func (m *Module) retryPhoto(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusAccepted, "id", func(id string) (Photo, error) {
		return m.urls(r)(m.svc.RetryPhoto(r.Context(), pr(r), id))
	})
}

func (m *Module) catalog(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Catalog, error) {
		q := r.URL.Query()
		return m.svc.Catalog(r.Context(), pr(r), q.Get("store_id"), q.Get("q"))
	})
}

func (m *Module) catalogItems(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[CatalogItem], error) {
		q := r.URL.Query()
		items, err := m.svc.CatalogItems(r.Context(), pr(r), CatalogFilter{
			StoreID: q.Get("store_id"), Query: q.Get("q"), CategoryID: q.Get("category_id"), BrandID: q.Get("brand_id"),
			Page: httpx.PageFrom(r),
		})
		return httpx.List[CatalogItem]{Items: items}, err
	})
}

func (m *Module) selectGroup(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SelectInput) (SelectResult, error) {
		return m.svc.Select(r.Context(), pr(r), in)
	})
}
