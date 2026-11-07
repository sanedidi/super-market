// Магазины → Продажники (Figma «Супер-админ · Продажники», С1–С3): продажники
// Super Market ходят по районам с приложением «SM Продажник», путь пишется во
// время обхода. «Сейчас» — кто в обходе и где; «Маршрут за день» — путь,
// хронология, км и повтор чужого пути; «Покрытие районов» — сколько клеток
// 100×100 м района обойдено (навсегда); «Продажники» — логины и районы.
/* eslint-disable @typescript-eslint/no-explicit-any */
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import dayjs from 'dayjs'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Alert,
  App,
  Avatar,
  Button,
  Card,
  DatePicker,
  Empty,
  Flex,
  Form,
  Input,
  Modal,
  Progress,
  Segmented,
  Select,
  Space,
  Spin,
  Table,
  Tag,
  Typography,
} from 'antd'
import { EditOutlined, EnvironmentOutlined, PlusOutlined, ReloadOutlined, UndoOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, PhoneInput, api, dateTime, errorText, formatPhone, normalizeUzPhone, phoneRule, useFitMap, useYmaps, TASHKENT } from '@sm/shared'
import { useUrlState } from '../hooks'

// ------------------------------------------------------------------ типы

interface Results {
  lead: number
  refused: number
  closed: number
  later: number
  ours: number
  total: number
}

interface Walk {
  id: string
  rep_id: string
  status: 'active' | 'paused' | 'ended'
  started_at: string
  ended_at: string | null
  end_reason: '' | 'manual' | 'auto'
  paused_at: string | null
  auto_paused: boolean
  active_sec: number
  distance_m: number
  other_m: number
  new_cells: number
  points: number
  mock_points: number
  gaps: number
  last_lat: number | null
  last_lng: number | null
  last_at: string | null
  results: Results
}

interface Rep {
  id: string
  full_name: string
  phone: string
  login: string
  district_id: string | null
  district_name: string
  status: 'active' | 'blocked'
  color: string
  last_login_at: string | null
  created_at: string
  locked: boolean
}

interface DayTotals {
  distance_m: number
  active_sec: number
  places: number
  leads: number
  other_m: number
}

interface LiveRep extends Rep {
  state: 'walking' | 'paused' | 'no_signal' | 'off'
  walk: Walk | null
  today: DayTotals
  ended_at: string | null
}

interface Live {
  reps: LiveRep[]
  walking: number
  total: number
  today: DayTotals
  other_pct: number
}

interface Grid {
  lat: number
  lng: number
}

interface Place {
  id: string
  lat: number
  lng: number
  name: string
  result: Result
  last_visit_at: string
  rep_name: string
  remind_on: string | null
  photo_url: string
  visits: number
  lead_status: string
}

interface MapData {
  grid: Grid
  cells: [number, number, number][]
  tracks: { walk_id: string; rep_id: string; color: string; today: boolean; pts: [number, number][] }[]
  places: Place[]
  truncated: boolean
}

type Result = 'lead' | 'refused' | 'closed' | 'later' | 'ours'

interface Visit {
  id: string
  place_id: string
  result: Result
  name: string
  reason: string
  program: string
  comment: string
  photo_url: string
  remind_on: string | null
  lat: number
  lng: number
  created_at: string
}

interface DayEvent {
  at: string
  kind: 'start' | 'pause' | 'resume' | 'auto_pause' | 'finish' | 'auto_finish' | 'other' | 'visit'
  lat: number | null
  lng: number | null
  data?: Record<string, any>
  visit?: Visit
}

interface Day {
  rep: Rep
  date: string
  walks: (Walk & { pts: [number, number][] })[]
  events: DayEvent[]
  totals: DayTotals
  other_pct: number
  new_cells: number
  mock_points: number
  gaps: number
}

interface District {
  id: string
  name: string
  name_uz: string
  boundary: [number, number][]
  total_cells: number
  covered_cells: number
  coverage_pct: number | null
  reps: string[]
  places: number
  connected: number
  last_walk_at: string | null
  walking: boolean
}

interface Districts {
  items: District[]
  total_cells: number
  covered_cells: number
  coverage_pct: number | null
}

// ------------------------------------------------------------- подписи

export const RESULTS: Record<Result, { label: string; color: string }> = {
  lead: { label: 'Подключить', color: '#16A34A' },
  refused: { label: 'Отказ', color: '#3F3F46' },
  closed: { label: 'Закрыт', color: '#A1A1AA' },
  later: { label: 'Прийти позже', color: '#D97706' },
  ours: { label: 'Уже с Super Market', color: '#E11D2A' },
}

const REASONS: Record<string, string> = {
  expensive: 'Дорого',
  has_program: 'Уже есть программа',
  not_interested: 'Не интересно',
  no_trust: 'Не доверяют',
  owner_against: 'Владелец против',
  other: 'Другое',
}

const PROGRAMS: Record<string, string> = { billz: 'BILLZ', regos: 'REGOS', '1c': '1С', notebook: 'Тетрадь', other: 'Другая' }

function km(m: number | null | undefined): string {
  const v = m ?? 0
  if (v < 1000) return `${Math.round(v / 10) * 10} м`
  return `${(v / 1000).toFixed(1).replace('.', ',')} км`
}

function dur(sec: number): string {
  const m = Math.round(sec / 60)
  const h = Math.floor(m / 60)
  if (!h) return `${m} мин`
  return m % 60 ? `${h} ч ${m % 60} мин` : `${h} ч`
}

function clock(sec: number): string {
  const h = Math.floor(sec / 3600)
  const m = Math.floor((sec % 3600) / 60)
  return h ? `${h}:${String(m).padStart(2, '0')}` : `0:${String(m).padStart(2, '0')}`
}

function hm(v: string | null | undefined): string {
  return v ? dayjs(v).format('H:mm') : ''
}

function pct(v: number | null | undefined): string {
  if (v === null || v === undefined) return '—'
  return `${String(Math.round(v * 10) / 10).replace('.', ',')}%`
}

function initials(name: string) {
  const w = name.trim().split(/\s+/).filter(Boolean)
  if (!w.length) return '?'
  return (w.length === 1 ? w[0].slice(0, 2) : w[0][0] + w[1][0]).toUpperCase()
}

function RepAvatar({ rep, size = 36 }: { rep: Pick<Rep, 'full_name' | 'color'>; size?: number }) {
  return (
    <Avatar size={size} style={{ background: rep.color, fontWeight: 700, flex: 'none' }}>
      {initials(rep.full_name)}
    </Avatar>
  )
}

function stateTag(r: LiveRep): ReactNode {
  switch (r.state) {
    case 'walking':
      return <Tag color="green">В обходе · {clock(r.walk?.active_sec ?? 0)}</Tag>
    case 'paused':
      return <Tag color="orange">{r.walk?.auto_paused ? 'Стоит на месте' : 'Пауза'}</Tag>
    case 'no_signal':
      return <Tag color="red">Нет сигнала · {r.walk?.last_at ? `${Math.max(1, dayjs().diff(dayjs(r.walk.last_at), 'minute'))} мин` : 'с начала'}</Tag>
    default:
      return <Tag>Не в обходе</Tag>
  }
}

// --------------------------------------------------------------- карта

/** Карта Яндекса в контейнере; объекты рисует draw(map) при каждом изменении deps. */
function useYMap(box: React.RefObject<HTMLDivElement | null>, center: [number, number], zoom: number) {
  const { ymaps, error } = useYmaps()
  const [map, setMap] = useState<any>(null)
  useEffect(() => {
    if (!ymaps || !box.current) return
    const m = new ymaps.Map(box.current, { center, zoom, controls: ['zoomControl', 'geolocationControl'] }, { suppressMapOpenBlock: true })
    setMap(m)
    return () => {
      m.destroy()
      setMap(null)
    }
    // Карта создаётся один раз.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ymaps])
  useFitMap(box, map)
  return { ymaps, map, error }
}

/** Слой объектов карты: при каждом вызове set старые объекты слоя убираются. */
function useLayer(ymaps: any, map: any) {
  const col = useRef<any>(null)
  useEffect(() => {
    if (!ymaps || !map) return
    const c = new ymaps.GeoObjectCollection()
    map.geoObjects.add(c)
    col.current = c
    return () => {
      map.geoObjects.remove(c)
      col.current = null
    }
  }, [ymaps, map])
  return col
}

function cellPolygon(ymaps: any, g: Grid, cx: number, cy: number, fill: string, opacity: number) {
  const s = cy * g.lat
  const w = cx * g.lng
  const n = (cy + 1) * g.lat
  const e = (cx + 1) * g.lng
  return new ymaps.Polygon([[[s, w], [n, w], [n, e], [s, e], [s, w]]], {}, { fillColor: fill, fillOpacity: opacity, strokeWidth: 0, interactivityModel: 'default#transparent' })
}

function placeMark(ymaps: any, p: { lat: number; lng: number; result: Result }, hint: string, onClick?: () => void) {
  const pm = new ymaps.Placemark([p.lat, p.lng], { hintContent: hint }, { preset: 'islands#circleDotIcon', iconColor: RESULTS[p.result]?.color ?? '#3F3F46' })
  if (onClick) pm.events.add('click', onClick)
  return pm
}

/** Обойдённые клетки, линии пути и магазины видимой области (GET /admin/field/map). */
function CoverageLayers({ ymaps, map, colors, reload, onPlace }: { ymaps: any; map: any; colors: boolean; reload: number; onPlace: (id: string) => void }) {
  const cells = useLayer(ymaps, map)
  const lines = useLayer(ymaps, map)
  const places = useLayer(ymaps, map)
  const [bounds, setBounds] = useState<number[][] | null>(null)
  const [data, setData] = useState<MapData | null>(null)

  useEffect(() => {
    if (!map) return
    let t: ReturnType<typeof setTimeout> | undefined
    const update = () => {
      clearTimeout(t)
      t = setTimeout(() => setBounds(map.getBounds()), 400)
    }
    map.events.add('boundschange', update)
    update()
    return () => {
      clearTimeout(t)
      map.events.remove('boundschange', update)
    }
  }, [map])

  useEffect(() => {
    if (!bounds) return
    let alive = true
    const [[s, w], [n, e]] = bounds
    api
      .get<MapData>('/admin/field/map', { min_lat: s.toFixed(6), min_lng: w.toFixed(6), max_lat: n.toFixed(6), max_lng: e.toFixed(6) })
      .then((d) => alive && setData(d))
      .catch(() => {})
    return () => {
      alive = false
    }
  }, [bounds, reload])

  useEffect(() => {
    if (!ymaps || !data) return
    cells.current?.removeAll()
    lines.current?.removeAll()
    places.current?.removeAll()
    // Клетки рисуем только вблизи (иначе их слишком много).
    if (map.getZoom() >= 14) {
      for (const [cx, cy] of data.cells) cells.current?.add(cellPolygon(ymaps, data.grid, cx, cy, '#3F3F46', 0.12))
    }
    // Прошлые обходы — серым снизу, сегодняшние — цветом продажника сверху.
    const sorted = [...data.tracks].sort((a, b) => Number(a.today) - Number(b.today))
    for (const t of sorted) {
      const today = colors && t.today
      lines.current?.add(
        new ymaps.Polyline(t.pts, {}, { strokeColor: today ? t.color : '#A1A1AA', strokeWidth: today ? 4 : 3, strokeOpacity: today ? 0.95 : 0.8 }),
      )
    }
    for (const p of data.places) {
      places.current?.add(placeMark(ymaps, p, `${p.name || RESULTS[p.result].label} · ${RESULTS[p.result].label} · ${p.rep_name}`, () => onPlace(p.id)))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ymaps, data, colors])
  return data?.truncated ? (
    <div className="sm-map-hint" style={{ top: 8 }}>
      Слишком много данных — приблизьте карту
    </div>
  ) : null
}

/** Карточка магазина: результат и история визитов. */
function PlaceModal({ id, onClose }: { id: string | null; onClose: () => void }) {
  const q = useQuery({
    queryKey: ['field-place', id],
    queryFn: () => api.get<Place & { history: (Visit & { rep_name: string })[] }>(`/admin/field/places/${id}`),
    enabled: !!id,
  })
  const p = q.data
  return (
    <Modal open={!!id} onCancel={onClose} footer={null} title={p ? p.name || 'Магазин без названия' : 'Магазин'} width={520} destroyOnClose>
      {q.isLoading && <Spin />}
      {q.error && <LoadError error={q.error} />}
      {p && (
        <Flex vertical gap={12}>
          <Space wrap>
            <Tag color={RESULTS[p.result].color}>{RESULTS[p.result].label}</Tag>
            {p.remind_on && <Tag>прийти {dayjs(p.remind_on).format('DD.MM')}</Tag>}
            <Typography.Text type="secondary">визитов: {p.visits}</Typography.Text>
          </Space>
          {p.photo_url && <img src={p.photo_url} alt="" style={{ width: '100%', borderRadius: 12, maxHeight: 280, objectFit: 'cover' }} />}
          {p.history.map((v) => (
            <Card key={v.id} size="small">
              <Flex justify="space-between">
                <Typography.Text strong style={{ color: RESULTS[v.result].color }}>
                  {RESULTS[v.result].label}
                </Typography.Text>
                <Typography.Text type="secondary">{dateTime(v.created_at)}</Typography.Text>
              </Flex>
              <div style={{ fontSize: 13 }}>
                {v.rep_name}
                {v.reason && ` · ${REASONS[v.reason] ?? v.reason}`}
                {v.program && ` · ${PROGRAMS[v.program] ?? v.program}`}
                {v.remind_on && ` · прийти ${dayjs(v.remind_on).format('DD.MM')}`}
              </div>
              {v.comment && <div style={{ fontSize: 13, color: '#667085' }}>«{v.comment}»</div>}
            </Card>
          ))}
        </Flex>
      )}
    </Modal>
  )
}

// ---------------------------------------------------------- С1 «Сейчас»

function Kpi({ value, label, color }: { value: ReactNode; label: string; color?: string }) {
  return (
    <Card size="small" style={{ flex: 1, minWidth: 180 }}>
      <div style={{ fontSize: 22, fontWeight: 700, color }}>{value}</div>
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
        {label}
      </Typography.Text>
    </Card>
  )
}

function Now({ onDay }: { onDay: (repId: string) => void }) {
  const live = useQuery({ queryKey: ['field-live'], queryFn: () => api.get<Live>('/admin/field/live'), refetchInterval: 30_000 })
  const box = useRef<HTMLDivElement>(null)
  const { ymaps, map, error } = useYMap(box, [TASHKENT.lat, TASHKENT.lng], 12)
  const markers = useLayer(ymaps, map)
  const [reload, setReload] = useState(0)
  const [place, setPlace] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const centered = useRef(false)
  const reps = live.data?.reps ?? []

  // Сейчас на карте — точка продажника в обходе с подписью.
  useEffect(() => {
    if (!ymaps || !markers.current) return
    markers.current.removeAll()
    const pts: number[][] = []
    for (const r of reps) {
      const w = r.walk
      if (!w || w.last_lat === null || w.last_lng === null) continue
      pts.push([w.last_lat, w.last_lng])
      const caption = `${r.full_name.split(' ')[0]} · ${r.state === 'paused' ? 'пауза' : r.state === 'no_signal' ? 'нет сигнала' : clock(w.active_sec)}`
      markers.current.add(
        new ymaps.Placemark([w.last_lat, w.last_lng], { iconCaption: caption, hintContent: `${r.full_name} · ${km(w.distance_m)}` }, { preset: 'islands#circleIcon', iconColor: r.color }),
      )
    }
    if (!centered.current && pts.length) {
      centered.current = true
      if (pts.length === 1) map.setCenter(pts[0], 15)
      else map.setBounds(ymaps.util.bounds.fromPoints(pts), { checkZoomRange: true, zoomMargin: 60 })
    }
    setReload((n) => n + 1)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ymaps, live.data])

  const focus = (r: LiveRep) => {
    setSelected(r.id)
    if (map && r.walk?.last_lat != null && r.walk.last_lng != null) map.setCenter([r.walk.last_lat, r.walk.last_lng], 16, { duration: 300 })
  }

  if (live.error) return <LoadError error={live.error} retry={live.refetch} />
  const d = live.data
  return (
    <Flex vertical gap={16}>
      <Flex gap={12} wrap>
        <Kpi value={d ? `${d.walking} из ${d.total}` : '—'} label="сейчас в обходе" color="#067647" />
        <Kpi value={km(d?.today.distance_m)} label="пройдено сегодня" />
        <Kpi value={d?.today.places ?? 0} label={`магазинов отмечено · ${d?.today.leads ?? 0} заявок`} />
        <Kpi value={`${km(d?.today.other_m)} · ${d?.other_pct ?? 0}%`} label="по чужому пути сегодня" color={d && d.other_pct > 0 ? '#b42318' : undefined} />
      </Flex>
      <Flex gap={16} align="flex-start">
        <Card size="small" style={{ width: 360, flex: 'none' }} styles={{ body: { padding: 6 } }}>
          {!d && <Spin style={{ margin: 24 }} />}
          {d && reps.length === 0 && <Empty style={{ margin: 24 }} description="Продажников ещё нет — добавьте во вкладке «Продажники»" />}
          {reps.map((r) => (
            <div
              key={r.id}
              onClick={() => focus(r)}
              style={{ display: 'flex', gap: 12, padding: '10px 10px', borderRadius: 12, cursor: 'pointer', background: selected === r.id ? '#fef3f2' : undefined }}
            >
              <RepAvatar rep={r} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div>
                  <Typography.Text strong>{r.full_name}</Typography.Text>
                  {r.district_name && <Typography.Text type="secondary" style={{ fontSize: 12 }}> · {r.district_name}</Typography.Text>}
                </div>
                <div style={{ margin: '3px 0' }}>{stateTag(r)}</div>
                <div style={{ fontSize: 12, color: '#667085' }}>
                  {r.state === 'off' && r.ended_at
                    ? `сегодня ${km(r.today.distance_m)} · закончил в ${hm(r.ended_at)}`
                    : `${km(r.today.distance_m)} · ${r.today.places} магазинов${r.today.leads ? ` · +${r.today.leads} заявки` : ''}`}
                </div>
                <Button size="small" type="link" style={{ padding: 0, height: 'auto' }} onClick={(e) => {
                    e.stopPropagation()
                    onDay(r.id)
                  }}>
                  Маршрут за день →
                </Button>
              </div>
            </div>
          ))}
        </Card>
        <div style={{ flex: 1, minWidth: 0 }}>
          {error ? (
            <Alert type="error" showIcon message={error} />
          ) : (
            <div className="sm-map" style={{ height: 640, borderRadius: 16, overflow: 'hidden' }}>
              <div ref={box} style={{ position: 'absolute', inset: 0 }} />
              {!ymaps && <Spin style={{ position: 'absolute', inset: 0, margin: 'auto', height: 32 }} />}
              {ymaps && map && <CoverageLayers ymaps={ymaps} map={map} colors reload={reload} onPlace={setPlace} />}
            </div>
          )}
          <Space size={16} wrap style={{ marginTop: 8, fontSize: 12, color: '#667085' }}>
            <span>Цвет — продажник, линия — путь сегодня</span>
            <span style={{ color: '#A1A1AA' }}>━ прошлые обходы</span>
            <span>▦ затемнённые клетки — обойдено навсегда, белые — никто не был</span>
            {Object.entries(RESULTS).map(([k, r]) => (
              <span key={k}>
                <span style={{ color: r.color }}>●</span> {r.label}
              </span>
            ))}
          </Space>
        </div>
      </Flex>
      <PlaceModal id={place} onClose={() => setPlace(null)} />
    </Flex>
  )
}

// -------------------------------------------------- С2 «Маршрут за день»

const EVENT_TEXT: Record<DayEvent['kind'], string> = {
  start: 'Начал обход',
  pause: 'Пауза',
  resume: 'Продолжил',
  auto_pause: 'Стоит на месте — пауза',
  finish: 'Закончил обход',
  auto_finish: 'Обход закрыт автоматически',
  other: 'Зашёл в обойдённую зону',
  visit: '',
}

function DayRoute({ repId, setRepId }: { repId: string | undefined; setRepId: (v: string | undefined) => void }) {
  const [date, setDate] = useUrlState('date')
  const reps = useQuery({ queryKey: ['field-reps'], queryFn: () => api.get<{ items: Rep[] }>('/admin/field/reps') })
  const day = useQuery({
    queryKey: ['field-day', repId, date],
    queryFn: () => api.get<Day>(`/admin/field/reps/${repId}/day`, { date }),
    enabled: !!repId,
  })
  const box = useRef<HTMLDivElement>(null)
  const { ymaps, map, error } = useYMap(box, [TASHKENT.lat, TASHKENT.lng], 12)
  const layer = useLayer(ymaps, map)
  const [place, setPlace] = useState<string | null>(null)
  const d = day.data

  useEffect(() => {
    if (!ymaps || !map || !layer.current) return
    layer.current.removeAll()
    if (!d) return
    const all: number[][] = []
    for (const w of d.walks) {
      if (w.pts.length > 1) layer.current.add(new ymaps.Polyline(w.pts, { hintContent: `${hm(w.started_at)}–${hm(w.ended_at)} · ${km(w.distance_m)}` }, { strokeColor: d.rep.color, strokeWidth: 5, strokeOpacity: 0.9 }))
      all.push(...w.pts)
      if (w.pts.length) {
        layer.current.add(new ymaps.Placemark(w.pts[0], { hintContent: `Старт ${hm(w.started_at)}` }, { preset: 'islands#greenCircleDotIcon' }))
        if (w.status === 'ended') layer.current.add(new ymaps.Placemark(w.pts[w.pts.length - 1], { hintContent: `Финиш ${hm(w.ended_at)}` }, { preset: 'islands#blackCircleDotIcon' }))
      }
    }
    for (const e of d.events) {
      if (e.kind === 'visit' && e.visit) {
        const v = e.visit
        layer.current.add(placeMark(ymaps, v, `${hm(e.at)} · ${v.name || RESULTS[v.result].label} · ${RESULTS[v.result].label}`))
      }
    }
    if (all.length > 1) map.setBounds(ymaps.util.bounds.fromPoints(all), { checkZoomRange: true, zoomMargin: 40 })
    else if (all.length === 1) map.setCenter(all[0], 16)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ymaps, map, d])

  return (
    <Flex vertical gap={16}>
      <Space wrap>
        <Select
          style={{ width: 280 }}
          placeholder="Продажник"
          value={repId}
          onChange={(v) => setRepId(v)}
          loading={reps.isLoading}
          showSearch
          optionFilterProp="label"
          options={(reps.data?.items ?? []).map((r) => ({ value: r.id, label: `${r.full_name}${r.district_name ? ` · ${r.district_name}` : ''}` }))}
        />
        <DatePicker
          allowClear={false}
          format="DD.MM.YYYY"
          value={date ? dayjs(date) : dayjs()}
          disabledDate={(v) => v.isAfter(dayjs(), 'day')}
          onChange={(v) => setDate(v && !v.isSame(dayjs(), 'day') ? v.format('YYYY-MM-DD') : undefined)}
        />
      </Space>
      {!repId && <Empty description="Выберите продажника" />}
      {day.error && <LoadError error={day.error} retry={day.refetch} />}
      {repId && (
        <Flex gap={16} align="flex-start">
          <div style={{ flex: 1, minWidth: 0 }}>
            {error ? (
              <Alert type="error" showIcon message={error} />
            ) : (
              <div className="sm-map" style={{ height: 560, borderRadius: 16, overflow: 'hidden' }}>
                <div ref={box} style={{ position: 'absolute', inset: 0 }} />
                {(!ymaps || day.isLoading) && <Spin style={{ position: 'absolute', inset: 0, margin: 'auto', height: 32 }} />}
              </div>
            )}
          </div>
          <Card size="small" style={{ width: 420, flex: 'none' }}>
            {d && (
              <Flex vertical gap={12}>
                <Flex gap={10} align="center">
                  <RepAvatar rep={d.rep} size={40} />
                  <div>
                    <Typography.Text strong style={{ fontSize: 16 }}>
                      {d.rep.full_name}
                    </Typography.Text>
                    <div style={{ fontSize: 12, color: '#667085' }}>
                      {d.rep.district_name || 'район не назначен'} · {formatPhone(d.rep.phone)}
                    </div>
                  </div>
                </Flex>
                <Flex gap={8} wrap>
                  <Kpi value={km(d.totals.distance_m)} label="пройдено" />
                  <Kpi value={dur(d.totals.active_sec)} label={d.walks.length ? `${hm(d.walks[0].started_at)} – ${hm(d.walks[d.walks.length - 1].ended_at) || 'сейчас'}` : 'в обходе'} />
                  <Kpi value={d.totals.places} label={`магазинов · ${d.totals.leads} заявки`} />
                  <Kpi value={`${km(d.totals.other_m)} · ${d.other_pct}%`} label="по чужому пути" color={d.other_pct > 0 ? '#b42318' : undefined} />
                </Flex>
                {d.walks.length > 0 &&
                  (d.mock_points > 0 ? (
                    <Alert type="error" showIcon message={`Поддельная геопозиция: ${d.mock_points} точек — в путь не засчитаны`} />
                  ) : (
                    <Alert
                      type="success"
                      showIcon
                      message={`GPS в порядке: поддельной геопозиции нет.${d.gaps ? ` ${d.gaps} раз(а) не было связи или GPS дольше 2 минут.` : ''}`}
                    />
                  ))}
                <Typography.Text strong>Хронология</Typography.Text>
                {d.events.length === 0 && <Typography.Text type="secondary">В этот день обходов не было</Typography.Text>}
                <Flex vertical gap={8}>
                  {d.events.map((e, i) => (
                    <Flex key={i} gap={10}>
                      <Typography.Text type="secondary" style={{ width: 42, flex: 'none' }}>
                        {hm(e.at)}
                      </Typography.Text>
                      {e.kind === 'visit' && e.visit ? (
                        <div style={{ cursor: 'pointer' }} onClick={() => e.visit && setPlace(e.visit.place_id)}>
                          <span style={{ color: RESULTS[e.visit.result].color }}>●</span>{' '}
                          <b>{e.visit.name || 'Магазин'}</b> — {RESULTS[e.visit.result].label.toLowerCase()}
                          {e.visit.reason && ` «${REASONS[e.visit.reason] ?? e.visit.reason}»`}
                          {e.visit.comment && <div style={{ fontSize: 12, color: '#667085' }}>«{e.visit.comment}»</div>}
                        </div>
                      ) : (
                        <div>
                          <span style={{ color: e.kind === 'other' ? '#b42318' : undefined }}>{EVENT_TEXT[e.kind]}</span>
                          {e.kind === 'other' && e.data?.rep_name && (
                            <div style={{ fontSize: 12, color: '#667085' }}>
                              там уже прошёл {e.data.rep_name}
                              {e.data.first_at && ` ${dayjs(e.data.first_at).format('DD.MM')}`}
                            </div>
                          )}
                          {e.kind === 'resume' && e.data?.auto && <div style={{ fontSize: 12, color: '#667085' }}>снова пошёл</div>}
                        </div>
                      )}
                    </Flex>
                  ))}
                </Flex>
              </Flex>
            )}
          </Card>
        </Flex>
      )}
      <PlaceModal id={place} onClose={() => setPlace(null)} />
    </Flex>
  )
}

// ------------------------------------------------- С3 «Покрытие районов»

function BoundaryModal({ district, onClose }: { district: District | null; onClose: () => void }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const box = useRef<HTMLDivElement>(null)
  const { ymaps, map, error } = useYMap(box, [TASHKENT.lat, TASHKENT.lng], 12)
  const poly = useRef<any>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!ymaps || !map || !district) return
    const coords = district.boundary.length ? [district.boundary] : [[]]
    const p = new ymaps.Polygon(coords, {}, { editorDrawingCursor: 'crosshair', fillColor: '#E11D2A', fillOpacity: 0.12, strokeColor: '#E11D2A', strokeWidth: 3 })
    map.geoObjects.add(p)
    poly.current = p
    if (district.boundary.length) {
      map.setBounds(p.geometry.getBounds(), { checkZoomRange: true, zoomMargin: 30 })
      p.editor.startEditing()
    } else {
      p.editor.startDrawing()
    }
    return () => {
      map.geoObjects.remove(p)
      poly.current = null
    }
  }, [ymaps, map, district])

  const save = async (clear = false) => {
    if (!district) return
    let ring: number[][] = []
    if (!clear && poly.current) {
      ring = (poly.current.geometry.getCoordinates()[0] ?? []) as number[][]
      if (ring.length > 1) {
        const [a, b] = [ring[0], ring[ring.length - 1]]
        if (a[0] === b[0] && a[1] === b[1]) ring = ring.slice(0, -1)
      }
      if (ring.length < 3) {
        message.error('Поставьте на карте хотя бы 3 точки границы')
        return
      }
    }
    setBusy(true)
    try {
      await api.put(`/admin/field/districts/${district.id}/boundary`, { boundary: ring.map(([lat, lng]) => [+lat.toFixed(6), +lng.toFixed(6)]) })
      message.success(clear ? 'Граница убрана' : 'Граница сохранена — покрытие пересчитано')
      qc.invalidateQueries({ queryKey: ['field-districts'] })
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={!!district}
      onCancel={onClose}
      width={900}
      title={district ? `Граница района «${district.name}»` : ''}
      destroyOnClose
      footer={
        <Space>
          {district?.boundary.length ? (
            <Button danger onClick={() => save(true)} loading={busy}>
              Убрать границу
            </Button>
          ) : null}
          <Button onClick={onClose}>Отмена</Button>
          <Button type="primary" onClick={() => save()} loading={busy}>
            Сохранить
          </Button>
        </Space>
      }
    >
      <Typography.Paragraph type="secondary">
        Кликайте по карте — точки границы. Точки можно двигать, правой кнопкой — удалить. Клетки 100×100 м, у которых середина внутри границы, и есть
        район.
      </Typography.Paragraph>
      {error ? (
        <Alert type="error" showIcon message={error} />
      ) : (
        <div className="sm-map" style={{ height: 520 }}>
          <div ref={box} style={{ position: 'absolute', inset: 0 }} />
          {!ymaps && <Spin style={{ position: 'absolute', inset: 0, margin: 'auto', height: 32 }} />}
        </div>
      )}
    </Modal>
  )
}

function Coverage() {
  const { message, modal } = App.useApp()
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['field-districts'], queryFn: () => api.get<Districts>('/admin/field/districts') })
  const [edit, setEdit] = useState<District | null>(null)
  if (q.error) return <LoadError error={q.error} retry={q.refetch} />
  const reset = (d: District) =>
    modal.confirm({
      title: `Сбросить покрытие района «${d.name}»?`,
      content: 'Обойдённые клетки района снова станут белыми — район обходят заново. Пути и отметки магазинов останутся.',
      okText: 'Сбросить',
      okButtonProps: { danger: true },
      onOk: async () => {
        try {
          await api.post(`/admin/field/districts/${d.id}/reset`)
          message.success('Покрытие сброшено')
          qc.invalidateQueries({ queryKey: ['field-districts'] })
        } catch (e) {
          message.error(errorText(e))
        }
      },
    })
  return (
    <Card
      size="small"
      title="Покрытие районов Ташкента"
      extra={q.data?.coverage_pct != null && <Tag color="red">Ташкент · {pct(q.data.coverage_pct)}</Tag>}
    >
      <Typography.Paragraph type="secondary" style={{ fontSize: 12 }}>
        Клетка 100×100 м считается обойдённой навсегда, когда через неё прошёл любой продажник. Без границы района процент не считается — нарисуйте её
        один раз.
      </Typography.Paragraph>
      <Table<District>
        size="small"
        rowKey="id"
        loading={q.isLoading}
        pagination={false}
        dataSource={q.data?.items ?? []}
        columns={[
          { title: 'Район', dataIndex: 'name', render: (v: string) => <b>{v}</b> },
          { title: 'Продажник', render: (_, d) => (d.reps.length ? d.reps.join(', ') : <span style={{ color: '#98a2b3' }}>—</span>) },
          {
            title: 'Обойдено',
            width: 260,
            render: (_, d) =>
              d.coverage_pct === null ? (
                <Button size="small" icon={<EnvironmentOutlined />} onClick={() => setEdit(d)}>
                  Нарисовать границу
                </Button>
              ) : (
                <Flex gap={8} align="center">
                  <Progress percent={d.coverage_pct} showInfo={false} strokeColor="#E11D2A" size="small" style={{ width: 160, margin: 0 }} />
                  <b>{pct(d.coverage_pct)}</b>
                </Flex>
              ),
          },
          { title: 'Отмечено магазинов', dataIndex: 'places' },
          { title: 'Подключено', dataIndex: 'connected' },
          {
            title: 'Последний обход',
            render: (_, d) =>
              d.walking ? <Tag color="green">сейчас</Tag> : d.last_walk_at ? dateTime(d.last_walk_at) : <span style={{ color: '#b42318' }}>не было</span>,
          },
          {
            title: '',
            width: 90,
            render: (_, d) => (
              <Space size={0}>
                {d.coverage_pct !== null && <Button type="text" icon={<EditOutlined />} title="Изменить границу" onClick={() => setEdit(d)} />}
                {d.coverage_pct !== null && <Button type="text" icon={<UndoOutlined />} title="Сбросить покрытие" onClick={() => reset(d)} />}
              </Space>
            ),
          },
        ]}
      />
      <BoundaryModal district={edit} onClose={() => setEdit(null)} />
    </Card>
  )
}

// -------------------------------------------------------- «Продажники»

interface RepForm {
  full_name: string
  phone: string
  district_id: string | null
  login: string
  password: string
  status: 'active' | 'blocked'
}

function Reps() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const reps = useQuery({ queryKey: ['field-reps'], queryFn: () => api.get<{ items: Rep[] }>('/admin/field/reps') })
  const districts = useQuery({ queryKey: ['field-districts'], queryFn: () => api.get<Districts>('/admin/field/districts') })
  const [edit, setEdit] = useState<Rep | 'new' | null>(null)
  const [form] = Form.useForm<RepForm>()
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!edit) return
    form.resetFields()
    if (edit !== 'new') {
      form.setFieldsValue({ full_name: edit.full_name, phone: edit.phone, district_id: edit.district_id, login: edit.login, password: '', status: edit.status })
    }
  }, [edit, form])

  const save = async () => {
    const v = await form.validateFields()
    setBusy(true)
    try {
      const body = { ...v, phone: normalizeUzPhone(v.phone) ?? v.phone, district_id: v.district_id ?? null }
      if (edit === 'new') {
        await api.post('/admin/field/reps', body)
        message.success('Продажник добавлен — передайте ему логин и пароль')
      } else if (edit) {
        await api.patch(`/admin/field/reps/${edit.id}`, body)
        message.success(v.password ? 'Сохранено — продажник войдёт с новым паролем' : 'Сохранено')
      }
      qc.invalidateQueries({ queryKey: ['field-reps'] })
      qc.invalidateQueries({ queryKey: ['field-live'] })
      setEdit(null)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  if (reps.error) return <LoadError error={reps.error} retry={reps.refetch} />
  return (
    <Card
      size="small"
      title="Продажники"
      extra={
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setEdit('new')}>
          Добавить продажника
        </Button>
      }
    >
      <Typography.Paragraph type="secondary" style={{ fontSize: 12 }}>
        Продажник входит в приложение «SM Продажник» по логину и паролю. Новый пароль или блокировка сразу закрывают его сессии; при блокировке открытый
        обход заканчивается.
      </Typography.Paragraph>
      <Table<Rep>
        size="small"
        rowKey="id"
        loading={reps.isLoading}
        pagination={false}
        dataSource={reps.data?.items ?? []}
        columns={[
          {
            title: 'Продажник',
            render: (_, r) => (
              <Flex gap={10} align="center">
                <RepAvatar rep={r} size={32} />
                <div>
                  <b>{r.full_name}</b>
                  <div style={{ fontSize: 12, color: '#667085' }}>{formatPhone(r.phone)}</div>
                </div>
              </Flex>
            ),
          },
          { title: 'Район', render: (_, r) => r.district_name || <span style={{ color: '#98a2b3' }}>не назначен</span> },
          { title: 'Логин', dataIndex: 'login', render: (v: string, r) => <>{v}{r.locked && <Tag color="red" style={{ marginLeft: 6 }}>вход закрыт 15 мин</Tag>}</> },
          { title: 'Последний вход', render: (_, r) => (r.last_login_at ? dateTime(r.last_login_at) : '—') },
          { title: 'Статус', render: (_, r) => (r.status === 'active' ? <Tag color="green">Работает</Tag> : <Tag>Заблокирован</Tag>) },
          { title: '', width: 50, render: (_, r) => <Button type="text" icon={<EditOutlined />} onClick={() => setEdit(r)} /> },
        ]}
      />
      <Modal
        open={!!edit}
        onCancel={() => setEdit(null)}
        onOk={save}
        okText="Сохранить"
        confirmLoading={busy}
        title={edit === 'new' ? 'Новый продажник' : 'Продажник'}
        destroyOnClose
      >
        <Form form={form} layout="vertical" initialValues={{ status: 'active' }}>
          <Form.Item name="full_name" label="Имя и фамилия" rules={[{ required: true, message: 'Введите имя' }]}>
            <Input maxLength={100} />
          </Form.Item>
          <Form.Item name="phone" label="Телефон" rules={[phoneRule(true)]}>
            <PhoneInput />
          </Form.Item>
          <Form.Item name="district_id" label="Район">
            <Select
              allowClear
              placeholder="Не назначен"
              options={(districts.data?.items ?? []).map((d) => ({ value: d.id, label: d.name }))}
            />
          </Form.Item>
          <Form.Item
            name="login"
            label="Логин"
            rules={[{ required: true, pattern: /^[a-zA-Z0-9][a-zA-Z0-9._-]{2,31}$/, message: 'Латиница, цифры, точка, дефис или _ — от 3 до 32 символов' }]}
          >
            <Input autoComplete="off" />
          </Form.Item>
          <Form.Item
            name="password"
            label={edit === 'new' ? 'Пароль' : 'Новый пароль'}
            extra={edit === 'new' ? 'Не меньше 8 символов' : 'Пусто — оставить прежний'}
            rules={[{ required: edit === 'new', min: 8, message: 'Не меньше 8 символов' }]}
          >
            <Input.Password autoComplete="new-password" />
          </Form.Item>
          {edit !== 'new' && (
            <Form.Item name="status" label="Статус">
              <Segmented
                options={[
                  { value: 'active', label: 'Работает' },
                  { value: 'blocked', label: 'Заблокирован' },
                ]}
              />
            </Form.Item>
          )}
        </Form>
      </Modal>
    </Card>
  )
}

// ------------------------------------------------------------- страница

export function Field() {
  const [tab = 'now', setTab] = useUrlState('tab', 'now')
  const [repId, setRepId] = useUrlState('rep')
  const qc = useQueryClient()
  const tabs = useMemo(
    () => [
      { value: 'now', label: 'Сейчас' },
      { value: 'day', label: 'Маршрут за день' },
      { value: 'coverage', label: 'Покрытие районов' },
      { value: 'reps', label: 'Продажники' },
    ],
    [],
  )
  return (
    <>
      <PageTitle
        title="Продажники"
        extra={
          <Space>
            <Segmented value={tab} onChange={(v) => setTab(String(v))} options={tabs} />
            <Button icon={<ReloadOutlined />} onClick={() => qc.invalidateQueries({ predicate: (q) => String(q.queryKey[0]).startsWith('field-') })} />
          </Space>
        }
      >
        Путь пишется, пока продажник в обходе («SM Продажник»). Пройденные клетки 100×100 м считаются обойдёнными навсегда.
      </PageTitle>
      {tab === 'now' && (
        <Now
          onDay={(id) => {
            setRepId(id)
            setTab('day')
          }}
        />
      )}
      {tab === 'day' && <DayRoute repId={repId} setRepId={(v) => setRepId(v)} />}
      {tab === 'coverage' && <Coverage />}
      {tab === 'reps' && <Reps />}
    </>
  )
}

/** Значок у пункта меню: сколько продажников сейчас в обходе. */
export function FieldBadge() {
  const { data } = useQuery({ queryKey: ['field-live', 'badge'], queryFn: () => api.get<Live>('/admin/field/live'), refetchInterval: 60_000 })
  const n = data?.walking ?? 0
  if (!n) return null
  return (
    <span style={{ background: '#16A34A', color: '#fff', borderRadius: 9, padding: '0 7px', fontSize: 11, fontWeight: 700, lineHeight: '17px', display: 'inline-block' }}>
      {n}
    </span>
  )
}
