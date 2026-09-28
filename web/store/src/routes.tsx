import type { ReactNode } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'
import { Flex, Select, Typography } from 'antd'
import {
  AppstoreOutlined,
  BarChartOutlined,
  BookOutlined,
  DashboardOutlined,
  DollarOutlined,
  InboxOutlined,
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

const TITLE = 'Панель магазина'

type Item = { key: string; label: string; perm?: string | string[]; icon?: ReactNode; children?: Item[] }

// Меню как в Dokondor: группы разделов; perm — какое право нужно, чтобы видеть пункт.
const MENU: Item[] = [
  { key: '/', label: 'Главная', icon: <DashboardOutlined /> },
  { key: '/orders', label: 'Онлайн-заказы', icon: <ShoppingCartOutlined />, perm: 'orders.manage' },
  {
    key: 'sales',
    label: 'Продажи',
    icon: <ShoppingOutlined />,
    children: [
      { key: '/sales/pos', label: 'Продажи POS', perm: ['sales.pos', 'sales.return', 'reports.view'] },
      { key: '/sales/returns', label: 'Возвраты', perm: ['sales.return', 'sales.pos'] },
      { key: '/sales/prices', label: 'Установка цен', perm: 'prices.manage' },
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
  const allowed = (i: Item) => !i.perm || (Array.isArray(i.perm) ? i.perm.some(can) : can(i.perm))
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

function Header() {
  const { me, stores, storeId, setStoreId } = useStore()
  return (
    <Flex align="center" gap={12} wrap={false} style={{ minWidth: 0 }}>
      <Typography.Text strong ellipsis style={{ maxWidth: 220 }}>
        {me?.network.name ?? ''}
      </Typography.Text>
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
      <Route element={<Shell title={TITLE} menu={menu} header={<Header />} />}>
        <Route index element={<DashboardPage />} />
        <Route path="orders" element={<OrdersPage />} />

        <Route path="sales/pos" element={<SalesPage />} />
        <Route path="sales/returns" element={<ReturnsPage />} />
        <Route path="sales/prices" element={<PriceDocsPage />} />
        <Route path="sales/prices/:id" element={<PriceDocEditor />} />

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
    </Routes>
  )
}
