// Crowd-доставка (курьеры «по пути»): обзор, курьеры, инциденты, выплаты,
// подключённые магазины и правила.
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  Button,
  Card,
  Checkbox,
  Col,
  Form,
  Input,
  InputNumber,
  Modal,
  Popconfirm,
  Row,
  Segmented,
  Space,
  Statistic,
  Switch,
  Table,
  Tabs,
  Tag,
  Typography,
} from 'antd'
import { LoadError, PageTitle, PagedTable, api, date, dateTime, money, useAction, useItem } from '@sm/shared'
import { useUrlState } from '../hooks'

type Overview = {
  today_offered: number
  today_taken: number
  crowd_minutes: number | null
  staff_minutes: number | null
  verified: number
  unverified: number
  blocked: number
  online_now: number
  new_week: number
  open_incidents: number
  lost_week: number
  payout_total: string
  payout_count: number
  payout_on: string
  bonus_pending: string
  stores: number
}

type CrowdCourier = {
  user_id: string
  code: string
  full_name: string
  phone: string
  status: 'unverified' | 'active' | 'blocked'
  online: boolean
  busy: boolean
  level: string
  delivered: number
  ontime_pct: number
  open_incidents: number
  balance: string
  verified_store: string | null
  verified_at: string | null
  blocked_reason: string
  created_at: string
}

type Incident = {
  id: string
  courier_id: string
  courier_name: string
  courier_code: string
  order_id: string | null
  order_number: number | null
  store_name: string | null
  kind: 'pickup_timeout' | 'no_handoff' | 'complaint' | 'released' | 'other'
  note: string
  violation: boolean
  status: 'open' | 'resolved'
  resolution: string
  created_at: string
  resolved_at: string | null
}

type Payout = { user_id: string; code: string; full_name: string; phone: string; balance: string; deliveries: number }

type CrowdStore = {
  id: string
  name: string
  address: string
  network_name: string
  crowd_enabled: boolean
  verifications: number
  crowd_orders: number
  bonus_pending: string
  bonus_credited: string
}

type Settings = {
  courier_fee: string
  platform_fee: string
  long_wait_bonus: string
  long_wait_minutes: number
  wait_minutes: number
  pickup_minutes: number
  radius_m: number
  detour_m: number
  store_bonus: string
  store_bonus_count: number
  store_bonus_hold_days: number
  newbie_limit: string
  newbie_parallel: number
  reliable_after: number
  reliable_ontime: number
  reliable_limit: string
  reliable_parallel: number
  trusted_after: number
  trusted_ontime: number
  trusted_limit: string
  trusted_parallel: number
}

const statusTags: Record<CrowdCourier['status'], { color: string; title: string }> = {
  unverified: { color: 'orange', title: 'Не проверен' },
  active: { color: 'green', title: 'Активен' },
  blocked: { color: 'red', title: 'Заблокирован' },
}

const kindTitles: Record<Incident['kind'], string> = {
  pickup_timeout: 'Не забрал вовремя',
  no_handoff: 'Не вручил',
  complaint: 'Жалоба',
  released: 'Отказ от заказа',
  other: 'Другое',
}

const name = (full: string, code: string) => (
  <>
    {full || 'Без имени'}
    <div>
      <Typography.Text type="secondary">{code}</Typography.Text>
    </div>
  </>
)

export function Crowd() {
  const [tab, setTab] = useUrlState('tab', 'overview')
  return (
    <>
      <PageTitle title="Курьеры по пути" />
      <Tabs
        activeKey={tab}
        onChange={setTab}
        destroyOnHidden
        items={[
          { key: 'overview', label: 'Обзор', children: <OverviewTab /> },
          { key: 'couriers', label: 'Курьеры', children: <CouriersTab /> },
          { key: 'incidents', label: 'Инциденты', children: <IncidentsTab /> },
          { key: 'payouts', label: 'Выплаты', children: <PayoutsTab /> },
          { key: 'stores', label: 'Магазины', children: <StoresTab /> },
          { key: 'settings', label: 'Правила', children: <SettingsTab /> },
        ]}
      />
    </>
  )
}

function OverviewTab() {
  const { data: o, isLoading, error, refetch } = useItem<Overview>('/admin/crowd/overview')
  const pct = o && o.today_offered ? Math.round((o.today_taken / o.today_offered) * 100) : 0
  const stat = (title: string, value: string | number, extra?: string) => (
    <Col xs={12} md={8} xl={6}>
      <Card loading={isLoading}>
        <Statistic title={title} value={value} />
        {extra && <Typography.Text type="secondary">{extra}</Typography.Text>}
      </Card>
    </Col>
  )
  return (
    <>
      <LoadError error={error} retry={() => refetch()} />
      {o && (
        <Row gutter={[16, 16]}>
          {stat('Взяли сегодня', `${o.today_taken} из ${o.today_offered}`, `${pct}% собранных заказов`)}
          {stat('Выдан → вручён', o.crowd_minutes != null ? `${o.crowd_minutes} мин` : '—', o.staff_minutes != null ? `штатные: ${o.staff_minutes} мин` : undefined)}
          {stat('Онлайн сейчас', o.online_now)}
          {stat('Подтверждены', o.verified, `ждут проверки: ${o.unverified} · заблокированы: ${o.blocked}`)}
          {stat('Новых за неделю', o.new_week)}
          {stat('Открытых инцидентов', o.open_incidents, `заказов с нарушениями за неделю: ${o.lost_week}`)}
          {stat('К выплате', money(o.payout_total), `${o.payout_count} курьерам · ${date(o.payout_on)}`)}
          {stat('Бонусы магазинам', money(o.bonus_pending), `подключено магазинов: ${o.stores}`)}
        </Row>
      )}
    </>
  )
}

function CouriersTab() {
  const [status, setStatus] = useUrlState('status', '')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const [blocking, setBlocking] = useState<CrowdCourier | null>(null)
  const [reason, setReason] = useState('')
  const block = useAction((v: { id: string; reason: string }) => api.post(`/admin/crowd/couriers/${v.id}/block`, { reason: v.reason }), {
    success: 'Курьер заблокирован',
  })
  const unblock = useAction((id: string) => api.post(`/admin/crowd/couriers/${id}/unblock`), { success: 'Курьер разблокирован' })
  return (
    <>
      <Space wrap style={{ marginBottom: 16 }}>
        <Segmented
          value={status ?? ''}
          onChange={(v) => setStatus(v as string)}
          options={[
            { value: '', label: 'Все' },
            { value: 'active', label: 'Активные' },
            { value: 'unverified', label: 'Не проверены' },
            { value: 'blocked', label: 'Заблокированы' },
          ]}
        />
        <Input.Search
          placeholder="Телефон, имя или код"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onSearch={(v) => setQ(v.trim())}
          style={{ width: 260 }}
        />
      </Space>
      <PagedTable<CrowdCourier>
        path="/admin/crowd/couriers"
        params={{ status: status || undefined, q }}
        rowKey="user_id"
        columns={[
          { title: 'Курьер', render: (_, c) => name(c.full_name, c.code) },
          { title: 'Телефон', dataIndex: 'phone' },
          {
            title: 'Статус',
            render: (_, c) => (
              <Space size={4} wrap>
                <Tag color={statusTags[c.status].color}>{statusTags[c.status].title}</Tag>
                {c.online && <Tag color="blue">онлайн</Tag>}
                {c.busy && <Tag color="purple">везёт заказ</Tag>}
              </Space>
            ),
          },
          { title: 'Уровень', dataIndex: 'level' },
          { title: 'Доставок', dataIndex: 'delivered', align: 'right' },
          { title: 'Вовремя', dataIndex: 'ontime_pct', align: 'right', render: (v: number, c) => (c.delivered ? `${v}%` : '—') },
          { title: 'Инциденты', dataIndex: 'open_incidents', align: 'right', render: (v: number) => (v ? <Tag color="red">{v}</Tag> : '—') },
          { title: 'Баланс', dataIndex: 'balance', align: 'right', render: (v: string) => money(v) },
          {
            title: 'Проверен',
            render: (_, c) =>
              c.verified_at ? (
                <>
                  {dateTime(c.verified_at)}
                  <div>
                    <Typography.Text type="secondary">{c.verified_store}</Typography.Text>
                  </div>
                </>
              ) : (
                '—'
              ),
          },
          {
            title: '',
            render: (_, c) =>
              c.status === 'blocked' ? (
                <Popconfirm title="Разблокировать курьера?" onConfirm={() => unblock.mutate(c.user_id)}>
                  <Button size="small" title={c.blocked_reason}>
                    Разблокировать
                  </Button>
                </Popconfirm>
              ) : (
                <Button size="small" danger onClick={() => setBlocking(c)}>
                  Заблокировать
                </Button>
              ),
          },
        ]}
      />
      <Modal
        open={!!blocking}
        title={`Заблокировать ${blocking?.code ?? ''}`}
        okText="Заблокировать"
        okButtonProps={{ danger: true, disabled: !reason.trim(), loading: block.isPending }}
        onCancel={() => setBlocking(null)}
        onOk={() =>
          blocking &&
          block.mutate(
            { id: blocking.user_id, reason: reason.trim() },
            {
              onSuccess: () => {
                setBlocking(null)
                setReason('')
              },
            },
          )
        }
      >
        <Typography.Paragraph type="secondary">Сессии курьера закроются, заказы до выдачи будут сняты.</Typography.Paragraph>
        <Input.TextArea rows={3} maxLength={500} placeholder="Причина" value={reason} onChange={(e) => setReason(e.target.value)} />
      </Modal>
    </>
  )
}

function IncidentsTab() {
  const [status, setStatus] = useUrlState('istatus', 'open')
  const [resolving, setResolving] = useState<Incident | null>(null)
  const [form] = Form.useForm<{ resolution: string; violation: boolean; penalty?: number }>()
  const resolve = useAction(
    (v: { id: string; resolution: string; violation: boolean; penalty?: number }) =>
      api.post(`/admin/crowd/incidents/${v.id}/resolve`, {
        resolution: v.resolution,
        violation: v.violation,
        penalty: v.penalty ? String(v.penalty) : null,
      }),
    { success: 'Инцидент закрыт' },
  )
  useEffect(() => {
    if (resolving) form.setFieldsValue({ resolution: '', violation: resolving.violation, penalty: undefined })
  }, [resolving, form])
  return (
    <>
      <Segmented
        style={{ marginBottom: 16 }}
        value={status ?? ''}
        onChange={(v) => setStatus(v as string)}
        options={[
          { value: 'open', label: 'Открытые' },
          { value: 'resolved', label: 'Закрытые' },
          { value: '', label: 'Все' },
        ]}
      />
      <PagedTable<Incident>
        path="/admin/crowd/incidents"
        params={{ status: status || undefined }}
        columns={[
          { title: 'Когда', dataIndex: 'created_at', render: dateTime },
          { title: 'Курьер', render: (_, i) => name(i.courier_name, i.courier_code) },
          {
            title: 'Что случилось',
            render: (_, i) => (
              <>
                {kindTitles[i.kind] ?? i.kind} {i.violation && <Tag color="red">нарушение</Tag>}
                {i.note && (
                  <div>
                    <Typography.Text type="secondary">{i.note}</Typography.Text>
                  </div>
                )}
              </>
            ),
          },
          {
            title: 'Заказ',
            render: (_, i) =>
              i.order_number ? (
                <>
                  № {i.order_number}
                  <div>
                    <Typography.Text type="secondary">{i.store_name}</Typography.Text>
                  </div>
                </>
              ) : (
                '—'
              ),
          },
          {
            title: 'Решение',
            render: (_, i) =>
              i.status === 'open' ? (
                <Button size="small" type="primary" onClick={() => setResolving(i)}>
                  Разобрать
                </Button>
              ) : (
                <>
                  {i.resolution || 'Закрыт'}
                  <div>
                    <Typography.Text type="secondary">{dateTime(i.resolved_at)}</Typography.Text>
                  </div>
                </>
              ),
          },
        ]}
      />
      <Modal
        open={!!resolving}
        title={resolving ? `${kindTitles[resolving.kind]} · ${resolving.courier_code}` : ''}
        okText="Закрыть инцидент"
        okButtonProps={{ loading: resolve.isPending }}
        onCancel={() => setResolving(null)}
        onOk={() => form.submit()}
        destroyOnHidden
      >
        <Form
          form={form}
          layout="vertical"
          onFinish={(v) => resolving && resolve.mutate({ id: resolving.id, ...v }, { onSuccess: () => setResolving(null) })}
        >
          <Form.Item name="resolution" label="Решение" rules={[{ required: true, whitespace: true, message: 'Опишите решение' }]}>
            <Input.TextArea rows={3} maxLength={500} />
          </Form.Item>
          <Form.Item name="violation" valuePropName="checked">
            <Checkbox>Считать нарушением курьера (влияет на уровень)</Checkbox>
          </Form.Item>
          <Form.Item name="penalty" label="Штраф, сум (необязательно)">
            <InputNumber min={0} step={1000} style={{ width: '100%' }} />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}

function PayoutsTab() {
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['/admin/crowd/payouts'],
    queryFn: () => api.get<{ items: Payout[] | null }>('/admin/crowd/payouts').then((r) => r.items ?? []),
  })
  const [selected, setSelected] = useState<string[]>([])
  const [note, setNote] = useState('')
  const pay = useAction((v: { courier_ids: string[]; note: string }) => api.post<{ paid: number }>('/admin/crowd/payouts', v), {})
  const total = (data ?? []).filter((p) => selected.includes(p.user_id)).reduce((s, p) => s + Number(p.balance), 0)
  return (
    <>
      <LoadError error={error} retry={() => refetch()} />
      <Space wrap style={{ marginBottom: 16 }}>
        <Input placeholder="Комментарий к выплате" value={note} onChange={(e) => setNote(e.target.value)} style={{ width: 280 }} maxLength={300} />
        <Popconfirm
          title={`Отметить выплату ${money(total)} — ${selected.length} курьерам?`}
          description="Баланс выбранных курьеров обнулится"
          disabled={!selected.length}
          onConfirm={() =>
            pay.mutate(
              { courier_ids: selected, note: note.trim() },
              {
                onSuccess: () => {
                  setSelected([])
                  setNote('')
                },
              },
            )
          }
        >
          <Button type="primary" disabled={!selected.length} loading={pay.isPending}>
            Выплачено{selected.length ? `: ${money(total)}` : ''}
          </Button>
        </Popconfirm>
      </Space>
      <Table<Payout>
        rowKey="user_id"
        loading={isLoading}
        dataSource={data}
        pagination={false}
        scroll={{ x: true }}
        rowSelection={{ selectedRowKeys: selected, onChange: (k) => setSelected(k as string[]) }}
        locale={{ emptyText: 'Нет курьеров с балансом' }}
        columns={[
          { title: 'Курьер', render: (_, p) => name(p.full_name, p.code) },
          { title: 'Телефон', dataIndex: 'phone' },
          { title: 'Доставок с прошлой выплаты', dataIndex: 'deliveries', align: 'right' },
          { title: 'К выплате', dataIndex: 'balance', align: 'right', render: (v: string) => <Typography.Text strong>{money(v)}</Typography.Text> },
        ]}
      />
    </>
  )
}

function StoresTab() {
  const [q, setQ] = useState('')
  const set = useAction((v: { id: string; on: boolean }) => api.put(`/admin/crowd/stores/${v.id}`, { crowd_enabled: v.on }), {
    success: 'Сохранено',
    invalidate: [['/admin/crowd/stores']],
  })
  return (
    <>
      <Input.Search placeholder="Магазин или сеть" allowClear onSearch={(v) => setQ(v.trim())} style={{ width: 280, marginBottom: 16 }} />
      <PagedTable<CrowdStore>
        path="/admin/crowd/stores"
        params={{ q: q || undefined }}
        columns={[
          {
            title: 'Магазин',
            render: (_, s) => (
              <>
                {s.name}
                <div>
                  <Typography.Text type="secondary">
                    {s.network_name} · {s.address}
                  </Typography.Text>
                </div>
              </>
            ),
          },
          {
            title: 'Курьеры по пути',
            dataIndex: 'crowd_enabled',
            render: (v: boolean, s) => <Switch checked={v} loading={set.isPending && set.variables?.id === s.id} onChange={(on) => set.mutate({ id: s.id, on })} />,
          },
          { title: 'Проверено курьеров', dataIndex: 'verifications', align: 'right' },
          { title: 'Доставок за 30 дней', dataIndex: 'crowd_orders', align: 'right' },
          { title: 'Бонус начислен', dataIndex: 'bonus_credited', align: 'right', render: (v: string) => money(v) },
          { title: 'Бонус ожидает', dataIndex: 'bonus_pending', align: 'right', render: (v: string) => money(v) },
        ]}
      />
    </>
  )
}

/** Денежные поля приходят строками, в форме — числа. */
const moneyKeys = ['courier_fee', 'platform_fee', 'long_wait_bonus', 'store_bonus', 'newbie_limit', 'reliable_limit', 'trusted_limit'] as const

function SettingsTab() {
  const { data, isLoading, error, refetch } = useItem<Settings>('/admin/crowd/settings')
  const [form] = Form.useForm()
  const save = useAction((v: Settings) => api.put<Settings>('/admin/crowd/settings', v), {
    success: 'Правила сохранены',
    invalidate: [['/admin/crowd/settings']],
  })
  useEffect(() => {
    if (!data) return
    const v: Record<string, unknown> = { ...data }
    moneyKeys.forEach((k) => (v[k] = Number(data[k])))
    form.setFieldsValue(v)
  }, [data, form])
  const num = (key: keyof Settings, label: string, opts: { min?: number; max?: number; step?: number; suffix?: string } = {}) => (
    <Col xs={24} sm={12} lg={8}>
      <Form.Item name={key} label={label} rules={[{ required: true, message: 'Обязательно' }]}>
        <InputNumber min={opts.min ?? 0} max={opts.max} step={opts.step ?? 1} addonAfter={opts.suffix} style={{ width: '100%' }} />
      </Form.Item>
    </Col>
  )
  return (
    <>
      <LoadError error={error} retry={() => refetch()} />
      <Form
        form={form}
        layout="vertical"
        disabled={isLoading}
        onFinish={(v: Record<string, unknown>) => {
          const out = { ...v } as Record<string, unknown>
          moneyKeys.forEach((k) => (out[k] = String(v[k] ?? 0)))
          save.mutate(out as unknown as Settings)
        }}
      >
        <Card title="Оплата за доставку" style={{ marginBottom: 16 }}>
          <Row gutter={16}>
            {num('courier_fee', 'Курьеру', { step: 1000, suffix: 'сум' })}
            {num('platform_fee', 'Платформе', { step: 1000, suffix: 'сум' })}
            {num('long_wait_bonus', 'Доплата за долгое ожидание', { step: 500, suffix: 'сум' })}
            {num('long_wait_minutes', 'Ожидание дольше', { min: 1, max: 120, suffix: 'мин' })}
          </Row>
        </Card>
        <Card title="Подбор заказов" style={{ marginBottom: 16 }}>
          <Row gutter={16}>
            {num('wait_minutes', 'Ждать курьера по пути', { min: 1, max: 240, suffix: 'мин' })}
            {num('pickup_minutes', 'Время дойти до магазина', { min: 5, max: 120, suffix: 'мин' })}
            {num('radius_m', 'Радиус от курьера до магазина', { min: 200, max: 20000, step: 100, suffix: 'м' })}
            {num('detour_m', 'Допустимый крюк', { min: 100, max: 10000, step: 100, suffix: 'м' })}
          </Row>
        </Card>
        <Card title="Бонус магазину за проверку" style={{ marginBottom: 16 }}>
          <Row gutter={16}>
            {num('store_bonus', 'За доставку', { step: 1000, suffix: 'сум' })}
            {num('store_bonus_count', 'За первые доставки', { max: 50 })}
            {num('store_bonus_hold_days', 'Проверочный срок', { max: 60, suffix: 'дн' })}
          </Row>
        </Card>
        <Card title="Уровни курьеров" style={{ marginBottom: 16 }}>
          <Typography.Title level={5}>Новичок</Typography.Title>
          <Row gutter={16}>
            {num('newbie_limit', 'Сумма заказа до', { step: 10000, suffix: 'сум' })}
            {num('newbie_parallel', 'Заказов одновременно', { min: 1, max: 10 })}
          </Row>
          <Typography.Title level={5}>Надёжный</Typography.Title>
          <Row gutter={16}>
            {num('reliable_after', 'После доставок')}
            {num('reliable_ontime', 'Вовремя не менее', { max: 100, suffix: '%' })}
            {num('reliable_limit', 'Сумма заказа до', { step: 10000, suffix: 'сум' })}
            {num('reliable_parallel', 'Заказов одновременно', { min: 1, max: 10 })}
          </Row>
          <Typography.Title level={5}>Проверенный</Typography.Title>
          <Row gutter={16}>
            {num('trusted_after', 'После доставок')}
            {num('trusted_ontime', 'Вовремя не менее', { max: 100, suffix: '%' })}
            {num('trusted_limit', 'Сумма заказа до', { step: 10000, suffix: 'сум' })}
            {num('trusted_parallel', 'Заказов одновременно', { min: 1, max: 10 })}
          </Row>
        </Card>
        <Button type="primary" htmlType="submit" loading={save.isPending}>
          Сохранить правила
        </Button>
      </Form>
    </>
  )
}
