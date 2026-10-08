// Главная: с правом «Отчёты» — выручка, прибыль, графики и ABC/XYZ (dashboard/Analytics),
// без него — продажи сегодня, новые заказы, баланс и контроль чеков.
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Alert, Button, Card, Col, Flex, Row, Segmented, Statistic, Table, Typography } from 'antd'
import { EnvironmentOutlined, RocketOutlined, ShoppingOutlined } from '@ant-design/icons'
import { PageTitle, StatusTag, dateTime, money, periodParams, tr, useItem } from '@sm/shared'
import { useStore } from '../ctx'
import { usePaidOrders } from '../notify'
import { NeedStore, today } from '../ui'
import type { Balance, FiscalSummary, Order, SalesSummary } from '../types'
import type { Draft } from './start/api'
import { SetupChecklist, useSetupState } from './setup/Setup'
import { Analytics, PERIODS, PeriodNote, type Period } from './dashboard/Analytics'

const PERIOD_KEY = 'sm.dashboard.period'
function savedPeriod(): Period {
  try {
    const v = localStorage.getItem(PERIOD_KEY)
    if (PERIODS.some((p) => p.value === v)) return v as Period
  } catch {
    /* хранилище недоступно */
  }
  return 'today'
}

export function DashboardPage() {
  const { can, storeId } = useStore()
  const analytics = can('reports.view')
  const [period, setPeriod] = useState<Period>(savedPeriod)
  const pick = (p: Period) => {
    setPeriod(p)
    try {
      localStorage.setItem(PERIOD_KEY, p)
    } catch {
      /* хранилище недоступно */
    }
  }
  return (
    <>
      <PageTitle
        title={tr('Главная', 'Bosh sahifa')}
        extra={analytics && storeId ? <Segmented<Period> value={period} onChange={pick} options={PERIODS} /> : undefined}
      >
        {analytics && storeId ? <PeriodNote period={period} /> : undefined}
      </PageTitle>
      <NeedStore>
        <Blocks analytics={analytics} />
        {analytics ? <Analytics period={period} /> : <Widgets />}
      </NeedStore>
    </>
  )
}

/** Чек-лист настройки, «Начало работы» и спрос на доставку. */
function Blocks({ analytics }: { analytics: boolean }) {
  const { storeId, can } = useStore()
  const setup = useSetupState(storeId, can('stores.manage')).data
  // Пока доставка не выбрана, спрос на неё показывает чек-лист.
  const checklist = !!setup && setup.can_setup && !setup.required && !setup.steps.done
  return (
    <>
      {setup && <SetupChecklist s={setup} />}
      <StartBlock />
      {!(checklist && !setup.steps.delivery) && <WishesBlock />}
      {/* С аналитикой долги — карточкой внизу главной. */}
      {!analytics && <DebtsBlock />}
    </>
  )
}

/** Долги покупателей: сколько должны и сколько просрочено. */
function DebtsBlock() {
  const { storeId, can, has } = useStore()
  const nav = useNavigate()
  const d = useItem<{ total: string; count: number; overdue: string; overdue_count: number; open_disputes: number }>(
    can('debts.manage') && has('debts') ? '/store/debtors/summary' : null,
    { store_id: storeId },
  ).data
  if (!d || d.count === 0) return null
  const extra = [
    d.overdue_count > 0 && tr(`просрочено ${money(d.overdue)} у ${d.overdue_count}`, `${d.overdue_count} kishida ${money(d.overdue)} muddati oʻtgan`),
    d.open_disputes > 0 && tr(`споров: ${d.open_disputes}`, `nizolar: ${d.open_disputes}`),
  ]
    .filter(Boolean)
    .join(' · ')
  return (
    <Alert
      style={{ marginBottom: 16 }}
      type={d.overdue_count > 0 || d.open_disputes > 0 ? 'warning' : 'info'}
      showIcon
      message={tr(`Долги покупателей: ${money(d.total)} сум у ${d.count}`, `Xaridorlar qarzlari: ${d.count} kishida ${money(d.total)} soʻm`)}
      description={extra || undefined}
      action={<Button size="small" onClick={() => nav('/debts')}>{tr('Открыть', 'Ochish')}</Button>}
    />
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
    return <Alert type="info" showIcon message={tr('Добро пожаловать', 'Xush kelibsiz')} description={tr('Доступные вам разделы — в меню слева.', 'Sizga ochiq boʻlimlar — chapdagi menyuda.')} />
  }

  return (
    <>
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        {seesSales && (
          <>
            <Col xs={12} lg={6}>
              <Card loading={sales.isLoading} hoverable onClick={() => nav('/sales/pos')}>
                <Statistic title={tr('Продажи сегодня, сум', 'Bugungi sotuvlar, soʻm')} value={money(sales.data?.revenue)} />
                {Number(sales.data?.returns) > 0 && <Typography.Text type="secondary">{tr('Возвраты:', 'Qaytarishlar:')} {money(sales.data?.returns)}</Typography.Text>}
              </Card>
            </Col>
            <Col xs={12} lg={6}>
              <Card loading={sales.isLoading} hoverable onClick={() => nav('/sales/pos')}>
                <Statistic title={tr('Чеков сегодня', 'Bugungi cheklar')} value={sales.data?.sales_count ?? 0} />
              </Card>
            </Col>
          </>
        )}
        {seesOrders && (
          <Col xs={12} lg={6}>
            <Card loading={orders.isLoading} hoverable onClick={() => nav('/orders')}>
              <Statistic
                title={tr('Новые онлайн-заказы', 'Yangi onlayn buyurtmalar')}
                value={orders.data?.length ?? 0}
                valueStyle={{ color: (orders.data?.length ?? 0) > 0 ? '#d97706' : undefined }}
              />
            </Card>
          </Col>
        )}
        {seesBalance && (
          <Col xs={12} lg={6}>
            <Card loading={balance.isLoading} hoverable onClick={() => nav('/balance')}>
              <Statistic title={tr('Баланс к выводу, сум', 'Yechib olish mumkin, soʻm')} value={money(balance.data?.available)} />
              <Typography.Text type="secondary">{tr('Ожидает:', 'Kutilmoqda:')} {money(balance.data?.pending)}</Typography.Text>
            </Card>
          </Col>
        )}
      </Row>
      <Row gutter={[16, 16]}>
        {seesSales && (
          <Col xs={24} lg={8}>
            <Card title={tr('Контроль чеков', 'Cheklar nazorati')} loading={fiscal.isLoading}>
              {pending === 0 ? (
                <Alert type="success" showIcon message={tr('Все чеки пробиты', 'Barcha cheklar urilgan')} />
              ) : (
                <>
                  <Alert
                    type="warning"
                    showIcon
                    message={tr(
                      `Не пробито: продаж — ${fiscal.data?.pending_sales ?? 0}, возвратов — ${fiscal.data?.pending_returns ?? 0}`,
                      `Chek urilmagan: sotuvlar — ${fiscal.data?.pending_sales ?? 0}, qaytarishlar — ${fiscal.data?.pending_returns ?? 0}`,
                    )}
                    description={fiscal.data?.oldest_pending_at && tr(`Самый старый: ${dateTime(fiscal.data.oldest_pending_at)}`, `Eng eskisi: ${dateTime(fiscal.data.oldest_pending_at)}`)}
                    style={{ marginBottom: 12 }}
                  />
                  <Link to="/sales/pos">{tr('К продажам', 'Sotuvlarga')}</Link>
                </>
              )}
            </Card>
          </Col>
        )}
        {seesOrders && (
          <Col xs={24} lg={16}>
            <Card
              title={tr('Новые заказы', 'Yangi buyurtmalar')}
              extra={
                <Button size="small" onClick={() => nav('/orders')}>
                  {tr('Все заказы', 'Barcha buyurtmalar')}
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
                locale={{ emptyText: tr('Новых заказов нет', 'Yangi buyurtmalar yoʻq') }}
                onRow={() => ({ onClick: () => nav('/orders'), style: { cursor: 'pointer' } })}
                columns={[
                  { title: '№', dataIndex: 'number' },
                  { title: tr('Создан', 'Yaratilgan'), dataIndex: 'created_at', render: dateTime },
                  { title: tr('Адрес', 'Manzil'), dataIndex: 'address', ellipsis: true },
                  { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
                  { title: tr('Статус', 'Holat'), dataIndex: 'status', render: (v: string) => <StatusTag status={v} /> },
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
              {tr('Начало работы', 'Ishni boshlash')}
            </Typography.Title>
            <Typography.Text type="secondary">
              {n > 0
                ? tr(
                    `В списке ${n} — проверьте цены и проведите, чтобы товары появились на складе и у покупателей.`,
                    `Roʻyxatda ${n} ta — mahsulotlar omborda va xaridorlarda paydo boʻlishi uchun narxlarni tekshirib, oʻtkazing.`,
                  )
                : tr(
                    'Добавьте товары, которые уже есть в магазине: фото полок, штрихкод или каталог. Super Market найдёт их в общем каталоге.',
                    'Doʻkonda bor mahsulotlarni qoʻshing: javon rasmi, shtrix-kod yoki katalog orqali. Super Market ularni umumiy katalogdan topadi.',
                  )}
            </Typography.Text>
          </div>
        </Flex>
        <Button type="primary" onClick={() => nav('/start')}>
          {n > 0 ? tr('Продолжить', 'Davom etish') : tr('Начать', 'Boshlash')}
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

const km = (m: number | null) =>
  m === null ? '' : m < 1000 ? `${Math.round(m / 10) * 10} ${tr('м', 'm')}` : `${(m / 1000).toFixed(1).replace('.', ',')} ${tr('км', 'km')}`
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
    ? [
        week > 0 && tr(`+${week} за 7 дней`, `7 kunda +${week}`),
        tr(`за 30 дней — ${d.month}`, `30 kunda — ${d.month}`),
        d.nearest_m !== null && tr(`ближайший — ${km(d.nearest_m)}`, `eng yaqini — ${km(d.nearest_m)}`),
      ]
    : [
        week > 0 && tr(`+${week} за 7 дней`, `7 kunda +${week}`),
        d.farthest_m !== null && tr(`дальше всего — ${km(d.farthest_m)}`, `eng uzogʻi — ${km(d.farthest_m)}`),
      ]
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
              {off
                ? tr(`${n} ${people(n)} рядом хотят, чтобы вы доставляли`, `Yaqinidagi ${n} ta xaridor siz yetkazib berishingizni xohlaydi`)
                : tr(`${n} ${people(n)} ждут доставку, но живут вне вашей зоны`, `${n} ta xaridor yetkazib berishni kutmoqda, lekin hududingizdan tashqarida yashaydi`)}
            </Typography.Title>
            <Typography.Text type="secondary">
              {off
                ? tr(
                    'Они нажали «Хочу доставку» на странице вашего магазина в приложении Super Market. Включите онлайн-заказы — и они смогут заказать у вас.',
                    'Ular Super Market ilovasida doʻkoningiz sahifasidagi «Yetkazib berishni xohlayman» tugmasini bosgan. Onlayn buyurtmalarni yoqing — ular sizdan buyurtma bera oladi.',
                  )
                : tr(
                    'Магазин принимает онлайн-заказы, но до их адресов не доставляет. Расширьте зону или радиус доставки.',
                    'Doʻkon onlayn buyurtmalarni qabul qiladi, lekin ularning manzillariga yetkazmaydi. Yetkazib berish hududi yoki radiusini kengaytiring.',
                  )}
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
            {off ? tr('Включить онлайн-заказы', 'Onlayn buyurtmalarni yoqish') : tr('Настроить зону доставки', 'Yetkazib berish hududini sozlash')}
          </Button>
        )}
      </Flex>
    </Card>
  )
}
