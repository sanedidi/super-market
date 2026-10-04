// Главная: продажи за сегодня, новые заказы, баланс, контроль чеков.
import { Link, useNavigate } from 'react-router-dom'
import { Alert, Button, Card, Col, Flex, Row, Statistic, Table, Typography } from 'antd'
import { EnvironmentOutlined, RocketOutlined, ShoppingOutlined } from '@ant-design/icons'
import { PageTitle, StatusTag, dateTime, money, periodParams, useItem } from '@sm/shared'
import { useStore } from '../ctx'
import { usePaidOrders } from '../notify'
import { NeedStore, today } from '../ui'
import type { Balance, FiscalSummary, Order, SalesSummary } from '../types'
import type { Draft } from './start/api'

export function DashboardPage() {
  return (
    <>
      <PageTitle title="Главная" />
      <NeedStore>
        <StartBlock />
        <WishesBlock />
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
                valueStyle={{ color: (orders.data?.length ?? 0) > 0 ? '#d97706' : undefined }}
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

/** «Начало работы» — пока на складе нет товаров или список не проведён. */
function StartBlock() {
  const { storeId, can } = useStore()
  const nav = useNavigate()
  const d = useItem<Draft>(can('inventory.manage') ? '/store/start' : null, { store_id: storeId, limit: 1 })
  if (!d.data || (d.data.stock_products > 0 && !d.data.id)) return null
  const n = d.data.totals.products
  return (
    <Card style={{ marginBottom: 16, borderColor: '#E11D2A' }}>
      <Flex align="center" justify="space-between" gap={16} wrap>
        <Flex align="center" gap={16}>
          <RocketOutlined style={{ fontSize: 28, color: '#E11D2A' }} />
          <div>
            <Typography.Title level={5} style={{ margin: 0 }}>
              Начало работы
            </Typography.Title>
            <Typography.Text type="secondary">
              {n > 0
                ? `В списке ${n} — проверьте цены и проведите, чтобы товары появились на складе и у покупателей.`
                : 'Добавьте товары, которые уже есть в магазине: фото полок, штрихкод или каталог. Super Market найдёт их в общем каталоге.'}
            </Typography.Text>
          </div>
        </Flex>
        <Button type="primary" onClick={() => nav('/start')}>
          {n > 0 ? 'Продолжить' : 'Начать'}
        </Button>
      </Flex>
    </Card>
  )
}

type WishStats = {
  accepts_online: boolean
  total: number
  week: number
  month: number
  nearest_m: number | null
  farthest_m: number | null
  out_of_zone: number
  out_of_zone_week: number
}

const km = (m: number | null) => (m === null ? '' : m < 1000 ? `${Math.round(m / 10) * 10} м` : `${(m / 1000).toFixed(1).replace('.', ',')} км`)
const people = (n: number) => {
  const m10 = n % 10
  const m100 = n % 100
  return m10 === 1 && m100 !== 11 ? 'покупатель' : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? 'покупателя' : 'покупателей'
}

/** «Хочу доставку» в приложении: сколько покупателей рядом ждут доставку из магазина. */
function WishesBlock() {
  const { storeId, can } = useStore()
  const nav = useNavigate()
  const sees = can('stores.manage') || can('orders.manage')
  const d = useItem<WishStats>(sees ? `/store/stores/${storeId}/wishes` : null).data
  if (!d) return null
  const off = !d.accepts_online && d.total > 0
  const outside = d.accepts_online && d.out_of_zone > 0
  if (!off && !outside) return null
  const n = off ? d.total : d.out_of_zone
  const week = off ? d.week : d.out_of_zone_week
  const chips = off
    ? [week > 0 && `+${week} за 7 дней`, `за 30 дней — ${d.month}`, d.nearest_m !== null && `ближайший — ${km(d.nearest_m)}`]
    : [week > 0 && `+${week} за 7 дней`, d.farthest_m !== null && `дальше всего — ${km(d.farthest_m)}`]
  return (
    <Card style={{ marginBottom: 16, borderColor: off ? '#E11D2A' : '#B54708' }}>
      <Flex align="center" justify="space-between" gap={16} wrap>
        <Flex align="center" gap={16} style={{ flex: 1, minWidth: 280 }}>
          {off ? (
            <ShoppingOutlined style={{ fontSize: 28, color: '#E11D2A' }} />
          ) : (
            <EnvironmentOutlined style={{ fontSize: 28, color: '#B54708' }} />
          )}
          <div>
            <Typography.Title level={5} style={{ margin: 0 }}>
              {off ? `${n} ${people(n)} рядом хотят, чтобы вы доставляли` : `${n} ${people(n)} ждут доставку, но живут вне вашей зоны`}
            </Typography.Title>
            <Typography.Text type="secondary">
              {off
                ? 'Они нажали «Хочу доставку» на странице вашего магазина в приложении Super Market. Включите онлайн-заказы — и они смогут заказать у вас.'
                : 'Магазин принимает онлайн-заказы, но до их адресов не доставляет. Расширьте зону или радиус доставки.'}
            </Typography.Text>
            <Flex gap={8} wrap style={{ marginTop: 8 }}>
              {chips.filter(Boolean).map((c) => (
                <Typography.Text key={String(c)} style={{ background: '#F2F4F7', borderRadius: 8, padding: '2px 10px', fontSize: 13 }}>
                  {c}
                </Typography.Text>
              ))}
            </Flex>
          </div>
        </Flex>
        {can('stores.manage') && (
          <Button type="primary" onClick={() => nav('/settings/delivery')}>
            {off ? 'Включить онлайн-заказы' : 'Настроить зону доставки'}
          </Button>
        )}
      </Flex>
    </Card>
  )
}
