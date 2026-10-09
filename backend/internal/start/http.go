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
		r.Get("/search", m.search)
		r.Post("/tasnif/preview", m.tasnifPreview)
		r.Post("/tasnif", m.tasnifAdd)
		r.Get("/new-items", m.listNewItems)
		r.Post("/new-items", m.createNewItem)
		r.Get("/new-items/by-barcode", m.newItemByBarcode)
		r.Get("/new-items/{id}", m.getNewItem)
		r.Post("/new-items/{id}/merge", m.mergeNewItem)
		r.Post("/new-items/{id}/retry", m.retryNewItem)
		r.Post("/new-items/{id}/confirm", m.confirmNewItem)
		r.Delete("/new-items/{id}", m.deleteNewItem)
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

func (m *Module) search(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[SearchItem], error) {
		q := r.URL.Query()
		items, err := m.svc.Search(r.Context(), pr(r), SearchFilter{StoreID: q.Get("store_id"), Query: q.Get("q"), Page: httpx.PageFrom(r)})
		return httpx.List[SearchItem]{Items: items}, err
	})
}

func (m *Module) tasnifPreview(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in TasnifPreviewInput) (httpx.List[TasnifPreviewItem], error) {
		items, err := m.svc.Preview(r.Context(), pr(r), in)
		return httpx.List[TasnifPreviewItem]{Items: items}, err
	})
}

func (m *Module) tasnifAdd(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in TasnifAddInput) (TasnifAddResult, error) {
		return m.svc.AddTasnif(r.Context(), pr(r), in)
	})
}

// newURLs — ключи фото → ссылки.
func (m *Module) newURLs(r *http.Request, it NewItem) NewItem {
	for i, k := range it.Images {
		it.Images[i] = m.media.URL(r, k)
	}
	if it.Duplicate != nil && it.Duplicate.Image != nil {
		u := m.media.URL(r, *it.Duplicate.Image)
		it.Duplicate.Image = &u
	}
	return it
}

// NewItemLookup — GET /store/start/new-items/by-barcode: карточка с этим штрихкодом в «Новых» или null.
type NewItemLookup struct {
	Item *NewItem `json:"item"`
}

func (m *Module) newItemByBarcode(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (NewItemLookup, error) {
		q := r.URL.Query()
		it, err := m.svc.NewItemByBarcode(r.Context(), pr(r), q.Get("store_id"), q.Get("code"))
		if it != nil {
			u := m.newURLs(r, *it)
			it = &u
		}
		return NewItemLookup{Item: it}, err
	})
}

func (m *Module) mergeNewItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in NewItemMerge) (NewItem, error) {
		it, err := m.svc.MergeNewItem(r.Context(), pr(r), id, in)
		return m.newURLs(r, it), err
	})
}

func (m *Module) listNewItems(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (NewItemList, error) {
		l, err := m.svc.ListNewItems(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		for i := range l.Items {
			l.Items[i] = m.newURLs(r, l.Items[i])
		}
		return l, err
	})
}

func (m *Module) createNewItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in NewItemInput) (NewItem, error) {
		it, err := m.svc.CreateNewItem(r.Context(), pr(r), in)
		return m.newURLs(r, it), err
	})
}

func (m *Module) getNewItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (NewItem, error) {
		it, err := m.svc.GetNewItem(r.Context(), pr(r), id)
		return m.newURLs(r, it), err
	})
}

func (m *Module) retryNewItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusAccepted, "id", func(id string) (NewItem, error) {
		it, err := m.svc.RetryNewItem(r.Context(), pr(r), id)
		return m.newURLs(r, it), err
	})
}

func (m *Module) deleteNewItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (struct{}, error) {
		return struct{}{}, m.svc.DeleteNewItem(r.Context(), pr(r), id)
	})
}

func (m *Module) confirmNewItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in NewItemConfirm) (NewItemConfirmResult, error) {
		return m.svc.ConfirmNewItem(r.Context(), pr(r), id, in)
	})
}
