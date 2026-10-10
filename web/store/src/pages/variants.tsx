// Группы вариаций в «Товарах» (Figma «ВВ1 · Панель магазина: Товары — группа
// с вариациями»): товары одной группы сворачиваются в строку группы, внутри —
// вес (цена на вес для всех вкусов) и вкусы (своя цена, остаток по вкусу).
import { useRef, useState, type ReactNode } from 'react'
import { useQueries, useQueryClient } from '@tanstack/react-query'
import { Button, Dropdown, Flex, InputNumber, Modal, Spin, Tag, Tooltip, Typography } from 'antd'
import Icon, { CheckOutlined, EditOutlined, InboxOutlined, MoreOutlined, PictureOutlined, UndoOutlined, WarningFilled } from '@ant-design/icons'
import { api, errorText, money, plural, qty, tr, useAction } from '@sm/shared'
import type { Product, VariantGroup, VariantItem, VariantWeight } from '../types'

/** Строка таблицы «Товары»: обычный товар или часть группы вариаций. */
export type VRow =
  | { id: string; kind: 'product'; product: Product }
  | {
      id: string
      kind: 'group'
      groupId: string
      name: string
      /** Товары группы на загруженной странице (до загрузки группы). */
      products: Product[]
      group?: VariantGroup
      children: VRow[]
    }
  | { id: string; kind: 'weight'; group: VariantGroup; weight: VariantWeight; children: VRow[] }
  | { id: string; kind: 'flavor'; group: VariantGroup; weight: VariantWeight; item: VariantItem; product?: Product }
  | { id: string; kind: 'loading'; groupId: string; error: unknown; retry: () => void }

export const childrenOf = (r: VRow): VRow[] | undefined => ('children' in r ? r.children : undefined)

const groupPath = (id: string) => `/store/variant-groups/${id}`

/** Остаток «мало» — подсвечиваем. */
const LOW_STOCK = 3

const flavors = (n: number) => tr(`${n} ${plural(n, 'вкус', 'вкуса', 'вкусов')}`, `${n} ta taʼm`)
const weights = (n: number) => tr(`${n} ${plural(n, 'вес', 'веса', 'весов')}`, `${n} ta vazn`)
const pcs = () => tr('шт', 'dona')

// Значки, которых нет в @ant-design/icons: весы и слои.
const ScaleSvg = () => (
  <svg viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 3v3M5 6h14M7 6l-3 7a3 3 0 0 0 6 0L7 6zM17 6l-3 7a3 3 0 0 0 6 0l-3-7zM12 6v14M8 20h8" />
  </svg>
)
const LayersSvg = () => (
  <svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor">
    <path d="M12 2 2 7l10 5 10-5-10-5zM2 12l10 5 10-5-2.4-1.2L12 14.6 4.4 10.8 2 12zm0 5 10 5 10-5-2.4-1.2L12 19.6l-7.6-3.8L2 17z" />
  </svg>
)
const ScaleIcon = () => <Icon component={ScaleSvg} style={{ color: '#98A2B3' }} />
const LayersIcon = () => <Icon component={LayersSvg} />

/**
 * Группы вариаций страницы «Товары»: сворачивает товары групп, по раскрытию
 * грузит группу (вес → вкусы) для магазина и меняет цены веса и «свою цену».
 */
export function useVariantGroups(storeId: string) {
  const qc = useQueryClient()
  const [open, setOpen] = useState<string[]>([])
  const qs = useQueries({
    queries: open.map((id) => ({
      queryKey: [groupPath(id), { store_id: storeId }],
      queryFn: () => api.get<VariantGroup>(groupPath(id), { store_id: storeId }),
      enabled: !!storeId,
    })),
  })
  const state: Record<string, { data?: VariantGroup; error: unknown; refetch: () => void }> = {}
  open.forEach((id, i) => {
    const q = qs[i]
    if (q) state[id] = { data: q.data, error: q.error, refetch: () => void q.refetch() }
  })

  /** Раскрыли группу — грузим её (один раз, дальше — из кэша). */
  const load = (groupId: string) => setOpen((o) => (o.includes(groupId) ? o : [...o, groupId]))

  /** Товары → строки: товары одной группы на странице — одна строка группы (на месте первого). */
  const build = (items: Product[]): VRow[] => {
    // Без магазина группу не загрузить — показываем товары как есть.
    if (!storeId) return items.map((p) => ({ id: p.id, kind: 'product', product: p }))
    const out: VRow[] = []
    const groups = new Map<string, Extract<VRow, { kind: 'group' }>>()
    const byId = new Map(items.map((p) => [p.id, p]))
    for (const p of items) {
      const gid = p.variant_group_id
      if (!gid) {
        out.push({ id: p.id, kind: 'product', product: p })
        continue
      }
      let g = groups.get(gid)
      if (!g) {
        g = { id: `g|${gid}`, kind: 'group', groupId: gid, name: p.variant_group_name || p.name, products: [], children: [] }
        groups.set(gid, g)
        out.push(g)
      }
      g.products.push(p)
    }
    for (const g of groups.values()) {
      const s = state[g.groupId]
      const data = s?.data
      g.group = data
      g.children = data
        ? data.weights.map((w) => ({
            id: `w|${g.groupId}|${w.weight}`,
            kind: 'weight' as const,
            group: data,
            weight: w,
            children: w.items.map((it) => ({
              id: `f|${it.product_id}`,
              kind: 'flavor' as const,
              group: data,
              weight: w,
              item: it,
              product: byId.get(it.product_id),
            })),
          }))
        : [{ id: `l|${g.groupId}`, kind: 'loading', groupId: g.groupId, error: s?.error ?? null, retry: () => s?.refetch() }]
    }
    return out
  }

  // Ответ — свежая группа: кладём в кэш, списки товаров и документы цен обновятся сами.
  const save = (g: VariantGroup) => {
    qc.setQueryData([groupPath(g.id), { store_id: storeId }], g)
    return g
  }
  const invalidate = [['/store/products'], ['/store/price-documents']]
  const weightPrice = useAction(
    (v: { group: VariantGroup; weight: string; price: string }) =>
      api
        .post<VariantGroup>(`${groupPath(v.group.id)}/weight-price`, {
          store_id: storeId,
          price_type_id: v.group.price_type_id,
          weight: v.weight,
          price: v.price,
        })
        .then(save),
    { success: tr('Цена установлена', 'Narx belgilandi'), invalidate },
  )
  const ownPrice = useAction(
    (v: { group: VariantGroup; productId: string; own: boolean; price?: string }) =>
      api
        .post<VariantGroup>(`${groupPath(v.group.id)}/own-price`, {
          store_id: storeId,
          price_type_id: v.group.price_type_id,
          product_id: v.productId,
          own: v.own,
          price: v.price,
        })
        .then(save),
    { success: tr('Цена сохранена', 'Narx saqlandi'), invalidate },
  )
  return { build, load, weightPrice, ownPrice }
}

export type VariantGroups = ReturnType<typeof useVariantGroups>

// ------------------------------------------------------------ ячейки

/** Ячейка названия для строк группы; null — обычный товар. */
export function variantNameCell(r: VRow): ReactNode {
  if (r.kind === 'group') {
    const p = r.products[0]
    const brand = r.group?.brand_name ?? p?.brand_name ?? null
    const parts = [brand, p?.category_name].filter(Boolean) as string[]
    if (r.group) {
      parts.push(weights(r.group.weights.length))
      parts.push(flavors(r.group.weights.reduce((n, w) => n + w.items.length, 0)))
    } else parts.push(flavors(r.products.length))
    return (
      <Flex align="center" gap={12}>
        <div className="sm-tree-logo">{(brand || r.name).trim().charAt(0).toUpperCase()}</div>
        <div style={{ minWidth: 0 }}>
          <Typography.Text strong style={{ fontSize: 15 }}>
            {r.group?.name ?? r.name}
          </Typography.Text>
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {parts.join(' · ')}
            </Typography.Text>
          </div>
          <Tag color="blue" bordered={false} icon={<LayersIcon />} className="sm-variant-tag">
            {tr('Группа вариаций', 'Variatsiyalar guruhi')}
          </Tag>
        </div>
      </Flex>
    )
  }
  if (r.kind === 'weight')
    return (
      <Flex align="center" gap={8}>
        <ScaleIcon />
        <Typography.Text strong>{r.weight.weight}</Typography.Text>
        <Tag bordered={false} style={{ marginInlineEnd: 0 }}>
          {flavors(r.weight.items.length)}
        </Tag>
      </Flex>
    )
  if (r.kind === 'flavor')
    return (
      <Flex align="center" gap={12}>
        {r.item.image ? (
          <img src={r.item.image} alt="" className="sm-variant-thumb" />
        ) : (
          <div className="sm-variant-thumb sm-variant-thumb-none">
            <PictureOutlined />
          </div>
        )}
        <div style={{ minWidth: 0 }}>
          <Typography.Text strong>{r.item.flavor || r.item.name}</Typography.Text>
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {r.item.name}
            </Typography.Text>
          </div>
        </div>
      </Flex>
    )
  if (r.kind === 'loading')
    return r.error ? (
      <Typography.Text type="danger">
        {tr('Не удалось загрузить группу', 'Guruhni yuklab boʻlmadi')}: {errorText(r.error)}{' '}
        <Button type="link" size="small" onClick={r.retry}>
          {tr('Повторить', 'Qayta urinish')}
        </Button>
      </Typography.Text>
    ) : (
      <Spin size="small" />
    )
  return null
}

/** Остаток вкуса/группы: «12 шт», мало — жёлтым со значком. */
export function StockChip({ value, total }: { value: string; total?: boolean }) {
  const low = !total && Number(value) <= LOW_STOCK
  const text = total ? tr(`${qty(value)} ${pcs()} всего`, `jami ${qty(value)} ${pcs()}`) : `${qty(value)} ${pcs()}`
  return (
    <Tooltip title={low ? tr('Остаток заканчивается', 'Qoldiq tugayapti') : tr('Остаток', 'Qoldiq')}>
      <Tag
        bordered={false}
        color={low ? 'warning' : undefined}
        icon={low ? <WarningFilled /> : <InboxOutlined />}
        className="sm-variant-stock"
      >
        {text}
      </Tag>
    </Tooltip>
  )
}

/** Остаток для колонки «Каталог / остаток»; null — обычный товар. */
export function variantStockCell(r: VRow): ReactNode {
  if (r.kind === 'group') return r.group ? <StockChip value={r.group.stock} total /> : null
  if (r.kind === 'weight')
    return (
      <Typography.Text strong>
        {qty(r.weight.stock)} {pcs()}
      </Typography.Text>
    )
  if (r.kind === 'flavor') return <StockChip value={r.item.stock} />
  return null
}

/** Цена для строк группы; null — обычный товар. */
export function variantPriceCell(r: VRow, v: VariantGroups, canEdit: boolean): ReactNode {
  if (r.kind === 'weight') return <WeightPrice group={r.group} weight={r.weight} v={v} canEdit={canEdit} />
  if (r.kind === 'flavor')
    return (
      <div style={{ lineHeight: 1.3 }}>
        <div>{money(r.item.price)}</div>
        {r.item.own_price ? (
          <Typography.Text strong style={{ fontSize: 12, color: '#B54708' }}>
            {tr('своя цена', 'oʻz narxi')}
          </Typography.Text>
        ) : (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr(`как у ${r.weight.weight}`, `${r.weight.weight} kabi`)}
          </Typography.Text>
        )}
      </div>
    )
  return null
}

/** Меню строки вкуса «⋯»: своя цена / цена как у веса. */
export function FlavorMenu({ r, v }: { r: Extract<VRow, { kind: 'flavor' }>; v: VariantGroups }) {
  const [open, setOpen] = useState(false)
  const [price, setPrice] = useState<string | null>(null)
  const it = r.item
  const busy = v.ownPrice.isPending
  return (
    <>
      <Dropdown
        trigger={['click']}
        menu={{
          items: it.own_price
            ? [
                { key: 'edit', icon: <EditOutlined />, label: tr('Изменить свою цену…', 'Oʻz narxini oʻzgartirish…') },
                { key: 'weight', icon: <UndoOutlined />, label: tr('Цена как у веса', 'Vazn narxiga qaytarish') },
              ]
            : [{ key: 'own', icon: <EditOutlined />, label: tr('Своя цена…', 'Oʻz narxi…') }],
          onClick: ({ key }) => {
            if (key === 'weight') v.ownPrice.mutate({ group: r.group, productId: it.product_id, own: false })
            else {
              setPrice(trim(it.price))
              setOpen(true)
            }
          },
        }}
      >
        <Button type="text" size="small" icon={<MoreOutlined />} loading={busy} aria-label={tr('Действия', 'Amallar')} />
      </Dropdown>
      <Modal
        open={open}
        title={tr(`Своя цена: ${it.flavor || it.name}`, `Oʻz narxi: ${it.flavor || it.name}`)}
        okText={tr('Сохранить', 'Saqlash')}
        cancelText={tr('Отмена', 'Bekor qilish')}
        width={380}
        confirmLoading={busy}
        okButtonProps={{ disabled: !price || Number(price) <= 0 }}
        onCancel={() => setOpen(false)}
        onOk={() => v.ownPrice.mutate({ group: r.group, productId: it.product_id, own: true, price: price ?? undefined }, { onSuccess: () => setOpen(false) })}
        destroyOnHidden
      >
        <Typography.Paragraph type="secondary">
          {tr(
            `Цена веса «${r.weight.weight}» не будет менять цену этого вкуса.`,
            `«${r.weight.weight}» vazn narxi bu taʼm narxini oʻzgartirmaydi.`,
          )}
        </Typography.Paragraph>
        <InputNumber<string>
          stringMode
          min="0"
          autoFocus
          value={price}
          onChange={setPrice}
          suffix={tr('сум', 'soʻm')}
          style={{ width: '100%' }}
          formatter={fmt}
          parser={parse}
          onPressEnter={() => {
            if (price && Number(price) > 0 && !busy)
              v.ownPrice.mutate({ group: r.group, productId: it.product_id, own: true, price }, { onSuccess: () => setOpen(false) })
          }}
        />
      </Modal>
    </>
  )
}

// "18000.00" → "18000": InputNumber показывает без лишних нулей.
const trim = (v: string | null | undefined): string | null => (v === null || v === undefined || v === '' ? null : String(Number(v)))
// 18000 → "18 000" в поле ввода.
const fmt = (v: string | undefined) => (v ? v.replace(/\B(?=(\d{3})+(?!\d))/g, ' ') : '')
const parse = (v: string | undefined) => (v ?? '').replace(/[\s ]/g, '').replace(',', '.')

/** Цена веса прямо в строке: Enter, уход из поля или ✓ — «для всех вкусов». */
function WeightPrice({ group, weight, v, canEdit }: { group: VariantGroup; weight: VariantWeight; v: VariantGroups; canEdit: boolean }) {
  const saved = trim(weight.price)
  const [value, setValue] = useState<string | null>(saved)
  const [prev, setPrev] = useState(saved)
  // Пришла новая цена с сервера — показываем её.
  if (prev !== saved) {
    setPrev(saved)
    setValue(saved)
  }
  const sent = useRef<string | null>(null)
  const dirty = !!value && Number(value) > 0 && (saved === null || Number(value) !== Number(saved))
  const submit = () => {
    if (!dirty || v.weightPrice.isPending || sent.current === value) return
    sent.current = value
    v.weightPrice.mutate(
      { group, weight: weight.weight, price: value! },
      {
        onSettled: () => {
          sent.current = null
        },
      },
    )
  }
  const caption = (
    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
      {tr('для всех вкусов', 'barcha taʼmlar uchun')}
    </Typography.Text>
  )
  if (!canEdit)
    return (
      <div style={{ lineHeight: 1.3 }}>
        <div>{weight.price ? money(weight.price) : <Typography.Text type="secondary">{tr('разные', 'turlicha')}</Typography.Text>}</div>
        {caption}
      </div>
    )
  return (
    <Flex vertical align="flex-end" gap={2}>
      <Flex align="center" gap={4}>
        <InputNumber<string>
          stringMode
          min="0"
          size="small"
          value={value}
          onChange={setValue}
          placeholder={tr('разные', 'turlicha')}
          suffix={
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('сум', 'soʻm')} {!dirty && <EditOutlined />}
            </Typography.Text>
          }
          formatter={fmt}
          parser={parse}
          disabled={v.weightPrice.isPending}
          onPressEnter={submit}
          onBlur={submit}
          style={{ width: 150 }}
          className="sm-variant-price"
        />
        {dirty && (
          <Tooltip title={tr('Сохранить', 'Saqlash')}>
            <Button
              size="small"
              type="primary"
              icon={<CheckOutlined />}
              loading={v.weightPrice.isPending}
              // mousedown раньше blur: иначе сохранение ушло бы дважды.
              onMouseDown={(e) => e.preventDefault()}
              onClick={submit}
              aria-label={tr('Сохранить', 'Saqlash')}
            />
          </Tooltip>
        )}
      </Flex>
      {caption}
    </Flex>
  )
}
