import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, Button, Descriptions, Drawer, Form, Input, Popconfirm, Select, Space, Spin, Table, Tag, Typography } from 'antd'
import { CoffeeOutlined, DeleteOutlined, KeyOutlined, ShopOutlined, TableOutlined, WarningOutlined } from '@ant-design/icons'
import { CrudPage, PhoneInput, StatusTag, api, date, dateTime, errorText, formatPhone, money, phoneRule, useAction, useItem, useList } from '@sm/shared'
import { useUrlState } from '../hooks'
import { planPrice, type Plan } from './Plans'
import { NetworkPlanModal, PlanCell, type NetworkBilling } from './NetworkPlan'
import { CredentialsModal, OwnerLoginFields, OwnerModal, OwnerPasswordState, type Credentials, type OwnerInfo } from './NetworkOwner'
import { DeleteTenantModal, type DeleteTarget } from './DeleteTenant'

/** Тип сети: сеть магазинов, одиночный магазин или дистрибьютор. */
function kindTitle(k: string, long = false): string {
  if (k === 'distributor') return 'Дистрибьютор'
  if (k === 'chain') return long ? 'Сеть магазинов' : 'Сеть'
  return 'Одиночный магазин'
}

/** Тип бизнеса: магазин или кафе (Figma «Кафе» П4). Меняет только супер-админ. */
function businessTitle(b: string | undefined): string {
  return b === 'cafe' ? 'Кафе' : 'Магазин'
}

/** Карточки выбора типа бизнеса в окне «Новая сеть». */
function BusinessTypeCards({ value = 'store', onChange }: { value?: string; onChange?: (v: string) => void }) {
  const cards = [
    { key: 'store', icon: <ShopOutlined />, title: 'Магазин', text: 'товары со штрихкодом, остатки, приходы' },
    { key: 'cafe', icon: <CoffeeOutlined />, title: 'Кафе', text: 'меню, техкарты, кухня, номер заказа' },
    { key: 'restaurant', icon: <TableOutlined />, title: 'Ресторан', text: 'столы, официанты, общий счёт', soon: true },
  ]
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
      {cards.map((c) => {
        const on = value === c.key
        return (
          <div
            key={c.key}
            role="radio"
            aria-checked={on}
            onClick={() => !c.soon && onChange?.(c.key)}
            style={{
              border: `${on ? 2 : 1}px solid ${on ? '#d92d20' : '#eaecf0'}`,
              background: on ? '#fef3f2' : c.soon ? '#f9fafb' : '#fff',
              borderRadius: 12,
              padding: 12,
              cursor: c.soon ? 'not-allowed' : 'pointer',
              opacity: c.soon ? 0.55 : 1,
            }}
          >
            <Space style={{ width: '100%', justifyContent: 'space-between' }}>
              <span style={{ fontSize: 20, color: on ? '#d92d20' : undefined }}>{c.icon}</span>
              {c.soon && <Tag bordered={false}>позже</Tag>}
            </Space>
            <div style={{ fontWeight: 700, marginTop: 6 }}>{c.title}</div>
            <div style={{ fontSize: 12, color: '#667085' }}>{c.text}</div>
          </div>
        )
      })}
    </div>
  )
}

interface Network extends OwnerInfo {
  kind: 'chain' | 'single' | 'distributor'
  status: 'active' | 'blocked'
  stores_count: number
  created_at: string
  plan_key: string
  plan_name: string
  effective_plan_key: string
  plan_trial_until: string | null
  business_type?: 'store' | 'cafe'
}

export function Networks() {
  const [q, setQ] = useState('')
  const [openId, setOpenId] = useUrlState('open')
  const [creds, setCreds] = useState<Credentials | null>(null)
  const setStatus = useAction((v: { id: string; status: string }) => api.patch(`/admin/networks/${v.id}`, { status: v.status }), {
    success: 'Статус изменён',
  })
  return (
    <>
      <CrudPage<Network>
        title="Сети и магазины"
        path="/admin/networks"
        params={{ q: q.trim() || undefined }}
        createLabel="Подключить сеть"
        toolbar={<Input.Search placeholder="Название, телефон или логин" allowClear onSearch={setQ} style={{ width: 280 }} />}
        columns={[
          {
            title: 'Название',
            dataIndex: 'name',
            render: (n, row) => <Typography.Link onClick={() => setOpenId(row.id)}>{n}</Typography.Link>,
          },
          {
            title: 'Тип',
            dataIndex: 'kind',
            render: (k, n) => (
              <Space size={4}>
                {kindTitle(k)}
                {n.business_type === 'cafe' && <Tag color="volcano">Кафе</Tag>}
              </Space>
            ),
          },
          { title: 'Магазинов', dataIndex: 'stores_count' },
          {
            title: 'Тариф',
            render: (_, n) => (
              <Space size={4} wrap>
                {n.plan_name}
                {n.effective_plan_key !== n.plan_key && n.plan_trial_until && <Tag color="gold">пробный до {date(n.plan_trial_until)}</Tag>}
              </Space>
            ),
          },
          {
            title: 'Владелец',
            render: (_, n) => (
              <>
                {n.owner_name}
                <br />
                <Typography.Text type="secondary">{formatPhone(n.owner_phone)}</Typography.Text>
                <br />
                {n.owner_login ? (
                  <Typography.Text type="secondary">
                    логин <b>{n.owner_login}</b>
                    {n.owner_temp_password && <Tag style={{ marginLeft: 6 }}>временный пароль</Tag>}
                  </Typography.Text>
                ) : (
                  <Tag color="red">нет логина</Tag>
                )}
              </>
            ),
          },
          { title: 'Статус', dataIndex: 'status', render: (s) => <StatusTag status={s} /> },
          { title: 'Подключена', dataIndex: 'created_at', render: dateTime },
          {
            key: 'block',
            render: (_, n) => (
              <Popconfirm
                title={n.status === 'active' ? 'Заблокировать сеть? Сотрудники сразу потеряют доступ.' : 'Разблокировать сеть?'}
                onConfirm={() => setStatus.mutateAsync({ id: n.id, status: n.status === 'active' ? 'blocked' : 'active' }).catch(() => undefined)}
              >
                <Button size="small" danger={n.status === 'active'} loading={setStatus.isPending && setStatus.variables?.id === n.id}>
                  {n.status === 'active' ? 'Заблокировать' : 'Разблокировать'}
                </Button>
              </Popconfirm>
            ),
          },
        ]}
        toForm={(n) => ({ name: n.name })}
        toBody={(v, editing) => (editing ? { name: v.name } : v)}
        modalWidth={560}
        onSaved={(res, editing, values) => {
          const n = res as Network
          if (!editing && n.owner_login && values.owner_password) {
            setCreds({ title: `Сеть «${n.name}» создана`, login: n.owner_login, password: String(values.owner_password) })
          }
        }}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={[{ required: true }]}>
              <Input />
            </Form.Item>
            {!editing && (
              <Space direction="vertical" style={{ width: '100%' }}>
                <Form.Item name="kind" label="Тип" initialValue="chain" rules={[{ required: true }]}>
                  <Select
                    options={[
                      { value: 'chain', label: 'Сеть магазинов' },
                      { value: 'single', label: 'Одиночный магазин' },
                      { value: 'distributor', label: 'Дистрибьютор (приложение «SM Дистрибьютор»)' },
                    ]}
                  />
                </Form.Item>
                <Form.Item noStyle dependencies={['kind']}>
                  {({ getFieldValue }) =>
                    getFieldValue('kind') !== 'distributor' && (
                      <Form.Item
                        name="business_type"
                        label="Тип бизнеса"
                        initialValue="store"
                        extra="У кафе в панели вместо «Закупок» и «Склада» будут «Меню», «Склад продуктов» и «Кухня». Тип потом меняет только супер-админ."
                      >
                        <BusinessTypeCards />
                      </Form.Item>
                    )
                  }
                </Form.Item>
                <PlanField />
                <Form.Item name="owner_name" label="Имя владельца" rules={[{ required: true }]}>
                  <Input />
                </Form.Item>
                <Form.Item
                  name="owner_phone"
                  label="Телефон владельца"
                  rules={[phoneRule(true)]}
                  extra="Для связи. Номер владельца потом меняет только супер-админ."
                >
                  <PhoneInput />
                </Form.Item>
                <OwnerLoginFields />
              </Space>
            )}
          </>
        )}
      />
      <NetworkCard id={openId ?? null} onClose={() => setOpenId(undefined)} />
      <CredentialsModal value={creds} onClose={() => setCreds(null)} />
    </>
  )
}

interface Store {
  id: string
  name: string
  address: string
  phone: string
  status: string
  created_at: string
}

/** Тариф новой сети: пусто — по умолчанию (одиночному «Бесплатный» с пробным, сети — «Сеть»). */
function PlanField() {
  const plans = useList<Plan>('/admin/plans')
  return (
    <Form.Item name="plan_key" label="Тариф" extra="Пусто — одиночный магазин начнёт с «Бесплатного» и пробного периода, сеть магазинов — с «Сети». Поменять можно потом.">
      <Select
        allowClear
        placeholder="По умолчанию"
        options={(plans.data ?? []).filter((p) => p.is_active).map((p) => ({ value: p.key, label: `${p.name} — ${planPrice(p)} за магазин${p.is_public ? '' : ' (скрытый)'}` }))}
      />
    </Form.Item>
  )
}

/** Карточка сети: владелец, магазины, подписка, баланс и ссылки на связанные списки. */
function NetworkCard({ id, onClose }: { id: string | null; onClose: () => void }) {
  const net = useItem<Network>(id ? `/admin/networks/${id}` : null)
  const stores = useList<Store>(id ? `/admin/networks/${id}/stores` : null)
  const billing = useItem<NetworkBilling>(id ? `/admin/billing/networks/${id}` : null)
  const n = net.data
  const b = billing.data
  const [owner, setOwner] = useState<Network | null>(null)
  const [planOpen, setPlanOpen] = useState(false)
  const [del, setDel] = useState<DeleteTarget | null>(null)
  const setStatus = useAction((status: string) => api.patch(`/admin/networks/${id}`, { status }), { success: 'Статус изменён' })
  const setBusiness = useAction((v: { id: string; business_type: string }) => api.patch(`/admin/networks/${v.id}`, { business_type: v.business_type }), {
    success: 'Тип бизнеса изменён',
  })
  const error = net.error ?? stores.error ?? billing.error
  return (
    <Drawer open={id !== null} onClose={onClose} width={720} title={n ? n.name : 'Сеть'}>
      {net.isLoading && <Spin style={{ display: 'block', margin: '48px auto' }} />}
      {error && (
        <Alert
          type="error"
          showIcon
          style={{ marginBottom: 16 }}
          message="Не удалось загрузить данные сети"
          description={errorText(error)}
          action={
            <Button
              size="small"
              onClick={() => {
                net.refetch()
                stores.refetch()
                billing.refetch()
              }}
            >
              Повторить
            </Button>
          }
        />
      )}
      {n && id && (
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label="Тип">{kindTitle(n.kind, true)}</Descriptions.Item>
            {n.kind !== 'distributor' && (
              <Descriptions.Item label="Тип бизнеса">
                <Space>
                  {businessTitle(n.business_type)}
                  <Popconfirm
                    title={n.business_type === 'cafe' ? 'Сделать магазином? Меню и техкарты останутся, но разделы кафе скроются.' : 'Сделать кафе? В панели появятся «Меню», «Склад продуктов» и «Кухня».'}
                    onConfirm={() =>
                      setBusiness
                        .mutateAsync({ id: n.id, business_type: n.business_type === 'cafe' ? 'store' : 'cafe' })
                        .then(() => net.refetch())
                        .catch(() => undefined)
                    }
                  >
                    <Button size="small" loading={setBusiness.isPending}>
                      {n.business_type === 'cafe' ? 'Сделать магазином' : 'Сделать кафе'}
                    </Button>
                  </Popconfirm>
                </Space>
              </Descriptions.Item>
            )}
            <Descriptions.Item label="Статус">
              <StatusTag status={n.status} />
            </Descriptions.Item>
            <Descriptions.Item label="Владелец">
              <Space direction="vertical" size={2}>
                <span>
                  {n.owner_name} · {formatPhone(n.owner_phone)}
                </span>
                {n.owner_login && (
                  <span>
                    Логин: <b>{n.owner_login}</b>
                  </span>
                )}
                <OwnerPasswordState n={n} />
                <Button size="small" icon={<KeyOutlined />} onClick={() => setOwner(n)} style={{ marginTop: 4 }}>
                  {n.owner_login ? 'Владелец и вход' : 'Выдать логин'}
                </Button>
              </Space>
            </Descriptions.Item>
            <Descriptions.Item label="Подключена">{dateTime(n.created_at)}</Descriptions.Item>
            {b && (
              <>
                <Descriptions.Item label="Тариф">
                  <Space direction="vertical" size={4}>
                    <PlanCell b={b} />
                    <span>
                      {money(b.price_per_store)} сум за магазин
                      {b.custom_price_uzs !== null && <Tag color="purple">своя цена</Tag>}· {money(b.monthly_uzs)} сум в месяц, платит с {date(b.billing_from)}
                    </span>
                    <Button size="small" onClick={() => setPlanOpen(true)}>
                      Изменить тариф
                    </Button>
                  </Space>
                </Descriptions.Item>
                <Descriptions.Item label="Баланс">
                  {money(b.balance_available)} сум <Typography.Text type="secondary">(+{money(b.balance_pending)} в пути)</Typography.Text>
                </Descriptions.Item>
                <Descriptions.Item label="Долг по подписке">
                  {Number(b.unpaid_uzs) > 0 ? (
                    <Typography.Text type={b.overdue ? 'danger' : undefined}>
                      {money(b.unpaid_uzs)} сум{b.overdue && ' — просрочен'}
                    </Typography.Text>
                  ) : (
                    '—'
                  )}
                </Descriptions.Item>
              </>
            )}
          </Descriptions>
          <Space wrap>
            <Link to={`/orders?network_id=${id}`}>Заказы</Link>
            <Link to={`/billing/invoices?network_id=${id}`}>Счета за подписку</Link>
            <Link to={`/payouts?network_id=${id}&status=`}>Выводы денег</Link>
          </Space>
          <div>
            <Typography.Title level={5}>Магазины</Typography.Title>
            <Table<Store>
              rowKey="id"
              size="small"
              loading={stores.isLoading}
              dataSource={stores.data}
              pagination={false}
              scroll={{ x: true }}
              columns={[
                { title: 'Название', dataIndex: 'name' },
                { title: 'Адрес', dataIndex: 'address', render: (v) => v || '—' },
                { title: 'Телефон', dataIndex: 'phone', render: (v) => formatPhone(v) || '—' },
                { title: 'Статус', dataIndex: 'status', render: (s) => (s === 'active' ? <Tag color="green">Работает</Tag> : <Tag>Выключен</Tag>) },
                {
                  key: 'delete',
                  width: 100,
                  render: (_, s) => (
                    <Button size="small" danger icon={<DeleteOutlined />} onClick={() => setDel({ kind: 'store', id: s.id, name: s.name })}>
                      Удалить
                    </Button>
                  ),
                },
              ]}
            />
          </div>
          <DangerZone
            n={n}
            blocking={setStatus.isPending}
            onToggleBlock={() => setStatus.mutateAsync(n.status === 'active' ? 'blocked' : 'active').catch(() => undefined)}
            onDelete={() => setDel({ kind: 'network', id: n.id, name: n.name, networkKind: n.kind })}
          />
        </Space>
      )}
      <OwnerModal network={owner} onClose={() => setOwner(null)} />
      <DeleteTenantModal target={del} onClose={() => setDel(null)} onDeleted={del?.kind === 'network' ? onClose : undefined} />
      <NetworkPlanModal
        networkId={planOpen ? id : null}
        onClose={() => {
          setPlanOpen(false)
          billing.refetch()
          net.refetch()
        }}
      />
    </Drawer>
  )
}

/**
 * «Опасная зона» карточки сети (Figma УС1): заблокировать — для неплательщиков
 * и нарушителей, удалить — навсегда, с подтверждением названием.
 */
function DangerZone({ n, blocking, onToggleBlock, onDelete }: { n: Network; blocking: boolean; onToggleBlock: () => void; onDelete: () => void }) {
  const what = n.kind === 'single' ? 'магазин' : n.kind === 'distributor' ? 'агента' : 'сеть'
  return (
    <div style={{ border: '1px solid #FECDCA', background: '#FFFBFA', borderRadius: 10, padding: 16 }}>
      <Space direction="vertical" size={8} style={{ width: '100%' }}>
        <Space size={8}>
          <WarningOutlined style={{ color: '#D92D20' }} />
          <Typography.Text strong style={{ color: '#D92D20' }}>
            Опасная зона
          </Typography.Text>
        </Space>
        <Typography.Text type="secondary">
          Удалить {what} «{n.name}» целиком
          {n.kind === 'chain' ? `: ${n.stores_count} маг., сотрудники, товары сети, остатки, документы, продажи и заказы` : ' со всеми данными'}. Вернуть
          будет нельзя. Одобренные товары останутся в центральной базе. Если {n.kind === 'chain' ? 'сеть' : 'магазин'} просто не платит или нарушает
          правила — лучше «Заблокировать».
        </Typography.Text>
        <Space wrap style={{ marginTop: 4 }}>
          <Popconfirm
            title={n.status === 'active' ? 'Заблокировать? Сотрудники сразу потеряют доступ.' : 'Разблокировать?'}
            onConfirm={onToggleBlock}
          >
            <Button loading={blocking}>{n.status === 'active' ? 'Заблокировать' : 'Разблокировать'}</Button>
          </Popconfirm>
          <Button type="primary" danger icon={<DeleteOutlined />} onClick={onDelete}>
            Удалить {what}…
          </Button>
        </Space>
      </Space>
    </div>
  )
}
