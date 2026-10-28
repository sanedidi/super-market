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
  InputNumber,
  Modal,
  Popconfirm,
  Row,
  Space,
  Switch,
  Table,
  Tag,
  Typography,
} from 'antd'
import { KeyOutlined, PlusOutlined, ReloadOutlined } from '@ant-design/icons'
import dayjs from 'dayjs'
import { Link } from 'react-router-dom'
import { DeleteButton, LoadError, PageTitle, api, dateTime, money, tr, useAction, useItem, useList, usePaged } from '@sm/shared'
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
  debt_paid_cash?: string
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
  /**
   * Как закрыта (Figma «Касса · Закрыть день», «Логика», п. 8): pos — с кассы с пересчётом,
   * pos_quick — с кассы без пересчёта, pos_auto — касса закрыла вчерашнюю смену сама при
   * «Начать день», auto — сервер (открыта дольше 20 часов), panel — в панели.
   */
  closed_via: 'pos' | 'pos_quick' | 'pos_auto' | 'auto' | 'panel' | null
  report?: ShiftReport
}

interface PosSettings {
  weight_prefixes: string[]
  receipt_header: string
  receipt_footer: string
  /** «Требовать пересчёт при закрытии дня» (Figma ЗД4), по умолчанию выключено. */
  require_recount?: boolean
}

/** Код XXXX-XXXX крупно — его вводят на кассе. */
function CodeView({ device }: { device: Device }) {
  const code = device.activation_code ?? ''
  return (
    <Flex vertical align="center" gap={12} style={{ padding: '8px 0' }}>
      <Typography.Text type="secondary">{tr(`Введите этот код на кассе «${device.name}»`, `Bu kodni «${device.name}» kassasida kiriting`)}</Typography.Text>
      <Typography.Text copyable={{ text: code }} style={{ fontSize: 40, fontWeight: 700, letterSpacing: 6, fontFamily: 'monospace' }}>
        {code.length === 8 ? code.slice(0, 4) + '-' + code.slice(4) : code}
      </Typography.Text>
      <Typography.Text type="secondary">
        {tr(
          `Действует до ${device.activation_expires ? dateTime(device.activation_expires) : 'завтра'} · подключить можно один раз`,
          `${device.activation_expires ? dateTime(device.activation_expires) : 'ertaga'} gacha amal qiladi · faqat bir marta ulash mumkin`,
        )}
      </Typography.Text>
    </Flex>
  )
}

function lastSeen(d: Device) {
  if (!d.last_seen_at) return null
  const min = dayjs().diff(dayjs(d.last_seen_at), 'minute')
  return min < 5 ? tr('на связи', 'aloqada') : tr(`была на связи ${dateTime(d.last_seen_at)}`, `oxirgi aloqa: ${dateTime(d.last_seen_at)}`)
}

function DevicesCard() {
  const { storeId, can } = useStore()
  const { modal } = App.useApp()
  const list = useList<Device>('/store/pos/devices', { store_id: storeId })
  const [creating, setCreating] = useState(false)
  const [form] = Form.useForm<{ name: string }>()
  const inv = { invalidate: [['/store/pos/devices']] }
  const showCode = (d: Device) => modal.info({ title: tr('Код подключения кассы', 'Kassani ulash kodi'), width: 520, icon: null, content: <CodeView device={d} /> })
  const create = useAction((v: { name: string }) => api.post<Device>('/store/pos/devices', { store_id: storeId, name: v.name }), inv)
  const newCode = useAction((id: string) => api.post<Device>(`/store/pos/devices/${id}/code`), inv)
  const revoke = useAction((id: string) => api.post<Device>(`/store/pos/devices/${id}/revoke`), { ...inv, success: tr('Касса отключена', 'Kassa oʻchirildi') })
  const manage = can('stores.manage')
  const items = list.data ?? []

  return (
    <Card
      title={`${tr('Кассы', 'Kassalar')} · ${items.filter((d) => d.status !== 'revoked').length}`}
      extra={
        manage && (
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreating(true)}>
            {tr('Новая касса', 'Yangi kassa')}
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
        locale={{ emptyText: tr(
            'Касс ещё нет — нажмите «Новая касса», затем введите код на компьютере или планшете',
            'Hali kassalar yoʻq — «Yangi kassa» tugmasini bosing, soʻng kodni kompyuter yoki planshetda kiriting',
          ), }}
        columns={[
          {
            title: tr('Касса', 'Kassa'),
            dataIndex: 'name',
            render: (v: string, d) => (
              <Space direction="vertical" size={0}>
                <b>{v}</b>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {[d.app_version && tr('версия ', 'versiya ') + d.app_version, d.activated_at && tr('подключена ', 'ulangan ') + dateTime(d.activated_at)]
                    .filter(Boolean)
                    .join(' · ') || tr('создана ', 'yaratilgan ') + dateTime(d.created_at)}
                </Typography.Text>
              </Space>
            ),
          },
          {
            title: tr('Статус', 'Holat'),
            key: 'status',
            render: (_, d) =>
              d.status === 'revoked' ? (
                <Tag>{tr('Отключена', 'Oʻchirilgan')}</Tag>
              ) : d.status === 'waiting' ? (
                <Tag color="orange">{tr('Ждёт подключения', 'Ulanishni kutmoqda')}</Tag>
              ) : (
                <Space size={4} wrap>
                  <Tag color="green">{tr('Подключена', 'Ulangan')}</Tag>
                  {d.open_shift_id && <Tag color="blue">{tr('Смена открыта', 'Smena ochiq')}</Tag>}
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
                    {d.status === 'waiting' ? tr('Показать код', 'Kodni koʻrsatish') : tr('Новый код', 'Yangi kod')}
                  </Button>
                  {d.status === 'waiting' && <DeleteButton path={`/store/pos/devices/${d.id}`} name={d.name} />}
                  <Popconfirm
                    title={tr('Отключить кассу?', 'Kassa oʻchirilsinmi?')}
                    description={tr(
                      'Она перестанет продавать и отправлять чеки. Неотправленные чеки останутся на ней.',
                      'U sotish va cheklarni yuborishni toʻxtatadi. Yuborilmagan cheklar unda qoladi.',
                    )}
                    okText={tr('Отключить', 'Oʻchirish')}
                    okButtonProps={{ danger: true }}
                    onConfirm={() => revoke.mutate(d.id)}
                  >
                    <Button size="small" danger>
                      {tr('Отключить', 'Oʻchirish')}
                    </Button>
                  </Popconfirm>
                </Space>
              ),
          },
        ]}
      />
      <Modal
        open={creating}
        title={tr('Новая касса', 'Yangi kassa')}
        okText={tr('Создать и показать код', 'Yaratish va kodni koʻrsatish')}
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
        <Form form={form} layout="vertical" preserve={false} initialValues={{ name: tr(`Касса ${items.length + 1}`, `Kassa ${items.length + 1}`) }}>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={[{ required: true, whitespace: true, message: tr('Например, «Касса 1 · Windows»', 'Masalan, «Kassa 1 · Windows»') }]}>
            <Input maxLength={60} autoFocus />
          </Form.Item>
          <Typography.Text type="secondary">
            {tr(
              'Касса привязывается к выбранному сейчас магазину. После создания появится код — введите его в программе кассы.',
              'Kassa hozir tanlangan doʻkonga bogʻlanadi. Yaratilgandan soʻng kod chiqadi — uni kassa dasturida kiriting.',
            )}
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
  const save = useAction((v: { id: string; pin: string }) => api.put(`/store/pos/pins/${v.id}`, { pin: v.pin }), { ...inv, success: tr('ПИН сохранён', 'PIN-kod saqlandi') })
  const clear = useAction((id: string) => api.del(`/store/pos/pins/${id}`), { ...inv, success: tr('ПИН убран', 'PIN-kod olib tashlandi') })
  if (!can('staff.manage')) return null
  const items = list.data ?? []
  const valid = /^[0-9]{4}$/.test(pin)

  return (
    <Card title={tr('ПИНы кассиров', 'Kassirlar PIN-kodlari')} styles={{ body: { paddingTop: 8 } }}>
      <Typography.Paragraph type="secondary" style={{ fontSize: 13 }}>
        {tr(
          'Кассир входит на кассе по ПИНу (ровно 4 цифры). Без ПИНа сотрудника нет в списке на кассе. Права (скидки, возвраты) — в «Настройки → Роли».',
          'Kassir kassaga PIN-kod (aynan 4 ta raqam) bilan kiradi. PIN-kodsiz xodim kassadagi roʻyxatda boʻlmaydi. Huquqlar (chegirmalar, qaytarishlar) — «Sozlamalar → Rollar» boʻlimida.',
        )}
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
                  {r.is_owner ? tr('Владелец', 'Egasi') : r.role_name}
                </Typography.Text>
                {!r.can_pos && <Tag style={{ fontSize: 11 }}>{tr('нет права продавать', 'sotish huquqi yoʻq')}</Tag>}
                {r.can_pos && r.can_return && <Tag color="purple" style={{ fontSize: 11 }}>
                    {tr('старший: возвраты', 'katta: qaytarishlar')}
                  </Tag>}
                {r.has_pin ? (
                  <Tag color="green" style={{ fontSize: 11 }}>
                    {tr('ПИН задан', 'PIN-kod bor')}
                  </Tag>
                ) : (
                  <Tag style={{ fontSize: 11 }}>{tr('без ПИНа', 'PIN-kodsiz')}</Tag>
                )}
                {r.locked && <Tag color="red" style={{ fontSize: 11 }}>
                    {tr('заблокирован 5 мин', '5 daqiqaga bloklangan')}
                  </Tag>}
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
              {r.has_pin ? tr('Сменить ПИН', 'PIN-kodni almashtirish') : tr('Задать ПИН', 'PIN-kod berish')}
            </Button>
            {r.has_pin && (
              <Popconfirm
                title={tr('Убрать ПИН?', 'PIN-kod olib tashlansinmi?')}
                description={tr('Сотрудник не сможет войти на кассе.', 'Xodim kassaga kira olmaydi.')}
                onConfirm={() => clear.mutate(r.employee_id)}>
                <Button size="small" type="text" danger>
                  {tr('Убрать', 'Olib tashlash')}
                </Button>
              </Popconfirm>
            )}
          </Flex>
        ))}
        {!list.isLoading && items.length === 0 && <Typography.Text type="secondary">{tr('Сотрудников в этом магазине нет', 'Bu doʻkonda xodimlar yoʻq')}</Typography.Text>}
      </Flex>
      <Modal
        open={!!editing}
        title={`${tr('ПИН', 'PIN-kod')} · ${editing?.name ?? ''}`}
        okText={tr('Сохранить', 'Saqlash')}
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
          maxLength={4}
          placeholder={tr('4 цифры', '4 ta raqam')}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
          onPressEnter={() => editing && valid && save.mutate({ id: editing.employee_id, pin }, { onSuccess: () => setEditing(null) })}
          style={{ fontSize: 24, letterSpacing: 8 }}
        />
        <Typography.Paragraph type="secondary" style={{ marginTop: 12, marginBottom: 0 }}>
          {tr(
            'Сообщите ПИН кассиру лично. На кассе он появится после обновления каталога — в течение минуты.',
            'PIN-kodni kassirga shaxsan ayting. U katalog yangilangach kassada paydo boʻladi — bir daqiqa ichida.',
          )}
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
    success: tr('Настройки кассы сохранены', 'Kassa sozlamalari saqlandi'),
  })
  if (!settings.data) return <LoadError error={settings.error} retry={() => settings.refetch()} />
  const readOnly = !can('stores.manage')
  return (
    <Card title={tr('Чек (для всей сети)', 'Chek (butun tarmoq uchun)')}>
      <Form
        form={form}
        layout="vertical"
        disabled={readOnly}
        initialValues={settings.data}
        onFinish={(v) =>
          save.mutate({ ...v, weight_prefixes: settings.data?.weight_prefixes ?? ['22'], require_recount: settings.data?.require_recount ?? false })
        }
      >
        <Form.Item
          name="receipt_header"
          label={tr('Шапка чека', 'Chek sarlavhasi')}
          extra={tr('Название ЯТТ/ООО, ИНН, адрес — как в регистрации', 'YaTT/MChJ nomi, STIR, manzil — roʻyxatdan oʻtgandagidek')}
        >
          <Input.TextArea rows={3} maxLength={500} placeholder={tr('ЯТТ «Baraka Market»\nИНН 123456789\nг. Ташкент, Чиланзар 1', 'YaTT «Baraka Market»\nSTIR 123456789\nToshkent sh., Chilonzor 1')} />
        </Form.Item>
        <Form.Item name="receipt_footer" label={tr('Текст внизу чека', 'Chek pastidagi matn')}>
          <Input.TextArea rows={2} maxLength={500} placeholder={tr('Спасибо за покупку!', 'Xaridingiz uchun rahmat!')} />
        </Form.Item>
        <Typography.Paragraph type="secondary">
          {tr('Весы с наклейками: формат штрихкода — в ', 'Yorliqli tarozi: shtrix-kod formati — ')}
          <Link to="/settings/scales">{tr('Настройки → Весы', 'Sozlamalar → Tarozi')}</Link>
          {tr(', номера товаров — в «Товары → На весах».', ', mahsulot raqamlari — «Mahsulotlar → Tarozida».')}
        </Typography.Paragraph>
        {!readOnly && (
          <Button type="primary" htmlType="submit" loading={save.isPending}>
            {tr('Сохранить', 'Saqlash')}
          </Button>
        )}
      </Form>
    </Card>
  )
}

// Figma «Касса · Закрыть день» (ЗД4, «Логика», п. 3): по умолчанию кассир закрывает
// день одной кнопкой, по расчёту; включено — касса сразу ведёт в пересчёт ящика.
function CloseDayCard() {
  const { can } = useStore()
  const settings = useItem<PosSettings>('/store/pos/settings')
  const save = useAction((v: PosSettings) => api.put<PosSettings>('/store/pos/settings', v), {
    invalidate: [['/store/pos/settings']],
    success: tr('Настройка сохранена — кассы получат её при синхронизации', 'Sozlama saqlandi — kassalar uni sinxronizatsiyada oladi'),
  })
  if (!settings.data) return null
  const on = settings.data.require_recount ?? false
  return (
    <Card title={tr('Закрытие дня (для всей сети)', 'Kunni yopish (butun tarmoq uchun)')}>
      <Flex gap={12} align="flex-start">
        <Switch
          checked={on}
          disabled={!can('stores.manage')}
          loading={save.isPending}
          onChange={(v) => save.mutate({ ...settings.data!, require_recount: v })}
        />
        <div>
          <Typography.Text strong>{tr('Требовать пересчёт при закрытии дня', 'Kunni yopishda sanashni talab qilish')}</Typography.Text>
          <div>
            <Typography.Text type="secondary">
              {on
                ? tr(
                    'Кассир пересчитывает ящик и набирает сумму, касса сверяет её с расчётом. Расхождение закрытие не задерживает — оно видно в «Сменах» и в Финансах.',
                    'Kassir gʻaladonni sanab, summani teradi, kassa uni hisob bilan solishtiradi. Farq yopishga xalaqit bermaydi — u «Smenalar» va Moliyada koʻrinadi.',
                  )
                : tr(
                    'Выключено: «Закрыть день» — одна кнопка, сумма в ящике по расчёту. Пересчитать ящик кассир может по желанию (F2).',
                    'Oʻchirilgan: «Kunni yopish» — bitta tugma, gʻaladondagi summa hisob boʻyicha. Kassir xohlasa gʻaladonni sanashi mumkin (F2).',
                  )}
            </Typography.Text>
          </div>
        </div>
      </Flex>
    </Card>
  )
}

export function PosDevicesPage() {
  return (
    <NeedStore>
      <PageTitle title={tr('Кассы и ПИНы', 'Kassalar va PIN-kodlar')}>
        <Typography.Text type="secondary">
          {tr(
            '1) Создайте кассу и введите код в программе. 2) Задайте ПИН кассиру. 3) На кассе: выбрать себя → ПИН → размен.',
            '1) Kassa yarating va kodni dasturda kiriting. 2) Kassirga PIN-kod bering. 3) Kassada: oʻzini tanlash → PIN-kod → mayda pul.',
          )}
        </Typography.Text>
      </PageTitle>
      <Row gutter={[16, 16]}>
        <Col xs={24} xl={14}>
          <Flex vertical gap={16}>
            <DevicesCard />
            <SettingsCard />
            <CloseDayCard />
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

/** Сколько часов открыта смена. */
const openHours = (s: Shift) => Math.max(0, dayjs().diff(dayjs(s.opened_at), 'hour'))

/** Как закрыта смена (Figma «Касса · Закрыть день», «Логика», п. 8). */
function closedVia(s: Shift) {
  switch (s.closed_via) {
    case 'pos':
      return tr('с кассы · пересчёт', 'kassadan · sanab')
    case 'pos_quick':
      return tr('с кассы · без пересчёта', 'kassadan · sanamasdan')
    case 'pos_auto':
      return tr('с кассы при начале дня · по расчёту', 'kun boshida kassadan · hisob boʻyicha')
    case 'auto':
      return tr('автоматически', 'avtomatik')
    case 'panel':
      return tr('из панели', 'paneldan')
  }
  return ''
}

/** Ящик пересчитывали: кассир на кассе или владелец в панели. */
const recounted = (s: Shift) => s.closed_via === 'pos' || s.closed_via === 'panel'

/** «автоматически» подсвечено — кассир не закрывал день сам. */
function ClosedViaTag({ s }: { s: Shift }) {
  if (!s.closed_via) return null
  const color = s.closed_via === 'auto' ? 'orange' : s.closed_via === 'pos_auto' ? 'gold' : s.closed_via === 'panel' ? 'blue' : 'default'
  return <Tag color={color}>{closedVia(s)}</Tag>
}

// Figma «Панель · Смены — закрыть зависшую смену кассы» (П1, П2): смена осталась
// открытой (касса недоступна или Z-отчёт не дошёл) — закрыть здесь. Право «Финансы».
function CloseShiftModal({ shift, onClose }: { shift: Shift | null; onClose: () => void }) {
  const [form] = Form.useForm<{ counted_cash: string; diff_reason?: string }>()
  const expected = shift?.report?.expected_cash ?? '0'
  const counted = Form.useWatch('counted_cash', form)
  const differs = counted !== undefined && counted !== null && counted !== '' && Number(counted) !== Number(expected)
  const close = useAction(
    (v: { counted_cash: string; diff_reason?: string }) =>
      api.post<Shift>(`/store/pos/shifts/${shift!.id}/close`, { counted_cash: String(v.counted_cash), diff_reason: v.diff_reason ?? '' }),
    { success: tr('Смена закрыта', 'Smena yopildi') },
  )
  return (
    <Modal
      open={!!shift}
      onCancel={onClose}
      destroyOnHidden
      title={shift ? tr(`Закрыть смену №${shift.number}?`, `№${shift.number} smena yopilsinmi?`) : ''}
      okText={tr('Закрыть смену', 'Smenani yopish')}
      okButtonProps={{ danger: true, loading: close.isPending }}
      cancelText={tr('Отмена', 'Bekor qilish')}
      onOk={() =>
        form
          .validateFields()
          .then((v) => close.mutateAsync(v))
          .then(onClose)
          .catch(() => {})
      }
    >
      {shift && (
        <Flex vertical gap={12}>
          <Typography.Text type="secondary">
            {shift.device_name} · {shift.opened_by_name} · {tr('открыта', 'ochilgan')} {dateTime(shift.opened_at)}
          </Typography.Text>
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label={tr('Должно быть в ящике', 'Gʻaladonda boʻlishi kerak')}>
              <b>{money(expected)}</b>
            </Descriptions.Item>
          </Descriptions>
          <Form form={form} layout="vertical" initialValues={{ counted_cash: String(Number(expected)) }} preserve={false}>
            <Form.Item
              name="counted_cash"
              label={tr('Посчитано в ящике', 'Gʻaladonda sanaldi')}
              rules={[{ required: true, message: tr('Укажите сумму', 'Summani kiriting') }]}
              extra={tr(
                'По умолчанию — по расчёту. Если касса уже в новой смене, наличные этой смены обычно лежат в её ящике.',
                'Odatiy — hisob boʻyicha. Agar kassa yangi smenada boʻlsa, bu smenaning naqd puli odatda uning gʻaladonida.',
              )}
            >
              <InputNumber<string> stringMode min="0" style={{ width: '100%' }} addonAfter={tr('сум', 'soʻm')} />
            </Form.Item>
            <Form.Item
              name="diff_reason"
              label={tr('Причина расхождения', 'Farq sababi')}
              rules={[{ required: differs, message: tr('Сумма отличается — укажите причину', 'Summa farq qiladi — sababini kiriting') }]}
            >
              <Input maxLength={300} disabled={!differs} placeholder={differs ? '' : tr('нужна, если сумма отличается', 'summa farq qilsa kerak')} />
            </Form.Item>
          </Form>
          <Alert
            type="warning"
            message={tr(
              'Смена закроется с пометкой «закрыта в панели». Касса сама отправит всё, что сервер не принял, — новую смену и её чеки.',
              'Smena «panelda yopilgan» belgisi bilan yopiladi. Kassa server qabul qilmagan hamma narsani — yangi smena va uning cheklarini oʻzi yuboradi.',
            )}
          />
        </Flex>
      )}
    </Modal>
  )
}

/** Строка формулы: знак, подпись (и пояснение), сумма. */
function MoneyLine({ sign, label, hint, value, strong }: { sign?: string; label: string; hint?: string; value: string | null; strong?: boolean }) {
  return (
    <Flex align="flex-start" gap={8} style={{ padding: '5px 0' }}>
      <Typography.Text type="secondary" strong style={{ width: 12 }}>
        {sign ?? ''}
      </Typography.Text>
      <div style={{ flex: 1 }}>
        <Typography.Text strong={strong} type={strong ? undefined : 'secondary'}>
          {label}
        </Typography.Text>
        {hint && (
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {hint}
            </Typography.Text>
          </div>
        )}
      </div>
      <Typography.Text strong style={{ fontSize: strong ? 16 : undefined, whiteSpace: 'nowrap' }}>
        {value === null ? '—' : money(value)}
      </Typography.Text>
    </Flex>
  )
}

/**
 * П1 · Две понятные формулы смены (Figma «Финансы понятно»): «Выручка» —
 * все способы оплаты, и «Наличные в ящике» — только то, что лежит в ящике.
 * Терминал в ящик не попадает.
 */
function ShiftMoney({ shift: s, report: r }: { shift: Shift; report: ShiftReport }) {
  const cash = r.by_method.filter((m) => m.kind === 'cash')
  const other = r.by_method.filter((m) => m.kind !== 'cash')
  const debtCash = Number(r.debt_paid_cash ?? 0)
  return (
    <Row gutter={[16, 16]}>
      <Col xs={24} md={12}>
        <Card size="small" title={tr('Выручка', 'Tushum')}>
          {cash.map((m, i) => (
            <MoneyLine key={m.payment_method_id} sign={i === 0 ? undefined : '+'} label={m.name} value={m.sales} />
          ))}
          {other.map((m, i) => (
            <MoneyLine
              key={m.payment_method_id}
              sign={cash.length + i === 0 ? undefined : '+'}
              label={m.name}
              hint={tr('уходит на счёт в банке', 'bankdagi hisobga tushadi')}
              value={m.sales}
            />
          ))}
          <MoneyLine
            sign="−"
            label={tr('Возвраты', 'Qaytarishlar')}
            hint={tr(`${r.returns_count} чек.`, `${r.returns_count} chek`)}
            value={r.returns_total}
          />
          <MoneyLine label={tr('Скидки (уже учтены в чеках)', 'Chegirmalar (cheklarda hisobga olingan)')} value={r.discounts} />
          <div style={{ borderTop: '1px solid #E8E8EB', marginTop: 6, paddingTop: 4 }}>
            <MoneyLine
              sign="="
              strong
              label={tr(`Выручка · ${r.sales_count} чек.`, `Tushum · ${r.sales_count} chek`)}
              value={String(Number(r.sales_total) - Number(r.returns_total))}
            />
          </div>
        </Card>
      </Col>
      <Col xs={24} md={12}>
        <Card size="small" title={tr('Наличные в ящике', 'Gʻaladondagi naqd pul')}>
          <MoneyLine label={tr('Размен на начало', 'Boshidagi maydalik')} hint={dateTime(s.opened_at)} value={s.opening_cash} />
          <MoneyLine sign="+" label={tr('Наличные продажи', 'Naqd sotuvlar')} value={r.cash_sales} />
          {debtCash > 0 && <MoneyLine sign="+" label={tr('Погашения долгов наличными', 'Qarzlar naqd toʻlovi')} value={r.debt_paid_cash ?? '0'} />}
          <MoneyLine sign="+" label={tr('Внесения', 'Kiritishlar')} value={r.cash_in} />
          <MoneyLine sign="−" label={tr('Изъятия и сдачи кассы', 'Olishlar va kassa topshirish')} value={r.cash_out} />
          <MoneyLine sign="−" label={tr('Возвраты наличными', 'Naqd qaytarishlar')} value={r.cash_returns} />
          <div style={{ borderTop: '1px solid #E8E8EB', marginTop: 6, paddingTop: 4 }}>
            <MoneyLine sign="=" strong label={tr('Должно быть в ящике', 'Gʻaladonda boʻlishi kerak')} value={s.expected_cash ?? r.expected_cash} />
          </div>
          {s.counted_cash !== null && recounted(s) && <MoneyLine label={tr('Посчитано при закрытии', 'Yopishda sanaldi')} value={s.counted_cash} />}
          {s.closed_at && !recounted(s) && (
            <Typography.Text type="secondary">{tr('Ящик не пересчитывали — сумма по расчёту', 'Gʻaladon sanalmagan — summa hisob boʻyicha')}</Typography.Text>
          )}
          {s.diff !== null && Number(s.diff) !== 0 && (
            <Typography.Text type="danger">
              {tr('Расхождение', 'Farq')} {money(s.diff)}
              {s.diff_reason && ` · ${s.diff_reason}`}
            </Typography.Text>
          )}
          <div style={{ marginTop: 8 }}>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('Терминал сюда не входит — эти деньги не в ящике', 'Terminal bu yerga kirmaydi — bu pul gʻaladonda emas')}
            </Typography.Text>
          </div>
        </Card>
      </Col>
    </Row>
  )
}

function ShiftDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const { can } = useStore()
  const sh = useItem<Shift>(id ? `/store/pos/shifts/${id}` : null)
  const [closing, setClosing] = useState<Shift | null>(null)
  const s = sh.data
  const r = s?.report
  return (
    <Drawer open={!!id} onClose={onClose} width={760} title={s ? tr(`Смена №${s.number} · ${s.device_name}`, `Smena №${s.number} · ${s.device_name}`) : tr('Смена', 'Smena')}>
      <LoadError error={sh.error} retry={() => sh.refetch()} />
      {s && (
        <Flex vertical gap={16}>
          {!s.closed_at && (
            <Alert
              type={openHours(s) >= 12 ? 'error' : 'info'}
              showIcon
              message={tr(`Смена открыта ${openHours(s)} ч`, `Smena ${openHours(s)} soatdan beri ochiq`)}
              description={tr(
                'Пока она открыта, сервер не примет новую смену этой кассы. Если Z-отчёт не дошёл или касса недоступна — закройте смену здесь.',
                'U ochiq ekan, server bu kassaning yangi smenasini qabul qilmaydi. Z-hisobot yetmagan yoki kassa ishlamasa — smenani shu yerda yoping.',
              )}
              action={
                can('finance.manage') && (
                  <Button danger type="primary" onClick={() => setClosing(s)}>
                    {tr('Закрыть смену', 'Smenani yopish')}
                  </Button>
                )
              }
            />
          )}
          <Descriptions column={1} size="small" bordered>
            <Descriptions.Item label={tr('Магазин', 'Doʻkon')}>{s.store_name}</Descriptions.Item>
            <Descriptions.Item label={tr('Открыл', 'Ochgan')}>
              {s.opened_by_name} · {dateTime(s.opened_at)}
            </Descriptions.Item>
            <Descriptions.Item label={tr('Закрыл', 'Yopgan')}>
              {s.closed_at ? `${s.closed_by_name ?? ''} · ${dateTime(s.closed_at)}` : tr('Смена открыта', 'Smena ochiq')}
              {s.closed_at && closedVia(s) && (
                <div>
                  <Typography.Text type="secondary">{closedVia(s)}</Typography.Text>
                </div>
              )}
            </Descriptions.Item>
            <Descriptions.Item label={tr('Размен', 'Mayda pul')}>{money(s.opening_cash)}</Descriptions.Item>
          </Descriptions>
          {r && (
            <>
              <ShiftMoney shift={s} report={r} />
              {r.fiscal_pending > 0 && (
                <Alert type="warning" showIcon message={tr(`Чеков без фискального признака: ${r.fiscal_pending}`, `Fiskal belgisiz cheklar: ${r.fiscal_pending}`)} />
              )}
            </>
          )}
        </Flex>
      )}
      <CloseShiftModal
        shift={closing}
        onClose={() => {
          setClosing(null)
          sh.refetch()
        }}
      />
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
        title={tr('Смены касс', 'Kassa smenalari')}
        extra={
          <Button icon={<ReloadOutlined spin={paged.isFetching} />} onClick={() => paged.refetch()}>
            {tr('Обновить', 'Yangilash')}
          </Button>
        }
      >
        <Typography.Text type="secondary">
          {tr(
            'Выручка по способам оплаты и расхождения наличных на закрытии. Нажмите на смену — откроется отчёт.',
            'Toʻlov usullari boʻyicha tushum va yopilishdagi naqd pul farqlari. Smenani bosing — hisobot ochiladi.',
          )}
        </Typography.Text>
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
          locale={{ emptyText: tr('Смен ещё не было', 'Hali smenalar boʻlmagan') }}
          columns={[
            { title: tr('Смена', 'Smena'), key: 'n', render: (_, r) => <b>№{r.number}</b> },
            { title: tr('Касса', 'Kassa'), dataIndex: 'device_name' },
            { title: tr('Открыл', 'Ochgan'), key: 'o', render: (_, r) => `${r.opened_by_name} · ${dateTime(r.opened_at)}` },
            {
              title: tr('Закрыта', 'Yopilgan'),
              key: 'c',
              render: (_, r) =>
                r.closed_at ? (
                  dateTime(r.closed_at)
                ) : openHours(r) >= 12 ? (
                  <Tag color="red">{tr(`открыта ${openHours(r)} ч`, `${openHours(r)} soat ochiq`)}</Tag>
                ) : (
                  <Tag color="blue">{tr('Открыта', 'Ochiq')}</Tag>
                ),
            },
            { title: tr('Как закрыта', 'Qanday yopilgan'), key: 'via', render: (_, r) => <ClosedViaTag s={r} /> },
            { title: tr('Размен', 'Mayda pul'), dataIndex: 'opening_cash', align: 'right', render: (v: string) => money(v) },
            { title: tr('Должно быть', 'Boʻlishi kerak'), dataIndex: 'expected_cash', align: 'right', render: (v: string | null) => (v === null ? '—' : money(v)) },
            {
              title: tr('Посчитано', 'Sanaldi'),
              key: 'counted',
              align: 'right',
              render: (_, r) => (r.counted_cash === null || !recounted(r) ? '—' : money(r.counted_cash)),
            },
            {
              title: tr('Расхождение', 'Farq'),
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
