// Инвест-страница (Figma «Супер-админ · Инвест-страница» → ИП1): кто смотрит
// калькулятор окупаемости на invest.super-market.uz — сейчас на странице,
// новые и вернувшиеся, сколько сидят, откуда пришли, последние визиты.
import { useState } from 'react'
import dayjs from 'dayjs'
import { useQuery } from '@tanstack/react-query'
import { Button, Card, Col, Empty, Flex, Progress, Row, Segmented, Table, Tag, Tooltip, Typography } from 'antd'
import { DesktopOutlined, ExportOutlined, MobileOutlined, TabletOutlined } from '@ant-design/icons'
import { LoadError, api } from '@sm/shared'

type Period = 'today' | '7d' | '30d' | 'all'

interface Visit {
  visitor: string
  started_at: string
  last_seen: string
  seconds: number
  is_new: boolean
  kind: 'phone' | 'tablet' | 'computer'
  device: string
  source: string
  visits: number
}

interface Stats {
  period: Period
  since: string
  now: number
  now_list: Visit[]
  new_visitors: number
  prev_new: number | null
  returned: number
  visits: number
  avg_seconds: number
  median_seconds: number
  total_unique: number
  first_seen: string | null
  days: { date: string; new: number; returned: number }[]
  sources: { source: string; visitors: number }[]
  recent: Visit[]
  updated_at: string
}

const SITE = 'https://invest.super-market.uz'
const periodLabel: Record<Period, string> = { today: 'сегодня', '7d': 'за 7 дней', '30d': 'за 30 дней', all: 'за всё время' }
const prevLabel: Record<Period, string> = { today: 'вчера', '7d': 'прошлым 7 дням', '30d': 'прошлым 30 дням', all: '' }

/** «4 мин 12 с», «48 с», «1 ч 05 мин». */
export function duration(sec: number): string {
  const s = Math.max(0, Math.round(sec))
  if (s < 60) return `${s} с`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m} мин ${String(s % 60).padStart(2, '0')} с`
  return `${Math.floor(m / 60)} ч ${String(m % 60).padStart(2, '0')} мин`
}

function when(v: string): string {
  const d = dayjs(v)
  if (dayjs().diff(d, 'second') < 90) return 'сейчас'
  if (d.isSame(dayjs(), 'day')) return `сегодня, ${d.format('HH:mm')}`
  if (d.isSame(dayjs().subtract(1, 'day'), 'day')) return `вчера, ${d.format('HH:mm')}`
  return d.format('D MMM, HH:mm')
}

function DeviceIcon({ kind }: { kind: Visit['kind'] }) {
  const Icon = kind === 'phone' ? MobileOutlined : kind === 'tablet' ? TabletOutlined : DesktopOutlined
  return (
    <span style={{ width: 38, height: 38, borderRadius: 10, background: '#EFF4FF', color: '#155EEF', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, flex: 'none' }}>
      <Icon />
    </span>
  )
}

const NewTag = ({ isNew }: { isNew: boolean }) =>
  isNew ? <Tag color="green" bordered={false}>Новый</Tag> : <Tag color="blue" bordered={false}>Вернулся</Tag>

function Metric({ label, value, note, color }: { label: string; value: string | number; note: string; color?: string }) {
  return (
    <Card size="small" styles={{ body: { padding: 16 } }} style={{ height: '100%' }}>
      <Typography.Text type="secondary" style={{ fontSize: 12, fontWeight: 700, textTransform: 'uppercase', letterSpacing: 0.4 }}>{label}</Typography.Text>
      <div style={{ fontSize: 26, fontWeight: 800, lineHeight: 1.25, color, fontVariantNumeric: 'tabular-nums' }}>{value}</div>
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>{note}</Typography.Text>
    </Card>
  )
}

/** Новые и вернувшиеся по дням — столбики друг на друге. */
function DaysChart({ days }: { days: Stats['days'] }) {
  const max = Math.max(1, ...days.map((d) => d.new + d.returned))
  const step = days.length > 20 ? 5 : days.length > 10 ? 2 : 1
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 4, height: 210, paddingTop: 8 }}>
      {days.map((d, i) => {
        const total = d.new + d.returned
        const last = i === days.length - 1
        return (
          <Tooltip key={d.date} title={`${dayjs(d.date).format('D MMMM')}: новых ${d.new}, вернулись ${d.returned}`}>
            <div style={{ flex: 1, minWidth: 0, height: '100%', display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', alignItems: 'center' }}>
              <div style={{ width: '62%', maxWidth: 28, display: 'flex', flexDirection: 'column-reverse', height: `${(total / max) * 170}px` }}>
                {d.new > 0 && <div style={{ height: `${(d.new / total) * 100}%`, background: '#155EEF', borderRadius: d.returned ? '0 0 3px 3px' : 3 }} />}
                {d.returned > 0 && <div style={{ height: `${(d.returned / total) * 100}%`, background: '#C6D9FD', borderRadius: d.new ? '3px 3px 0 0' : 3 }} />}
              </div>
              <div style={{ height: 22, fontSize: 11, color: last ? '#344054' : '#98A2B3', fontWeight: last ? 700 : 400, whiteSpace: 'nowrap', paddingTop: 6 }}>
                {last ? 'сегодня' : i % step === 0 ? dayjs(d.date).format('D MMM') : ''}
              </div>
            </div>
          </Tooltip>
        )
      })}
    </div>
  )
}

export function InvestVisitors() {
  const [period, setPeriod] = useState<Period>('30d')
  const { data, error, refetch, isLoading } = useQuery({
    queryKey: ['/admin/invest/stats', period],
    queryFn: () => api.get<Stats>('/admin/invest/stats', { period }),
    refetchInterval: 15_000,
  })
  if (error) return <LoadError error={error} retry={() => refetch()} />
  const s = data
  const diff = s && s.prev_new !== null ? s.new_visitors - s.prev_new : null

  return (
    <Flex vertical gap={20}>
      <div>
        <Flex align="center" gap={10} wrap>
          <Typography.Title level={3} style={{ margin: 0 }}>Инвест-страница</Typography.Title>
          {s && s.now > 0 && <Tag color="green" bordered={false} style={{ fontWeight: 700 }}>● {s.now} сейчас на странице</Tag>}
        </Flex>
        <Typography.Paragraph type="secondary" style={{ margin: '4px 0 0', maxWidth: 1100 }}>
          Кто открывает калькулятор окупаемости на invest.super-market.uz. Новый посетитель — браузер, который открыл страницу впервые. «Сейчас на странице» — страница открыта и подавала сигнал за последнюю минуту.
        </Typography.Paragraph>
      </div>

      <Flex align="center" gap={8} wrap>
        <Segmented<Period>
          value={period}
          onChange={setPeriod}
          options={[{ value: 'today', label: 'Сегодня' }, { value: '7d', label: '7 дней' }, { value: '30d', label: '30 дней' }, { value: 'all', label: 'Всё время' }]}
        />
        <div style={{ flex: 1 }} />
        {s && <Typography.Text type="secondary" style={{ fontSize: 12 }}>Обновлено {dayjs(s.updated_at).format('HH:mm:ss')} · само каждые 15 с</Typography.Text>}
        <Button icon={<ExportOutlined />} href={SITE} target="_blank" rel="noreferrer">invest.super-market.uz</Button>
      </Flex>

      <Row gutter={[16, 16]}>
        <Col flex="1 1 200px">
          <Metric label="Сейчас на странице" value={s?.now ?? '—'} color="#027A48"
            note={!s ? '' : s.now === 0 ? 'никого нет' : `новых ${s.now_list.filter((v) => v.is_new).length} из ${s.now}`} />
        </Col>
        <Col flex="1 1 200px">
          <Metric label={`Новых ${periodLabel[period]}`} value={s?.new_visitors ?? '—'}
            note={diff === null ? 'первый раз открыли страницу' : `${diff >= 0 ? '+' : '−'}${Math.abs(diff)} к ${prevLabel[period]}`} />
        </Col>
        <Col flex="1 1 200px">
          <Metric label="Вернулись" value={s?.returned ?? '—'} note="открывали страницу раньше" />
        </Col>
        <Col flex="1 1 200px">
          <Metric label="Сидят в среднем" value={s ? duration(s.avg_seconds) : '—'} note={s ? `половина — дольше ${duration(s.median_seconds)}` : ''} />
        </Col>
        <Col flex="1 1 200px">
          <Metric label="Всего уникальных" value={s?.total_unique ?? '—'} note={s?.first_seen ? `с ${dayjs(s.first_seen).format('D MMM YYYY')}` : 'пока никого'} />
        </Col>
      </Row>

      <Card loading={isLoading} title="Посетители по дням"
        extra={<Flex gap={14}><Typography.Text type="secondary" style={{ fontSize: 12 }}><span style={{ display: 'inline-block', width: 10, height: 10, background: '#155EEF', borderRadius: 2, marginRight: 6 }} />новые</Typography.Text><Typography.Text type="secondary" style={{ fontSize: 12 }}><span style={{ display: 'inline-block', width: 10, height: 10, background: '#C6D9FD', borderRadius: 2, marginRight: 6 }} />вернулись</Typography.Text></Flex>}>
        {s && s.days.length > 0 ? <DaysChart days={s.days} /> : <Empty description="Пока никто не заходил" />}
      </Card>

      <Row gutter={[20, 20]}>
        <Col xs={24} xl={15}>
          <Card title={<Flex align="center" gap={8}><span style={{ width: 10, height: 10, borderRadius: 5, background: '#12B76A', display: 'inline-block' }} />Сейчас на странице · {s?.now ?? 0}</Flex>} loading={isLoading}>
            <Flex vertical gap={10}>
              {s && s.now_list.length === 0 && <Typography.Text type="secondary">Сейчас никто не смотрит страницу.</Typography.Text>}
              {s?.now_list.map((v) => (
                <Flex key={v.visitor + v.started_at} align="center" gap={12} style={{ border: '1px solid #EAECF0', borderRadius: 12, padding: '12px 14px' }}>
                  <DeviceIcon kind={v.kind} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 800 }}>{v.visitor}</div>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>{v.device} · {v.source === 'Прямая ссылка' ? 'прямая ссылка' : `пришёл из ${v.source}`}</Typography.Text>
                  </div>
                  <Flex vertical align="end" gap={4}>
                    <NewTag isNew={v.is_new} />
                    <Typography.Text style={{ fontSize: 12, fontWeight: 600 }}>на странице {duration(v.seconds)}</Typography.Text>
                  </Flex>
                </Flex>
              ))}
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>Пропадает из списка через минуту после того, как посетитель закрыл вкладку.</Typography.Text>
            </Flex>
          </Card>
        </Col>
        <Col xs={24} xl={9}>
          <Card title={`Откуда пришли · ${periodLabel[period]}`} loading={isLoading}>
            {s && s.sources.length === 0 && <Typography.Text type="secondary">Пока нет визитов.</Typography.Text>}
            <Flex vertical gap={12}>
              {s?.sources.map((src) => (
                <div key={src.source}>
                  <Flex justify="space-between"><Typography.Text strong>{src.source}</Typography.Text><Typography.Text strong>{src.visitors}</Typography.Text></Flex>
                  <Progress percent={(src.visitors / Math.max(1, s.sources[0].visitors)) * 100} showInfo={false} size="small" strokeColor="#155EEF" />
                </div>
              ))}
            </Flex>
          </Card>
        </Col>
      </Row>

      <Card title="Последние визиты" loading={isLoading} extra={s && <Typography.Text type="secondary" style={{ fontSize: 12 }}>визитов {periodLabel[period]}: {s.visits}</Typography.Text>}>
        <Table<Visit>
          size="middle"
          rowKey={(v) => v.visitor + v.started_at}
          dataSource={s?.recent ?? []}
          pagination={false}
          scroll={{ x: 900 }}
          locale={{ emptyText: 'Пока нет визитов' }}
          columns={[
            { title: 'Когда', dataIndex: 'started_at', render: (v: string) => when(v) },
            { title: 'Посетитель', dataIndex: 'visitor', render: (v: string) => <b>{v}</b> },
            { title: '', dataIndex: 'is_new', render: (v: boolean) => <NewTag isNew={v} /> },
            { title: 'Сидел', dataIndex: 'seconds', render: (v: number) => duration(v) },
            { title: 'Устройство', dataIndex: 'device' },
            { title: 'Откуда', dataIndex: 'source' },
            { title: 'Визитов', dataIndex: 'visits', align: 'right' },
          ]}
        />
      </Card>

      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
        Свои заходы не считать: откройте один раз {SITE}/?notrack на своих устройствах. Вернуть подсчёт — {SITE}/?track.
      </Typography.Text>
    </Flex>
  )
}

/** Зелёная цифра у пункта меню — сколько людей сейчас на странице. */
export function InvestNowBadge() {
  const { data } = useQuery({
    queryKey: ['/admin/invest/now'],
    queryFn: () => api.get<{ now: number }>('/admin/invest/now'),
    refetchInterval: 30_000,
  })
  if (!data?.now) return null
  return (
    <span style={{ background: '#12B76A', color: '#fff', borderRadius: 9, padding: '0 7px', fontSize: 11, fontWeight: 700, lineHeight: '17px', display: 'inline-block' }}>
      {data.now}
    </span>
  )
}
