import { Navigate, Route, Routes } from 'react-router-dom'
import { Shell, type MenuItem } from '@sm/shared'
import {
  AppstoreOutlined,
  BankOutlined,
  BellOutlined,
  DashboardOutlined,
  DollarOutlined,
  ShopOutlined,
  ShoppingCartOutlined,
  UserOutlined,
} from '@ant-design/icons'
import { Dashboard } from './pages/Dashboard'
import { Networks } from './pages/Networks'
import { Products, Dictionary } from './pages/Catalog'
import { Banners } from './pages/Banners'
import { AppHome } from './pages/AppHome'
import { Orders, Payments } from './pages/Orders'
import { Tariffs, BillingSettings, BillingNetworks, Invoices, Payouts } from './pages/Billing'
import { Customers } from './pages/Customers'
import { Notifications } from './pages/Notifications'

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
      { key: '/app-home', label: 'Главная приложения' },
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
  { key: '/customers', icon: <UserOutlined />, label: 'Покупатели' },
  { key: '/notifications', icon: <BellOutlined />, label: 'Уведомления' },
]

export function AdminRoutes() {
  return (
    <Routes>
      <Route element={<Shell title="Супер-админ" menu={menu} user={{ name: 'Супер-админ', subtitle: 'Платформа Super Market' }} />}>
        <Route index element={<Dashboard />} />
        <Route path="networks" element={<Networks />} />
        <Route path="products" element={<Products key="products" />} />
        <Route path="moderation" element={<Products key="moderation" moderation />} />
        <Route path="catalog/:kind" element={<Dictionary />} />
        <Route path="banners" element={<Banners />} />
        <Route path="app-home" element={<AppHome />} />
        <Route path="orders" element={<Orders key="orders" />} />
        <Route path="stale" element={<Orders key="stale" stale />} />
        <Route path="payments" element={<Payments />} />
        <Route path="billing/networks" element={<BillingNetworks />} />
        <Route path="billing/invoices" element={<Invoices />} />
        <Route path="billing/tariffs" element={<Tariffs />} />
        <Route path="billing/settings" element={<BillingSettings />} />
        <Route path="payouts" element={<Payouts />} />
        <Route path="customers" element={<Customers />} />
        <Route path="notifications" element={<Notifications />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}
