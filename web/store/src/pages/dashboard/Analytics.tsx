// Главная для владельца и всех с правом «Отчёты»: выручка, прибыль и графики.
// Дизайн: Figma «Super Market» → «Веб-панели» → «Панель магазина · главная с дашбордами».
import { useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Alert, Button, Card, Col, Empty, Row, Skeleton, Table, Typography } from 'antd'
import {
  AccountBookOutlined,
  ArrowLeftOutlined,
  ArrowRightOutlined,
  ClockCircleOutlined,
  DeleteOutlined,
  DollarOutlined,
  FileDoneOutlined,
  HourglassOutlined,
  InboxOutlined,
  LineChartOutlined,
  RiseOutlined,
  ShoppingOutlined,
  TeamOutlined,
  WalletOutlined,
} from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { StatusTag, dateTime, money, qty, useItem } from '@sm/shared'
import { useStore } from '../../ctx'
import { usePaidOrders } from '../../notify'
import type { AbcLetter, AbcXyz, Balance, FiscalSummary, Order, SalesBreakdown, SalesSeries } from '../../types'
import { CELL, GROUP, LOW_DAYS, TONE } from '../AbcXyz'
import { C, DayLines, Donut, HeatLegend, Heatmap, Legend, Pareto, Sparkline, StackedBars, short, type Bucket } from './charts'

export type Period = 'today' | 'yesterday' | '7d' | '30d'

export const PERIODS: { value: Period; label: string }[] = [
  { value: 'today', label: 'Сегодня' },
  { value: 'yesterday', label: 'Вчера' },
  { value: '7d', label: '7 дней' },
  { value: '30d', label: '30 дней' },
]

const fmt = (d: Dayjs) => d.format('YYYY-MM-DD')
const n = (v: string | number | null | undefined) => Number(v ?? 0) || 0

// «прошлая среда», «прошлый четверг» — с чем сравниваем «сегодня».
const LAST_WEEKDAY = ['прошлое воскресенье', 'прошлый понедельник', 'прошлый вторник', 'прошлая среда', 'прошлый четверг', 'прошлая пятница', 'прошлая суббота']
const LAST_WEEKDAY_TO = ['прошлому воскресенью', 'прошлому понедельнику', 'прошлому вторнику', 'прошлой среде', 'прошлому четвергу', 'прошлой пятнице', 'прошлой субботе']
const WEEKDAY = ['', 'понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье']

function periodQuery(p: Period) {
  const t = dayjs().startOf('day')
  switch (p) {
    case 'today':
      return { from: fmt(t), to: fmt(t.add(1, 'day')), bucket: 'hour', compare: 'week' }
    case 'yesterday':
      return { from: fmt(t.subtract(1, 'day')), to: fmt(t), bucket: 'hour', compare: 'week' }
    case '7d':
      return { from: fmt(t.subtract(6, 'day')), to: fmt(t.add(1, 'day')), bucket: 'day', compare: 'prev' }
    case '30d':
      return { from: fmt(t.subtract(29, 'day')), to: fmt(t.add(1, 'day')), bucket: 'day', compare: 'prev' }
  }
}

/** «к прошлой среде», «к прошлым 7 дням». */
function prevTo(p: Period) {
  if (p === 'today') return 'к ' + LAST_WEEKDAY_TO[dayjs().day()]
  if (p === 'yesterday') return 'к ' + LAST_WEEKDAY_TO[dayjs().subtract(1, 'day').day()]
  return p === '7d' ? 'к прошлым 7 дням' : 'к прошлым 30 дням'
}

function prevName(p: Period) {
  if (p === 'today') return LAST_WEEKDAY[dayjs().day()]
  if (p === 'yesterday') return LAST_WEEKDAY[dayjs().subtract(1, 'day').day()]
  return p === '7d' ? 'прошлые 7 дней' : 'прошлые 30 дней'
}
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1)

function changePct(cur: number, prev: number): number | null {
  return prev > 0 ? ((cur - prev) / prev) * 100 : null
}

function plural(k: number, one: string, few: string, many: string) {
  const m10 = k % 10
  const m100 = k % 100
  return m10 === 1 && m100 !== 11 ? one : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? few : many
}
const products = (k: number) => `${k} ${plural(k, 'товар', 'товара', 'товаров')}`

// ---------------------------------------------------------------- общее

const cardBody: CSSProperties = { padding: 20 }

function Head({ title, sub, extra }: { title: ReactNode; sub?: ReactNode; extra?: ReactNode }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, marginBottom: 14 }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 16, fontWeight: 800, color: C.text }}>{title}</div>
        {sub && <div style={{ fontSize: 12, color: C.muted, marginTop: 2 }}>{sub}</div>}
      </div>
      {extra}
    </div>
  )
}

function Delta({ v, invert = false }: { v: number | null | undefined; invert?: boolean }) {
  if (v === null || v === undefined || !Number.isFinite(v)) return null
  const up = v >= 0
  const good = invert ? !up : up
  return (
    <span
      style={{
        display: 'inline-block',
        padding: '1px 7px',
        borderRadius: 999,
        fontSize: 12,
        fontWeight: 700,
        background: good ? '#ecfdf3' : '#fef3f2',
        color: good ? '#079455' : '#d92d20',
        whiteSpace: 'nowrap',
      }}
    >
      {up ? '▲' : '▼'} {Math.abs(v).toLocaleString('ru-RU', { maximumFractionDigits: Math.abs(v) < 10 ? 1 : 0 })}%
    </span>
  )
}

function LinkText({ to, children }: { to: string; children: ReactNode }) {
  return (
    <Link to={to} style={{ fontSize: 13, fontWeight: 700, color: C.now, whiteSpace: 'nowrap' }}>
      {children} →
    </Link>
  )
}

// ---------------------------------------------------------------- страница

export function Analytics({ period }: { period: Period }) {
  const { storeId, can } = useStore()
  const q = periodQuery(period)
  const series = useItem<SalesSeries>('/store/reports/sales-series', { store_id: storeId, ...q })
  const t = dayjs().startOf('day')
  // Мини-графики — всегда 14 дней по дням.
  const spark = useItem<SalesSeries>('/store/reports/sales-series', { store_id: storeId, bucket: 'day', from: fmt(t.subtract(13, 'day')), to: fmt(t.add(1, 'day')) })
  const pn = prevName(period)

  return (
    <>
      <Kpis period={period} series={series.data} loading={series.isLoading} spark={spark.data} />
      <Row gutter={[16, 16]} style={{ marginTop: 16 }}>
        <Col xs={24} xl={16}>
          <TimeCard period={period} data={series.data} loading={series.isLoading} prevName={pn} />
        </Col>
        <Col xs={24} xl={8}>
          <TopProducts period={period} />
        </Col>
        <Col xs={24} xl={16}>
          <Month />
        </Col>
        <Col xs={24} xl={8}>
          <Payments period={period} />
        </Col>
        <Col xs={24} xl={10}>
          <Categories />
        </Col>
        <Col xs={24} xl={14}>
          <WhenBuy />
        </Col>
        <Col span={24}>
          <AbcBlock />
        </Col>
        {can('orders.manage') && (
          <Col xs={24} xl={16}>
            <NewOrders />
          </Col>
        )}
        <Col xs={24} xl={can('orders.manage') ? 8 : 24}>
          <Row gutter={[16, 16]}>
            <Col span={24}>
              <Fiscal />
            </Col>
            {can('debts.manage') && (
              <Col span={24}>
                <DebtsCard />
              </Col>
            )}
          </Row>
        </Col>
      </Row>
    </>
  )
}

/** Подпись справа от периода: когда обновлено и с чем сравниваем. */
export function PeriodNote({ period }: { period: Period }) {
  return (
    <Typography.Text type="secondary" style={{ fontSize: 13 }}>
      Обновлено в {dayjs().format('HH:mm')} · сравнение: {prevName(period)}
      {period === 'today' && ' до того же часа'}
    </Typography.Text>
  )
}

// ---------------------------------------------------------------- карточки

function Kpis({ period, series, loading, spark }: { period: Period; series?: SalesSeries; loading: boolean; spark?: SalesSeries }) {
  const { can } = useStore()
  const nav = useNavigate()
  const orders = usePaidOrders()
  const balance = useItem<Balance>(can('payouts.manage') ? '/store/balance' : null)
  const tt = series?.totals
  const pt = series?.prev_totals
  const sp = spark?.points ?? []
  const fresh = orders.data?.length ?? 0
  const tiles: ReactNode[] = [
    <Kpi
      key="rev"
      icon={<DollarOutlined />}
      title="Выручка, сум"
      value={money(tt?.revenue)}
      delta={series?.change_pct}
      note={prevTo(period)}
      spark={<Sparkline values={sp.map((p) => n(p.revenue))} color={C.pos} />}
      loading={loading}
      onClick={() => nav('/reports/profit-loss')}
    />,
    <Kpi
      key="profit"
      icon={<RiseOutlined />}
      title="Валовая прибыль, сум"
      value={money(tt?.profit)}
      delta={tt && pt ? changePct(n(tt.profit), n(pt.profit)) : null}
      note={tt?.margin_pct != null ? `маржа ${tt.margin_pct.toLocaleString('ru-RU', { maximumFractionDigits: 1 })}%` : 'маржа —'}
      spark={<Sparkline values={sp.map((p) => n(p.profit))} color={C.profit} />}
      loading={loading}
      onClick={() => nav('/reports/profit-loss')}
    />,
    <Kpi
      key="checks"
      icon={<FileDoneOutlined />}
      title="Чеков"
      value={String(tt?.checks ?? 0)}
      delta={tt && pt ? changePct(tt.checks, pt.checks) : null}
      note={`средний чек ${money(tt?.avg_check)} сум`}
      spark={<Sparkline values={sp.map((p) => p.checks)} color={C.pos} />}
      loading={loading}
      onClick={() => nav('/sales/pos')}
    />,
  ]
  if (can('orders.manage'))
    tiles.push(
      <Kpi
        key="orders"
        icon={<ShoppingOutlined />}
        title="Онлайн-заказы"
        value={String(tt?.orders ?? 0)}
        warn={fresh > 0}
        badge={fresh > 0 ? `${fresh} ${plural(fresh, 'новый', 'новых', 'новых')}` : undefined}
        note={fresh > 0 ? 'ждут сборки' : `доставлено на ${money(tt?.online)} сум`}
        spark={<Sparkline values={sp.map((p) => p.orders)} color="#eb6834" />}
        loading={loading}
        onClick={() => nav('/orders')}
      />,
    )
  if (can('payouts.manage'))
    tiles.push(
      <Kpi
        key="balance"
        icon={<WalletOutlined />}
        title="Баланс к выводу, сум"
        value={money(balance.data?.available)}
        note={`ожидает ${money(balance.data?.pending)}${balance.data?.next_payout_at ? ' · вывод ' + dayjs(balance.data.next_payout_at).format('D MMM') : ''}`}
        loading={balance.isLoading}
        onClick={() => nav('/balance')}
      />,
    )
  return <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(210px, 1fr))', gap: 16 }}>{tiles}</div>
}

function Kpi(p: {
  icon: ReactNode
  title: string
  value: string
  delta?: number | null
  badge?: string
  note: string
  spark?: ReactNode
  loading: boolean
  warn?: boolean
  onClick: () => void
}) {
  return (
    <Card hoverable onClick={p.onClick} style={{ borderColor: p.warn ? '#fec84b' : undefined }} styles={{ body: { padding: 18 } }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, color: C.muted, fontSize: 13, fontWeight: 600 }}>
        <span style={{ width: 26, height: 26, borderRadius: 8, display: 'grid', placeItems: 'center', background: p.warn ? '#fffaeb' : '#f2f4f7', color: p.warn ? '#b54708' : '#475467' }}>
          {p.icon}
        </span>
        {p.title}
      </div>
      {p.loading ? (
        <Skeleton active paragraph={{ rows: 1 }} title={false} style={{ marginTop: 10 }} />
      ) : (
        <>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
            <span style={{ fontSize: 24, fontWeight: 800, color: p.warn ? '#b54708' : C.text, lineHeight: 1.2 }}>{p.value}</span>
            <Delta v={p.delta} />
            {p.badge && <span style={{ padding: '1px 7px', borderRadius: 999, fontSize: 12, fontWeight: 700, background: '#fffaeb', color: '#b54708' }}>{p.badge}</span>}
          </div>
          <div style={{ fontSize: 12, color: C.muted, margin: '2px 0 8px' }}>{p.note}</div>
          {p.spark}
          {p.spark && <div style={{ fontSize: 10, color: C.faint, marginTop: 2 }}>14 дней</div>}
        </>
      )}
    </Card>
  )
}

function TimeCard({ period, data, loading, prevName: pn }: { period: Period; data?: SalesSeries; loading: boolean; prevName: string }) {
  const hourly = period === 'today' || period === 'yesterday'
  // По часам — только рабочие часы: с 8 до 22 или шире, если продажи были раньше или позже.
  const [lo, hi] = useMemo(() => {
    if (!hourly || !data) return [0, Infinity]
    const busy = [data.points, data.prev ?? []].flatMap((l) => l.flatMap((p, i) => (n(p.revenue) !== 0 ? [i] : [])))
    return [Math.min(8, ...busy), Math.max(22, ...busy)]
  }, [hourly, data])
  // Прошлый отрезок подписываем текущими датами: подписи и подсказки идут по текущему.
  const unit = hourly ? 'hour' : 'day'
  const allPrev = (data?.prev ?? []).map((p, i) => ({ ...p, at: dayjs(data?.from).add(i, unit).toISOString() }))
  const points = (data?.points ?? []).filter((_, i) => i >= lo && i <= hi)
  const prev = allPrev.filter((_, i) => i >= lo && i <= hi)
  const label = (p: Bucket, i: number) => {
    if (hourly) {
      const h = dayjs(p.at).hour()
      return h % 3 === 0 ? `${h}:00` : null
    }
    const every = period === '30d' ? 5 : 1
    const last = (prev.length || points.length) - 1
    return i % every === 0 || i === last ? dayjs(p.at).format('D MMM') : null
  }
  const title = hourly ? 'Выручка по часам' : 'Выручка по дням'
  return (
    <Card style={{ height: '100%' }} styles={{ body: cardBody }}>
      <Head
        title={title}
        sub="Наведите на столбец — суммы и сравнение"
        extra={
          <Legend
            items={[
              { color: C.pos, label: `Касса · ${money(data?.totals.pos)}` },
              { color: C.online, label: `Онлайн · ${money(data?.totals.online)}` },
              { color: C.prev, label: cap(pn), dashed: true },
            ]}
          />
        }
      />
      {loading ? (
        <Skeleton active paragraph={{ rows: 6 }} title={false} />
      ) : (
        <StackedBars
          points={points}
          prev={prev}
          label={label}
          prevName={cap(pn)}
          tipTitle={(p) => (hourly ? `${dayjs(p.at).hour()}:00–${dayjs(p.at).hour() + 1}:00` : dayjs(p.at).format('D MMMM, dd'))}
          nowIndex={period === 'yesterday' ? undefined : points.length - 1}
        />
      )}
    </Card>
  )
}

function TopProducts({ period }: { period: Period }) {
  const { storeId } = useStore()
  const q = periodQuery(period)
  const { data, isLoading } = useItem<SalesBreakdown>('/store/reports/sales-breakdown', { store_id: storeId, by: 'product', limit: 5, from: q.from, to: q.to })
  const items = data?.items ?? []
  const top = n(items[0]?.value)
  const title = { today: 'Топ-5 товаров сегодня', yesterday: 'Топ-5 товаров вчера', '7d': 'Топ-5 товаров за 7 дней', '30d': 'Топ-5 товаров за 30 дней' }[period]
  return (
    <Card style={{ height: '100%' }} styles={{ body: cardBody }}>
      <Head title={title} extra={<LinkText to="/sales/pos">Все продажи</LinkText>} />
      {isLoading ? (
        <Skeleton active />
      ) : items.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="Продаж пока нет" />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          {items.map((it, i) => (
            <div key={it.key} style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <span style={{ width: 30, height: 30, flex: 'none', borderRadius: 8, background: '#f2f4f7', display: 'grid', placeItems: 'center', fontWeight: 800, color: '#475467' }}>{i + 1}</span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', gap: 8 }}>
                  <span style={{ flex: 1, minWidth: 0, fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{it.name}</span>
                  <b>{money(it.value)}</b>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 4 }}>
                  <span style={{ fontSize: 11, color: C.muted, whiteSpace: 'nowrap' }}>{qty(it.qty, it.unit ?? '')}</span>
                  <span style={{ flex: 1, height: 6, background: '#f2f4f7', borderRadius: 3 }}>
                    <span style={{ display: 'block', height: 6, borderRadius: 3, background: C.pos, width: `${top ? Math.max(4, (n(it.value) / top) * 100) : 0}%` }} />
                  </span>
                  <span style={{ fontSize: 11, color: C.muted }}>{it.share.toLocaleString('ru-RU', { maximumFractionDigits: 1 })}%</span>
                </div>
              </div>
            </div>
          ))}
          <div style={{ fontSize: 11, color: C.faint }}>% — доля в выручке за период</div>
        </div>
      )}
    </Card>
  )
}

function Month() {
  const { storeId } = useStore()
  const t = dayjs().startOf('day')
  const { data, isLoading } = useItem<SalesSeries>('/store/reports/sales-series', {
    store_id: storeId,
    bucket: 'day',
    compare: 'prev',
    from: fmt(t.subtract(29, 'day')),
    to: fmt(t.add(1, 'day')),
  })
  const pts = data?.points ?? []
  const dates = (data?.prev ?? pts).map((_, i) => dayjs(data?.from).add(i, 'day').format('D MMM'))
  const rev = pts.map((p) => n(p.revenue))
  const prof = pts.map((p) => n(p.profit))
  const prev = (data?.prev ?? []).map((p) => n(p.revenue))
  // Сегодняшний день ещё идёт — дотягиваем линии до конца нулями не будем: точек меньше дат на 0.
  return (
    <Card style={{ height: '100%' }} styles={{ body: cardBody }}>
      <Head
        title="Выручка и прибыль · 30 дней"
        sub={
          data && (
            <span style={{ display: 'inline-flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
              <span style={{ fontSize: 20, fontWeight: 800, color: C.text }}>{short(n(data.totals.revenue))} сум</span>
              <Delta v={data.change_pct} />
              <span>
                прибыль {short(n(data.totals.profit))}
                {data.totals.margin_pct != null && ` · маржа ${Math.round(data.totals.margin_pct)}%`}
              </span>
            </span>
          )
        }
        extra={<LinkText to="/reports/profit-loss">Прибыль и убыток</LinkText>}
      />
      <div style={{ marginBottom: 10 }}>
        <Legend
          items={[
            { color: C.pos, label: 'Выручка' },
            { color: C.profit, label: 'Прибыль' },
            { color: C.prev, label: 'Прошлые 30 дней', dashed: true },
          ]}
        />
      </div>
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 6 }} title={false} />
      ) : (
        <DayLines
          series={[
            { name: 'Выручка', color: C.pos, values: rev },
            { name: 'Прибыль', color: C.profit, values: prof },
          ]}
          prev={prev.slice(0, rev.length)}
          dates={dates.slice(0, rev.length)}
          prevName="30 дней назад"
        />
      )}
    </Card>
  )
}

const isCash = (name: string) => /налич/i.test(name)

function Payments({ period }: { period: Period }) {
  const { storeId } = useStore()
  const q = periodQuery(period)
  const { data, isLoading } = useItem<SalesBreakdown>('/store/reports/sales-breakdown', { store_id: storeId, by: 'payment', compare: q.compare, from: q.from, to: q.to })
  // Порядок цветов фиксирован по способу, а не по месту в списке.
  const items = useMemo(() => [...(data?.items ?? [])].sort((a, b) => a.key.localeCompare(b.key)), [data])
  const colorOf = (i: number) => C.cats[i % C.cats.length]
  const total = n(data?.total)
  const nonCash = (vals: { name: string; v: number }[]) => {
    const all = vals.reduce((s, x) => s + x.v, 0)
    return all > 0 ? Math.round((vals.filter((x) => !isCash(x.name)).reduce((s, x) => s + x.v, 0) / all) * 100) : null
  }
  const cur = nonCash(items.map((i) => ({ name: i.name, v: n(i.value) })))
  const prev = nonCash(items.map((i) => ({ name: i.name, v: n(i.prev_value) })))
  const when = q.compare === 'week' ? 'Неделю назад' : 'В прошлом периоде'
  return (
    <Card style={{ height: '100%' }} styles={{ body: cardBody }}>
      <Head title="Способы оплаты" sub={`${PERIODS.find((p) => p.value === period)?.label}, касса и онлайн`} />
      {isLoading ? (
        <Skeleton active />
      ) : items.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="Оплат пока нет" />
      ) : (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: 20 }}>
            <Donut
              parts={items.map((it, i) => ({ value: n(it.value), color: colorOf(i), name: it.name }))}
              center={
                <div>
                  <div style={{ fontWeight: 800, fontSize: 16, color: C.text }}>{short(total)}</div>
                  <div style={{ fontSize: 11, color: C.muted }}>сум</div>
                </div>
              }
            />
            <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 10 }}>
              {items.map((it, i) => (
                <div key={it.key} style={{ display: 'flex', gap: 8 }}>
                  <span style={{ width: 10, height: 10, borderRadius: 3, background: colorOf(i), marginTop: 4, flex: 'none' }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, fontSize: 12 }}>
                      <span style={{ fontWeight: 600, color: '#344054' }}>{it.name}</span>
                      <b>{Math.round(it.share)}%</b>
                    </div>
                    <div style={{ fontSize: 11, color: C.muted }}>{money(it.value)} сум</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
          {cur !== null && (
            <div style={{ marginTop: 16, background: '#f9fafb', borderRadius: 8, padding: '8px 12px', fontSize: 12, color: '#475467' }}>
              Безналичных — {cur}%.{prev !== null && ` ${when} было ${prev}%.`}
            </div>
          )}
        </>
      )}
    </Card>
  )
}

function Categories() {
  const { storeId } = useStore()
  const nav = useNavigate()
  const t = dayjs().startOf('day')
  const [parent, setParent] = useState<{ id: string; name: string } | null>(null)
  const { data, isLoading } = useItem<SalesBreakdown>('/store/reports/sales-breakdown', {
    store_id: storeId,
    by: 'category',
    compare: 'prev',
    parent_id: parent?.id,
    from: fmt(t.subtract(29, 'day')),
    to: fmt(t.add(1, 'day')),
  })
  const rows = [...(data?.items ?? [])]
  const max = Math.max(1, ...rows.map((r) => n(r.value)), n(data?.other?.value))
  return (
    <Card style={{ height: '100%' }} styles={{ body: cardBody }}>
      <Head
        title={
          parent ? (
            <span>
              <Button type="text" size="small" icon={<ArrowLeftOutlined />} onClick={() => setParent(null)} style={{ marginLeft: -6 }} /> {parent.name}
            </span>
          ) : (
            'Продажи по категориям'
          )
        }
        sub="30 дней · выручка, сум · изменение к прошлым 30"
      />
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 6 }} />
      ) : rows.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="Продаж пока нет" />
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
          {rows.map((r) => (
            <CatRow
              key={r.key}
              name={r.name}
              value={n(r.value)}
              change={r.change_pct}
              max={max}
              onClick={() => (parent ? nav('/reports/abc-xyz') : setParent({ id: r.key, name: r.name }))}
            />
          ))}
          {data?.other && <CatRow name={`Остальное · ${data.other.count}`} value={n(data.other.value)} max={max} muted />}
          {!parent && <div style={{ fontSize: 11, color: C.faint }}>Нажмите на категорию — откроются её подкатегории</div>}
        </div>
      )}
    </Card>
  )
}

function CatRow({ name, value, change, max, muted, onClick }: { name: string; value: number; change?: number | null; max: number; muted?: boolean; onClick?: () => void }) {
  return (
    <div onClick={onClick} style={{ display: 'grid', gridTemplateColumns: 'minmax(90px, 150px) 1fr 70px 52px', gap: 10, alignItems: 'center', cursor: onClick ? 'pointer' : undefined }}>
      <span style={{ fontSize: 12, fontWeight: 600, color: muted ? C.muted : '#344054', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={name}>
        {name}
      </span>
      <span style={{ height: 14 }}>
        <span style={{ display: 'block', height: 14, borderRadius: '0 4px 4px 0', background: muted ? '#b9c3d0' : C.pos, width: `${Math.max(2, (value / max) * 100)}%` }} />
      </span>
      <b style={{ fontSize: 12, textAlign: 'right' }}>{short(value)}</b>
      <span style={{ textAlign: 'right' }}>{change != null && <Delta v={change} />}</span>
    </div>
  )
}

function WhenBuy() {
  const { storeId } = useStore()
  const { data, isLoading } = useItem<SalesSeries>('/store/reports/sales-series', { store_id: storeId, bucket: 'weekday_hour' })
  const cells = data?.heatmap ?? []
  const hrs = cells.map((c) => c.hour)
  const from = Math.min(8, ...hrs)
  const to = Math.max(22, ...hrs)
  const hours = Array.from({ length: to - from + 1 }, (_, i) => from + i)
  const peak = cells.reduce<(typeof cells)[number] | null>((m, c) => (!m || c.checks > m.checks ? c : m), null)
  return (
    <Card style={{ height: '100%' }} styles={{ body: cardBody }}>
      <Head title="Когда покупают" sub="Чеков на кассе в среднем за час · последние 4 недели" extra={<HeatLegend />} />
      {isLoading ? (
        <Skeleton active paragraph={{ rows: 6 }} />
      ) : cells.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="Продаж на кассе пока нет" />
      ) : (
        <>
          <Heatmap cells={cells} hours={hours} peak={peak} />
          {peak && (
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 14, background: '#f9fafb', borderRadius: 8, padding: '8px 12px', fontSize: 12, color: '#344054' }}>
              <TeamOutlined style={{ color: '#475467' }} />
              Пик — {WEEKDAY[peak.weekday]} {peak.hour}:00–{peak.hour + 1}:00, {peak.checks.toLocaleString('ru-RU')} чеков в час.
              {peak.checks >= 25 && ' В это время нужен второй кассир.'}
            </div>
          )}
        </>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------- ABC/XYZ

function AbcBlock() {
  const { storeId } = useStore()
  const nav = useNavigate()
  const { data, isLoading } = useItem<AbcXyz>('/store/reports/abc-xyz', { store_id: storeId, compact: 1 })
  const head = (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 18 }}>
      <span style={{ width: 34, height: 34, borderRadius: 10, background: '#fef3f2', color: C.now, display: 'grid', placeItems: 'center', fontSize: 18 }}>
        <LineChartOutlined />
      </span>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 16, fontWeight: 800 }}>ABC/XYZ-анализ{data?.xyz_available ? ' · последние 12 недель' : ''}</div>
        <div style={{ fontSize: 12, color: C.muted }}>Какие товары приносят деньги (ABC) и насколько ровно продаются (XYZ)</div>
      </div>
      <Button onClick={() => nav('/reports/abc-xyz')}>
        {data && !data.xyz_available ? 'Что это?' : 'Открыть анализ'} <ArrowRightOutlined />
      </Button>
    </div>
  )
  if (isLoading || !data)
    return (
      <Card styles={{ body: cardBody }}>
        {head}
        <Skeleton active />
      </Card>
    )

  if (!data.xyz_available) {
    const weeks = Math.min(data.weeks, data.min_weeks)
    return (
      <Card styles={{ body: cardBody }}>
        {head}
        <div style={{ display: 'flex', gap: 20, alignItems: 'center', background: '#f9fafb', borderRadius: 12, padding: '18px 20px' }}>
          <HourglassOutlined style={{ fontSize: 28, color: C.faint }} />
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 15, fontWeight: 800 }}>
              {data.weeks === 0 && data.totals.products === 0
                ? 'Анализ появится, когда пройдут продажи'
                : `Анализ появится через ${data.xyz_days_left} ${plural(data.xyz_days_left, 'день', 'дня', 'дней')}`}
            </div>
            <div style={{ fontSize: 13, color: '#475467', margin: '4px 0 10px' }}>
              Super Market нужно минимум {data.min_weeks} недели продаж, чтобы понять, какие товары главные и какие продаются ровно. Продавайте через
              кассу Super Market — данные копятся сами.
            </div>
            <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
              {Array.from({ length: data.min_weeks }, (_, i) => (
                <span key={i} style={{ flex: 1, height: 8, borderRadius: 4, background: i < weeks ? '#17b26a' : '#eaecf0' }} />
              ))}
              <b style={{ fontSize: 12, marginLeft: 6, whiteSpace: 'nowrap' }}>
                {weeks} из {data.min_weeks} недель
              </b>
            </div>
          </div>
        </div>
      </Card>
    )
  }

  const g = data.groups
  const total = data.totals.products || 1
  const cell = (k: string) => data.matrix.find((m) => m.cell === k)?.count ?? 0
  const low = data.items
  const cz = cell('CZ')
  const actions = [
    low.length > 0 && {
      tone: 'rose' as const,
      icon: <InboxOutlined />,
      title: `${low.length} ${plural(low.length, 'главный товар заканчивается', 'главных товара заканчиваются', 'главных товаров заканчиваются')}`,
      text: low
        .slice(0, 3)
        .map((i) => `${i.name} — ${i.days_cover === 0 ? 'нет в наличии' : `на ${i.days_cover} ${plural(i.days_cover ?? 0, 'день', 'дня', 'дней')}`}`)
        .join(' · '),
      to: '/reports/abc-xyz?low=1',
    },
    data.no_sales.count > 0 && {
      tone: 'amber' as const,
      icon: <ClockCircleOutlined />,
      title: `${products(data.no_sales.count)} без продаж за 12 недель`,
      text: `Лежат на складе на ${money(data.no_sales.stock_value)} сум — сделайте скидку или верните поставщику`,
      to: '/reports/abc-xyz?view=nosale',
    },
    cz > 0 && {
      tone: 'gray' as const,
      icon: <DeleteOutlined />,
      title: `${products(cz)} в CZ`,
      text: 'Продаются редко и мало — кандидаты на вывод из ассортимента',
      to: '/reports/abc-xyz?cell=CZ',
    },
  ].filter(Boolean) as { tone: 'rose' | 'amber' | 'gray'; icon: ReactNode; title: string; text: string; to: string }[]
  const tones = { rose: { bg: '#fef3f2', fg: '#b42318' }, amber: { bg: '#fffaeb', fg: '#b54708' }, gray: { bg: '#f2f4f7', fg: '#475467' } }

  return (
    <Card styles={{ body: cardBody }}>
      {head}
      <Row gutter={[24, 20]}>
        <Col xs={24} lg={8}>
          <div style={{ fontSize: 13, fontWeight: 700, color: '#344054', marginBottom: 10 }}>Кривая Парето: товары → выручка</div>
          <Pareto groups={(['A', 'B', 'C'] as const).map((k) => ({ count: g[k].count, share: g[k].share }))} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 12 }}>
            {(['A', 'B', 'C'] as const).map((k) => (
              <div key={k} style={{ display: 'flex', gap: 10, alignItems: 'center', fontSize: 13 }}>
                <Letter k={k} />
                <span style={{ flex: 1, fontWeight: 600, color: '#344054' }}>
                  {products(g[k].count)} · {Math.round((g[k].count / total) * 100)}%
                </span>
                <span style={{ color: C.muted, fontSize: 12 }}>{money(g[k].revenue)} сум</span>
                <b style={{ width: 52, textAlign: 'right' }}>{g[k].share.toLocaleString('ru-RU', { maximumFractionDigits: 1 })}%</b>
              </div>
            ))}
          </div>
        </Col>
        <Col xs={24} lg={7}>
          <div style={{ fontSize: 13, fontWeight: 700, color: '#344054', marginBottom: 10 }}>Матрица ABC × XYZ, товаров</div>
          <div style={{ display: 'grid', gridTemplateColumns: '18px repeat(3, 1fr)', gap: 6, alignItems: 'center' }}>
            <span />
            {['X · ровно', 'Y · колеблется', 'Z · случайно'].map((x) => (
              <span key={x} style={{ fontSize: 10, color: C.muted, fontWeight: 600, textAlign: 'center' }}>
                {x}
              </span>
            ))}
            {(['A', 'B', 'C'] as const).map((r) => (
              <MatrixLine key={r} r={r} count={cell} onPick={(k) => nav(`/reports/abc-xyz?cell=${k}`)} />
            ))}
          </div>
          <div style={{ fontSize: 11, color: C.faint, marginTop: 8 }}>Нажмите на клетку — откроется список</div>
        </Col>
        <Col xs={24} lg={9}>
          <div style={{ fontSize: 13, fontWeight: 700, color: '#344054', marginBottom: 10 }}>Требует внимания</div>
          {actions.length === 0 ? (
            <Alert type="success" showIcon message="Главные товары в наличии, залежавшихся нет" />
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {actions.map((a) => (
                <div key={a.to} style={{ display: 'flex', gap: 12, alignItems: 'center', background: tones[a.tone].bg, borderRadius: 10, padding: '10px 12px' }}>
                  <span style={{ fontSize: 18, color: tones[a.tone].fg }}>{a.icon}</span>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 800, fontSize: 13, color: tones[a.tone].fg }}>{a.title}</div>
                    <div style={{ fontSize: 12, color: '#475467' }}>{a.text}</div>
                  </div>
                  <Button size="small" onClick={() => nav(a.to)}>
                    Показать
                  </Button>
                </div>
              ))}
            </div>
          )}
          {low.length > 0 && (
            <div style={{ fontSize: 11, color: C.faint, marginTop: 8 }}>
              «Заканчивается» — товара A хватит меньше чем на {LOW_DAYS} дней при спросе за последние 14 дней
            </div>
          )}
        </Col>
      </Row>
    </Card>
  )
}

function Letter({ k }: { k: AbcLetter }) {
  return <span style={{ width: 24, height: 24, borderRadius: 6, display: 'grid', placeItems: 'center', fontWeight: 800, background: GROUP[k].bg, color: GROUP[k].text }}>{k}</span>
}

function MatrixLine({ r, count, onPick }: { r: AbcLetter; count: (k: string) => number; onPick: (k: string) => void }) {
  return (
    <>
      <b style={{ fontSize: 13, color: '#344054' }}>{r}</b>
      {(['X', 'Y', 'Z'] as const).map((x) => {
        const k = r + x
        const t = TONE[CELL[k].tone]
        return (
          <button
            key={k}
            type="button"
            onClick={() => onPick(k)}
            title={CELL[k].action}
            style={{ border: 0, cursor: 'pointer', background: t.bg, color: t.fg, borderRadius: 8, padding: '7px 4px', textAlign: 'center', fontFamily: 'inherit' }}
          >
            <div style={{ fontSize: 16, fontWeight: 800, lineHeight: 1.2 }}>{count(k)}</div>
            <div style={{ fontSize: 10, fontWeight: 700 }}>{k}</div>
          </button>
        )
      })}
    </>
  )
}

// ---------------------------------------------------------------- заказы, чеки, долги

function NewOrders() {
  const nav = useNavigate()
  const orders = usePaidOrders()
  const list = orders.data ?? []
  return (
    <Card
      title={`Новые онлайн-заказы${list.length ? ' · ' + list.length : ''}`}
      extra={<LinkText to="/orders">Все заказы</LinkText>}
      style={{ height: '100%' }}
      styles={{ body: { padding: 0 } }}
    >
      <Table<Order>
        rowKey="id"
        size="small"
        loading={orders.isLoading}
        dataSource={list.slice(0, 8)}
        pagination={false}
        scroll={{ x: true }}
        locale={{ emptyText: 'Новых заказов нет' }}
        onRow={() => ({ onClick: () => nav('/orders'), style: { cursor: 'pointer' } })}
        columns={[
          { title: '№', dataIndex: 'number' },
          { title: 'Создан', dataIndex: 'created_at', render: dateTime },
          { title: 'Адрес', dataIndex: 'address', ellipsis: true },
          { title: 'Сумма', dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
          { title: 'Статус', dataIndex: 'status', render: (v: string) => <StatusTag status={v} /> },
        ]}
      />
    </Card>
  )
}

function Fiscal() {
  const { storeId } = useStore()
  const fiscal = useItem<FiscalSummary>('/store/sales/fiscal-control', { store_id: storeId })
  const pending = (fiscal.data?.pending_sales ?? 0) + (fiscal.data?.pending_returns ?? 0)
  return (
    <Card title="Контроль чеков" loading={fiscal.isLoading}>
      {pending === 0 ? (
        <Alert type="success" showIcon message="Все чеки пробиты" />
      ) : (
        <>
          <Alert
            type="warning"
            showIcon
            message={`Не пробито: продаж — ${fiscal.data?.pending_sales ?? 0}, возвратов — ${fiscal.data?.pending_returns ?? 0}`}
            description={fiscal.data?.oldest_pending_at && `Самый старый: ${dateTime(fiscal.data.oldest_pending_at)}`}
            style={{ marginBottom: 12 }}
          />
          <Link to="/sales/pos">К продажам</Link>
        </>
      )}
    </Card>
  )
}

function DebtsCard() {
  const { storeId } = useStore()
  const d = useItem<{ total: string; count: number; overdue: string; overdue_count: number; open_disputes: number }>('/store/debtors/summary', { store_id: storeId })
  return (
    <Card title="Долги покупателей" extra={<LinkText to="/debts">Открыть</LinkText>} loading={d.isLoading}>
      {!d.data || d.data.count === 0 ? (
        <Typography.Text type="secondary">Долгов нет</Typography.Text>
      ) : (
        <>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 22, fontWeight: 800 }}>{money(d.data.total)}</span>
            <Typography.Text type="secondary">
              сум у {d.data.count} {plural(d.data.count, 'покупателя', 'покупателей', 'покупателей')}
            </Typography.Text>
          </div>
          {d.data.overdue_count > 0 && (
            <div style={{ color: '#b42318', fontWeight: 700, marginTop: 6 }}>
              <AccountBookOutlined /> просрочено {money(d.data.overdue)} у {d.data.overdue_count}
            </div>
          )}
          {d.data.open_disputes > 0 && <div style={{ color: '#b54708', marginTop: 4 }}>Споров: {d.data.open_disputes}</div>}
        </>
      )}
    </Card>
  )
}
