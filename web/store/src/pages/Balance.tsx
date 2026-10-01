// Баланс сети на платформе, вывод денег и подписка.
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link, useSearchParams } from 'react-router-dom'
import { Alert, Button, Card, Col, Descriptions, Form, Input, Modal, Popconfirm, Row, Statistic, Table, Tabs, Tag } from 'antd'
import { LoadError, PageTitle, PagedTable, StatusTag, api, date, dateTime, money, periodParams, useAction, useItem, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { RangeFilter, Num, Signed, thisMonth, type Range } from '../ui'
import type { Balance, BalanceEntry, Billing, Invoice, Payout } from '../types'

const entryKinds: Record<string, string> = {
  order: 'Онлайн-заказ',
  refund: 'Возврат покупателю',
  payout: 'Вывод',
  subscription: 'Подписка',
  adjustment: 'Корректировка',
  ad_share: 'Доля с рекламы брендов',
}

export function BalancePage() {
  const balance = useItem<Balance>('/store/balance')
  const billing = useItem<Billing>('/store/billing')
  const [payout, setPayout] = useState(false)
  const [params, setParams] = useSearchParams()
  const tab = params.get('tab') ?? 'entries'
  const b = balance.data

  return (
    <>
      <PageTitle
        title="Баланс и подписка"
        extra={
          <Button type="primary" onClick={() => setPayout(true)} disabled={!b || Number(b.available) <= 0}>
            Вывести деньги
          </Button>
        }
      />
      {billing.data?.overdue && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }} message="Есть просроченный счёт за подписку. Оплатите его, чтобы не потерять доступ." />
      )}
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} md={6}>
          <Card loading={balance.isLoading}>
            <Statistic title="Доступно к выводу, сум" value={money(b?.available)} valueStyle={{ color: '#17b26a' }} />
          </Card>
        </Col>
        <Col xs={12} md={6}>
          <Card loading={balance.isLoading}>
            <Statistic title="Ожидает доставки, сум" value={money(b?.pending)} />
          </Card>
        </Col>
        <Col xs={12} md={6}>
          <Card loading={balance.isLoading}>
            <Statistic title="Следующий вывод" value={b?.next_payout_at ? dateTime(b.next_payout_at) : 'Доступен сейчас'} />
          </Card>
        </Col>
        <Col xs={12} md={6}>
          <Card loading={billing.isLoading}>
            <Statistic title="Долг по подписке, сум" value={money(billing.data?.unpaid_uzs)} valueStyle={{ color: Number(billing.data?.unpaid_uzs) > 0 ? '#b3261e' : undefined }} />
          </Card>
        </Col>
      </Row>
      <Card>
        <Tabs
          activeKey={tab}
          onChange={(k) => setParams(k === 'entries' ? {} : { tab: k }, { replace: true })}
          items={[
            { key: 'entries', label: 'Движения', children: <Entries /> },
            { key: 'payouts', label: 'Заявки на вывод', children: <Payouts /> },
            { key: 'billing', label: 'Подписка', children: <Subscription billing={billing.data} /> },
          ]}
        />
      </Card>
      <PayoutModal open={payout} onClose={() => setPayout(false)} available={b?.available} />
    </>
  )
}

function Entries() {
  const [range, setRange] = useState<Range | null>(thisMonth)
  const list = usePaged<BalanceEntry>('/store/balance/entries', periodParams(range))
  return (
    <>
      <div style={{ marginBottom: 12 }}>
        <RangeFilter value={range} onChange={setRange} allowClear />
      </div>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Table<BalanceEntry>
        rowKey="id"
        size="small"
        loading={list.isLoading || list.isFetching}
        dataSource={list.items}
        scroll={{ x: true }}
        pagination={list.pagination}
        columns={[
          { title: 'Дата', dataIndex: 'created_at', render: dateTime },
          { title: 'Вид', dataIndex: 'kind', render: (v: string) => entryKinds[v] ?? v },
          { title: 'Заказ', dataIndex: 'order_number', render: (v: number | null) => (v ? `№ ${v}` : '') },
          { title: 'Статус', dataIndex: 'status', render: (v: string) => <StatusTag status={v} /> },
          { title: 'Примечание', dataIndex: 'note' },
          { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v: string) => <Signed v={v} /> },
        ]}
      />
    </>
  )
}

const payoutTitles: Record<string, string> = { requested: 'Запрошен', paid: 'Выплачен', rejected: 'Отклонён' }

function Payouts() {
  return (
    <PagedTable<Payout>
      path="/store/payouts"
      size="small"
      columns={[
        { title: '№', dataIndex: 'number' },
        { title: 'Дата', dataIndex: 'created_at', render: dateTime },
        { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v: string) => money(v) },
        { title: 'Реквизиты', dataIndex: 'requisites' },
        { title: 'Статус', dataIndex: 'status', render: (v: string) => <StatusTag status={v} title={payoutTitles[v]} /> },
        { title: 'Обработан', dataIndex: 'processed_at', render: dateTime },
        { title: 'Комментарий', key: 'n', render: (_, r) => [r.note, r.admin_note].filter(Boolean).join(' · ') },
      ]}
    />
  )
}

function PayoutModal({ open, onClose, available }: { open: boolean; onClose: () => void; available?: string }) {
  const [form] = Form.useForm()
  const save = useAction((v: Record<string, unknown>) => api.post('/store/payouts', { ...v, note: v.note ?? '' }), {
    success: 'Заявка на вывод отправлена',
  })
  return (
    <Modal open={open} title="Вывод денег" okText="Отправить заявку" onOk={() => form.submit()} confirmLoading={save.isPending} onCancel={onClose} destroyOnHidden>
      <Alert type="info" showIcon style={{ marginBottom: 16 }} message={`Доступно: ${money(available)} сум. Вывод — не чаще раза в 7 дней.`} />
      <Form form={form} layout="vertical" preserve={false} onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Form.Item name="amount" label="Сумма" rules={[{ required: true, message: 'Укажите сумму' }]}>
          <Num min="1" max={available} />
        </Form.Item>
        <Form.Item name="requisites" label="Реквизиты" rules={[{ required: true, whitespace: true, message: 'Укажите карту или расчётный счёт' }]}>
          <Input.TextArea rows={2} placeholder="Номер карты или р/с, банк, МФО" />
        </Form.Item>
        <Form.Item name="note" label="Комментарий">
          <Input />
        </Form.Item>
      </Form>
    </Modal>
  )
}

function AdShareLine() {
  const { can } = useStore()
  const q = useQuery({
    queryKey: ['/store/ads'],
    queryFn: () => api.get<{ month_share: string; share_pct: string; share_to_subscription: boolean; month_views: number }>('/store/ads'),
    enabled: can('showcase.manage'),
    retry: false,
  })
  const d = q.data
  if (!d) return null
  return (
    <Alert
      type="success"
      showIcon
      style={{ marginBottom: 16 }}
      message={
        <>
          Доля с рекламы брендов за этот месяц: <b>{money(d.month_share)} сум</b> ({Number(d.share_pct).toLocaleString('ru-RU')}% · {d.month_views.toLocaleString('ru-RU')} показов).{' '}
          {d.share_to_subscription ? 'Зачтём в следующий счёт за подписку, остаток — на баланс.' : 'Зачислим на баланс после конца месяца.'}{' '}
          <Link to="/brand-ads">Подробнее</Link>
        </>
      }
    />
  )
}

function Subscription({ billing }: { billing?: Billing }) {

  const pay = useAction((id: string) => api.post(`/store/billing/invoices/${id}/pay`), { success: 'Счёт оплачен с баланса' })
  return (
    <>
      {billing && (
        <Descriptions size="small" bordered column={{ xs: 1, sm: 1, md: 3, lg: 3, xl: 3, xxl: 3 }} style={{ marginBottom: 16 }}>
          <Descriptions.Item label="Магазинов">{billing.stores_count}</Descriptions.Item>
          <Descriptions.Item label="Цена за магазин">
            {money(billing.price_per_store)} $ {billing.custom_price_per_store && <Tag color="blue">индивидуальная</Tag>}
          </Descriptions.Item>
          <Descriptions.Item label="В месяц">{money(billing.monthly_usd)} $</Descriptions.Item>
          <Descriptions.Item label="Оплата с">{date(billing.billing_from)}</Descriptions.Item>
          <Descriptions.Item label="Долг">{money(billing.unpaid_uzs)} сум</Descriptions.Item>
          <Descriptions.Item label="Просрочка">{billing.overdue ? <Tag color="red">Да</Tag> : 'Нет'}</Descriptions.Item>
        </Descriptions>
      )}
      <AdShareLine />
      <PagedTable<Invoice>
        path="/store/billing/invoices"
        pageSize={24}
        size="small"
        locale={{ emptyText: 'Счетов пока нет' }}
        columns={[
          { title: 'Период', dataIndex: 'period' },
          { title: 'Магазинов', dataIndex: 'stores_count', align: 'right' },
          { title: 'Сумма, $', dataIndex: 'amount_usd', align: 'right', render: (v: string) => money(v) },
          { title: 'Курс', dataIndex: 'rate', align: 'right', render: (v: string) => money(v) },
          {
            title: 'Витрина, сум',
            dataIndex: 'showcase_uzs',
            align: 'right',
            render: (v?: string) => (Number(v) ? money(v!) : '—'),
          },
          {
            title: 'Зачтено с рекламы',
            dataIndex: 'ad_share_uzs',
            align: 'right',
            render: (v?: string) => (Number(v) ? <span style={{ color: '#2E9E5B' }}>−{money(v!)}</span> : '—'),
          },
          { title: 'К оплате, сум', dataIndex: 'amount_uzs', align: 'right', render: (v: string) => <b>{money(v)}</b> },
          { title: 'Оплатить до', dataIndex: 'due_date', render: (v: string) => date(v) },
          {
            title: 'Статус',
            dataIndex: 'status',
            render: (v: string, r) => (
              <>
                <StatusTag status={v} />
                {r.overdue && v === 'unpaid' && <Tag color="red">Просрочен</Tag>}
              </>
            ),
          },
          { title: 'Оплачен', dataIndex: 'paid_at', render: dateTime },
          {
            key: 'pay',
            render: (_, r) =>
              r.status === 'unpaid' && (
                <Popconfirm title={`Списать ${money(r.amount_uzs)} сум с баланса?`} onConfirm={() => pay.mutate(r.id)}>
                  <Button size="small" type="primary" loading={pay.isPending}>
                    Оплатить с баланса
                  </Button>
                </Popconfirm>
              ),
          },
        ]}
      />
    </>
  )
}
