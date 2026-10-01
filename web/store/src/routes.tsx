import type { ReactNode } from 'react'
import { Navigate, Outlet, Route, Routes, useLocation } from 'react-router-dom'
import { Flex, Result, Select, Spin } from 'antd'
import {
  AppstoreOutlined,
  BarChartOutlined,
  BookOutlined,
  CarOutlined,
  DashboardOutlined,
  DollarOutlined,
  InboxOutlined,
  LayoutOutlined,
  SettingOutlined,
  ShoppingCartOutlined,
  ShoppingOutlined,
  WalletOutlined,
} from '@ant-design/icons'
import { Shell, type MenuItem } from '@sm/shared'
import { useStore } from './ctx'
import { DashboardPage } from './pages/Dashboard'
import { OrdersPage } from './pages/Orders'
import { ReturnsPage, SalesPage } from './pages/Sales'
import { PriceDocEditor, PriceDocsPage } from './pages/Prices'
import { PromotionEditor, PromotionsPage } from './pages/Promotions'
import { StockDocEditor, StockDocsPage, docPaths } from './pages/StockDocs'
import { MovementsPage, StockPage } from './pages/Stock'
import { CashboxesPage, OperationsPage, RatesPage, TransfersPage } from './pages/Finance'
import { CashFlowPage, ProfitLossPage } from './pages/Reports'
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
import { ShowcasePage } from './pages/Showcase'
import { OrderAlerts } from './notify'

const TITLE = 'Панель магазина'

type Item = { key: string; label: string; perm?: string | string[]; icon?: ReactNode; children?: Item[] }

// Меню как в Dokondor: группы разделов; perm — какое право нужно, чтобы видеть пункт.
// Права совпадают с правами сервера на чтение раздела (docs/api.md, «Права на чтение»).
const MENU: Item[] = [
  { key: '/', label: 'Главная', icon: <DashboardOutlined /> },
  { key: '/orders', label: 'Онлайн-заказы', icon: <ShoppingCartOutlined />, perm: 'orders.manage' },
  { key: '/couriers', label: 'Курьеры', icon: <CarOutlined />, perm: 'orders.manage' },
  { key: '/showcase', label: 'Витрина приложения', icon: <LayoutOutlined />, perm: 'showcase.manage' },
  {
    key: 'sales',
    label: 'Продажи',
    icon: <ShoppingOutlined />,
    children: [
      { key: '/sales/pos', label: 'Продажи POS', perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/returns', label: 'Возвраты', perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/prices', label: 'Установка цен', perm: 'prices.manage' },
      { key: '/sales/promotions', label: 'Акции в приложении', perm: 'prices.manage' },
    ],
  },
  {
    key: 'purchases',
    label: 'Закупки',
    icon: <InboxOutlined />,
    children: [
      { key: docPaths.income, label: 'Приход товара', perm: 'inventory.manage' },
      { key: docPaths.supplier_return, label: 'Возврат поставщику', perm: 'inventory.manage' },
    ],
  },
  {
    key: 'stock',
    label: 'Склад',
    icon: <AppstoreOutlined />,
    children: [
      { key: '/stock/balance', label: 'Остатки' },
      { key: docPaths.transfer, label: 'Между складами', perm: 'inventory.manage' },
      { key: docPaths.inventory, label: 'Инвентаризация', perm: 'inventory.manage' },
      { key: docPaths.write_off, label: 'Списание', perm: 'inventory.manage' },
      { key: docPaths.posting, label: 'Оприходование', perm: 'inventory.manage' },
      { key: '/stock/movements', label: 'История движения' },
    ],
  },
  {
    key: 'finance',
    label: 'Финансы',
    icon: <DollarOutlined />,
    children: [
      { key: '/finance/cashboxes', label: 'Кассы', perm: 'finance.manage' },
      { key: '/finance/operations', label: 'Кассовые операции', perm: 'finance.manage' },
      { key: '/finance/handovers', label: 'Сдача кассы', perm: 'finance.manage' },
      { key: '/finance/transfers', label: 'Из кассы в кассу', perm: 'finance.manage' },
      { key: '/finance/rates', label: 'Курс валюты', perm: 'finance.manage' },
    ],
  },
  {
    key: 'reports',
    label: 'Отчёты',
    icon: <BarChartOutlined />,
    children: [
      { key: '/reports/cash-flow', label: 'Денежный поток', perm: 'reports.view' },
      { key: '/reports/profit-loss', label: 'Прибыль и убыток', perm: 'reports.view' },
    ],
  },
  {
    key: 'dirs',
    label: 'Справочники',
    icon: <BookOutlined />,
    children: [
      { key: '/dirs/counterparties', label: 'Контрагенты', perm: ['counterparties.manage', 'inventory.manage', 'finance.manage'] },
      { key: '/dirs/counterparty-types', label: 'Типы контрагентов', perm: 'counterparties.manage' },
      { key: '/dirs/products', label: 'Товары' },
      { key: '/dirs/brands', label: 'Бренды' },
      { key: '/dirs/colors', label: 'Цвета' },
      { key: '/dirs/categories', label: 'Категории' },
      { key: '/dirs/units', label: 'Единицы' },
      { key: '/dirs/price-types', label: 'Типы цен', perm: ['catalog.manage', 'prices.manage'] },
      { key: '/dirs/warehouses', label: 'Склады', perm: ['stores.manage', 'inventory.manage'] },
      { key: '/dirs/payment-methods', label: 'Способы оплаты', perm: 'finance.manage' },
      { key: '/dirs/reasons', label: 'Финансовые причины', perm: 'finance.manage' },
    ],
  },
  {
    key: 'settings',
    label: 'Настройки',
    icon: <SettingOutlined />,
    children: [
      { key: '/settings/stores', label: 'Магазины', perm: 'stores.manage' },
      { key: '/settings/delivery', label: 'Доставка', perm: 'stores.manage' },
      { key: '/settings/roles', label: 'Роли', perm: 'staff.manage' },
      { key: '/settings/employees', label: 'Сотрудники', perm: 'staff.manage' },
    ],
  },
  { key: '/balance', label: 'Баланс и подписка', icon: <WalletOutlined />, perm: 'payouts.manage' },
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
    return <Result status="403" title="Нет доступа" subTitle="У вашей роли нет права на этот раздел. Обратитесь к владельцу сети." />
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
          aria-label="Магазин"
        />
      )}
    </Flex>
  )
}

export function StoreRoutes() {
  const { can, me } = useStore()
  const menu = me ? filterMenu(MENU, can) : []
  return (
    <Routes>
      <Route element={<Shell
          title={TITLE}
          menu={menu}
          header={<Header />}
          user={me ? { name: me.network.name, subtitle: me.is_owner ? 'Владелец сети' : 'Сотрудник' } : undefined}
        />}>
       <Route element={<Guard />}>
        <Route index element={<DashboardPage />} />
        <Route path="orders" element={<OrdersPage />} />
        <Route path="couriers" element={<CouriersPage />} />
        <Route path="showcase" element={<ShowcasePage />} />

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

        <Route path="dirs/counterparties" element={<CounterpartiesPage />} />
        <Route path="dirs/counterparty-types" element={<CounterpartyTypesPage />} />
        <Route path="dirs/products" element={<ProductsPage />} />
        <Route path="dirs/brands" element={<DictPage kind="brands" title="Бренды" />} />
        <Route path="dirs/colors" element={<DictPage kind="colors" title="Цвета" />} />
        <Route path="dirs/categories" element={<DictPage kind="categories" title="Категории" />} />
        <Route path="dirs/units" element={<DictPage kind="units" title="Единицы измерения" />} />
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
  )
}
