// Касса → Залы и столы (Figma П9): залы точки, схема столов на сетке
// (перетащить, растянуть за угол), свойства стола справа; кнопка
// «Режим кафе» открывает П10. Касса показывает ту же схему.
import { useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react'
import { App, Alert, Button, Card, Dropdown, Empty, Flex, Input, InputNumber, Modal, Segmented, Select, Space, Switch, Tag, Typography } from 'antd'
import {
  BorderOutlined,
  CheckOutlined,
  DeleteOutlined,
  EditOutlined,
  InfoCircleOutlined,
  MoreOutlined,
  PlusOutlined,
  SlidersOutlined,
  UserOutlined,
} from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, tr, useItem, useLeaveGuard, useList } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { CafeModeModal } from './CafeMode'
import type { CafeSettings, LayoutHall, TableShape } from './types'

/** Клетка сетки, px. Координаты столов хранятся в клетках. */
const CELL = 24
const MAX_XY = 200
const MAX_WH = 20

type DraftTable = {
  key: string
  id?: string
  number: string
  seats: number
  shape: TableShape
  x: number
  y: number
  w: number
  h: number
  waiter_id: string | null
  bookable: boolean
  service: boolean
  busy: boolean
}

type DraftHall = { key: string; id?: string; name: string; name_uz: string; tables: DraftTable[] }

let seq = 0
const newKey = () => `n${++seq}`

function fromServer(halls: LayoutHall[]): DraftHall[] {
  return halls.map((h) => ({
    key: h.id,
    id: h.id,
    name: h.name_ru || h.name,
    name_uz: h.name_uz,
    tables: h.tables.map((t) => ({
      key: t.id,
      id: t.id,
      number: t.number,
      seats: t.seats,
      shape: t.shape,
      x: t.x,
      y: t.y,
      w: t.w,
      h: t.h,
      waiter_id: t.waiter_id,
      bookable: t.bookable,
      service: t.service,
      busy: t.busy,
    })),
  }))
}

function toInput(storeId: string, halls: DraftHall[]) {
  return {
    store_id: storeId,
    halls: halls.map((h) => ({
      id: h.id ?? null,
      name: h.name,
      name_uz: h.name_uz,
      tables: h.tables.map((t) => ({
        id: t.id ?? null,
        number: t.number,
        seats: t.seats,
        shape: t.shape,
        x: t.x,
        y: t.y,
        w: t.w,
        h: t.h,
        waiter_id: t.waiter_id,
        bookable: t.bookable,
        service: t.service,
      })),
    })),
  }
}

const SIZE: Record<TableShape, [number, number]> = { rect: [4, 4], round: [4, 4], topchan: [6, 4] }

const overlaps = (a: { x: number; y: number; w: number; h: number }, b: { x: number; y: number; w: number; h: number }) =>
  a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h

/** Свободное место для нового стола: слева направо, сверху вниз. */
function freeSpot(tables: DraftTable[], w: number, h: number, cols: number) {
  for (let y = 1; y < MAX_XY - h; y++)
    for (let x = 1; x + w <= Math.max(cols - 1, w + 1); x++) {
      const r = { x, y, w: w + 1, h: h + 1 }
      if (!tables.some((t) => overlaps(r, { x: t.x, y: t.y, w: t.w + 1, h: t.h + 1 }))) return { x, y }
    }
  return { x: 0, y: 0 }
}

function nextNumber(halls: DraftHall[]) {
  let max = 0
  for (const h of halls) for (const t of h.tables) if (/^\d+$/.test(t.number)) max = Math.max(max, Number(t.number))
  return String(max + 1)
}

const shapeLabel = (s: TableShape) => (s === 'round' ? tr('Круг', 'Doira') : s === 'topchan' ? tr('Топчан', 'Soʻri') : tr('Стол', 'Stol'))

type Waiter = { employee_id: string; name: string; can_pos: boolean; has_pin: boolean }

export function HallsPage() {
  const { storeId, can } = useStore()
  const manage = can('stores.manage')
  const layout = useList<LayoutHall>(storeId ? '/store/cafe/halls' : null, { store_id: storeId })
  const settings = useItem<CafeSettings>('/store/cafe/settings')
  const pins = useList<Waiter>(can('staff.manage') && storeId ? '/store/pos/pins' : null, { store_id: storeId })
  const qc = useQueryClient()
  const { message, modal } = App.useApp()

  const [halls, setHalls] = useState<DraftHall[]>([])
  const [base, setBase] = useState('[]')
  const [hallKey, setHallKey] = useState<string | null>(null)
  const [selKey, setSelKey] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [modeOpen, setModeOpen] = useState(false)
  const [hallEdit, setHallEdit] = useState<DraftHall | 'new' | null>(null)
  const [canvasEl, setCanvasEl] = useState<HTMLDivElement | null>(null)
  const [cols, setCols] = useState(34)

  // Загрузка и смена магазина — схема с сервера; пустая точка — «Зал».
  useEffect(() => {
    if (!layout.data) return
    const d = fromServer(layout.data)
    setBase(JSON.stringify(d))
    setHalls(d.length ? d : [{ key: newKey(), name: tr('Зал', 'Zal'), name_uz: '', tables: [] }])
    setHallKey((k) => (k && d.some((h) => h.key === k) ? k : (d[0]?.key ?? null)))
    setSelKey(null)
  }, [layout.data])

  useEffect(() => {
    if (!hallKey && halls.length) setHallKey(halls[0].key)
  }, [halls, hallKey])

  useEffect(() => {
    if (!canvasEl) return
    const ro = new ResizeObserver(() => setCols(Math.floor(canvasEl.clientWidth / CELL)))
    ro.observe(canvasEl)
    return () => ro.disconnect()
  }, [canvasEl])

  const dirty = useMemo(() => JSON.stringify(halls) !== base && !(base === '[]' && halls.every((h) => !h.id && !h.tables.length)), [halls, base])
  useLeaveGuard(dirty)

  const hall = halls.find((h) => h.key === hallKey) ?? halls[0]
  const sel = hall?.tables.find((t) => t.key === selKey) ?? null
  const totalTables = halls.reduce((s, h) => s + h.tables.length, 0)

  const patchHall = (key: string, f: (h: DraftHall) => DraftHall) => setHalls((hs) => hs.map((h) => (h.key === key ? f(h) : h)))
  const patchTable = (key: string, patch: Partial<DraftTable>) =>
    hall && patchHall(hall.key, (h) => ({ ...h, tables: h.tables.map((t) => (t.key === key ? { ...t, ...patch } : t)) }))

  const addTable = (shape: TableShape) => {
    if (!hall) return
    const [w, h] = SIZE[shape]
    const spot = freeSpot(hall.tables, w, h, cols)
    const t: DraftTable = {
      key: newKey(),
      number: nextNumber(halls),
      seats: shape === 'topchan' ? 6 : shape === 'round' ? 2 : 4,
      shape,
      ...spot,
      w,
      h,
      waiter_id: null,
      bookable: true,
      service: true,
      busy: false,
    }
    patchHall(hall.key, (x) => ({ ...x, tables: [...x.tables, t] }))
    setSelKey(t.key)
  }

  const removeTable = (t: DraftTable) => {
    if (!hall) return
    if (t.busy) {
      message.warning(tr(`У стола ${t.number} открыт счёт — удалить нельзя`, `${t.number}-stolda hisob ochiq — oʻchirib boʻlmaydi`))
      return
    }
    patchHall(hall.key, (h) => ({ ...h, tables: h.tables.filter((x) => x.key !== t.key) }))
    setSelKey(null)
  }

  const removeHall = (h: DraftHall) => {
    if (h.tables.some((t) => t.busy)) {
      message.warning(tr('В зале есть столы с открытым счётом', 'Zalda hisobi ochiq stollar bor'))
      return
    }
    modal.confirm({
      title: tr(`Удалить зал «${h.name}»?`, `«${h.name}» zalini oʻchirasizmi?`),
      content: h.tables.length ? tr(`Вместе с ним — ${h.tables.length} стол(ов).`, `U bilan birga — ${h.tables.length} ta stol.`) : undefined,
      okButtonProps: { danger: true },
      onOk: () => {
        setHalls((hs) => hs.filter((x) => x.key !== h.key))
        setHallKey(null)
        setSelKey(null)
      },
    })
  }

  const save = async () => {
    if (!storeId) return
    const seen = new Map<string, string>()
    for (const h of halls)
      for (const t of h.tables) {
        const k = t.number.trim().toLowerCase()
        if (!k) return message.error(tr('У стола пустой номер', 'Stol raqami boʻsh'))
        if (seen.has(k)) return message.error(tr(`Номер ${t.number} повторяется`, `${t.number} raqami takrorlanadi`))
        seen.set(k, h.key)
      }
    setSaving(true)
    try {
      const r = await api.put<{ items: LayoutHall[] }>('/store/cafe/halls', toInput(storeId, halls))
      const d = fromServer(r.items ?? [])
      // Ключи новых залов меняются на id — остаться на том же по порядку.
      const idx = halls.findIndex((h) => h.key === hall?.key)
      setBase(JSON.stringify(d))
      setHalls(d)
      setHallKey(d[Math.max(idx, 0)]?.key ?? null)
      setSelKey(null)
      qc.setQueryData(['/store/cafe/halls', { store_id: storeId }], r.items ?? [])
      message.success(tr('Схема сохранена — касса покажет её через несколько секунд', 'Sxema saqlandi — kassa uni bir necha soniyada koʻrsatadi'))
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  const waiters = (pins.data ?? []).filter((w) => w.can_pos)
  const percent = settings.data?.service_percent ?? '0'

  return (
    <NeedStore>
      <PageTitle
        title={tr('Залы и столы', 'Zallar va stollar')}
        extra={
          <Space>
            <Button icon={<SlidersOutlined />} onClick={() => setModeOpen(true)}>
              {tr('Режим кафе', 'Kafe rejimi')}
            </Button>
            {manage && (
              <Button type="primary" icon={<CheckOutlined />} loading={saving} disabled={!dirty} onClick={save}>
                {tr('Сохранить', 'Saqlash')}
              </Button>
            )}
          </Space>
        }
      >
        <Typography.Text type="secondary">
          {tr(
            'Залы и столы для кассы кафе. Перетащите столы так, как они стоят в зале — касса покажет такую же схему.',
            'Kafe kassasi uchun zallar va stollar. Stollarni zalda qanday tursa, shunday joylashtiring — kassa xuddi shu sxemani koʻrsatadi.',
          )}
        </Typography.Text>
      </PageTitle>
      <LoadError error={layout.error} retry={() => layout.refetch()} />
      {settings.data && settings.data.cafe_mode === 'counter' && (
        <Alert
          style={{ marginBottom: 16 }}
          type="info"
          showIcon
          message={tr('Касса работает «У прилавка» — столы не видны', 'Kassa «Peshtaxtada» rejimida — stollar koʻrinmaydi')}
          description={tr('Чтобы касса открывалась на зале, включите «Со столами» или «Столы + с собой».', 'Kassa zaldan ochilishi uchun «Stollar bilan» yoki «Stollar + olib ketish» ni yoqing.')}
          action={<Button onClick={() => setModeOpen(true)}>{tr('Режим кафе', 'Kafe rejimi')}</Button>}
        />
      )}

      <Flex gap={16} align="stretch" style={{ minHeight: 560 }} wrap="wrap">
        <div style={{ flex: '1 1 560px', minWidth: 0 }}>
          <Flex gap={8} wrap="wrap" align="center" style={{ marginBottom: 12 }}>
            {halls.map((h) => {
              const active = h.key === hall?.key
              return (
                <Space.Compact key={h.key}>
                  <Button
                    type={active ? 'primary' : 'default'}
                    style={active ? { background: '#111827', borderColor: '#111827' } : undefined}
                    onClick={() => {
                      setHallKey(h.key)
                      setSelKey(null)
                    }}
                  >
                    <b>{h.name}</b>
                    <Typography.Text style={{ fontSize: 12, color: active ? '#d1d5db' : undefined }} type={active ? undefined : 'secondary'}>
                      {tr(`${h.tables.length} столов`, `${h.tables.length} ta stol`)}
                    </Typography.Text>
                  </Button>
                  {active && manage && (
                    <Dropdown
                      trigger={['click']}
                      menu={{
                        items: [
                          { key: 'edit', icon: <EditOutlined />, label: tr('Переименовать', 'Nomini oʻzgartirish'), onClick: () => setHallEdit(h) },
                          { key: 'del', icon: <DeleteOutlined />, danger: true, label: tr('Удалить зал', 'Zalni oʻchirish'), onClick: () => removeHall(h) },
                        ],
                      }}
                    >
                      <Button type="primary" style={{ background: '#111827', borderColor: '#111827' }} icon={<MoreOutlined />} />
                    </Dropdown>
                  )}
                </Space.Compact>
              )
            })}
            {manage && (
              <Button type="dashed" icon={<PlusOutlined />} onClick={() => setHallEdit('new')}>
                {tr('Зал', 'Zal')}
              </Button>
            )}
            <div style={{ flex: 1 }} />
            {manage && hall && (
              <Space wrap>
                <Button icon={<BorderOutlined />} onClick={() => addTable('rect')}>
                  {tr('+ Стол', '+ Stol')}
                </Button>
                <Button icon={<span style={{ display: 'inline-block', width: 12, height: 12, borderRadius: 6, background: '#374151' }} />} onClick={() => addTable('round')}>
                  {tr('+ Круглый', '+ Dumaloq')}
                </Button>
                <Button icon={<TopchanIcon />} onClick={() => addTable('topchan')}>
                  {tr('+ Топчан', '+ Soʻri')}
                </Button>
              </Space>
            )}
          </Flex>

          <Canvas
            innerRef={setCanvasEl}
            tables={hall?.tables ?? []}
            selected={selKey}
            editable={manage}
            onSelect={setSelKey}
            onChange={(key, box) => patchTable(key, box)}
          />
          <Typography.Text type="secondary" style={{ display: 'block', marginTop: 8, fontSize: 12 }}>
            <InfoCircleOutlined /> {tr('Номера столов уникальны в кафе. Стол с открытым счётом удалить нельзя.', 'Stol raqamlari kafeda takrorlanmaydi. Hisobi ochiq stolni oʻchirib boʻlmaydi.')}
          </Typography.Text>
        </div>

        <Card style={{ flex: '0 0 300px', alignSelf: 'stretch' }} styles={{ body: { height: '100%', display: 'flex', flexDirection: 'column' } }}>
          {sel ? (
            <TableProps
              t={sel}
              hallName={hall?.name ?? ''}
              percent={percent}
              waiters={waiters}
              disabled={!manage}
              onChange={(p) => patchTable(sel.key, p)}
              onRemove={() => removeTable(sel)}
            />
          ) : (
            <Empty
              style={{ margin: 'auto' }}
              image={Empty.PRESENTED_IMAGE_SIMPLE}
              description={
                hall?.tables.length
                  ? tr('Выберите стол на схеме', 'Sxemada stolni tanlang')
                  : tr('В зале пока нет столов — добавьте кнопками сверху', 'Zalda hali stol yoʻq — yuqoridagi tugmalar bilan qoʻshing')
              }
            />
          )}
          <Typography.Text type="secondary" style={{ fontSize: 12, marginTop: 12 }}>
            {tr(`Всего столов: ${totalTables}`, `Jami stollar: ${totalTables}`)}
          </Typography.Text>
        </Card>
      </Flex>

      <HallModal
        value={hallEdit}
        onClose={() => setHallEdit(null)}
        onSave={(name, nameUz) => {
          if (hallEdit === 'new') {
            const h: DraftHall = { key: newKey(), name, name_uz: nameUz, tables: [] }
            setHalls((hs) => [...hs, h])
            setHallKey(h.key)
            setSelKey(null)
          } else if (hallEdit) patchHall(hallEdit.key, (h) => ({ ...h, name, name_uz: nameUz }))
          setHallEdit(null)
        }}
      />
      <CafeModeModal open={modeOpen} settings={settings.data} onClose={() => setModeOpen(false)} />
    </NeedStore>
  )
}

function TopchanIcon() {
  return (
    <svg width="14" height="12" viewBox="0 0 14 12" fill="none" stroke="currentColor" strokeWidth="1.4">
      <rect x="1" y="3" width="12" height="5" rx="1" />
      <path d="M2 8v3M12 8v3M3 3V1h8v2" />
    </svg>
  )
}

type Box = { x: number; y: number; w: number; h: number }
type Drag = { key: string; mode: 'move' | 'nw' | 'ne' | 'sw' | 'se'; startX: number; startY: number; box: Box }

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v))

/** Сетка со столами: перетаскивание и растягивание за углы, шаг — клетка. */
function Canvas({
  innerRef,
  tables,
  selected,
  editable,
  onSelect,
  onChange,
}: {
  innerRef: (el: HTMLDivElement | null) => void
  tables: DraftTable[]
  selected: string | null
  editable: boolean
  onSelect: (k: string | null) => void
  onChange: (key: string, box: Box) => void
}) {
  const drag = useRef<Drag | null>(null)
  const rows = Math.max(20, ...tables.map((t) => t.y + t.h + 3))

  const start = (e: RPointerEvent, t: DraftTable, mode: Drag['mode']) => {
    e.stopPropagation()
    onSelect(t.key)
    if (!editable) return
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    drag.current = { key: t.key, mode, startX: e.clientX, startY: e.clientY, box: { x: t.x, y: t.y, w: t.w, h: t.h } }
  }
  const move = (e: RPointerEvent) => {
    const d = drag.current
    if (!d) return
    const dx = Math.round((e.clientX - d.startX) / CELL)
    const dy = Math.round((e.clientY - d.startY) / CELL)
    const b = d.box
    let next: Box
    if (d.mode === 'move') next = { ...b, x: clamp(b.x + dx, 0, MAX_XY), y: clamp(b.y + dy, 0, MAX_XY) }
    else {
      let { x, y, w, h } = b
      if (d.mode === 'se' || d.mode === 'ne') w = clamp(b.w + dx, 1, MAX_WH)
      if (d.mode === 'se' || d.mode === 'sw') h = clamp(b.h + dy, 1, MAX_WH)
      if (d.mode === 'nw' || d.mode === 'sw') {
        w = clamp(b.w - dx, 1, MAX_WH)
        x = clamp(b.x + b.w - w, 0, MAX_XY)
      }
      if (d.mode === 'nw' || d.mode === 'ne') {
        h = clamp(b.h - dy, 1, MAX_WH)
        y = clamp(b.y + b.h - h, 0, MAX_XY)
      }
      next = { x, y, w, h }
    }
    onChange(d.key, next)
  }
  const end = () => {
    drag.current = null
  }

  return (
    <div
      ref={innerRef}
      onPointerDown={() => onSelect(null)}
      onPointerMove={move}
      onPointerUp={end}
      onPointerCancel={end}
      style={{
        position: 'relative',
        overflow: 'auto',
        height: Math.min(rows * CELL, 720),
        minHeight: 480,
        border: '1px solid #e5e7eb',
        borderRadius: 12,
        backgroundColor: '#fafafa',
        backgroundImage: 'linear-gradient(#eceef1 1px, transparent 1px), linear-gradient(90deg, #eceef1 1px, transparent 1px)',
        backgroundSize: `${CELL}px ${CELL}px`,
        touchAction: 'none',
        userSelect: 'none',
      }}
    >
      <div style={{ position: 'relative', height: rows * CELL, minWidth: Math.max(...tables.map((t) => (t.x + t.w + 1) * CELL), 0) }}>
        {tables.map((t) => {
          const on = t.key === selected
          return (
            <div
              key={t.key}
              onPointerDown={(e) => start(e, t, 'move')}
              style={{
                position: 'absolute',
                left: t.x * CELL + 2,
                top: t.y * CELL + 2,
                width: t.w * CELL - 4,
                height: t.h * CELL - 4,
                borderRadius: t.shape === 'round' ? '50%' : t.shape === 'topchan' ? 6 : 10,
                border: `${on ? 2 : 1}px solid ${on ? '#e11d2a' : '#d1d5db'}`,
                background: on ? '#fef2f2' : t.shape === 'topchan' ? '#fffbeb' : '#fff',
                boxShadow: '0 1px 2px rgba(0,0,0,.05)',
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                justifyContent: 'center',
                cursor: editable ? 'grab' : 'pointer',
              }}
            >
              <div style={{ fontWeight: 700, fontSize: t.w * t.h >= 9 ? 20 : 14, color: on ? '#e11d2a' : '#111827', lineHeight: 1.2 }}>{t.number}</div>
              {t.h >= 2 && (
                <div style={{ fontSize: 12, color: '#6b7280' }}>
                  <UserOutlined /> {t.seats}
                </div>
              )}
              {t.busy && <Tag color="orange" style={{ position: 'absolute', top: 4, right: 0, fontSize: 10, lineHeight: '16px' }}>{tr('счёт', 'hisob')}</Tag>}
              {on &&
                editable &&
                (['nw', 'ne', 'sw', 'se'] as const).map((c) => (
                  <span
                    key={c}
                    onPointerDown={(e) => start(e, t, c)}
                    style={{
                      position: 'absolute',
                      width: 10,
                      height: 10,
                      background: '#fff',
                      border: '2px solid #e11d2a',
                      borderRadius: 2,
                      left: c[1] === 'w' ? -6 : undefined,
                      right: c[1] === 'e' ? -6 : undefined,
                      top: c[0] === 'n' ? -6 : undefined,
                      bottom: c[0] === 's' ? -6 : undefined,
                      cursor: c === 'nw' || c === 'se' ? 'nwse-resize' : 'nesw-resize',
                    }}
                  />
                ))}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function TableProps({
  t,
  hallName,
  percent,
  waiters,
  disabled,
  onChange,
  onRemove,
}: {
  t: DraftTable
  hallName: string
  percent: string
  waiters: Waiter[]
  disabled: boolean
  onChange: (p: Partial<DraftTable>) => void
  onRemove: () => void
}) {
  const label = { display: 'block', fontSize: 12, color: '#374151', marginBottom: 4 } as const
  return (
    <Flex vertical gap={16} style={{ flex: 1 }}>
      <Flex justify="space-between" align="center">
        <Typography.Title level={4} style={{ margin: 0 }}>
          {tr(`Стол ${t.number}`, `${t.number}-stol`)}
        </Typography.Title>
        <Tag bordered={false}>{hallName}</Tag>
      </Flex>
      <Flex gap={12}>
        <div style={{ flex: 1 }}>
          <span style={label}>{tr('Номер', 'Raqam')}</span>
          <Input value={t.number} maxLength={8} disabled={disabled} onChange={(e) => onChange({ number: e.target.value })} />
        </div>
        <div style={{ flex: 1 }}>
          <span style={label}>{tr('Мест', 'Oʻrin')}</span>
          <InputNumber style={{ width: '100%' }} min={1} max={50} precision={0} value={t.seats} disabled={disabled} onChange={(v) => onChange({ seats: v ?? 1 })} />
        </div>
      </Flex>
      <div>
        <span style={label}>{tr('Форма', 'Shakl')}</span>
        <Segmented<TableShape>
          block
          disabled={disabled}
          value={t.shape}
          onChange={(shape) => onChange({ shape })}
          options={(['rect', 'round', 'topchan'] as TableShape[]).map((s) => ({ value: s, label: shapeLabel(s) }))}
        />
      </div>
      <div>
        <span style={label}>{tr('Официант по умолчанию', 'Standart ofitsiant')}</span>
        <Select
          style={{ width: '100%' }}
          allowClear
          disabled={disabled}
          placeholder={tr('Любой', 'Istalgan')}
          value={t.waiter_id ?? undefined}
          onChange={(v) => onChange({ waiter_id: v ?? null })}
          options={waiters.map((w) => ({ value: w.employee_id, label: w.name }))}
          suffixIcon={<UserOutlined />}
        />
      </div>
      <Flex justify="space-between" align="center">
        <b>{tr('Можно бронировать', 'Bron qilish mumkin')}</b>
        <Switch checked={t.bookable} disabled={disabled} onChange={(bookable) => onChange({ bookable })} />
      </Flex>
      <Flex justify="space-between" align="center">
        <div>
          <b>{tr('Обслуживание %', 'Xizmat %')}</b>
          <Typography.Text type="secondary" style={{ display: 'block', fontSize: 12 }}>
            {tr(`по правилу кафе — ${percent}%`, `kafe qoidasi boʻyicha — ${percent}%`)}
          </Typography.Text>
        </div>
        <Switch checked={t.service} disabled={disabled} onChange={(service) => onChange({ service })} />
      </Flex>
      <div style={{ flex: 1 }} />
      {!disabled && (
        <Button danger block icon={<DeleteOutlined />} onClick={onRemove} disabled={t.busy}>
          {t.busy ? tr('Открыт счёт — удалить нельзя', 'Hisob ochiq — oʻchirib boʻlmaydi') : tr('Удалить стол', 'Stolni oʻchirish')}
        </Button>
      )}
    </Flex>
  )
}

function HallModal({ value, onClose, onSave }: { value: DraftHall | 'new' | null; onClose: () => void; onSave: (name: string, nameUz: string) => void }) {
  const [name, setName] = useState('')
  const [nameUz, setNameUz] = useState('')
  useEffect(() => {
    setName(value && value !== 'new' ? value.name : '')
    setNameUz(value && value !== 'new' ? value.name_uz : '')
  }, [value])
  const ok = name.trim() !== '' || nameUz.trim() !== ''
  return (
    <Modal
      open={value !== null}
      title={value === 'new' ? tr('Новый зал', 'Yangi zal') : tr('Зал', 'Zal')}
      onCancel={onClose}
      okText={value === 'new' ? tr('Добавить', 'Qoʻshish') : tr('Готово', 'Tayyor')}
      okButtonProps={{ disabled: !ok }}
      onOk={() => onSave(name.trim() || nameUz.trim(), nameUz.trim())}
      destroyOnHidden
    >
      <Flex vertical gap={12}>
        <div>
          <Typography.Text type="secondary">{tr('Название', 'Nomi')}</Typography.Text>
          <Input autoFocus maxLength={40} value={name} placeholder={tr('Терраса', 'Terrasa')} onChange={(e) => setName(e.target.value)} />
        </div>
        <div>
          <Typography.Text type="secondary">{tr('Название на узбекском', 'Oʻzbekcha nomi')}</Typography.Text>
          <Input maxLength={40} value={nameUz} placeholder="Terrasa" onChange={(e) => setNameUz(e.target.value)} />
        </div>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {tr('Зал появится на схеме после «Сохранить».', 'Zal «Saqlash» dan keyin sxemada paydo boʻladi.')}
        </Typography.Text>
      </Flex>
    </Modal>
  )
}
