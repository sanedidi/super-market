import { useState, type ReactNode } from 'react'
import { BrowserRouter, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { App as AntApp, Button, ConfigProvider, Drawer, Grid, Layout, Menu, Typography, type MenuProps } from 'antd'
import { LogoutOutlined, MenuOutlined } from '@ant-design/icons'
import ruRU from 'antd/locale/ru_RU'
import dayjs from 'dayjs'
import 'dayjs/locale/ru'
import { ApiError, configureApi, type AppName } from './api'
import { AuthProvider, LoginPage, useAuth } from './auth'

dayjs.locale('ru')

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      refetchOnWindowFocus: false,
      retry: (n, e) => !(e instanceof ApiError && e.status >= 400 && e.status < 500) && n < 2,
    },
  },
})

/** Провайдеры приложения и экран входа. */
export function AppRoot({ app, basename, title, children }: { app: AppName; basename: string; title: string; children: ReactNode }) {
  configureApi(app)
  return (
    <ConfigProvider locale={ruRU} theme={{ token: { colorPrimary: '#16a34a', borderRadius: 8 } }}>
      <AntApp>
        <QueryClientProvider client={queryClient}>
          <AuthProvider app={app}>
            <BrowserRouter basename={basename}>
              <Gate app={app} title={title}>
                {children}
              </Gate>
            </BrowserRouter>
          </AuthProvider>
        </QueryClientProvider>
      </AntApp>
    </ConfigProvider>
  )
}

function Gate({ app, title, children }: { app: AppName; title: string; children: ReactNode }) {
  const { loggedIn } = useAuth()
  if (!loggedIn) {
    queryClient.clear()
    return <LoginPage app={app} title={title} />
  }
  return <>{children}</>
}

export type MenuItem = Required<MenuProps>['items'][number]

/** Боковое меню + шапка. Пункты меню — пути роутера. */
export function Shell({ title, menu, header }: { title: string; menu: MenuItem[]; header?: ReactNode }) {
  const { logout } = useAuth()
  const nav = useNavigate()
  const loc = useLocation()
  const screens = Grid.useBreakpoint()
  const [drawer, setDrawer] = useState(false)
  const selected = '/' + (loc.pathname.split('/')[1] ?? '')
  const full = loc.pathname.replace(/\/$/, '') || '/'
  const parent = menu.find(
    (m) => m && 'children' in m && (m.children ?? []).some((c) => c && String(c.key) === full),
  )

  const menuEl = (
    <Menu
      mode="inline"
      selectedKeys={[full, selected]}
      defaultOpenKeys={parent ? [String(parent.key)] : []}
      items={menu}
      onClick={(e) => {
        nav(e.key)
        setDrawer(false)
      }}
      style={{ borderInlineEnd: 0 }}
    />
  )

  return (
    <Layout style={{ minHeight: '100vh' }}>
      {screens.lg ? (
        <Layout.Sider width={250} theme="light" style={{ borderRight: '1px solid #f0f0f0', overflow: 'auto', height: '100vh', position: 'sticky', top: 0 }}>
          <Typography.Title level={4} style={{ padding: '16px 24px', margin: 0 }}>
            {title}
          </Typography.Title>
          {menuEl}
        </Layout.Sider>
      ) : (
        <Drawer open={drawer} onClose={() => setDrawer(false)} placement="left" width={270} title={title} styles={{ body: { padding: 0 } }}>
          {menuEl}
        </Drawer>
      )}
      <Layout>
        <Layout.Header
          style={{ background: '#fff', padding: '0 16px', display: 'flex', alignItems: 'center', gap: 12, borderBottom: '1px solid #f0f0f0' }}
        >
          {!screens.lg && <Button icon={<MenuOutlined />} onClick={() => setDrawer(true)} />}
          <div style={{ flex: 1, minWidth: 0 }}>{header}</div>
          <Button icon={<LogoutOutlined />} onClick={() => logout()}>
            Выйти
          </Button>
        </Layout.Header>
        <Layout.Content style={{ padding: screens.md ? 24 : 12 }}>
          <Outlet />
        </Layout.Content>
      </Layout>
    </Layout>
  )
}
