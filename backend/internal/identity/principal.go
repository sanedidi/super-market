// Package identity — пользователи, вход по коду из Telegram, сессии,
// супер-админы, роли и сотрудники сетей.
package identity

import (
	"context"
	"slices"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
)

// Приложения, в которые можно войти. Токен выдаётся на одно приложение.
const (
	AppClient = "client" // Flutter-приложение покупателя
	AppStore  = "store"  // панель магазина и POS
	AppAdmin  = "admin"  // панель супер-админа
)

// Права сотрудников. Роль — это набор прав; у владельца есть все.
const (
	PermStoresManage  = "stores.manage"  // магазины и склады
	PermStaffManage   = "staff.manage"   // роли и сотрудники
	PermCatalogManage = "catalog.manage" // свои товары, типы цен
	PermPricesManage  = "prices.manage"  // установка цен
)

// PermissionInfo — право с понятным названием для экрана ролей.
type PermissionInfo struct {
	Code  string `json:"code"`
	Title string `json:"title"`
}

// Permissions — все права системы. Новые модули добавляют сюда свои.
var Permissions = []PermissionInfo{
	{PermStoresManage, "Магазины и склады"},
	{PermStaffManage, "Роли и сотрудники"},
	{PermCatalogManage, "Товары и типы цен"},
	{PermPricesManage, "Установка цен"},
}

func knownPermission(code string) bool {
	return slices.ContainsFunc(Permissions, func(p PermissionInfo) bool { return p.Code == code })
}

// Principal — кто делает запрос. Кладётся в context middleware'ом.
type Principal struct {
	UserID    string
	SessionID string
	App       string

	// Заполнено только для App == AppStore.
	NetworkID   string
	NetworkKind string
	EmployeeID  string
	Permissions []string
	IsOwner     bool
	AllStores   bool
	StoreIDs    []string
}

// Can — есть ли у сотрудника право.
func (p *Principal) Can(perm string) bool {
	return p.IsOwner || slices.Contains(p.Permissions, perm)
}

// Require возвращает 403, если права нет.
func (p *Principal) Require(perm string) error {
	if !p.Can(perm) {
		return apperr.Forbidden("недостаточно прав").WithDetails(map[string]any{"permission": perm})
	}
	return nil
}

// SeesAllStores — сотрудник видит все магазины сети.
func (p *Principal) SeesAllStores() bool { return p.IsOwner || p.AllStores }

// CanAccessStore — есть ли у сотрудника доступ к магазину.
func (p *Principal) CanAccessStore(storeID string) bool {
	return p.SeesAllStores() || slices.Contains(p.StoreIDs, storeID)
}

type ctxKey struct{}

// WithPrincipal кладёт Principal в контекст.
func WithPrincipal(ctx context.Context, p *Principal) context.Context {
	return context.WithValue(ctx, ctxKey{}, p)
}

// FromContext достаёт Principal. Внутри маршрутов под Require он всегда есть.
func FromContext(ctx context.Context) *Principal {
	p, _ := ctx.Value(ctxKey{}).(*Principal)
	return p
}
