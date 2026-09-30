// Главная: продажи за сегодня, новые заказы, баланс, контроль чеков.
import { Link, useNavigate } from 'react-router-dom'
import { Alert, Button, Card, Col, Row, Statistic, Table, Typography } from 'antd'
import { PageTitle, StatusTag, dateTime, money, periodParams, useItem } from '@sm/shared'
import { useStore } from '../ctx'
import { usePaidOrders } from '../notify'
import { NeedStore, today } from '../ui'
import type { Balance, FiscalSummary, Order, SalesSummary } from '../types'

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
  // Виджеты запрашиваются только при праве на раздел — иначе сервер ответит 403.
  const seesSales = ['sales.pos', 'sales.return', 'reports.view'].some(can)
  const seesOrders = can('orders.manage')
  const seesBalance = can('payouts.manage')
  const sales = useItem<SalesSummary>(seesSales ? '/store/sales/summary' : null, { store_id: storeId, ...periodParams(today()) })
  const orders = usePaidOrders()
  const balance = useItem<Balance>(seesBalance ? '/store/balance' : null)
  const fiscal = useItem<FiscalSummary>(seesSales ? '/store/sales/fiscal-control' : null, { store_id: storeId })
  const pending = (fiscal.data?.pending_sales ?? 0) + (fiscal.data?.pending_returns ?? 0)

  if (!seesSales && !seesOrders && !seesBalance) {
    return <Alert type="info" showIcon message="Добро пожаловать" description="Доступные вам разделы — в меню слева." />
  }

  return (
    <>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        {seesSales && (
          <>
            <Col xs={12} lg={6}>
              <Card loading={sales.isLoading} hoverable onClick={() => nav('/sales/pos')}>
                <Statistic title="Продажи сегодня, сум" value={money(sales.data?.revenue)} />
                {Number(sales.data?.returns) > 0 && <Typography.Text type="secondary">Возвраты: {money(sales.data?.returns)}</Typography.Text>}
              </Card>
            </Col>
            <Col xs={12} lg={6}>
              <Card loading={sales.isLoading} hoverable onClick={() => nav('/sales/pos')}>
                <Statistic title="Чеков сегодня" value={sales.data?.sales_count ?? 0} />
              </Card>
            </Col>
          </>
        )}
        {seesOrders && (
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
        {seesBalance && (
          <Col xs={12} lg={6}>
            <Card loading={balance.isLoading} hoverable onClick={() => nav('/balance')}>
              <Statistic title="Баланс к выводу, сум" value={money(balance.data?.available)} />
              <Typography.Text type="secondary">Ожидает: {money(balance.data?.pending)}</Typography.Text>
            </Card>
          </Col>
        )}
      </Row>
      <Row gutter={[16, 16]}>
        {seesSales && (
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
        )}
        {seesOrders && (
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
