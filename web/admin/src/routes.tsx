import { Navigate, Route, Routes } from 'react-router-dom'
import { Shell, tabLabels, type MenuItem } from '@sm/shared'
import {
  AppstoreOutlined,
  AuditOutlined,
  BankOutlined,
  BellOutlined,
  BlockOutlined,
  BookOutlined,
  BulbOutlined,
  CarOutlined,
  CloudSyncOutlined,
  DeliveredProcedureOutlined,
  DashboardOutlined,
  DollarOutlined,
  FundProjectionScreenOutlined,
  InboxOutlined,
  MobileOutlined,
  NotificationOutlined,
  PictureOutlined,
  RiseOutlined,
  ShopOutlined,
  ShoppingCartOutlined,
  TranslationOutlined,
  UserAddOutlined,
  UserOutlined,
  NodeIndexOutlined,
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
import { WebPhotos } from './pages/WebPhotos'
import { Translations } from './pages/Translations'
import { Notifications, PushCampaign, PushNew } from './pages/Push'
import { InvestNowBadge, InvestVisitors } from './pages/InvestVisitors'
import { AppVersions } from './pages/AppVersions'
import { AgentRewards, StoreLeads, StoreLeadsBadge } from './pages/StoreLeads'
import { Field, FieldBadge } from './pages/Field'

// Разделы меню (Figma «Сайдбар · группировка разделов»): серые заголовки, подменю — панелью справа.
const menu: MenuItem[] = [
  { key: '/', icon: <DashboardOutlined />, label: 'Главная' },
  {
    type: 'group',
    key: 'sec-shops',
    label: 'Магазины',
    children: [
      { key: '/networks', icon: <ShopOutlined />, label: 'Сети и магазины' },
      { key: '/store-leads', icon: <UserAddOutlined />, label: 'Заявки агентов', extra: <StoreLeadsBadge /> },
      { key: '/field', icon: <NodeIndexOutlined />, label: 'Продажники', extra: <FieldBadge /> },
      {
        key: 'billing',
        icon: <DollarOutlined />,
        label: 'Тарифы и счета',
        children: [
          { key: '/billing/tariffs', label: 'Тарифы' },
          { key: '/billing/networks', label: 'Сети и оплата' },
          { key: '/billing/invoices', label: 'Счета' },
          { key: '/billing/agent-rewards', label: 'Агентам' },
          { key: '/billing/settings', label: 'Настройки' },
        ],
      },
      { key: '/payouts', icon: <BankOutlined />, label: 'Выводы денег' },
    ],
  },
  {
    type: 'group',
    key: 'sec-catalog',
    label: 'Каталог',
    children: [
      { key: '/products', icon: <AppstoreOutlined />, label: 'Товары' },
      { key: '/moderation', icon: <AuditOutlined />, label: 'Модерация' },
      { key: '/catalog/variants', icon: <BlockOutlined />, label: 'Вариации' },
      {
        key: 'dicts',
        icon: <BookOutlined />,
        label: 'Справочники',
        children: [
          { key: '/catalog/categories', label: 'Категории' },
          { key: '/catalog/brands', label: 'Бренды' },
          { key: '/catalog/colors', label: 'Цвета' },
          { key: '/catalog/units', label: 'Единицы измерения' },
        ],
      },
      {
        key: 'requests',
        icon: <InboxOutlined />,
        label: 'Заявки',
        children: [
          { key: '/catalog/brand-requests', label: 'Заявки на бренды' },
          { key: '/catalog/product-suggestions', label: 'Исправления от магазинов' },
        ],
      },
    ],
  },
  {
    type: 'group',
    key: 'sec-orders',
    label: 'Заказы и доставка',
    children: [
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
      { key: '/crowd', icon: <CarOutlined />, label: 'Курьеры по пути' },
      { key: '/delivery-wishes', icon: <DeliveredProcedureOutlined />, label: 'Спрос на доставку' },
    ],
  },
  {
    type: 'group',
    key: 'sec-app',
    label: 'Для покупателей',
    children: [
      { key: '/customers', icon: <UserOutlined />, label: 'Покупатели' },
      { key: '/app-home', icon: <MobileOutlined />, label: 'Главная приложения' },
      { key: '/banners', icon: <FundProjectionScreenOutlined />, label: 'Баннеры' },
      { key: '/ads', icon: <NotificationOutlined />, label: 'Реклама брендов' },
      { key: '/notifications', icon: <BellOutlined />, label: 'Уведомления' },
    ],
  },
  {
    type: 'group',
    key: 'sec-system',
    label: 'ИИ и система',
    children: [
      { key: '/ai', icon: <BulbOutlined />, label: 'ИИ-сервис' },
      { key: '/ai-photo', icon: <PictureOutlined />, label: 'ИИ для фото' },
      { key: '/translations', icon: <TranslationOutlined />, label: 'Переводы' },
      { key: '/app-versions', icon: <CloudSyncOutlined />, label: 'Версии приложений' },
      { key: '/invest', icon: <RiseOutlined />, label: 'Инвест-страница', extra: <InvestNowBadge /> },
    ],
  },
]

// Подстраницы, которых нет в меню, — подписи вкладок.
tabLabels['/ai-photo/store'] = 'Фото магазинов'
tabLabels['/ai-photo/web'] = 'Фото из сети'

export function AdminRoutes() {
  return (
    <Routes>
      <Route element={<Shell title="Супер-админ" menu={menu} user={{ name: 'Супер-админ', subtitle: 'Платформа Super Market' }} />}>
        <Route index element={<Dashboard />} />
        <Route path="networks" element={<Networks />} />
        <Route path="store-leads" element={<StoreLeads />} />
        <Route path="field" element={<Field />} />
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
        <Route path="billing/agent-rewards" element={<AgentRewards />} />
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
        <Route path="ai-photo/web" element={<WebPhotos />} />
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
