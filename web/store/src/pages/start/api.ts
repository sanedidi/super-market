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
  qty: string
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
}

export type LineInput = {
  product_id: string
  qty?: string | number
  add?: boolean
  cost?: string | number | null
  price?: string | number | null
  barcode?: string
  source?: 'photo' | 'barcode' | 'catalog' | 'search' | 'new' | 'manual'
}

export type CatalogGroup = {
  category_ids: string[]
  category_names: string[]
  brand_id: string | null
  brand_name: string
  count: number
  selected: number
}

export type Catalog = { groups: CatalogGroup[]; total: number; selected: number }

export type CatalogItem = {
  product_id: string
  name: string
  image: string | null
  unit_short: string
  current_price: string
  barcode: string | null
  own: boolean
  selected: boolean
}

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
const KEYS = ['/store/start', '/store/start/catalog', '/store/start/catalog/items']

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
    setLines: (items: LineInput[]) => run(api.post<{ lines: Line[]; totals: Totals }>('/store/start/lines', { store_id: storeId, items })),
    deleteLine: (productId: string) => run(api.del(`/store/start/lines/${productId}?store_id=${storeId}`)),
    select: (body: { category_id?: string; brand_id?: string; exact?: boolean; q?: string; selected: boolean }) =>
      run(api.post<{ changed: number; totals: Totals }>('/store/start/catalog/select', { store_id: storeId, ...body })),
  }
}

/** Количество для отображения без лишних нулей. */
export const plainNum = (v: string | null | undefined) => (v === null || v === undefined || v === '' ? '' : String(Number(v)))
