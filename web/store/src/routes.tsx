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
} from '@ant-design/icons'
import { Shell, tr, type MenuItem } from '@sm/shared'
import { useStore } from './ctx'
import { DashboardPage } from './pages/Dashboard'
import { StartPage } from './pages/start/Start'
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

const TITLE = tr('Панель магазина', 'Doʻkon paneli')

type Item = { key: string; label: string; perm?: string | string[]; icon?: ReactNode; children?: Item[] }

// Меню как в Dokondor: группы разделов; perm — какое право нужно, чтобы видеть пункт.
// Права совпадают с правами сервера на чтение раздела (docs/api.md, «Права на чтение»).
const MENU: Item[] = [
  { key: '/', label: tr('Главная', 'Bosh sahifa'), icon: <DashboardOutlined /> },
  { key: '/start', label: tr('Начало работы', 'Ishni boshlash'), icon: <RocketOutlined />, perm: 'inventory.manage' },
  { key: '/orders', label: tr('Онлайн-заказы', 'Onlayn buyurtmalar'), icon: <ShoppingCartOutlined />, perm: 'orders.manage' },
  { key: '/couriers', label: tr('Курьеры', 'Kuryerlar'), icon: <CarOutlined />, perm: 'orders.manage' },
  { key: '/crowd', label: tr('Курьеры по пути', 'Yoʻlakay kuryerlar'), icon: <SafetyCertificateOutlined />, perm: 'orders.manage' },
  { key: '/showcase', label: tr('Витрина приложения', 'Ilova vitrinasi'), icon: <LayoutOutlined />, perm: 'showcase.manage' },
  { key: '/brand-ads', label: tr('Реклама брендов', 'Brendlar reklamasi'), icon: <NotificationOutlined />, perm: 'showcase.manage' },
  {
    key: 'sales',
    label: tr('Продажи', 'Sotuvlar'),
    icon: <ShoppingOutlined />,
    children: [
      { key: '/sales/pos', label: tr('Продажи POS', 'POS sotuvlari'), perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/returns', label: tr('Возвраты', 'Qaytarishlar'), perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/prices', label: tr('Установка цен', 'Narxlarni belgilash'), perm: 'prices.manage' },
      { key: '/sales/promotions', label: tr('Акции в приложении', 'Ilovadagi aksiyalar'), perm: 'prices.manage' },
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
  { key: '/debts', label: tr('Долги покупателей', 'Xaridorlar qarzlari'), icon: <AuditOutlined />, perm: ['debts.manage', 'debts.give'] },
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
      { key: '/reports/cash-flow', label: tr('Денежный поток', 'Pul oqimi'), perm: 'reports.view' },
      { key: '/reports/profit-loss', label: tr('Прибыль и убыток', 'Foyda va zarar'), perm: 'reports.view' },
      { key: '/reports/abc-xyz', label: tr('ABC/XYZ-анализ', 'ABC/XYZ tahlili'), perm: 'reports.view' },
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
      { key: '/settings/debts', label: tr('Долги покупателей', 'Xaridorlar qarzlari'), perm: ['debts.manage', 'debts.give'] },
      { key: '/settings/roles', label: tr('Роли', 'Rollar'), perm: 'staff.manage' },
      { key: '/settings/employees', label: tr('Сотрудники', 'Xodimlar'), perm: 'staff.manage' },
    ],
  },
  { key: '/balance', label: tr('Баланс и подписка', 'Balans va obuna'), icon: <WalletOutlined />, perm: 'payouts.manage' },
]

function filterMenu(items: Item[], can: (p: string) => boolean): MenuItem[] {
  const allowed = (i: Item) => allowedBy(i.perm, can)
  const out: MenuItem[] = []
  for (const i of items) {
    if (!allowed(i)) continue
    if (i.children) {
      const children = filterMenu(i.children, can)
      if (children.length) out.push({ key: i.key, label: i.label, icon: i.icon, children })
    } else {
      out.push({ key: i.key, label: i.label, icon: i.icon })
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
  const { can, me } = useStore()
  const { pathname } = useLocation()
  if (!me) return <Spin style={{ display: 'block', marginTop: 48 }} />
  if (!allowedBy(permFor(pathname.replace(/\/$/, '') || '/'), can)) {
    return <Result status="403" title={tr('Нет доступа', 'Ruxsat yoʻq')} subTitle={tr('У вашей роли нет права на этот раздел. Обратитесь к владельцу сети.', 'Rolingizda bu boʻlimga huquq yoʻq. Tarmoq egasiga murojaat qiling.')} />
  }
  return <Outlet />
}

function Header() {
  const { stores, storeId, setStoreId } = useStore()
  return (
    <Flex align="center" gap={12} wrap={false} style={{ minWidth: 0 }}>
      <OrderAlerts />
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
  const { can, me } = useStore()
  const menu = me ? filterMenu(MENU, can) : []
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

        <Route path="balance" element={<BalancePage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
       </Route>
      </Route>
    </Routes>
    </SetupGate>
  )
}
