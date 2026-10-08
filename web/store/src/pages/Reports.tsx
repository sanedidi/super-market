// Отчёты: денежный поток и прибыль/убыток.
import { useState, type ReactNode } from 'react'
import { Alert, Card, Col, Descriptions, Row, Select, Space, Statistic, Table, Typography } from 'antd'
import { PageTitle, date, errorText, money, periodParams, tr, useItem } from '@sm/shared'
import dayjs from 'dayjs'
import { useStore } from '../ctx'
import { RangeFilter, thisMonth, type Range } from '../ui'
import type { CashFlow, CashboxFlow, ProfitLoss, ReasonAmount } from '../types'

/** Фильтры отчёта: период и магазин ('' — вся сеть). */
export function useReportFilters(initial: () => Range = thisMonth) {
  const { storeId, stores, me } = useStore()
  const [range, setRange] = useState<Range | null>(initial)
  const seesAll = !!me && (me.is_owner || me.all_stores)
  // Пока пользователь сам не выбрал — вся сеть (если доступна) или текущий магазин;
  // значение вычисляется, поэтому подхватывает /store/me и магазины после загрузки.
  const [picked, setPicked] = useState<string | null>(null)
  const store = picked ?? (seesAll ? '' : storeId)
  const setStore = setPicked
  const params = { ...periodParams(range), store_id: store || undefined }
  const filters = (
    <>
      <RangeFilter value={range} onChange={setRange} />
      <Select
        value={store}
        onChange={setStore}
        style={{ minWidth: 200 }}
        options={[
          ...(seesAll ? [{ value: '', label: tr('Вся сеть', 'Butun tarmoq') }] : []),
          ...stores.map((s) => ({ value: s.id, label: s.name })),
        ]}
      />
    </>
  )
  return { params, filters, range }
}

function Period({ from, to }: { from: string; to: string }) {
  // to не включается — показываем последний день периода.
  return (
    <Typography.Text type="secondary">
      {tr('Период:', 'Davr:')} {date(from)} — {date(dayjs(to).subtract(1, 'second').toISOString())}
    </Typography.Text>
  )
}

export function CashFlowPage() {
  const { params, filters } = useReportFilters()
  const { data, isLoading, error } = useItem<CashFlow>('/store/reports/cash-flow', params)
  const currencies = [...new Set((data?.lines ?? []).map((l) => l.currency).concat((data?.cashboxes ?? []).map((c) => c.currency)))]

  return (
    <>
      <PageTitle title={tr('Денежный поток', 'Pul oqimi')}>{filters}</PageTitle>
      {error && <Alert type="error" showIcon message={errorText(error)} style={{ marginBottom: 16 }} />}
      {data && (
        <div style={{ marginBottom: 12 }}>
          <Period from={data.from} to={data.to} />
        </div>
      )}
      {currencies.map((cur) => {
        const boxes = (data?.cashboxes ?? []).filter((c) => c.currency === cur)
        const lines = (data?.lines ?? []).filter((l) => l.currency === cur)
        const t = (k: keyof CashboxFlow) => boxes.reduce((s, b) => s + Number(b[k] ?? 0), 0)
        return (
          <Card key={cur} title={tr(`Валюта: ${cur}`, `Valyuta: ${cur}`)} style={{ marginBottom: 16 }} loading={isLoading}>
            <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
              <Col xs={12} md={6}>
                <Statistic title={tr('На начало', 'Davr boshida')} value={money(t('opening'))} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title={tr('Приход', 'Kirim')} value={money(t('income'))} valueStyle={{ color: '#17b26a' }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title={tr('Расход', 'Chiqim')} value={money(t('expense'))} valueStyle={{ color: '#b3261e' }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title={tr('На конец', 'Davr oxirida')} value={money(t('closing'))} />
              </Col>
            </Row>
            <Row gutter={[16, 16]}>
              <Col xs={24} xl={12}>
                <Typography.Title level={5}>{tr('По кассам', 'Kassalar boʻyicha')}</Typography.Title>
                <Table<CashboxFlow>
                  rowKey="id"
                  size="small"
                  pagination={false}
                  dataSource={boxes}
                  scroll={{ x: true }}
                  columns={[
                    { title: tr('Касса', 'Kassa'), dataIndex: 'name' },
                    { title: tr('Начало', 'Boshida'), dataIndex: 'opening', align: 'right', render: (v) => money(v) },
                    { title: tr('Приход', 'Kirim'), dataIndex: 'income', align: 'right', render: (v) => money(v) },
                    { title: tr('Расход', 'Chiqim'), dataIndex: 'expense', align: 'right', render: (v) => money(v) },
                    { title: tr('Конец', 'Oxirida'), dataIndex: 'closing', align: 'right', render: (v) => <b>{money(v)}</b> },
                  ]}
                />
              </Col>
              <Col xs={24} xl={12}>
                <Typography.Title level={5}>{tr('По статьям', 'Moddalar boʻyicha')}</Typography.Title>
                <Table
                  rowKey={(r) => r.category}
                  size="small"
                  pagination={false}
                  dataSource={lines}
                  scroll={{ x: true }}
                  locale={{ emptyText: tr('Движений нет', 'Harakatlar yoʻq') }}
                  columns={[
                    { title: tr('Статья', 'Modda'), dataIndex: 'title' },
                    { title: tr('Приход', 'Kirim'), dataIndex: 'income', align: 'right', render: (v: string) => (Number(v) ? money(v) : '—') },
                    { title: tr('Расход', 'Chiqim'), dataIndex: 'expense', align: 'right', render: (v: string) => (Number(v) ? money(v) : '—') },
                  ]}
                />
              </Col>
            </Row>
          </Card>
        )
      })}
      {data && currencies.length === 0 && <Alert type="info" showIcon message={tr('Касс в выбранной области нет', 'Tanlangan doirada kassalar yoʻq')} />}
    </>
  )
}

function Amount({ v, strong, negative }: { v: string | number; strong?: boolean; negative?: boolean }) {
  const n = Number(v)
  const text = (negative && n ? '− ' : '') + money(v)
  return strong ? <b>{text}</b> : <>{text}</>
}

function ReasonList({ items, negative }: { items: ReasonAmount[] | null; negative?: boolean }) {
  if (!items?.length) return <Typography.Text type="secondary">{tr('нет', 'yoʻq')}</Typography.Text>
  return (
    <Space direction="vertical" size={2} style={{ width: '100%' }}>
      {items.map((r) => (
        <Space key={r.reason_id} style={{ width: '100%', justifyContent: 'space-between' }}>
          <span>{r.name}</span>
          <Amount v={r.amount} negative={negative} />
        </Space>
      ))}
    </Space>
  )
}

export function ProfitLossPage() {
  const { params, filters } = useReportFilters()
  const { data: d, isLoading, error } = useItem<ProfitLoss>('/store/reports/profit-loss', params)
  const row = (label: ReactNode, v: string, opts: { negative?: boolean; strong?: boolean } = {}) => (
    <Descriptions.Item label={label}>
      <Amount v={v} {...opts} />
    </Descriptions.Item>
  )
  const color = (v: string | undefined) => (Number(v) < 0 ? '#b3261e' : '#17b26a')
  const otherIncome = (d?.other_income ?? []).reduce((s, r) => s + Number(r.amount), 0)
  const expenses = (d?.expenses ?? []).reduce((s, r) => s + Number(r.amount), 0)

  return (
    <>
      <PageTitle title={tr('Прибыль и убыток', 'Foyda va zarar')}>{filters}</PageTitle>
      {error && <Alert type="error" showIcon message={errorText(error)} style={{ marginBottom: 16 }} />}
      <Card loading={isLoading} style={{ marginBottom: 16 }}>
        {d && (
          <>
            <div style={{ marginBottom: 12 }}>
              <Period from={d.from} to={d.to} />
            </div>
            <Row gutter={[16, 16]}>
              <Col xs={12} md={6}>
                <Statistic title={tr('Выручка, сум', 'Tushum, soʻm')} value={money(d.revenue.total)} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title={tr('Валовая прибыль', 'Yalpi foyda')} value={money(d.gross_profit)} valueStyle={{ color: color(d.gross_profit) }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title={tr('Чистая прибыль', 'Sof foyda')} value={money(d.net_profit)} valueStyle={{ color: color(d.net_profit) }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title={tr('Чеков / заказов', 'Cheklar / buyurtmalar')} value={`${d.sales_count} / ${d.orders_count}`} />
              </Col>
            </Row>
          </>
        )}
      </Card>
      {d && (
        <Row gutter={[16, 16]}>
          <Col xs={24} lg={12}>
            <Card title={tr('Выручка и себестоимость', 'Tushum va tannarx')}>
              <Descriptions column={1} size="small" bordered styles={{ label: { width: '55%' } }}>
                {row(tr('Продажи POS', 'POS sotuvlari'), d.revenue.pos_sales)}
                {row(tr('Возвраты покупателей', 'Xaridorlardan qaytarishlar'), d.revenue.customer_returns, { negative: true })}
                {row(tr('Онлайн-заказы', 'Onlayn buyurtmalar'), d.revenue.online_orders)}
                {row(tr('Доставка', 'Yetkazib berish'), d.revenue.delivery_fees)}
                {row(<b>{tr('Выручка', 'Tushum')}</b>, d.revenue.total, { strong: true })}
                {row(tr('Себестоимость POS', 'POS tannarxi'), d.cost_of_goods.pos, { negative: true })}
                {row(tr('Себестоимость возвратов (уменьшает)', 'Qaytarishlar tannarxi (kamaytiradi)'), d.cost_of_goods.returns)}
                {row(tr('Себестоимость онлайн', 'Onlayn tannarx'), d.cost_of_goods.online, { negative: true })}
                {row(<b>{tr('Себестоимость (FIFO)', 'Tannarx (FIFO)')}</b>, d.cost_of_goods.total, { strong: true, negative: true })}
                {row(<b>{tr('Валовая прибыль', 'Yalpi foyda')}</b>, d.gross_profit, { strong: true })}
              </Descriptions>
            </Card>
          </Col>
          <Col xs={24} lg={12}>
            <Card title={tr('Прочие статьи', 'Boshqa moddalar')}>
              <Descriptions column={1} size="small" bordered styles={{ label: { width: '55%' } }}>
                {row(tr('Списания', 'Hisobdan chiqarishlar'), d.stock_adjustments.write_offs, { negative: true })}
                {row(tr('Недостача (инвентаризация)', 'Kamomad (inventarizatsiya)'), d.stock_adjustments.inventory_shortage, { negative: true })}
                {row(tr('Излишки (инвентаризация)', 'Ortiqcha (inventarizatsiya)'), d.stock_adjustments.inventory_surplus)}
                {row(<b>{tr('Итого по складу', 'Ombor boʻyicha jami')}</b>, d.stock_adjustments.total, { strong: true })}
                <Descriptions.Item label={tr(`Прочие доходы (${money(otherIncome)})`, `Boshqa daromadlar (${money(otherIncome)})`)}>
                  <ReasonList items={d.other_income} />
                </Descriptions.Item>
                <Descriptions.Item label={tr(`Расходы (${money(expenses)})`, `Xarajatlar (${money(expenses)})`)}>
                  <ReasonList items={d.expenses} negative />
                </Descriptions.Item>
                {row(tr('Подписка платформы', 'Platforma obunasi'), d.platform_subscription, { negative: true })}
                <Descriptions.Item label={<b>{tr('Чистая прибыль', 'Sof foyda')}</b>}>
                  <b style={{ color: color(d.net_profit) }}>{money(d.net_profit)}</b>
                </Descriptions.Item>
              </Descriptions>
            </Card>
          </Col>
        </Row>
      )}
    </>
  )
}
