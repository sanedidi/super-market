// Зоны доставки на Яндекс Карте: магазин рисует многоугольники и задаёт цену
// каждого. Зоны можно вкладывать друг в друга — для адреса действует самая
// маленькая (внутренняя) зона, в которую он попал.
import { useEffect, useMemo, useRef, useState } from 'react'
import { Alert, Button, Card, Empty, Form, Input, Modal, Popconfirm, Radio, Space, Spin, Tooltip, Typography } from 'antd'
import { CheckOutlined, CloseOutlined, DeleteOutlined, EditOutlined, FormOutlined, PlusOutlined } from '@ant-design/icons'
import { api, money, useAction, useFitMap, useList, useYmaps } from '@sm/shared'
import { Num } from '../ui'
import type { Zone } from '../types'

/* eslint-disable @typescript-eslint/no-explicit-any */

const COLORS = ['#3761e9', '#17b26a', '#d97706', '#7c3aed', '#ef4444', '#0891b2', '#db2777', '#65a30d']

type Pt = [number, number] // [lng, lat] — как в API

/** Площадь многоугольника в условных единицах — только для сортировки вложенных зон. */
function area(poly: Pt[]): number {
  let s = 0
  for (let i = 0; i < poly.length; i++) {
    const [x1, y1] = poly[i]
    const [x2, y2] = poly[(i + 1) % poly.length]
    s += x1 * y2 - x2 * y1
  }
  return Math.abs(s / 2)
}

/** Кольцо ymaps [[lat, lng], …] → точки API [[lng, lat], …] без повтора первой точки. */
function fromRing(ring: number[][]): Pt[] {
  const pts: Pt[] = ring.map(([lat, lng]) => [+lng.toFixed(6), +lat.toFixed(6)])
  const [a, b] = [pts[0], pts[pts.length - 1]]
  if (pts.length > 1 && a[0] === b[0] && a[1] === b[1]) pts.pop()
  return pts
}

const toRing = (poly: Pt[]) => poly.map(([lng, lat]) => [lat, lng])

type Mode = { kind: 'idle' } | { kind: 'draw' } | { kind: 'edit'; id: string }

interface Props {
  storeId: string
  storeName?: string
  lat: number | null
  lng: number | null
  radiusM: number | null
  /** Сколько активных зон — страница настроек меняет подсказки. */
  onZonesChange?: (activeCount: number) => void
}

export function DeliveryZones({ storeId, storeName, lat, lng, radiusM, onZonesChange }: Props) {
  const path = `/store/stores/${storeId}/zones`
  const { data: zones = [], isLoading } = useList<Zone>(path)
  const { ymaps, error: mapError } = useYmaps()
  const box = useRef<HTMLDivElement>(null)
  const [map, setMap] = useState<any>(null)
  const layer = useRef<any>(null)
  const polys = useRef<Map<string, any>>(new Map())
  const draft = useRef<any>(null)
  const [mode, setMode] = useState<Mode>({ kind: 'idle' })
  const [points, setPoints] = useState(0)
  const [selected, setSelected] = useState<string | null>(null)
  const [form, setForm] = useState<{ zone: Zone | null; polygon: Pt[] | null } | null>(null)
  const [formRef] = Form.useForm()
  const fitted = useRef(false)

  // Цвет закреплён за зоной по порядку создания списка (по названию с сервера).
  const colorOf = useMemo(() => {
    const m = new Map<string, string>()
    zones.forEach((z, i) => m.set(z.id, COLORS[i % COLORS.length]))
    return m
  }, [zones])
  // Внутренние зоны — выше в списке и поверх на карте.
  const sorted = useMemo(() => [...zones].sort((a, b) => area(a.polygon) - area(b.polygon)), [zones])
  const hasActive = zones.some((z) => z.is_active)
  const activeCount = zones.filter((z) => z.is_active).length
  useEffect(() => onZonesChange?.(activeCount), [activeCount, onZonesChange])

  const save = useAction(
    (v: { id?: string; body: Record<string, unknown> }) => (v.id ? api.patch(`${path}/${v.id}`, v.body) : api.post(path, v.body)),
    { success: 'Зона сохранена', invalidate: [[path]] },
  )
  const remove = useAction((id: string) => api.del(`${path}/${id}`), { success: 'Зона удалена', invalidate: [[path]] })

  // Карта
  useEffect(() => {
    if (!ymaps || !box.current) return
    const center = lat !== null && lng !== null ? [lat, lng] : [41.311, 69.279]
    const m = new ymaps.Map(box.current, { center, zoom: 13, controls: ['zoomControl', 'searchControl', 'fullscreenControl'] }, { suppressMapOpenBlock: true })
    m.controls.get('searchControl')?.options.set({ placeholderContent: 'Поиск адреса', size: 'small' })
    const col = new ymaps.GeoObjectCollection()
    m.geoObjects.add(col)
    layer.current = col
    setMap(m)
    return () => {
      m.destroy()
      layer.current = null
      polys.current.clear()
      draft.current = null
      setMap(null)
    }
  }, [ymaps, lat, lng])

  useFitMap(box, map)

  // Зоны, точка магазина и радиус (если зон нет)
  useEffect(() => {
    const col = layer.current
    if (!ymaps || !map || !col) return
    col.removeAll()
    polys.current.clear()
    if (lat !== null && lng !== null) {
      if (!hasActive && radiusM) {
        col.add(
          new ymaps.Circle([[lat, lng], radiusM], { hintContent: `Радиус доставки ${radiusM} м` }, {
            fillColor: '#3761e91a',
            strokeColor: '#3761e9',
            strokeStyle: 'dash',
            strokeWidth: 2,
            interactivityModel: 'default#transparent',
          }),
        )
      }
      col.add(new ymaps.Placemark([lat, lng], { hintContent: storeName ?? 'Магазин' }, { preset: 'islands#darkBlueShoppingIcon' }))
    }
    // Большие зоны добавляются первыми, чтобы внутренние были сверху и кликались.
    for (const z of [...sorted].reverse()) {
      const c = colorOf.get(z.id) ?? COLORS[0]
      const p = new ymaps.Polygon(
        [toRing(z.polygon)],
        { hintContent: `${z.name} — ${money(z.price)} сум${z.is_active ? '' : ' (отключена)'}` },
        {
          fillColor: c + (z.is_active ? '33' : '12'),
          strokeColor: c,
          strokeWidth: selected === z.id ? 4 : 2,
          strokeStyle: z.is_active ? 'solid' : 'dash',
        },
      )
      p.events.add('click', () => setSelected(z.id))
      col.add(p)
      polys.current.set(z.id, p)
    }
    if (zones.length > 0 && mode.kind === 'idle' && !fitted.current) {
      fitted.current = true
      const b = col.getBounds()
      if (b) map.setBounds(b, { checkZoomRange: true, zoomMargin: 30 })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ymaps, map, sorted, colorOf, selected, hasActive, radiusM, lat, lng, storeName])

  const stopDraft = () => {
    if (draft.current) {
      draft.current.editor.stopDrawing()
      map?.geoObjects.remove(draft.current)
      draft.current = null
    }
    setPoints(0)
  }

  const startDraw = () => {
    if (!ymaps || !map) return
    setSelected(null)
    const c = COLORS[zones.length % COLORS.length]
    const p = new ymaps.Polygon([[]], {}, { editorDrawingCursor: 'crosshair', fillColor: c + '40', strokeColor: c, strokeWidth: 3, editorMaxPoints: 500 })
    map.geoObjects.add(p)
    p.geometry.events.add('change', () => setPoints(Math.max(0, (p.geometry.getCoordinates()[0]?.length ?? 1) - 1)))
    p.editor.startDrawing()
    draft.current = p
    setMode({ kind: 'draw' })
  }

  const finishDraw = () => {
    const p = draft.current
    if (!p) return
    const pts = fromRing(p.geometry.getCoordinates()[0] ?? [])
    if (pts.length < 3) return
    p.editor.stopDrawing()
    formRef.resetFields()
    formRef.setFieldsValue({ name: `Зона ${zones.length + 1}`, price: null, is_active: true })
    setForm({ zone: null, polygon: pts })
  }

  const cancelDraw = () => {
    stopDraft()
    setMode({ kind: 'idle' })
  }

  const startEdit = (z: Zone) => {
    const p = polys.current.get(z.id)
    if (!p) return
    setSelected(z.id)
    p.editor.startEditing()
    setMode({ kind: 'edit', id: z.id })
  }

  const finishEdit = (keep: boolean) => {
    if (mode.kind !== 'edit') return
    const p = polys.current.get(mode.id)
    const z = zones.find((x) => x.id === mode.id)
    if (p) p.editor.stopEditing()
    if (keep && p) {
      const pts = fromRing(p.geometry.getCoordinates()[0] ?? [])
      save.mutate({ id: mode.id, body: { polygon: pts } })
    } else if (p && z) {
      p.geometry.setCoordinates([toRing(z.polygon)])
    }
    setMode({ kind: 'idle' })
  }

  const openProps = (z: Zone) => {
    formRef.resetFields()
    formRef.setFieldsValue({ name: z.name, price: z.price, is_active: z.is_active })
    setForm({ zone: z, polygon: null })
  }

  const submit = (v: { name: string; price: string; is_active: boolean }) => {
    const body: Record<string, unknown> = { name: v.name, price: v.price, is_active: v.is_active }
    if (form?.polygon) body.polygon = form.polygon
    save.mutate(
      { id: form?.zone?.id, body },
      {
        onSuccess: () => {
          if (!form?.zone) {
            stopDraft()
            setMode({ kind: 'idle' })
          }
          setForm(null)
        },
      },
    )
  }

  const closeForm = () => {
    // Новую зону можно дорисовать: возвращаемся в режим рисования.
    if (!form?.zone && draft.current) draft.current.editor.startDrawing()
    setForm(null)
  }

  const busy = mode.kind !== 'idle'
  const noPoint = lat === null || lng === null

  return (
    <Card
      title="Зоны доставки"
      className="sm-zones"
      extra={
        mode.kind === 'draw' ? (
          <Space>
            <Button icon={<CloseOutlined />} onClick={cancelDraw}>
              Отмена
            </Button>
            <Button className="sm-btn-blue" icon={<CheckOutlined />} disabled={points < 3} onClick={finishDraw}>
              Готово ({points} {points === 1 ? 'точка' : points >= 2 && points <= 4 ? 'точки' : 'точек'})
            </Button>
          </Space>
        ) : mode.kind === 'edit' ? (
          <Space>
            <Button icon={<CloseOutlined />} onClick={() => finishEdit(false)}>
              Отмена
            </Button>
            <Button className="sm-btn-blue" icon={<CheckOutlined />} loading={save.isPending} onClick={() => finishEdit(true)}>
              Сохранить границы
            </Button>
          </Space>
        ) : (
          <Button type="primary" icon={<PlusOutlined />} disabled={!map} onClick={startDraw}>
            Нарисовать зону
          </Button>
        )
      }
    >
      {mode.kind === 'draw' && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 12 }}
          message="Кликайте по карте, чтобы поставить вершины зоны. Когда контур готов (минимум 3 точки) — нажмите «Готово»."
        />
      )}
      {mode.kind === 'edit' && (
        <Alert type="info" showIcon style={{ marginBottom: 12 }} message="Перетаскивайте вершины. Клик по вершине — удалить или добавить точку." />
      )}
      {noPoint && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message="Точка магазина не указана — поставьте её в разделе «Магазины»." />}
      <div className="sm-zones-body">
        <div className="sm-zones-list">
          {isLoading ? (
            <Spin />
          ) : sorted.length === 0 ? (
            <Empty
              image={Empty.PRESENTED_IMAGE_SIMPLE}
              description={
                <>
                  Зон нет — доставка в радиусе{radiusM ? ` ${radiusM} м` : ''}.
                  <br />
                  Нарисуйте зону, чтобы доставлять только в неё и по своей цене.
                </>
              }
            />
          ) : (
            sorted.map((z) => (
              <div
                key={z.id}
                className={'sm-zone' + (selected === z.id ? ' active' : '') + (z.is_active ? '' : ' off')}
                onClick={() => {
                  setSelected(z.id)
                  const b = polys.current.get(z.id)?.geometry.getBounds()
                  if (b && map) map.setBounds(b, { checkZoomRange: true, zoomMargin: 40, duration: 250 })
                }}
              >
                <span className="sm-zone-dot" style={{ background: colorOf.get(z.id) }} />
                <div className="sm-zone-text">
                  <b>{z.name}</b>
                  <span>{z.is_active ? `${money(z.price)} сум` : 'отключена'}</span>
                </div>
                <Space size={2} onClick={(e) => e.stopPropagation()}>
                  <Tooltip title="Название и цена">
                    <Button size="small" type="text" icon={<FormOutlined />} disabled={busy} onClick={() => openProps(z)} />
                  </Tooltip>
                  <Tooltip title="Изменить границы">
                    <Button size="small" type="text" icon={<EditOutlined />} disabled={busy} onClick={() => startEdit(z)} />
                  </Tooltip>
                  <Popconfirm title="Удалить зону?" onConfirm={() => remove.mutate(z.id)}>
                    <Button size="small" type="text" danger icon={<DeleteOutlined />} disabled={busy} />
                  </Popconfirm>
                </Space>
              </div>
            ))
          )}
          {zones.length > 1 && (
            <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginTop: 12, marginBottom: 0 }}>
              Если адрес попадает в несколько зон, действует самая маленькая — внутренняя. Так можно сделать центр дешевле, а окраины дороже.
            </Typography.Paragraph>
          )}
        </div>
        <div className="sm-map sm-zones-map">
          <div ref={box} style={{ position: 'absolute', inset: 0 }} />
          {mapError && <Alert type="error" showIcon message={mapError} style={{ position: 'absolute', inset: 16, height: 'fit-content' }} />}
          {!ymaps && !mapError && <Spin style={{ position: 'absolute', inset: 0, margin: 'auto', height: 32 }} />}
        </div>
      </div>

      <Modal
        open={!!form}
        title={form?.zone ? 'Зона доставки' : 'Новая зона'}
        okText="Сохранить"
        onOk={() => formRef.submit()}
        confirmLoading={save.isPending}
        onCancel={closeForm}
        forceRender
      >
        <Form form={formRef} layout="vertical" onFinish={submit}>
          <Form.Item name="name" label="Название" rules={[{ required: true, whitespace: true, message: 'Обязательное поле' }]}>
            <Input placeholder="Например: Центр" />
          </Form.Item>
          <Form.Item name="price" label="Цена доставки, сум" rules={[{ required: true, message: 'Укажите цену' }]} extra="0 — бесплатная доставка в этой зоне">
            <Num step="1000" />
          </Form.Item>
          <Form.Item name="is_active" label="Статус">
            <Radio.Group
              options={[
                { value: true, label: 'Доставляем' },
                { value: false, label: 'Отключена' },
              ]}
            />
          </Form.Item>
        </Form>
      </Modal>
    </Card>
  )
}
