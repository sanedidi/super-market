// Package planapi — HTTP тарифов: настройка супер-админом, «мой тариф» в
// панели магазина, тарифы для сайта. Логика — в пакете plans.
package planapi

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/plans"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

type Module struct {
	pool *pgxpool.Pool
	auth *identity.Authenticator
	log  *slog.Logger
	// changed — после правки тарифа (сбросить кэши витрины и т. п.).
	changed func()
}

func NewModule(pool *pgxpool.Pool, auth *identity.Authenticator, log *slog.Logger, changed func()) *Module {
	if changed == nil {
		changed = func() {}
	}
	return &Module{pool: pool, auth: auth, log: log, changed: changed}
}

func (m *Module) Routes(r chi.Router) {
	// Тарифы для сайта super-market.uz — без входа.
	r.Get("/public/tariffs", m.public)

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppStore))
		r.Get("/store/plan", m.mine)
		r.Post("/store/plan", m.choose)
	})

	r.Route("/admin/plans", func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/", m.list)
		r.Post("/", m.create)
		r.Get("/registry", m.registry)
		r.Get("/{key}", m.get)
		r.Patch("/{key}", m.update)
		r.Delete("/{key}", m.delete)
	})
}

func pr(r *http.Request) *identity.Principal { return identity.FromContext(r.Context()) }

func (m *Module) public(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=300")
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[plans.View], error) {
		items, err := plans.Views(r.Context(), m.pool)
		return httpx.List[plans.View]{Items: items}, err
	})
}

func (m *Module) mine(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (plans.Mine, error) {
		p := pr(r)
		return plans.ForStore(r.Context(), m.pool, p.NetworkID, p.Can(identity.PermPayoutsManage))
	})
}

type chooseBody struct {
	Plan string `json:"plan"`
}

// choose — сеть меняет тариф сама (владелец или сотрудник с правом на деньги).
func (m *Module) choose(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in chooseBody) (plans.Mine, error) {
		p := pr(r)
		if err := p.Require(identity.PermPayoutsManage); err != nil {
			return plans.Mine{}, err
		}
		if _, err := plans.Choose(r.Context(), m.pool, p.NetworkID, in.Plan); err != nil {
			return plans.Mine{}, err
		}
		m.changed()
		return plans.ForStore(r.Context(), m.pool, p.NetworkID, true)
	})
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[plans.Plan], error) {
		items, err := plans.List(r.Context(), m.pool, false)
		return httpx.List[plans.Plan]{Items: items}, err
	})
}

func (m *Module) registry(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (plans.Registry, error) { return plans.GetRegistry(), nil })
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (plans.Plan, error) {
		return plans.Get(r.Context(), m.pool, chi.URLParam(r, "key"))
	})
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in plans.Input) (plans.Plan, error) {
		p, err := plans.Create(r.Context(), m.pool, in)
		m.changed()
		return p, err
	})
}

func (m *Module) update(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in plans.Input) (plans.Plan, error) {
		p, err := plans.Update(r.Context(), m.pool, chi.URLParam(r, "key"), in)
		m.changed()
		return p, err
	})
}

func (m *Module) delete(w http.ResponseWriter, r *http.Request) {
	if err := plans.Delete(r.Context(), m.pool, chi.URLParam(r, "key")); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	m.changed()
	w.WriteHeader(http.StatusNoContent)
}
