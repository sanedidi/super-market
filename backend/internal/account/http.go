package account

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/identity"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Module — HTTP-маршруты удаления аккаунтов.
type Module struct {
	svc  *Service
	auth *identity.Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *identity.Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	r.With(m.auth.Require(identity.AppCrowd)).Delete("/crowd/me", m.deleteCrowd)
	r.With(m.auth.Require(identity.AppStore)).Post("/store/me/deletion-request", m.request)
	r.With(m.auth.Require(identity.AppCourier, identity.AppStore)).Post("/courier/me/deletion-request", m.request)

	// Без входа: страница удаления аккаунта на сайте (ссылка для Google Play).
	r.Post("/public/account-deletion/request", m.publicRequest)
	r.Post("/public/account-deletion/confirm", m.publicConfirm)

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(identity.AppAdmin))
		r.Get("/admin/account-deletion-requests", m.adminList)
		r.Post("/admin/account-deletion-requests/{id}/done", m.adminResolve("done"))
		r.Post("/admin/account-deletion-requests/{id}/reject", m.adminResolve("rejected"))
	})
}

func (m *Module) deleteCrowd(w http.ResponseWriter, r *http.Request) {
	if err := m.svc.DeleteCrowd(r.Context(), identity.FromContext(r.Context())); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// decodeOptional — тело необязательно: пустой запрос — пустые поля.
func decodeOptional(r *http.Request, dst any) error {
	if r.Body == nil || r.ContentLength == 0 {
		return nil
	}
	return httpx.Decode(r, dst)
}

func (m *Module) request(w http.ResponseWriter, r *http.Request) {
	var in RequestInput
	if err := decodeOptional(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	req, isNew, err := m.svc.Request(r.Context(), identity.FromContext(r.Context()), in)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	status := http.StatusOK
	if isNew {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, req)
}

func (m *Module) publicRequest(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Phone string `json:"phone"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	expiresIn, channel, err := m.svc.RequestCode(r.Context(), in.Phone)
	if err != nil {
		httpx.Fail(w, r, m.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"sent": true, "expires_in": expiresIn, "resend_in": identity.ResendIn(), "channel": channel,
	})
}

func (m *Module) publicConfirm(w http.ResponseWriter, r *http.Request) {
	type body struct {
		Phone string `json:"phone"`
		Code  string `json:"code"`
	}
	httpx.RespondBody(w, r, m.log, http.StatusOK, "", func(_ string, in body) (Result, error) {
		return m.svc.Confirm(r.Context(), in.Phone, in.Code)
	})
}

func (m *Module) adminList(w http.ResponseWriter, r *http.Request) {
	httpx.Respond(w, r, m.log, http.StatusOK, func() (httpx.List[DeletionRequest], error) {
		items, err := m.svc.AdminRequests(r.Context(), r.URL.Query().Get("status"), httpx.PageFrom(r))
		return httpx.List[DeletionRequest]{Items: items}, err
	})
}

func (m *Module) adminResolve(status string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := httpx.PathID(r, "id")
		var in ResolveInput
		if err == nil {
			err = decodeOptional(r, &in)
		}
		if err != nil {
			httpx.Fail(w, r, m.log, err)
			return
		}
		httpx.Respond(w, r, m.log, http.StatusOK, func() (DeletionRequest, error) {
			return m.svc.AdminResolve(r.Context(), identity.FromContext(r.Context()), id, status, in)
		})
	}
}
