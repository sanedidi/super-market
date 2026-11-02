import { createContext, Fragment, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { BrowserRouter, Outlet, useLocation, useNavigate, useNavigationType } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { App as AntApp, Button, ConfigProvider, Drawer, Grid, type MenuProps } from 'antd'
import { CloseOutlined, DeleteOutlined, DownOutlined, LeftOutlined, LogoutOutlined, MenuOutlined, PushpinOutlined, RightOutlined, TranslationOutlined } from '@ant-design/icons'
import ruRU from 'antd/locale/ru_RU'
import uzUZ from 'antd/locale/uz_UZ'
import dayjs from 'dayjs'
import 'dayjs/locale/ru'
import 'dayjs/locale/uz-latn'
import { ApiError, configureApi, type AppName } from './api'
import { AuthProvider, LoginPage, useAuth } from './auth'
import { StorePasswordGate } from './passwordLogin'
import { guardedNavigate } from './leaveGuard'
import { getLang, i18nEnabled, setLang, tr } from './i18n'
import './theme.css'
import logo from './logo.png'

dayjs.locale(getLang() === 'uz' ? 'uz-latn' : 'ru')

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      refetchOnWindowFocus: false,
      retry: (n, e) => !(e instanceof ApiError && e.status >= 400 && e.status < 500) && n < 2,
    },
  },
})

/** Тема antd под дизайн Hamroh: тёмные основные кнопки, шрифт Nunito Sans, скругления. */
const theme = {
  token: {
    colorPrimary: '#1f2937',
    colorLink: '#0040c1',
    colorInfo: '#0040c1',
    colorSuccess: '#17b26a',
    colorError: '#b3261e',
    colorWarning: '#d97706',
    colorErrorText: '#b3261e',
    colorTextTertiary: '#667085',
    colorTextQuaternary: '#98a2b3',
    colorFillAlter: '#f9fafb',
    colorPrimaryHover: '#111827',
    colorPrimaryActive: '#111827',
    colorLinkHover: '#1746a2',
    colorText: '#101828',
    colorTextSecondary: '#475467',
    colorBorder: '#cbd5e1',
    colorBorderSecondary: '#eaecf0',
    colorBgLayout: '#f2f4f7',
    borderRadius: 8,
    borderRadiusLG: 16,
    fontFamily: "'Nunito Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
    fontSize: 14,
    controlHeight: 36,
  },
  components: {
    Button: { fontWeight: 600, primaryShadow: 'none', defaultShadow: 'none', dangerShadow: 'none' },
    Table: { headerBg: '#f9fafb', headerColor: '#475467', rowHoverBg: '#f2f4f7', borderColor: '#eaecf0' },
    Card: { headerFontSize: 16 },
    Tabs: { itemColor: '#516075', itemSelectedColor: '#0f172a', inkBarColor: '#3761e9', itemHoverColor: '#0f172a' },
    Segmented: { itemSelectedBg: '#0f172a', itemSelectedColor: '#fff' },
    Modal: { titleFontSize: 18 },
    Checkbox: { colorPrimary: '#2d3e50', colorPrimaryHover: '#1e293b' },
  },
}

/** Провайдеры приложения и экран входа. */
export function AppRoot({ app, basename, title, children }: { app: AppName; basename: string; title: string; children: ReactNode }) {
  configureApi(app)
  return (
    <ConfigProvider
      locale={getLang() === 'uz' ? uzUZ : ruRU}
      theme={theme}
      renderEmpty={() => <div style={{ padding: 24, color: '#667085', textAlign: 'center' }}>{tr('Пока пусто', 'Hozircha boʻsh')}</div>}
    >
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
  if (app === 'store') return <StorePasswordGate title={title}>{children}</StorePasswordGate>
  return <>{children}</>
}

export type MenuItem = Required<MenuProps>['items'][number]

// extra — значок справа от пункта (например, замок функции не по тарифу).
// section — раздел меню: серый заголовок и пункты под ним (в antd-меню — { type: 'group' }).
type NavItem = { key: string; label: ReactNode; icon?: ReactNode; extra?: ReactNode; children?: NavItem[]; section?: boolean }

function toNav(items: MenuItem[]): NavItem[] {
  return (items ?? [])
    .filter(Boolean)
    .map((m, n) => {
      const i = m as unknown as { key?: string; type?: string; label: ReactNode; icon?: ReactNode; extra?: ReactNode; children?: MenuItem[] }
      return {
        key: String(i.key ?? `section-${n}`),
        label: i.label,
        icon: i.icon,
        extra: i.extra,
        children: i.children ? toNav(i.children) : undefined,
        section: i.type === 'group' || undefined,
      }
    })
}

/** Пункты без разделов: раздел раскрывается в свои пункты. */
const flat = (items: NavItem[]): NavItem[] => items.flatMap((i) => (i.section ? flat(i.children ?? []) : [i]))

const text = (n: ReactNode) => (typeof n === 'string' || typeof n === 'number' ? String(n) : '')

/**
 * Подписи вкладок для страниц, которых нет в меню (подстраница пункта меню):
 * путь → подпись («/путь/*» — для всех страниц под путём). Без записи такая
 * страница подписывается «Пункт / Документ».
 */
export const tabLabels: Record<string, string> = {}

/** Подпись страницы для полосы вкладок: «Группа / Пункт» по самому длинному совпадению пути. */
function labelFor(nav: NavItem[], path: string): string {
  if (tabLabels[path]) return tabLabels[path]
  // «/menu/dishes/*» — подпись для всех страниц под этим путём.
  const wild = Object.keys(tabLabels)
    .filter((k) => k.endsWith('/*') && path.startsWith(k.slice(0, -1)))
    .sort((a, b) => b.length - a.length)[0]
  if (wild) return tabLabels[wild]
  let best: { key: string; label: string } | undefined
  const walk = (items: NavItem[], parent?: string) =>
    items.forEach((i) => {
      if (i.children) return walk(i.children, text(i.label))
      const hit = i.key === '/' ? path === '/' : path === i.key || path.startsWith(i.key + '/')
      if (hit && (!best || i.key.length > best.key.length)) {
        best = { key: i.key, label: parent ? `${parent} / ${text(i.label)}` : text(i.label) }
      }
    })
  walk(flat(nav))
  if (!best) return tr('Страница', 'Sahifa')
  if (path !== best.key && best.key !== '/') {
    const last = path.slice(best.key.length + 1).split('/').pop() ?? ''
    return `${best.label} / ${last === 'new' ? tr('Создать', 'Yaratish') : tr('Документ', 'Hujjat')}`
  }
  return best.label
}

// ─── Контекст оболочки: что показывать справа в шапке страницы ────────────

interface ShellCtx {
  headerExtra?: ReactNode
}

const ShellContext = createContext<ShellCtx>({})

export function useShell() {
  return useContext(ShellContext)
}

/** Логотип: знак и название. */
export function Brand({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div className="sm-brand">
      <span className="sm-brand-mark">
        <img src={logo} alt="Super Market" />
      </span>
      <span className="sm-brand-text">
        {title}
        {subtitle && <small>{subtitle}</small>}
      </span>
    </div>
  )
}

const PIN_KEY = 'sm_sidebar_pinned'

function readPinned(): boolean {
  try {
    return localStorage.getItem(PIN_KEY) !== 'false'
  } catch {
    return true
  }
}

function Sidebar({
  title,
  nav,
  user,
  collapsible,
  onNavigate,
}: {
  title: string
  nav: NavItem[]
  user?: { name: string; subtitle?: string }
  collapsible: boolean
  onNavigate?: () => void
}) {
  const navigate = useNavigate()
  const { pathname } = useLocation()
  const { logout } = useAuth()
  const [pinned, setPinned] = useState(readPinned)
  const [hovered, setHovered] = useState(false)
  // Открытое подменю — ключ пункта. На компьютере подменю — панель справа от сайдбара,
  // в шторке на телефоне — список вместо меню с кнопкой «Назад» (Figma «Сайдбар · группировка»).
  const [fly, setFly] = useState<string | null>(null)
  const [userMenu, setUserMenu] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>()
  const asideRef = useRef<HTMLElement>(null)
  const flyRef = useRef<HTMLDivElement>(null)
  const expanded = !collapsible || pinned || hovered

  const matches = (key: string) => (key === '/' ? pathname === '/' : pathname === key || pathname.startsWith(key + '/'))
  const activeKey = useMemo(() => {
    let best = ''
    const walk = (items: NavItem[]) =>
      items.forEach((i) => {
        if (i.children) walk(i.children)
        else if (matches(i.key) && i.key.length > best.length) best = i.key
      })
    walk(nav)
    return best
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nav, pathname])
  const items = useMemo(() => flat(nav), [nav])
  const activeParent = items.find((p) => p.children?.some((c) => c.key === activeKey))?.key
  const flyItem = fly ? items.find((i) => i.key === fly && i.children) : undefined

  useEffect(() => {
    try {
      localStorage.setItem(PIN_KEY, String(pinned))
    } catch {
      // приватный режим
    }
  }, [pinned])

  // Перешли на другую страницу — подменю закрывается.
  useEffect(() => setFly(null), [pathname])

  /** Панель подменю — на уровне своего пункта, справа от сайдбара; за край экрана не вылезает. */
  const place = useCallback(() => {
    const aside = asideRef.current
    const el = flyRef.current
    if (!aside || !el || !fly) return
    const btn = aside.querySelector<HTMLElement>(`[data-fly="${CSS.escape(fly)}"]`)
    const a = aside.getBoundingClientRect()
    const top = (btn?.getBoundingClientRect().top ?? a.top) - 6
    el.style.left = `${a.right + 8}px`
    el.style.top = `${Math.max(8, Math.min(top, window.innerHeight - el.offsetHeight - 8))}px`
  }, [fly])

  useLayoutEffect(() => {
    if (!fly || !collapsible) return
    place()
    const aside = asideRef.current
    const list = aside?.querySelector('.sm-nav')
    // Сайдбар раскрывается и сворачивается с анимацией — панель едет вместе с его краем.
    const ro = new ResizeObserver(place)
    if (aside) ro.observe(aside)
    const down = (e: MouseEvent) => {
      const t = e.target as Node
      if (!asideRef.current?.contains(t) && !flyRef.current?.contains(t)) setFly(null)
    }
    const esc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setFly(null)
    }
    window.addEventListener('resize', place)
    list?.addEventListener('scroll', place)
    document.addEventListener('mousedown', down)
    document.addEventListener('keydown', esc)
    return () => {
      ro.disconnect()
      window.removeEventListener('resize', place)
      list?.removeEventListener('scroll', place)
      document.removeEventListener('mousedown', down)
      document.removeEventListener('keydown', esc)
    }
  }, [fly, collapsible, place])

  // Незакреплённое меню раскрыто, пока мышь над сайдбаром или над панелью подменю.
  const keep = () => {
    clearTimeout(timer.current)
    if (collapsible && !pinned) setHovered(true)
  }
  const leave = () => {
    if (!collapsible || pinned) return
    clearTimeout(timer.current)
    timer.current = setTimeout(() => {
      setHovered(false)
      setUserMenu(false)
      setFly(null)
    }, 150)
  }

  const go = (key: string) =>
    guardedNavigate(() => {
      setFly(null)
      navigate(key)
      onNavigate?.()
    })

  const initials = (user?.name ?? title)
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase())
    .join('')

  const child = (c: NavItem) => (
    <button key={c.key} role="menuitem" className={`sm-glass sm-child ${activeKey === c.key ? 'active' : ''}`} onClick={() => go(c.key)}>
      <span className="sm-child-label">{c.label}</span>
      {c.extra && <span className="sm-link-extra">{c.extra}</span>}
    </button>
  )

  const link = (item: NavItem) => {
    if (!item.children) {
      return (
        <button
          key={item.key}
          className={`sm-glass sm-link ${activeKey === item.key ? 'active' : ''}`}
          onClick={() => go(item.key)}
          title={expanded ? undefined : text(item.label)}
        >
          <span className="sm-link-icon">{item.icon}</span>
          {expanded && <span className="sm-link-label">{item.label}</span>}
          {expanded && item.extra && <span className="sm-link-extra">{item.extra}</span>}
        </button>
      )
    }
    const open = fly === item.key
    return (
      <button
        key={item.key}
        data-fly={item.key}
        aria-haspopup="menu"
        aria-expanded={open}
        className={`sm-glass sm-link ${open || activeParent === item.key ? 'active' : ''} ${open ? 'open' : ''}`}
        onClick={() => setFly(open ? null : item.key)}
        // Пока одно подменю открыто, наведение на другой такой пункт сразу переключает панель.
        onMouseEnter={() => {
          if (collapsible && fly && fly !== item.key) setFly(item.key)
        }}
        title={expanded ? undefined : text(item.label)}
      >
        <span className="sm-link-icon">{item.icon}</span>
        {expanded && (
          <>
            <span className="sm-link-label">{item.label}</span>
            <RightOutlined className="sm-chevron" />
          </>
        )}
      </button>
    )
  }

  return (
    <>
    <aside ref={asideRef} className={`sm-sidebar ${expanded ? '' : 'collapsed sm-collapsed'}`} onMouseEnter={keep} onMouseLeave={leave}>
      <div className="sm-sb-head">
        {expanded ? (
          <>
            <Brand title="Super Market" subtitle={title} />
            {collapsible && (
              <button
                className={`sm-pin ${pinned ? 'on' : ''}`}
                onClick={() => setPinned((p) => !p)}
                title={pinned ? tr('Открепить меню', 'Menyuni boʻshatish') : tr('Закрепить меню', 'Menyuni qadash')}
              >
                <PushpinOutlined style={{ fontSize: 13 }} />
              </button>
            )}
          </>
        ) : (
          <div style={{ width: '100%', display: 'grid', placeItems: 'center' }}>
            <span className="sm-brand-mark">
              <img src={logo} alt="Super Market" />
            </span>
          </div>
        )}
      </div>

      <nav className="sm-nav">
        {!collapsible && flyItem ? (
          <>
            <button className="sm-glass sm-link sm-nav-back" onClick={() => setFly(null)}>
              <span className="sm-link-icon">
                <LeftOutlined />
              </span>
              <span className="sm-link-label">{tr('Назад', 'Orqaga')}</span>
            </button>
            <div className="sm-nav-section">{flyItem.label}</div>
            {flyItem.children?.map(child)}
          </>
        ) : (
          nav.map((item, n) =>
            item.section ? (
              <Fragment key={item.key}>
                {expanded ? <div className="sm-nav-section">{item.label}</div> : n > 0 && <div className="sm-nav-sep" />}
                {item.children?.map(link)}
              </Fragment>
            ) : (
              link(item)
            ),
          )
        )}
      </nav>

      <div className="sm-user">
        {userMenu && (
          <div className="sm-user-menu">
            {/* Язык — личная настройка сотрудника (Figma «Панель магазина · язык», WЯ1). */}
            {i18nEnabled && (
              <>
                <div className="sm-user-lang">
                  <div className="sm-user-lang-label">
                    <TranslationOutlined /> Til · Язык
                  </div>
                  <div className="sm-lang-seg" role="radiogroup" aria-label="Til · Язык">
                    {(['uz', 'ru'] as const).map((l) => (
                      <button
                        key={l}
                        type="button"
                        role="radio"
                        aria-checked={getLang() === l}
                        className={getLang() === l ? 'on' : ''}
                        onClick={() => setLang(l)}
                      >
                        {l === 'uz' ? 'Oʻzbekcha' : 'Русский'}
                      </button>
                    ))}
                  </div>
                </div>
                <div className="sm-user-menu-sep" />
              </>
            )}
            <button className="sm-logout" onClick={() => logout()}>
              <LogoutOutlined /> {tr('Выйти', 'Chiqish')}
            </button>
          </div>
        )}
        <button className="sm-glass sm-user-btn" onClick={() => setUserMenu((v) => !v)}>
          <span className="sm-avatar">{initials || 'SM'}</span>
          {expanded && (
            <>
              <span className="sm-user-text">
                <b>{user?.name || title}</b>
                {user?.subtitle && <span>{user.subtitle}</span>}
              </span>
              <DownOutlined style={{ fontSize: 11, color: '#cbd5e1', transform: userMenu ? 'rotate(180deg)' : undefined }} />
            </>
          )}
        </button>
      </div>
    </aside>
    {collapsible &&
      flyItem &&
      createPortal(
        <div ref={flyRef} className="sm-flyout" role="menu" onMouseEnter={keep} onMouseLeave={leave}>
          <div className="sm-flyout-title">{flyItem.label}</div>
          {flyItem.children?.map(child)}
        </div>,
        document.body,
      )}
    </>
  )
}

// ─── Полоса открытых вкладок ───────────────────────────────────────────────

interface OpenTab {
  path: string
  label: string
}

function useOpenTabs(storageKey: string, nav: NavItem[]) {
  const { pathname, search } = useLocation()
  const [tabs, setTabs] = useState<OpenTab[]>(() => {
    try {
      return JSON.parse(sessionStorage.getItem(storageKey) ?? '[]') as OpenTab[]
    } catch {
      return []
    }
  })

  const current = pathname.replace(/\/$/, '') || '/'
  const base = (p: string) => p.split('?')[0]
  const navType = useNavigationType()
  const prev = useRef(current)

  useEffect(() => {
    const label = labelFor(nav, current)
    const was = prev.current
    prev.current = current
    setTabs((list) => {
      const i = list.findIndex((t) => base(t.path) === current)
      const tab = { path: current + search, label }
      // Подписи остальных вкладок — заново: после смены языка в sessionStorage остались старые.
      const relabel = (t: OpenTab) => ({ ...t, label: labelFor(nav, base(t.path)) })
      if (i >= 0) return list.map((t, j) => (j === i ? tab : relabel(t)))
      // Переход с заменой (документ сохранили: «…/new» → «…/id») — вкладка «Создать» становится вкладкой документа, а не остаётся висеть.
      const w = navType === 'REPLACE' && was !== current ? list.findIndex((t) => base(t.path) === was) : -1
      if (w >= 0) return list.map((t, j) => (j === w ? tab : relabel(t)))
      return [...list, tab].slice(-12)
    })
  }, [current, search, nav, navType])

  useEffect(() => {
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(tabs))
    } catch {
      // приватный режим
    }
  }, [tabs, storageKey])

  return { tabs, setTabs, current, base }
}

function TabsBar({ nav, storageKey, onMenu }: { nav: NavItem[]; storageKey: string; onMenu?: () => void }) {
  const navigate = useNavigate()
  const { tabs, setTabs, current, base } = useOpenTabs(storageKey, nav)
  const activeRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    activeRef.current?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }, [current])

  const close = (path: string) => {
    const rest = tabs.filter((t) => t.path !== path)
    setTabs(rest)
    if (base(path) === current) navigate(rest[rest.length - 1]?.path ?? '/')
  }

  return (
    <div className="sm-tabsbar">
      {onMenu && <Button className="sm-tabsbar-menu" size="small" type="text" icon={<MenuOutlined />} onClick={onMenu} />}
      <div className="sm-tabs">
        {tabs.map((t) => {
          const active = base(t.path) === current
          return (
            <button
              key={t.path}
              ref={active ? activeRef : undefined}
              className={`sm-tab ${active ? 'active' : ''}`}
              onClick={() => guardedNavigate(() => navigate(t.path))}
              onAuxClick={(e) => {
                if (e.button === 1) close(t.path)
              }}
            >
              <span className="sm-tab-label">{t.label}</span>
              {tabs.length > 1 && (
                <span
                  className="sm-tab-close"
                  role="button"
                  aria-label={tr('Закрыть вкладку', 'Varaqni yopish')}
                  onClick={(e) => {
                    e.stopPropagation()
                    close(t.path)
                  }}
                >
                  <CloseOutlined />
                </span>
              )}
            </button>
          )
        })}
      </div>
      {tabs.length > 1 && (
        <button className="sm-tabs-clear" onClick={() => setTabs(tabs.filter((t) => base(t.path) === current))} title={tr('Закрыть остальные вкладки', 'Boshqa varaqlarni yopish')}>
          {tr('Все', 'Hammasi')} <DeleteOutlined style={{ fontSize: 12 }} />
        </button>
      )}
    </div>
  )
}

/**
 * Оболочка панели: тёмное меню слева, полоса открытых вкладок, контент.
 * header — элементы справа в шапке каждой страницы (выбор магазина и т.п.).
 */
export function Shell({
  title,
  menu,
  header,
  user,
}: {
  title: string
  menu: MenuItem[]
  header?: ReactNode
  user?: { name: string; subtitle?: string }
}) {
  const screens = Grid.useBreakpoint()
  const [drawer, setDrawer] = useState(false)
  const nav = useMemo(() => toNav(menu), [menu])
  const desktop = screens.lg ?? true
  const storageKey = `sm_tabs_${title}`

  return (
    <ShellContext.Provider value={{ headerExtra: header }}>
      <div className="sm-layout">
        {desktop ? (
          <Sidebar title={title} nav={nav} user={user} collapsible />
        ) : (
          <Drawer
            open={drawer}
            onClose={() => setDrawer(false)}
            placement="left"
            width={260}
            closable={false}
            rootClassName="sm-sidebar-drawer"
            styles={{ body: { padding: 0 } }}
          >
            <Sidebar title={title} nav={nav} user={user} collapsible={false} onNavigate={() => setDrawer(false)} />
          </Drawer>
        )}
        <div className="sm-main">
          <TabsBar nav={nav} storageKey={storageKey} onMenu={desktop ? undefined : () => setDrawer(true)} />
          <main className="sm-outlet">
            <Outlet />
          </main>
        </div>
      </div>
    </ShellContext.Provider>
  )
}
