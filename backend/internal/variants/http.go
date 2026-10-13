package variants

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
		r.Get("/admin/variant-groups", m.list)
		r.Post("/admin/variant-groups", m.create)
		r.Post("/admin/variant-groups/suggest", m.suggest)
		r.Get("/admin/variant-groups/suggest", m.suggestState)
		r.Get("/admin/variant-groups/{id}", m.get)
		r.Patch("/admin/variant-groups/{id}", m.update)
		r.Post("/admin/variant-groups/{id}/items", m.addItem)
		r.Post("/admin/variant-groups/{id}/split", m.split)
		r.Post("/admin/variant-groups/{id}/confirm", m.confirm)
		r.Post("/admin/variant-groups/{id}/reject", m.reject)
	})
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/variant-groups/{id}", m.storeGet)
		r.Post("/store/variant-groups/{id}/weight-price", m.weightPrice)
		r.Post("/store/variant-groups/{id}/own-price", m.ownPrice)
		// Группы своих товаров сети (вкладка «Вариации»).
		r.Get("/store/own-variant-groups", m.netList)
		r.Post("/store/own-variant-groups/suggest", m.netSuggest)
		r.Get("/store/own-variant-groups/suggest", m.netSuggestState)
		r.Get("/store/own-variant-groups/{id}", m.netGet)
		r.Patch("/store/own-variant-groups/{id}", m.netUpdate)
		r.Post("/store/own-variant-groups/{id}/items", m.netAddItem)
		r.Post("/store/own-variant-groups/{id}/split", m.netSplit)
		r.Post("/store/own-variant-groups/{id}/confirm", m.netConfirm)
		r.Post("/store/own-variant-groups/{id}/reject", m.netReject)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (GroupList, error) {
		q := r.URL.Query()
		return m.svc.List(r.Context(), ListFilter{Status: q.Get("status"), Query: q.Get("q"), Page: httpx.PageFrom(r)})
	})
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Group, error) {
		return m.svc.Get(r.Context(), id)
	})
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CreateInput) (Group, error) {
		return m.svc.Create(r.Context(), in)
	})
}

func (m *Module) suggest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SuggestInput) (SuggestStatus, error) {
		return m.svc.StartSuggest(r.Context(), in)
	})
}

func (m *Module) suggestState(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (SuggestStatus, error) {
		return m.svc.SuggestState(), nil
	})
}

func (m *Module) update(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in UpdateInput) (Group, error) {
		return m.svc.Update(r.Context(), id, in)
	})
}

func (m *Module) addItem(w http.ResponseWriter, r *http.Request) {
	type body struct {
		ProductID string `json:"product_id"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in body) (Group, error) {
		return m.svc.AddItem(r.Context(), id, in.ProductID)
	})
}

func (m *Module) split(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in SplitInput) (SplitResult, error) {
		return m.svc.Split(r.Context(), id, in)
	})
}

func (m *Module) confirm(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Group, error) {
		return m.svc.Confirm(r.Context(), id)
	})
}

func (m *Module) reject(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Group, error) {
		return m.svc.Reject(r.Context(), id)
	})
}

func (m *Module) storeGet(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (StoreGroup, error) {
		q := r.URL.Query()
		return m.svc.StoreGroup(r.Context(), pr(r), id, q.Get("store_id"), q.Get("price_type_id"))
	})
}

func (m *Module) weightPrice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in WeightPriceInput) (StoreGroup, error) {
		return m.svc.SetWeightPrice(r.Context(), pr(r), id, in)
	})
}

func (m *Module) ownPrice(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in OwnPriceInput) (StoreGroup, error) {
		return m.svc.SetOwnPrice(r.Context(), pr(r), id, in)
	})
}

// ---------------------------------------------------------- группы своих товаров сети

func (m *Module) netList(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (GroupList, error) {
		q := r.URL.Query()
		return m.svc.NetList(r.Context(), pr(r), ListFilter{Status: q.Get("status"), Query: q.Get("q"), Page: httpx.PageFrom(r)})
	})
}

func (m *Module) netSuggest(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (SuggestStatus, error) {
		p := pr(r)
		if err := p.Require(identity.PermCatalogManage); err != nil {
			return SuggestStatus{}, err
		}
		return m.svc.StartNetSuggest(r.Context(), p.NetworkID), nil
	})
}

func (m *Module) netSuggestState(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (SuggestStatus, error) {
		return m.svc.NetSuggestState(pr(r).NetworkID), nil
	})
}

func (m *Module) netGet(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Group, error) {
		return m.svc.NetGet(r.Context(), pr(r), id)
	})
}

func (m *Module) netUpdate(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in UpdateInput) (Group, error) {
		return m.svc.NetUpdate(r.Context(), pr(r), id, in)
	})
}

func (m *Module) netAddItem(w http.ResponseWriter, r *http.Request) {
	type body struct {
		ProductID string `json:"product_id"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in body) (Group, error) {
		return m.svc.NetAddItem(r.Context(), pr(r), id, in.ProductID)
	})
}

func (m *Module) netSplit(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in SplitInput) (SplitResult, error) {
		return m.svc.NetSplit(r.Context(), pr(r), id, in)
	})
}

func (m *Module) netConfirm(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Group, error) {
		return m.svc.NetConfirm(r.Context(), pr(r), id)
	})
}

func (m *Module) netReject(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Group, error) {
		return m.svc.NetReject(r.Context(), pr(r), id)
	})
}
