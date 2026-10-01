// Онлайн-заказы: список с автообновлением и карточка заказа с действиями.
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  Alert,
  Badge,
  Button,
  Card,
  Descriptions,
  Drawer,
  Form,
  Grid,
  Input,
  Modal,
  Segmented,
  Select,
  Space,
  Table,
  Tag,
  Timeline,
  Typography,
} from 'antd'
import { PrinterOutlined, ReloadOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, StatusTag, api, dateTime, money, periodParams, qty, useAction, useList, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { usePaidOrders } from '../notify'
import { NeedStore, RangeFilter, type Range } from '../ui'
import type { Courier, Order, OrderItem, Warehouse } from '../types'

const statusFilters = [
  { value: '', label: 'Все' },
  { value: 'paid', label: 'Новые' },
  { value: 'accepted', label: 'Приняты' },
  { value: 'picking', label: 'Сборка' },
  { value: 'picked', label: 'Собраны' },
  { value: 'delivering', label: 'В пути' },
  { value: 'delivered', label: 'Доставлены' },
  { value: 'cancelled', label: 'Отменены' },
]

// cash — ВРЕМЕННО: наличные курьеру, пока Payme и Click не подключены.
const providers: Record<string, string> = { payme: 'Payme', click: 'Click', cash: 'Наличные курьеру' }

/** Кто сменил статус: client, payment, store:<id>, admin, system. */
function actorTitle(a: string) {
  if (a.startsWith('store')) return 'Магазин'
  return ({ client: 'Покупатель', payment: 'Платёжная система', admin: 'Администратор', system: 'Система' } as Record<string, string>)[a] ?? a
}

export function OrdersPage() {
  const { storeId } = useStore()
  const [status, setStatus] = useState('paid')
  const [openId, setOpenId] = useState<string | null>(null)
  const [sort, setSort] = useState<'' | 'delivery'>('')
  const [q, setQ] = useState('')
  const [range, setRange] = useState<Range | null>(null)
  const list = usePaged<Order>(storeId ? '/store/orders' : null, {
    store_id: storeId,
    status,
    sort: sort || undefined,
    q: q || undefined,
    ...periodParams(range),
  })
  const { refetch, isFetching, dataUpdatedAt } = list
  // Автообновление текущей страницы.
  useEffect(() => {
    const t = setInterval(() => void refetch(), 15_000)
    return () => clearInterval(t)
  }, [refetch])
  const fresh = usePaidOrders()
  const newCount = fresh.data?.length ?? 0

  return (
    <NeedStore>
      <PageTitle
        title={
          <Space>
            Онлайн-заказы
            {newCount > 0 && <Badge count={newCount} title="Новые заказы" />}
          </Space>
        }
        extra={
          <Button icon={<ReloadOutlined spin={isFetching} />} onClick={() => refetch()}>
            {dataUpdatedAt ? dateTime(new Date(dataUpdatedAt).toISOString()).slice(-5) : 'Обновить'}
          </Button>
        }
      >
        <Space wrap>
          <Segmented value={status} onChange={(v) => setStatus(String(v))} options={statusFilters} />
          <Input.Search placeholder="№ заказа или телефон" allowClear onSearch={(v) => setQ(v.trim())} style={{ width: 220 }} />
          <RangeFilter value={range} onChange={setRange} allowClear />
          <Select
            value={sort}
            onChange={setSort}
            style={{ width: 200 }}
            options={[
              { value: '', label: 'Сначала новые' },
              { value: 'delivery', label: 'По времени доставки' },
            ]}
          />
        </Space>
      </PageTitle>
      <LoadError error={list.error} retry={() => refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Order>
          rowKey="id"
          loading={list.isLoading}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          locale={{ emptyText: q ? 'Ничего не найдено' : 'Заказов нет' }}
          onRow={(r) => ({ onClick: () => setOpenId(r.id), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: 'Создан', dataIndex: 'created_at', render: dateTime },
            { title: 'К времени', key: 'slot', render: (_, r) => <DeliveryWindow order={r} /> },
            { title: 'Статус', dataIndex: 'status', render: (s: string, r) => <StatusTag status={s} title={r.status_title || undefined} /> },
            { title: 'Покупатель', dataIndex: 'customer_phone' },
            { title: 'Адрес', dataIndex: 'address', ellipsis: true },
            { title: 'Курьер', dataIndex: 'courier_name', render: (v: string | null) => v ?? <Typography.Text type="secondary">—</Typography.Text> },
            { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            { title: 'Оплата', dataIndex: 'payment_provider', render: (v: string) => providers[v] ?? v },
            {
              title: 'Чек',
              dataIndex: 'fiscal_status',
              render: (v: string) => (v === 'registered' ? <Tag color="green">Пробит</Tag> : <Tag>Нет</Tag>),
            },
          ]}
        />
      </Card>
      <OrderDrawer id={openId} onClose={() => setOpenId(null)} />
    </NeedStore>
  )
}

function OrderDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const screens = Grid.useBreakpoint()
  const { can } = useStore()
  const { data: o, isLoading } = useQuery({
    queryKey: ['/store/orders', id],
    queryFn: () => api.get<Order>(`/store/orders/${id}`),
    enabled: !!id,
    refetchInterval: 15_000,
  })
  const warehouses = useList<Warehouse>(o ? '/store/warehouses' : null, { store_id: o?.store_id })
  const whName = (wid: string | null) => (warehouses.data ?? []).find((w) => w.id === wid)?.name ?? ''
  const [picking, setPicking] = useState(false)
  const [cancelling, setCancelling] = useState(false)
  const [fiscal, setFiscal] = useState(false)

  const act = useAction((step: string) => api.post(`/store/orders/${id}/${step}`), { success: 'Статус заказа обновлён' })
  const manage = can('orders.manage')
  const s = o?.status ?? ''

  const actions = o && manage && (
    <Space wrap>
      <Button icon={<PrinterOutlined />} onClick={() => printPickingList(o, whName(o.warehouse_id))}>
        Лист сборки
      </Button>
      {s === 'paid' && (
        <Button type="primary" loading={act.isPending} onClick={() => act.mutate('accept')}>
          Принять
        </Button>
      )}
      {s === 'accepted' && (
        <Button type="primary" loading={act.isPending} onClick={() => act.mutate('start-picking')}>
          Начать сборку
        </Button>
      )}
      {(s === 'accepted' || s === 'picking') && (
        <Button type={s === 'picking' ? 'primary' : 'default'} onClick={() => setPicking(true)}>
          Собран
        </Button>
      )}
      {s === 'picked' && (
        <Button type="primary" loading={act.isPending} onClick={() => act.mutate('start-delivery')}>
          В путь
        </Button>
      )}
      {(s === 'delivering' || s === 'picked') && (
        <Button type={s === 'delivering' ? 'primary' : 'default'} loading={act.isPending} onClick={() => act.mutate('delivered')}>
          Доставлен
        </Button>
      )}
      {['picked', 'delivering', 'delivered'].includes(s) && o.fiscal_status !== 'registered' && (
        <Button onClick={() => setFiscal(true)}>Чек</Button>
      )}
      {['paid', 'accepted', 'picking'].includes(s) && (
        <Button danger onClick={() => setCancelling(true)}>
          Отменить
        </Button>
      )}
    </Space>
  )

  return (
    <Drawer
      open={!!id}
      onClose={onClose}
      width={screens.md ? 720 : '100%'}
      title={o ? `Заказ № ${o.number}` : 'Заказ'}
      extra={o && <StatusTag status={o.status} title={o.status_title || undefined} />}
      loading={isLoading}
    >
      {o && (
        <>
          {actions && <div style={{ marginBottom: 16 }}>{actions}</div>}
          {o.status === 'cancelled' && o.cancel_reason && (
            <Alert type="warning" showIcon message={`Причина отмены: ${o.cancel_reason}`} style={{ marginBottom: 16 }} />
          )}
          <Descriptions size="small" bordered column={{ xs: 1, sm: 2, md: 2, lg: 2, xl: 2, xxl: 2 }} style={{ marginBottom: 16 }}>
            <Descriptions.Item label="Покупатель">
              <a href={`tel:${o.customer_phone}`}>{o.customer_phone}</a>
            </Descriptions.Item>
            <Descriptions.Item label="Создан">{dateTime(o.created_at)}</Descriptions.Item>
            <Descriptions.Item label="Доставка">
              <DeliveryWindow order={o} />
            </Descriptions.Item>
            <Descriptions.Item label="Курьер" span="filled">
              <CourierPicker order={o} editable={manage} />
            </Descriptions.Item>
            <Descriptions.Item label="Адрес" span="filled">
              {o.address}
              {o.entrance && `, подъезд ${o.entrance}`}
              {o.floor && `, этаж ${o.floor}`}
              {o.apartment && `, кв. ${o.apartment}`}
              {o.address_comment && (
                <div>
                  <Typography.Text type="secondary">{o.address_comment}</Typography.Text>
                </div>
              )}
              <div>
                <a href={`https://yandex.ru/maps/?pt=${o.lng},${o.lat}&z=17&l=map`} target="_blank" rel="noreferrer">
                  На карте
                </a>
                {o.distance_m > 0 && <Typography.Text type="secondary"> · {(o.distance_m / 1000).toFixed(1)} км</Typography.Text>}
              </div>
            </Descriptions.Item>
            {o.comment && (
              <Descriptions.Item label="Комментарий" span="filled">
                {o.comment}
              </Descriptions.Item>
            )}
            <Descriptions.Item label="Оплата">
              {providers[o.payment_provider] ?? o.payment_provider} {o.payment_status && <StatusTag status={o.payment_status} />}
            </Descriptions.Item>
            <Descriptions.Item label="Оплачен">{dateTime(o.paid_at)}</Descriptions.Item>
            <Descriptions.Item label="Чек">{o.fiscal_status === 'registered' ? <Tag color="green">Пробит</Tag> : <Tag>Не пробит</Tag>}</Descriptions.Item>
            <Descriptions.Item label="Склад">{whName(o.warehouse_id)}</Descriptions.Item>
          </Descriptions>
          <Table<OrderItem>
            rowKey="line"
            size="small"
            dataSource={o.items}
            pagination={false}
            scroll={{ x: true }}
            style={{ marginBottom: 16 }}
            columns={[
              {
                title: 'Товар',
                dataIndex: 'product_name',
                render: (v: string, r) => (
                  <>
                    {v}{' '}
                    {r.from_other_warehouse && <Tag color="orange">Со склада: {whName(r.picked_warehouse_id) || 'другой'}</Tag>}
                  </>
                ),
              },
              { title: 'Кол-во', dataIndex: 'qty', align: 'right', render: (v: string, r) => qty(v, r.unit_short) },
              {
                title: 'Цена',
                dataIndex: 'price',
                align: 'right',
                render: (v: string, r) =>
                  r.old_price ? (
                    <Space direction="vertical" size={0} style={{ alignItems: 'flex-end' }}>
                      <Typography.Text delete type="secondary" style={{ fontSize: 12 }}>
                        {money(r.old_price)}
                      </Typography.Text>
                      <Typography.Text type="danger">{money(v)}</Typography.Text>
                    </Space>
                  ) : (
                    money(v)
                  ),
              },
              { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            ]}
            summary={() => (
              <>
                <Table.Summary.Row>
                  <Table.Summary.Cell index={0} colSpan={3}>
                    Товары
                  </Table.Summary.Cell>
                  <Table.Summary.Cell index={1} align="right">
                    {money(o.subtotal)}
                  </Table.Summary.Cell>
                </Table.Summary.Row>
                {Number(o.discount) > 0 && (
                  <Table.Summary.Row>
                    <Table.Summary.Cell index={0} colSpan={3}>
                      Скидка
                    </Table.Summary.Cell>
                    <Table.Summary.Cell index={1} align="right">
                      <Typography.Text type="danger">−{money(o.discount)}</Typography.Text>
                    </Table.Summary.Cell>
                  </Table.Summary.Row>
                )}
                <Table.Summary.Row>
                  <Table.Summary.Cell index={0} colSpan={3}>
                    Доставка
                  </Table.Summary.Cell>
                  <Table.Summary.Cell index={1} align="right">
                    {money(o.delivery_fee)}
                  </Table.Summary.Cell>
                </Table.Summary.Row>
                <Table.Summary.Row>
                  <Table.Summary.Cell index={0} colSpan={3}>
                    <b>Итого</b>
                  </Table.Summary.Cell>
                  <Table.Summary.Cell index={1} align="right">
                    <b>{money(o.total)}</b>
                  </Table.Summary.Cell>
                </Table.Summary.Row>
              </>
            )}
          />
          <Typography.Title level={5}>История</Typography.Title>
          <Timeline
            items={(o.history ?? []).map((h) => ({
              children: (
                <>
                  <StatusTag status={h.status} /> {dateTime(h.created_at)}
                  <div>
                    <Typography.Text type="secondary">
                      {actorTitle(h.actor)}
                      {h.note && ` — ${h.note}`}
                    </Typography.Text>
                  </div>
                </>
              ),
            }))}
          />
          <PickedModal order={o} warehouses={(warehouses.data ?? []).filter((w) => w.is_active)} open={picking} onClose={() => setPicking(false)} />
          <CancelModal id={o.id} open={cancelling} onClose={() => setCancelling(false)} />
          <FiscalModal path={`/store/orders/${o.id}/fiscal`} open={fiscal} onClose={() => setFiscal(false)} />
        </>
      )}
    </Drawer>
  )
}

function PickedModal({ order, warehouses, open, onClose }: { order: Order; warehouses: Warehouse[]; open: boolean; onClose: () => void }) {
  const [chosen, setChosen] = useState<Record<number, string>>({})
  const save = useAction(
    () => {
      // Отправляем только строки, собранные не с основного склада заказа.
      const items = Object.entries(chosen)
        .filter(([, wid]) => wid && wid !== order.warehouse_id)
        .map(([line, warehouse_id]) => ({ line: Number(line), warehouse_id }))
      return api.post(`/store/orders/${order.id}/picked`, { items })
    },
    { success: 'Заказ собран' },
  )
  return (
    <Modal
      open={open}
      title={`Заказ № ${order.number} собран`}
      okText="Собран"
      onOk={() => save.mutate(undefined, { onSuccess: onClose })}
      confirmLoading={save.isPending}
      onCancel={onClose}
      width={640}
      destroyOnHidden
      afterOpenChange={(v) => v && setChosen({})}
    >
      <Typography.Paragraph type="secondary">
        Если товар взят с другого склада магазина — выберите склад в строке. Товар спишется с него.
      </Typography.Paragraph>
      <Table<OrderItem>
        rowKey="line"
        size="small"
        pagination={false}
        dataSource={order.items}
        scroll={{ x: true }}
        columns={[
          { title: 'Товар', dataIndex: 'product_name' },
          { title: 'Кол-во', dataIndex: 'qty', render: (v: string, r) => qty(v, r.unit_short) },
          {
            title: 'Склад',
            key: 'wh',
            render: (_, r) => (
              <Select
                style={{ minWidth: 180 }}
                value={chosen[r.line] ?? order.warehouse_id}
                onChange={(v: string) => setChosen((c) => ({ ...c, [r.line]: v }))}
                options={warehouses.map((w) => ({ value: w.id, label: w.name }))}
              />
            ),
          },
        ]}
      />
    </Modal>
  )
}

function CancelModal({ id, open, onClose }: { id: string; open: boolean; onClose: () => void }) {
  const [form] = Form.useForm<{ reason: string }>()
  const cancel = useAction((reason: string) => api.post(`/store/orders/${id}/cancel`, { reason }), { success: 'Заказ отменён' })
  return (
    <Modal
      open={open}
      title="Отменить заказ"
      okText="Отменить заказ"
      okButtonProps={{ danger: true }}
      cancelText="Назад"
      onOk={() => form.submit()}
      confirmLoading={cancel.isPending}
      onCancel={onClose}
      destroyOnHidden
    >
      <Alert type="warning" showIcon message="Покупателю вернутся деньги, резерв товара снимется." style={{ marginBottom: 16 }} />
      <Form form={form} layout="vertical" onFinish={(v) => cancel.mutate(v.reason, { onSuccess: onClose })}>
        <Form.Item name="reason" label="Причина" rules={[{ required: true, whitespace: true, message: 'Укажите причину' }]}>
          <Input.TextArea rows={3} placeholder="Нет товара, не удалось связаться…" />
        </Form.Item>
      </Form>
    </Modal>
  )
}

/** Регистрация чека: номер и фискальный признак (для заказов, продаж и возвратов). */
export function FiscalModal({ path, open, onClose }: { path: string; open: boolean; onClose: () => void }) {
  const [form] = Form.useForm<{ fiscal_number: string; fiscal_sign: string }>()
  const save = useAction((v: { fiscal_number: string; fiscal_sign: string }) => api.post(path, v), { success: 'Чек зарегистрирован' })
  return (
    <Modal
      open={open}
      title="Чек"
      okText="Сохранить"
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      destroyOnHidden
    >
      <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Form.Item name="fiscal_number" label="Фискальный номер" rules={[{ required: true, whitespace: true, message: 'Обязательное поле' }]}>
          <Input />
        </Form.Item>
        <Form.Item name="fiscal_sign" label="Фискальный признак" rules={[{ required: true, whitespace: true, message: 'Обязательное поле' }]}>
          <Input />
        </Form.Item>
      </Form>
    </Modal>
  )
}

/** «Сегодня, 14:00–15:00» или «Как можно скорее». */
export function DeliveryWindow({ order }: { order: Pick<Order, 'delivery_from' | 'delivery_to'> }) {
  if (!order.delivery_from || !order.delivery_to) return <Typography.Text type="secondary">Как можно скорее</Typography.Text>
  const from = new Date(order.delivery_from)
  const to = new Date(order.delivery_to)
  const hm = (d: Date) => d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Tashkent' })
  const day = (d: Date) => d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', timeZone: 'Asia/Tashkent' })
  const today = day(new Date())
  const tomorrow = day(new Date(Date.now() + 86_400_000))
  const label = day(from) === today ? 'Сегодня' : day(from) === tomorrow ? 'Завтра' : day(from)
  return (
    <Tag color="blue">
      {label}, {hm(from)}–{hm(to)}
    </Tag>
  )
}

const vehicles: Record<Courier['vehicle'], string> = { foot: 'пешком', bike: 'велосипед', scooter: 'скутер', car: 'машина' }

/** Курьер заказа: выбор из курьеров магазина (сначала на смене). */
function CourierPicker({ order, editable }: { order: Order; editable: boolean }) {
  const couriers = useList<Courier>(editable ? '/store/couriers' : null, { store_id: order.store_id })
  const assign = useAction((courier_id: string | null) => api.post(`/store/orders/${order.id}/assign-courier`, { courier_id }), {
    success: 'Курьер назначен',
    invalidate: [['/store/orders']],
  })
  const canChange = editable && ['accepted', 'picking', 'picked', 'delivering'].includes(order.status)
  const eta = order.eta_at && order.status === 'delivering' ? ` · прибудет к ${dateTime(order.eta_at).slice(-5)}` : ''
  if (!canChange) return <>{order.courier_name ? order.courier_name + eta : <Typography.Text type="secondary">Не назначен</Typography.Text>}</>
  return (
    <Space wrap>
      <Select
        style={{ minWidth: 260 }}
        placeholder="Назначить курьера"
        allowClear
        loading={couriers.isLoading || assign.isPending}
        value={order.courier_id ?? undefined}
        onChange={(v) => assign.mutate((v as string | undefined) ?? null)}
        notFoundContent="Нет курьеров: дайте сотруднику право «Курьер: доставка заказов»"
        options={(couriers.data ?? []).map((c) => ({
          value: c.employee_id,
          label: `${c.on_shift ? '🟢' : '⚪️'} ${c.full_name} · ${vehicles[c.vehicle]}${c.active_orders ? ` · заказов: ${c.active_orders}` : ''}`,
        }))}
      />
      {eta && <Typography.Text type="secondary">{eta.slice(3)}</Typography.Text>}
    </Space>
  )
}

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

/** Время доставки для печати: окно или «как можно скорее». */
function windowText(o: Order) {
  if (!o.delivery_from || !o.delivery_to) return 'Как можно скорее'
  const f = (v: string) => new Date(v).toLocaleString('ru-RU', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Tashkent' })
  return `${f(o.delivery_from)} – ${f(o.delivery_to).slice(-5)}`
}

/** Лист сборки заказа: печать из скрытого iframe, без всплывающих окон. */
function printPickingList(o: Order, warehouse: string) {
  const address = [
    o.address,
    o.entrance && `подъезд ${o.entrance}`,
    o.floor && `этаж ${o.floor}`,
    o.apartment && `кв. ${o.apartment}`,
  ]
    .filter(Boolean)
    .join(', ')
  const rows = (o.items ?? [])
    .map(
      (i, n) =>
        `<tr><td>${n + 1}</td><td>${esc(i.product_name)}</td><td class="r"><b>${esc(qty(i.qty, i.unit_short))}</b></td><td class="c">☐</td></tr>`,
    )
    .join('')
  const html = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Заказ № ${o.number}</title>
<style>
  body { font: 14px/1.4 -apple-system, Segoe UI, Roboto, Arial, sans-serif; margin: 24px; color: #000; }
  h1 { font-size: 22px; margin: 0 0 12px; }
  dl { display: grid; grid-template-columns: 140px 1fr; gap: 4px 12px; margin: 0 0 16px; }
  dt { color: #555; } dd { margin: 0; }
  table { width: 100%; border-collapse: collapse; }
  th, td { border: 1px solid #999; padding: 6px 8px; text-align: left; vertical-align: top; }
  th { background: #eee; } .r { text-align: right; white-space: nowrap; } .c { text-align: center; width: 40px; font-size: 18px; }
  .note { margin-top: 16px; padding: 8px; border: 1px dashed #999; }
</style></head><body>
<h1>Лист сборки — заказ № ${o.number}</h1>
<dl>
  <dt>Создан</dt><dd>${esc(dateTime(o.created_at))}</dd>
  <dt>Доставка</dt><dd>${esc(windowText(o))}</dd>
  <dt>Магазин</dt><dd>${esc(o.store_name)}${warehouse ? ` · склад «${esc(warehouse)}»` : ''}</dd>
  <dt>Адрес</dt><dd>${esc(address)}${o.address_comment ? `<br>${esc(o.address_comment)}` : ''}</dd>
  <dt>Покупатель</dt><dd>${esc(o.customer_phone)}</dd>
  <dt>Курьер</dt><dd>${esc(o.courier_name ?? '—')}</dd>
</dl>
<table><thead><tr><th>№</th><th>Товар</th><th class="r">Кол-во</th><th class="c">✓</th></tr></thead><tbody>${rows}</tbody></table>
${o.comment ? `<div class="note"><b>Комментарий покупателя:</b> ${esc(o.comment)}</div>` : ''}
</body></html>`
  const frame = document.createElement('iframe')
  frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0'
  document.body.appendChild(frame)
  const doc = frame.contentDocument
  const win = frame.contentWindow
  if (!doc || !win) {
    frame.remove()
    return
  }
  doc.open()
  doc.write(html)
  doc.close()
  setTimeout(() => {
    win.focus()
    win.print()
    setTimeout(() => frame.remove(), 1000)
  }, 100)
}
