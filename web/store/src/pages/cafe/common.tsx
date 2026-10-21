// Общие элементы разделов кафе: вкладки «Меню», «Склад продуктов», значки цехов.
import { useEffect, useState, type ReactNode } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { Select, Tabs, Tag, type SelectProps } from 'antd'
import { money, qty, tr, useDebounced, useList } from '@sm/shared'
import type { Ingredient, Kind, WorkshopIcon } from './types'

/** Вкладки страницы со ссылками: активна та, чей путь совпал точнее всего. */
export function LinkTabs({ items }: { items: { path: string; label: ReactNode; count?: number; badge?: ReactNode }[] }) {
  const nav = useNavigate()
  const { pathname } = useLocation()
  const active = [...items].sort((a, b) => b.path.length - a.path.length).find((i) => pathname === i.path || pathname.startsWith(i.path + '/'))
  return (
    <Tabs
      activeKey={active?.path}
      onChange={(k) => nav(k)}
      items={items.map((i) => ({
        key: i.path,
        label: (
          <span>
            {i.label}
            {i.count !== undefined && (
              <Tag bordered={false} style={{ marginLeft: 6, marginInlineEnd: 0 }}>
                {i.count}
              </Tag>
            )}
            {i.badge}
          </span>
        ),
      }))}
    />
  )
}

export function MenuTabs({ dishes, modifiers, workshops, stopped }: { dishes?: number; modifiers?: number; workshops?: number; stopped?: number }) {
  return (
    <LinkTabs
      items={[
        { path: '/menu', label: tr('Блюда', 'Taomlar'), count: dishes },
        { path: '/menu/modifiers', label: tr('Модификаторы', 'Modifikatorlar'), count: modifiers },
        { path: '/kitchen', label: tr('Цеха', 'Sexlar'), count: workshops },
        { path: '/menu/stop', label: tr('Стоп-лист', 'Stop-roʻyxat'), count: stopped },
      ]}
    />
  )
}

export function StockTabs() {
  return (
    <LinkTabs
      items={[
        { path: '/kitchen-stock', label: tr('Остатки', 'Qoldiqlar') },
        { path: '/kitchen-stock/preps', label: tr('Заготовки', 'Yarim tayyorlar') },
        { path: '/purchases/income', label: tr('Приходы', 'Kirimlar') },
        { path: '/stock/write-off', label: tr('Списания', 'Hisobdan chiqarishlar') },
        { path: '/stock/inventory', label: tr('Инвентаризация', 'Inventarizatsiya') },
      ]}
    />
  )
}

export const WORKSHOP_ICONS: { key: WorkshopIcon; emoji: string; title: string }[] = [
  { key: 'fire', emoji: '🔥', title: tr('Горячий цех', 'Issiq sex') },
  { key: 'bakery', emoji: '🥟', title: tr('Выпечка', 'Pishiriqlar') },
  { key: 'bar', emoji: '🍹', title: tr('Бар', 'Bar') },
  { key: 'soup', emoji: '🍜', title: tr('Супы', 'Shoʻrvalar') },
  { key: 'grill', emoji: '🍢', title: tr('Гриль', 'Gril') },
  { key: 'salad', emoji: '🥗', title: tr('Салаты', 'Salatlar') },
  { key: 'pizza', emoji: '🍕', title: tr('Пицца', 'Pitsa') },
  { key: 'cafe', emoji: '☕', title: tr('Кофе и чай', 'Qahva va choy') },
]

export function WorkshopEmoji({ icon, size = 22 }: { icon: WorkshopIcon; size?: number }) {
  const e = WORKSHOP_ICONS.find((i) => i.key === icon)?.emoji ?? '🔥'
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: size + 18,
        height: size + 18,
        borderRadius: 10,
        background: '#fef3f2',
        fontSize: size,
        lineHeight: 1,
      }}
    >
      {e}
    </span>
  )
}

/** Наценка в процентах к себестоимости (как в Figma П1/П2). */
export function markupPct(price: string, cost: string): number | null {
  const c = Number(cost)
  const p = Number(price)
  if (!(c > 0)) return null
  return Math.round(((p - c) / c) * 100)
}

export function MarkupText({ price, cost }: { price: string; cost: string }) {
  const m = markupPct(price, cost)
  if (m === null) return <span style={{ color: 'var(--sm-muted)' }}>—</span>
  return <b style={{ color: m < 60 ? '#b54708' : '#067647' }}>{m}%</b>
}

export const kindLabel = (k: Kind) => (k === 'prep' ? tr('заготовка', 'yarim tayyor') : k === 'dish' ? tr('блюдо', 'taom') : tr('товар', 'mahsulot'))

/**
 * Поиск продукта для техкарты или модификатора: товары каталога (по названию
 * и штрихкоду) и заготовки сети; withDishes — ещё и блюда (для «+ салат»).
 */
export function IngredientSelect({
  value,
  label,
  onPick,
  withDishes,
  ...props
}: {
  value?: string
  label?: string
  onPick: (i: Ingredient) => void
  withDishes?: boolean
} & Omit<SelectProps, 'value' | 'onChange' | 'options'>) {
  const [q, setQ] = useState('')
  const debounced = useDebounced(q.trim())
  const { data, isFetching } = useList<Ingredient>('/store/cafe/ingredients', { q: debounced || undefined, with_dishes: withDishes ? 1 : undefined })
  const [known, setKnown] = useState<Record<string, Ingredient>>({})
  useEffect(() => {
    if (data?.length) setKnown((k) => ({ ...k, ...Object.fromEntries(data.map((d) => [d.id, d])) }))
  }, [data])
  const options = (data ?? []).map((i) => ({
    value: i.id,
    label: (
      <span>
        {i.name}{' '}
        <span style={{ color: 'var(--sm-muted)', fontSize: 12 }}>
          {i.kind !== 'goods' ? kindLabel(i.kind) + ' · ' : ''}
          {i.unit_short}
          {i.cost ? ' · ' + money(i.cost) + ' / ' + i.unit_short : ''}
        </span>
      </span>
    ),
  }))
  if (value && !options.some((o) => o.value === value)) options.unshift({ value, label: <span>{label ?? known[value]?.name ?? value}</span> })
  return (
    <Select
      showSearch
      value={value || undefined}
      filterOption={false}
      onSearch={setQ}
      loading={isFetching}
      options={options}
      placeholder={tr('Продукт, заготовка или штрихкод', 'Mahsulot, yarim tayyor yoki shtrix-kod')}
      notFoundContent={debounced ? tr('Ничего не нашлось', 'Hech narsa topilmadi') : tr('Начните вводить название', 'Nomini yoza boshlang')}
      onChange={(id) => {
        const i = data?.find((x) => x.id === id) ?? known[id as string]
        if (i) onPick(i)
      }}
      style={{ width: '100%' }}
      {...props}
    />
  )
}

export function qtyUnit(v: string | null | undefined, unit: string) {
  return qty(v, unit)
}
