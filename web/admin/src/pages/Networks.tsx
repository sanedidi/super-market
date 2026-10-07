import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, Button, Descriptions, Drawer, Form, Input, Popconfirm, Select, Space, Spin, Table, Tag, Typography } from 'antd'
import { KeyOutlined } from '@ant-design/icons'
import { CrudPage, PhoneInput, StatusTag, api, date, dateTime, errorText, formatPhone, money, phoneRule, useAction, useItem, useList } from '@sm/shared'
import { useUrlState } from '../hooks'
import { CredentialsModal, OwnerLoginFields, OwnerModal, OwnerPasswordState, type Credentials, type OwnerInfo } from './NetworkOwner'

interface Network extends OwnerInfo {
  kind: 'chain' | 'single'
  status: 'active' | 'blocked'
  stores_count: number
  created_at: string
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
          { title: 'Тип', dataIndex: 'kind', render: (k) => (k === 'chain' ? 'Сеть' : 'Одиночный магазин') },
          { title: 'Магазинов', dataIndex: 'stores_count' },
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
                    ]}
                  />
                </Form.Item>
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

interface NetworkBilling {
  price_per_store: string
  custom_price_per_store: string | null
  monthly_usd: string
  billing_from: string
  balance_available: string
  balance_pending: string
  unpaid_uzs: string
  overdue: boolean
}

/** Карточка сети: владелец, магазины, подписка, баланс и ссылки на связанные списки. */
function NetworkCard({ id, onClose }: { id: string | null; onClose: () => void }) {
  const net = useItem<Network>(id ? `/admin/networks/${id}` : null)
  const stores = useList<Store>(id ? `/admin/networks/${id}/stores` : null)
  const billing = useItem<NetworkBilling>(id ? `/admin/billing/networks/${id}` : null)
  const n = net.data
  const b = billing.data
  const [owner, setOwner] = useState<Network | null>(null)
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
            <Descriptions.Item label="Тип">{n.kind === 'chain' ? 'Сеть магазинов' : 'Одиночный магазин'}</Descriptions.Item>
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
                <Descriptions.Item label="Подписка">
                  {money(b.price_per_store)} $ за магазин {b.custom_price_per_store !== null && <Tag color="purple">индивидуальная</Tag>}· {money(b.monthly_usd)} $ в месяц, платит с {date(b.billing_from)}
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
              ]}
            />
          </div>
        </Space>
      )}
      <OwnerModal network={owner} onClose={() => setOwner(null)} />
    </Drawer>
  )
}
