import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, Button, Descriptions, Drawer, Form, Input, Popconfirm, Select, Space, Spin, Table, Tag, Typography } from 'antd'
import { CrudPage, PhoneInput, StatusTag, api, date, dateTime, errorText, formatPhone, money, phoneRule, useAction, useItem, useList } from '@sm/shared'
import { useUrlState } from '../hooks'

interface Network {
  id: string
  name: string
  kind: 'chain' | 'single'
  status: 'active' | 'blocked'
  owner_name: string
  owner_phone: string
  stores_count: number
  created_at: string
}

export function Networks() {
  const [q, setQ] = useState('')
  const [openId, setOpenId] = useUrlState('open')
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
        toolbar={<Input.Search placeholder="Название или телефон" allowClear onSearch={setQ} style={{ width: 260 }} />}
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
                  extra="Владелец входит в панель магазина по этому номеру через Telegram-бота."
                >
                  <PhoneInput />
                </Form.Item>
              </Space>
            )}
          </>
        )}
      />
      <NetworkCard id={openId ?? null} onClose={() => setOpenId(undefined)} />
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
              {n.owner_name} · {formatPhone(n.owner_phone)}
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
    </Drawer>
  )
}
