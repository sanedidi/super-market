// Уведомления покупателям: push-рассылки (всем, по фильтру, одному клиенту,
// сейчас или по расписанию, с переходом в нужный экран приложения),
// журнал доставки и тестовый push.
import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import { useNavigate, useParams, useSearchParams } from 'react-router-dom'
import {
  Alert,
  App,
  Button,
  Card,
  Col,
  DatePicker,
  Empty,
  Input,
  InputNumber,
  Modal,
  Popconfirm,
  Row,
  Segmented,
  Select,
  Space,
  Spin,
  Tabs,
  Tag,
  TimePicker,
  Typography,
} from 'antd'
import {
  AimOutlined,
  AppstoreOutlined,
  ArrowLeftOutlined,
  BellOutlined,
  CalendarOutlined,
  CheckCircleOutlined,
  ClockCircleOutlined,
  CopyOutlined,
  ExclamationCircleOutlined,
  FireOutlined,
  GlobalOutlined,
  HomeOutlined,
  LinkOutlined,
  MobileOutlined,
  PlusOutlined,
  ProfileOutlined,
  SearchOutlined,
  SendOutlined,
  ShopOutlined,
  ShoppingCartOutlined,
  ShoppingOutlined,
  StopOutlined,
  SyncOutlined,
  TagOutlined,
  TeamOutlined,
  UserOutlined,
  EnvironmentOutlined,
  LayoutOutlined,
} from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { useQuery } from '@tanstack/react-query'
import { DeleteButton, LoadError, PagedTable, PageTitle, PhoneInput, RemoteSelect, api, dateTime, errorText, formatPhone, normalizeUzPhone, useAction, useDebounced, useItem, useList } from '@sm/shared'
import { SearchSelect } from '../components'
import { useUrlState } from '../hooks'

// ─── Типы ──────────────────────────────────────────────────────────────────

type TargetType =
  | 'home'
  | 'catalog'
  | 'map'
  | 'cart'
  | 'orders'
  | 'profile'
  | 'family'
  | 'store'
  | 'category'
  | 'product'
  | 'deals'
  | 'block'
  | 'url'

interface Target {
  type: TargetType
  store_id?: string
  category_id?: string
  product_id?: string
  block_id?: string
  url?: string
}

interface Audience {
  type: 'all' | 'filter' | 'one'
  city?: string
  language?: string
  network_id?: string
  store_id?: string
  orders?: '' | 'within' | 'not_within' | 'never'
  days?: number
  user_id?: string
}

interface Stats {
  pending: number
  sent: number
  no_push: number
  failed: number
}

interface Campaign {
  id: string
  title: string
  body: string
  target: Target
  target_title: string
  audience: Audience
  audience_title: string
  send_at: string
  status: 'scheduled' | 'sending' | 'sent' | 'cancelled'
  recipients: number
  created_by: string
  created_at: string
  started_at: string | null
  finished_at: string | null
  cancelled_at: string | null
  stats: Stats
}

interface Reach {
  recipients: number
  with_push: number
  without_push: number
  send_at: string
  shifted: boolean
  target_title: string
  audience_title: string
}

interface Overview {
  with_push: number
  without_push: number
  promos_off: number
  sent_30d: number
  total_30d: number
  delivered_30d: number
  push_enabled: boolean
}

interface Recipient {
  id: number
  user_id: string
  phone: string
  name: string
  status: string
  devices: string
  reason: string
  sent_at: string | null
  attempts: number
}

interface CustomerInfo {
  user_id: string
  phone: string
  name: string
  orders: number
  last_order_at: string | null
  promos_on: boolean
  devices: { platform: string; name: string; last_seen_at: string }[]
}

interface TestResult {
  customer: CustomerInfo
  results: { name: string; ok: boolean; reason: string; ms: number }[]
  sent_at: string
}

interface Notification {
  id: number
  phone: string
  kind: string
  title: string
  body: string
  status: 'pending' | 'sent' | 'skipped' | 'failed'
  attempts: number
  last_error: string
  devices: string
  send_after: string
  created_at: string
  sent_at: string | null
}

// ─── Общее ─────────────────────────────────────────────────────────────────

const C = { blue: '#155eef', blueSoft: '#eef4ff', green: '#17b26a', red: '#e11d2a', ink: '#101828', t2: '#475467', t3: '#667085', line: '#eaecf0' }

const CAMPAIGN_STATUS: Record<Campaign['status'], { label: string; color: string; icon: ReactNode }> = {
  scheduled: { label: 'Запланирована', color: 'blue', icon: <ClockCircleOutlined /> },
  sending: { label: 'Идёт отправка', color: 'orange', icon: <SyncOutlined spin /> },
  sent: { label: 'Отправлена', color: 'green', icon: <CheckCircleOutlined /> },
  cancelled: { label: 'Отменена', color: 'default', icon: <StopOutlined /> },
}

function CampaignTag({ status }: { status: Campaign['status'] }) {
  const s = CAMPAIGN_STATUS[status]
  return (
    <Tag color={s.color} icon={s.icon} style={{ borderRadius: 12 }}>
      {s.label}
    </Tag>
  )
}

const NOTIFY_STATUS: Record<Notification['status'], { label: string; color: string }> = {
  pending: { label: 'В очереди', color: 'blue' },
  sent: { label: 'Доставлено', color: 'green' },
  skipped: { label: 'Нет push', color: 'gold' },
  failed: { label: 'Не доставлено', color: 'red' },
}

const n = (v: number) => v.toLocaleString('ru-RU')

function DeliveryBar({ s, total, width = 170 }: { s: Stats; total: number; width?: number }) {
  const all = Math.max(total, s.sent + s.no_push + s.failed + s.pending, 1)
  const part = (v: number, color: string) => (v > 0 ? <div style={{ width: `${(v / all) * 100}%`, background: color, minWidth: 3 }} /> : null)
  return (
    <div style={{ width, display: 'flex', height: 6, borderRadius: 3, overflow: 'hidden', background: '#f2f4f7', gap: 1 }}>
      {part(s.sent, C.green)}
      {part(s.no_push + s.failed, '#f04438')}
    </div>
  )
}

function deliveryText(c: Campaign) {
  const s = c.stats
  if (c.status === 'scheduled') return 'ожидает отправки'
  if (c.status === 'cancelled') return 'не отправлялась'
  if (c.status === 'sending') return `${n(s.sent + s.no_push + s.failed)} из ${n(c.recipients)}`
  return `${n(s.sent)} доставлено · ${n(s.no_push + s.failed)} нет`
}

function StatCard({ icon, color, bg, value, title, sub }: { icon: ReactNode; color: string; bg: string; value: ReactNode; title: string; sub?: ReactNode }) {
  return (
    <Card style={{ height: '100%' }}>
      <Space align="start" size={12}>
        <div style={{ width: 36, height: 36, borderRadius: 10, background: bg, color, display: 'grid', placeItems: 'center', fontSize: 18 }}>{icon}</div>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: C.ink, lineHeight: '26px' }}>{value}</div>
          <div style={{ fontSize: 12, color: C.t3 }}>{title}</div>
        </div>
      </Space>
      {sub && <div style={{ fontSize: 12, color: C.t3, marginTop: 10 }}>{sub}</div>}
    </Card>
  )
}

// ─── Список рассылок и журнал ──────────────────────────────────────────────

export function Notifications() {
  const nav = useNavigate()
  const [tab, setTab] = useUrlState('tab', 'campaigns')
  const [test, setTest] = useState(false)
  return (
    <>
      <PageTitle
        title="Уведомления"
        extra={
          <Space>
            <Button type="primary" icon={<PlusOutlined />} onClick={() => nav('/notifications/new')}>
              Новая рассылка
            </Button>
            <Button icon={<MobileOutlined />} onClick={() => setTest(true)}>
              Тестовый push
            </Button>
          </Space>
        }
        tabs={
          <Tabs
            activeKey={tab}
            onChange={setTab}
            items={[
              { key: 'campaigns', label: 'Рассылки' },
              { key: 'log', label: 'Журнал доставки' },
            ]}
          />
        }
      >
        <Typography.Text type="secondary">Push-рассылки покупателям и журнал доставки.</Typography.Text>
      </PageTitle>
      {tab === 'log' ? <DeliveryLog /> : <Campaigns />}
      <TestPushModal open={test} onClose={() => setTest(false)} />
    </>
  )
}

function OverviewCards() {
  const ov = useItem<Overview>('/admin/push/overview')
  const o = ov.data
  return (
    <>
      <LoadError error={ov.error} retry={() => ov.refetch()} />
      {o && !o.push_enabled && (
        <Alert
          type="error"
          showIcon
          style={{ marginBottom: 16 }}
          message="Push не настроен на сервере"
          description="Нет ключа Firebase (FCM_CREDENTIALS) — уведомления не доставляются. Добавьте секрет в GitHub и перезапустите деплой."
        />
      )}
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} lg={6}>
          <StatCard icon={<MobileOutlined />} color={C.green} bg="#dcfae6" value={o ? n(o.with_push) : '…'} title="Получают push" sub="iPhone и Android с разрешением" />
        </Col>
        <Col xs={12} lg={6}>
          <StatCard icon={<BellOutlined />} color="#b54708" bg="#fef0c7" value={o ? n(o.without_push) : '…'} title="Без push" sub="не разрешили уведомления или не входили в приложение" />
        </Col>
        <Col xs={12} lg={6}>
          <StatCard icon={<StopOutlined />} color="#b42318" bg="#fee4e2" value={o ? n(o.promos_off) : '…'} title="Отключили акции" sub="рассылки им не приходят" />
        </Col>
        <Col xs={12} lg={6}>
          <StatCard
            icon={<CheckCircleOutlined />}
            color={C.blue}
            bg={C.blueSoft}
            value={o ? (o.total_30d ? `${String(o.delivered_30d).replace('.', ',')}%` : '—') : '…'}
            title="Доставлено за 30 дней"
            sub={o ? `${n(o.sent_30d)} из ${n(o.total_30d)} push` : undefined}
          />
        </Col>
      </Row>
    </>
  )
}

function Campaigns() {
  const nav = useNavigate()
  return (
    <>
      <OverviewCards />
      <Card styles={{ body: { padding: 0 } }}>
        <PagedTable<Campaign>
          path="/admin/push/campaigns"
          refetchInterval={5000}
          onRow={(c) => ({ onClick: () => nav(`/notifications/${c.id}`), style: { cursor: 'pointer' } })}
          locale={{ emptyText: <Empty description="Рассылок ещё не было" image={Empty.PRESENTED_IMAGE_SIMPLE} /> }}
          columns={[
            {
              title: 'Рассылка',
              render: (_, c) => (
                <div style={{ maxWidth: 320 }}>
                  <b>{c.title}</b>
                  <div style={{ color: C.t3, fontSize: 12 }}>{c.body}</div>
                </div>
              ),
            },
            {
              title: 'Кому',
              render: (_, c) => (
                <div style={{ maxWidth: 240 }}>
                  <div>{c.audience_title.replace(/^По фильтру · /, 'По фильтру')} · {n(c.recipients)}</div>
                  {c.audience.type === 'filter' && <div style={{ color: C.t3, fontSize: 12 }}>{c.audience_title.replace(/^По фильтру · /, '')}</div>}
                </div>
              ),
            },
            {
              title: 'Когда',
              render: (_, c) => (
                <>
                  <div>{dateTime(c.send_at)}</div>
                  {c.status === 'cancelled' && c.cancelled_at && <div style={{ color: C.t3, fontSize: 12 }}>отменена {dateTime(c.cancelled_at)}</div>}
                  {c.status === 'sent' && c.started_at && c.finished_at && (
                    <div style={{ color: C.t3, fontSize: 12 }}>за {Math.max(1, dayjs(c.finished_at).diff(c.started_at, 'minute'))} мин</div>
                  )}
                </>
              ),
            },
            { title: 'Статус', render: (_, c) => <CampaignTag status={c.status} /> },
            {
              key: 'del',
              align: 'right',
              render: (_, c) =>
                (c.status === 'scheduled' || c.status === 'cancelled') && <DeleteButton path={`/admin/push/campaigns/${c.id}`} name={c.title} />,
            },
            {
              title: 'Доставка',
              render: (_, c) => (
                <>
                  {(c.status === 'sent' || c.status === 'sending') && <DeliveryBar s={c.stats} total={c.recipients} />}
                  <div style={{ color: C.t3, fontSize: 12, marginTop: 4 }}>{deliveryText(c)}</div>
                </>
              ),
            },
          ]}
        />
      </Card>
      <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
        Рассылки уходят push-уведомлением в приложение и видны в колокольчике. Ночью (22:00–08:00 по Ташкенту) отправка ждёт до утра.
      </Typography.Paragraph>
    </>
  )
}

function kindTitle(kind: string) {
  if (kind.startsWith('order')) return 'Статус заказа'
  if (kind.startsWith('family')) return 'Моя семья'
  if (kind === 'campaign') return 'Рассылка'
  if (kind === 'test') return 'Тестовый push'
  return kind
}

function DeliveryLog() {
  const { message } = App.useApp()
  const [status, setStatus] = useUrlState('status')
  const [kind, setKind] = useUrlState('kind')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const retry = useAction((id: number) => api.post(`/admin/notifications/${id}/retry`), { success: 'Уведомление снова в очереди' })
  return (
    <>
      <Space wrap style={{ marginBottom: 16 }}>
        <Input.Search
          placeholder="Телефон или заголовок"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onSearch={(v) => setQ(v.trim())}
          style={{ width: 260 }}
        />
        <Segmented
          value={status ?? ''}
          onChange={(v) => setStatus(String(v))}
          options={[
            { value: '', label: 'Все' },
            { value: 'sent', label: 'Доставлено' },
            { value: 'skipped', label: 'Нет push' },
            { value: 'failed', label: 'Не доставлено' },
            { value: 'pending', label: 'В очереди' },
          ]}
        />
        <Select
          placeholder="Все типы"
          allowClear
          value={kind}
          onChange={setKind}
          style={{ width: 180 }}
          options={[
            { value: 'order', label: 'Статус заказа' },
            { value: 'campaign', label: 'Рассылка' },
            { value: 'family', label: 'Моя семья' },
            { value: 'test', label: 'Тестовый push' },
          ]}
        />
      </Space>
      <Card styles={{ body: { padding: 0 } }}>
        <PagedTable<Notification>
          path="/admin/notifications"
          params={{ status, kind, q }}
          columns={[
            { title: 'Время', dataIndex: 'created_at', render: dateTime, width: 150 },
            { title: 'Покупатель', dataIndex: 'phone', width: 170, render: (v: string) => formatPhone(v) },
            {
              title: 'Уведомление',
              render: (_, x) => (
                <div style={{ maxWidth: 340 }}>
                  <b>{x.title}</b>
                  <div style={{ color: C.t3, fontSize: 12 }}>
                    {kindTitle(x.kind)} · {x.body}
                  </div>
                </div>
              ),
            },
            {
              title: 'Статус',
              render: (_, x) => (
                <>
                  <Tag color={NOTIFY_STATUS[x.status]?.color}>{NOTIFY_STATUS[x.status]?.label ?? x.status}</Tag>
                  {x.devices && <div style={{ color: C.t3, fontSize: 12 }}>{x.devices}</div>}
                  {x.status === 'pending' && x.attempts > 0 && <div style={{ color: C.t3, fontSize: 12 }}>попытка {x.attempts + 1} · {dateTime(x.send_after)}</div>}
                </>
              ),
            },
            {
              title: 'Причина',
              render: (_, x) =>
                x.last_error ? (
                  <Typography.Text type={x.status === 'failed' ? 'danger' : 'secondary'} style={{ fontSize: 12 }}>
                    {x.last_error}
                  </Typography.Text>
                ) : (
                  <span style={{ color: '#98a2b3' }}>—</span>
                ),
            },
            {
              key: 'act',
              render: (_, x) =>
                (x.status === 'failed' || x.status === 'skipped') && x.kind !== 'test' ? (
                  <Popconfirm
                    title="Отправить ещё раз на текущие устройства?"
                    onConfirm={() => retry.mutateAsync(x.id).catch(() => message.destroy())}
                  >
                    <Button size="small" loading={retry.isPending && retry.variables === x.id}>
                      Повторить
                    </Button>
                  </Popconfirm>
                ) : null,
            },
          ]}
        />
      </Card>
      <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
        «Нет push» — у покупателя нет устройства с разрешёнными уведомлениями. «Не доставлено» — Firebase отклонил сообщение (причина в
        колонке). «Повторить» отправляет ещё раз на текущие устройства.
      </Typography.Paragraph>
    </>
  )
}

// ─── Куда ведёт уведомление ────────────────────────────────────────────────

const TARGETS: { group: string; items: { value: TargetType; label: string; hint?: string; icon: ReactNode }[] }[] = [
  {
    group: 'Магазины и товары',
    items: [
      { value: 'store', label: 'Магазин', hint: 'Витрина выбранного магазина', icon: <ShopOutlined /> },
      { value: 'category', label: 'Категория магазина', hint: 'Например «Фрукты» в Лимонарии', icon: <AppstoreOutlined /> },
      { value: 'product', label: 'Товар', hint: 'Карточка товара в магазине', icon: <ShoppingOutlined /> },
      { value: 'deals', label: 'Скидки магазина', hint: 'Все товары со скидкой', icon: <TagOutlined /> },
    ],
  },
  {
    group: 'Разделы приложения',
    items: [
      { value: 'home', label: 'Главная', icon: <HomeOutlined /> },
      { value: 'catalog', label: 'Каталог', icon: <AppstoreOutlined /> },
      { value: 'map', label: 'Карта магазинов', icon: <EnvironmentOutlined /> },
      { value: 'cart', label: 'Корзина', icon: <ShoppingCartOutlined /> },
      { value: 'orders', label: 'Мои заказы', icon: <ProfileOutlined /> },
      { value: 'profile', label: 'Профиль', icon: <UserOutlined /> },
      { value: 'family', label: 'Моя семья', icon: <TeamOutlined /> },
    ],
  },
  {
    group: 'Другое',
    items: [
      { value: 'block', label: 'Блок главной', hint: 'Баннер или полка, например «Хиты недели»', icon: <LayoutOutlined /> },
      { value: 'url', label: 'Внешняя ссылка', hint: 'Откроется в браузере', icon: <LinkOutlined /> },
    ],
  },
]

const needsStore = (t: TargetType) => t === 'store' || t === 'category' || t === 'product' || t === 'deals'

function StoreSelect({ value, onChange, nearest }: { value?: string; onChange: (v: string) => void; nearest: boolean }) {
  const stores = useList<{ id: string; name: string; network_name: string }>('/admin/home/stores')
  const options = [
    ...(nearest ? [{ value: 'nearest', label: <span><AimOutlined style={{ color: C.blue }} /> Ближайший к покупателю</span> }] : []),
    ...(stores.data ?? []).map((s) => ({ value: s.id, label: s.name.includes(s.network_name) ? s.name : `${s.name} · ${s.network_name}` })),
  ]
  return (
    <Select
      showSearch
      optionFilterProp="label"
      placeholder="Выберите магазин"
      loading={stores.isLoading}
      value={value}
      onChange={onChange}
      options={options as { value: string; label: string }[]}
      filterOption={(input, o) => (typeof o?.label === 'string' ? o.label : 'ближайший').toLowerCase().includes(input.toLowerCase())}
      style={{ width: '100%' }}
    />
  )
}

function TargetPicker({ value, onChange, title }: { value: Target; onChange: (t: Target) => void; title?: string }) {
  const t = value.type
  const set = (p: Partial<Target>) => onChange({ ...value, ...p })
  return (
    <Space direction="vertical" style={{ width: '100%' }} size={10}>
      <Row gutter={12}>
        <Col span={needsStore(t) || t === 'block' || t === 'url' ? 8 : 24}>
          <Label>Что открыть</Label>
          <Select
            value={t}
            onChange={(v: TargetType) => onChange({ type: v, store_id: needsStore(v) ? value.store_id : undefined })}
            style={{ width: '100%' }}
            options={TARGETS.map((g) => ({
              label: g.group,
              options: g.items.map((i) => ({
                value: i.value,
                label: (
                  <Space size={8}>
                    <span style={{ color: C.t2 }}>{i.icon}</span>
                    <span>{i.label}</span>
                    {i.hint && <span style={{ color: '#98a2b3', fontSize: 12 }}>{i.hint}</span>}
                  </Space>
                ),
              })),
            }))}
            optionLabelProp="value"
            labelRender={(o) => {
              const it = TARGETS.flatMap((g) => g.items).find((i) => i.value === o.value)
              return it ? (
                <Space size={8}>
                  <span style={{ color: C.blue }}>{it.icon}</span>
                  {it.label}
                </Space>
              ) : (
                String(o.value)
              )
            }}
          />
        </Col>
        {needsStore(t) && (
          <Col span={t === 'store' || t === 'deals' ? 16 : 8}>
            <Label>Магазин</Label>
            <StoreSelect value={value.store_id} onChange={(v) => set({ store_id: v })} nearest={t !== 'store'} />
          </Col>
        )}
        {t === 'category' && (
          <Col span={8}>
            <Label>Категория</Label>
            <SearchSelect
              path="/admin/catalog/categories"
              value={value.category_id}
              onChange={(v) => set({ category_id: v as string })}
              placeholder="Найдите категорию"
              style={{ width: '100%' }}
            />
          </Col>
        )}
        {t === 'product' && (
          <Col span={8}>
            <Label>Товар</Label>
            <SearchSelect
              path="/admin/products"
              value={value.product_id}
              onChange={(v) => set({ product_id: v as string })}
              placeholder="Название товара"
              style={{ width: '100%' }}
            />
          </Col>
        )}
        {t === 'block' && (
          <Col span={16}>
            <Label>Блок</Label>
            <RemoteSelect<{ id: string; title: string }>
              path="/admin/push/blocks"
              label={(b) => b.title}
              value={value.block_id}
              onChange={(v) => set({ block_id: v as string })}
              placeholder="Блок из «Каталог → Главная приложения»"
              style={{ width: '100%' }}
            />
          </Col>
        )}
        {t === 'url' && (
          <Col span={16}>
            <Label>Адрес</Label>
            <Input prefix={<LinkOutlined />} placeholder="https://instagram.com/…" value={value.url} onChange={(e) => set({ url: e.target.value })} />
          </Col>
        )}
      </Row>
      <Hint icon={<AimOutlined />} kind={t === 'url' ? 'amber' : 'blue'}>
        <b>{title ? `Откроется: ${title}` : 'Выберите, что откроется'}</b>
        <div style={{ fontSize: 12 }}>
          {t === 'url'
            ? 'Откроется в браузере телефона — покупатель выйдет из приложения.'
            : value.store_id === 'nearest'
              ? 'Ближайший — по адресу доставки покупателя. Нет адреса — откроется главная.'
              : 'Если магазин закроется или товар/категорию скроют — откроется главная приложения.'}
        </div>
      </Hint>
    </Space>
  )
}

function Label({ children }: { children: ReactNode }) {
  return <div style={{ fontSize: 12, fontWeight: 700, color: C.t2, marginBottom: 6 }}>{children}</div>
}

function Hint({ icon, children, kind = 'blue', style }: { icon: ReactNode; children: ReactNode; kind?: 'blue' | 'amber'; style?: CSSProperties }) {
  const [bg, fg] = kind === 'amber' ? ['#fff7d6', '#7a4a00'] : [C.blueSoft, '#1849a9']
  return (
    <div style={{ display: 'flex', gap: 10, alignItems: 'center', background: bg, color: fg, borderRadius: 10, padding: '10px 12px', ...style }}>
      <span style={{ fontSize: 18 }}>{icon}</span>
      <div style={{ flex: 1 }}>{children}</div>
    </div>
  )
}

// ─── Предпросмотр на телефоне ──────────────────────────────────────────────

function PhonePreview({ title, body, when, tap }: { title: string; body: string; when?: Dayjs | null; tap?: string }) {
  const [os, setOs] = useState<'ios' | 'android'>('ios')
  const t = when ?? dayjs()
  const days = ['Воскресенье', 'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота']
  const months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря']
  const ios = os === 'ios'
  return (
    <Card title="Предпросмотр" extra={<Typography.Text type="secondary">Так увидит покупатель</Typography.Text>}>
      <Segmented block value={os} onChange={(v) => setOs(v as 'ios' | 'android')} options={[{ value: 'ios', label: 'iPhone' }, { value: 'android', label: 'Android' }]} />
      <div
        style={{
          margin: '16px auto 12px',
          width: 260,
          height: 500,
          borderRadius: ios ? 40 : 28,
          border: '8px solid #101828',
          background: 'linear-gradient(160deg, #3b2667 0%, #bc4e9c 55%, #f8b195 100%)',
          position: 'relative',
          overflow: 'hidden',
          color: '#fff',
        }}
      >
        {ios ? (
          <div style={{ position: 'absolute', top: 10, left: '50%', transform: 'translateX(-50%)', width: 80, height: 22, borderRadius: 12, background: '#000' }} />
        ) : (
          <div style={{ position: 'absolute', top: 10, left: '50%', transform: 'translateX(-50%)', width: 10, height: 10, borderRadius: 5, background: '#000' }} />
        )}
        <div style={{ textAlign: 'center', marginTop: 50, fontSize: 13, opacity: 0.9, fontWeight: 600 }}>
          {days[t.day()]}, {t.date()} {months[t.month()]}
        </div>
        <div style={{ textAlign: 'center', fontSize: 60, fontWeight: 700, lineHeight: '70px' }}>{t.format('HH:mm')}</div>
        <div
          style={{
            position: 'absolute',
            left: 10,
            right: 10,
            top: 170,
            background: 'rgba(255,255,255,0.85)',
            borderRadius: ios ? 18 : 14,
            padding: '10px 12px',
            color: C.ink,
          }}
        >
          <Space size={6} style={{ fontSize: 11, color: C.t2 }}>
            <span style={{ display: 'inline-grid', placeItems: 'center', width: 18, height: 18, borderRadius: 5, background: C.red, color: '#fff', fontSize: 11 }}>
              <ShoppingOutlined />
            </span>
            <b>{ios ? 'SUPER MARKET' : 'Super Market'}</b>
            <span>· сейчас</span>
          </Space>
          <div style={{ fontWeight: 700, fontSize: 14, marginTop: 4, wordBreak: 'break-word' }}>{title || 'Заголовок'}</div>
          <div
            style={{ fontSize: 13, lineHeight: '18px', display: '-webkit-box', WebkitLineClamp: ios ? 4 : 2, WebkitBoxOrient: 'vertical', overflow: 'hidden', wordBreak: 'break-word' }}
          >
            {body || 'Текст уведомления'}
          </div>
        </div>
      </div>
      {tap && (
        <div style={{ border: `1px solid ${C.line}`, background: '#f8fafc', borderRadius: 10, padding: '8px 10px', fontSize: 12, color: C.t2, fontWeight: 600 }}>
          <AimOutlined /> Нажатие → {tap}
        </div>
      )}
      <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginTop: 10, marginBottom: 0 }}>
        Длинный текст на экране блокировки сокращается до 2–4 строк. Полностью — после нажатия.
      </Typography.Paragraph>
    </Card>
  )
}

// ─── Новая рассылка ────────────────────────────────────────────────────────

function useCustomer(phone: string) {
  const q = useDebounced(normalizeUzPhone(phone) ?? '', 400)
  return useQuery({
    queryKey: ['/admin/push/customer', q],
    queryFn: () => api.get<CustomerInfo>('/admin/push/customer', { phone: q }),
    enabled: q !== '',
    retry: false,
  })
}

function CustomerCard({ c }: { c: CustomerInfo }) {
  const push = c.devices.length > 0
  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center', border: `1px solid ${C.line}`, background: '#f8fafc', borderRadius: 12, padding: '12px 14px' }}>
      <div style={{ width: 36, height: 36, borderRadius: 18, background: '#dcfae6', color: '#067647', display: 'grid', placeItems: 'center' }}>
        <UserOutlined />
      </div>
      <div style={{ flex: 1 }}>
        <b>
          {c.name || 'Без имени'} · {formatPhone(c.phone)}
        </b>
        <div style={{ fontSize: 12, color: C.t3 }}>
          {push ? `${c.devices.length} устр.: ${c.devices.map((d) => `${d.name} (${dayjs(d.last_seen_at).format('DD.MM')})`).join(', ')}` : 'Нет устройств с push'}
          {' · '}заказов: {c.orders}
          {c.last_order_at ? `, последний ${dayjs(c.last_order_at).format('DD.MM.YYYY')}` : ''}
        </div>
      </div>
      {push ? <Tag color="green" icon={<CheckCircleOutlined />}>push вкл.</Tag> : <Tag color="gold">нет push</Tag>}
    </div>
  )
}

function fromCampaign(c: Campaign) {
  return { title: c.title, body: c.body, target: c.target, audience: c.audience }
}

export function PushNew() {
  const nav = useNavigate()
  const { message } = App.useApp()
  const [sp] = useSearchParams()
  const copyId = sp.get('copy')
  const copy = useItem<Campaign>(copyId ? `/admin/push/campaigns/${copyId}` : null)

  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [target, setTarget] = useState<Target>({ type: 'home' })
  const [audience, setAudience] = useState<Audience>({ type: 'all' })
  const [when, setWhen] = useState<'now' | 'later'>('now')
  const [date, setDate] = useState<Dayjs | null>(dayjs().add(1, 'day').hour(10).minute(0).second(0))
  const [phone, setPhone] = useState('')
  const [confirm, setConfirm] = useState(false)

  useEffect(() => {
    if (!copy.data) return
    const c = fromCampaign(copy.data)
    setTitle(c.title)
    setBody(c.body)
    setTarget(c.target)
    setAudience(c.audience)
  }, [copy.data])

  const customer = useCustomer(phone)
  useEffect(() => {
    if (audience.type === 'one') setAudience({ type: 'one', user_id: customer.data?.user_id })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [customer.data?.user_id])

  const input = useMemo(
    () => ({ title, body, target, audience, send_at: when === 'later' && date ? date.toISOString() : null }),
    [title, body, target, audience, when, date],
  )
  const debounced = useDebounced(input, 400)
  const preview = useQuery({
    queryKey: ['/admin/push/campaigns/preview', debounced],
    queryFn: () => api.post<Reach>('/admin/push/campaigns/preview', { ...debounced, title: debounced.title || '.', body: debounced.body || '.' }),
    retry: false,
    placeholderData: (prev) => prev,
  })
  const reach = preview.data
  const previewError = preview.error ? errorText(preview.error) : ''

  const create = useAction((v: typeof input) => api.post<Campaign>('/admin/push/campaigns', v), { success: 'Рассылка создана' })
  const testSelf = useAction(() => api.post<TestResult>('/admin/push/test', { title, body, target }))

  const setA = (p: Partial<Audience>) => setAudience((a) => ({ ...a, ...p }))
  const canGo = title.trim() !== '' && body.trim() !== '' && !preview.isFetching && !previewError && reach && reach.recipients > 0

  return (
    <>
      <PageTitle
        title={
          <Space>
            <Button type="text" icon={<ArrowLeftOutlined />} onClick={() => nav('/notifications')} />
            Новая рассылка
          </Space>
        }
        extra={
          <Space>
            <Button type="primary" icon={<SendOutlined />} disabled={!canGo} onClick={() => setConfirm(true)}>
              Продолжить
            </Button>
            <Button
              icon={<MobileOutlined />}
              loading={testSelf.isPending}
              disabled={!title.trim() || !body.trim()}
              onClick={() =>
                testSelf.mutateAsync(undefined).then(
                  (r) =>
                    r.results.every((x) => x.ok)
                      ? message.success('Тест отправлен на ваш телефон')
                      : message.warning(r.results.map((x) => `${x.name}: ${x.ok ? 'доставлено' : x.reason}`).join('; ')),
                  () => undefined,
                )
              }
            >
              Отправить тест себе
            </Button>
            <Button onClick={() => nav('/notifications')}>Отмена</Button>
          </Space>
        }
      >
        <Typography.Text type="secondary">Покупатели получат push-уведомление в приложении и увидят его в колокольчике.</Typography.Text>
      </PageTitle>
      {copy.isLoading ? (
        <Spin />
      ) : (
        <Row gutter={16}>
          <Col xs={24} xl={16}>
            <Space direction="vertical" size={16} style={{ width: '100%' }}>
              <Card title="Сообщение">
                <Space direction="vertical" size={14} style={{ width: '100%' }}>
                  <div>
                    <Label>Заголовок</Label>
                    <Input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={65} showCount placeholder="Скидки выходных до −30%" />
                  </div>
                  <div>
                    <Label>Текст</Label>
                    <Input.TextArea
                      value={body}
                      onChange={(e) => setBody(e.target.value)}
                      maxLength={240}
                      showCount
                      style={{ marginBottom: 12 }}
                      autoSize={{ minRows: 3, maxRows: 6 }}
                      placeholder="Фрукты и овощи дешевле до воскресенья. Успейте заказать!"
                    />
                  </div>
                  <div>
                    <Label>При нажатии открыть</Label>
                    <TargetPicker value={target} onChange={setTarget} title={previewError ? undefined : reach?.target_title} />
                  </div>
                </Space>
              </Card>

              <Card title="Кому">
                <Space direction="vertical" size={14} style={{ width: '100%' }}>
                  <Segmented
                    block
                    value={audience.type}
                    onChange={(v) => setAudience(v === 'one' ? { type: 'one', user_id: customer.data?.user_id } : { type: v as Audience['type'] })}
                    options={[
                      { value: 'all', label: 'Все покупатели', icon: <TeamOutlined /> },
                      { value: 'filter', label: 'По фильтру', icon: <SearchOutlined /> },
                      { value: 'one', label: 'Один клиент', icon: <UserOutlined /> },
                    ]}
                  />
                  {audience.type === 'filter' && (
                    <Row gutter={[16, 14]}>
                      <Col span={12}>
                        <Label>Город</Label>
                        <CitySelect value={audience.city} onChange={(v) => setA({ city: v })} />
                        <Hint2>Город в профиле или магазина, где заказывал.</Hint2>
                      </Col>
                      <Col span={12}>
                        <Label>Язык приложения</Label>
                        <Select
                          allowClear
                          placeholder="Все языки"
                          value={audience.language}
                          onChange={(v) => setA({ language: v })}
                          style={{ width: '100%' }}
                          options={[
                            { value: 'ru', label: 'Русский' },
                            { value: 'uz', label: 'Oʻzbekcha' },
                          ]}
                        />
                      </Col>
                      <Col span={12}>
                        <Label>Сеть или магазин</Label>
                        <NetworkStoreSelect audience={audience} onChange={setA} />
                        <Hint2>Покупатели, которые заказывали в выбранной сети или магазине.</Hint2>
                      </Col>
                      <Col span={12}>
                        <Label>Заказы</Label>
                        <Space.Compact style={{ width: '100%' }}>
                          <Select
                            value={audience.orders ?? ''}
                            onChange={(v) => setA({ orders: v, days: v === 'within' || v === 'not_within' ? (audience.days ?? 30) : undefined })}
                            style={{ width: '100%' }}
                            options={[
                              { value: '', label: 'Не важно' },
                              { value: 'within', label: 'Заказывали за последние' },
                              { value: 'not_within', label: 'Не заказывали последние' },
                              { value: 'never', label: 'Ни разу не заказывали' },
                            ]}
                          />
                          {(audience.orders === 'within' || audience.orders === 'not_within') && (
                            <InputNumber min={1} max={365} value={audience.days} onChange={(v) => setA({ days: v ?? 30 })} addonAfter="дн." style={{ width: 150 }} />
                          )}
                        </Space.Compact>
                      </Col>
                    </Row>
                  )}
                  {audience.type === 'one' && (
                    <Space direction="vertical" size={10} style={{ width: '100%' }}>
                      <div>
                        <Label>Телефон покупателя</Label>
                        <PhoneInput value={phone} onChange={setPhone} style={{ maxWidth: 360 }} />
                      </div>
                      {customer.isFetching && <Spin size="small" />}
                      {customer.error && <Alert type="warning" showIcon message={errorText(customer.error)} />}
                      {customer.data && <CustomerCard c={customer.data} />}
                      <Hint icon={<ExclamationCircleOutlined />} kind="amber">
                        Если у клиента нет push, отправить не получится — уведомление останется только в колокольчике приложения.
                      </Hint>
                    </Space>
                  )}
                  {reach && !previewError && (
                    <Hint icon={<TeamOutlined />}>
                      <div style={{ fontSize: 16, fontWeight: 800, color: C.ink }}>Получат ≈ {n(reach.with_push)} покупателей</div>
                      <div style={{ fontSize: 12 }}>
                        Подходят {n(reach.recipients)}
                        {reach.without_push > 0 ? ` · у ${n(reach.without_push)} push выключен — им придёт только в колокольчик` : ''}
                        {audience.type !== 'one' ? ' · отписавшиеся от акций не учитываются' : ''}
                      </div>
                    </Hint>
                  )}
                  {previewError && title && body && <Alert type="warning" showIcon message={previewError} />}
                </Space>
              </Card>

              <Card title="Когда">
                <Space direction="vertical" size={14} style={{ width: '100%' }}>
                  <Segmented
                    value={when}
                    onChange={(v) => setWhen(v as 'now' | 'later')}
                    options={[
                      { value: 'now', label: 'Сейчас', icon: <FireOutlined /> },
                      { value: 'later', label: 'Запланировать', icon: <CalendarOutlined /> },
                    ]}
                  />
                  {when === 'later' && (
                    <Space>
                      <div>
                        <Label>Дата</Label>
                        <DatePicker
                          value={date}
                          format="DD.MM.YYYY"
                          allowClear={false}
                          disabledDate={(d) => d.isBefore(dayjs(), 'day') || d.isAfter(dayjs().add(3, 'month'))}
                          onChange={(d) => d && setDate((old) => d.hour(old?.hour() ?? 10).minute(old?.minute() ?? 0))}
                        />
                      </div>
                      <div>
                        <Label>Время</Label>
                        <TimePicker
                          value={date}
                          format="HH:mm"
                          minuteStep={5}
                          allowClear={false}
                          needConfirm={false}
                          onChange={(t) => t && setDate((old) => (old ?? dayjs()).hour(t.hour()).minute(t.minute()).second(0))}
                        />
                      </div>
                    </Space>
                  )}
                  {reach?.shifted ? (
                    <Hint icon={<ClockCircleOutlined />} kind="amber">
                      Сейчас ночь по Ташкенту — рассылка уйдёт в {dateTime(reach.send_at)}. С 22:00 до 08:00 уведомления не отправляются.
                    </Hint>
                  ) : (
                    <Hint icon={<ClockCircleOutlined />} kind="amber">
                      Время Ташкента. С 22:00 до 08:00 рассылки не отправляются — такие сдвинем на 08:00.
                    </Hint>
                  )}
                </Space>
              </Card>
            </Space>
          </Col>
          <Col xs={24} xl={8}>
            <div style={{ position: 'sticky', top: 16 }}>
              <PhonePreview
                title={title}
                body={body}
                when={reach ? dayjs(reach.send_at) : when === 'later' ? date : null}
                tap={previewError ? undefined : reach?.target_title}
              />
            </div>
          </Col>
        </Row>
      )}
      <Modal
        open={confirm}
        onCancel={() => setConfirm(false)}
        title={when === 'later' || reach?.shifted ? 'Запланировать рассылку?' : 'Отправить рассылку?'}
        okText={reach && (when === 'later' || reach.shifted) ? `Запланировать на ${dayjs(reach.send_at).format('DD.MM, HH:mm')}` : 'Отправить сейчас'}
        cancelText="Назад"
        okButtonProps={{ danger: true, loading: create.isPending }}
        onOk={() =>
          create.mutateAsync(input).then(
            (c) => nav(`/notifications/${c.id}`),
            () => undefined,
          )
        }
      >
        {reach && (
          <>
            <Typography.Paragraph type="secondary">Проверьте перед отправкой — изменить текст после начала отправки нельзя.</Typography.Paragraph>
            <KV k="Сообщение" v={title} sub={`Откроет: ${reach.target_title}`} />
            <KV k="Кому" v={`${reach.audience_title.split(' · ')[0]} · ≈ ${n(reach.with_push)} с push`} sub={reach.audience_title.split(' · ').slice(1).join(' · ') || `подходят ${n(reach.recipients)}`} />
            <KV k="Когда" v={when === 'now' && !reach.shifted ? 'Сразу' : dateTime(reach.send_at)} sub="по времени Ташкента" />
            <Hint icon={<ExclamationCircleOutlined />} style={{ marginTop: 12 }}>
              Отменить можно, пока отправка не началась: в карточке рассылки → «Отменить».
            </Hint>
          </>
        )}
      </Modal>
    </>
  )
}

function Hint2({ children }: { children: ReactNode }) {
  return <div style={{ fontSize: 12, color: C.t3, marginTop: 4 }}>{children}</div>
}

function KV({ k, v, sub }: { k: string; v: ReactNode; sub?: ReactNode }) {
  return (
    <div style={{ display: 'flex', gap: 16, padding: '10px 0', borderBottom: `1px solid ${C.line}` }}>
      <div style={{ width: 110, color: C.t3, fontSize: 13 }}>{k}</div>
      <div style={{ flex: 1 }}>
        <div style={{ fontWeight: 600 }}>{v}</div>
        {sub && <div style={{ fontSize: 12, color: C.t3 }}>{sub}</div>}
      </div>
    </div>
  )
}

function CitySelect({ value, onChange }: { value?: string; onChange: (v?: string) => void }) {
  const cities = useList<string>('/admin/push/cities')
  return (
    <Select
      allowClear
      showSearch
      placeholder="Все города"
      loading={cities.isLoading}
      value={value}
      onChange={onChange}
      style={{ width: '100%' }}
      options={(cities.data ?? []).map((c) => ({ value: c, label: c }))}
    />
  )
}

function NetworkStoreSelect({ audience, onChange }: { audience: Audience; onChange: (p: Partial<Audience>) => void }) {
  const networks = useList<{ id: string; name: string }>('/admin/networks', { limit: 200 })
  const stores = useList<{ id: string; name: string; network_name: string; network_id: string }>('/admin/home/stores')
  const value = audience.store_id ? `s:${audience.store_id}` : audience.network_id ? `n:${audience.network_id}` : undefined
  return (
    <Select
      allowClear
      showSearch
      optionFilterProp="label"
      placeholder="Все сети"
      value={value}
      loading={networks.isLoading || stores.isLoading}
      onChange={(v?: string) =>
        onChange(!v ? { network_id: undefined, store_id: undefined } : v.startsWith('s:') ? { store_id: v.slice(2), network_id: undefined } : { network_id: v.slice(2), store_id: undefined })
      }
      style={{ width: '100%' }}
      options={[
        { label: 'Сети', options: (networks.data ?? []).map((x) => ({ value: `n:${x.id}`, label: `Сеть ${x.name}` })) },
        { label: 'Магазины', options: (stores.data ?? []).map((x) => ({ value: `s:${x.id}`, label: x.name.includes(x.network_name) ? x.name : `${x.name} · ${x.network_name}` })) },
      ]}
    />
  )
}

// ─── Карточка рассылки ─────────────────────────────────────────────────────

export function PushCampaign() {
  const { id } = useParams()
  const nav = useNavigate()
  const [status, setStatus] = useState('')
  const [q, setQ] = useState('')
  const dq = useDebounced(q.trim())
  const c = useQuery({
    queryKey: [`/admin/push/campaigns/${id}`],
    queryFn: () => api.get<Campaign>(`/admin/push/campaigns/${id}`),
    refetchInterval: (query) => (query.state.data?.status === 'sending' || query.state.data?.status === 'scheduled' ? 3000 : false),
  })
  const cancel = useAction(() => api.post(`/admin/push/campaigns/${id}/cancel`), { success: 'Рассылка отменена' })
  const x = c.data
  if (!x) return c.error ? <LoadError error={c.error} retry={() => c.refetch()} /> : <Spin style={{ margin: 48 }} />
  const s = x.stats
  const notSent = s.no_push + s.failed
  const done = s.sent + notSent
  return (
    <>
      <PageTitle
        title={
          <Space>
            <Button type="text" icon={<ArrowLeftOutlined />} onClick={() => nav('/notifications')} />
            {x.title}
            <CampaignTag status={x.status} />
          </Space>
        }
        extra={
          <Space>
            {x.status === 'scheduled' && (
              <Popconfirm title="Отменить рассылку?" okText="Отменить" cancelText="Нет" onConfirm={() => cancel.mutateAsync(undefined).catch(() => undefined)}>
                <Button danger icon={<StopOutlined />} loading={cancel.isPending}>
                  Отменить рассылку
                </Button>
              </Popconfirm>
            )}
            <Button icon={<CopyOutlined />} onClick={() => nav(`/notifications/new?copy=${x.id}`)}>
              Создать похожую
            </Button>
          </Space>
        }
      >
        <Typography.Text type="secondary">
          Создал {x.created_by || '—'} {dateTime(x.created_at)}
          {x.started_at ? ` · отправка начата ${dateTime(x.started_at)}` : ''}
          {x.finished_at && x.started_at ? ` · заняла ${Math.max(1, dayjs(x.finished_at).diff(x.started_at, 'minute'))} мин` : ''}
        </Typography.Text>
      </PageTitle>
      {x.status === 'scheduled' && (
        <Hint icon={<ClockCircleOutlined />} style={{ marginBottom: 16 }}>
          <b>
            Отправится {dateTime(x.send_at)} · подходят {n(x.recipients)} покупателей.
          </b>{' '}
          Отменить можно до начала отправки.
        </Hint>
      )}
      {x.status === 'cancelled' && <Alert type="info" showIcon style={{ marginBottom: 16 }} message={`Рассылка отменена ${x.cancelled_at ? dateTime(x.cancelled_at) : ''} и не отправлялась.`} />}
      {(x.status === 'sent' || x.status === 'sending') && (
        <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
          <Col xs={12} lg={x.status === 'sending' ? 6 : 8}>
            <StatCard icon={<TeamOutlined />} color={C.t2} bg="#f2f4f7" value={n(x.recipients)} title="Получателей" sub={x.audience_title} />
          </Col>
          <Col xs={12} lg={x.status === 'sending' ? 6 : 8}>
            <StatCard
              icon={<CheckCircleOutlined />}
              color="#067647"
              bg="#dcfae6"
              value={n(s.sent)}
              title="Доставлено"
              sub={done ? `${Math.round((s.sent / done) * 1000) / 10}% — Firebase принял на устройство` : undefined}
            />
          </Col>
          <Col xs={12} lg={x.status === 'sending' ? 6 : 8}>
            <StatCard icon={<ExclamationCircleOutlined />} color="#b42318" bg="#fee4e2" value={n(notSent)} title="Не доставлено" sub={`нет push — ${n(s.no_push)} · ошибка — ${n(s.failed)}`} />
          </Col>
          {x.status === 'sending' && (
            <Col xs={12} lg={6}>
              <StatCard icon={<SyncOutlined spin />} color={C.blue} bg={C.blueSoft} value={n(s.pending)} title="В очереди" />
            </Col>
          )}
        </Row>
      )}
      <Row gutter={16}>
        <Col xs={24} lg={8}>
          <Card title="Сообщение">
            <div style={{ border: `1px solid ${C.line}`, background: '#f8fafc', borderRadius: 14, padding: '12px 14px', marginBottom: 12 }}>
              <Space size={6} style={{ fontSize: 11, color: C.t2 }}>
                <span style={{ display: 'inline-grid', placeItems: 'center', width: 18, height: 18, borderRadius: 5, background: C.red, color: '#fff' }}>
                  <ShoppingOutlined />
                </span>
                <b>SUPER MARKET</b>
              </Space>
              <div style={{ fontWeight: 700, marginTop: 4 }}>{x.title}</div>
              <div style={{ fontSize: 13 }}>{x.body}</div>
            </div>
            <KV k="Открывает" v={x.target_title} />
            <KV k="Кому" v={x.audience_title} />
            <KV k="Когда" v={dateTime(x.send_at)} />
          </Card>
        </Col>
        <Col xs={24} lg={16}>
          <Card title="Получатели" extra={<Typography.Text type="secondary">Кому дошло и почему нет</Typography.Text>} styles={{ body: { padding: 0 } }}>
            {x.status === 'scheduled' || x.status === 'cancelled' ? (
              <Empty style={{ padding: 32 }} description={x.status === 'scheduled' ? 'Список появится, когда начнётся отправка' : 'Рассылка не отправлялась'} />
            ) : (
              <>
                <Space wrap style={{ padding: 16 }}>
                  <Input prefix={<SearchOutlined />} placeholder="Телефон или имя" allowClear value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 240 }} />
                  <Segmented
                    value={status}
                    onChange={(v) => setStatus(String(v))}
                    options={[
                      { value: '', label: `Все · ${n(x.recipients)}` },
                      { value: 'sent', label: `Доставлено · ${n(s.sent)}` },
                      { value: 'not_sent', label: `Не доставлено · ${n(notSent)}` },
                      ...(s.pending ? [{ value: 'pending', label: `В очереди · ${n(s.pending)}` }] : []),
                    ]}
                  />
                </Space>
                <PagedTable<Recipient>
                  path={`/admin/push/campaigns/${x.id}/recipients`}
                  params={{ status, q: dq }}
                  refetchInterval={x.status === 'sending' ? 3000 : undefined}
                  columns={[
                    {
                      title: 'Покупатель',
                      render: (_, r) => (
                        <>
                          <div style={{ fontWeight: 600 }}>{r.name || 'Без имени'}</div>
                          <div style={{ color: C.t3, fontSize: 12 }}>{formatPhone(r.phone)}</div>
                        </>
                      ),
                    },
                    { title: 'Устройство', dataIndex: 'devices', render: (v: string) => v || <span style={{ color: '#98a2b3' }}>—</span> },
                    {
                      title: 'Статус',
                      render: (_, r) => <Tag color={NOTIFY_STATUS[r.status as Notification['status']]?.color}>{NOTIFY_STATUS[r.status as Notification['status']]?.label ?? r.status}</Tag>,
                    },
                    {
                      title: 'Причина',
                      render: (_, r) =>
                        r.reason ? <span style={{ fontSize: 12, color: C.t2 }}>{r.reason}</span> : <span style={{ color: '#98a2b3' }}>—</span>,
                    },
                  ]}
                />
              </>
            )}
          </Card>
        </Col>
      </Row>
    </>
  )
}

// ─── Тестовый push ─────────────────────────────────────────────────────────

function TestPushModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [who, setWho] = useState<'self' | 'phone'>('phone')
  const [phone, setPhone] = useState('')
  const [title, setTitle] = useState('Проверка уведомлений')
  const [body, setBody] = useState('Если вы это видите — push работает')
  const [result, setResult] = useState<TestResult | null>(null)
  const [error, setError] = useState('')
  const customer = useCustomer(who === 'phone' ? phone : '')
  const send = useAction((v: { phone: string; title: string; body: string }) => api.post<TestResult>('/admin/push/test', v), { invalidate: [['/admin/notifications']] })

  const run = () => {
    setError('')
    send.mutateAsync({ phone: who === 'phone' ? phone : '', title, body }).then(setResult, (e) => setError(errorText(e)))
  }
  return (
    <Modal
      open={open}
      onCancel={onClose}
      width={560}
      title={
        <Space>
          <MobileOutlined style={{ color: C.blue }} /> Тестовый push
        </Space>
      }
      footer={[
        <Button key="close" onClick={onClose}>
          Закрыть
        </Button>,
        <Button key="send" type="primary" icon={<SendOutlined />} loading={send.isPending} disabled={who === 'phone' && !customer.data} onClick={run}>
          {result ? 'Отправить ещё раз' : 'Отправить'}
        </Button>,
      ]}
    >
      <Typography.Paragraph type="secondary">Проверить, доходят ли уведомления до конкретного телефона. Ответ Firebase — по каждому устройству.</Typography.Paragraph>
      <Space direction="vertical" size={12} style={{ width: '100%' }}>
        <Segmented
          block
          value={who}
          onChange={(v) => {
            setWho(v as 'self' | 'phone')
            setResult(null)
            setError('')
          }}
          options={[
            { value: 'self', label: 'Себе', icon: <UserOutlined /> },
            { value: 'phone', label: 'По номеру телефона', icon: <GlobalOutlined /> },
          ]}
        />
        {who === 'phone' ? (
          <>
            <div>
              <Label>Телефон покупателя</Label>
              <PhoneInput value={phone} onChange={(v) => (setPhone(v), setResult(null))} />
            </div>
            {customer.isFetching && <Spin size="small" />}
            {customer.error && <Alert type="warning" showIcon message={errorText(customer.error)} />}
            {customer.data && <CustomerCard c={customer.data} />}
          </>
        ) : (
          <Typography.Text type="secondary">Уйдёт на устройства, где вы вошли в приложение покупателя под своим номером.</Typography.Text>
        )}
        <div>
          <Label>Заголовок</Label>
          <Input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={65} />
        </div>
        <div>
          <Label>Текст</Label>
          <Input value={body} onChange={(e) => setBody(e.target.value)} maxLength={240} />
        </div>
        {error && <Alert type="error" showIcon message={error} />}
        {result && (
          <div>
            <Label>Результат · {dayjs(result.sent_at).format('HH:mm')}</Label>
            {result.results.map((r, i) => (
              <div key={i} style={{ display: 'flex', gap: 12, alignItems: 'center', padding: '10px 0', borderBottom: `1px solid ${C.line}` }}>
                <MobileOutlined style={{ fontSize: 20, color: C.t2 }} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 600 }}>{r.name}</div>
                  <div style={{ fontSize: 12, color: r.ok ? C.t3 : '#b42318' }}>{r.ok ? `Firebase принял за ${(r.ms / 1000).toFixed(1).replace('.', ',')} с` : r.reason}</div>
                </div>
                {r.ok ? <Tag color="green" icon={<CheckCircleOutlined />}>Доставлено</Tag> : <Tag color="red" icon={<ExclamationCircleOutlined />}>Ошибка</Tag>}
              </div>
            ))}
          </div>
        )}
      </Space>
    </Modal>
  )
}

