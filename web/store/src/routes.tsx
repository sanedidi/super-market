import type { ReactNode } from 'react'
import { Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom'
import { Flex, Result, Select, Spin } from 'antd'
import {
  AppstoreOutlined,
  AuditOutlined,
  BarChartOutlined,
  BookOutlined,
  CarOutlined,
  CalculatorOutlined,
  CrownOutlined,
  LockOutlined,
  DashboardOutlined,
  DollarOutlined,
  InboxOutlined,
  LayoutOutlined,
  NotificationOutlined,
  RocketOutlined,
  SettingOutlined,
  SafetyCertificateOutlined,
  ShoppingCartOutlined,
  ShoppingOutlined,
  WalletOutlined,
  CoffeeOutlined,
  FireOutlined,
  ShopOutlined,
} from '@ant-design/icons'
import { Shell, tabLabels, tr, type MenuItem } from '@sm/shared'
import { useStore } from './ctx'
import { DashboardPage } from './pages/Dashboard'
import { StartPage } from './pages/start/Start'
import { StockCountPage } from './pages/start/Count'
import { SetupGate, SetupPage } from './pages/setup/Setup'
import { OrdersPage } from './pages/Orders'
import { ReturnsPage, SalesPage } from './pages/Sales'
import { PriceDocEditor, PriceDocsPage } from './pages/Prices'
import { PromotionEditor, PromotionsPage } from './pages/Promotions'
import { StockDocEditor, StockDocsPage, docPaths } from './pages/StockDocs'
import { MovementsPage, StockPage } from './pages/Stock'
import { CashboxesPage, OperationsPage, RatesPage, TransfersPage } from './pages/Finance'
import { CashFlowPage, ProfitLossPage } from './pages/Reports'
import { AbcXyzPage } from './pages/AbcXyz'
import {
  CounterpartiesPage,
  CounterpartyTypesPage,
  DictPage,
  PaymentMethodsPage,
  PriceTypesPage,
  ReasonsPage,
  WarehousesPage,
} from './pages/Directories'
import { ProductsPage } from './pages/Products'
import { EmployeesPage, RolesPage, StoresPage } from './pages/Settings'
import { DeliveryPage } from './pages/Delivery'
import { BalancePage } from './pages/Balance'
import { CouriersPage } from './pages/Couriers'
import { CrowdPage } from './pages/Crowd'
import { ShowcasePage } from './pages/Showcase'
import { StoreAdsPage } from './pages/StoreAds'
import { PosDevicesPage, PosShiftsPage } from './pages/Pos'
import { DebtSettingsPage, DebtorsPage } from './pages/Debts'
import { OrderAlerts } from './notify'
import { FEATURE_BY_PATH, LockedFeature, PlanErrorHost, PlanPage } from './pages/Plan'
import { MenuPage, StopListPage } from './pages/cafe/Menu'
import { DishEditorPage } from './pages/cafe/Dish'
import { ModifiersPage } from './pages/cafe/Modifiers'
import { KitchenPage } from './pages/cafe/Kitchen'
import { KitchenStockPage } from './pages/cafe/KitchenStock'
import { PrepsPage } from './pages/cafe/Preps'
import { HallsPage } from './pages/cafe/Halls'

const TITLE = tr('Панель магазина', 'Doʻkon paneli')

// feature — функция тарифа: без неё у пункта замок, страница — с предложением тарифа.
type Item = { key: string; label: string; perm?: string | string[]; feature?: string; icon?: ReactNode; children?: Item[] }

// Меню как в Dokondor: группы разделов; perm — какое право нужно, чтобы видеть пункт.
// Права совпадают с правами сервера на чтение раздела (docs/api.md, «Права на чтение»).
const MENU: Item[] = [
  { key: '/', label: tr('Главная', 'Bosh sahifa'), icon: <DashboardOutlined /> },
  { key: '/start', label: tr('Начало работы', 'Ishni boshlash'), icon: <RocketOutlined />, perm: 'inventory.manage' },
  { key: '/orders', label: tr('Онлайн-заказы', 'Onlayn buyurtmalar'), icon: <ShoppingCartOutlined />, perm: 'orders.manage' },
  { key: '/couriers', label: tr('Курьеры', 'Kuryerlar'), icon: <CarOutlined />, perm: 'orders.manage' },
  { key: '/crowd', label: tr('Курьеры по пути', 'Yoʻlakay kuryerlar'), icon: <SafetyCertificateOutlined />, perm: 'orders.manage', feature: 'crowd' },
  { key: '/showcase', label: tr('Витрина приложения', 'Ilova vitrinasi'), icon: <LayoutOutlined />, perm: 'showcase.manage' },
  { key: '/brand-ads', label: tr('Реклама брендов', 'Brendlar reklamasi'), icon: <NotificationOutlined />, perm: 'showcase.manage', feature: 'brand_ads' },
  {
    key: 'sales',
    label: tr('Продажи', 'Sotuvlar'),
    icon: <ShoppingOutlined />,
    children: [
      { key: '/sales/pos', label: tr('Продажи POS', 'POS sotuvlari'), perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/returns', label: tr('Возвраты', 'Qaytarishlar'), perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/prices', label: tr('Установка цен', 'Narxlarni belgilash'), perm: 'prices.manage' },
      { key: '/sales/promotions', label: tr('Акции в приложении', 'Ilovadagi aksiyalar'), perm: 'prices.manage', feature: 'promotions' },
    ],
  },
  {
    key: 'pos',
    label: tr('Касса', 'Kassa'),
    icon: <CalculatorOutlined />,
    children: [
      { key: '/pos/devices', label: tr('Кассы и ПИНы', 'Kassalar va PIN-kodlar'), perm: ['stores.manage', 'staff.manage'] },
      { key: '/pos/shifts', label: tr('Смены', 'Smenalar'), perm: ['reports.view', 'finance.manage'] },
    ],
  },
  { key: '/debts', label: tr('Долги покупателей', 'Xaridorlar qarzlari'), icon: <AuditOutlined />, perm: ['debts.manage', 'debts.give'], feature: 'debts' },
  {
    key: 'purchases',
    label: tr('Закупки', 'Xaridlar'),
    icon: <InboxOutlined />,
    children: [
      { key: docPaths.income, label: tr('Приход товара', 'Mahsulot kirimi'), perm: 'inventory.manage' },
      { key: docPaths.supplier_return, label: tr('Возврат поставщику', 'Yetkazib beruvchiga qaytarish'), perm: 'inventory.manage' },
    ],
  },
  {
    key: 'stock',
    label: tr('Склад', 'Ombor'),
    icon: <AppstoreOutlined />,
    children: [
      { key: '/stock/balance', label: tr('Остатки', 'Qoldiqlar') },
      { key: docPaths.transfer, label: tr('Между складами', 'Omborlar oʻrtasida'), perm: 'inventory.manage' },
      { key: docPaths.inventory, label: tr('Инвентаризация', 'Inventarizatsiya'), perm: 'inventory.manage' },
      { key: docPaths.write_off, label: tr('Списание', 'Hisobdan chiqarish'), perm: 'inventory.manage' },
      { key: docPaths.posting, label: tr('Оприходование', 'Kirim qilish'), perm: 'inventory.manage' },
      { key: '/stock/movements', label: tr('История движения', 'Harakatlar tarixi') },
    ],
  },
  {
    key: 'finance',
    label: tr('Финансы', 'Moliya'),
    icon: <DollarOutlined />,
    children: [
      { key: '/finance/cashboxes', label: tr('Кассы', 'Kassalar'), perm: 'finance.manage' },
      { key: '/finance/operations', label: tr('Кассовые операции', 'Kassa operatsiyalari'), perm: 'finance.manage' },
      { key: '/finance/handovers', label: tr('Сдача кассы', 'Kassani topshirish'), perm: 'finance.manage' },
      { key: '/finance/transfers', label: tr('Из кассы в кассу', 'Kassadan kassaga'), perm: 'finance.manage' },
      { key: '/finance/rates', label: tr('Курс валюты', 'Valyuta kursi'), perm: 'finance.manage' },
    ],
  },
  {
    key: 'reports',
    label: tr('Отчёты', 'Hisobotlar'),
    icon: <BarChartOutlined />,
    children: [
      { key: '/reports/cash-flow', label: tr('Денежный поток', 'Pul oqimi'), perm: 'reports.view', feature: 'reports_pro' },
      { key: '/reports/profit-loss', label: tr('Прибыль и убыток', 'Foyda va zarar'), perm: 'reports.view', feature: 'reports_pro' },
      { key: '/reports/abc-xyz', label: tr('ABC/XYZ-анализ', 'ABC/XYZ tahlili'), perm: 'reports.view', feature: 'abc_xyz' },
    ],
  },
  {
    key: 'dirs',
    label: tr('Справочники', 'Maʼlumotnomalar'),
    icon: <BookOutlined />,
    children: [
      { key: '/dirs/counterparties', label: tr('Контрагенты', 'Kontragentlar'), perm: ['counterparties.manage', 'inventory.manage', 'finance.manage'] },
      { key: '/dirs/counterparty-types', label: tr('Типы контрагентов', 'Kontragent turlari'), perm: 'counterparties.manage' },
      { key: '/dirs/products', label: tr('Товары', 'Mahsulotlar') },
      { key: '/dirs/brands', label: tr('Бренды', 'Brendlar') },
      { key: '/dirs/colors', label: tr('Цвета', 'Ranglar') },
      { key: '/dirs/categories', label: tr('Категории', 'Kategoriyalar') },
      { key: '/dirs/units', label: tr('Единицы', 'Oʻlchov birliklari') },
      { key: '/dirs/price-types', label: tr('Типы цен', 'Narx turlari'), perm: ['catalog.manage', 'prices.manage'] },
      { key: '/dirs/warehouses', label: tr('Склады', 'Omborlar'), perm: ['stores.manage', 'inventory.manage'] },
      { key: '/dirs/payment-methods', label: tr('Способы оплаты', 'Toʻlov usullari'), perm: 'finance.manage' },
      { key: '/dirs/reasons', label: tr('Финансовые причины', 'Moliyaviy sabablar'), perm: 'finance.manage' },
    ],
  },
  {
    key: 'settings',
    label: tr('Настройки', 'Sozlamalar'),
    icon: <SettingOutlined />,
    children: [
      { key: '/settings/stores', label: tr('Магазины', 'Doʻkonlar'), perm: 'stores.manage' },
      { key: '/settings/delivery', label: tr('Доставка', 'Yetkazib berish'), perm: 'stores.manage' },
      { key: '/settings/debts', label: tr('Долги покупателей', 'Xaridorlar qarzlari'), perm: ['debts.manage', 'debts.give'], feature: 'debts' },
      { key: '/settings/roles', label: tr('Роли', 'Rollar'), perm: 'staff.manage' },
      { key: '/settings/employees', label: tr('Сотрудники', 'Xodimlar'), perm: 'staff.manage' },
    ],
  },
  { key: '/balance', label: tr('Баланс и подписка', 'Balans va obuna'), icon: <WalletOutlined />, perm: 'payouts.manage' },
  { key: '/plan', label: tr('Тариф', 'Tarif'), icon: <CrownOutlined /> },
]

// Кафе: вместо «Закупок» и «Склада» — «Меню», «Склад продуктов» и «Кухня»
// (Figma «Веб-панель», Panel/Sidebar · Кафе). Приход, списание и
// инвентаризация открываются со страницы «Склад продуктов».
const CAFE_ITEMS: Item[] = [
  { key: '/menu', label: tr('Меню', 'Menyu'), icon: <CoffeeOutlined /> },
  { key: '/kitchen-stock', label: tr('Склад продуктов', 'Mahsulotlar ombori'), icon: <ShopOutlined /> },
  { key: '/kitchen', label: tr('Кухня', 'Oshxona'), icon: <FireOutlined /> },
]

Object.assign(tabLabels, {
  '/menu/modifiers': tr('Меню / Модификаторы', 'Menyu / Modifikatorlar'),
  '/menu/stop': tr('Меню / Стоп-лист', 'Menyu / Stop-roʻyxat'),
  '/menu/dishes/new': tr('Меню / Новое блюдо', 'Menyu / Yangi taom'),
  '/menu/dishes/*': tr('Меню / Блюдо', 'Menyu / Taom'),
  '/kitchen-stock/preps': tr('Склад продуктов / Заготовки', 'Mahsulotlar ombori / Yarim tayyorlar'),
  '/kitchen-stock/preps/new': tr('Заготовки / Новая', 'Yarim tayyorlar / Yangi'),
  '/kitchen-stock/preps/*': tr('Заготовки / Техкарта', 'Yarim tayyorlar / Texkarta'),
})

function menuFor(cafe: boolean): Item[] {
  if (!cafe) return MENU
  const out: Item[] = []
  for (const i of MENU) {
    if (i.key === 'purchases' || i.key === 'stock' || i.key === '/start') continue
    out.push(i)
    if (i.key === '/orders') out.push(...CAFE_ITEMS)
  }
  // Касса кафе: схема залов (П9) рядом с «Кассы и ПИНы».
  const pos = out.findIndex((i) => i.key === 'pos')
  if (pos >= 0) {
    const ch = [...(out[pos].children ?? [])]
    ch.splice(1, 0, { key: '/pos/halls', label: tr('Залы и столы', 'Zallar va stollar'), perm: 'stores.manage' })
    out[pos] = { ...out[pos], children: ch }
  }
  return out
}

function filterMenu(items: Item[], can: (p: string) => boolean, has: (f: string) => boolean): MenuItem[] {
  const allowed = (i: Item) => allowedBy(i.perm, can)
  const out: MenuItem[] = []
  for (const i of items) {
    if (!allowed(i)) continue
    if (i.children) {
      const children = filterMenu(i.children, can, has)
      if (children.length) out.push({ key: i.key, label: i.label, icon: i.icon, children })
    } else {
      out.push({ key: i.key, label: i.label, icon: i.icon, extra: i.feature && !has(i.feature) ? <LockOutlined /> : undefined })
    }
  }
  return out
}

const allowedBy = (perm: Item['perm'], can: (p: string) => boolean) =>
  !perm || (Array.isArray(perm) ? perm.some(can) : can(perm))

/** Право на страницу — по пункту меню с самым длинным совпадающим путём. */
function permFor(path: string): Item['perm'] {
  let best: Item | undefined
  const walk = (items: Item[]) =>
    items.forEach((i) => {
      if (i.children) walk(i.children)
      else if (i.key !== '/' && (path === i.key || path.startsWith(i.key + '/')) && (!best || i.key.length > best.key.length)) best = i
    })
  walk(MENU)
  return best?.perm
}

/** Не пускает на страницу без права, даже по прямой ссылке. */
function Guard() {
  const { can, me, has, planLoading } = useStore()
  const { pathname } = useLocation()
  if (!me) return <Spin style={{ display: 'block', marginTop: 48 }} />
  const path = pathname.replace(/\/$/, '') || '/'
  if (!allowedBy(permFor(path), can)) {
    return <Result status="403" title={tr('Нет доступа', 'Ruxsat yoʻq')} subTitle={tr('У вашей роли нет права на этот раздел. Обратитесь к владельцу сети.', 'Rolingizda bu boʻlimga huquq yoʻq. Tarmoq egasiga murojaat qiling.')} />
  }
  // Страница закрыта тарифом — показываем, что даёт функция и на каком тарифе есть.
  const feature = Object.entries(FEATURE_BY_PATH).find(([p]) => path === p || path.startsWith(p + '/'))?.[1]
  if (feature && planLoading) return <Spin style={{ display: 'block', marginTop: 48 }} />
  if (feature && !has(feature)) return <LockedFeature feature={feature} />
  return <Outlet />
}

function Header() {
  const { stores, storeId, setStoreId } = useStore()
  return (
    <Flex align="center" gap={12} wrap={false} style={{ minWidth: 0 }}>
      <OrderAlerts />
      <PlanErrorHost />
      {stores.length > 0 && (
        <Select
          value={storeId || undefined}
          onChange={setStoreId}
          style={{ minWidth: 160, maxWidth: 280 }}
          options={stores.map((s) => ({ value: s.id, label: s.name }))}
          aria-label={tr('Магазин', 'Doʻkon')}
        />
      )}
    </Flex>
  )
}

export function StoreRoutes() {
  const { can, me, has } = useStore()
  // Ресторан — то же кафе, только касса открывается на зале со столами.
  const cafe = me?.network.business_type === 'cafe' || me?.network.business_type === 'restaurant'
  const menu = me ? filterMenu(menuFor(cafe), can, has) : []
  return (
    <SetupGate>
    <Routes>
      <Route path="setup" element={<SetupPage />} />
      <Route element={<Shell
          title={TITLE}
          menu={menu}
          header={<Header />}
          user={me ? { name: me.network.name, subtitle: me.is_owner ? tr('Владелец сети', 'Tarmoq egasi') : tr('Сотрудник', 'Xodim') } : undefined}
        />}>
       <Route element={<Guard />}>
        <Route index element={<DashboardPage />} />
        <Route path="start" element={<StartPage />} />
        <Route path="start/count" element={<StockCountPage />} />
        <Route path="orders" element={<OrdersPage />} />
        <Route path="couriers" element={<CouriersPage />} />
        <Route path="crowd" element={<CrowdPage />} />
        <Route path="showcase" element={<ShowcasePage />} />
        <Route path="brand-ads" element={<StoreAdsPage />} />

        <Route path="pos/devices" element={<PosDevicesPage />} />
        <Route path="pos/shifts" element={<PosShiftsPage />} />
        <Route path="debts" element={<DebtorsPage />} />
        <Route path="settings/debts" element={<DebtSettingsPage />} />

        <Route path="sales/pos" element={<SalesPage />} />
        <Route path="sales/returns" element={<ReturnsPage />} />
        <Route path="sales/prices" element={<PriceDocsPage />} />
        <Route path="sales/prices/:id" element={<PriceDocEditor />} />
        <Route path="sales/promotions" element={<PromotionsPage />} />
        <Route path="sales/promotions/:id" element={<PromotionEditor />} />

        {(Object.keys(docPaths) as (keyof typeof docPaths)[]).map((t) => [
          <Route key={t} path={docPaths[t].slice(1)} element={<StockDocsPage type={t} />} />,
          <Route key={t + ':id'} path={docPaths[t].slice(1) + '/:id'} element={<StockDocEditor type={t} />} />,
        ])}
        <Route path="stock/balance" element={<StockPage />} />
        <Route path="stock/movements" element={<MovementsPage />} />

        <Route path="finance/cashboxes" element={<CashboxesPage />} />
        <Route path="finance/operations" element={<OperationsPage />} />
        <Route path="finance/handovers" element={<TransfersPage kind="handover" />} />
        <Route path="finance/transfers" element={<TransfersPage kind="transfer" />} />
        <Route path="finance/rates" element={<RatesPage />} />

        <Route path="reports/cash-flow" element={<CashFlowPage />} />
        <Route path="reports/profit-loss" element={<ProfitLossPage />} />
        <Route path="reports/abc-xyz" element={<AbcXyzPage />} />

        <Route path="dirs/counterparties" element={<CounterpartiesPage />} />
        <Route path="dirs/counterparty-types" element={<CounterpartyTypesPage />} />
        <Route path="dirs/products" element={<ProductsPage />} />
        <Route path="dirs/brands" element={<DictPage kind="brands" title={tr('Бренды', 'Brendlar')} />} />
        <Route path="dirs/colors" element={<DictPage kind="colors" title={tr('Цвета', 'Ranglar')} />} />
        <Route path="dirs/categories" element={<DictPage kind="categories" title={tr('Категории', 'Kategoriyalar')} />} />
        <Route path="dirs/units" element={<DictPage kind="units" title={tr('Единицы измерения', 'Oʻlchov birliklari')} />} />
        <Route path="dirs/price-types" element={<PriceTypesPage />} />
        <Route path="dirs/warehouses" element={<WarehousesPage />} />
        <Route path="dirs/payment-methods" element={<PaymentMethodsPage />} />
        <Route path="dirs/reasons" element={<ReasonsPage />} />

        <Route path="settings/stores" element={<StoresPage />} />
        <Route path="settings/delivery" element={<DeliveryPage />} />
        <Route path="settings/roles" element={<RolesPage />} />
        <Route path="settings/employees" element={<EmployeesPage />} />

        {cafe && [
          <Route key="menu" path="menu" element={<MenuPage />} />,
          <Route key="mods" path="menu/modifiers" element={<ModifiersPage />} />,
          <Route key="stop" path="menu/stop" element={<StopListPage />} />,
          <Route key="dish" path="menu/dishes/:id" element={<DishEditorPage kind="dish" />} />,
          <Route key="kstock" path="kitchen-stock" element={<KitchenStockPage />} />,
          <Route key="preps" path="kitchen-stock/preps" element={<PrepsPage />} />,
          <Route key="prep-new" path="kitchen-stock/preps/new" element={<DishEditorPage kind="prep" />} />,
          <Route key="prep" path="kitchen-stock/preps/:id/edit" element={<DishEditorPage kind="prep" />} />,
          <Route key="kitchen" path="kitchen" element={<KitchenPage />} />,
          <Route key="halls" path="pos/halls" element={<HallsPage />} />,
        ]}
        <Route path="balance" element={<BalancePage />} />
        <Route path="plan" element={<PlanPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
       </Route>
      </Route>
    </Routes>
    </SetupGate>
  )
}
