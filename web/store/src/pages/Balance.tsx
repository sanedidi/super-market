// Баланс сети на платформе, вывод денег и подписка.
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link, useSearchParams } from 'react-router-dom'
import { Alert, Button, Card, Col, Descriptions, Form, Input, Modal, Popconfirm, Row, Statistic, Table, Tabs, Tag } from 'antd'
import { LoadError, PageTitle, PagedTable, StatusTag, api, date, dateTime, money, periodParams, tr, useAction, useItem, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { RangeFilter, Num, Signed, thisMonth, type Range } from '../ui'
import type { Balance, BalanceEntry, Billing, Invoice, Payout } from '../types'

const entryKinds: Record<string, string> = {
  order: tr('Онлайн-заказ', 'Onlayn buyurtma'),
  refund: tr('Возврат покупателю', 'Xaridorga qaytarish'),
  payout: tr('Вывод', 'Pul yechib olish'),
  subscription: tr('Подписка', 'Obuna'),
  adjustment: tr('Корректировка', 'Tuzatish'),
  ad_share: tr('Доля с рекламы брендов', 'Brendlar reklamasidan ulush'),
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
        title={tr('Баланс и подписка', 'Balans va obuna')}
        extra={
          <Button type="primary" onClick={() => setPayout(true)} disabled={!b || Number(b.available) <= 0}>
            {tr('Вывести деньги', 'Pulni yechib olish')}
          </Button>
        }
      />
      {billing.data?.overdue && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }} message={tr(
            'Есть просроченный счёт за подписку. Оплатите его, чтобы не потерять доступ.',
            'Obuna uchun muddati oʻtgan hisob bor. Kirish huquqini yoʻqotmaslik uchun uni toʻlang.',
          )} />
      )}
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} md={6}>
          <Card loading={balance.isLoading}>
            <Statistic title={tr('Доступно к выводу, сум', 'Yechib olish mumkin, soʻm')} value={money(b?.available)} valueStyle={{ color: '#17b26a' }} />
          </Card>
        </Col>
        <Col xs={12} md={6}>
          <Card loading={balance.isLoading}>
            <Statistic title={tr('Ожидает доставки, сум', 'Yetkazishni kutmoqda, soʻm')} value={money(b?.pending)} />
          </Card>
        </Col>
        <Col xs={12} md={6}>
          <Card loading={balance.isLoading}>
            <Statistic
              title={tr('Следующий вывод', 'Keyingi yechib olish')}
              value={b?.next_payout_at ? dateTime(b.next_payout_at) : tr('Доступен сейчас', 'Hozir mumkin')}
            />
          </Card>
        </Col>
        <Col xs={12} md={6}>
          <Card loading={billing.isLoading}>
            <Statistic title={tr('Долг по подписке, сум', 'Obuna boʻyicha qarz, soʻm')} value={money(billing.data?.unpaid_uzs)} valueStyle={{ color: Number(billing.data?.unpaid_uzs) > 0 ? '#b3261e' : undefined }} />
          </Card>
        </Col>
      </Row>
      <Card>
        <Tabs
          activeKey={tab}
          onChange={(k) => setParams(k === 'entries' ? {} : { tab: k }, { replace: true })}
          items={[
            { key: 'entries', label: tr('Движения', 'Harakatlar'), children: <Entries /> },
            { key: 'payouts', label: tr('Заявки на вывод', 'Yechib olish arizalari'), children: <Payouts /> },
            { key: 'billing', label: tr('Подписка', 'Obuna'), children: <Subscription billing={billing.data} /> },
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
          { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
          { title: tr('Вид', 'Turi'), dataIndex: 'kind', render: (v: string) => entryKinds[v] ?? v },
          { title: tr('Заказ', 'Buyurtma'), dataIndex: 'order_number', render: (v: number | null) => (v ? `№ ${v}` : '') },
          { title: tr('Статус', 'Holat'), dataIndex: 'status', render: (v: string) => <StatusTag status={v} /> },
          { title: tr('Примечание', 'Izoh'), dataIndex: 'note' },
          { title: tr('Сумма', 'Summa'), dataIndex: 'amount', align: 'right', render: (v: string) => <Signed v={v} /> },
        ]}
      />
    </>
  )
}

const payoutTitles: Record<string, string> = {
  requested: tr('Запрошен', 'Soʻralgan'),
  paid: tr('Выплачен', 'Toʻlab berildi'),
  rejected: tr('Отклонён', 'Rad etildi'),
}

function Payouts() {
  return (
    <PagedTable<Payout>
      path="/store/payouts"
      size="small"
      columns={[
        { title: '№', dataIndex: 'number' },
        { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
        { title: tr('Сумма', 'Summa'), dataIndex: 'amount', align: 'right', render: (v: string) => money(v) },
        { title: tr('Реквизиты', 'Rekvizitlar'), dataIndex: 'requisites' },
        { title: tr('Статус', 'Holat'), dataIndex: 'status', render: (v: string) => <StatusTag status={v} title={payoutTitles[v]} /> },
        { title: tr('Обработан', 'Koʻrib chiqildi'), dataIndex: 'processed_at', render: dateTime },
        { title: tr('Комментарий', 'Izoh'), key: 'n', render: (_, r) => [r.note, r.admin_note].filter(Boolean).join(' · ') },
      ]}
    />
  )
}

function PayoutModal({ open, onClose, available }: { open: boolean; onClose: () => void; available?: string }) {
  const [form] = Form.useForm()
  const save = useAction((v: Record<string, unknown>) => api.post('/store/payouts', { ...v, note: v.note ?? '' }), {
    success: tr('Заявка на вывод отправлена', 'Pul yechib olish arizasi yuborildi'),
  })
  return (
    <Modal open={open} title={tr('Вывод денег', 'Pul yechib olish')} okText={tr('Отправить заявку', 'Ariza yuborish')} onOk={() => form.submit()} confirmLoading={save.isPending} onCancel={onClose} destroyOnHidden>
      <Alert type="info" showIcon style={{ marginBottom: 16 }} message={tr(
          `Доступно: ${money(available)} сум. Вывод — не чаще раза в 7 дней.`,
          `Mavjud: ${money(available)} soʻm. Pul yechib olish — 7 kunda bir martadan koʻp emas.`,
        )} />
      <Form form={form} layout="vertical" preserve={false} onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Form.Item name="amount" label={tr('Сумма', 'Summa')} rules={[{ required: true, message: tr('Укажите сумму', 'Summani kiriting') }]}>
          <Num min="1" max={available} />
        </Form.Item>
        <Form.Item name="requisites" label={tr('Реквизиты', 'Rekvizitlar')}
          rules={[{ required: true, whitespace: true, message: tr('Укажите карту или расчётный счёт', 'Karta yoki hisob raqamini kiriting') }]}
        >
          <Input.TextArea rows={2} placeholder={tr('Номер карты или р/с, банк, МФО', 'Karta raqami yoki h/r, bank, MFO')} />
        </Form.Item>
        <Form.Item name="note" label={tr('Комментарий', 'Izoh')}>
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
          {tr('Доля с рекламы брендов за этот месяц:', 'Shu oy uchun brendlar reklamasidan ulush:')}{' '}
          <b>
            {money(d.month_share)} {tr('сум', 'soʻm')}
          </b>{' '}
          ({Number(d.share_pct).toLocaleString('ru-RU')}% · {d.month_views.toLocaleString('ru-RU')} {tr('показов', 'ta koʻrsatish')}).{' '}
          {d.share_to_subscription
            ? tr('Зачтём в следующий счёт за подписку, остаток — на баланс.', 'Keyingi obuna hisobiga hisoblanadi, qoldigʻi — balansga.')
            : tr('Зачислим на баланс после конца месяца.', 'Oy tugagach balansga oʻtkaziladi.')}{' '}
          <Link to="/brand-ads">{tr('Подробнее', 'Batafsil')}</Link>
        </>
      }
    />
  )
}

function Subscription({ billing }: { billing?: Billing }) {

  const pay = useAction((id: string) => api.post(`/store/billing/invoices/${id}/pay`), { success: tr('Счёт оплачен с баланса', 'Hisob balansdan toʻlandi') })
  return (
    <>
      {billing && (
        <Descriptions size="small" bordered column={{ xs: 1, sm: 1, md: 3, lg: 3, xl: 3, xxl: 3 }} style={{ marginBottom: 16 }}>
          <Descriptions.Item label={tr('Магазинов', 'Doʻkonlar')}>{billing.stores_count}</Descriptions.Item>
          <Descriptions.Item label={tr('Цена за магазин', 'Bitta doʻkon narxi')}>
            {money(billing.price_per_store)} $ {billing.custom_price_per_store && <Tag color="blue">{tr('индивидуальная', 'individual')}</Tag>}
          </Descriptions.Item>
          <Descriptions.Item label={tr('В месяц', 'Oyiga')}>{money(billing.monthly_usd)} $</Descriptions.Item>
          <Descriptions.Item label={tr('Оплата с', 'Toʻlov boshlanishi')}>{date(billing.billing_from)}</Descriptions.Item>
          <Descriptions.Item label={tr('Долг', 'Qarz')}>
            {money(billing.unpaid_uzs)} {tr('сум', 'soʻm')}
          </Descriptions.Item>
          <Descriptions.Item label={tr('Просрочка', 'Muddati oʻtgan')}>
            {billing.overdue ? <Tag color="red">{tr('Да', 'Ha')}</Tag> : tr('Нет', 'Yoʻq')}
          </Descriptions.Item>
        </Descriptions>
      )}
      <AdShareLine />
      <PagedTable<Invoice>
        path="/store/billing/invoices"
        pageSize={24}
        size="small"
        locale={{ emptyText: tr('Счетов пока нет', 'Hozircha hisoblar yoʻq') }}
        columns={[
          { title: tr('Период', 'Davr'), dataIndex: 'period' },
          { title: tr('Магазинов', 'Doʻkonlar'), dataIndex: 'stores_count', align: 'right' },
          { title: tr('Сумма, $', 'Summa, $'), dataIndex: 'amount_usd', align: 'right', render: (v: string) => money(v) },
          { title: tr('Курс', 'Kurs'), dataIndex: 'rate', align: 'right', render: (v: string) => money(v) },
          {
            title: tr('Витрина, сум', 'Vitrina, soʻm'),
            dataIndex: 'showcase_uzs',
            align: 'right',
            render: (v?: string) => (Number(v) ? money(v!) : '—'),
          },
          {
            title: tr('Зачтено с рекламы', 'Reklamadan hisoblangan'),
            dataIndex: 'ad_share_uzs',
            align: 'right',
            render: (v?: string) => (Number(v) ? <span style={{ color: '#2E9E5B' }}>−{money(v!)}</span> : '—'),
          },
          { title: tr('К оплате, сум', 'Toʻlovga, soʻm'), dataIndex: 'amount_uzs', align: 'right', render: (v: string) => <b>{money(v)}</b> },
          { title: tr('Оплатить до', 'Toʻlov muddati'), dataIndex: 'due_date', render: (v: string) => date(v) },
          {
            title: tr('Статус', 'Holat'),
            dataIndex: 'status',
            render: (v: string, r) => (
              <>
                <StatusTag status={v} />
                {r.overdue && v === 'unpaid' && <Tag color="red">{tr('Просрочен', 'Muddati oʻtgan')}</Tag>}
              </>
            ),
          },
          { title: tr('Оплачен', 'Toʻlangan'), dataIndex: 'paid_at', render: dateTime },
          {
            key: 'pay',
            render: (_, r) =>
              r.status === 'unpaid' && (
                <Popconfirm title={tr(`Списать ${money(r.amount_uzs)} сум с баланса?`, `Balansdan ${money(r.amount_uzs)} soʻm yechilsinmi?`)} onConfirm={() => pay.mutate(r.id)}>
                  <Button size="small" type="primary" loading={pay.isPending}>
                    {tr('Оплатить с баланса', 'Balansdan toʻlash')}
                  </Button>
                </Popconfirm>
              ),
          },
        ]}
      />
    </>
  )
}
