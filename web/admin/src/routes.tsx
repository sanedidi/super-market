import { Navigate, Route, Routes } from 'react-router-dom'
import { Shell, tabLabels, type MenuItem } from '@sm/shared'
import {
  AppstoreOutlined,
  BankOutlined,
  BellOutlined,
  BulbOutlined,
  CarOutlined,
  CloudSyncOutlined,
  DeliveredProcedureOutlined,
  DashboardOutlined,
  DollarOutlined,
  PictureOutlined,
  RiseOutlined,
  ShopOutlined,
  ShoppingCartOutlined,
  TranslationOutlined,
  UserOutlined,
} from '@ant-design/icons'
import { Dashboard } from './pages/Dashboard'
import { Networks } from './pages/Networks'
import { Products, Dictionary } from './pages/Catalog'
import { ProductPage } from './pages/Product'
import { Variants } from './pages/Variants'
import { BrandRequests } from './pages/BrandRequests'
import { ProductSuggestions } from './pages/ProductSuggestions'
import { Banners } from './pages/Banners'
import { AppHome } from './pages/AppHome'
import { Ads } from './pages/Ads'
import { Orders, Payments } from './pages/Orders'
import { BillingSettings, BillingNetworks, Invoices, Payouts } from './pages/Billing'
import { Plans } from './pages/Plans'
import { Customers } from './pages/Customers'
import { Crowd } from './pages/Crowd'
import { Wishes } from './pages/Wishes'
import { AISettings } from './pages/AI'
import { AIPhoto } from './pages/AIPhoto'
import { StorePhotos } from './pages/StorePhotos'
import { Translations } from './pages/Translations'
import { Notifications, PushCampaign, PushNew } from './pages/Push'
import { InvestNowBadge, InvestVisitors } from './pages/InvestVisitors'
import { AppVersions } from './pages/AppVersions'

const menu: MenuItem[] = [
  { key: '/', icon: <DashboardOutlined />, label: 'Главная' },
  { key: '/networks', icon: <ShopOutlined />, label: 'Сети и магазины' },
  {
    key: 'catalog',
    icon: <AppstoreOutlined />,
    label: 'Каталог',
    children: [
      { key: '/products', label: 'Товары' },
      { key: '/catalog/variants', label: 'Вариации' },
      { key: '/moderation', label: 'Модерация' },
      { key: '/catalog/categories', label: 'Категории' },
      { key: '/catalog/brands', label: 'Бренды' },
      { key: '/catalog/brand-requests', label: 'Заявки на бренды' },
      { key: '/catalog/product-suggestions', label: 'Исправления от магазинов' },
      { key: '/catalog/colors', label: 'Цвета' },
      { key: '/catalog/units', label: 'Единицы измерения' },
      { key: '/banners', label: 'Баннеры в приложении' },
      { key: '/app-home', label: 'Главная приложения' },
      { key: '/ads', label: 'Реклама брендов' },
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
    label: 'Тарифы и подписка',
    children: [
      { key: '/billing/tariffs', label: 'Тарифы' },
      { key: '/billing/networks', label: 'Сети и оплата' },
      { key: '/billing/invoices', label: 'Счета' },
      { key: '/billing/settings', label: 'Настройки' },
    ],
  },
  { key: '/crowd', icon: <CarOutlined />, label: 'Курьеры по пути' },
  { key: '/delivery-wishes', icon: <DeliveredProcedureOutlined />, label: 'Спрос на доставку' },
  { key: '/payouts', icon: <BankOutlined />, label: 'Выводы денег' },
  { key: '/customers', icon: <UserOutlined />, label: 'Покупатели' },
  { key: '/notifications', icon: <BellOutlined />, label: 'Уведомления' },
  { key: '/ai', icon: <BulbOutlined />, label: 'ИИ-сервис' },
  { key: '/ai-photo', icon: <PictureOutlined />, label: 'ИИ для фото' },
  { key: '/invest', icon: <RiseOutlined />, label: 'Инвест-страница', extra: <InvestNowBadge /> },
  { key: '/translations', icon: <TranslationOutlined />, label: 'Переводы' },
  { key: '/app-versions', icon: <CloudSyncOutlined />, label: 'Версии приложений' },
]

// Подстраницы, которых нет в меню, — подписи вкладок.
tabLabels['/ai-photo/store'] = 'Фото магазинов'

export function AdminRoutes() {
  return (
    <Routes>
      <Route element={<Shell title="Супер-админ" menu={menu} user={{ name: 'Супер-админ', subtitle: 'Платформа Super Market' }} />}>
        <Route index element={<Dashboard />} />
        <Route path="networks" element={<Networks />} />
        <Route path="products" element={<Products key="products" />} />
        <Route path="products/:id" element={<ProductPage />} />
        <Route path="moderation" element={<Products key="moderation" moderation />} />
        <Route path="catalog/variants" element={<Variants />} />
        <Route path="catalog/brand-requests" element={<BrandRequests />} />
        <Route path="catalog/product-suggestions" element={<ProductSuggestions />} />
        <Route path="catalog/:kind" element={<Dictionary />} />
        <Route path="banners" element={<Banners />} />
        <Route path="app-home" element={<AppHome />} />
        <Route path="ads" element={<Ads />} />
        <Route path="orders" element={<Orders key="orders" />} />
        <Route path="stale" element={<Orders key="stale" stale />} />
        <Route path="payments" element={<Payments />} />
        <Route path="billing/networks" element={<BillingNetworks />} />
        <Route path="billing/invoices" element={<Invoices />} />
        <Route path="billing/tariffs" element={<Plans />} />
        <Route path="billing/showcase" element={<Navigate to="/billing/tariffs" replace />} />
        <Route path="billing/settings" element={<BillingSettings />} />
        <Route path="crowd" element={<Crowd />} />
        <Route path="delivery-wishes" element={<Wishes />} />
        <Route path="payouts" element={<Payouts />} />
        <Route path="customers" element={<Customers />} />
        <Route path="notifications" element={<Notifications />} />
        <Route path="ai" element={<AISettings />} />
        <Route path="ai-photo" element={<AIPhoto />} />
        <Route path="ai-photo/store" element={<StorePhotos />} />
        <Route path="translations" element={<Translations />} />
        <Route path="app-versions" element={<AppVersions />} />
        <Route path="invest" element={<InvestVisitors />} />
        <Route path="notifications/new" element={<PushNew />} />
        <Route path="notifications/:id" element={<PushCampaign />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}
