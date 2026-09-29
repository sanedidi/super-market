import { Navigate, Route, Routes } from 'react-router-dom'
import { Shell, type MenuItem } from '@sm/shared'
import {
  AppstoreOutlined,
  BankOutlined,
  DashboardOutlined,
  DollarOutlined,
  ShopOutlined,
  ShoppingCartOutlined,
} from '@ant-design/icons'
import { Dashboard } from './pages/Dashboard'
import { Networks } from './pages/Networks'
import { Products, Dictionary } from './pages/Catalog'
import { Banners } from './pages/Banners'
import { Orders, Payments } from './pages/Orders'
import { Tariffs, BillingSettings, BillingNetworks, Invoices, Payouts } from './pages/Billing'

const menu: MenuItem[] = [
  { key: '/', icon: <DashboardOutlined />, label: 'Главная' },
  { key: '/networks', icon: <ShopOutlined />, label: 'Сети и магазины' },
  {
    key: 'catalog',
    icon: <AppstoreOutlined />,
    label: 'Каталог',
    children: [
      { key: '/products', label: 'Товары' },
      { key: '/moderation', label: 'Модерация' },
      { key: '/catalog/categories', label: 'Категории' },
      { key: '/catalog/brands', label: 'Бренды' },
      { key: '/catalog/colors', label: 'Цвета' },
      { key: '/catalog/units', label: 'Единицы измерения' },
      { key: '/banners', label: 'Баннеры в приложении' },
    ],
  },
  {
    key: 'orders',
    icon: <ShoppingCartOutlined />,
    label: 'Заказы',
    children: [
      { key: '/orders', label: 'Все заказы' },
      { key: '/stale', label: 'Не приняты вовремя' },
      { key: '/payments', label: 'Платежи и возвраты' },
    ],
  },
  {
    key: 'billing',
    icon: <DollarOutlined />,
    label: 'Подписка',
    children: [
      { key: '/billing/networks', label: 'Сети и оплата' },
      { key: '/billing/invoices', label: 'Счета' },
      { key: '/billing/tariffs', label: 'Тарифы' },
      { key: '/billing/settings', label: 'Настройки' },
    ],
  },
  { key: '/payouts', icon: <BankOutlined />, label: 'Выводы денег' },
]

export function AdminRoutes() {
  return (
    <Routes>
      <Route element={<Shell title="Супер-админ" menu={menu} />}>
        <Route index element={<Dashboard />} />
        <Route path="networks" element={<Networks />} />
        <Route path="products" element={<Products />} />
        <Route path="moderation" element={<Products moderation />} />
        <Route path="catalog/:kind" element={<Dictionary />} />
        <Route path="banners" element={<Banners />} />
        <Route path="orders" element={<Orders />} />
        <Route path="stale" element={<Orders stale />} />
        <Route path="payments" element={<Payments />} />
        <Route path="billing/networks" element={<BillingNetworks />} />
        <Route path="billing/invoices" element={<Invoices />} />
        <Route path="billing/tariffs" element={<Tariffs />} />
        <Route path="billing/settings" element={<BillingSettings />} />
        <Route path="payouts" element={<Payouts />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}
