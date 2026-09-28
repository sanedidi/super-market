import { Card, Col, Row, Statistic } from 'antd'
import { useNavigate } from 'react-router-dom'
import { PageTitle, useList } from '@sm/shared'

function Tile({ title, value, to, danger, loading }: { title: string; value: number; to: string; danger?: boolean; loading: boolean }) {
  const nav = useNavigate()
  return (
    <Col xs={24} sm={12} lg={8}>
      <Card hoverable onClick={() => nav(to)}>
        <Statistic title={title} value={value} loading={loading} valueStyle={danger && value > 0 ? { color: '#cf1322' } : undefined} />
      </Card>
    </Col>
  )
}

/** Что требует внимания супер-админа прямо сейчас. */
export function Dashboard() {
  const stale = useList('/admin/orders', { stale: true, limit: 200 })
  const paid = useList('/admin/orders', { status: 'paid', limit: 200 })
  const refunds = useList('/admin/payments', { status: 'refund_pending', limit: 200 })
  const payouts = useList('/admin/payouts', { status: 'requested', limit: 200 })
  const moderation = useList('/admin/products', { status: 'pending', limit: 200 })
  const overdue = useList('/admin/billing/networks', { overdue: true, limit: 200 })
  return (
    <>
      <PageTitle title="Главная" />
      <Row gutter={[16, 16]}>
        <Tile title="Заказы не приняты вовремя" value={stale.data?.length ?? 0} to="/stale" danger loading={stale.isLoading} />
        <Tile title="Оплачены, ждут принятия" value={paid.data?.length ?? 0} to="/orders" loading={paid.isLoading} />
        <Tile title="Возвраты к выполнению" value={refunds.data?.length ?? 0} to="/payments" danger loading={refunds.isLoading} />
        <Tile title="Заявки на вывод" value={payouts.data?.length ?? 0} to="/payouts" danger loading={payouts.isLoading} />
        <Tile title="Товары на модерации" value={moderation.data?.length ?? 0} to="/moderation" loading={moderation.isLoading} />
        <Tile title="Сети с долгом по подписке" value={overdue.data?.length ?? 0} to="/billing/networks" danger loading={overdue.isLoading} />
      </Row>
    </>
  )
}
