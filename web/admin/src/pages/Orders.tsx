import { useState } from 'react'
import {
  Alert,
  Button,
  Card,
  DatePicker,
  Descriptions,
  Drawer,
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
  Spin,
  Table,
  Tag,
  Timeline,
  Typography,
} from 'antd'
import dayjs from 'dayjs'
import { LoadError, PageTitle, StatusTag, api, dateTime, errorText, money, qty, useAction, useItem, useList, usePaged } from '@sm/shared'
import { SearchSelect } from '../components'
import { useInterval, useUrlState } from '../hooks'

interface OrderItem {
  line: number
  product_name: string
  unit_short: string
  qty: string
  price: string
  total: string
  from_other_warehouse: boolean
  old_price: string | null
}

interface Order {
  id: string
  number: number
  network_id: string
  store_name: string
  status: string
  status_title: string
  subtotal: string
  discount: string
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
  delivery_from: string | null
  delivery_to: string | null
  courier_name: string | null
  eta_at: string | null
  payment_deadline?: string
  accept_overdue?: boolean
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

// cash — ВРЕМЕННО: наличные курьеру, пока Payme и Click не подключены.
const providerTitle = (p: string) => (p === 'payme' ? 'Payme' : p === 'click' ? 'Click' : p === 'cash' ? 'Наличные курьеру' : p)

function minutesSince(v: string | null) {
  return v ? Math.floor((Date.now() - new Date(v).getTime()) / 60000) : 0
}

/** Окно доставки: «12.05 14:00–15:00» или «как можно скорее». */
function deliveryWindow(from: string | null, to: string | null) {
  if (!from || !to) return 'Как можно скорее'
  return `${dayjs(from).format('DD.MM HH:mm')}–${dayjs(to).format('HH:mm')}`
}

/** Заказы всех сетей; stale — оплачены, но не приняты вовремя. */
export function Orders({ stale = false }: { stale?: boolean }) {
  const [status, setStatus] = useUrlState('status')
  const [q, setQ] = useUrlState('q')
  const [network, setNetwork] = useUrlState('network_id')
  const [store, setStore] = useUrlState('store_id')
  const [provider, setProvider] = useUrlState('payment_provider')
  const [from, setFrom] = useUrlState('from')
  const [to, setTo] = useUrlState('to')
  const [search, setSearch] = useState(q ?? '')
  const [openId, setOpenId] = useState<string | null>(null)

  const networkItem = useItem<{ name: string }>(network ? `/admin/networks/${network}` : null)
  const stores = useList<{ id: string; name: string }>(network ? `/admin/networks/${network}/stores` : null)

  const list = usePaged<Order>('/admin/orders', {
    status: stale ? undefined : status,
    stale: stale || undefined,
    q,
    network_id: network,
    store_id: store,
    payment_provider: provider,
    from,
    to,
  })
  // Очередь «не приняты вовремя» обновляется сама.
  useInterval(() => list.refetch(), 30_000, stale)

  const range = from && to ? ([dayjs(from), dayjs(to).subtract(1, 'day')] as [dayjs.Dayjs, dayjs.Dayjs]) : null
  return (
    <>
      <PageTitle title={stale ? 'Заказы, не принятые вовремя' : 'Заказы'}>
        <Input.Search
          placeholder="Номер заказа или телефон"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onSearch={(v) => setQ(v.trim())}
          style={{ width: 240 }}
        />
        {!stale && (
          <Select
            placeholder="Статус"
            allowClear
            value={status}
            onChange={setStatus}
            style={{ width: 160 }}
            options={statuses.map((s) => ({ value: s, label: statusTitles[s] }))}
          />
        )}
        <SearchSelect
          path="/admin/networks"
          placeholder="Сеть"
          allowClear
          value={network}
          known={{ id: network, label: networkItem.data?.name }}
          onChange={(v) => {
            setNetwork(v as string | undefined)
            setStore(undefined)
          }}
          style={{ width: 200 }}
        />
        {network && (
          <Select
            placeholder="Магазин"
            allowClear
            value={store}
            onChange={setStore}
            loading={stores.isLoading}
            style={{ width: 180 }}
            options={(stores.data ?? []).map((s) => ({ value: s.id, label: s.name }))}
          />
        )}
        <Select
          placeholder="Оплата"
          allowClear
          value={provider}
          onChange={setProvider}
          style={{ width: 120 }}
          options={[
            { value: 'payme', label: 'Payme' },
            { value: 'click', label: 'Click' },
            { value: 'cash', label: 'Наличные курьеру' },
          ]}
        />
        <DatePicker.RangePicker
          format="DD.MM.YYYY"
          value={range}
          onChange={(r) => {
            setFrom(r?.[0] ? r[0].format('YYYY-MM-DD') : undefined)
            setTo(r?.[1] ? r[1].add(1, 'day').format('YYYY-MM-DD') : undefined)
          }}
        />
      </PageTitle>
      {stale && (
        <Typography.Paragraph type="secondary">Список обновляется каждые 30 секунд.</Typography.Paragraph>
      )}
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Order>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          scroll={{ x: true }}
          onRow={(o) => ({ onClick: () => setOpenId(o.id), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number' },
            { title: 'Создан', dataIndex: 'created_at', render: dateTime },
            { title: 'Магазин', dataIndex: 'store_name' },
            { title: 'Покупатель', dataIndex: 'customer_phone' },
            { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v) => money(v) },
            {
              title: 'Оплата',
              dataIndex: 'payment_provider',
              render: (p, o) => (
                <>
                  {providerTitle(p)} {o.payment_status && <StatusTag status={o.payment_status} />}
                </>
              ),
            },
            {
              title: 'Статус',
              dataIndex: 'status',
              render: (s, o) => (
                <>
                  <StatusTag status={s} title={o.status_title} />
                  {s === 'paid' && (
                    <Tag color={o.accept_overdue ? 'red' : 'default'} title="Сколько минут назад оплачен">
                      {minutesSince(o.paid_at)} мин
                    </Tag>
                  )}
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
  const { data: o, isLoading, error, refetch } = useItem<Order>(id ? `/admin/orders/${id}` : null)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [reason, setReason] = useState('')
  const cancel = useAction((v: { id: string; reason: string }) => api.post(`/admin/orders/${v.id}/cancel`, { reason: v.reason }), {
    success: 'Заказ отменён; оплата ушла в очередь возвратов',
  })
  const closeCancel = () => {
    setCancelOpen(false)
    setReason('')
  }
  const cancellable = o && ['awaiting_payment', 'paid', 'accepted', 'picking'].includes(o.status)
  return (
    <Drawer open={id !== null} onClose={onClose} width={640} title={o ? `Заказ №${o.number}` : 'Заказ'}>
      {isLoading && <Spin style={{ display: 'block', margin: '48px auto' }} />}
      {error && (
        <Alert
          type="error"
          showIcon
          message="Не удалось загрузить заказ"
          description={errorText(error)}
          action={<Button size="small" onClick={() => refetch()}>Повторить</Button>}
        />
      )}
      {o && (
        <Space direction="vertical" style={{ width: '100%' }} size="large">
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label="Статус">
              <StatusTag status={o.status} title={o.status_title} />
              {o.accept_overdue && <Tag color="red">не принят вовремя</Tag>}
            </Descriptions.Item>
            <Descriptions.Item label="Создан">{dateTime(o.created_at)}</Descriptions.Item>
            <Descriptions.Item label="Магазин">{o.store_name}</Descriptions.Item>
            <Descriptions.Item label="Покупатель">{o.customer_phone}</Descriptions.Item>
            <Descriptions.Item label="Адрес">
              {o.address}
              {o.apartment && `, кв. ${o.apartment}`}
              {o.entrance && `, подъезд ${o.entrance}`}
              {o.floor && `, этаж ${o.floor}`}
              {o.address_comment && <div>{o.address_comment}</div>}
            </Descriptions.Item>
            <Descriptions.Item label="Доставка ко времени">{deliveryWindow(o.delivery_from, o.delivery_to)}</Descriptions.Item>
            {(o.courier_name || o.eta_at) && (
              <Descriptions.Item label="Курьер">
                {o.courier_name ?? '—'}
                {o.eta_at && <Typography.Text type="secondary"> · прибудет к {dayjs(o.eta_at).format('HH:mm')}</Typography.Text>}
              </Descriptions.Item>
            )}
            {o.comment && <Descriptions.Item label="Комментарий">{o.comment}</Descriptions.Item>}
            <Descriptions.Item label="Товары">{money(o.subtotal)}</Descriptions.Item>
            {Number(o.discount) > 0 && <Descriptions.Item label="Скидка">−{money(o.discount)}</Descriptions.Item>}
            <Descriptions.Item label="Доставка">{money(o.delivery_fee)}</Descriptions.Item>
            <Descriptions.Item label="Итого">
              <b>{money(o.total)} сум</b> · {providerTitle(o.payment_provider)} {o.payment_status && <StatusTag status={o.payment_status} />}
            </Descriptions.Item>
            {o.payment_deadline && <Descriptions.Item label="Оплатить до">{dateTime(o.payment_deadline)}</Descriptions.Item>}
            {o.paid_at && <Descriptions.Item label="Оплачен">{dateTime(o.paid_at)}</Descriptions.Item>}
            {o.accepted_at && <Descriptions.Item label="Принят">{dateTime(o.accepted_at)}</Descriptions.Item>}
            {o.delivered_at && <Descriptions.Item label="Доставлен">{dateTime(o.delivered_at)}</Descriptions.Item>}
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
              {
                title: 'Цена',
                dataIndex: 'price',
                align: 'right',
                render: (v, i) => (
                  <>
                    {i.old_price && (
                      <Typography.Text delete type="secondary">
                        {money(i.old_price)}
                      </Typography.Text>
                    )}{' '}
                    {money(v)}
                  </>
                ),
              },
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
        cancelText="Закрыть"
        okButtonProps={{ danger: true, disabled: !reason.trim() }}
        confirmLoading={cancel.isPending}
        onCancel={closeCancel}
        onOk={() => cancel.mutate({ id: o!.id, reason }, { onSuccess: closeCancel })}
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
  const [status, setStatus] = useUrlState('status', 'refund_pending')
  const list = usePaged<Payment>('/admin/payments', { status })
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
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Payment>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          scroll={{ x: true }}
          columns={[
            { title: 'Создан', dataIndex: 'created_at', render: dateTime },
            { title: 'Заказ', dataIndex: 'order_number', render: (n) => `№${n}` },
            { title: 'Сеть', dataIndex: 'network_name' },
            { title: 'Система', dataIndex: 'provider', render: providerTitle },
            { title: 'ID в системе', dataIndex: 'external_id' },
            { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v) => money(v) },
            { title: 'Статус', dataIndex: 'status', render: (s) => <StatusTag status={s} /> },
            { title: 'Оплачен', dataIndex: 'paid_at', render: dateTime },
            {
              key: 'act',
              render: (_, p) =>
                p.status === 'refund_pending' && (
                  <Popconfirm
                    title="Деньги возвращены покупателю в кабинете платёжной системы?"
                    onConfirm={() => refunded.mutateAsync(p.id).catch(() => undefined)}
                  >
                    <Button size="small" type="primary" loading={refunded.isPending && refunded.variables === p.id}>
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
