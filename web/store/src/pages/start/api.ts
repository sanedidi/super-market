// «Начало работы»: типы и запросы к /store/start (docs/api.md).
import { useQueryClient } from '@tanstack/react-query'
import { App } from 'antd'
import { api, errorText } from '@sm/shared'

export type Line = {
  product_id: string
  name: string
  image: string | null
  unit_short: string
  is_fractional: boolean
  barcode: string | null
  /** null — ещё не введено на шаге «Инвентаризация». */
  qty: string | null
  cost: string | null
  price: string | null
  current_price: string
  source: string
  own: boolean
  moderation: string
  posted: boolean
  added_at: string
}

export type Totals = {
  products: number
  qty: string
  cost_total: string
  price_total: string
  no_cost: number
  pending: number
  /** Строк без количества или цены продажи. */
  unfilled: number
}

export type Draft = {
  id: string | null
  store_id: string
  store_name: string
  warehouse_id: string
  warehouse_name: string
  status: 'open' | 'posting' | 'posted'
  lines: Line[]
  totals: Totals
  stock_products: number
  last_posted_at: string | null
  /** «Начало работы» записано и закрыто. */
  closed: boolean
}

export type LineInput = {
  product_id: string
  qty?: string | number | null
  /** Добавить в «Мои товары» (шаг 1): повтор — ошибка already_added. */
  add?: boolean
  confirm_similar?: boolean
  cost?: string | number | null
  price?: string | number | null
  barcode?: string
  source?: 'photo' | 'barcode' | 'catalog' | 'search' | 'new' | 'manual'
}

/** Товар центральной базы в поиске шага 1. */
export type SearchItem = {
  product_id: string
  name: string
  image: string | null
  unit_short: string
  current_price: string
  barcode: string | null
  own: boolean
  moderation: string
  /** Уже в «Моих товарах». */
  added: boolean
  /** Уже в товарах магазина (был на складе или в цене магазина), а не в этом списке. */
  in_store: boolean
}

/** Похожий товар из ошибки similar_exists. */
export type Similar = { product_id: string; name: string; image: string | null; barcode: string | null }

export type LinesResult = { lines: Line[]; totals: Totals; skipped: string[] }

export type Candidate = {
  product_id: string
  name: string
  image: string | null
  unit_short: string
  current_price: string
  barcode: string | null
  score: number
}

export type PhotoItem = {
  n: number
  name: string
  brand: string
  barcode: string
  qty: string
  state: 'found' | 'choose' | 'missing'
  product: Candidate | null
  candidates: Candidate[]
  brand_id: string | null
  category_id: string | null
  in_draft: boolean
}

export type Photo = {
  id: string
  store_id: string
  status: 'processing' | 'ready' | 'failed'
  error: string
  images: string[]
  items: PhotoItem[]
  counts: { found: number; choose: number; missing: number }
  created_at: string
}

export type PostResult = {
  draft_id: string
  products: number
  qty: string
  cost_total: string
  documents: { id: string; number: number }[]
  price_document: { id: string; number: number } | null
  visible: number
  pending: number
}

/** Все запросы «Начала работы» начинаются с этих ключей — их и обновляем. */
const KEYS = ['/store/start', '/store/start/search']

export function useStartRefresh() {
  const qc = useQueryClient()
  return () => Promise.all(KEYS.map((k) => qc.invalidateQueries({ queryKey: [k] })))
}

/** Запросы черновика с обновлением экрана и сообщением об ошибке. */
export function useStartApi(storeId: string) {
  const refresh = useStartRefresh()
  const { message } = App.useApp()
  const run = async <T,>(p: Promise<T>): Promise<T> => {
    try {
      const r = await p
      await refresh()
      return r
    } catch (e) {
      message.error(errorText(e))
      await refresh()
      throw e
    }
  }
  return {
    refresh,
    setLines: (items: LineInput[]) => run(api.post<LinesResult>('/store/start/lines', { store_id: storeId, items })),
    deleteLine: (productId: string) => run(api.del(`/store/start/lines/${productId}?store_id=${storeId}`)),
  }
}

/** Количество для отображения без лишних нулей. */
export const plainNum = (v: string | null | undefined) => (v === null || v === undefined || v === '' ? '' : String(Number(v)))
