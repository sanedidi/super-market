import type { ReactNode } from 'react'
import {
  AimOutlined,
  AppstoreFilled,
  BulbFilled,
  ClockCircleFilled,
  FireFilled,
  GiftFilled,
  PercentageOutlined,
  PictureFilled,
  SmileFilled,
  SoundFilled,
  StarFilled,
  TableOutlined,
  TagFilled,
  ThunderboltFilled,
  CarFilled,
} from '@ant-design/icons'
import dayjs from 'dayjs'
import type { BlockType, HomeBlock } from './types'

export const BLOCK_TYPES: { type: BlockType; title: string; text: string; icon: ReactNode }[] = [
  { type: 'shelf', title: 'Полка товаров', text: 'Хиты, скидки, новинки, категория или подборка вручную', icon: <AppstoreFilled /> },
  { type: 'banners', title: 'Баннеры', text: 'Фото на всю ширину или узкая лента с текстом', icon: <PictureFilled /> },
  { type: 'promo', title: 'Промо-полоска', text: 'Короткая строка с иконкой, цветом и ссылкой', icon: <SoundFilled /> },
  { type: 'category_icons', title: 'Иконки разделов', text: 'Круглые иконки выбранных категорий', icon: <AimOutlined /> },
  { type: 'catalog_sections', title: 'Каталог по разделам', text: 'Все категории магазина плитками', icon: <TableOutlined /> },
]

export const typeMeta = (t: BlockType) => BLOCK_TYPES.find((x) => x.type === t)!

export const SOURCES = [
  { value: 'hits', label: 'Хиты' },
  { value: 'discount', label: 'Скидки' },
  { value: 'new', label: 'Новинки' },
  { value: 'category', label: 'Категория' },
  { value: 'manual', label: 'Вручную' },
]

export const SHELF_VIEWS = [
  { value: 'row', label: 'Лента' },
  { value: 'grid2', label: 'Сетка ×2' },
  { value: 'grid3', label: 'Сетка ×3' },
]

export const CATALOG_VIEWS = [
  { value: 'tiles3', label: 'Плитки ×3' },
  { value: 'tiles2', label: 'Плитки ×2' },
  { value: 'list', label: 'Список' },
]

export const SHAPES = [
  { value: 'circle', label: 'Круги' },
  { value: 'square', label: 'Квадраты' },
  { value: 'tiles', label: 'Плитки' },
]

/** Иконки промо-полоски и узкой ленты (те же ключи в приложении). */
export const ICONS: { value: string; icon: ReactNode }[] = [
  { value: 'tag', icon: <TagFilled /> },
  { value: 'percent', icon: <PercentageOutlined /> },
  { value: 'bolt', icon: <ThunderboltFilled /> },
  { value: 'party', icon: <SmileFilled /> },
  { value: 'leaf', icon: <BulbFilled /> },
  { value: 'gift', icon: <GiftFilled /> },
  { value: 'truck', icon: <CarFilled /> },
  { value: 'fire', icon: <FireFilled /> },
  { value: 'star', icon: <StarFilled /> },
  { value: 'clock', icon: <ClockCircleFilled /> },
]

export const iconOf = (k?: string) => ICONS.find((i) => i.value === k)?.icon ?? <TagFilled />

/** Цвета полосок: фон, иконка, текст. */
export const COLORS: Record<string, { bg: string; icon: string; fg: string; swatch: string; label: string }> = {
  red: { bg: '#E11D2A', icon: '#fff', fg: '#fff', swatch: '#E11D2A', label: 'Красный' },
  yellow: { bg: '#FFF7D6', icon: '#D69E00', fg: '#151515', swatch: '#FFC21A', label: 'Жёлтый' },
  green: { bg: '#E8F6EE', icon: '#2E9E5B', fg: '#151515', swatch: '#17B26A', label: 'Зелёный' },
  dark: { bg: '#151515', icon: '#FFD84D', fg: '#fff', swatch: '#1F2430', label: 'Тёмный' },
}

export const LINKS = [
  { value: 'none', label: 'Никуда' },
  { value: 'deals', label: 'Все скидки' },
  { value: 'category', label: 'Категория' },
  { value: 'product', label: 'Товар' },
  { value: 'delivery_terms', label: 'Условия доставки' },
  { value: 'url', label: 'Сайт' },
]

/** Заголовок блока в списке. */
export function blockTitle(b: HomeBlock): string {
  switch (b.type) {
    case 'shelf':
      return `Полка «${b.title || '…'}»`
    case 'banners':
      return b.size === 'strip' ? 'Узкая лента' : 'Баннеры'
    case 'promo':
      return 'Промо-полоска'
    default:
      return typeMeta(b.type).title
  }
}

/** Строка под заголовком: что внутри блока. */
export function blockSummary(b: HomeBlock): string {
  const label = (list: { value: string; label: string }[], v?: string) => list.find((x) => x.value === v)?.label ?? ''
  switch (b.type) {
    case 'shelf': {
      const src = b.source === 'manual' ? `Вручную · ${b.product_ids?.length ?? 0} товаров` : `${label(SOURCES, b.source)} · ${b.limit} товаров`
      return `${src} · ${label(SHELF_VIEWS, b.view).toLowerCase()}`
    }
    case 'banners':
      if (b.size === 'strip') return `«${b.title ?? ''}»`
      return b.banner_ids?.length ? `${b.banner_ids.length} баннера по порядку` : 'Все активные баннеры'
    case 'promo':
      return b.kind === 'free_delivery' ? '«Доставка 0 сум от …» и сколько осталось' : `«${b.title ?? ''}»`
    case 'category_icons':
      return `${b.show_deals !== false ? 'Скидки + ' : ''}${b.mode === 'manual' ? `${b.category_ids?.length ?? 0} категорий` : 'все разделы магазина'} · ${label(SHAPES, b.shape).toLowerCase()}`
    case 'catalog_sections':
      return `${b.mode === 'selected' ? `${b.category_ids?.length ?? 0} разделов` : 'Все категории'} · ${label(CATALOG_VIEWS, b.view).toLowerCase()}`
  }
}

/** Пометка расписания: «до 5 окт», «с 10 окт», «прошло». */
export function scheduleTag(b: HomeBlock): { text: string; tone: 'warn' | 'muted' } | null {
  const now = dayjs()
  const fmt = (v: string) => dayjs(v).format('D MMM')
  if (b.ends_at && dayjs(b.ends_at).isBefore(now)) return { text: 'прошло', tone: 'muted' }
  if (b.starts_at && dayjs(b.starts_at).isAfter(now)) return { text: `с ${fmt(b.starts_at)}`, tone: 'warn' }
  if (b.ends_at) return { text: `до ${fmt(b.ends_at)}`, tone: 'warn' }
  return null
}
