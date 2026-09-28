import { useState } from 'react'
import { Button, Card, Descriptions, Drawer, Input, Modal, Popconfirm, Select, Space, Table, Tag, Timeline, Typography } from 'antd'
import { PageTitle, StatusTag, api, dateTime, money, qty, useAction, useItem, useList } from '@sm/shared'

interface OrderItem {
  line: number
  product_name: string
  unit_short: string
  qty: string
  price: string
  total: string
  from_other_warehouse: boolean
}

interface Order {
  id: string
  number: number
  network_id: string
  store_name: string
  status: string
  status_title: string
  subtotal: string
  delivery_fee: string
  total: string
  address: string
  apartment: string
  entrance: string
  floor: string
  address_comment: string
  customer_phone: string
  comment: string
  payment_provider: string
  payment_status: string | null
  paid_at: string | null
  accepted_at: string | null
  delivered_at: string | null
  cancel_reason: string
  fiscal_status: string
  created_at: string
  items?: OrderItem[]
  history?: { status: string; actor: string; note: string; created_at: string }[]
}

const statuses = ['awaiting_payment', 'paid', 'accepted', 'picking', 'picked', 'delivering', 'delivered', 'cancelled', 'expired']
const statusTitles: Record<string, string> = {
  awaiting_payment: 'Ждёт оплаты',
  paid: 'Оплачен',
  accepted: 'Принят',
  picking: 'Собирается',
  picked: 'Собран',
  delivering: 'В пути',
  delivered: 'Доставлен',
  cancelled: 'Отменён',
  expired: 'Не оплачен',
}

function minutesSince(v: string | null) {
  return v ? Math.floor((Date.now() - new Date(v).getTime()) / 60000) : 0
}

/** Заказы всех сетей; stale — оплачены, но не приняты вовремя. */
export function Orders({ stale = false }: { stale?: boolean }) {
  const [status, setStatus] = useState<string>()
  const [openId, setOpenId] = useState<string | null>(null)
  const { data, isLoading } = useList<Order>('/admin/orders', { status: stale ? undefined : status, stale: stale || undefined, limit: 200 })
  return (
    <>
      <PageTitle title={stale ? 'Заказы, не принятые вовремя' : 'Заказы'}>
        {!stale && (
          <Select
            placeholder="Статус"
            allowClear
            value={status}
            onChange={setStatus}
            style={{ width: 180 }}
            options={statuses.map((s) => ({ value: s, label: statusTitles[s] }))}
          />
        )}
      </PageTitle>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Order>
          rowKey="id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          onRow={(o) => ({ onClick: () => setOpenId(o.id), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number' },
            { title: 'Создан', dataIndex: 'created_at', render: dateTime },
            { title: 'Магазин', dataIndex: 'store_name' },
            { title: 'Покупатель', dataIndex: 'customer_phone' },
            { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v) => money(v) },
            { title: 'Оплата', dataIndex: 'payment_provider', render: (p, o) => <>{p === 'payme' ? 'Payme' : 'Click'} {o.payment_status && <StatusTag status={o.payment_status} />}</> },
            {
              title: 'Статус',
              dataIndex: 'status',
              render: (s, o) => (
                <>
                  <StatusTag status={s} title={o.status_title} />
                  {s === 'paid' && <Tag color="red">{minutesSince(o.paid_at)} мин</Tag>}
                </>
              ),
            },
          ]}
        />
      </Card>
      <OrderDrawer id={openId} onClose={() => setOpenId(null)} />
    </>
  )
}

function OrderDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const { data: o } = useItem<Order>(id ? `/admin/orders/${id}` : null)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [reason, setReason] = useState('')
  const cancel = useAction((v: { id: string; reason: string }) => api.post(`/admin/orders/${v.id}/cancel`, { reason: v.reason }), {
    success: 'Заказ отменён; оплата ушла в очередь возвратов',
  })
  const cancellable = o && ['awaiting_payment', 'paid', 'accepted', 'picking'].includes(o.status)
  return (
    <Drawer open={id !== null} onClose={onClose} width={640} title={o ? `Заказ №${o.number}` : 'Заказ'}>
      {o && (
        <Space direction="vertical" style={{ width: '100%' }} size="large">
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label="Статус">
              <StatusTag status={o.status} title={o.status_title} />
            </Descriptions.Item>
            <Descriptions.Item label="Магазин">{o.store_name}</Descriptions.Item>
            <Descriptions.Item label="Покупатель">{o.customer_phone}</Descriptions.Item>
            <Descriptions.Item label="Адрес">
              {o.address}
              {o.apartment && `, кв. ${o.apartment}`}
              {o.entrance && `, подъезд ${o.entrance}`}
              {o.floor && `, этаж ${o.floor}`}
              {o.address_comment && <div>{o.address_comment}</div>}
            </Descriptions.Item>
            {o.comment && <Descriptions.Item label="Комментарий">{o.comment}</Descriptions.Item>}
            <Descriptions.Item label="Товары">{money(o.subtotal)}</Descriptions.Item>
            <Descriptions.Item label="Доставка">{money(o.delivery_fee)}</Descriptions.Item>
            <Descriptions.Item label="Итого">
              <b>{money(o.total)} сум</b> · {o.payment_provider === 'payme' ? 'Payme' : 'Click'}{' '}
              {o.payment_status && <StatusTag status={o.payment_status} />}
            </Descriptions.Item>
            {o.cancel_reason && <Descriptions.Item label="Причина отмены">{o.cancel_reason}</Descriptions.Item>}
          </Descriptions>
          <Table<OrderItem>
            rowKey="line"
            size="small"
            pagination={false}
            dataSource={o.items}
            columns={[
              {
                title: 'Товар',
                dataIndex: 'product_name',
                render: (n, i) => (
                  <>
                    {n} {i.from_other_warehouse && <Tag>с другого склада</Tag>}
                  </>
                ),
              },
              { title: 'Кол-во', dataIndex: 'qty', render: (v, i) => qty(v, i.unit_short) },
              { title: 'Цена', dataIndex: 'price', align: 'right', render: (v) => money(v) },
              { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v) => money(v) },
            ]}
          />
          <div>
            <Typography.Title level={5}>История</Typography.Title>
            <Timeline
              items={(o.history ?? []).map((h) => ({
                children: (
                  <>
                    <b>{statusTitles[h.status] ?? h.status}</b> · {dateTime(h.created_at)}
                    <br />
                    <Typography.Text type="secondary">
                      {h.actor}
                      {h.note && ` — ${h.note}`}
                    </Typography.Text>
                  </>
                ),
              }))}
            />
          </div>
          {cancellable && (
            <Button danger onClick={() => setCancelOpen(true)}>
              Отменить заказ
            </Button>
          )}
        </Space>
      )}
      <Modal
        open={cancelOpen}
        title="Отменить заказ"
        okText="Отменить заказ"
        okButtonProps={{ danger: true, disabled: !reason.trim() }}
        onCancel={() => setCancelOpen(false)}
        onOk={() => cancel.mutate({ id: o!.id, reason }, { onSuccess: () => (setCancelOpen(false), setReason('')) })}
      >
        <Typography.Paragraph>Резерв товара снимется, оплаченные деньги попадут в очередь возвратов.</Typography.Paragraph>
        <Input.TextArea rows={3} placeholder="Причина" value={reason} onChange={(e) => setReason(e.target.value)} />
      </Modal>
    </Drawer>
  )
}

interface Payment {
  id: string
  order_id: string
  order_number: number
  network_name: string
  provider: string
  amount: string
  status: string
  external_id: string | null
  paid_at: string | null
  refunded_at: string | null
  created_at: string
}

/** Платежи; очередь возвратов — status=refund_pending. */
export function Payments() {
  const [status, setStatus] = useState<string | undefined>('refund_pending')
  const { data, isLoading } = useList<Payment>('/admin/payments', { status, limit: 200 })
  const refunded = useAction((id: string) => api.post(`/admin/payments/${id}/refunded`), { success: 'Возврат отмечен' })
  return (
    <>
      <PageTitle title="Платежи и возвраты">
        <Select
          value={status}
          allowClear
          placeholder="Все платежи"
          onChange={setStatus}
          style={{ width: 200 }}
          options={[
            { value: 'refund_pending', label: 'Ждут возврата' },
            { value: 'paid', label: 'Оплачены' },
            { value: 'refunded', label: 'Возвращены' },
            { value: 'created', label: 'Начаты' },
            { value: 'cancelled', label: 'Отменены' },
          ]}
        />
      </PageTitle>
      {status === 'refund_pending' && (
        <Typography.Paragraph type="secondary">
          Верните деньги в кабинете платёжной системы. Payme сообщит о возврате сам; для Click после возврата нажмите «Возвращено».
        </Typography.Paragraph>
      )}
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Payment>
          rowKey="id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          columns={[
            { title: 'Создан', dataIndex: 'created_at', render: dateTime },
            { title: 'Заказ', dataIndex: 'order_number', render: (n) => `№${n}` },
            { title: 'Сеть', dataIndex: 'network_name' },
            { title: 'Система', dataIndex: 'provider', render: (p) => (p === 'payme' ? 'Payme' : 'Click') },
            { title: 'ID в системе', dataIndex: 'external_id' },
            { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v) => money(v) },
            { title: 'Статус', dataIndex: 'status', render: (s) => <StatusTag status={s} /> },
            { title: 'Оплачен', dataIndex: 'paid_at', render: dateTime },
            {
              key: 'act',
              render: (_, p) =>
                p.status === 'refund_pending' && (
                  <Popconfirm title="Деньги возвращены покупателю в кабинете платёжной системы?" onConfirm={() => refunded.mutate(p.id)}>
                    <Button size="small" type="primary">
                      Возвращено
                    </Button>
                  </Popconfirm>
                ),
            },
          ]}
        />
      </Card>
    </>
  )
}
