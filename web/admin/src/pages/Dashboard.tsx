import { Card, Col, Row, Statistic, Typography } from 'antd'
import { useNavigate } from 'react-router-dom'
import dayjs from 'dayjs'
import { useQuery } from '@tanstack/react-query'
import { LoadError, PageTitle, api, dateTime, money } from '@sm/shared'

interface Stats {
  stale_orders: number
  paid_waiting: number
  refunds_pending: number
  payouts_requested: number
  products_pending: number
  overdue_networks: number
  failed_notifications: number
  today_orders: number
  today_gmv: string
  accept_timeout_min: number
}

function Tile({
  title,
  value,
  to,
  danger,
  loading,
  suffix,
}: {
  title: string
  value: number | string
  to?: string
  danger?: boolean
  loading: boolean
  suffix?: string
}) {
  const nav = useNavigate()
  return (
    <Col xs={24} sm={12} lg={8}>
      <Card hoverable={!!to} onClick={to ? () => nav(to) : undefined}>
        <Statistic
          title={title}
          value={value}
          suffix={suffix}
          loading={loading}
          valueStyle={danger && Number(value) > 0 ? { color: '#cf1322' } : undefined}
        />
      </Card>
    </Col>
  )
}

/** Что требует внимания супер-админа прямо сейчас; обновляется каждые 30 секунд. */
export function Dashboard() {
  const q = useQuery({
    queryKey: ['/admin/stats'],
    queryFn: () => api.get<Stats>('/admin/stats'),
    refetchInterval: 30_000,
  })
  const s = q.data
  const loading = q.isLoading
  const today = dayjs().format('YYYY-MM-DD')
  const tomorrow = dayjs().add(1, 'day').format('YYYY-MM-DD')
  return (
    <>
      <PageTitle title="Главная">
        {q.dataUpdatedAt > 0 && <Typography.Text type="secondary">Обновлено {dateTime(new Date(q.dataUpdatedAt).toISOString())}</Typography.Text>}
      </PageTitle>
      <LoadError error={q.error} retry={() => q.refetch()} />
      <Row gutter={[16, 16]}>
        <Tile
          title={`Заказы не приняты вовремя${s ? ` (дольше ${s.accept_timeout_min} мин)` : ''}`}
          value={s?.stale_orders ?? 0}
          to="/stale"
          danger
          loading={loading}
        />
        <Tile title="Оплачены, ждут принятия" value={s?.paid_waiting ?? 0} to="/orders?status=paid" loading={loading} />
        <Tile title="Возвраты к выполнению" value={s?.refunds_pending ?? 0} to="/payments?status=refund_pending" danger loading={loading} />
        <Tile title="Заявки на вывод" value={s?.payouts_requested ?? 0} to="/payouts?status=requested" danger loading={loading} />
        <Tile title="Товары на модерации" value={s?.products_pending ?? 0} to="/moderation" loading={loading} />
        <Tile title="Сети с долгом по подписке" value={s?.overdue_networks ?? 0} to="/billing/networks?overdue=true" danger loading={loading} />
        <Tile title="Не доставленные уведомления" value={s?.failed_notifications ?? 0} to="/notifications?status=failed" danger loading={loading} />
        <Tile title="Заказов оплачено сегодня" value={s?.today_orders ?? 0} to={`/orders?from=${today}&to=${tomorrow}`} loading={loading} />
        <Tile title="Оборот за сегодня" value={s ? money(s.today_gmv) : 0} suffix="сум" loading={loading} />
      </Row>
    </>
  )
}
