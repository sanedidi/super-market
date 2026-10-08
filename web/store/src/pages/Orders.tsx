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
  Popconfirm,
  Segmented,
  Select,
  Space,
  Table,
  Tag,
  Timeline,
  Typography,
} from 'antd'
import { PrinterOutlined, QrcodeOutlined, ReloadOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, StatusTag, api, dateTime, formatPhone, money, periodParams, qty, tr, getLang, useAction, useList, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { usePaidOrders } from '../notify'
import { NeedStore, RangeFilter, type Range } from '../ui'
import { QrCodeModal } from '../qr'
import type { Courier, Order, OrderItem, Warehouse } from '../types'

const statusFilters = [
  { value: '', label: tr('Все', 'Hammasi') },
  { value: 'paid', label: tr('Новые', 'Yangi') },
  { value: 'accepted', label: tr('Приняты', 'Qabul qilingan') },
  { value: 'picking', label: tr('Сборка', 'Yigʻilmoqda') },
  { value: 'picked', label: tr('Собраны', 'Yigʻilgan') },
  { value: 'delivering', label: tr('В пути', 'Yoʻlda') },
  { value: 'delivered', label: tr('Доставлены', 'Yetkazilgan') },
  { value: 'cancelled', label: tr('Отменены', 'Bekor qilingan') },
]

// cash — ВРЕМЕННО: наличные курьеру, пока Payme и Click не подключены.
const providers: Record<string, string> = { payme: 'Payme', click: 'Click', cash: tr('Наличные курьеру', 'Kuryerga naqd pul') }

/** Кто сменил статус: client, payment, store:<id>, admin, system. */
function actorTitle(a: string) {
  if (a.startsWith('store')) return tr('Магазин', 'Doʻkon')
  return (
    (
      {
        client: tr('Покупатель', 'Xaridor'),
        payment: tr('Платёжная система', 'Toʻlov tizimi'),
        admin: tr('Администратор', 'Administrator'),
        system: tr('Система', 'Tizim'),
      } as Record<string, string>
    )[a] ?? a
  )
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
            {tr('Онлайн-заказы', 'Onlayn buyurtmalar')}
            {newCount > 0 && <Badge count={newCount} title={tr('Новые заказы', 'Yangi buyurtmalar')} />}
          </Space>
        }
        extra={
          <Button icon={<ReloadOutlined spin={isFetching} />} onClick={() => refetch()}>
            {dataUpdatedAt ? dateTime(new Date(dataUpdatedAt).toISOString()).slice(-5) : tr('Обновить', 'Yangilash')}
          </Button>
        }
      >
        <Space wrap>
          <Segmented value={status} onChange={(v) => setStatus(String(v))} options={statusFilters} />
          <Input.Search placeholder={tr('№ заказа или телефон', 'Buyurtma № yoki telefon')} allowClear onSearch={(v) => setQ(v.trim())} style={{ width: 220 }} />
          <RangeFilter value={range} onChange={setRange} allowClear />
          <Select
            value={sort}
            onChange={setSort}
            style={{ width: 200 }}
            options={[
              { value: '', label: tr('Сначала новые', 'Avval yangilari') },
              { value: 'delivery', label: tr('По времени доставки', 'Yetkazish vaqti boʻyicha') },
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
          locale={{ emptyText: q ? tr('Ничего не найдено', 'Hech narsa topilmadi') : tr('Заказов нет', 'Buyurtmalar yoʻq') }}
          onRow={(r) => ({ onClick: () => setOpenId(r.id), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: tr('Создан', 'Yaratilgan'), dataIndex: 'created_at', render: dateTime },
            { title: tr('К времени', 'Vaqtga'), key: 'slot', render: (_, r) => <DeliveryWindow order={r} /> },
            { title: tr('Статус', 'Holat'), dataIndex: 'status', render: (s: string, r) => <StatusTag status={s} title={r.status_title || undefined} /> },
            { title: tr('Покупатель', 'Xaridor'), dataIndex: 'customer_phone', render: (v: string) => formatPhone(v) || '—' },
            { title: tr('Адрес', 'Manzil'), dataIndex: 'address', ellipsis: true },
            { title: tr('Курьер', 'Kuryer'), dataIndex: 'courier_name', render: (v: string | null) => v ?? <Typography.Text type="secondary">—</Typography.Text> },
            { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            { title: tr('Оплата', 'Toʻlov'), dataIndex: 'payment_provider', render: (v: string) => providers[v] ?? v },
            {
              title: tr('Чек', 'Chek'),
              dataIndex: 'fiscal_status',
              render: (v: string) => (v === 'registered' ? <Tag color="green">{tr('Пробит', 'Urilgan')}</Tag> : <Tag>{tr('Нет', 'Yoʻq')}</Tag>),
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
  const [handover, setHandover] = useState(false)

  const act = useAction((step: string) => api.post(`/store/orders/${id}/${step}`), { success: tr('Статус заказа обновлён', 'Buyurtma holati yangilandi') })
  const giveCrowd = useAction((code: string) => api.post(`/store/orders/${id}/crowd-handover`, { code }), { success: tr('Заказ выдан курьеру', 'Buyurtma kuryerga berildi') })
  const releaseCrowd = useAction(() => api.post(`/store/orders/${id}/crowd-release`), { success: tr('Курьер снят с заказа', 'Kuryer buyurtmadan olindi') })
  const manage = can('orders.manage')
  const s = o?.status ?? ''
  const crowd = !!o?.crowd_courier_id

  const actions = o && manage && (
    <Space wrap>
      <Button icon={<PrinterOutlined />} onClick={() => printPickingList(o, whName(o.warehouse_id))}>
        {tr('Лист сборки', 'Yigʻish varaqasi')}
      </Button>
      {s === 'paid' && (
        <Button type="primary" loading={act.isPending} onClick={() => act.mutate('accept')}>
          {tr('Принять', 'Qabul qilish')}
        </Button>
      )}
      {s === 'accepted' && (
        <Button type="primary" loading={act.isPending} onClick={() => act.mutate('start-picking')}>
          {tr('Начать сборку', 'Yigʻishni boshlash')}
        </Button>
      )}
      {(s === 'accepted' || s === 'picking') && (
        <Button type={s === 'picking' ? 'primary' : 'default'} onClick={() => setPicking(true)}>
          {tr('Собран', 'Yigʻildi')}
        </Button>
      )}
      {crowd && s === 'picked' && (
        <Button type="primary" icon={<QrcodeOutlined />} onClick={() => setHandover(true)}>
          {tr('Выдать курьеру', 'Kuryerga berish')}
        </Button>
      )}
      {crowd && s === 'picked' && (
        <Popconfirm
          title={tr('Снять курьера с заказа?', 'Kuryer buyurtmadan olinsinmi?')}
          description={tr('Заказ снова станет доступен курьерам или его можно отдать штатному курьеру', 'Buyurtma yana kuryerlarga ochiladi yoki uni shtatdagi kuryerga berish mumkin')}
          okText={tr('Снять', 'Olish')}
          onConfirm={() => releaseCrowd.mutate()}
        >
          <Button loading={releaseCrowd.isPending}>{tr('Снять курьера', 'Kuryerni olish')}</Button>
        </Popconfirm>
      )}
      {!crowd && s === 'picked' && (
        <Button type="primary" loading={act.isPending} onClick={() => act.mutate('start-delivery')}>
          {tr('В путь', 'Yoʻlga')}
        </Button>
      )}
      {!crowd && (s === 'delivering' || s === 'picked') && (
        <Button type={s === 'delivering' ? 'primary' : 'default'} loading={act.isPending} onClick={() => act.mutate('delivered')}>
          {tr('Доставлен', 'Yetkazildi')}
        </Button>
      )}
      {['picked', 'delivering', 'delivered'].includes(s) && o.fiscal_status !== 'registered' && (
        <Button onClick={() => setFiscal(true)}>{tr('Чек', 'Chek')}</Button>
      )}
      {['paid', 'accepted', 'picking'].includes(s) && (
        <Button danger onClick={() => setCancelling(true)}>
          {tr('Отменить', 'Bekor qilish')}
        </Button>
      )}
    </Space>
  )

  return (
    <Drawer
      open={!!id}
      onClose={onClose}
      width={screens.md ? 720 : '100%'}
      title={o ? tr(`Заказ № ${o.number}`, `Buyurtma № ${o.number}`) : tr('Заказ', 'Buyurtma')}
      extra={o && <StatusTag status={o.status} title={o.status_title || undefined} />}
      loading={isLoading}
    >
      {o && (
        <>
          {actions && <div style={{ marginBottom: 16 }}>{actions}</div>}
          {o.status === 'cancelled' && o.cancel_reason && (
            <Alert type="warning" showIcon message={tr(`Причина отмены: ${o.cancel_reason}`, `Bekor qilish sababi: ${o.cancel_reason}`)} style={{ marginBottom: 16 }} />
          )}
          {o.crowd_open && (
            <Alert
              type="info"
              showIcon
              message={tr('Заказ предложен курьерам по пути', 'Buyurtma yoʻlakay kuryerlarga taklif qilindi')}
              description={tr('Если никто не возьмёт его в ближайшие минуты, назначьте штатного курьера.', 'Agar yaqin daqiqalarda hech kim olmasa, shtatdagi kuryerni tayinlang.')}
              style={{ marginBottom: 16 }}
            />
          )}
          {crowd && s === 'picked' && (
            <Alert
              type="info"
              showIcon
              message={tr('Курьер по пути идёт за заказом', 'Yoʻlakay kuryer buyurtma uchun kelmoqda')}
              description={
                <>
                  {tr(
                    'Выдайте заказ, только отсканировав QR курьера или введя его код выдачи',
                    'Buyurtmani faqat kuryer QR kodini skanerlab yoki uning berish kodini kiritib bering',
                  )}
                  {o.crowd_pickup_until && (
                    <>
                      {' '}
                      · {tr(`должен забрать до ${dateTime(o.crowd_pickup_until).slice(-5)}`, `${dateTime(o.crowd_pickup_until).slice(-5)} gacha olib ketishi kerak`)}
                    </>
                  )}
                </>
              }
              style={{ marginBottom: 16 }}
            />
          )}
          <Descriptions size="small" bordered column={{ xs: 1, sm: 2, md: 2, lg: 2, xl: 2, xxl: 2 }} style={{ marginBottom: 16 }}>
            <Descriptions.Item label={tr('Покупатель', 'Xaridor')}>
              <a href={`tel:${o.customer_phone}`}>{formatPhone(o.customer_phone)}</a>
            </Descriptions.Item>
            <Descriptions.Item label={tr('Создан', 'Yaratilgan')}>{dateTime(o.created_at)}</Descriptions.Item>
            <Descriptions.Item label={tr('Доставка', 'Yetkazib berish')}>
              <DeliveryWindow order={o} />
            </Descriptions.Item>
            <Descriptions.Item label={tr('Курьер', 'Kuryer')} span="filled">
              <CourierPicker order={o} editable={manage} />
            </Descriptions.Item>
            <Descriptions.Item label={tr('Адрес', 'Manzil')} span="filled">
              {o.address}
              {o.entrance && tr(`, подъезд ${o.entrance}`, `, ${o.entrance}-podyezd`)}
              {o.floor && tr(`, этаж ${o.floor}`, `, ${o.floor}-qavat`)}
              {o.apartment && tr(`, кв. ${o.apartment}`, `, ${o.apartment}-xonadon`)}
              {o.address_comment && (
                <div>
                  <Typography.Text type="secondary">{o.address_comment}</Typography.Text>
                </div>
              )}
              <div>
                <a href={`https://yandex.ru/maps/?pt=${o.lng},${o.lat}&z=17&l=map`} target="_blank" rel="noreferrer">
                  {tr('На карте', 'Xaritada')}
                </a>
                {o.distance_m > 0 && <Typography.Text type="secondary"> · {(o.distance_m / 1000).toFixed(1)} {tr('км', 'km')}</Typography.Text>}
              </div>
            </Descriptions.Item>
            {o.comment && (
              <Descriptions.Item label={tr('Комментарий', 'Izoh')} span="filled">
                {o.comment}
              </Descriptions.Item>
            )}
            <Descriptions.Item label={tr('Оплата', 'Toʻlov')}>
              {providers[o.payment_provider] ?? o.payment_provider} {o.payment_status && <StatusTag status={o.payment_status} />}
            </Descriptions.Item>
            <Descriptions.Item label={tr('Оплачен', 'Toʻlangan')}>{dateTime(o.paid_at)}</Descriptions.Item>
            <Descriptions.Item label={tr('Чек', 'Chek')}>{o.fiscal_status === 'registered' ? <Tag color="green">{tr('Пробит', 'Urilgan')}</Tag> : <Tag>{tr('Не пробит', 'Urilmagan')}</Tag>}</Descriptions.Item>
            <Descriptions.Item label={tr('Склад', 'Ombor')}>{whName(o.warehouse_id)}</Descriptions.Item>
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
                title: tr('Товар', 'Mahsulot'),
                dataIndex: 'product_name',
                render: (v: string, r) => (
                  <>
                    {v}{' '}
                    {r.from_other_warehouse && <Tag color="orange">{tr('Со склада:', 'Ombordan:')} {whName(r.picked_warehouse_id) || tr('другой', 'boshqa')}</Tag>}
                  </>
                ),
              },
              { title: tr('Кол-во', 'Miqdor'), dataIndex: 'qty', align: 'right', render: (v: string, r) => qty(v, r.unit_short) },
              {
                title: tr('Цена', 'Narx'),
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
              { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            ]}
            summary={() => (
              <>
                <Table.Summary.Row>
                  <Table.Summary.Cell index={0} colSpan={3}>
                    {tr('Товары', 'Mahsulotlar')}
                  </Table.Summary.Cell>
                  <Table.Summary.Cell index={1} align="right">
                    {money(o.subtotal)}
                  </Table.Summary.Cell>
                </Table.Summary.Row>
                {Number(o.discount) > 0 && (
                  <Table.Summary.Row>
                    <Table.Summary.Cell index={0} colSpan={3}>
                      {tr('Скидка', 'Chegirma')}
                    </Table.Summary.Cell>
                    <Table.Summary.Cell index={1} align="right">
                      <Typography.Text type="danger">−{money(o.discount)}</Typography.Text>
                    </Table.Summary.Cell>
                  </Table.Summary.Row>
                )}
                <Table.Summary.Row>
                  <Table.Summary.Cell index={0} colSpan={3}>
                    {tr('Доставка', 'Yetkazib berish')}
                  </Table.Summary.Cell>
                  <Table.Summary.Cell index={1} align="right">
                    {money(o.delivery_fee)}
                  </Table.Summary.Cell>
                </Table.Summary.Row>
                <Table.Summary.Row>
                  <Table.Summary.Cell index={0} colSpan={3}>
                    <b>{tr('Итого', 'Jami')}</b>
                  </Table.Summary.Cell>
                  <Table.Summary.Cell index={1} align="right">
                    <b>{money(o.total)}</b>
                  </Table.Summary.Cell>
                </Table.Summary.Row>
              </>
            )}
          />
          <Typography.Title level={5}>{tr('История', 'Tarix')}</Typography.Title>
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
      <QrCodeModal
        open={handover}
        title={tr('Выдача курьеру по пути', 'Yoʻlakay kuryerga berish')}
        hint={tr('Отсканируйте QR на экране заказа у курьера или введите код выдачи из 3 символов', 'Kuryerdagi buyurtma ekranidagi QR kodni skanerlang yoki 3 belgili berish kodini kiriting')}
        placeholder={tr('Код выдачи, например 7KX', 'Berish kodi, masalan 7KX')}
        okText={tr('Выдать', 'Berish')}
        loading={giveCrowd.isPending}
        onClose={() => setHandover(false)}
        onSubmit={(code) => giveCrowd.mutate(code, { onSuccess: () => setHandover(false) })}
      />
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
    { success: tr('Заказ собран', 'Buyurtma yigʻildi') },
  )
  return (
    <Modal
      open={open}
      title={tr(`Заказ № ${order.number} собран`, `Buyurtma № ${order.number} yigʻildi`)}
      okText={tr('Собран', 'Yigʻildi')}
      onOk={() => save.mutate(undefined, { onSuccess: onClose })}
      confirmLoading={save.isPending}
      onCancel={onClose}
      width={640}
      destroyOnHidden
      afterOpenChange={(v) => v && setChosen({})}
    >
      <Typography.Paragraph type="secondary">
        {tr('Если товар взят с другого склада магазина — выберите склад в строке. Товар спишется с него.', 'Agar mahsulot doʻkonning boshqa omboridan olingan boʻlsa — qatorda omborni tanlang. Mahsulot oʻsha ombordan chiqariladi.')}
      </Typography.Paragraph>
      <Table<OrderItem>
        rowKey="line"
        size="small"
        pagination={false}
        dataSource={order.items}
        scroll={{ x: true }}
        columns={[
          { title: tr('Товар', 'Mahsulot'), dataIndex: 'product_name' },
          { title: tr('Кол-во', 'Miqdor'), dataIndex: 'qty', render: (v: string, r) => qty(v, r.unit_short) },
          {
            title: tr('Склад', 'Ombor'),
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
  const cancel = useAction((reason: string) => api.post(`/store/orders/${id}/cancel`, { reason }), { success: tr('Заказ отменён', 'Buyurtma bekor qilindi') })
  return (
    <Modal
      open={open}
      title={tr('Отменить заказ', 'Buyurtmani bekor qilish')}
      okText={tr('Отменить заказ', 'Buyurtmani bekor qilish')}
      okButtonProps={{ danger: true }}
      cancelText={tr('Назад', 'Orqaga')}
      onOk={() => form.submit()}
      confirmLoading={cancel.isPending}
      onCancel={onClose}
      destroyOnHidden
    >
      <Alert type="warning" showIcon message={tr('Покупателю вернутся деньги, резерв товара снимется.', 'Xaridorga pul qaytariladi, mahsulot zaxirasi bekor qilinadi.')} style={{ marginBottom: 16 }} />
      <Form form={form} layout="vertical" onFinish={(v) => cancel.mutate(v.reason, { onSuccess: onClose })}>
        <Form.Item name="reason" label={tr('Причина', 'Sabab')} rules={[{ required: true, whitespace: true, message: tr('Укажите причину', 'Sababni koʻrsating') }]}>
          <Input.TextArea rows={3} placeholder={tr('Нет товара, не удалось связаться…', 'Mahsulot yoʻq, bogʻlanib boʻlmadi…')} />
        </Form.Item>
      </Form>
    </Modal>
  )
}

/** Регистрация чека: номер и фискальный признак (для заказов, продаж и возвратов). */
export function FiscalModal({ path, open, onClose }: { path: string; open: boolean; onClose: () => void }) {
  const [form] = Form.useForm<{ fiscal_number: string; fiscal_sign: string }>()
  const save = useAction((v: { fiscal_number: string; fiscal_sign: string }) => api.post(path, v), { success: tr('Чек зарегистрирован', 'Chek roʻyxatdan oʻtkazildi') })
  return (
    <Modal
      open={open}
      title={tr('Чек', 'Chek')}
      okText={tr('Сохранить', 'Saqlash')}
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      destroyOnHidden
    >
      <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Form.Item name="fiscal_number" label={tr('Фискальный номер', 'Fiskal raqam')} rules={[{ required: true, whitespace: true, message: tr('Обязательное поле', 'Majburiy maydon') }]}>
          <Input />
        </Form.Item>
        <Form.Item name="fiscal_sign" label={tr('Фискальный признак', 'Fiskal belgi')} rules={[{ required: true, whitespace: true, message: tr('Обязательное поле', 'Majburiy maydon') }]}>
          <Input />
        </Form.Item>
      </Form>
    </Modal>
  )
}

/** «Сегодня, 14:00–15:00» или «Как можно скорее». */
export function DeliveryWindow({ order }: { order: Pick<Order, 'delivery_from' | 'delivery_to'> }) {
  if (!order.delivery_from || !order.delivery_to) return <Typography.Text type="secondary">{tr('Как можно скорее', 'Imkon qadar tezroq')}</Typography.Text>
  const from = new Date(order.delivery_from)
  const to = new Date(order.delivery_to)
  const hm = (d: Date) => d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Tashkent' })
  const day = (d: Date) => d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', timeZone: 'Asia/Tashkent' })
  const today = day(new Date())
  const tomorrow = day(new Date(Date.now() + 86_400_000))
  const label = day(from) === today ? tr('Сегодня', 'Bugun') : day(from) === tomorrow ? tr('Завтра', 'Ertaga') : day(from)
  return (
    <Tag color="blue">
      {label}, {hm(from)}–{hm(to)}
    </Tag>
  )
}

const vehicles: Record<Courier['vehicle'], string> = {
  foot: tr('пешком', 'piyoda'),
  bike: tr('велосипед', 'velosiped'),
  scooter: tr('скутер', 'skuter'),
  car: tr('машина', 'mashina'),
}

/** Курьер заказа: выбор из курьеров магазина (сначала на смене). */
function CourierPicker({ order, editable }: { order: Order; editable: boolean }) {
  const couriers = useList<Courier>(editable ? '/store/couriers' : null, { store_id: order.store_id })
  const assign = useAction((courier_id: string | null) => api.post(`/store/orders/${order.id}/assign-courier`, { courier_id }), {
    success: tr('Курьер назначен', 'Kuryer tayinlandi'),
    invalidate: [['/store/orders']],
  })
  if (order.crowd_courier_id)
    return (
      <Space wrap size={4}>
        {order.courier_name}
        <Tag color="purple">{tr('по пути', 'yoʻlakay')}</Tag>
        {order.crowd_courier_phone && <a href={`tel:${order.crowd_courier_phone}`}>{formatPhone(order.crowd_courier_phone)}</a>}
      </Space>
    )
  const canChange = editable && ['accepted', 'picking', 'picked', 'delivering'].includes(order.status)
  const eta =
    order.eta_at && order.status === 'delivering'
      ? tr(` · прибудет к ${dateTime(order.eta_at).slice(-5)}`, ` · ${dateTime(order.eta_at).slice(-5)} da yetib keladi`)
      : ''
  if (!canChange) return <>{order.courier_name ? order.courier_name + eta : <Typography.Text type="secondary">{tr('Не назначен', 'Tayinlanmagan')}</Typography.Text>}</>
  return (
    <Space wrap>
      <Select
        style={{ minWidth: 260 }}
        placeholder={tr('Назначить курьера', 'Kuryerni tayinlash')}
        allowClear
        loading={couriers.isLoading || assign.isPending}
        value={order.courier_id ?? undefined}
        onChange={(v) => assign.mutate((v as string | undefined) ?? null)}
        notFoundContent={tr('Нет курьеров: дайте сотруднику право «Курьер: доставка заказов»', 'Kuryerlar yoʻq: xodimga «Kuryer: buyurtmalarni yetkazish» huquqini bering')}
        options={(couriers.data ?? []).map((c) => ({
          value: c.employee_id,
          label: `${c.on_shift ? '🟢' : '⚪️'} ${c.full_name} · ${vehicles[c.vehicle]}${c.active_orders ? tr(` · заказов: ${c.active_orders}`, ` · buyurtmalar: ${c.active_orders}`) : ''}`,
        }))}
      />
      {eta && <Typography.Text type="secondary">{eta.slice(3)}</Typography.Text>}
    </Space>
  )
}

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

/** Время доставки для печати: окно или «как можно скорее». */
function windowText(o: Order) {
  if (!o.delivery_from || !o.delivery_to) return tr('Как можно скорее', 'Imkon qadar tezroq')
  const f = (v: string) => new Date(v).toLocaleString('ru-RU', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Tashkent' })
  return `${f(o.delivery_from)} – ${f(o.delivery_to).slice(-5)}`
}

/** Лист сборки заказа: печать из скрытого iframe, без всплывающих окон. */
function printPickingList(o: Order, warehouse: string) {
  const address = [
    o.address,
    o.entrance && tr(`подъезд ${o.entrance}`, `${o.entrance}-podyezd`),
    o.floor && tr(`этаж ${o.floor}`, `${o.floor}-qavat`),
    o.apartment && tr(`кв. ${o.apartment}`, `${o.apartment}-xonadon`),
  ]
    .filter(Boolean)
    .join(', ')
  const rows = (o.items ?? [])
    .map(
      (i, n) =>
        `<tr><td>${n + 1}</td><td>${esc(i.product_name)}</td><td class="r"><b>${esc(qty(i.qty, i.unit_short))}</b></td><td class="c">☐</td></tr>`,
    )
    .join('')
  const html = `<!doctype html><html lang="${getLang()}"><head><meta charset="utf-8"><title>${tr('Заказ', 'Buyurtma')} № ${o.number}</title>
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
<h1>${tr('Лист сборки — заказ', 'Yigʻish varaqasi — buyurtma')} № ${o.number}</h1>
<dl>
  <dt>${tr('Создан', 'Yaratilgan')}</dt><dd>${esc(dateTime(o.created_at))}</dd>
  <dt>${tr('Доставка', 'Yetkazib berish')}</dt><dd>${esc(windowText(o))}</dd>
  <dt>${tr('Магазин', 'Doʻkon')}</dt><dd>${esc(o.store_name)}${warehouse ? ` · ${tr('склад', 'ombor')} «${esc(warehouse)}»` : ''}</dd>
  <dt>${tr('Адрес', 'Manzil')}</dt><dd>${esc(address)}${o.address_comment ? `<br>${esc(o.address_comment)}` : ''}</dd>
  <dt>${tr('Покупатель', 'Xaridor')}</dt><dd>${esc(formatPhone(o.customer_phone))}</dd>
  <dt>${tr('Курьер', 'Kuryer')}</dt><dd>${esc(o.courier_name ?? '—')}</dd>
</dl>
<table><thead><tr><th>№</th><th>${tr('Товар', 'Mahsulot')}</th><th class="r">${tr('Кол-во', 'Miqdor')}</th><th class="c">✓</th></tr></thead><tbody>${rows}</tbody></table>
${o.comment ? `<div class="note"><b>${tr('Комментарий покупателя:', 'Xaridor izohi:')}</b> ${esc(o.comment)}</div>` : ''}
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
