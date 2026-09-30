// Покупатели приложения: поиск, карточка, блокировка.
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, Button, Checkbox, Descriptions, Drawer, Input, Modal, Popconfirm, Space, Spin, Table, Tag, Typography } from 'antd'
import { PageTitle, PagedTable, StatusTag, api, dateTime, errorText, money, useAction, useItem } from '@sm/shared'
import { useUrlState } from '../hooks'

interface Customer {
  id: string
  phone: string
  full_name: string
  created_at: string
  deleted_at: string | null
  blocked_at: string | null
  blocked_reason: string
  orders_count: number
  last_order_at: string | null
  family_name: string | null
  telegram_linked: boolean
}

interface CustomerDetail extends Customer {
  language: string
  city: string
  devices_count: number
  addresses: { id: string; label: string; address: string; apartment: string; created_at: string }[]
  recent_orders: { id: string; number: number; store_name: string; status: string; total: string; created_at: string }[]
}

function CustomerTags({ c }: { c: Customer }) {
  return (
    <>
      {c.blocked_at && <Tag color="red">Заблокирован</Tag>}
      {c.deleted_at && <Tag>Аккаунт удалён</Tag>}
    </>
  )
}

export function Customers() {
  const [q, setQ] = useUrlState('q')
  const [blocked, setBlocked] = useUrlState('blocked')
  const [search, setSearch] = useState(q ?? '')
  const [openId, setOpenId] = useUrlState('open')
  return (
    <>
      <PageTitle title="Покупатели">
        <Input.Search
          placeholder="Телефон или имя"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onSearch={(v) => setQ(v.trim())}
          style={{ width: 240 }}
        />
        <Checkbox checked={blocked === 'true'} onChange={(e) => setBlocked(e.target.checked ? 'true' : undefined)}>
          Только заблокированные
        </Checkbox>
      </PageTitle>
      <PagedTable<Customer>
        path="/admin/customers"
        params={{ q, blocked: blocked === 'true' || undefined }}
        onRow={(c) => ({ onClick: () => setOpenId(c.id), style: { cursor: 'pointer' } })}
        columns={[
          {
            title: 'Покупатель',
            render: (_, c) => (
              <>
                {c.phone} <CustomerTags c={c} />
                {c.full_name && (
                  <div>
                    <Typography.Text type="secondary">{c.full_name}</Typography.Text>
                  </div>
                )}
              </>
            ),
          },
          { title: 'Заказов', dataIndex: 'orders_count', align: 'right' },
          { title: 'Последний заказ', dataIndex: 'last_order_at', render: dateTime },
          { title: 'Семья', dataIndex: 'family_name', render: (v: string | null) => v ?? '—' },
          { title: 'Telegram', dataIndex: 'telegram_linked', render: (v: boolean) => (v ? <Tag color="blue">привязан</Tag> : '—') },
          { title: 'С нами с', dataIndex: 'created_at', render: dateTime },
        ]}
      />
      <CustomerDrawer id={openId ?? null} onClose={() => setOpenId(undefined)} />
    </>
  )
}

function CustomerDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const { data: c, isLoading, error, refetch } = useItem<CustomerDetail>(id ? `/admin/customers/${id}` : null)
  const [blockOpen, setBlockOpen] = useState(false)
  const [reason, setReason] = useState('')
  const closeBlock = () => {
    setBlockOpen(false)
    setReason('')
  }
  const block = useAction((v: { id: string; reason: string }) => api.post(`/admin/customers/${v.id}/block`, { reason: v.reason }), {
    success: 'Покупатель заблокирован',
  })
  const unblock = useAction((cid: string) => api.post(`/admin/customers/${cid}/unblock`), { success: 'Покупатель разблокирован' })
  return (
    <Drawer open={id !== null} onClose={onClose} width={640} title={c ? c.phone : 'Покупатель'}>
      {isLoading && <Spin style={{ display: 'block', margin: '48px auto' }} />}
      {error && (
        <Alert
          type="error"
          showIcon
          message="Не удалось загрузить покупателя"
          description={errorText(error)}
          action={<Button size="small" onClick={() => refetch()}>Повторить</Button>}
        />
      )}
      {c && (
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          {c.blocked_at && (
            <Alert
              type="error"
              showIcon
              message={`Заблокирован ${dateTime(c.blocked_at)}`}
              description={
                <>
                  {c.blocked_reason}
                  <br />
                  Не может заново войти в приложение и оформить заказ; свои заказы видит.
                </>
              }
            />
          )}
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label="Имя">{c.full_name || '—'}</Descriptions.Item>
            <Descriptions.Item label="Статус">
              <CustomerTags c={c} /> {!c.blocked_at && !c.deleted_at && <Tag color="green">Активен</Tag>}
            </Descriptions.Item>
            <Descriptions.Item label="Язык, город">
              {c.language === 'uz' ? 'Узбекский' : 'Русский'}
              {c.city && `, ${c.city}`}
            </Descriptions.Item>
            <Descriptions.Item label="Семья">{c.family_name ?? '—'}</Descriptions.Item>
            <Descriptions.Item label="Telegram">{c.telegram_linked ? 'Номер привязан к боту' : 'Не привязан'}</Descriptions.Item>
            <Descriptions.Item label="Устройств с push">{c.devices_count}</Descriptions.Item>
            <Descriptions.Item label="Заказов">{c.orders_count}</Descriptions.Item>
            <Descriptions.Item label="Регистрация">{dateTime(c.created_at)}</Descriptions.Item>
          </Descriptions>
          <Space wrap>
            <Link to={`/orders?q=${encodeURIComponent(c.phone.replace(/\D/g, ''))}`}>Все заказы покупателя</Link>
            <Link to={`/notifications?q=${encodeURIComponent(c.phone.replace(/\D/g, ''))}`}>Уведомления</Link>
          </Space>
          <div>
            <Typography.Title level={5}>Адреса</Typography.Title>
            {c.addresses.length === 0 ? (
              <Typography.Text type="secondary">Нет сохранённых адресов</Typography.Text>
            ) : (
              c.addresses.map((a) => (
                <div key={a.id}>
                  {a.label && <b>{a.label}: </b>}
                  {a.address}
                  {a.apartment && `, кв. ${a.apartment}`}
                </div>
              ))
            )}
          </div>
          <div>
            <Typography.Title level={5}>Последние заказы</Typography.Title>
            <Table
              rowKey="id"
              size="small"
              pagination={false}
              dataSource={c.recent_orders}
              columns={[
                { title: '№', dataIndex: 'number' },
                { title: 'Создан', dataIndex: 'created_at', render: dateTime },
                { title: 'Магазин', dataIndex: 'store_name' },
                { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
                { title: 'Статус', dataIndex: 'status', render: (s: string) => <StatusTag status={s} /> },
              ]}
            />
          </div>
          {c.blocked_at ? (
            <Popconfirm title="Разблокировать покупателя?" onConfirm={() => unblock.mutateAsync(c.id).catch(() => undefined)}>
              <Button loading={unblock.isPending}>Разблокировать</Button>
            </Popconfirm>
          ) : (
            <Button danger onClick={() => setBlockOpen(true)}>
              Заблокировать
            </Button>
          )}
        </Space>
      )}
      <Modal
        open={blockOpen}
        title="Заблокировать покупателя"
        okText="Заблокировать"
        cancelText="Закрыть"
        okButtonProps={{ danger: true, disabled: !reason.trim() }}
        confirmLoading={block.isPending}
        onCancel={closeBlock}
        onOk={() => block.mutate({ id: c!.id, reason }, { onSuccess: closeBlock })}
      >
        <Typography.Paragraph>Покупатель не сможет заново войти в приложение и оформить заказ. Уже оформленные заказы это не затрагивает.</Typography.Paragraph>
        <Input.TextArea rows={3} maxLength={500} placeholder="Причина (видна только в админке)" value={reason} onChange={(e) => setReason(e.target.value)} />
      </Modal>
    </Drawer>
  )
}
