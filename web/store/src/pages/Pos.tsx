// Касса: устройства (код подключения), ПИНы кассиров, настройки чека и смены касс.
// Дизайн — Figma «POS · касса», ряд 7 (панель).
import { useState } from 'react'
import {
  Alert,
  App,
  Button,
  Card,
  Col,
  Descriptions,
  Drawer,
  Flex,
  Form,
  Input,
  Modal,
  Popconfirm,
  Row,
  Select,
  Space,
  Table,
  Tag,
  Typography,
} from 'antd'
import { KeyOutlined, PlusOutlined, ReloadOutlined } from '@ant-design/icons'
import dayjs from 'dayjs'
import { DeleteButton, LoadError, PageTitle, api, dateTime, money, useAction, useItem, useList, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'

interface Device {
  id: string
  store_id: string
  store_name: string
  name: string
  status: 'waiting' | 'active' | 'revoked'
  activated_at: string | null
  last_seen_at: string | null
  app_version: string
  created_at: string
  activation_code?: string
  activation_expires?: string | null
  open_shift_id: string | null
}

interface PinRow {
  employee_id: string
  name: string
  role_name: string
  is_owner: boolean
  has_pin: boolean
  locked: boolean
  can_pos: boolean
  can_discount: boolean
  can_return: boolean
}

interface MethodTotal {
  payment_method_id: string
  name: string
  kind: string
  sales: string
  returns: string
}

interface ShiftReport {
  sales_count: number
  sales_total: string
  discounts: string
  returns_count: number
  returns_total: string
  by_method: MethodTotal[]
  cash_in: string
  cash_out: string
  cash_sales: string
  cash_returns: string
  expected_cash: string
  fiscal_pending: number
}

interface Shift {
  id: string
  number: number
  store_id: string
  store_name: string
  device_id: string
  device_name: string
  opened_by_name: string
  opened_at: string
  opening_cash: string
  closed_by_name: string | null
  closed_at: string | null
  expected_cash: string | null
  counted_cash: string | null
  diff: string | null
  diff_reason: string
  report?: ShiftReport
}

interface PosSettings {
  weight_prefixes: string[]
  receipt_header: string
  receipt_footer: string
}

/** Код XXXX-XXXX крупно — его вводят на кассе. */
function CodeView({ device }: { device: Device }) {
  const code = device.activation_code ?? ''
  return (
    <Flex vertical align="center" gap={12} style={{ padding: '8px 0' }}>
      <Typography.Text type="secondary">Введите этот код на кассе «{device.name}»</Typography.Text>
      <Typography.Text copyable={{ text: code }} style={{ fontSize: 40, fontWeight: 700, letterSpacing: 6, fontFamily: 'monospace' }}>
        {code.length === 8 ? code.slice(0, 4) + '-' + code.slice(4) : code}
      </Typography.Text>
      <Typography.Text type="secondary">
        Действует до {device.activation_expires ? dateTime(device.activation_expires) : 'завтра'} · подключить можно один раз
      </Typography.Text>
    </Flex>
  )
}

function lastSeen(d: Device) {
  if (!d.last_seen_at) return null
  const min = dayjs().diff(dayjs(d.last_seen_at), 'minute')
  return min < 5 ? 'на связи' : `была на связи ${dateTime(d.last_seen_at)}`
}

function DevicesCard() {
  const { storeId, can } = useStore()
  const { modal } = App.useApp()
  const list = useList<Device>('/store/pos/devices', { store_id: storeId })
  const [creating, setCreating] = useState(false)
  const [form] = Form.useForm<{ name: string }>()
  const inv = { invalidate: [['/store/pos/devices']] }
  const showCode = (d: Device) => modal.info({ title: 'Код подключения кассы', width: 520, icon: null, content: <CodeView device={d} /> })
  const create = useAction((v: { name: string }) => api.post<Device>('/store/pos/devices', { store_id: storeId, name: v.name }), inv)
  const newCode = useAction((id: string) => api.post<Device>(`/store/pos/devices/${id}/code`), inv)
  const revoke = useAction((id: string) => api.post<Device>(`/store/pos/devices/${id}/revoke`), { ...inv, success: 'Касса отключена' })
  const manage = can('stores.manage')
  const items = list.data ?? []

  return (
    <Card
      title={`Кассы · ${items.filter((d) => d.status !== 'revoked').length}`}
      extra={
        manage && (
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreating(true)}>
            Новая касса
          </Button>
        )
      }
      styles={{ body: { padding: 0 } }}
    >
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Table<Device>
        rowKey="id"
        loading={list.isLoading}
        dataSource={items}
        pagination={false}
        locale={{ emptyText: 'Касс ещё нет — нажмите «Новая касса», затем введите код на компьютере или планшете' }}
        columns={[
          {
            title: 'Касса',
            dataIndex: 'name',
            render: (v: string, d) => (
              <Space direction="vertical" size={0}>
                <b>{v}</b>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {[d.app_version && 'версия ' + d.app_version, d.activated_at && 'подключена ' + dateTime(d.activated_at)]
                    .filter(Boolean)
                    .join(' · ') || 'создана ' + dateTime(d.created_at)}
                </Typography.Text>
              </Space>
            ),
          },
          {
            title: 'Статус',
            key: 'status',
            render: (_, d) =>
              d.status === 'revoked' ? (
                <Tag>Отключена</Tag>
              ) : d.status === 'waiting' ? (
                <Tag color="orange">Ждёт подключения</Tag>
              ) : (
                <Space size={4} wrap>
                  <Tag color="green">Подключена</Tag>
                  {d.open_shift_id && <Tag color="blue">Смена открыта</Tag>}
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {lastSeen(d)}
                  </Typography.Text>
                </Space>
              ),
          },
          {
            title: '',
            key: 'actions',
            align: 'right',
            render: (_, d) =>
              manage &&
              d.status !== 'revoked' && (
                <Space>
                  <Button
                    size="small"
                    icon={<KeyOutlined />}
                    loading={newCode.isPending && newCode.variables === d.id}
                    onClick={() => newCode.mutate(d.id, { onSuccess: showCode })}
                  >
                    {d.status === 'waiting' ? 'Показать код' : 'Новый код'}
                  </Button>
                  {d.status === 'waiting' && <DeleteButton path={`/store/pos/devices/${d.id}`} name={d.name} />}
                  <Popconfirm
                    title="Отключить кассу?"
                    description="Она перестанет продавать и отправлять чеки. Неотправленные чеки останутся на ней."
                    okText="Отключить"
                    okButtonProps={{ danger: true }}
                    onConfirm={() => revoke.mutate(d.id)}
                  >
                    <Button size="small" danger>
                      Отключить
                    </Button>
                  </Popconfirm>
                </Space>
              ),
          },
        ]}
      />
      <Modal
        open={creating}
        title="Новая касса"
        okText="Создать и показать код"
        confirmLoading={create.isPending}
        onCancel={() => setCreating(false)}
        onOk={() =>
          form.validateFields().then((v) =>
            create.mutate(v, {
              onSuccess: (d) => {
                setCreating(false)
                form.resetFields()
                showCode(d)
              },
            }),
          )
        }
        destroyOnClose
      >
        <Form form={form} layout="vertical" preserve={false} initialValues={{ name: `Касса ${items.length + 1}` }}>
          <Form.Item name="name" label="Название" rules={[{ required: true, whitespace: true, message: 'Например, «Касса 1 · Windows»' }]}>
            <Input maxLength={60} autoFocus />
          </Form.Item>
          <Typography.Text type="secondary">
            Касса привязывается к выбранному сейчас магазину. После создания появится код — введите его в программе кассы.
          </Typography.Text>
        </Form>
      </Modal>
    </Card>
  )
}

function PinsCard() {
  const { storeId, can } = useStore()
  const list = useList<PinRow>(can('staff.manage') ? '/store/pos/pins' : null, { store_id: storeId })
  const [editing, setEditing] = useState<PinRow | null>(null)
  const [pin, setPin] = useState('')
  const inv = { invalidate: [['/store/pos/pins']] }
  const save = useAction((v: { id: string; pin: string }) => api.put(`/store/pos/pins/${v.id}`, { pin: v.pin }), { ...inv, success: 'ПИН сохранён' })
  const clear = useAction((id: string) => api.del(`/store/pos/pins/${id}`), { ...inv, success: 'ПИН убран' })
  if (!can('staff.manage')) return null
  const items = list.data ?? []
  const valid = /^[0-9]{4,6}$/.test(pin)

  return (
    <Card title="ПИНы кассиров" styles={{ body: { paddingTop: 8 } }}>
      <Typography.Paragraph type="secondary" style={{ fontSize: 13 }}>
        Кассир входит на кассе по ПИНу (4–6 цифр). Без ПИНа сотрудника нет в списке на кассе. Права (скидки, возвраты) — в
        «Настройки → Роли».
      </Typography.Paragraph>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Flex vertical gap={8}>
        {items.map((r) => (
          <Flex key={r.employee_id} align="center" gap={8} style={{ padding: '8px 12px', background: '#F9FAFB', borderRadius: 8 }}>
            <Flex vertical style={{ flex: 1, minWidth: 0 }}>
              <Typography.Text strong ellipsis>
                {r.name}
              </Typography.Text>
              <Space size={4} wrap>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {r.is_owner ? 'Владелец' : r.role_name}
                </Typography.Text>
                {!r.can_pos && <Tag style={{ fontSize: 11 }}>нет права продавать</Tag>}
                {r.can_pos && r.can_return && <Tag color="purple" style={{ fontSize: 11 }}>старший: возвраты</Tag>}
                {r.has_pin ? <Tag color="green" style={{ fontSize: 11 }}>ПИН задан</Tag> : <Tag style={{ fontSize: 11 }}>без ПИНа</Tag>}
                {r.locked && <Tag color="red" style={{ fontSize: 11 }}>заблокирован 5 мин</Tag>}
              </Space>
            </Flex>
            <Button
              size="small"
              type={r.has_pin ? 'default' : 'primary'}
              onClick={() => {
                setPin('')
                setEditing(r)
              }}
            >
              {r.has_pin ? 'Сменить ПИН' : 'Задать ПИН'}
            </Button>
            {r.has_pin && (
              <Popconfirm title="Убрать ПИН?" description="Сотрудник не сможет войти на кассе." onConfirm={() => clear.mutate(r.employee_id)}>
                <Button size="small" type="text" danger>
                  Убрать
                </Button>
              </Popconfirm>
            )}
          </Flex>
        ))}
        {!list.isLoading && items.length === 0 && <Typography.Text type="secondary">Сотрудников в этом магазине нет</Typography.Text>}
      </Flex>
      <Modal
        open={!!editing}
        title={`ПИН · ${editing?.name ?? ''}`}
        okText="Сохранить"
        okButtonProps={{ disabled: !valid }}
        confirmLoading={save.isPending}
        onCancel={() => setEditing(null)}
        onOk={() => editing && save.mutate({ id: editing.employee_id, pin }, { onSuccess: () => setEditing(null) })}
        destroyOnClose
      >
        <Input.Password
          autoFocus
          value={pin}
          inputMode="numeric"
          maxLength={6}
          placeholder="4–6 цифр"
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
          onPressEnter={() => editing && valid && save.mutate({ id: editing.employee_id, pin }, { onSuccess: () => setEditing(null) })}
          style={{ fontSize: 24, letterSpacing: 8 }}
        />
        <Typography.Paragraph type="secondary" style={{ marginTop: 12, marginBottom: 0 }}>
          Сообщите ПИН кассиру лично. На кассе он появится после обновления каталога — в течение минуты.
        </Typography.Paragraph>
      </Modal>
    </Card>
  )
}

function SettingsCard() {
  const { can } = useStore()
  const settings = useItem<PosSettings>('/store/pos/settings')
  const [form] = Form.useForm<{ weight_prefixes: string[]; receipt_header: string; receipt_footer: string }>()
  const save = useAction((v: PosSettings) => api.put<PosSettings>('/store/pos/settings', v), {
    invalidate: [['/store/pos/settings']],
    success: 'Настройки кассы сохранены',
  })
  if (!settings.data) return <LoadError error={settings.error} retry={() => settings.refetch()} />
  const readOnly = !can('stores.manage')
  return (
    <Card title="Чек и весы (для всей сети)">
      <Form
        form={form}
        layout="vertical"
        disabled={readOnly}
        initialValues={settings.data}
        onFinish={(v) => save.mutate({ ...v, weight_prefixes: v.weight_prefixes ?? [] })}
      >
        <Form.Item
          name="receipt_header"
          label="Шапка чека"
          extra="Название ЯТТ/ООО, ИНН, адрес — как в регистрации"
        >
          <Input.TextArea rows={3} maxLength={500} placeholder={'ЯТТ «Baraka Market»\nИНН 123456789\nг. Ташкент, Чиланзар 1'} />
        </Form.Item>
        <Form.Item name="receipt_footer" label="Текст внизу чека">
          <Input.TextArea rows={2} maxLength={500} placeholder="Спасибо за покупку!" />
        </Form.Item>
        <Form.Item
          name="weight_prefixes"
          label="Префиксы весовых этикеток"
          extra="Первые 2 цифры штрихкода, который печатают весы (обычно 22). Код товара на этикетке = короткий код (PLU)."
        >
          <Select mode="tags" tokenSeparators={[',', ' ']} options={['20', '21', '22', '23', '24', '25', '26', '27', '28', '29'].map((v) => ({ value: v }))} />
        </Form.Item>
        {!readOnly && (
          <Button type="primary" htmlType="submit" loading={save.isPending}>
            Сохранить
          </Button>
        )}
      </Form>
    </Card>
  )
}

export function PosDevicesPage() {
  return (
    <NeedStore>
      <PageTitle title="Кассы и ПИНы">
        <Typography.Text type="secondary">
          1) Создайте кассу и введите код в программе. 2) Задайте ПИН кассиру. 3) На кассе: выбрать себя → ПИН → размен.
        </Typography.Text>
      </PageTitle>
      <Row gutter={[16, 16]}>
        <Col xs={24} xl={14}>
          <Flex vertical gap={16}>
            <DevicesCard />
            <SettingsCard />
          </Flex>
        </Col>
        <Col xs={24} xl={10}>
          <PinsCard />
        </Col>
      </Row>
    </NeedStore>
  )
}

// ---------------------------------------------------------------- смены

function ShiftDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const sh = useItem<Shift>(id ? `/store/pos/shifts/${id}` : null)
  const s = sh.data
  const r = s?.report
  return (
    <Drawer open={!!id} onClose={onClose} width={520} title={s ? `Смена №${s.number} · ${s.device_name}` : 'Смена'}>
      <LoadError error={sh.error} retry={() => sh.refetch()} />
      {s && (
        <Flex vertical gap={16}>
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label="Магазин">{s.store_name}</Descriptions.Item>
            <Descriptions.Item label="Открыл">
              {s.opened_by_name} · {dateTime(s.opened_at)}
            </Descriptions.Item>
            <Descriptions.Item label="Закрыл">{s.closed_at ? `${s.closed_by_name ?? ''} · ${dateTime(s.closed_at)}` : 'Смена открыта'}</Descriptions.Item>
            <Descriptions.Item label="Размен">{money(s.opening_cash)}</Descriptions.Item>
          </Descriptions>
          {r && (
            <>
              <Descriptions column={1} size="small" bordered title="Продажи">
                <Descriptions.Item label="Чеков">{r.sales_count}</Descriptions.Item>
                <Descriptions.Item label="Выручка">{money(r.sales_total)}</Descriptions.Item>
                <Descriptions.Item label="Скидки">{money(r.discounts)}</Descriptions.Item>
                <Descriptions.Item label="Возвраты">
                  {r.returns_count} · {money(r.returns_total)}
                </Descriptions.Item>
                {r.by_method.map((m) => (
                  <Descriptions.Item key={m.payment_method_id} label={m.name}>
                    {money(m.sales)}
                    {Number(m.returns) > 0 && ` · возвраты ${money(m.returns)}`}
                  </Descriptions.Item>
                ))}
              </Descriptions>
              <Descriptions column={1} size="small" bordered title="Наличные в ящике">
                <Descriptions.Item label="Внесения">{money(r.cash_in)}</Descriptions.Item>
                <Descriptions.Item label="Изъятия">{money(r.cash_out)}</Descriptions.Item>
                <Descriptions.Item label="Должно быть">{money(s.expected_cash ?? r.expected_cash)}</Descriptions.Item>
                {s.counted_cash !== null && <Descriptions.Item label="Посчитано">{money(s.counted_cash)}</Descriptions.Item>}
                {s.diff !== null && (
                  <Descriptions.Item label="Расхождение">
                    <Typography.Text type={Number(s.diff) === 0 ? 'success' : 'danger'}>
                      {money(s.diff)}
                      {s.diff_reason && ` · ${s.diff_reason}`}
                    </Typography.Text>
                  </Descriptions.Item>
                )}
              </Descriptions>
              {r.fiscal_pending > 0 && (
                <Alert type="warning" showIcon message={`Чеков без фискального признака: ${r.fiscal_pending}`} />
              )}
            </>
          )}
        </Flex>
      )}
    </Drawer>
  )
}

export function PosShiftsPage() {
  const { storeId } = useStore()
  const paged = usePaged<Shift>('/store/pos/shifts', { store_id: storeId })
  const [open, setOpen] = useState<string | null>(null)
  return (
    <NeedStore>
      <PageTitle
        title="Смены касс"
        extra={
          <Button icon={<ReloadOutlined spin={paged.isFetching} />} onClick={() => paged.refetch()}>
            Обновить
          </Button>
        }
      >
        <Typography.Text type="secondary">Выручка по способам оплаты и расхождения наличных на закрытии. Нажмите на смену — откроется отчёт.</Typography.Text>
      </PageTitle>
      <LoadError error={paged.error} retry={() => paged.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Shift>
          rowKey="id"
          loading={paged.isLoading}
          dataSource={paged.items}
          pagination={paged.pagination}
          scroll={{ x: true }}
          onRow={(r) => ({ onClick: () => setOpen(r.id), style: { cursor: 'pointer' } })}
          locale={{ emptyText: 'Смен ещё не было' }}
          columns={[
            { title: 'Смена', key: 'n', render: (_, r) => <b>№{r.number}</b> },
            { title: 'Касса', dataIndex: 'device_name' },
            { title: 'Открыл', key: 'o', render: (_, r) => `${r.opened_by_name} · ${dateTime(r.opened_at)}` },
            {
              title: 'Закрыта',
              key: 'c',
              render: (_, r) => (r.closed_at ? dateTime(r.closed_at) : <Tag color="blue">Открыта</Tag>),
            },
            { title: 'Размен', dataIndex: 'opening_cash', align: 'right', render: (v: string) => money(v) },
            { title: 'Должно быть', dataIndex: 'expected_cash', align: 'right', render: (v: string | null) => (v === null ? '—' : money(v)) },
            { title: 'Посчитано', dataIndex: 'counted_cash', align: 'right', render: (v: string | null) => (v === null ? '—' : money(v)) },
            {
              title: 'Расхождение',
              key: 'd',
              align: 'right',
              render: (_, r) =>
                r.diff === null ? (
                  '—'
                ) : Number(r.diff) === 0 ? (
                  <Typography.Text type="success">0</Typography.Text>
                ) : (
                  <Space direction="vertical" size={0} style={{ alignItems: 'flex-end' }}>
                    <Typography.Text type="danger" strong>
                      {money(r.diff)}
                    </Typography.Text>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {r.diff_reason}
                    </Typography.Text>
                  </Space>
                ),
            },
          ]}
        />
      </Card>
      <ShiftDrawer id={open} onClose={() => setOpen(null)} />
    </NeedStore>
  )
}
