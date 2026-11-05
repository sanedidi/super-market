// Магазины → Заявки агентов (Figma «Супер-админ · Заявки агентов на магазины»,
// С1–С3): агент «SM Агент» добавил магазин, которого ещё нет в Super Market.
// «Подключить» — обычное создание сети, поля уже из заявки, сеть навсегда
// привязана к агенту; «Отклонить» — только с причиной (её увидит агент).
// С первого оплаченного счёта подписки магазина агенту начисляется 50%.
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert, App, Avatar, Button, Card, Empty, Flex, Form, Input, Modal, Segmented, Space, Spin, Statistic, Table, Tabs, Tag, Typography } from 'antd'
import { CheckCircleOutlined, EnvironmentOutlined, LockOutlined, PhoneOutlined, StopOutlined, WarningOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, PhoneInput, api, date, dateTime, errorText, formatPhone, money, phoneRule, useYmaps } from '@sm/shared'
import { useUrlState } from '../hooks'
import { BusinessTypeCards, PlanField } from './Networks'
import { CredentialsModal, OwnerLoginFields, type Credentials } from './NetworkOwner'

type Status = 'pending' | 'connected' | 'paid' | 'rejected' | 'expired'

interface Nearby {
  kind: 'store' | 'lead'
  name: string
  phone: string
  address: string
  distance_m: number
  lat: number
  lng: number
}

export interface StoreLead {
  id: string
  name: string
  owner_name: string
  owner_phone: string
  address: string
  lat: number
  lng: number
  status: Status
  reason: string
  expires_at: string
  created_at: string
  decided_at: string | null
  network_id: string | null
  network_name: string
  plan_name: string
  invoice_due: string | null
  invoice_amount?: string | null
  paid_amount?: string | null
  paid_at: string | null
  reward_amount: string | null
  rewarded_at: string | null
  agent_network_id: string
  agent_network_name: string
  agent_name: string
  agent_phone: string
  agent_connected?: number
  agent_paid?: number
  nearby?: Nearby[]
}

interface Counts {
  all: number
  pending: number
  connected: number
  paid: number
  closed: number
}

const palette = [
  ['#dbeafe', '#1d4ed8'],
  ['#dcfce7', '#15803d'],
  ['#fef3c7', '#b45309'],
  ['#ede9fe', '#6d28d9'],
  ['#fce7f3', '#be185d'],
]

function initials(name: string) {
  const w = name.trim().split(/\s+/).filter(Boolean)
  if (w.length === 0) return '?'
  return (w.length === 1 ? w[0].slice(0, 2) : w[0][0] + w[1][0]).toUpperCase()
}

function LeadAvatar({ name, size = 44 }: { name: string; size?: number }) {
  let h = 0
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) | 0
  const [bg, fg] = palette[Math.abs(h) % palette.length]
  return (
    <Avatar shape="square" size={size} style={{ background: bg, color: fg, fontWeight: 800, borderRadius: 10, flex: 'none' }}>
      {initials(name)}
    </Avatar>
  )
}

/** Дней до конца закрепления (минимум 0). */
function daysLeft(until: string) {
  return Math.max(0, Math.ceil((new Date(until).getTime() - Date.now()) / (24 * 3600 * 1000)))
}

export function leadStatusTag(l: Pick<StoreLead, 'status' | 'reward_amount'>): ReactNode {
  switch (l.status) {
    case 'pending':
      return <Tag color="gold">Новая · ждёт решения</Tag>
    case 'connected':
      return <Tag color="orange">Ждём первую оплату</Tag>
    case 'paid':
      return <Tag color="green">Оплатил · агенту {money(l.reward_amount)} сум</Tag>
    case 'rejected':
      return <Tag color="red">Отклонена</Tag>
    case 'expired':
      return <Tag>Срок истёк</Tag>
  }
}

/** Значок у пункта меню: сколько новых заявок. */
export function StoreLeadsBadge() {
  const { data } = useQuery({
    queryKey: ['store-leads', 'badge'],
    queryFn: () => api.get<{ counts: Counts }>('/admin/store-leads', { status: 'pending', limit: 1 }),
    refetchInterval: 60_000,
  })
  const n = data?.counts.pending ?? 0
  if (!n) return null
  return (
    <span style={{ background: '#e11d2a', color: '#fff', borderRadius: 9, padding: '0 7px', fontSize: 11, fontWeight: 700, lineHeight: '17px', display: 'inline-block' }}>
      {n}
    </span>
  )
}

export function StoreLeads() {
  const [status = 'pending', setStatus] = useUrlState('status', 'pending')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const [openId, setOpenId] = useUrlState('open')
  const list = useQuery({
    queryKey: ['store-leads', status, q],
    queryFn: () => api.get<{ items: StoreLead[]; counts: Counts }>('/admin/store-leads', { status, q, limit: 100 }),
    placeholderData: keepPreviousData,
  })
  const items = list.data?.items ?? []
  const c = list.data?.counts
  // По умолчанию открыта первая заявка списка.
  useEffect(() => {
    if (!openId && items.length > 0) setOpenId(items[0].id)
  }, [openId, items, setOpenId])

  const tabs = [
    { key: 'pending', label: `Новые · ${c?.pending ?? 0}` },
    { key: 'connected', label: `Подключены · ${c?.connected ?? 0}` },
    { key: 'paid', label: `Оплатили · ${c?.paid ?? 0}` },
    { key: 'closed', label: `Закрыты · ${c?.closed ?? 0}` },
  ]
  return (
    <>
      <PageTitle
        title={
          <Space>
            Заявки агентов на магазины
            {(c?.pending ?? 0) > 0 && <Tag color="red">{c?.pending} новые</Tag>}
          </Space>
        }
      />
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        Агенты «SM Агент» добавляют магазины, которых ещё нет в Super Market. Подключите — откроется создание сети с уже заполненными полями, магазин
        закрепится за агентом. С первого оплаченного счёта подписки агенту начислится 50%.
      </Typography.Paragraph>
      <Flex gap={24} align="flex-start" wrap>
        <Card style={{ flex: '1 1 520px', maxWidth: 640 }}>
          <Tabs
            activeKey={status}
            onChange={(k) => {
              setStatus(k)
              setOpenId(undefined)
            }}
            items={tabs}
          />
          <Input.Search
            placeholder="Поиск по магазину, телефону или агенту"
            allowClear
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onSearch={(v) => setQ(v.trim())}
            style={{ marginBottom: 12 }}
          />
          {list.error ? (
            <LoadError error={list.error} retry={() => list.refetch()} />
          ) : list.isLoading ? (
            <Spin />
          ) : items.length === 0 ? (
            <Empty description={status === 'pending' ? 'Новых заявок нет' : 'Заявок нет'} />
          ) : (
            <Flex vertical gap={8}>
              {items.map((l) => (
                <Card
                  key={l.id}
                  size="small"
                  hoverable
                  onClick={() => setOpenId(l.id)}
                  style={{ borderColor: l.id === openId ? '#e11d2a' : undefined, background: l.id === openId ? '#fef3f2' : undefined }}
                >
                  <Flex gap={12} align="center">
                    <LeadAvatar name={l.name} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <Typography.Text strong>{l.name}</Typography.Text>
                      <div>
                        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                          {l.owner_name} · {formatPhone(l.owner_phone)}
                        </Typography.Text>
                      </div>
                      <div style={{ fontSize: 12 }}>
                        Агент: {l.agent_name} · {l.agent_network_name}
                      </div>
                    </div>
                    <Flex vertical align="flex-end" gap={4}>
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                        {dateTime(l.created_at)}
                      </Typography.Text>
                      {l.status === 'pending' ? <Tag>Закреплён ещё {daysLeft(l.expires_at)} дн</Tag> : leadStatusTag(l)}
                    </Flex>
                  </Flex>
                </Card>
              ))}
            </Flex>
          )}
          <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginTop: 12, marginBottom: 0 }}>
            Заявка без решения 30 дней уходит в «Срок истёк» — магазин снова может добавить любой агент. О новой заявке приходит уведомление в Telegram-бот.
          </Typography.Paragraph>
        </Card>
        <div style={{ flex: '1 1 480px', maxWidth: 600 }}>
          {openId ? (
            <LeadCard key={openId} id={openId} />
          ) : (
            <Card>
              <Empty description="Выберите заявку" />
            </Card>
          )}
        </div>
      </Flex>
    </>
  )
}

/** Карта заявки: точка магазина и что есть рядом (только просмотр). */
function LeadMap({ lead }: { lead: StoreLead }) {
  const { ymaps, error } = useYmaps()
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ymaps || !box.current) return
    const m = new ymaps.Map(box.current, { center: [lead.lat, lead.lng], zoom: 17, controls: ['zoomControl'] }, { suppressMapOpenBlock: true })
    m.geoObjects.add(new ymaps.Placemark([lead.lat, lead.lng], { hintContent: lead.name }, { preset: 'islands#redShoppingIcon' }))
    for (const n of lead.nearby ?? []) {
      m.geoObjects.add(new ymaps.Placemark([n.lat, n.lng], { hintContent: `${n.name} · ${n.distance_m} м` }, { preset: 'islands#orangeShoppingIcon' }))
    }
    return () => m.destroy()
  }, [ymaps, lead])
  if (error) return null
  return <div ref={box} style={{ height: 180, borderRadius: 12, overflow: 'hidden', background: '#e4eaf1' }} />
}

function LeadCard({ id }: { id: string }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const { data: l, error, isLoading, refetch } = useQuery({
    queryKey: ['store-lead', id],
    queryFn: () => api.get<StoreLead>(`/admin/store-leads/${id}`),
  })
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [connectOpen, setConnectOpen] = useState(false)

  if (error) return <LoadError error={error} retry={() => refetch()} />
  if (isLoading || !l) return <Card><Spin /></Card>

  const pending = l.status === 'pending'
  const reject = async () => {
    if (!reason.trim()) {
      message.warning('Напишите причину — её увидит агент')
      return
    }
    setBusy(true)
    try {
      await api.post(`/admin/store-leads/${id}/reject`, { reason: reason.trim() })
      message.success('Заявка отклонена')
      await qc.invalidateQueries({ queryKey: ['store-leads'] })
      await refetch()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <Flex gap={14} align="center" style={{ marginBottom: 16 }}>
        <LeadAvatar name={l.name} size={64} />
        <div>
          <Typography.Title level={4} style={{ margin: 0 }}>
            {l.name}
          </Typography.Title>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            Добавлен агентом {dateTime(l.created_at)}
            {pending && ` · закреплён до ${date(l.expires_at)}`}
          </Typography.Text>
          <div>{leadStatusTag(l)}</div>
        </div>
      </Flex>

      <LeadMap lead={l} />
      <Flex gap={6} align="center" style={{ margin: '8px 0 12px', fontSize: 13 }}>
        <EnvironmentOutlined style={{ color: '#e11d2a' }} />
        <span style={{ flex: 1 }}>{l.address || 'Адрес не указан'}</span>
        <a href={`https://yandex.uz/maps/?ll=${l.lng},${l.lat}&z=18&pt=${l.lng},${l.lat}`} target="_blank" rel="noreferrer">
          Открыть в Яндекс Картах
        </a>
      </Flex>

      <Card size="small" style={{ marginBottom: 12 }}>
        <Flex gap={12} align="center">
          <div style={{ flex: 1 }}>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              Владелец
            </Typography.Text>
            <div>
              <b>{l.owner_name}</b> · {formatPhone(l.owner_phone)}
            </div>
          </div>
          <Button icon={<PhoneOutlined />} href={`tel:${l.owner_phone}`}>
            Позвонить
          </Button>
        </Flex>
      </Card>

      <Card size="small" style={{ background: '#f8fafc', marginBottom: 12 }}>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          Агент
        </Typography.Text>
        <Flex gap={12} align="center">
          <Avatar style={{ background: '#e11d2a', fontWeight: 800 }}>{initials(l.agent_name || '?')}</Avatar>
          <div style={{ flex: 1 }}>
            <Typography.Text strong>
              {l.agent_name} · {l.agent_network_name}
            </Typography.Text>
            <div style={{ fontSize: 12, color: '#667085' }}>
              {formatPhone(l.agent_phone)} · подключил {(l.agent_connected ?? 0) + (l.agent_paid ?? 0)} маг., {l.agent_paid ?? 0} оплатили
            </div>
          </div>
          <Button icon={<PhoneOutlined />} href={`tel:${l.agent_phone}`}>
            Позвонить
          </Button>
        </Flex>
      </Card>

      {pending && (l.nearby ?? []).length > 0 && (
        <Card size="small" style={{ background: '#fffaeb', borderColor: '#fedf89', marginBottom: 12 }}>
          <Typography.Text strong style={{ color: '#93370d' }}>
            <WarningOutlined /> Рядом уже есть магазин — {l.nearby![0].distance_m} м
          </Typography.Text>
          {(l.nearby ?? []).map((n, i) => (
            <div key={i} style={{ fontSize: 13, color: '#93370d', marginTop: 4 }}>
              «{n.name}»{n.kind === 'lead' ? ' (заявка другого агента)' : ''} · {n.distance_m} м{n.phone ? ` · ${formatPhone(n.phone)}` : ''}
            </div>
          ))}
          <div style={{ fontSize: 12, color: '#93370d', marginTop: 6 }}>Если это тот же магазин — отклоните заявку как дубль.</div>
        </Card>
      )}

      {pending ? (
        <Flex vertical gap={10}>
          <Alert
            type="success"
            showIcon
            message="Агенту — 50% первого оплаченного счёта"
            description="Сумма зависит от тарифа, который выберет магазин. Начислится на баланс агента автоматически, когда магазин оплатит первый счёт."
          />
          <Button type="primary" size="large" icon={<CheckCircleOutlined />} onClick={() => setConnectOpen(true)} block>
            Подключить — создать сеть с этими данными
          </Button>
          <Flex gap={10}>
            <Input size="large" placeholder="Причина отказа (увидит агент)" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} />
            <Button size="large" danger icon={<StopOutlined />} loading={busy} onClick={reject}>
              Отклонить
            </Button>
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            Агент получит пуш с решением. Отклонённую заявку он видит с причиной; магазин сразу становится свободным.
          </Typography.Text>
        </Flex>
      ) : (
        <Card size="small">
          {l.status === 'rejected' && (
            <>
              Отклонена {dateTime(l.decided_at)}. Причина: {l.reason}
            </>
          )}
          {l.status === 'expired' && <>Срок закрепления истёк {dateTime(l.expires_at)} — магазин свободен.</>}
          {(l.status === 'connected' || l.status === 'paid') && (
            <Space direction="vertical" size={2}>
              <span>
                Подключён {dateTime(l.decided_at)} — сеть <b>{l.network_name || 'удалена'}</b>
                {l.plan_name && <> · тариф «{l.plan_name}»</>}
              </span>
              {l.status === 'connected' &&
                (l.invoice_due ? (
                  <span>
                    Счёт {money(l.invoice_amount)} сум — оплатить до {date(l.invoice_due)}
                  </span>
                ) : (
                  <span>Первого счёта ещё нет (пробный период).</span>
                ))}
              {l.status === 'paid' && (
                <span>
                  Оплатил {money(l.paid_amount)} сум {dateTime(l.paid_at)} → агенту <b>{money(l.reward_amount)} сум</b> на баланс
                </span>
              )}
            </Space>
          )}
        </Card>
      )}

      <ConnectModal lead={connectOpen ? l : null} onClose={() => setConnectOpen(false)} onDone={() => refetch()} />
    </Card>
  )
}

interface ConnectForm {
  name: string
  kind: 'single' | 'chain'
  business_type: string
  owner_name: string
  owner_phone: string
  owner_login: string
  owner_password: string
  plan_key?: string
}

/** С2 · «Подключить»: создание сети, всё из заявки уже заполнено, агент привязан. */
function ConnectModal({ lead, onClose, onDone }: { lead: StoreLead | null; onClose: () => void; onDone: () => void }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [form] = Form.useForm<ConnectForm>()
  const [busy, setBusy] = useState(false)
  const [creds, setCreds] = useState<Credentials | null>(null)

  const submit = async () => {
    if (!lead) return
    const v = await form.validateFields()
    setBusy(true)
    try {
      await api.post(`/admin/store-leads/${lead.id}/connect`, v)
      message.success('Магазин подключён и закреплён за агентом')
      await qc.invalidateQueries({ queryKey: ['store-leads'] })
      await qc.invalidateQueries({ queryKey: ['/admin/networks'] })
      onDone()
      onClose()
      setCreds({ title: `Магазин «${v.name}» подключён`, login: v.owner_login.trim().toLowerCase(), password: v.owner_password })
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <Modal
        title="Подключить магазин"
        open={!!lead}
        onCancel={onClose}
        width={640}
        okText="Создать сеть и подключить"
        okButtonProps={{ icon: <CheckCircleOutlined />, loading: busy }}
        onOk={submit}
        destroyOnClose
      >
        <Typography.Paragraph type="secondary">Новая сеть · данные взяты из заявки агента</Typography.Paragraph>
        <Form
          form={form}
          layout="vertical"
          preserve={false}
          initialValues={lead ? { name: lead.name, owner_name: lead.owner_name, owner_phone: lead.owner_phone, kind: 'single', business_type: 'store' } : undefined}
        >
          <Form.Item name="name" label="Название" rules={[{ required: true, message: 'Название магазина' }]}>
            <Input />
          </Form.Item>
          <Form.Item name="kind" label="Вид">
            <Segmented block options={[{ value: 'single', label: 'Одиночный магазин' }, { value: 'chain', label: 'Сеть магазинов' }]} />
          </Form.Item>
          <Form.Item name="business_type" label="Тип бизнеса">
            <BusinessTypeCards />
          </Form.Item>
          <Flex gap={12}>
            <Form.Item name="owner_name" label="Имя владельца" rules={[{ required: true }]} style={{ flex: 1 }}>
              <Input />
            </Form.Item>
            <Form.Item name="owner_phone" label="Телефон владельца" rules={[phoneRule(true)]} style={{ flex: 1 }}>
              <PhoneInput />
            </Form.Item>
          </Flex>
          <PlanField />
          <OwnerLoginFields />
        </Form>
        {lead && (
          <Flex vertical gap={10} style={{ marginTop: 16 }}>
            <Card size="small" style={{ background: '#f8fafc' }}>
              <EnvironmentOutlined style={{ color: '#e11d2a' }} /> <b>Первый магазин сети — точка из заявки</b>
              <div style={{ fontSize: 13, color: '#667085' }}>
                {lead.address || 'Точка на карте'} · дальше владелец проходит мастер настройки как обычно
              </div>
            </Card>
            <Card size="small" style={{ background: '#ecfdf3', borderColor: '#abefc6' }}>
              <Flex gap={10} align="center">
                <Avatar size={32} style={{ background: '#e11d2a', fontWeight: 800 }}>
                  {initials(lead.agent_name || '?')}
                </Avatar>
                <div style={{ flex: 1, color: '#067647' }}>
                  <b>
                    Агент: {lead.agent_name} · {lead.agent_network_name}
                  </b>
                  <div style={{ fontSize: 12 }}>Сеть закрепится за агентом. С первого оплаченного счёта — 50% ему на баланс.</div>
                </div>
                <LockOutlined style={{ color: '#067647' }} />
              </Flex>
            </Card>
          </Flex>
        )}
      </Modal>
      <CredentialsModal value={creds} onClose={() => setCreds(null)} />
    </>
  )
}

/** Тарифы и счета → «Агентам» (С3): начисления 50% с первых оплат магазинов. */
export function AgentRewards() {
  const { data, error, isLoading, refetch } = useQuery({
    queryKey: ['store-leads', 'rewards'],
    queryFn: () => api.get<{ items: StoreLead[]; earned_month: string; waiting: number }>('/admin/store-leads/rewards', { limit: 200 }),
  })
  if (error) return <LoadError error={error} retry={() => refetch()} />
  return (
    <>
      <PageTitle title="Начисления агентам" />
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        Магазины, подключённые по заявкам агентов. Когда магазин оплачивает первый счёт подписки, агенту автоматически начисляется 50% от оплаченной суммы на
        баланс Super Market: сначала гасит его подписку, остаток агент выводит.
      </Typography.Paragraph>
      <Flex gap={16} style={{ marginBottom: 16 }} wrap>
        <Card size="small">
          <Statistic title="Начислено в этом месяце" value={money(data?.earned_month)} suffix="сум" valueStyle={{ color: '#067647', fontWeight: 800 }} />
        </Card>
        <Card size="small">
          <Statistic title="Ждём первую оплату" value={data?.waiting ?? 0} suffix="маг." valueStyle={{ color: '#b54708', fontWeight: 800 }} />
        </Card>
      </Flex>
      <Table<StoreLead>
        rowKey="id"
        loading={isLoading}
        dataSource={data?.items ?? []}
        pagination={false}
        columns={[
          { title: 'Агент', render: (_, l) => `${l.agent_name} · ${l.agent_network_name}` },
          { title: 'Магазин', render: (_, l) => l.network_name || l.name },
          { title: 'Подключён', dataIndex: 'decided_at', render: date },
          { title: 'Первый счёт', render: (_, l) => (l.paid_amount ?? l.invoice_amount ? money(l.paid_amount ?? l.invoice_amount) : '—') },
          { title: 'Оплачен', dataIndex: 'paid_at', render: (v) => (v ? date(v) : '—') },
          {
            title: 'Агенту 50%',
            render: (_, l) => (l.reward_amount ? <b style={{ color: '#067647' }}>{money(l.reward_amount)}</b> : <span style={{ color: '#98a2b3' }}>—</span>),
          },
          { title: 'Статус', render: (_, l) => (l.status === 'paid' ? <Tag color="green">На балансе агента</Tag> : <Tag color="orange">Ждём оплату</Tag>) },
        ]}
      />
    </>
  )
}
