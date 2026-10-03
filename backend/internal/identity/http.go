package identity

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
)

// Module — HTTP-маршруты identity.
type Module struct {
	svc  *Service
	auth *Authenticator
	log  *slog.Logger
}

func NewModule(svc *Service, auth *Authenticator, log *slog.Logger) *Module {
	return &Module{svc: svc, auth: auth, log: log}
}

func (m *Module) Routes(r chi.Router) {
	r.Post("/auth/otp/request", m.requestCode)
	r.Post("/auth/otp/verify", m.verifyCode)
	r.Post("/auth/refresh", m.refresh)
	r.With(m.auth.Require(AppClient)).Post("/auth/client/logout", m.logout)
	r.With(m.auth.Require(AppStore)).Post("/auth/store/logout", m.logout)
	r.With(m.auth.Require(AppAdmin)).Post("/auth/admin/logout", m.logout)
	r.Post("/auth/courier/login", m.courierLogin)
	r.With(m.auth.Require(AppCourier)).Post("/auth/courier/logout", m.logout)
	r.With(m.auth.Require(AppCrowd)).Post("/auth/crowd/logout", m.logout)

	r.Group(func(r chi.Router) {
		r.Use(m.auth.Require(AppStore))
		staff := m.auth.Allow(PermStaffManage)
		r.With(staff).Get("/store/permissions", m.listPermissions)
		r.With(staff).Get("/store/roles", m.listRoles)
		r.Post("/store/roles", m.createRole)
		r.Patch("/store/roles/{id}", m.updateRole)
		r.Delete("/store/roles/{id}", m.deleteRole)
		r.With(staff).Get("/store/employees", m.listEmployees)
		r.Post("/store/employees", m.createEmployee)
		r.Patch("/store/employees/{id}", m.updateEmployee)
		r.Delete("/store/employees/{id}", m.deleteEmployee)
		// Логин и пароль курьера для приложения курьера.
		r.With(m.auth.Allow(PermStaffManage, PermOrdersManage)).Get("/store/couriers/{id}/login", m.getCourierLogin)
		r.Put("/store/couriers/{id}/login", m.setCourierLogin)
		r.Delete("/store/couriers/{id}/login", m.deleteCourierLogin)
	})
}

func (m *Module) fail(w http.ResponseWriter, r *http.Request, err error) {
	httpx.Fail(w, r, m.log, err)
}

// ----------------------------------------------------------------- вход

func (m *Module) requestCode(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Phone string `json:"phone"`
		App   string `json:"app"` // crowd — код по SMS
	}
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	expiresIn, err := m.svc.RequestCode(r.Context(), in.Phone, in.App)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	// resend_in — через сколько секунд можно запросить код снова (таймер на экране).
	channel := "telegram"
	if in.App == AppCrowd && m.svc.sms != nil {
		channel = "sms"
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"sent": true, "expires_in": expiresIn, "resend_in": int(resendCooldown.Seconds()), "bot_url": m.svc.botURL(),
		"channel": channel,
	})
}

func (m *Module) verifyCode(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Phone string `json:"phone"`
		Code  string `json:"code"`
		App   string `json:"app"`
		// Согласие с условиями — для регистрации курьера «по пути».
		TermsAccepted bool `json:"terms_accepted"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	t, err := m.svc.VerifyCodeTerms(r.Context(), in.Phone, in.Code, in.App, r.UserAgent(), in.TermsAccepted)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (m *Module) refresh(w http.ResponseWriter, r *http.Request) {
	var in struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	t, err := m.svc.Refresh(r.Context(), in.RefreshToken)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (m *Module) logout(w http.ResponseWriter, r *http.Request) {
	if err := m.svc.Logout(r.Context(), FromContext(r.Context()).SessionID); err != nil {
		m.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ------------------------------------------------------ роли и сотрудники

func (m *Module) listPermissions(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": Permissions})
}

func (m *Module) listRoles(w http.ResponseWriter, r *http.Request) {
	roles, err := m.svc.ListRoles(r.Context(), FromContext(r.Context()))
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": httpx.PageSlice(r, roles)})
}

func (m *Module) createRole(w http.ResponseWriter, r *http.Request) {
	var in RoleInput
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	role, err := m.svc.CreateRole(r.Context(), FromContext(r.Context()), in)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, role)
}

func (m *Module) updateRole(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		m.fail(w, r, err)
		return
	}
	var in RoleInput
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	role, err := m.svc.UpdateRole(r.Context(), FromContext(r.Context()), id, in)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, role)
}

func (m *Module) listEmployees(w http.ResponseWriter, r *http.Request) {
	page := httpx.PageFrom(r)
	items, err := m.svc.ListEmployees(r.Context(), FromContext(r.Context()), page.Limit, page.Offset)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (m *Module) createEmployee(w http.ResponseWriter, r *http.Request) {
	var in EmployeeInput
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	e, err := m.svc.CreateEmployee(r.Context(), FromContext(r.Context()), in)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, e)
}

func (m *Module) updateEmployee(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err != nil {
		m.fail(w, r, err)
		return
	}
	var in EmployeeInput
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	e, err := m.svc.UpdateEmployee(r.Context(), FromContext(r.Context()), id, in)
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, e)
}

// ----------------------------------------------------------------- курьер

func (m *Module) courierLogin(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Login    string `json:"login"`
		Password string `json:"password"`
	}
	if err := httpx.Decode(r, &in); err != nil {
		m.fail(w, r, err)
		return
	}
	t, err := m.svc.CourierLogin(r.Context(), in.Login, in.Password, r.UserAgent())
	if err != nil {
		m.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, t)
}

func (m *Module) getCourierLogin(w http.ResponseWriter, r *http.Request) {
	httpx.RespondID(w, r, m.log, http.StatusOK, "id", func(id string) (CourierLoginInfo, error) {
		if _, err := m.svc.courierEmployee(r.Context(), FromContext(r.Context()), id); err != nil {
			return CourierLoginInfo{}, err
		}
		return m.svc.CourierLoginOf(r.Context(), id)
	})
}

func (m *Module) setCourierLogin(w http.ResponseWriter, r *http.Request) {
	httpx.RespondBody(w, r, m.log, http.StatusOK, "id", func(id string, in CourierLoginInput) (CourierLoginInfo, error) {
		return m.svc.SetCourierLogin(r.Context(), FromContext(r.Context()), id, in)
	})
}

func (m *Module) deleteCourierLogin(w http.ResponseWriter, r *http.Request) {
	id, err := httpx.PathID(r, "id")
	if err == nil {
		err = m.svc.DeleteCourierLogin(r.Context(), FromContext(r.Context()), id)
	}
	if err != nil {
		m.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
