import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, App, Button, Card, Checkbox, Input, Modal, Popconfirm, Select, Space, Table, Tag, Typography } from 'antd'
import dayjs from 'dayjs'
import { LoadError, PageTitle, StatusTag, api, date, dateTime, money, useAction, useItem, useList, usePaged } from '@sm/shared'
import { SearchSelect } from '../components'
import { useUrlState } from '../hooks'
import { BillingSettingsForm, type Plan } from './Plans'
import { NetworkPlanModal, PlanCell, type NetworkBilling } from './NetworkPlan'

export function BillingSettings() {
  const plans = useList<Plan>('/admin/plans')
  return (
    <>
      <PageTitle title="Настройки подписки" />
      <Card style={{ maxWidth: 520 }}>
        <BillingSettingsForm plans={plans.data ?? []} />
      </Card>
    </>
  )
}

export function BillingNetworks() {
  const [overdueParam, setOverdue] = useUrlState('overdue')
  const overdue = overdueParam === 'true'
  const list = usePaged<NetworkBilling>('/admin/billing/networks', { overdue: overdue || undefined })
  const plans = useList<Plan>('/admin/plans')
  const [editing, setEditing] = useState<string | null>(null)
  return (
    <>
      <PageTitle title="Сети и оплата">
        <Checkbox checked={overdue} onChange={(e) => setOverdue(e.target.checked ? 'true' : undefined)}>
          Только с просрочкой
        </Checkbox>
      </PageTitle>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<NetworkBilling>
          rowKey="network_id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          scroll={{ x: true }}
          columns={[
            {
              title: 'Сеть',
              render: (_, n) => (
                <>
                  <Link to={`/networks?open=${n.network_id}`}>{n.network_name}</Link> {n.status !== 'active' && <StatusTag status={n.status} />}
                </>
              ),
            },
            { title: 'Тариф', render: (_, n) => <PlanCell b={n} plans={plans.data} /> },
            { title: 'Магазинов', dataIndex: 'stores_count' },
            {
              title: 'Цена за магазин',
              render: (_, n) => (
                <>
                  {money(n.price_per_store)} сум {n.custom_price_uzs !== null && <Tag color="purple">своя цена</Tag>}
                </>
              ),
            },
            { title: 'В месяц', dataIndex: 'monthly_uzs', render: (v) => `${money(v)} сум` },
            { title: 'Платит с', dataIndex: 'billing_from', render: date },
            { title: 'Баланс', render: (_, n) => <>{money(n.balance_available)} <Typography.Text type="secondary">(+{money(n.balance_pending)} в пути)</Typography.Text></> },
            {
              title: 'Долг',
              render: (_, n) =>
                Number(n.unpaid_uzs) > 0 ? (
                  <Link to={`/billing/invoices?network_id=${n.network_id}&status=unpaid`}>
                    <Typography.Text type={n.overdue ? 'danger' : undefined}>
                      {money(n.unpaid_uzs)} сум{n.overdue && ' — просрочен'}
                    </Typography.Text>
                  </Link>
                ) : (
                  '—'
                ),
            },
            {
              key: 'edit',
              render: (_, n) => (
                <Button size="small" onClick={() => setEditing(n.network_id)}>
                  Тариф
                </Button>
              ),
            },
          ]}
        />
      </Card>
      <NetworkPlanModal networkId={editing} onClose={() => setEditing(null)} />
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
  currency: 'UZS' | 'USD'
  amount_usd: string | null
  rate: string | null
  amount_uzs: string
  plan_key: string | null
  plan_name: string
  ad_share_uzs: string
  showcase_plan: string | null
  showcase_uzs: string
  status: string
  due_date: string
  overdue: boolean
  paid_via: string | null
  paid_at: string | null
  note: string
}

export function Invoices() {
  const [status, setStatus] = useUrlState('status')
  const [network, setNetwork] = useUrlState('network_id')
  const networkItem = useItem<{ name: string }>(network ? `/admin/networks/${network}` : null)
  const list = usePaged<Invoice>('/admin/billing/invoices', { status, network_id: network })
  const [acting, setActing] = useState<{ inv: Invoice; action: 'paid' | 'cancel' } | null>(null)
  const [note, setNote] = useState('')
  const closeActing = () => {
    setActing(null)
    setNote('')
  }
  const act = useAction((v: { id: string; action: string; note: string }) => api.post(`/admin/billing/invoices/${v.id}/${v.action}`, { note: v.note }), {
    success: 'Готово',
  })
  const { modal } = App.useApp()
  const generate = useAction(() => api.post<{ created: number }>('/admin/billing/invoices/generate'), {})
  return (
    <>
      <PageTitle title="Счета за подписку">
        <SearchSelect
          path="/admin/networks"
          placeholder="Сеть"
          allowClear
          value={network}
          known={{ id: network, label: networkItem.data?.name }}
          onChange={(v) => setNetwork(v as string | undefined)}
        />
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
        <Popconfirm
          title="Выставить счета за текущий месяц?"
          description="Счета получат все сети, у которых их ещё нет за этот месяц."
          okText="Выставить"
          onConfirm={() =>
            generate
              .mutateAsync(undefined)
              .then((r) => {
                modal.info({ title: `Новых счетов: ${r.created}` })
              })
              .catch(() => undefined)
          }
        >
          <Button loading={generate.isPending}>Выставить за текущий месяц</Button>
        </Popconfirm>
      </PageTitle>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Invoice>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          scroll={{ x: true }}
          columns={[
            { title: 'Месяц', dataIndex: 'period', render: (p: string) => dayjs(p + '-01').format('MM.YYYY') },
            { title: 'Сеть', dataIndex: 'network_name' },
            { title: 'Магазинов', dataIndex: 'stores_count' },
            {
              title: 'Сумма',
              render: (_, i) => (
                <>
                  <b>{money(i.amount_uzs)} сум</b>
                  {i.currency === 'USD' ? (
                    <Typography.Text type="secondary"> ({money(i.amount_usd)} $ по курсу {money(i.rate)})</Typography.Text>
                  ) : (
                    <div>
                      <Typography.Text type="secondary">
                        «{i.plan_name}»: {i.stores_count} × {money(i.price_per_store)} сум
                      </Typography.Text>
                    </div>
                  )}
                  {Number(i.showcase_uzs) > 0 && (
                    <div>
                      <Typography.Text type="secondary">в т. ч. витрина «{i.showcase_plan}»: {money(i.showcase_uzs)} сум</Typography.Text>
                    </div>
                  )}
                  {Number(i.ad_share_uzs) > 0 && (
                    <div>
                      <Typography.Text type="secondary">зачтено с рекламы брендов: {money(i.ad_share_uzs)} сум</Typography.Text>
                    </div>
                  )}
                </>
              ),
            },
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
        confirmLoading={act.isPending}
        onCancel={closeActing}
        onOk={() => act.mutate({ id: acting!.inv.id, action: acting!.action, note }, { onSuccess: closeActing })}
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
  const [status, setStatus] = useUrlState('status', 'requested')
  const [network, setNetwork] = useUrlState('network_id')
  const networkItem = useItem<{ name: string }>(network ? `/admin/networks/${network}` : null)
  const list = usePaged<Payout>('/admin/payouts', { status, network_id: network })
  const [acting, setActing] = useState<{ p: Payout; action: 'paid' | 'reject' } | null>(null)
  const [note, setNote] = useState('')
  const closeActing = () => {
    setActing(null)
    setNote('')
  }
  const act = useAction((v: { id: string; action: string; note: string }) => api.post(`/admin/payouts/${v.id}/${v.action}`, { note: v.note }), {
    success: 'Готово',
  })
  return (
    <>
      <PageTitle title="Выводы денег">
        <SearchSelect
          path="/admin/networks"
          placeholder="Сеть"
          allowClear
          value={network}
          known={{ id: network, label: networkItem.data?.name }}
          onChange={(v) => setNetwork(v as string | undefined)}
        />
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
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Payout>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
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
        confirmLoading={act.isPending}
        onCancel={closeActing}
        onOk={() => act.mutate({ id: acting!.p.id, action: acting!.action, note }, { onSuccess: closeActing })}
      >
        <Typography.Paragraph>
          {acting?.p.network_name}: {acting && money(acting.p.amount)} сум на {acting?.p.requisites}
        </Typography.Paragraph>
        <Input placeholder={acting?.action === 'paid' ? 'Номер платёжки (необязательно)' : 'Причина отказа'} value={note} onChange={(e) => setNote(e.target.value)} />
      </Modal>
    </>
  )
}
