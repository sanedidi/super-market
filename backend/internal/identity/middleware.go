package identity

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/httpx"
	"github.com/sanedidi/super-market/backend/internal/platform/token"
)

// Authenticator проверяет access-токен и кладёт Principal в контекст.
type Authenticator struct {
	svc *Service
	log *slog.Logger
}

func NewAuthenticator(svc *Service, log *slog.Logger) *Authenticator {
	return &Authenticator{svc: svc, log: log}
}

// Require пускает только запросы с токеном одного из приложений apps и живой сессией.
// Права сотрудника читаются из базы на каждый запрос, поэтому смена роли
// или блокировка действуют сразу, без перевыпуска токена.
func (a *Authenticator) Require(apps ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p, err := a.authenticate(r, apps...)
			if err != nil {
				httpx.Fail(w, r, a.log, err)
				return
			}
			next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
		})
	}
}

// Optional узнаёт пользователя приложения app, если токен есть и годен;
// без токена или с негодным запрос идёт дальше анонимно.
func (a *Authenticator) Optional(app string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if p, err := a.authenticate(r, app); err == nil {
				r = r.WithContext(WithPrincipal(r.Context(), p))
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Allow пускает сотрудника, у которого есть хотя бы одно из прав perms.
// Ставится на маршруты чтения после Require(AppStore): права на запись
// проверяют сервисы, а это — чтобы список или карточку раздела не видел
// тот, кому раздел не положен.
func (a *Authenticator) Allow(perms ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p := FromContext(r.Context())
			if p == nil {
				httpx.Fail(w, r, a.log, apperr.Unauthorized("нужен токен авторизации"))
				return
			}
			if err := p.RequireAny(perms...); err != nil {
				httpx.Fail(w, r, a.log, err)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func (a *Authenticator) authenticate(r *http.Request, apps ...string) (*Principal, error) {
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || raw == "" {
		return nil, apperr.Unauthorized("нужен токен авторизации")
	}
	claims, err := a.svc.signer.Verify(raw)
	switch {
	case errors.Is(err, token.ErrExpired):
		return nil, apperr.New(http.StatusUnauthorized, "token_expired", "срок токена истёк, обновите его")
	case err != nil:
		return nil, apperr.Unauthorized("неверный токен")
	case !slices.Contains(apps, claims.App):
		return nil, apperr.Forbidden("токен выдан для другого приложения")
	}
	return a.svc.loadPrincipal(r.Context(), claims)
}

var errSession = apperr.Unauthorized("сессия закрыта, войдите заново")

func (s *Service) loadPrincipal(ctx context.Context, c token.Claims) (*Principal, error) {
	p := &Principal{UserID: c.UserID, SessionID: c.SessionID, App: c.App}
	const live = `s.id = $1 AND s.user_id = $2 AND s.revoked_at IS NULL AND s.expires_at > now()`

	var err error
	switch c.App {
	case AppClient:
		err = s.pool.QueryRow(ctx, `
			SELECT 1 FROM sessions s JOIN customers c ON c.user_id = s.user_id AND c.deleted_at IS NULL
			WHERE `+live, c.SessionID, c.UserID).Scan(new(int))
	case AppAdmin:
		err = s.pool.QueryRow(ctx, `
			SELECT 1 FROM sessions s JOIN platform_admins pa ON pa.user_id = s.user_id
			WHERE `+live, c.SessionID, c.UserID).Scan(new(int))
	case AppCrowd:
		err = s.pool.QueryRow(ctx, `
			SELECT 1 FROM sessions s JOIN crowd_couriers cc ON cc.user_id = s.user_id AND cc.status <> 'blocked' AND cc.deleted_at IS NULL
			WHERE `+live, c.SessionID, c.UserID).Scan(new(int))
	case AppStore, AppCourier:
		// Курьеру нужен действующий логин и право доставки: отключили вход
		// или убрали право — сессия перестаёт работать сразу.
		courier := ""
		if c.App == AppCourier {
			courier = `
			JOIN courier_logins cl ON cl.employee_id = e.id
			WHERE (r.is_owner OR 'orders.deliver' = ANY(r.permissions)) AND `
		} else {
			courier = " WHERE "
		}
		err = s.pool.QueryRow(ctx, `
			SELECT e.id, e.network_id, n.kind, r.permissions, r.is_owner, e.all_stores,
			       COALESCE((SELECT array_agg(es.store_id::text) FROM employee_stores es
			                 WHERE es.employee_id = e.id), '{}')
			FROM sessions s
			JOIN employees e ON e.user_id = s.user_id AND e.status = 'active'
			JOIN roles r     ON r.id = e.role_id
			JOIN networks n  ON n.id = e.network_id AND n.status = 'active'`+courier+live, c.SessionID, c.UserID).Scan(
			&p.EmployeeID, &p.NetworkID, &p.NetworkKind, &p.Permissions, &p.IsOwner, &p.AllStores, &p.StoreIDs)
	default:
		return nil, errSession
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errSession
	}
	if err != nil {
		return nil, err
	}
	return p, nil
}

// EmployeePrincipal — права действующего сотрудника без сессии: для фоновых
// задач, которые считают данные от его имени (итоги дня владельцу).
func EmployeePrincipal(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, employeeID string) (*Principal, error) {
	p := &Principal{App: AppStore, EmployeeID: employeeID}
	err := q.QueryRow(ctx, `
		SELECT e.user_id, e.network_id, n.kind, r.permissions, r.is_owner, e.all_stores,
		       COALESCE((SELECT array_agg(es.store_id::text) FROM employee_stores es WHERE es.employee_id = e.id), '{}')
		FROM employees e
		JOIN roles r    ON r.id = e.role_id
		JOIN networks n ON n.id = e.network_id AND n.status = 'active'
		WHERE e.id = $1 AND e.status = 'active'`, employeeID).Scan(
		&p.UserID, &p.NetworkID, &p.NetworkKind, &p.Permissions, &p.IsOwner, &p.AllStores, &p.StoreIDs)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.NotFound("сотрудник не найден")
	}
	if err != nil {
		return nil, err
	}
	return p, nil
}
