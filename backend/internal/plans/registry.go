// Package plans — тарифы магазинов: цена, функции и лимиты.
//
// Какие функции и лимиты вообще бывают, задаёт код (реестр ниже): каждая
// функция проверяется в своём модуле. Какие из них входят в какой тариф,
// цены, комиссия и пробный период — настраивает супер-админ, без релиза.
//
// Новая платная функция: ключ в Features, проверка в модуле —
// auth.Feature("ключ") на маршрутах или plans.Require в сервисе, — и
// супер-админ включает её в нужных тарифах.
package plans

import "github.com/sanedidi/super-market/backend/internal/platform/i18n"

// Группы функций для экрана тарифов.
const (
	GroupStore    = "store"
	GroupReports  = "reports"
	GroupDelivery = "delivery"
	GroupShowcase = "showcase"
)

// Функции.
const (
	FeatureDebts            = "debts"
	FeaturePromotions       = "promotions"
	FeatureInvoiceScans     = "invoice_scans"
	FeatureReportsPro       = "reports_pro"
	FeatureABCXYZ           = "abc_xyz"
	FeatureBrandAds         = "brand_ads"
	FeatureCrowd            = "crowd"
	FeatureShowcaseCustom   = "showcase_custom"
	FeatureShowcaseManual   = "showcase_manual"
	FeatureShowcaseSchedule = "showcase_schedule"
	FeatureShowcasePerStore = "showcase_per_store"
	FeatureShowcaseStats    = "showcase_stats"
	FeatureShowcaseStatsAll = "showcase_stats_full"
	FeatureAdsOff           = "ads_off"
)

// Лимиты.
const (
	LimitStores    = "stores"
	LimitRegisters = "registers"
	LimitStaff     = "staff"
	LimitCouriers  = "couriers"
	LimitBanners   = "banners"
	LimitShelves   = "shelves"
	LimitPromos    = "promos"
	LimitAds       = "ads"
	// LimitAIPhotos — фото, которые Super Market делает магазину сам
	// (нормализация фото новых товаров и строк инвентаризации), в месяц.
	LimitAIPhotos = "ai_photos"
)

// Feature — функция, которую можно включить в тариф.
type Feature struct {
	Key   string
	Group string
	Name  i18n.Text
	Hint  i18n.Text
}

// Limit — что тариф ограничивает числом. Max — наибольшее осмысленное
// значение (0 — без верхней границы), Default — если в тарифе не задано
// (nil — без лимита).
type Limit struct {
	Key     string
	Group   string
	Name    i18n.Text
	Hint    i18n.Text
	Max     int
	Default *int
}

func ptr(v int) *int { return &v }

// Features — реестр функций в порядке показа.
var Features = []Feature{
	{FeatureDebts, GroupStore,
		i18n.Text{RU: "Долги покупателей (насия)", UZ: "Xaridorlar qarzi (nasiya)"},
		i18n.Text{RU: "Продажа в долг на кассе, лимиты, должники, напоминания", UZ: "Kassada nasiyaga sotish, limitlar, qarzdorlar, eslatmalar"}},
	{FeaturePromotions, GroupStore,
		i18n.Text{RU: "Акции и скидки", UZ: "Aksiyalar va chegirmalar"},
		i18n.Text{RU: "Скидки на товары на кассе и в приложении", UZ: "Kassada va ilovada mahsulotlarga chegirmalar"}},
	{FeatureInvoiceScans, GroupStore,
		i18n.Text{RU: "Накладные по фото", UZ: "Rasmdan nakladnoy"},
		i18n.Text{RU: "Super Market распознаёт накладную поставщика и делает приход", UZ: "Super Market yetkazib beruvchi nakladnoyini taniydi va kirim qiladi"}},
	{FeatureReportsPro, GroupReports,
		i18n.Text{RU: "Расширенные отчёты", UZ: "Kengaytirilgan hisobotlar"},
		i18n.Text{RU: "Прибыль и убытки, движение денег", UZ: "Foyda va zarar, pul harakati"}},
	{FeatureABCXYZ, GroupReports,
		i18n.Text{RU: "ABC/XYZ-анализ", UZ: "ABC/XYZ-tahlil"},
		i18n.Text{RU: "Какие товары приносят деньги, какие стоят и что скоро закончится", UZ: "Qaysi mahsulotlar pul keltiradi, qaysilari turib qolgan va nima tez orada tugaydi"}},
	{FeatureCrowd, GroupDelivery,
		i18n.Text{RU: "Доставка «по пути»", UZ: "«Yoʻl-yoʻlakay» yetkazish"},
		i18n.Text{RU: "Заказы магазина могут брать курьеры «по пути», не только свои", UZ: "Doʻkon buyurtmalarini oʻz kuryerlaridan tashqari «yoʻl-yoʻlakay» kuryerlar ham olishi mumkin"}},
	{FeatureShowcaseCustom, GroupShowcase,
		i18n.Text{RU: "Своя витрина", UZ: "Oʻz vitrinasi"},
		i18n.Text{RU: "Свои блоки, баннеры и порядок на главной магазина в приложении", UZ: "Ilovada doʻkon bosh sahifasida oʻz bloklari, bannerlari va tartibi"}},
	{FeatureShowcaseManual, GroupShowcase,
		i18n.Text{RU: "Подборки вручную", UZ: "Qoʻlda toʻplamlar"},
		i18n.Text{RU: "Полки с товарами, выбранными вручную", UZ: "Qoʻlda tanlangan mahsulotlar javonlari"}},
	{FeatureShowcaseSchedule, GroupShowcase,
		i18n.Text{RU: "Расписание блоков", UZ: "Bloklar jadvali"},
		i18n.Text{RU: "Блок витрины показывается в заданные дни и часы", UZ: "Vitrina bloki belgilangan kun va soatlarda koʻrsatiladi"}},
	{FeatureShowcasePerStore, GroupShowcase,
		i18n.Text{RU: "Витрина для каждого магазина", UZ: "Har bir doʻkonga vitrina"},
		i18n.Text{RU: "У каждого магазина сети своя главная", UZ: "Tarmoqning har bir doʻkonida oʻz bosh sahifasi"}},
	{FeatureShowcaseStats, GroupShowcase,
		i18n.Text{RU: "Статистика витрины", UZ: "Vitrina statistikasi"},
		i18n.Text{RU: "Показы и нажатия по блокам", UZ: "Bloklar boʻyicha koʻrishlar va bosishlar"}},
	{FeatureShowcaseStatsAll, GroupShowcase,
		i18n.Text{RU: "Полная статистика витрины", UZ: "Toʻliq vitrina statistikasi"},
		i18n.Text{RU: "Продажи с витрины, по дням и по магазинам", UZ: "Vitrinadan sotuvlar, kunlar va doʻkonlar boʻyicha"}},
	{FeatureBrandAds, GroupShowcase,
		i18n.Text{RU: "Реклама брендов", UZ: "Brendlar reklamasi"},
		i18n.Text{RU: "Доля магазина с рекламы брендов и настройки: скрыть бренды, исключить категории", UZ: "Brendlar reklamasidan doʻkon ulushi va sozlamalar: brendlarni yashirish, toifalarni chiqarib tashlash"}},
	{FeatureAdsOff, GroupShowcase,
		i18n.Text{RU: "Меньше рекламы брендов", UZ: "Brendlar reklamasi kamroq"},
		i18n.Text{RU: "Магазин может уменьшить или выключить рекламу брендов на своей главной", UZ: "Doʻkon oʻz bosh sahifasida brendlar reklamasini kamaytirishi yoki oʻchirishi mumkin"}},
}

// Limits — реестр лимитов в порядке показа.
var Limits = []Limit{
	{LimitStores, GroupStore,
		i18n.Text{RU: "Магазинов", UZ: "Doʻkonlar"},
		i18n.Text{RU: "Сколько магазинов (точек) можно завести в сети", UZ: "Tarmoqda nechta doʻkon (nuqta) ochish mumkin"}, 0, nil},
	{LimitRegisters, GroupStore,
		i18n.Text{RU: "Касс", UZ: "Kassalar"},
		i18n.Text{RU: "Подключённых касс POS на всю сеть", UZ: "Butun tarmoqqa ulangan POS kassalar"}, 0, nil},
	{LimitStaff, GroupStore,
		i18n.Text{RU: "Сотрудников", UZ: "Xodimlar"},
		i18n.Text{RU: "Сотрудников, кроме владельца и курьеров", UZ: "Egasi va kuryerlardan tashqari xodimlar"}, 0, nil},
	{LimitAIPhotos, GroupStore,
		i18n.Text{RU: "Фото от Super Market в месяц", UZ: "Oyiga Super Market rasmlari"},
		i18n.Text{RU: "Super Market сам делает чистое фото новых товаров и товаров без фото на инвентаризации", UZ: "Super Market yangi mahsulotlar va inventarizatsiyadagi rasmsiz mahsulotlarning toza rasmini oʻzi tayyorlaydi"}, 0, ptr(300)},
	{LimitCouriers, GroupDelivery,
		i18n.Text{RU: "Своих курьеров", UZ: "Oʻz kuryerlari"},
		i18n.Text{RU: "Сотрудников с правом доставки", UZ: "Yetkazib berish huquqiga ega xodimlar"}, 0, nil},
	{LimitBanners, GroupShowcase,
		i18n.Text{RU: "Своих баннеров", UZ: "Oʻz bannerlari"},
		i18n.Text{RU: "Активных баннеров на витрине", UZ: "Vitrinadagi faol bannerlar"}, 0, nil},
	{LimitShelves, GroupShowcase,
		i18n.Text{RU: "Своих полок", UZ: "Oʻz javonlari"},
		i18n.Text{RU: "Полок с товарами на витрине", UZ: "Vitrinadagi mahsulot javonlari"}, 0, nil},
	{LimitPromos, GroupShowcase,
		i18n.Text{RU: "Промо-полосок", UZ: "Promo-chiziqlar"},
		i18n.Text{RU: "Промо-полосок на витрине", UZ: "Vitrinadagi promo-chiziqlar"}, 0, nil},
	{LimitAds, GroupShowcase,
		i18n.Text{RU: "Рекламы брендов на главной", UZ: "Bosh sahifada brendlar reklamasi"},
		i18n.Text{RU: "Сколько рекламных блоков брендов показывать (0–2)", UZ: "Nechta brend reklama bloki koʻrsatiladi (0–2)"}, 2, ptr(2)},
}

// Groups — названия групп.
var Groups = []struct {
	Key  string
	Name i18n.Text
}{
	{GroupStore, i18n.Text{RU: "Магазин и касса", UZ: "Doʻkon va kassa"}},
	{GroupReports, i18n.Text{RU: "Отчёты", UZ: "Hisobotlar"}},
	{GroupDelivery, i18n.Text{RU: "Доставка", UZ: "Yetkazib berish"}},
	{GroupShowcase, i18n.Text{RU: "Витрина в приложении", UZ: "Ilovadagi vitrina"}},
}

func featureInfo(key string) (Feature, bool) {
	for _, f := range Features {
		if f.Key == key {
			return f, true
		}
	}
	return Feature{}, false
}

func limitInfo(key string) (Limit, bool) {
	for _, l := range Limits {
		if l.Key == key {
			return l, true
		}
	}
	return Limit{}, false
}
