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
  source?: 'photo' | 'barcode' | 'catalog' | 'search' | 'new' | 'manual' | 'tasnif'
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

/** Вариант из каталога ИКПУ (POST /store/start/tasnif/preview). */
export type TasnifPreview = {
  /** Номер записи tasnif в запросе. */
  index: number
  name: string
  barcode: string | null
  ikpu: string
  unit_short: string
  /** Товар с этим штрихкодом уже есть в центральной базе. */
  product_id: string | null
  image: string | null
  added: boolean
  in_store: boolean
}

/** Подкатегория: раздел и название на обоих языках. */
export type CategoryRef = { id: string; section: string; section_uz: string; name: string; name_uz: string }

/** Новая категория (подкатегория в разделе parent_id или в новом разделе parent_name). */
export type NewCategory = { parent_id: string | null; parent_name: string; parent_name_uz: string; name: string; name_uz: string }

/** Предложение Super Market, когда категорию по коду ИКПУ не определить. */
export type CategorySuggestion = { category: CategoryRef | null; alternatives: CategoryRef[]; new: NewCategory | null; name_uz: string }

export type TasnifAddResult = {
  status: 'added' | 'need_category'
  product_id?: string
  created: boolean
  line?: Line
  totals?: Totals
  name: string
  unit_short: string
  suggestion: CategorySuggestion | null
}

/** Похожий товар базы для карточки по фото. */
export type NewItemMatch = { product_id: string; name: string; image: string | null; barcode: string | null; own: boolean }

/** Карточка, которую заполнил Super Market по фото. */
export type NewItemResult = {
  name: string
  name_uz: string
  brand: string
  brand_id: string | null
  description: string
  unit_id: string
  unit_short: string
  suggestion: CategorySuggestion | null
  match: NewItemMatch | null
}

/** Другая карточка в «Новых», похожая на эту (тот же штрихкод или похожее название). */
export type NewItemDup = { id: string; name: string; image: string | null; barcode: string; status: 'processing' | 'ready' | 'failed' }

/** Фото нового товара в очереди «Новые». */
export type NewItem = {
  id: string
  store_id: string
  status: 'processing' | 'ready' | 'failed' | 'done'
  error: string
  barcode: string
  images: string[]
  result: NewItemResult | null
  product_id: string | null
  created_at: string
  /** Похоже, этот товар уже есть в «Новых» — «Это он» объединяет карточки. */
  duplicate: NewItemDup | null
}

export type NewItemConfirmResult = { product_id: string; created: boolean; line: Line; totals: Totals }

/** Страница очереди «Новые»: counts и total — по всей очереди магазина. */
export type NewItemList = { items: NewItem[]; counts: { processing: number; ready: number; failed: number }; total: number }

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
const KEYS = ['/store/start', '/store/start/search', '/store/start/tasnif/preview', '/store/start/new-items']

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
