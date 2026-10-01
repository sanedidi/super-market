// Блоки главной приложения (см. backend/internal/orders/home_blocks.go).

export type BlockType = 'shelf' | 'banners' | 'promo' | 'category_icons' | 'catalog_sections'

export interface BlockLink {
  type: 'none' | 'deals' | 'category' | 'product' | 'delivery_terms' | 'url'
  id?: string
  url?: string
}

export interface HomeBlock {
  id: string
  type: BlockType
  disabled?: boolean
  pinned?: boolean
  starts_at?: string | null
  ends_at?: string | null
  // полка
  title?: string
  source?: 'hits' | 'discount' | 'new' | 'category' | 'manual'
  category_id?: string
  product_ids?: string[]
  limit?: number
  view?: string
  show_all?: boolean
  show_empty?: boolean
  // баннеры
  size?: 'big' | 'strip'
  banner_ids?: string[]
  autoplay?: boolean
  // промо и узкая лента
  kind?: 'custom' | 'free_delivery'
  subtitle?: string
  icon?: string
  color?: 'yellow' | 'red' | 'green' | 'dark'
  link?: BlockLink | null
  // иконки и каталог
  mode?: string
  category_ids?: string[]
  shape?: 'circle' | 'square' | 'tiles'
  show_deals?: boolean
  show_images?: boolean
  // данные предпросмотра
  products?: PreviewProduct[]
  banners?: PreviewBanner[]
}

export interface PreviewProduct {
  id: string
  name: string
  images: string[]
  price: string
  old_price: string | null
  discount_percent: number | null
  unit_short: string
}

export interface PreviewBanner {
  id: string
  title: string
  subtitle: string
  image_url: string
  color: string
  show_text: boolean
}

export interface LayoutEditor {
  network_id?: string
  network_name?: string
  store_id?: string
  store_name?: string
  version: number
  published_at: string | null
  blocks: HomeBlock[]
  inherited: boolean
  draft: HomeBlock[] | null
  draft_updated_at: string | null
}

export interface LayoutVersion {
  version: number
  published_at: string
  published_by: string
  blocks: number
}

export function newId(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID()
  return 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => Math.floor(Math.random() * 16).toString(16))
}

/** Новый блок с настройками по умолчанию. */
export function defaultBlock(type: BlockType): HomeBlock {
  const id = newId()
  switch (type) {
    case 'shelf':
      return { id, type, title: 'Хиты недели', source: 'hits', limit: 6, view: 'row', show_all: true }
    case 'banners':
      return { id, type, size: 'big', autoplay: true }
    case 'promo':
      return { id, type, kind: 'custom', title: 'Скидка 10% на первый заказ', icon: 'percent', color: 'yellow', link: { type: 'deals' } }
    case 'category_icons':
      return { id, type, mode: 'auto', shape: 'circle', show_deals: true }
    case 'catalog_sections':
      return { id, type, mode: 'all', view: 'tiles3', show_images: true }
  }
}

/** Блок для сохранения: без данных предпросмотра. */
export function clean(b: HomeBlock): HomeBlock {
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const { products, banners, ...rest } = b
  return rest
}
