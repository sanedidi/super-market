// Первая настройка магазина: состояние и шаги (GET/POST/PUT /store/setup).
import { api, tr } from '@sm/shared'

export type WorkingHours = { weekday: number; opens: string; closes: string }

export type SetupState = {
  /** Мастер не пройден: в сети нет магазина с точкой и часами. */
  required: boolean
  can_setup: boolean
  store: {
    id: string
    name: string
    phone: string
    address: string
    lat: number | null
    lng: number | null
  } | null
  working_hours: WorkingHours[]
  steps: { store: boolean; hours: boolean; delivery: boolean; done: boolean }
  delivery: {
    accepts_online: boolean
    declined: boolean
    delivery_radius_m: number
    min_order_amount: string
    eta_min: number | null
    eta_max: number | null
    fee: string | null
    free_from: string | null
  }
  wishes: number
}

export type StoreStep = {
  store_id?: string
  name: string
  phone: string
  address: string
  lat: number
  lng: number
  city?: string
}
export type DeliveryStep =
  | { store_id: string; mode: 'none' }
  | {
      store_id: string
      mode: 'deliver'
      delivery_radius_m: number
      fee: string
      free_from: string | null
      min_order_amount: string
      eta_min: number
      eta_max: number
    }

export const setupApi = {
  get: (storeId?: string) => api.get<SetupState>('/store/setup', storeId ? { store_id: storeId } : undefined),
  store: (b: StoreStep) => api.post<SetupState>('/store/setup/store', b),
  hours: (storeId: string, hours: WorkingHours[]) =>
    api.put<SetupState>('/store/setup/hours', {
      store_id: storeId,
      working_hours: hours,
    }),
  delivery: (b: DeliveryStep) => api.put<SetupState>('/store/setup/delivery', b),
}

/** Шаг, с которого продолжить: первый непройденный. */
export function firstStep(s: SetupState): 1 | 2 | 3 {
  if (!s.steps.store) return 1
  if (!s.steps.hours) return 2
  return 3
}

const DAY_SHORT = tr('Вс Пн Вт Ср Чт Пт Сб', 'Ya Du Se Ch Pa Ju Sh').split(' ')

/** «Пн–Пт 08:00–22:00 · Сб 09:00–20:00 · Вс выходной»; пусто — круглосуточно. */
export function hoursText(hours: WorkingHours[]): string {
  if (hours.length === 0) return tr('Круглосуточно', 'Kecha-kunduz')
  const order = [1, 2, 3, 4, 5, 6, 0]
  const by = new Map(hours.map((h) => [h.weekday, `${h.opens}–${h.closes}`]))
  const parts: string[] = []
  let i = 0
  while (i < order.length) {
    const v = by.get(order[i]) ?? null
    let j = i
    while (j + 1 < order.length && (by.get(order[j + 1]) ?? null) === v) j++
    const days = i === j ? DAY_SHORT[order[i]] : `${DAY_SHORT[order[i]]}–${DAY_SHORT[order[j]]}`
    parts.push(`${days} ${v ?? tr('выходной', 'dam olish')}`)
    i = j + 1
  }
  const week = `${DAY_SHORT[1]}–${DAY_SHORT[0]} `
  return parts.length === 1 && parts[0].startsWith(week) ? tr('Каждый день ', 'Har kuni ') + parts[0].slice(week.length) : parts.join(' · ')
}

/** «1 покупатель», «3 покупателя», «12 покупателей». */
export function buyers(n: number): string {
  const m10 = n % 10
  const m100 = n % 100
  const w = m10 === 1 && m100 !== 11 ? 'покупатель' : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? 'покупателя' : 'покупателей'
  return tr(`${n} ${w}`, `${n} ta xaridor`)
}
