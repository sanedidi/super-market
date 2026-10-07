// Package identity — пользователи, вход по коду из Telegram, сессии,
// супер-админы, роли и сотрудники сетей.
package identity

import (
	"context"
	"slices"

	"github.com/sanedidi/super-market/backend/internal/platform/apperr"
	"github.com/sanedidi/super-market/backend/internal/platform/i18n"
)

// Приложения, в которые можно войти. Токен выдаётся на одно приложение.
const (
	AppClient = "client" // Flutter-приложение покупателя
	AppStore  = "store"  // панель магазина и POS
	AppAdmin  = "admin"  // панель супер-админа
	// AppPOS — касса: входит не по SMS-коду, а токеном устройства
	// (см. пакет pos); кассир выбирается по ПИНу на самом устройстве.
	AppPOS = "pos"
	// AppCourier — приложение курьера: вход по логину и паролю, которые
	// задаёт магазин; доступны только маршруты /courier/*.
	AppCourier = "courier"
	// AppCrowd — то же приложение курьера в режиме «по пути»: вход по
	// телефону и коду, доступны только маршруты /crowd/*.
	AppCrowd = "crowd"
)

// Права сотрудников. Роль — это набор прав; у владельца есть все.
const (
	PermStoresManage         = "stores.manage"         // магазины и склады
	PermStaffManage          = "staff.manage"          // роли и сотрудники
	PermCatalogManage        = "catalog.manage"        // свои товары, типы цен
	PermPricesManage         = "prices.manage"         // установка цен
	PermCounterpartiesManage = "counterparties.manage" // контрагенты
	PermFinanceManage        = "finance.manage"        // кассы, операции, курс, сдача кассы
	PermInventoryManage      = "inventory.manage"      // складские документы
	PermSalesPOS             = "sales.pos"             // продажа на кассе
	PermSalesDiscount        = "sales.discount"        // скидки на кассе
	PermSalesReturn          = "sales.return"          // возврат от клиента
	PermReportsView          = "reports.view"          // отчёты
	PermOrdersManage         = "orders.manage"         // онлайн-заказы
	PermPayoutsManage        = "payouts.manage"        // вывод денег с платформы
	PermOrdersDeliver        = "orders.deliver"        // курьер: доставка заказов
	PermShowcaseManage       = "showcase.manage"       // витрина магазина в приложении
	PermDebtsGive            = "debts.give"            // продажа в долг на кассе
	PermDebtsManage          = "debts.manage"          // долги покупателей: оплата, лимиты, списание, настройки
	PermPOSSettings          = "pos.settings"          // настройка кассы: быстрые кнопки
)

// PermissionInfo — право с понятным названием для экрана ролей.
type PermissionInfo struct {
	Code  string `json:"code"`
	Title string `json:"title"`
	// TitleUz — название по-узбекски; в ответе Title уже на языке запроса.
	TitleUz string `json:"-"`
}

// PermissionsIn — права с названиями на языке lang.
func PermissionsIn(lang string) []PermissionInfo {
	out := make([]PermissionInfo, len(Permissions))
	for i, p := range Permissions {
		out[i] = PermissionInfo{Code: p.Code, Title: i18n.Pick(lang, p.Title, p.TitleUz)}
	}
	return out
}

// Permissions — все права системы. Новые модули добавляют сюда свои.
var Permissions = []PermissionInfo{
	{PermStoresManage, "Магазины и склады", "Doʻkonlar va omborlar"},
	{PermStaffManage, "Роли и сотрудники", "Rollar va xodimlar"},
	{PermCatalogManage, "Товары и типы цен", "Mahsulotlar va narx turlari"},
	{PermPricesManage, "Установка цен", "Narxlarni belgilash"},
	{PermCounterpartiesManage, "Контрагенты", "Kontragentlar"},
	{PermFinanceManage, "Финансы: кассы, операции, курс", "Moliya: kassalar, operatsiyalar, kurs"},
	{PermInventoryManage, "Склад: приход, перемещения, списания, инвентаризация", "Ombor: kirim, koʻchirish, hisobdan chiqarish, inventarizatsiya"},
	{PermSalesPOS, "Продажа на кассе (POS)", "Kassada sotish (POS)"},
	{PermSalesDiscount, "Скидки на кассе", "Kassada chegirmalar"},
	{PermSalesReturn, "Возврат от клиента", "Mijozdan qaytarish"},
	{PermReportsView, "Отчёты", "Hisobotlar"},
	{PermOrdersManage, "Онлайн-заказы", "Onlayn buyurtmalar"},
	{PermPayoutsManage, "Вывод денег с платформы", "Platformadan pul yechib olish"},
	{PermOrdersDeliver, "Курьер: доставка заказов", "Kuryer: buyurtmalarni yetkazish"},
	{PermShowcaseManage, "Витрина в приложении", "Ilovadagi vitrina"},
	{PermDebtsGive, "Продажа в долг на кассе", "Kassada qarzga sotish"},
	{PermDebtsManage, "Долги покупателей: оплата, лимиты, списание", "Xaridorlar qarzlari: toʻlov, limitlar, hisobdan chiqarish"},
	{PermPOSSettings, "Настройка кассы: быстрые кнопки", "Kassa sozlamalari: tezkor tugmalar"},
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
	// MustChangePassword — сотрудник вошёл в панель по временному паролю.
	MustChangePassword bool

	// Касса, с которой пришёл запрос (только App == AppPOS).
	DeviceID string
}

// Can — есть ли у сотрудника право.
func (p *Principal) Can(perm string) bool {
	return p.IsOwner || slices.Contains(p.Permissions, perm)
}

// Require возвращает 403, если права нет.
func (p *Principal) Require(perm string) error {
	if !p.Can(perm) {
		return apperr.Forbidden("недостаточно прав").Uz("huquqlar yetarli emas").WithDetails(map[string]any{"permission": perm})
	}
	return nil
}

// CanAny — есть ли у сотрудника хотя бы одно из прав.
func (p *Principal) CanAny(perms ...string) bool {
	return slices.ContainsFunc(perms, p.Can)
}

// RequireAny возвращает 403, если нет ни одного из прав.
func (p *Principal) RequireAny(perms ...string) error {
	if !p.CanAny(perms...) {
		return apperr.Forbidden("недостаточно прав").Uz("huquqlar yetarli emas").WithDetails(map[string]any{"permission": perms[0], "any_of": perms})
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
