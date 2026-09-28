// Главная: продажи за сегодня, новые заказы, баланс, контроль чеков.
import { Link, useNavigate } from 'react-router-dom'
import { Alert, Button, Card, Col, Row, Statistic, Table, Typography } from 'antd'
import { useQuery } from '@tanstack/react-query'
import { PageTitle, StatusTag, api, dateTime, money, periodParams, useItem, useList, type List } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore, sum, today } from '../ui'
import type { Balance, FiscalSummary, Order, Sale } from '../types'

export function DashboardPage() {
  return (
    <>
      <PageTitle title="Главная" />
      <NeedStore>
        <Widgets />
      </NeedStore>
    </>
  )
}

function Widgets() {
  const { storeId, can } = useStore()
  const nav = useNavigate()
  const sales = useList<Sale>('/store/sales', { store_id: storeId, ...periodParams(today()), limit: 200 })
  const ordersParams = { store_id: storeId, status: 'paid', limit: 200 }
  const orders = useQuery({
    queryKey: ['/store/orders', ordersParams],
    queryFn: () => api.get<List<Order>>('/store/orders', ordersParams).then((r) => r.items ?? []),
    enabled: can('orders.manage'),
    refetchInterval: 15_000,
  })
  const balance = useItem<Balance>(can('payouts.manage') ? '/store/balance' : null)
  const fiscal = useItem<FiscalSummary>('/store/sales/fiscal-control', { store_id: storeId })
  const rows = sales.data ?? []
  const pending = (fiscal.data?.pending_sales ?? 0) + (fiscal.data?.pending_returns ?? 0)

  return (
    <>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={12} lg={6}>
          <Card loading={sales.isLoading} hoverable onClick={() => nav('/sales/pos')}>
            <Statistic title="Продажи сегодня, сум" value={money(sum(rows.map((s) => s.total)))} />
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card loading={sales.isLoading} hoverable onClick={() => nav('/sales/pos')}>
            <Statistic title="Чеков сегодня" value={rows.length} />
          </Card>
        </Col>
        {can('orders.manage') && (
          <Col xs={12} lg={6}>
            <Card loading={orders.isLoading} hoverable onClick={() => nav('/orders')}>
              <Statistic
                title="Новые онлайн-заказы"
                value={orders.data?.length ?? 0}
                valueStyle={{ color: (orders.data?.length ?? 0) > 0 ? '#ea580c' : undefined }}
              />
            </Card>
          </Col>
        )}
        {can('payouts.manage') && (
          <Col xs={12} lg={6}>
            <Card loading={balance.isLoading} hoverable onClick={() => nav('/balance')}>
              <Statistic title="Баланс к выводу, сум" value={money(balance.data?.available)} />
              <Typography.Text type="secondary">Ожидает: {money(balance.data?.pending)}</Typography.Text>
            </Card>
          </Col>
        )}
      </Row>
      <Row gutter={[16, 16]}>
        <Col xs={24} lg={8}>
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
        </Col>
        {can('orders.manage') && (
          <Col xs={24} lg={16}>
            <Card
              title="Новые заказы"
              extra={
                <Button size="small" onClick={() => nav('/orders')}>
                  Все заказы
                </Button>
              }
              styles={{ body: { padding: 0 } }}
            >
              <Table<Order>
                rowKey="id"
                size="small"
                loading={orders.isLoading}
                dataSource={(orders.data ?? []).slice(0, 8)}
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
          </Col>
        )}
      </Row>
    </>
  )
}
