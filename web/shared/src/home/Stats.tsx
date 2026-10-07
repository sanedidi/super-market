// Статистика витрины (Figma «Витрина · монетизация» → «Статистика витрины
// — в панели магазина»): показы, нажатия, заказы и выручка с главной и по
// каждому блоку.
import { useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Button, Segmented, Spin, Table } from 'antd'
import { LockFilled, RiseOutlined } from '@ant-design/icons'
import { ApiError, api } from '../api'
import { LoadError } from '../components'
import { money } from '../format'
import { tr } from '../i18n'

interface BlockStat {
  block_id: string
  type: string
  title: string
  views: number
  clicks: number
  ctr: number
  orders: number
  revenue: string
}

interface HomeStats {
  level: 'basic' | 'full'
  days: number
  from: string
  to: string
  views: number
  clicks: number
  orders: number
  revenue: string
  blocks: BlockStat[]
  series: { day: string; views: number; clicks: number; orders: number; revenue: string }[]
  hint: string
}

const num = (v: number) => v.toLocaleString('ru-RU')

/** 31 400 000 → «31,4 млн». */
export function shortMoney(v: string | number): string {
  const n = Number(v)
  if (n >= 1_000_000) return `${(n / 1_000_000).toLocaleString('ru-RU', { maximumFractionDigits: 1 })} ${tr('млн', 'mln')}`
  if (n >= 10_000) return `${Math.round(n / 1000).toLocaleString('ru-RU')} ${tr('тыс', 'ming')}`
  return money(n)
}

function Kpi({ label, value, locked }: { label: string; value: string; locked?: boolean }) {
  return (
    <div className={`smh-kpi${locked ? ' locked' : ''}`}>
      <span>{label}</span>
      <b>{locked ? <LockFilled /> : value}</b>
    </div>
  )
}

/** Мини-график показов по дням. */
function Spark({ series }: { series: HomeStats['series'] }) {
  if (series.length < 2) return null
  const max = Math.max(...series.map((s) => s.views), 1)
  return (
    <div className="smh-spark" title={tr('Показы по дням', 'Kunlar boʻyicha koʻrsatishlar')}>
      {series.map((s) => (
        <i key={s.day} style={{ height: `${Math.max(4, (s.views / max) * 100)}%` }} title={tr(`${s.day}: ${num(s.views)} показов, ${num(s.orders)} заказов`, `${s.day}: ${num(s.views)} ta koʻrsatish, ${num(s.orders)} ta buyurtma`)} />
      ))}
    </div>
  )
}

export function HomeStatsPanel({
  path,
  params,
  subtitle,
  onUpgrade,
}: {
  path: string
  params: Record<string, string | undefined>
  /** «Baraka · Чиланзар». */
  subtitle?: string
  /** Статистика закрыта тарифом — кнопка перехода. */
  onUpgrade?: (feature: string) => void
}) {
  const [days, setDays] = useState(7)
  const q = useQuery({
    queryKey: [path, params, days],
    queryFn: () => api.get<HomeStats>(path, { ...params, days }),
    retry: false,
  })
  if (q.error instanceof ApiError && q.error.code === 'tariff_limit') {
    return (
      <div className="smh-locked" style={{ margin: 0 }}>
        <LockFilled />
        <b>{tr('Статистика витрины — с тарифа «Бизнес»', 'Vitrina statistikasi — «Biznes» tarifidan')}</b>
        <span>{tr('Показы, нажатия и покупки по каждому блоку главной: видно, что приносит заказы.', 'Bosh sahifaning har bir bloki boʻyicha koʻrsatishlar, bosishlar va xaridlar: nima buyurtma keltirayotgani koʻrinadi.')}</span>
        {onUpgrade && (
          <Button type="primary" danger onClick={() => onUpgrade('stats')}>
            {tr('Сравнить тарифы', 'Tariflarni solishtirish')}
          </Button>
        )}
      </div>
    )
  }
  if (q.error) return <LoadError error={q.error} retry={q.refetch} />
  const s = q.data
  if (!s) return <Spin style={{ margin: 32 }} />
  const full = s.level === 'full'
  const lockCell = (v: ReactNode) => (full ? v : <LockFilled className="smh-cell-lock" />)
  return (
    <div className="smh-stats">
      <div className="smh-stats-head">
        <div>
          <h2>{tr('Статистика витрины', 'Vitrina statistikasi')}</h2>
          <span>
            {tr(`За ${s.days} дней`, `${s.days} kunda`)}
            {subtitle ? ` · ${subtitle}` : ''}
          </span>
        </div>
        {full ? (
          <Segmented
            value={days}
            onChange={(v) => setDays(v as number)}
            options={[
              { value: 7, label: tr('7 дней', '7 kun') },
              { value: 30, label: tr('30 дней', '30 kun') },
              { value: 90, label: tr('90 дней', '90 kun') },
            ]}
          />
        ) : (
          <a onClick={() => onUpgrade?.('stats_full')}>
            <LockFilled /> {tr('Заказы, выручка и 30 дней — в «Про»', 'Buyurtmalar, tushum va 30 kun — «Pro» tarifida')}
          </a>
        )}
      </div>
      <div className="smh-kpis">
        <Kpi label={tr('Показы главной', 'Bosh sahifa koʻrsatishlari')} value={num(s.views)} />
        <Kpi label={tr('Нажатия на блоки', 'Bloklarga bosishlar')} value={num(s.clicks)} />
        <Kpi label={tr('Заказы с главной', 'Bosh sahifadan buyurtmalar')} value={num(s.orders)} locked={!full} />
        <Kpi label={tr('Выручка с главной', 'Bosh sahifadan tushum')} value={`${shortMoney(s.revenue)} ${tr('сум', 'soʻm')}`} locked={!full} />
      </div>
      {full && <Spark series={s.series} />}
      <Table<BlockStat>
        className="smh-stats-table"
        rowKey="block_id"
        size="middle"
        loading={q.isFetching}
        dataSource={s.blocks}
        pagination={false}
        locale={{ emptyText: tr('Пока нет данных: показы появятся, когда покупатели откроют главную в новой версии приложения.', 'Hozircha maʼlumot yoʻq: xaridorlar ilovaning yangi versiyasida bosh sahifani ochganda koʻrsatishlar paydo boʻladi.') }}
        columns={[
          { title: tr('Блок', 'Blok'), dataIndex: 'title' },
          { title: tr('Показы', 'Koʻrsatishlar'), dataIndex: 'views', align: 'right', render: num },
          { title: tr('Нажатия', 'Bosishlar'), dataIndex: 'clicks', align: 'right', render: num },
          { title: 'CTR', dataIndex: 'ctr', align: 'right', render: (v: number) => `${(v * 100).toLocaleString('ru-RU', { maximumFractionDigits: 1 })}%` },
          { title: tr('Заказы', 'Buyurtmalar'), dataIndex: 'orders', align: 'right', render: (v: number) => lockCell(<b>{num(v)}</b>) },
          { title: tr('Выручка', 'Tushum'), dataIndex: 'revenue', align: 'right', render: (v: string) => lockCell(`${shortMoney(v)}`) },
        ]}
      />
      {s.hint && (
        <div className="smh-hint">
          <RiseOutlined /> {s.hint}.
        </div>
      )}
      <div className="smh-field-hint">
        {tr(
          'Показ — блок был на экране хотя бы наполовину секунду; нажатие — касание внутри блока. Считает приложение (версия 0.7 и новее), поэтому возможны небольшие потери без сети.',
          'Koʻrsatish — blok kamida bir soniya davomida yarmi ekranda koʻrinib turgan; bosish — blok ichiga teginish. Ilova hisoblaydi (0.7 va yangi versiyalar), shuning uchun tarmoq yoʻqligida ozgina yoʻqotishlar boʻlishi mumkin.',
        )}
      </div>
    </div>
  )
}
