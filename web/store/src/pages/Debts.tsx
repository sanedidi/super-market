// Долги покупателей: должники магазина, карточка с историей, оплата,
// напоминание, лимит, стоп-лист, списание, споры «Это не я» и настройки.
import { useState, type ReactNode } from 'react'
import {
  Alert,
  Button,
  Card,
  Col,
  Empty,
  Flex,
  Form,
  Input,
  InputNumber,
  Modal,
  Row,
  Segmented,
  Select,
  Space,
  Statistic,
  Switch,
  Table,
  Tag,
  Typography,
} from 'antd'
import { BellOutlined, ReloadOutlined, SearchOutlined } from '@ant-design/icons'
import dayjs from 'dayjs'
import {
  ApiError,
  LoadError,
  PageTitle,
  api,
  date,
  dateTime,
  errorText,
  formatPhone,
  money,
  useAction,
  useDebounced,
  useItem,
  useList,
  usePaged,
} from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'

export interface Debtor {
  debtor_id: string
  phone: string
  full_name: string
  store_id: string
  store_name: string
  amount: string
  limit: string
  available: string
  blocked: boolean
  verified: boolean
  since: string | null
  due_date: string | null
  overdue_days: number
  last_paid_at: string | null
  last_reminder_at: string | null
  open_disputes: number
}

interface Entry {
  id: number
  store_id: string
  store_name: string
  doc_type: 'sale' | 'payment' | 'return' | 'writeoff'
  number: number | null
  amount: string
  balance: string
  detail: string
  employee: string
  dispute_status: '' | 'open' | 'accepted' | 'rejected'
  created_at: string
}

interface Card {
  id: string
  phone: string
  full_name: string
  credit_limit: string | null
  blocked: boolean
  verified: boolean
  note: string
  has_app: boolean
  stores: Debtor[]
  entries: Entry[]
  sales_count: number
  sales_amount: string
}

interface Summary {
  total: string
  count: number
  overdue: string
  overdue_count: number
  unverified: number
  open_disputes: number
  given_today: string
  given_today_count: number
  paid_today: string
  paid_today_cash: string
  paid_today_other: string
}

interface Dispute {
  id: string
  entry_id: number
  debtor_id: string
  full_name: string
  phone: string
  store_name: string
  amount: string
  number: number | null
  comment: string
  status: string
  cashier: string
  entry_at: string
  created_at: string
}

export interface DebtSettings {
  default_limit: string
  unverified_limit: string
  term_days: number
  require_code: boolean
  extra_reminders: boolean
  stores: { store_id: string; name: string; debt_enabled: boolean }[]
}

interface PaymentMethod {
  id: string
  name: string
  store_id: string | null
  is_active: boolean
}

const DOC: Record<Entry['doc_type'], string> = {
  sale: 'В долг',
  payment: 'Оплата',
  return: 'Возврат',
  writeoff: 'Списание',
}

type Status = 'all' | 'overdue' | 'unverified' | 'blocked' | 'disputes'

function statusTag(d: Debtor) {
  if (d.blocked) return <Tag>стоп-лист</Tag>
  if (d.overdue_days > 0) return <Tag color="red">просрочка {d.overdue_days} дн.</Tag>
  if (!d.verified) return <Tag color="orange">не подтв.</Tag>
  return <Tag color="green">в срок</Tag>
}

export function DebtorsPage() {
  const { storeId, can } = useStore()
  const [status, setStatus] = useState<Status>('all')
  const [q, setQ] = useState('')
  const debounced = useDebounced(q.trim())
  const [open, setOpen] = useState<string | null>(null)
  const summary = useItem<Summary>(storeId ? '/store/debtors/summary' : null, { store_id: storeId })
  const disputes = status === 'disputes'
  const paged = usePaged<Debtor>(storeId && !disputes ? '/store/debtors' : null, { store_id: storeId, status, q: debounced })
  const s = summary.data
  const manage = can('debts.manage')
  return (
    <NeedStore>
      <PageTitle
        title="Долги покупателей"
        extra={
          <Button icon={<ReloadOutlined spin={paged.isFetching} />} onClick={() => (paged.refetch(), summary.refetch())}>
            Обновить
          </Button>
        }
      >
        <Typography.Text type="secondary">
          Кто и сколько должен магазину. Продажа в долг — на кассе; здесь — оплата, лимиты, стоп-лист и списание.
        </Typography.Text>
      </PageTitle>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} lg={6}>
          <Card size="small">
            <Statistic title="Нам должны" value={money(s?.total ?? 0)} />
            <Typography.Text type="secondary">{s?.count ?? 0} покупателей</Typography.Text>
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card size="small">
            <Statistic title="Просрочено" value={money(s?.overdue ?? 0)} valueStyle={{ color: '#d92d20' }} />
            <Typography.Text type="secondary">{s?.overdue_count ?? 0} покупателей</Typography.Text>
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card size="small">
            <Statistic title="Сегодня дали в долг" value={money(s?.given_today ?? 0)} />
            <Typography.Text type="secondary">{s?.given_today_count ?? 0} чеков</Typography.Text>
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card size="small">
            <Statistic title="Сегодня вернули" value={money(s?.paid_today ?? 0)} valueStyle={{ color: '#027a48' }} />
            <Typography.Text type="secondary">
              наличными {money(s?.paid_today_cash ?? 0)} · иначе {money(s?.paid_today_other ?? 0)}
            </Typography.Text>
          </Card>
        </Col>
      </Row>
      <Flex gap={12} wrap style={{ marginBottom: 12 }}>
        <Segmented<Status>
          value={status}
          onChange={setStatus}
          options={[
            { value: 'all', label: 'Все' },
            { value: 'overdue', label: `Просрочка${s?.overdue_count ? ' ' + s.overdue_count : ''}` },
            { value: 'unverified', label: `Не подтв.${s?.unverified ? ' ' + s.unverified : ''}` },
            { value: 'blocked', label: 'Стоп-лист' },
            ...(manage ? [{ value: 'disputes' as Status, label: `Споры${s?.open_disputes ? ' ' + s.open_disputes : ''}` }] : []),
          ]}
        />
        {!disputes && (
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="Имя или телефон"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            style={{ width: 260 }}
          />
        )}
      </Flex>
      {disputes ? (
        <DisputesList storeId={storeId} onOpen={setOpen} />
      ) : (
        <Row gutter={16}>
          <Col xs={24} xl={open ? 14 : 24}>
            <LoadError error={paged.error} retry={() => paged.refetch()} />
            <Card styles={{ body: { padding: 0 } }}>
              <Table<Debtor>
                rowKey="debtor_id"
                loading={paged.isLoading}
                dataSource={paged.items}
                pagination={paged.pagination}
                scroll={{ x: true }}
                rowClassName={(r) => (r.debtor_id === open ? 'ant-table-row-selected' : '')}
                onRow={(r) => ({ onClick: () => setOpen(r.debtor_id), style: { cursor: 'pointer' } })}
                locale={{ emptyText: 'Должников нет' }}
                columns={[
                  {
                    title: 'Покупатель',
                    key: 'n',
                    render: (_, r) => (
                      <Space direction="vertical" size={0}>
                        <b>{r.full_name || 'Без имени'}</b>
                        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                          {formatPhone(r.phone)}
                        </Typography.Text>
                      </Space>
                    ),
                  },
                  { title: 'Вернуть до', dataIndex: 'due_date', render: (v: string | null) => (v ? date(v) : '—') },
                  { title: 'Долг', dataIndex: 'amount', align: 'right', render: (v: string) => <b>{money(v)}</b> },
                  { title: 'Лимит', dataIndex: 'limit', align: 'right', render: (v: string) => money(v) },
                  { title: 'Статус', key: 's', render: (_, r) => statusTag(r) },
                ]}
              />
            </Card>
          </Col>
          {open && (
            <Col xs={24} xl={10}>
              <DebtorCard id={open} storeId={storeId} onClose={() => setOpen(null)} />
            </Col>
          )}
        </Row>
      )}
    </NeedStore>
  )
}

function DebtorCard({ id, storeId, onClose }: { id: string; storeId: string; onClose: () => void }) {
  const { can } = useStore()
  const manage = can('debts.manage')
  const card = useItem<Card>(`/store/debtors/${id}`, { store_id: storeId })
  const [modal, setModal] = useState<'' | 'pay' | 'remind' | 'limit' | 'writeoff'>('')
  const save = useAction((body: Record<string, unknown>) => api.patch(`/store/debtors/${id}`, body), { success: 'Сохранено' })
  const c = card.data
  if (card.error) return <LoadError error={card.error} retry={() => card.refetch()} />
  if (!c) return <Card loading />
  const here = c.stores.find((s) => s.store_id === storeId)
  const debt = here?.amount ?? '0'
  const rows: [string, ReactNode][] = [
    ['Долг', <b key="d">{money(debt)}</b>],
    ['Лимит', money(here?.limit ?? c.credit_limit ?? 0) + (c.credit_limit ? ' · свой' : '')],
    ['Свободно', money(here?.available ?? 0)],
    ['Вернуть до', here?.due_date ? date(here.due_date) : '—'],
    ['Последняя оплата', here?.last_paid_at ? dateTime(here.last_paid_at) : 'не было'],
    [`В долг за 2 месяца · ${c.sales_count} чеков`, money(c.sales_amount)],
    ['Номер', c.verified ? 'подтверждён' : <Typography.Text type="warning">не подтверждён</Typography.Text>],
    ['Стоп-лист', c.blocked ? <b>включён</b> : 'выключен'],
  ]
  if (here && here.overdue_days > 0) rows.push(['Просрочка', <Typography.Text type="danger" strong>{here.overdue_days} дн.</Typography.Text>])
  return (
    <Card
      title={
        <Space direction="vertical" size={0}>
          <span>{c.full_name || 'Без имени'}</span>
          <Typography.Text type="secondary" style={{ fontSize: 13, fontWeight: 400 }}>
            {formatPhone(c.phone)}
          </Typography.Text>
        </Space>
      }
      extra={<Button type="text" onClick={onClose}>✕</Button>}
    >
      {rows.map(([k, v]) => (
        <Flex key={k} justify="space-between" style={{ padding: '4px 0' }}>
          <Typography.Text type="secondary">{k}</Typography.Text>
          <span>{v}</span>
        </Flex>
      ))}
      {here?.last_reminder_at && (
        <Alert style={{ margin: '12px 0' }} type="warning" message={`Последнее напоминание: ${dateTime(here.last_reminder_at)}`} />
      )}
      {manage && (
        <Space direction="vertical" style={{ width: '100%', marginTop: 12 }}>
          <Button
            type="primary"
            danger
            block
            icon={<BellOutlined />}
            disabled={Number(debt) <= 0 || !c.has_app}
            onClick={() => setModal('remind')}
          >
            Напомнить об оплате
          </Button>
          {!c.has_app && Number(debt) > 0 && (
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              У покупателя нет приложения Super Market — позвоните ему. В день оплаты автонапоминание тоже не дойдёт.
            </Typography.Text>
          )}
          <Flex gap={8} wrap>
            <Button disabled={Number(debt) <= 0} onClick={() => setModal('pay')}>
              Принять оплату
            </Button>
            <Button onClick={() => setModal('limit')}>Изменить лимит</Button>
            <Button onClick={() => save.mutate({ blocked: !c.blocked })} loading={save.isPending}>
              {c.blocked ? 'Убрать из стоп-листа' : 'В стоп-лист'}
            </Button>
            <Button danger disabled={Number(debt) <= 0} onClick={() => setModal('writeoff')}>
              Списать
            </Button>
          </Flex>
        </Space>
      )}
      <Typography.Title level={5} style={{ marginTop: 20 }}>
        История
      </Typography.Title>
      <Table<Entry>
        size="small"
        rowKey="id"
        pagination={{ pageSize: 10, hideOnSinglePage: true }}
        dataSource={c.entries.filter((e) => e.store_id === storeId)}
        locale={{ emptyText: <Empty description="Записей нет" /> }}
        columns={[
          {
            title: 'Запись',
            key: 'e',
            render: (_, e) => (
              <Space direction="vertical" size={0}>
                <span>
                  {DOC[e.doc_type]}
                  {e.number ? ` № ${e.number}` : ''}
                  {e.dispute_status === 'open' && <Tag color="red" style={{ marginLeft: 6 }}>спор</Tag>}
                </span>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {dateTime(e.created_at)} · {[e.detail, e.employee].filter(Boolean).join(' · ')}
                </Typography.Text>
              </Space>
            ),
          },
          {
            title: 'Сумма',
            key: 'a',
            align: 'right',
            render: (_, e) => (
              <Space direction="vertical" size={0} style={{ alignItems: 'flex-end' }}>
                <Typography.Text strong type={Number(e.amount) < 0 ? 'success' : undefined}>
                  {Number(e.amount) > 0 ? '+' : ''}
                  {money(e.amount)}
                </Typography.Text>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  долг {money(e.balance)}
                </Typography.Text>
              </Space>
            ),
          },
        ]}
      />
      {modal === 'pay' && <PayModal card={c} storeId={storeId} debt={debt} onClose={() => setModal('')} />}
      {modal === 'remind' && here && <RemindModal card={c} debtor={here} onClose={() => setModal('')} />}
      {modal === 'limit' && <LimitModal card={c} onClose={() => setModal('')} />}
      {modal === 'writeoff' && <WriteoffModal card={c} storeId={storeId} debt={debt} onClose={() => setModal('')} />}
    </Card>
  )
}

function PayModal({ card, storeId, debt, onClose }: { card: Card; storeId: string; debt: string; onClose: () => void }) {
  const methods = useList<PaymentMethod>('/store/finance/payment-methods')
  const options = (methods.data ?? []).filter((m) => m.is_active && m.store_id === storeId).map((m) => ({ value: m.id, label: m.name }))
  const [form] = Form.useForm()
  const pay = useAction((v: { amount: string; payment_method_id: string; note?: string }) =>
    api.post('/store/debt-payments', { debtor_id: card.id, store_id: storeId, ...v }), { success: 'Оплата принята' })
  return (
    <Modal
      open
      title="Принять оплату долга"
      okText="Принять"
      confirmLoading={pay.isPending}
      onCancel={onClose}
      onOk={() => form.validateFields().then((v) => pay.mutateAsync(v).then(onClose))}
    >
      <Typography.Paragraph type="secondary">
        {card.full_name || formatPhone(card.phone)} · долг {money(debt)} сум
      </Typography.Paragraph>
      <Form form={form} layout="vertical" initialValues={{ amount: debt, payment_method_id: options[0]?.value }}>
        <Form.Item name="amount" label="Сумма" rules={[{ required: true, message: 'Сумма' }]}>
          <InputNumber<string> stringMode min="1" max={debt} style={{ width: '100%' }} />
        </Form.Item>
        <Space style={{ marginBottom: 16 }}>
          <Button size="small" onClick={() => form.setFieldValue('amount', debt)}>
            Весь долг
          </Button>
          <Button size="small" onClick={() => form.setFieldValue('amount', String(Math.round(Number(debt) / 2)))}>
            Половина
          </Button>
        </Space>
        <Form.Item name="payment_method_id" label="Как платит" rules={[{ required: true, message: 'Выберите способ оплаты' }]}>
          <Select options={options} loading={methods.isLoading} placeholder="Наличными, картой…" />
        </Form.Item>
        <Form.Item name="note" label="Комментарий">
          <Input placeholder="Например: принёс сын" maxLength={200} />
        </Form.Item>
      </Form>
    </Modal>
  )
}

/** Подтверждение ручного напоминания: как увидит покупатель и правила. */
function RemindModal({ card, debtor, onClose }: { card: Card; debtor: Debtor; onClose: () => void }) {
  const remind = useAction(() => api.post(`/store/debtors/${card.id}/remind`, { store_id: debtor.store_id }), {
    success: 'Напоминание отправлено',
  })
  const due = debtor.due_date
  const body =
    debtor.overdue_days > 0 && due
      ? `Ваш долг ${money(debtor.amount)} сум. Срок был ${dayjs(due).format('D MMMM')} — пожалуйста, погасите долг в магазине.`
      : `Ваш долг ${money(debtor.amount)} сум. Пожалуйста, погасите долг в магазине.`
  return (
    <Modal open title="Напомнить об оплате" okText="Отправить push" okButtonProps={{ danger: true }} confirmLoading={remind.isPending}
      onCancel={onClose}
      onOk={() => remind.mutateAsync(undefined).then(onClose).catch((e) => {
        if (e instanceof ApiError && e.code === 'too_soon') onClose()
      })}
    >
      <Typography.Paragraph>
        Push придёт {card.full_name || 'покупателю'} в приложение Super Market. Нажатие откроет его долг в {debtor.store_name}.
      </Typography.Paragraph>
      <div style={{ background: '#1d2939', borderRadius: 14, padding: 16, marginBottom: 16 }}>
        <Typography.Text style={{ color: '#d0d5dd', fontSize: 12 }}>Так увидит покупатель</Typography.Text>
        <div style={{ background: '#fff', borderRadius: 14, padding: 12, marginTop: 8 }}>
          <Flex justify="space-between">
            <b>Напоминание · {debtor.store_name}</b>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>сейчас</Typography.Text>
          </Flex>
          <div style={{ fontSize: 13 }}>{body}</div>
        </div>
      </div>
      <ul style={{ paddingLeft: 18, color: '#475467', fontSize: 13 }}>
        <li>Не чаще одного раза в сутки</li>
        <li>Ночью (22:00–08:00) push уйдёт утром</li>
        <li>В день оплаты в 10:00 напоминание уходит автоматически</li>
      </ul>
    </Modal>
  )
}

function LimitModal({ card, onClose }: { card: Card; onClose: () => void }) {
  const [own, setOwn] = useState(card.credit_limit !== null)
  const [value, setValue] = useState<string | null>(card.credit_limit)
  const save = useAction((body: Record<string, unknown>) => api.patch(`/store/debtors/${card.id}`, body), { success: 'Лимит сохранён' })
  return (
    <Modal open title="Лимит покупателя" okText="Сохранить" confirmLoading={save.isPending} onCancel={onClose}
      onOk={() => save.mutateAsync({ credit_limit: own ? value ?? '0' : null }).then(onClose)}
    >
      <Space direction="vertical" style={{ width: '100%' }}>
        <Space>
          <Switch checked={own} onChange={setOwn} />
          <span>Свой лимит (иначе — из настроек сети)</span>
        </Space>
        {own && (
          <InputNumber<string> stringMode min="0" value={value ?? undefined} onChange={setValue} style={{ width: '100%' }} addonAfter="сум" />
        )}
      </Space>
    </Modal>
  )
}

function WriteoffModal({ card, storeId, debt, onClose }: { card: Card; storeId: string; debt: string; onClose: () => void }) {
  const [form] = Form.useForm()
  const wo = useAction((v: { amount: string; reason: string }) =>
    api.post('/store/debt-writeoffs', { debtor_id: card.id, store_id: storeId, ...v }), { success: 'Долг списан' })
  return (
    <Modal open title="Списать долг" okText="Списать" okButtonProps={{ danger: true }} confirmLoading={wo.isPending} onCancel={onClose}
      onOk={() => form.validateFields().then((v) => wo.mutateAsync(v).then(onClose))}
    >
      <Typography.Paragraph type="secondary">
        Безнадёжный долг. В отчёте «Прибыль и убыток» он попадёт в расходы.
      </Typography.Paragraph>
      <Form form={form} layout="vertical" initialValues={{ amount: debt }}>
        <Form.Item name="amount" label="Сумма" rules={[{ required: true, message: 'Сумма' }]}>
          <InputNumber<string> stringMode min="1" max={debt} style={{ width: '100%' }} />
        </Form.Item>
        <Form.Item name="reason" label="Причина" rules={[{ required: true, message: 'Укажите причину' }]}>
          <Input maxLength={300} placeholder="Например: покупатель переехал" />
        </Form.Item>
      </Form>
    </Modal>
  )
}

function DisputesList({ storeId, onOpen }: { storeId: string; onOpen: (id: string) => void }) {
  const list = useList<Dispute>('/store/debt-disputes', { store_id: storeId })
  const resolve = useAction(({ id, status }: { id: string; status: string }) => api.post(`/store/debt-disputes/${id}/resolve`, { status }), {
    success: 'Готово',
  })
  return (
    <Card styles={{ body: { padding: 0 } }}>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Table<Dispute>
        rowKey="id"
        loading={list.isLoading}
        dataSource={list.data ?? []}
        pagination={false}
        scroll={{ x: true }}
        locale={{ emptyText: 'Споров нет' }}
        columns={[
          {
            title: 'Покупатель',
            key: 'n',
            render: (_, r) => (
              <a onClick={() => onOpen(r.debtor_id)}>
                {r.full_name || 'Без имени'} · {formatPhone(r.phone)}
              </a>
            ),
          },
          { title: 'Запись', key: 'e', render: (_, r) => `В долг${r.number ? ' · чек № ' + r.number : ''} · ${dateTime(r.entry_at)}` },
          { title: 'Кассир', dataIndex: 'cashier' },
          { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v: string) => <b>{money(v)}</b> },
          { title: 'Комментарий покупателя', dataIndex: 'comment', render: (v: string) => v || '—' },
          {
            title: '',
            key: 'a',
            render: (_, r) => (
              <Space>
                <Button
                  danger
                  size="small"
                  onClick={() =>
                    Modal.confirm({
                      title: 'Запись ошибочна?',
                      content: 'Долг по этой записи будет списан.',
                      okText: 'Да, списать',
                      onOk: () => resolve.mutateAsync({ id: r.id, status: 'accepted' }),
                    })
                  }
                >
                  Принять
                </Button>
                <Button size="small" onClick={() => resolve.mutate({ id: r.id, status: 'rejected' })}>
                  Отклонить
                </Button>
              </Space>
            ),
          },
        ]}
      />
    </Card>
  )
}

/** Настройки → Долги покупателей: переключатель магазина, лимиты и срок сети. */
export function DebtSettingsPage() {
  const { can } = useStore()
  const st = useItem<DebtSettings>('/store/debt-settings')
  const [form] = Form.useForm()
  const toggle = useAction(({ id, on }: { id: string; on: boolean }) => api.put(`/store/debt-settings/stores/${id}`, { debt_enabled: on }), {
    success: 'Сохранено',
  })
  const save = useAction((v: Partial<DebtSettings>) => api.put('/store/debt-settings', v), { success: 'Сохранено' })
  const manage = can('debts.manage')
  if (st.error) return <LoadError error={st.error} retry={() => st.refetch()} />
  if (!st.data) return <Card loading />
  return (
    <>
      <PageTitle title="Настройки · Долги покупателей">
        <Typography.Text type="secondary">
          Переключатель — для каждого магазина. Лимиты и срок — для всей сети. Покупатели эти настройки не видят.
        </Typography.Text>
      </PageTitle>
      <Card title="Даёт в долг" style={{ maxWidth: 760, marginBottom: 16 }}>
        <Typography.Paragraph type="secondary">
          Включено — на кассе есть «В долг». Выключите — кнопка пропадёт, старые долги останутся: их можно принимать и видеть в списке.
        </Typography.Paragraph>
        {st.data.stores.map((s) => (
          <Flex key={s.store_id} justify="space-between" align="center" style={{ padding: '8px 0', borderTop: '1px solid #eaecf0' }}>
            <b>{s.name}</b>
            <Switch
              checked={s.debt_enabled}
              disabled={!manage}
              loading={toggle.isPending && toggle.variables?.id === s.store_id}
              onChange={(on) => toggle.mutate({ id: s.store_id, on })}
            />
          </Flex>
        ))}
      </Card>
      <Card title="Для всей сети" style={{ maxWidth: 760 }}>
        <Form
          form={form}
          layout="vertical"
          disabled={!manage}
          initialValues={st.data}
          onFinish={(v) => save.mutate(v)}
        >
          <Row gutter={16}>
            <Col xs={24} md={8}>
              <Form.Item name="default_limit" label="Лимит по умолчанию, сум" tooltip="На одного покупателя в магазине">
                <InputNumber<string> stringMode min="0" style={{ width: '100%' }} />
              </Form.Item>
            </Col>
            <Col xs={24} md={8}>
              <Form.Item name="unverified_limit" label="Лимит без кода, сум" tooltip="Для покупателей, не подтвердивших номер">
                <InputNumber<string> stringMode min="0" style={{ width: '100%' }} />
              </Form.Item>
            </Col>
            <Col xs={24} md={8}>
              <Form.Item name="term_days" label="Срок возврата, дней" tooltip="С первой неоплаченной покупки">
                <InputNumber min={1} max={365} style={{ width: '100%' }} />
              </Form.Item>
            </Col>
          </Row>
          <Form.Item name="require_code" valuePropName="checked" label="Код при первом долге (Telegram или push на номер покупателя)">
            <Switch />
          </Form.Item>
          <Form.Item
            name="extra_reminders"
            valuePropName="checked"
            label="Дополнительные напоминания: за 3 дня до срока и после просрочки"
            extra="В день оплаты (10:00) напоминание уходит всегда."
          >
            <Switch />
          </Form.Item>
          {manage && (
            <Button type="primary" htmlType="submit" loading={save.isPending}>
              Сохранить
            </Button>
          )}
          {save.error && <Alert type="error" message={errorText(save.error)} style={{ marginTop: 12 }} />}
        </Form>
      </Card>
    </>
  )
}
