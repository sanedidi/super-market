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
import { tr } from '../i18n'

export const BLOCK_TYPES: { type: BlockType; title: string; text: string; icon: ReactNode }[] = [
  { type: 'shelf', title: tr('Полка товаров', 'Mahsulotlar javoni'), text: tr('Хиты, скидки, новинки, категория или подборка вручную', 'Xitlar, chegirmalar, yangiliklar, kategoriya yoki qoʻlda tanlov'), icon: <AppstoreFilled /> },
  { type: 'banners', title: tr('Баннеры', 'Bannerlar'), text: tr('Фото на всю ширину или узкая лента с текстом', 'Toʻliq kenglikdagi rasm yoki matnli tor lenta'), icon: <PictureFilled /> },
  { type: 'promo', title: tr('Промо-полоска', 'Promo-chiziq'), text: tr('Короткая строка с иконкой, цветом и ссылкой', 'Belgi, rang va havolali qisqa satr'), icon: <SoundFilled /> },
  { type: 'category_icons', title: tr('Иконки разделов', 'Boʻlim belgilari'), text: tr('Круглые иконки выбранных категорий', 'Tanlangan kategoriyalarning dumaloq belgilari'), icon: <AimOutlined /> },
  { type: 'catalog_sections', title: tr('Каталог по разделам', 'Boʻlimlar boʻyicha katalog'), text: tr('Все категории магазина плитками', 'Doʻkonning barcha kategoriyalari plitkalarda'), icon: <TableOutlined /> },
]

export const typeMeta = (t: BlockType) => BLOCK_TYPES.find((x) => x.type === t)!

export const SOURCES = [
  { value: 'hits', label: tr('Хиты', 'Xitlar') },
  { value: 'discount', label: tr('Скидки', 'Chegirmalar') },
  { value: 'new', label: tr('Новинки', 'Yangiliklar') },
  { value: 'category', label: tr('Категория', 'Kategoriya') },
  { value: 'manual', label: tr('Вручную', 'Qoʻlda') },
]

export const SHELF_VIEWS = [
  { value: 'row', label: tr('Лента', 'Lenta') },
  { value: 'grid2', label: tr('Сетка ×2', 'Toʻr ×2') },
  { value: 'grid3', label: tr('Сетка ×3', 'Toʻr ×3') },
]

export const CATALOG_VIEWS = [
  { value: 'tiles3', label: tr('Плитки ×3', 'Plitkalar ×3') },
  { value: 'tiles2', label: tr('Плитки ×2', 'Plitkalar ×2') },
  { value: 'list', label: tr('Список', 'Roʻyxat') },
]

export const SHAPES = [
  { value: 'circle', label: tr('Круги', 'Doiralar') },
  { value: 'square', label: tr('Квадраты', 'Kvadratlar') },
  { value: 'tiles', label: tr('Плитки', 'Plitkalar') },
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
  red: { bg: '#E11D2A', icon: '#fff', fg: '#fff', swatch: '#E11D2A', label: tr('Красный', 'Qizil') },
  yellow: { bg: '#FFF7D6', icon: '#D69E00', fg: '#151515', swatch: '#FFC21A', label: tr('Жёлтый', 'Sariq') },
  green: { bg: '#E8F6EE', icon: '#2E9E5B', fg: '#151515', swatch: '#17B26A', label: tr('Зелёный', 'Yashil') },
  dark: { bg: '#151515', icon: '#FFD84D', fg: '#fff', swatch: '#1F2430', label: tr('Тёмный', 'Toʻq') },
}

export const LINKS = [
  { value: 'none', label: tr('Никуда', 'Hech qayerga') },
  { value: 'deals', label: tr('Все скидки', 'Barcha chegirmalar') },
  { value: 'category', label: tr('Категория', 'Kategoriya') },
  { value: 'product', label: tr('Товар', 'Mahsulot') },
  { value: 'delivery_terms', label: tr('Условия доставки', 'Yetkazib berish shartlari') },
  { value: 'url', label: tr('Сайт', 'Sayt') },
]

/** Заголовок блока в списке. */
export function blockTitle(b: HomeBlock): string {
  switch (b.type) {
    case 'shelf':
      return tr(`Полка «${b.title || '…'}»`, `«${b.title || '…'}» javoni`)
    case 'banners':
      return b.size === 'strip' ? tr('Узкая лента', 'Tor lenta') : tr('Баннеры', 'Bannerlar')
    case 'promo':
      return tr('Промо-полоска', 'Promo-chiziq')
    default:
      return typeMeta(b.type).title
  }
}

/** Строка под заголовком: что внутри блока. */
export function blockSummary(b: HomeBlock): string {
  const label = (list: { value: string; label: string }[], v?: string) => list.find((x) => x.value === v)?.label ?? ''
  switch (b.type) {
    case 'shelf': {
      const src =
        b.source === 'manual'
          ? tr(`Вручную · ${b.product_ids?.length ?? 0} товаров`, `Qoʻlda · ${b.product_ids?.length ?? 0} ta mahsulot`)
          : tr(`${label(SOURCES, b.source)} · ${b.limit} товаров`, `${label(SOURCES, b.source)} · ${b.limit} ta mahsulot`)
      return `${src} · ${label(SHELF_VIEWS, b.view).toLowerCase()}`
    }
    case 'banners':
      if (b.size === 'strip') return `«${b.title ?? ''}»`
      return b.banner_ids?.length
        ? tr(`${b.banner_ids.length} баннера по порядку`, `${b.banner_ids.length} ta banner tartib bilan`)
        : tr('Все активные баннеры', 'Barcha faol bannerlar')
    case 'promo':
      return b.kind === 'free_delivery'
        ? tr('«Доставка 0 сум от …» и сколько осталось', '«… dan yetkazib berish 0 soʻm» va qancha qolgani')
        : `«${b.title ?? ''}»`
    case 'category_icons':
      return `${b.show_deals !== false ? tr('Скидки + ', 'Chegirmalar + ') : ''}${
        b.mode === 'manual'
          ? tr(`${b.category_ids?.length ?? 0} категорий`, `${b.category_ids?.length ?? 0} ta kategoriya`)
          : tr('все разделы магазина', 'doʻkonning barcha boʻlimlari')
      } · ${label(SHAPES, b.shape).toLowerCase()}`
    case 'catalog_sections':
      return `${
        b.mode === 'selected'
          ? tr(`${b.category_ids?.length ?? 0} разделов`, `${b.category_ids?.length ?? 0} ta boʻlim`)
          : tr('Все категории', 'Barcha kategoriyalar')
      } · ${label(CATALOG_VIEWS, b.view).toLowerCase()}`
  }
}

/** Пометка расписания: «до 5 окт», «с 10 окт», «прошло». */
export function scheduleTag(b: HomeBlock): { text: string; tone: 'warn' | 'muted' } | null {
  const now = dayjs()
  const fmt = (v: string) => dayjs(v).format('D MMM')
  if (b.ends_at && dayjs(b.ends_at).isBefore(now)) return { text: tr('прошло', 'oʻtdi'), tone: 'muted' }
  if (b.starts_at && dayjs(b.starts_at).isAfter(now)) return { text: tr(`с ${fmt(b.starts_at)}`, `${fmt(b.starts_at)} dan`), tone: 'warn' }
  if (b.ends_at) return { text: tr(`до ${fmt(b.ends_at)}`, `${fmt(b.ends_at)} gacha`), tone: 'warn' }
  return null
}
