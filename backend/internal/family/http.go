package family

import (
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
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

func uid(r *http.Request) string { return identity.FromContext(r.Context()).UserID }

func (m *Module) Routes(r chi.Router) {
	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppClient))
		r.Get("/client/family", m.get)
		r.Post("/client/family", m.create)
		r.Post("/client/family/invites", m.invite)
		r.Post("/client/family/join", m.join)
		r.Post("/client/family/leave", m.leave)
		r.Patch("/client/family/members/{id}", m.updateMember)
		r.Delete("/client/family/members/{id}", m.removeMember)
		r.Get("/client/family/suggestions", m.suggestions)
		r.Get("/client/family/requests", m.requests)
		r.Post("/client/family/requests", m.createRequest)
		r.Get("/client/family/requests/{id}", m.request)
		r.Post("/client/family/requests/{id}/items/{item}/bought", m.markItem)
		r.Post("/client/family/requests/{id}/snooze", m.snooze)
		r.Post("/client/family/requests/{id}/cancel", m.cancel)
		r.Post("/client/family/requests/{id}/ordered", m.ordered)
		r.Get("/client/family/requests/{id}/to-cart", m.toCart)
	})
}

// get: {"family": null}, если пользователь ещё не в семье.
func (m *Module) get(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (map[string]any, error) {
		f, err := m.svc.Get(r.Context(), uid(r))
		return map[string]any{"family": f}, err
	})
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in CreateInput) (*Family, error) {
		return m.svc.Create(r.Context(), uid(r), in)
	})
}

func (m *Module) invite(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusCreated, func() (Invite, error) { return m.svc.CreateInvite(r.Context(), uid(r)) })
}

func (m *Module) join(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in JoinInput) (*Family, error) {
		return m.svc.Join(r.Context(), uid(r), in)
	})
}

func (m *Module) leave(w http.ResponseWriter, r *http.Request) {
	if err := m.svc.Leave(r.Context(), uid(r)); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) updateMember(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in MemberInput) (*Family, error) {
		return m.svc.UpdateMember(r.Context(), uid(r), id, in)
	})
}

func (m *Module) removeMember(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err == nil {
		err = m.svc.RemoveMember(r.Context(), uid(r), id)
	}
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (m *Module) suggestions(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Suggestion], error) {
		items, err := m.svc.Suggestions(r.Context(), uid(r))
		return httpx.List[Suggestion]{Items: items}, err
	})
}

func (m *Module) requests(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[Request], error) {
		items, err := m.svc.Requests(r.Context(), uid(r), r.URL.Query().Get("status") != "history", httpx.PageFrom(r))
		return httpx.List[Request]{Items: items}, err
	})
}

func (m *Module) createRequest(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusCreated, "", func(_ string, in RequestInput) (Request, error) {
		return m.svc.CreateRequest(r.Context(), uid(r), in)
	})
}

func (m *Module) request(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Request, error) {
		return m.svc.Request(r.Context(), uid(r), id)
	})
}

func (m *Module) markItem(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in BoughtInput) (Request, error) {
		return m.svc.MarkItem(r.Context(), uid(r), id, chi.URLParam(r, "item"), in)
	})
}

func (m *Module) snooze(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in SnoozeInput) (Request, error) {
		return m.svc.Snooze(r.Context(), uid(r), id, in)
	})
}

func (m *Module) cancel(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Request, error) {
		return m.svc.Cancel(r.Context(), uid(r), id)
	})
}

func (m *Module) ordered(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in OrderedInput) (Request, error) {
		return m.svc.Ordered(r.Context(), uid(r), id, in)
	})
}

func (m *Module) toCart(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (Quote, error) {
		lat, err1 := strconv.ParseFloat(r.URL.Query().Get("lat"), 64)
		lng, err2 := strconv.ParseFloat(r.URL.Query().Get("lng"), 64)
		if err1 != nil || err2 != nil {
			return Quote{}, apperr.Validation("lat/lng: укажите адрес доставки")
		}
		return m.svc.ToCart(r.Context(), uid(r), id, lat, lng)
	})
}
