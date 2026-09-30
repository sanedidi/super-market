package tenant

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
		r.Get("/admin/networks", m.listNetworks)
		r.Post("/admin/networks", m.createNetwork)
		r.Get("/admin/networks/{id}", m.getNetwork)
		r.Patch("/admin/networks/{id}", m.updateNetwork)
	})

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/me", m.me)
		r.Get("/store/stores", m.listStores)
		r.Post("/store/stores", m.createStore)
		r.Get("/store/stores/{id}", m.getStore)
		r.Patch("/store/stores/{id}", m.updateStore)
		r.Get("/store/warehouses", m.listWarehouses)
		r.Post("/store/warehouses", m.createWarehouse)
		r.Patch("/store/warehouses/{id}", m.updateWarehouse)
	})
}

// handle — общий каркас: вызвать fn, при ошибке ответить ошибкой,
// иначе отдать результат с кодом status.
func handle[T any](m *Module, w http.ResponseWriter, r *http.Request, status int, fn func() (T, error)) {
	v, err := fn()
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.WriteJSON(w, status, v)
}

// withBody декодирует тело и ID из пути (если idParam не пуст).
func withBody[In any, T any](m *Module, w http.ResponseWriter, r *http.Request, status int, idParam string,
	fn func(id string, in In) (T, error)) {
	var id string
	if idParam != "" {
		var err error
		if id, err = httpx.PathID(r, idParam); err != nil {
			httpx.Fail(w, r, m.log, err)
			return
		}
	}
	var in In
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	handle(m, w, r, status, func() (T, error) { return fn(id, in) })
}

type list[T any] struct {
	Items []T `json:"items"`
}

// ------------------------------------------------------------ супер-админ

func (m *Module) listNetworks(w http.ResponseWriter, r *http.Request) {
	handle(m, w, r, http.StatusOK, func() (list[Network], error) {
		items, err := m.svc.ListNetworks(r.Context(), r.URL.Query().Get("q"), httpx.PageFrom(r))
		return list[Network]{items}, err
	})
}

func (m *Module) createNetwork(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusCreated, "", func(_ string, in CreateNetworkInput) (Network, error) {
		return m.svc.CreateNetwork(r.Context(), in)
	})
}

func (m *Module) getNetwork(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	handle(m, w, r, http.StatusOK, func() (Network, error) { return m.svc.GetNetwork(r.Context(), id) })
}

func (m *Module) updateNetwork(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusOK, "id", func(id string, in UpdateNetworkInput) (Network, error) {
		return m.svc.UpdateNetwork(r.Context(), id, in)
	})
}

// --------------------------------------------------------- панель магазина

type meResponse struct {
	UserID      string   `json:"user_id"`
	EmployeeID  string   `json:"employee_id"`
	Network     Network  `json:"network"`
	IsOwner     bool     `json:"is_owner"`
	Permissions []string `json:"permissions"`
	AllStores   bool     `json:"all_stores"`
	StoreIDs    []string `json:"store_ids"`
}

func (m *Module) me(w http.ResponseWriter, r *http.Request) {
	p := identity.FromContext(r.Context())
	handle(m, w, r, http.StatusOK, func() (meResponse, error) {
		n, err := m.svc.GetNetwork(r.Context(), p.NetworkID)
		perms := p.Permissions
		if p.IsOwner {
			perms = make([]string, 0, len(identity.Permissions))
			for _, pi := range identity.Permissions {
				perms = append(perms, pi.Code)
			}
		}
		return meResponse{
			UserID: p.UserID, EmployeeID: p.EmployeeID, Network: n, IsOwner: p.IsOwner,
			Permissions: perms, AllStores: p.SeesAllStores(), StoreIDs: p.StoreIDs,
		}, err
	})
}

func (m *Module) listStores(w http.ResponseWriter, r *http.Request) {
	handle(m, w, r, http.StatusOK, func() (list[Store], error) {
		items, err := m.svc.ListStores(r.Context(), identity.FromContext(r.Context()))
		return list[Store]{httpx.PageSlice(r, items)}, err
	})
}

func (m *Module) createStore(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusCreated, "", func(_ string, in StoreInput) (Store, error) {
		return m.svc.CreateStore(r.Context(), identity.FromContext(r.Context()), in)
	})
}

func (m *Module) getStore(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	handle(m, w, r, http.StatusOK, func() (Store, error) {
		return m.svc.GetStore(r.Context(), identity.FromContext(r.Context()), id)
	})
}

func (m *Module) updateStore(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusOK, "id", func(id string, in StoreInput) (Store, error) {
		return m.svc.UpdateStore(r.Context(), identity.FromContext(r.Context()), id, in)
	})
}

func (m *Module) listWarehouses(w http.ResponseWriter, r *http.Request) {
	handle(m, w, r, http.StatusOK, func() (list[Warehouse], error) {
		items, err := m.svc.ListWarehouses(r.Context(), identity.FromContext(r.Context()), r.URL.Query().Get("store_id"))
		return list[Warehouse]{httpx.PageSlice(r, items)}, err
	})
}

func (m *Module) createWarehouse(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusCreated, "", func(_ string, in WarehouseInput) (Warehouse, error) {
		return m.svc.CreateWarehouse(r.Context(), identity.FromContext(r.Context()), in)
	})
}

func (m *Module) updateWarehouse(w http.ResponseWriter, r *http.Request) {
	withBody(m, w, r, http.StatusOK, "id", func(id string, in WarehouseInput) (Warehouse, error) {
		return m.svc.UpdateWarehouse(r.Context(), identity.FromContext(r.Context()), id, in)
	})
}
