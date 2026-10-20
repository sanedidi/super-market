package start

import (
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/ai"
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
		r.Post("/group-price", m.groupPrice)
		r.Post("/lines/{product_id}/own-price", m.ownPrice)
		r.Delete("/lines/{product_id}", m.deleteLine)
		r.Post("/post", m.post)
		r.Get("/search", m.search)
		r.Get("/scan", m.scan)
		r.Post("/step", m.setStep)
		r.Post("/mode", m.setMode)
		r.Get("/count", m.countSummary)
		r.Get("/count/items", m.countItems)
		r.Get("/count/categories", m.countCategories)
		r.Post("/count", m.count)
		r.Post("/fill", m.fill)
		r.Post("/lines/{product_id}/photo", m.linePhoto)
		r.Post("/tasnif/preview", m.tasnifPreview)
		r.Post("/tasnif", m.tasnifAdd)
		r.Get("/new-items", m.listNewItems)
		r.Post("/new-items", m.createNewItem)
		r.Get("/new-items/by-barcode", m.newItemByBarcode)
		r.Post("/new-items/confirm-all", m.confirmAllNewItems)
		r.Post("/new-items/retry-all", m.retryAllNewItems)
		r.Get("/new-items/{id}", m.getNewItem)
		r.Post("/new-items/{id}/merge", m.mergeNewItem)
		r.Post("/new-items/{id}/retry", m.retryNewItem)
		r.Post("/new-items/{id}/photo", m.redoNewItemPhoto)
		r.Get("/photo-quota", m.photoQuota)
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
		f := Filter{Query: q.Get("q"), Only: q.Get("only"), Order: q.Get("order")}
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
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in PostInput) (PostResult, error) {
		return m.svc.Post(r.Context(), pr(r), in)
	})
}

type modeInput struct {
	StoreID string `json:"store_id"`
	Mode    string `json:"mode"`
}

func (m *Module) setMode(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in modeInput) (Draft, error) {
		return m.svc.SetMode(r.Context(), pr(r), in.StoreID, in.Mode)
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
	if it.Photo != nil && it.Photo.Image != nil {
		u := m.media.URL(r, *it.Photo.Image)
		it.Photo.Image = &u
	}
	return it
}

// redoNewItemPhoto — «Переделать»: Super Market делает фото карточки ещё раз.
func (m *Module) redoNewItemPhoto(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusAccepted, "id", func(id string) (NewItem, error) {
		it, err := m.svc.RedoNewItemPhoto(r.Context(), pr(r), id)
		return m.newURLs(r, it), err
	})
}

// photoQuota — GET /store/start/photo-quota: фото Super Market в этом месяце.
func (m *Module) photoQuota(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ai.StoreQuota, error) {
		return m.svc.PhotoQuota(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
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
		// Без limit — первые 200, как раньше (старые версии «SM Магазин»).
		page := httpx.PageFrom(r)
		if !r.URL.Query().Has("limit") {
			page.Limit = 200
		}
		l, err := m.svc.ListNewItems(r.Context(), pr(r), r.URL.Query().Get("store_id"), page)
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

func (m *Module) confirmAllNewItems(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in NewItemsBulkInput) (NewItemsBulk, error) {
		return m.svc.ConfirmAllNewItems(r.Context(), pr(r), in)
	})
}

func (m *Module) scan(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (ScanResult, error) {
		q := r.URL.Query()
		return m.svc.Scan(r.Context(), pr(r), q.Get("store_id"), q.Get("code"))
	})
}

type stepInput struct {
	StoreID string `json:"store_id"`
	Step    int    `json:"step"`
}

func (m *Module) setStep(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in stepInput) (Draft, error) {
		return m.svc.SetStep(r.Context(), pr(r), in.StoreID, in.Step)
	})
}

type linePhotoInput struct {
	StoreID string   `json:"store_id"`
	Images  []string `json:"images"`
}

func (m *Module) linePhoto(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "product_id", func(id string, in linePhotoInput) (LinesResult, error) {
		return m.svc.SetPhoto(r.Context(), pr(r), in.StoreID, id, in.Images)
	})
}

func (m *Module) groupPrice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in GroupPriceInput) (LinesResult, error) {
		return m.svc.SetGroupPrice(r.Context(), pr(r), in)
	})
}

func (m *Module) ownPrice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "product_id", func(id string, in OwnPriceInput) (LinesResult, error) {
		return m.svc.SetOwnPrice(r.Context(), pr(r), id, in)
	})
}

func (m *Module) retryAllNewItems(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusAccepted, "", func(_ string, in RetryAllInput) (RetryAllResult, error) {
		return m.svc.RetryAllNewItems(r.Context(), pr(r), in)
	})
}

func (m *Module) countSummary(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CountSummary, error) {
		return m.svc.CountSummary(r.Context(), pr(r), r.URL.Query().Get("store_id"))
	})
}

func (m *Module) countItems(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (CountItems, error) {
		q := r.URL.Query()
		f := CountFilter{Set: q.Get("set"), CategoryID: q.Get("category_id"), ProductID: q.Get("product_id"), Query: q.Get("q")}
		for _, id := range strings.Split(q.Get("product_ids"), ",") {
			if id = strings.TrimSpace(id); id != "" {
				f.ProductIDs = append(f.ProductIDs, id)
			}
		}
		f.Limit, _ = strconv.Atoi(q.Get("limit"))
		f.Offset, _ = strconv.Atoi(q.Get("offset"))
		return m.svc.CountItems(r.Context(), pr(r), q.Get("store_id"), f)
	})
}

type countCategoriesOut struct {
	Items []CountCategory `json:"items"`
}

func (m *Module) countCategories(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (countCategoriesOut, error) {
		items, err := m.svc.CountCategories(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return countCategoriesOut{Items: items}, err
	})
}

func (m *Module) fill(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in FillInput) (FillResult, error) {
		return m.svc.Fill(r.Context(), pr(r), in)
	})
}

func (m *Module) count(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in CountInput) (CountResult, error) {
		return m.svc.Count(r.Context(), pr(r), in)
	})
}
