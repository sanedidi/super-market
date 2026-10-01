// Яндекс Карты (JS API 2.1): загрузка скрипта и выбор точки на карте.
// Ключ — VITE_YANDEX_MAPS_KEY при сборке («JavaScript API и HTTP Геокодер»
// в кабинете разработчика Яндекса). Без ключа карта рисуется, но поиск по
// адресу и определение адреса по точке не работают.
import { useEffect, useRef, useState } from 'react'
import { Alert, Spin } from 'antd'

/* eslint-disable @typescript-eslint/no-explicit-any */
declare global {
  interface Window {
    ymaps?: any
  }
}

export type LatLng = { lat: number; lng: number }

export const TASHKENT: LatLng = { lat: 41.311, lng: 69.279 }

const KEY = (import.meta as unknown as { env?: Record<string, string | undefined> }).env?.VITE_YANDEX_MAPS_KEY ?? ''
export const hasMapsKey = KEY !== ''

let loading: Promise<any> | null = null

export function loadYmaps(): Promise<any> {
  if (window.ymaps?.Map) return Promise.resolve(window.ymaps)
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const s = document.createElement('script')
      s.src = `https://api-maps.yandex.ru/2.1/?lang=ru_RU${KEY ? `&apikey=${encodeURIComponent(KEY)}` : ''}`
      s.async = true
      s.onload = () => window.ymaps.ready(() => resolve(window.ymaps))
      s.onerror = () => {
        loading = null
        reject(new Error('Не удалось загрузить Яндекс Карты'))
      }
      document.head.appendChild(s)
    })
  }
  return loading
}

/** Хук: объект ymaps или ошибка загрузки. */
export function useYmaps() {
  const [ymaps, setYmaps] = useState<any>(window.ymaps?.Map ? window.ymaps : null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    let alive = true
    loadYmaps().then(
      (y) => alive && setYmaps(y),
      (e: Error) => alive && setError(e.message),
    )
    return () => {
      alive = false
    }
  }, [])
  return { ymaps, error }
}

/** Карта подстраивается под размер контейнера (модалки, вкладки, мобильная ширина). */
export function useFitMap(el: React.RefObject<HTMLDivElement | null>, map: any) {
  useEffect(() => {
    if (!map || !el.current || typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver(() => map.container.fitToViewport())
    ro.observe(el.current)
    return () => ro.disconnect()
  }, [map, el])
}

/** Город точки (населённый пункт по геокодеру). */
export async function cityAt(ymaps: any, p: LatLng): Promise<string | null> {
  try {
    const res = await ymaps.geocode([p.lat, p.lng], { results: 1, kind: 'locality' })
    const obj = res.geoObjects.get(0)
    return obj ? (obj.getLocalities?.()[0] ?? obj.properties.get('name') ?? null) : null
  } catch {
    return null
  }
}

/** Адрес точки (нужен ключ с геокодером). */
export async function addressAt(ymaps: any, p: LatLng): Promise<string | null> {
  try {
    const res = await ymaps.geocode([p.lat, p.lng], { results: 1 })
    const obj = res.geoObjects.get(0)
    return obj ? (obj.getAddressLine?.() ?? obj.properties.get('text') ?? null) : null
  } catch {
    return null
  }
}

interface PickerProps {
  value?: LatLng | null
  onChange?: (v: LatLng | null) => void
  /** Вызывается с адресом новой точки, если его удалось определить. */
  onAddress?: (address: string) => void
  /** Вызывается с городом новой точки. */
  onCity?: (city: string) => void
  height?: number
}

/** Точка на карте: клик или перетаскивание метки, поиск по адресу. Для Form.Item. */
export function MapPointPicker({ value, onChange, onAddress, onCity, height = 280 }: PickerProps) {
  const { ymaps, error } = useYmaps()
  const box = useRef<HTMLDivElement>(null)
  const [map, setMap] = useState<any>(null)
  const mark = useRef<any>(null)
  const cb = useRef({ onChange, onAddress, onCity })
  cb.current = { onChange, onAddress, onCity }

  useEffect(() => {
    if (!ymaps || !box.current) return
    const start = value ?? TASHKENT
    const m = new ymaps.Map(box.current, { center: [start.lat, start.lng], zoom: value ? 16 : 12, controls: ['zoomControl', 'geolocationControl', 'searchControl'] }, { suppressMapOpenBlock: true })
    const set = (coords: number[]) => {
      const p = { lat: +coords[0].toFixed(6), lng: +coords[1].toFixed(6) }
      cb.current.onChange?.(p)
      if (cb.current.onAddress) void addressAt(ymaps, p).then((a) => a && cb.current.onAddress?.(a))
      if (cb.current.onCity) void cityAt(ymaps, p).then((c) => c && cb.current.onCity?.(c))
    }
    m.events.add('click', (e: any) => set(e.get('coords')))
    const search = m.controls.get('searchControl')
    search?.options.set({ noPlacemark: true, placeholderContent: 'Поиск адреса' })
    search?.events.add('resultselect', (e: any) => {
      const r = search.getResultsArray()[e.get('index')]
      if (r) set(r.geometry.getCoordinates())
    })
    const pm = new ymaps.Placemark([start.lat, start.lng], { hintContent: 'Магазин' }, { draggable: true, preset: 'islands#darkBlueShoppingIcon', visible: !!value })
    pm.events.add('dragend', () => set(pm.geometry.getCoordinates()))
    m.geoObjects.add(pm)
    mark.current = pm
    setMap(m)
    return () => {
      m.destroy()
      mark.current = null
      setMap(null)
    }
    // Карта создаётся один раз; value подхватывает эффект ниже.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ymaps])

  useFitMap(box, map)

  useEffect(() => {
    const pm = mark.current
    if (!map || !pm) return
    if (value) {
      const cur = pm.geometry.getCoordinates()
      if (!pm.options.get('visible') || Math.abs(cur[0] - value.lat) > 1e-7 || Math.abs(cur[1] - value.lng) > 1e-7) {
        pm.geometry.setCoordinates([value.lat, value.lng])
        const zoom = map.getZoom()
        map.setCenter([value.lat, value.lng], zoom < 14 ? 16 : zoom, { duration: 200 })
      }
      pm.options.set('visible', true)
    } else {
      pm.options.set('visible', false)
    }
  }, [map, value])

  if (error) return <Alert type="error" showIcon message={error} />
  return (
    <div className="sm-map" style={{ height }}>
      <div ref={box} style={{ position: 'absolute', inset: 0 }} />
      {!ymaps && <Spin style={{ position: 'absolute', inset: 0, margin: 'auto', height: 32 }} />}
      {ymaps && !value && <div className="sm-map-hint">Нажмите на карту, чтобы поставить точку</div>}
    </div>
  )
}
