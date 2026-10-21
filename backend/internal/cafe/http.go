package cafe

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

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) Routes(r chi.Router) {
	r.Route("/store/cafe", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/settings", m.getSettings)
		r.Patch("/settings", m.updateSettings)

		r.Get("/workshops", m.listWorkshops)
		r.Post("/workshops", m.createWorkshop)
		r.Patch("/workshops/{id}", m.updateWorkshop)
		r.Delete("/workshops/{id}", m.deleteWorkshop)

		r.Get("/menu-groups", m.listGroups)
		r.Post("/menu-groups", m.createGroup)
		r.Patch("/menu-groups/{id}", m.updateGroup)
		r.Delete("/menu-groups/{id}", m.deleteGroup)

		r.Get("/dishes", m.listDishes)
		r.Post("/dishes", m.createDish)
		r.Get("/dishes/{id}", m.getDish)
		r.Patch("/dishes/{id}", m.updateDish)

		r.Get("/modifier-groups", m.listModifierGroups)
		r.Post("/modifier-groups", m.createModifierGroup)
		r.Patch("/modifier-groups/{id}", m.updateModifierGroup)
		r.Delete("/modifier-groups/{id}", m.deleteModifierGroup)

		r.Get("/production", m.listProduction)
		r.Post("/production", m.createProduction)
		r.Get("/production/{id}", m.getProduction)

		r.Get("/shortfalls", m.listShortfalls)
	})
}

func (m *Module) getSettings(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (Settings, error) { return m.svc.GetSettings(r.Context(), pr(r)) })
}

func (m *Module) updateSettings(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in SettingsInput) (Settings, error) {
		return m.svc.UpdateSettings(r.Context(), pr(r), in)
	})
}

func (m *Module) listWorkshops(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Workshop], error) {
		items, err := m.svc.ListWorkshops(r.Context(), pr(r))
		return httpx.List[Workshop]{Items: items}, err
	})
}

func (m *Module) createWorkshop(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in WorkshopInput) (Workshop, error) {
		return m.svc.CreateWorkshop(r.Context(), pr(r), in)
	})
}

func (m *Module) updateWorkshop(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in WorkshopInput) (Workshop, error) {
		return m.svc.UpdateWorkshop(r.Context(), pr(r), id, in)
	})
}

func (m *Module) deleteWorkshop(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteWorkshop(r.Context(), pr(r), id) })
}

func (m *Module) listGroups(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[MenuGroup], error) {
		items, err := m.svc.ListMenuGroups(r.Context(), pr(r))
		return httpx.List[MenuGroup]{Items: items}, err
	})
}

func (m *Module) createGroup(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in MenuGroupInput) (MenuGroup, error) {
		return m.svc.CreateMenuGroup(r.Context(), pr(r), in)
	})
}

func (m *Module) updateGroup(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in MenuGroupInput) (MenuGroup, error) {
		return m.svc.UpdateMenuGroup(r.Context(), pr(r), id, in)
	})
}

func (m *Module) deleteGroup(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteMenuGroup(r.Context(), pr(r), id) })
}

func (m *Module) listDishes(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Dish], error) {
		items, err := m.svc.ListDishes(r.Context(), pr(r), DishFilter{
			Kind: q.Get("kind"), Query: q.Get("q"), GroupID: q.Get("group_id"), StoreID: q.Get("store_id"),
			NoRecipe: q.Get("no_recipe") == "1" || q.Get("no_recipe") == "true",
			All:      q.Get("all") == "1" || q.Get("all") == "true",
			Page:     httpx.PageFrom(r),
		})
		return httpx.List[Dish]{Items: items}, err
	})
}

func (m *Module) createDish(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in DishInput) (Dish, error) {
		return m.svc.CreateDish(r.Context(), pr(r), in)
	})
}

func (m *Module) getDish(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Dish, error) { return m.svc.GetDish(r.Context(), pr(r), id) })
}

func (m *Module) updateDish(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in DishInput) (Dish, error) {
		return m.svc.UpdateDish(r.Context(), pr(r), id, in)
	})
}

func (m *Module) listModifierGroups(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[ModifierGroup], error) {
		items, err := m.svc.ListModifierGroups(r.Context(), pr(r))
		return httpx.List[ModifierGroup]{Items: items}, err
	})
}

func (m *Module) createModifierGroup(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in ModifierGroupInput) (ModifierGroup, error) {
		return m.svc.CreateModifierGroup(r.Context(), pr(r), in)
	})
}

func (m *Module) updateModifierGroup(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in ModifierGroupInput) (ModifierGroup, error) {
		return m.svc.UpdateModifierGroup(r.Context(), pr(r), id, in)
	})
}

func (m *Module) deleteModifierGroup(w http.ResponseWriter, r *http.Request) {
	httpx.Delete(w, r, m.log, func(id string) error { return m.svc.DeleteModifierGroup(r.Context(), pr(r), id) })
}

func (m *Module) listProduction(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Production], error) {
		items, err := m.svc.ListProduction(r.Context(), pr(r), ProductionFilter{
			StoreID: q.Get("store_id"), ProductID: q.Get("product_id"), Page: httpx.PageFrom(r),
		})
		return httpx.List[Production]{Items: items}, err
	})
}

func (m *Module) createProduction(w http.ResponseWriter, r *http.Request) {
	var in ProductionInput
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	d, created, err := m.svc.CreateProduction(r.Context(), pr(r), in)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, d)
}

func (m *Module) getProduction(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Production, error) {
		return m.svc.GetProduction(r.Context(), pr(r), id)
	})
}

func (m *Module) listShortfalls(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Shortfall], error) {
		items, err := m.svc.ListShortfalls(r.Context(), pr(r), r.URL.Query().Get("store_id"))
		return httpx.List[Shortfall]{Items: items}, err
	})
}
