// Отчёты: денежный поток и прибыль/убыток.
import { useState, type ReactNode } from 'react'
import { Alert, Card, Col, Descriptions, Row, Select, Space, Statistic, Table, Typography } from 'antd'
import { PageTitle, date, errorText, money, periodParams, useItem } from '@sm/shared'
import dayjs from 'dayjs'
import { useStore } from '../ctx'
import { RangeFilter, thisMonth, type Range } from '../ui'
import type { CashFlow, CashboxFlow, ProfitLoss, ReasonAmount } from '../types'

/** Фильтры отчёта: период и магазин ('' — вся сеть). */
function useReportFilters() {
  const { storeId, stores, me } = useStore()
  const [range, setRange] = useState<Range | null>(thisMonth)
  const [store, setStore] = useState<string>(me?.all_stores ? '' : storeId)
  const params = { ...periodParams(range), store_id: store || undefined }
  const filters = (
    <>
      <RangeFilter value={range} onChange={setRange} />
      <Select
        value={store}
        onChange={setStore}
        style={{ minWidth: 200 }}
        options={[
          ...(me?.all_stores ? [{ value: '', label: 'Вся сеть' }] : []),
          ...stores.map((s) => ({ value: s.id, label: s.name })),
        ]}
      />
    </>
  )
  return { params, filters }
}

function Period({ from, to }: { from: string; to: string }) {
  // to не включается — показываем последний день периода.
  return (
    <Typography.Text type="secondary">
      Период: {date(from)} — {date(dayjs(to).subtract(1, 'second').toISOString())}
    </Typography.Text>
  )
}

export function CashFlowPage() {
  const { params, filters } = useReportFilters()
  const { data, isLoading, error } = useItem<CashFlow>('/store/reports/cash-flow', params)
  const currencies = [...new Set((data?.lines ?? []).map((l) => l.currency).concat((data?.cashboxes ?? []).map((c) => c.currency)))]

  return (
    <>
      <PageTitle title="Денежный поток">{filters}</PageTitle>
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
          <Card key={cur} title={`Валюта: ${cur}`} style={{ marginBottom: 16 }} loading={isLoading}>
            <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
              <Col xs={12} md={6}>
                <Statistic title="На начало" value={money(t('opening'))} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title="Приход" value={money(t('income'))} valueStyle={{ color: '#16a34a' }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title="Расход" value={money(t('expense'))} valueStyle={{ color: '#dc2626' }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title="На конец" value={money(t('closing'))} />
              </Col>
            </Row>
            <Row gutter={[16, 16]}>
              <Col xs={24} xl={12}>
                <Typography.Title level={5}>По кассам</Typography.Title>
                <Table<CashboxFlow>
                  rowKey="id"
                  size="small"
                  pagination={false}
                  dataSource={boxes}
                  scroll={{ x: true }}
                  columns={[
                    { title: 'Касса', dataIndex: 'name' },
                    { title: 'Начало', dataIndex: 'opening', align: 'right', render: (v) => money(v) },
                    { title: 'Приход', dataIndex: 'income', align: 'right', render: (v) => money(v) },
                    { title: 'Расход', dataIndex: 'expense', align: 'right', render: (v) => money(v) },
                    { title: 'Конец', dataIndex: 'closing', align: 'right', render: (v) => <b>{money(v)}</b> },
                  ]}
                />
              </Col>
              <Col xs={24} xl={12}>
                <Typography.Title level={5}>По статьям</Typography.Title>
                <Table
                  rowKey={(r) => r.category}
                  size="small"
                  pagination={false}
                  dataSource={lines}
                  scroll={{ x: true }}
                  locale={{ emptyText: 'Движений нет' }}
                  columns={[
                    { title: 'Статья', dataIndex: 'title' },
                    { title: 'Приход', dataIndex: 'income', align: 'right', render: (v: string) => (Number(v) ? money(v) : '—') },
                    { title: 'Расход', dataIndex: 'expense', align: 'right', render: (v: string) => (Number(v) ? money(v) : '—') },
                  ]}
                />
              </Col>
            </Row>
          </Card>
        )
      })}
      {data && currencies.length === 0 && <Alert type="info" showIcon message="Касс в выбранной области нет" />}
    </>
  )
}

function Amount({ v, strong, negative }: { v: string | number; strong?: boolean; negative?: boolean }) {
  const n = Number(v)
  const text = (negative && n ? '− ' : '') + money(v)
  return strong ? <b>{text}</b> : <>{text}</>
}

function ReasonList({ items, negative }: { items: ReasonAmount[] | null; negative?: boolean }) {
  if (!items?.length) return <Typography.Text type="secondary">нет</Typography.Text>
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
  const color = (v: string | undefined) => (Number(v) < 0 ? '#dc2626' : '#16a34a')
  const otherIncome = (d?.other_income ?? []).reduce((s, r) => s + Number(r.amount), 0)
  const expenses = (d?.expenses ?? []).reduce((s, r) => s + Number(r.amount), 0)

  return (
    <>
      <PageTitle title="Прибыль и убыток">{filters}</PageTitle>
      {error && <Alert type="error" showIcon message={errorText(error)} style={{ marginBottom: 16 }} />}
      <Card loading={isLoading} style={{ marginBottom: 16 }}>
        {d && (
          <>
            <div style={{ marginBottom: 12 }}>
              <Period from={d.from} to={d.to} />
            </div>
            <Row gutter={[16, 16]}>
              <Col xs={12} md={6}>
                <Statistic title="Выручка, сум" value={money(d.revenue.total)} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title="Валовая прибыль" value={money(d.gross_profit)} valueStyle={{ color: color(d.gross_profit) }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title="Чистая прибыль" value={money(d.net_profit)} valueStyle={{ color: color(d.net_profit) }} />
              </Col>
              <Col xs={12} md={6}>
                <Statistic title="Чеков / заказов" value={`${d.sales_count} / ${d.orders_count}`} />
              </Col>
            </Row>
          </>
        )}
      </Card>
      {d && (
        <Row gutter={[16, 16]}>
          <Col xs={24} lg={12}>
            <Card title="Выручка и себестоимость">
              <Descriptions column={1} size="small" bordered styles={{ label: { width: '55%' } }}>
                {row('Продажи POS', d.revenue.pos_sales)}
                {row('Возвраты покупателей', d.revenue.customer_returns, { negative: true })}
                {row('Онлайн-заказы', d.revenue.online_orders)}
                {row('Доставка', d.revenue.delivery_fees)}
                {row(<b>Выручка</b>, d.revenue.total, { strong: true })}
                {row('Себестоимость POS', d.cost_of_goods.pos, { negative: true })}
                {row('Себестоимость возвратов (уменьшает)', d.cost_of_goods.returns)}
                {row('Себестоимость онлайн', d.cost_of_goods.online, { negative: true })}
                {row(<b>Себестоимость (FIFO)</b>, d.cost_of_goods.total, { strong: true, negative: true })}
                {row(<b>Валовая прибыль</b>, d.gross_profit, { strong: true })}
              </Descriptions>
            </Card>
          </Col>
          <Col xs={24} lg={12}>
            <Card title="Прочие статьи">
              <Descriptions column={1} size="small" bordered styles={{ label: { width: '55%' } }}>
                {row('Списания', d.stock_adjustments.write_offs, { negative: true })}
                {row('Недостача (инвентаризация)', d.stock_adjustments.inventory_shortage, { negative: true })}
                {row('Излишки (инвентаризация)', d.stock_adjustments.inventory_surplus)}
                {row(<b>Итого по складу</b>, d.stock_adjustments.total, { strong: true })}
                <Descriptions.Item label={`Прочие доходы (${money(otherIncome)})`}>
                  <ReasonList items={d.other_income} />
                </Descriptions.Item>
                <Descriptions.Item label={`Расходы (${money(expenses)})`}>
                  <ReasonList items={d.expenses} negative />
                </Descriptions.Item>
                {row('Подписка платформы', d.platform_subscription, { negative: true })}
                <Descriptions.Item label={<b>Чистая прибыль</b>}>
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
