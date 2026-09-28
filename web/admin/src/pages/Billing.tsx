import { useEffect, useState } from 'react'
import { Alert, App, Button, Card, Checkbox, DatePicker, Form, Input, InputNumber, Modal, Select, Space, Switch, Table, Tag, Typography } from 'antd'
import dayjs from 'dayjs'
import { ActiveTag, CrudPage, PageTitle, RemoteSelect, StatusTag, api, date, dateTime, money, useAction, useItem, useList } from '@sm/shared'

interface Tariff {
  id: string
  name: string
  min_stores: number
  price_per_store: string
  is_active: boolean
}

export function Tariffs() {
  return (
    <>
      <CrudPage<Tariff>
        title="Тарифы подписки"
        path="/admin/billing/tariffs"
        createLabel="Новый тариф"
        columns={[
          { title: 'Название', dataIndex: 'name' },
          { title: 'От магазинов', dataIndex: 'min_stores' },
          { title: 'Цена за магазин в месяц', dataIndex: 'price_per_store', render: (v) => `${money(v)} $` },
          { title: 'Статус', dataIndex: 'is_active', render: (v) => <ActiveTag active={v} /> },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={[{ required: true }]}>
              <Input />
            </Form.Item>
            <Form.Item name="min_stores" label="Действует от числа магазинов" rules={[{ required: true }]}>
              <InputNumber min={1} style={{ width: '100%' }} />
            </Form.Item>
            <Form.Item name="price_per_store" label="Цена за магазин в месяц, $" rules={[{ required: true }]}>
              <InputNumber min={0} step={1} style={{ width: '100%' }} />
            </Form.Item>
            {editing && (
              <Form.Item name="is_active" label="Активен" valuePropName="checked">
                <Switch />
              </Form.Item>
            )}
          </>
        )}
      />
      <Typography.Paragraph type="secondary" style={{ marginTop: 16 }}>
        Для сети действует тариф с наибольшим «от магазинов», не превышающим число её активных магазинов. Новая цена применяется к
        следующим счетам.
      </Typography.Paragraph>
    </>
  )
}

interface Settings {
  usd_rate: string
  grace_days: number
  auto_charge_balance: boolean
}

export function BillingSettings() {
  const { data } = useItem<Settings>('/admin/billing/settings')
  const [form] = Form.useForm()
  useEffect(() => {
    if (data) form.setFieldsValue({ ...data, usd_rate: Number(data.usd_rate) })
  }, [data, form])
  const save = useAction((v: Settings) => api.put('/admin/billing/settings', { ...v, usd_rate: String(v.usd_rate) }), { success: 'Сохранено' })
  return (
    <>
      <PageTitle title="Настройки подписки" />
      <Card style={{ maxWidth: 520 }}>
        <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v)}>
          <Form.Item name="usd_rate" label="Курс доллара для счетов, сум" rules={[{ required: true }]}>
            <InputNumber min={1} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="grace_days" label="Дней на оплату счёта" rules={[{ required: true }]} extra="После этого магазины сети скрываются из приложения.">
            <InputNumber min={0} max={60} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="auto_charge_balance" valuePropName="checked">
            <Checkbox>Оплачивать счета с баланса платформы автоматически</Checkbox>
          </Form.Item>
          <Button type="primary" htmlType="submit" loading={save.isPending}>
            Сохранить
          </Button>
        </Form>
      </Card>
    </>
  )
}

interface NetworkBilling {
  network_id: string
  network_name: string
  kind: string
  status: string
  stores_count: number
  custom_price_per_store: string | null
  price_per_store: string
  monthly_usd: string
  billing_from: string
  balance_available: string
  balance_pending: string
  unpaid_uzs: string
  overdue: boolean
}

export function BillingNetworks() {
  const [overdue, setOverdue] = useState(false)
  const { data, isLoading } = useList<NetworkBilling>('/admin/billing/networks', { overdue: overdue || undefined, limit: 200 })
  const [editing, setEditing] = useState<NetworkBilling | null>(null)
  const [form] = Form.useForm()
  const save = useAction(
    (v: { custom: boolean; price?: number; billing_from?: dayjs.Dayjs }) =>
      api.patch(`/admin/billing/networks/${editing!.network_id}`, {
        ...(v.custom ? { custom_price_per_store: v.price ?? 0 } : { clear_custom_price: true }),
        billing_from: v.billing_from ? v.billing_from.startOf('month').format('YYYY-MM-DD') : undefined,
      }),
    { success: 'Сохранено' },
  )
  const open = (n: NetworkBilling) => {
    setEditing(n)
    form.setFieldsValue({
      custom: n.custom_price_per_store !== null,
      price: n.custom_price_per_store ? Number(n.custom_price_per_store) : undefined,
      billing_from: dayjs(n.billing_from),
    })
  }
  const custom = Form.useWatch('custom', form)
  return (
    <>
      <PageTitle title="Сети и оплата">
        <Checkbox checked={overdue} onChange={(e) => setOverdue(e.target.checked)}>
          Только с просрочкой
        </Checkbox>
      </PageTitle>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<NetworkBilling>
          rowKey="network_id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          columns={[
            {
              title: 'Сеть',
              render: (_, n) => (
                <>
                  {n.network_name} {n.status !== 'active' && <StatusTag status={n.status} />}
                </>
              ),
            },
            { title: 'Магазинов', dataIndex: 'stores_count' },
            {
              title: 'Цена за магазин',
              render: (_, n) => (
                <>
                  {money(n.price_per_store)} $ {n.custom_price_per_store !== null && <Tag color="purple">индивидуальная</Tag>}
                </>
              ),
            },
            { title: 'В месяц', dataIndex: 'monthly_usd', render: (v) => `${money(v)} $` },
            { title: 'Платит с', dataIndex: 'billing_from', render: date },
            { title: 'Баланс', render: (_, n) => <>{money(n.balance_available)} <Typography.Text type="secondary">(+{money(n.balance_pending)} в пути)</Typography.Text></> },
            { title: 'Долг', render: (_, n) => (Number(n.unpaid_uzs) > 0 ? <Typography.Text type={n.overdue ? 'danger' : undefined}>{money(n.unpaid_uzs)} сум{n.overdue && ' — просрочен'}</Typography.Text> : '—') },
            {
              key: 'edit',
              render: (_, n) => (
                <Button size="small" onClick={() => open(n)}>
                  Условия
                </Button>
              ),
            },
          ]}
        />
      </Card>
      <Modal open={editing !== null} title={`Условия: ${editing?.network_name}`} onCancel={() => setEditing(null)} onOk={() => form.submit()} okText="Сохранить" forceRender>
        <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: () => setEditing(null) })}>
          <Form.Item name="custom" valuePropName="checked">
            <Checkbox>Индивидуальная цена</Checkbox>
          </Form.Item>
          {custom && (
            <Form.Item name="price" label="Цена за магазин в месяц, $" rules={[{ required: true }]}>
              <InputNumber min={0} style={{ width: '100%' }} />
            </Form.Item>
          )}
          <Form.Item name="billing_from" label="Платит с месяца" extra="До этого месяца подписка бесплатна.">
            <DatePicker picker="month" format="MM.YYYY" style={{ width: '100%' }} />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}

interface Invoice {
  id: string
  network_id: string
  network_name: string
  period: string
  stores_count: number
  price_per_store: string
  amount_usd: string
  rate: string
  amount_uzs: string
  status: string
  due_date: string
  overdue: boolean
  paid_via: string | null
  paid_at: string | null
  note: string
}

export function Invoices() {
  const [status, setStatus] = useState<string>()
  const [network, setNetwork] = useState<string>()
  const { data, isLoading } = useList<Invoice>('/admin/billing/invoices', { status, network_id: network, limit: 200 })
  const [acting, setActing] = useState<{ inv: Invoice; action: 'paid' | 'cancel' } | null>(null)
  const [note, setNote] = useState('')
  const act = useAction((v: { id: string; action: string; note: string }) => api.post(`/admin/billing/invoices/${v.id}/${v.action}`, { note: v.note }), {
    success: 'Готово',
  })
  const { modal } = App.useApp()
  const generate = useAction(() => api.post<{ created: number }>('/admin/billing/invoices/generate'), {})
  return (
    <>
      <PageTitle title="Счета за подписку">
        <RemoteSelect path="/admin/networks" params={{ limit: 200 }} placeholder="Сеть" allowClear value={network} onChange={setNetwork} />
        <Select
          placeholder="Статус"
          allowClear
          value={status}
          onChange={setStatus}
          style={{ width: 160 }}
          options={[
            { value: 'unpaid', label: 'Не оплачены' },
            { value: 'overdue', label: 'Просрочены' },
            { value: 'paid', label: 'Оплачены' },
            { value: 'cancelled', label: 'Отменены' },
          ]}
        />
        <Button onClick={() => generate.mutate(undefined, { onSuccess: (r) => modal.info({ title: `Новых счетов: ${r.created}` }) })} loading={generate.isPending}>
          Выставить за текущий месяц
        </Button>
      </PageTitle>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Invoice>
          rowKey="id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          columns={[
            { title: 'Месяц', dataIndex: 'period', render: (p: string) => dayjs(p + '-01').format('MM.YYYY') },
            { title: 'Сеть', dataIndex: 'network_name' },
            { title: 'Магазинов', dataIndex: 'stores_count' },
            { title: 'Сумма', render: (_, i) => <>{money(i.amount_usd)} $ <Typography.Text type="secondary">({money(i.amount_uzs)} сум)</Typography.Text></> },
            { title: 'Срок', dataIndex: 'due_date', render: (d, i) => <Typography.Text type={i.overdue ? 'danger' : undefined}>{date(d)}</Typography.Text> },
            {
              title: 'Статус',
              render: (_, i) => (
                <>
                  <StatusTag status={i.status} />
                  {i.paid_via && <Typography.Text type="secondary">{i.paid_via === 'balance' ? 'с баланса' : 'вручную'} {dateTime(i.paid_at)}</Typography.Text>}
                  {i.note && <div>{i.note}</div>}
                </>
              ),
            },
            {
              key: 'act',
              render: (_, i) =>
                i.status === 'unpaid' && (
                  <Space>
                    <Button size="small" type="primary" onClick={() => setActing({ inv: i, action: 'paid' })}>
                      Оплачен
                    </Button>
                    <Button size="small" onClick={() => setActing({ inv: i, action: 'cancel' })}>
                      Списать
                    </Button>
                  </Space>
                ),
            },
          ]}
        />
      </Card>
      <Modal
        open={acting !== null}
        title={acting?.action === 'paid' ? 'Отметить оплату' : 'Списать счёт'}
        onCancel={() => setActing(null)}
        onOk={() => act.mutate({ id: acting!.inv.id, action: acting!.action, note }, { onSuccess: () => (setActing(null), setNote('')) })}
      >
        <Typography.Paragraph>
          {acting?.inv.network_name}, {acting && money(acting.inv.amount_uzs)} сум
        </Typography.Paragraph>
        <Input placeholder={acting?.action === 'paid' ? 'Номер платёжки, способ оплаты' : 'Причина'} value={note} onChange={(e) => setNote(e.target.value)} />
      </Modal>
    </>
  )
}

interface Payout {
  id: string
  network_name: string
  number: number
  amount: string
  status: string
  requisites: string
  note: string
  admin_note: string
  processed_at: string | null
  created_at: string
}

export function Payouts() {
  const [status, setStatus] = useState<string | undefined>('requested')
  const { data, isLoading } = useList<Payout>('/admin/payouts', { status, limit: 200 })
  const [acting, setActing] = useState<{ p: Payout; action: 'paid' | 'reject' } | null>(null)
  const [note, setNote] = useState('')
  const act = useAction((v: { id: string; action: string; note: string }) => api.post(`/admin/payouts/${v.id}/${v.action}`, { note: v.note }), {
    success: 'Готово',
  })
  return (
    <>
      <PageTitle title="Выводы денег">
        <Select
          value={status}
          allowClear
          placeholder="Все"
          onChange={setStatus}
          style={{ width: 170 }}
          options={[
            { value: 'requested', label: 'Новые заявки' },
            { value: 'paid', label: 'Выплачены' },
            { value: 'rejected', label: 'Отклонены' },
          ]}
        />
      </PageTitle>
      {status === 'requested' && <Alert type="info" showIcon style={{ marginBottom: 16 }} message="Переведите деньги по реквизитам и нажмите «Выплачено». При отказе сумма вернётся на баланс сети." />}
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Payout>
          rowKey="id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          columns={[
            { title: 'Дата', dataIndex: 'created_at', render: dateTime },
            { title: 'Сеть', dataIndex: 'network_name' },
            { title: '№', dataIndex: 'number' },
            { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v) => <b>{money(v)}</b> },
            { title: 'Реквизиты', dataIndex: 'requisites', render: (r, p) => <>{r}{p.note && <div><Typography.Text type="secondary">{p.note}</Typography.Text></div>}</> },
            { title: 'Статус', render: (_, p) => <><StatusTag status={p.status} />{p.admin_note && <div>{p.admin_note}</div>}</> },
            {
              key: 'act',
              render: (_, p) =>
                p.status === 'requested' && (
                  <Space>
                    <Button size="small" type="primary" onClick={() => setActing({ p, action: 'paid' })}>
                      Выплачено
                    </Button>
                    <Button size="small" danger onClick={() => setActing({ p, action: 'reject' })}>
                      Отказать
                    </Button>
                  </Space>
                ),
            },
          ]}
        />
      </Card>
      <Modal
        open={acting !== null}
        title={acting?.action === 'paid' ? 'Подтвердить выплату' : 'Отказать в выводе'}
        okButtonProps={{ danger: acting?.action === 'reject', disabled: acting?.action === 'reject' && !note.trim() }}
        onCancel={() => setActing(null)}
        onOk={() => act.mutate({ id: acting!.p.id, action: acting!.action, note }, { onSuccess: () => (setActing(null), setNote('')) })}
      >
        <Typography.Paragraph>
          {acting?.p.network_name}: {acting && money(acting.p.amount)} сум на {acting?.p.requisites}
        </Typography.Paragraph>
        <Input placeholder={acting?.action === 'paid' ? 'Номер платёжки (необязательно)' : 'Причина отказа'} value={note} onChange={(e) => setNote(e.target.value)} />
      </Modal>
    </>
  )
}
