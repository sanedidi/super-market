// Дерево товаров «бренд → категория → товар» (Figma «Товары · бренд → категория»).
// Группы и их счётчики — одним запросом (groupsPath), товары категории —
// списком itemsPath с brand_id и leaf_category_id, по pageSize с «Показать ещё».
// mapItems/childrenOf — свои строки вместо товаров категории (например, группа
// вариаций «вес → вкус» в панели магазина); по умолчанию строка = товар.
import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useQueries, useQuery } from '@tanstack/react-query'
import { Button, Card, Flex, Segmented, Spin, Table, Tag, Typography, type TableColumnType } from 'antd'
import {
  ApartmentOutlined,
  ClockCircleOutlined,
  DownOutlined,
  FolderOpenOutlined,
  FolderOutlined,
  NodeCollapseOutlined,
  UnorderedListOutlined,
} from '@ant-design/icons'
import { api, type List } from './api'
import { LoadError } from './components'
import { tr } from './i18n'

type Params = Record<string, string | number | boolean | undefined | null>

export type ProductGroupCategory = {
  category_id: string
  category_name: string
  count: number
  pending: number
}
export type ProductGroupBrand = {
  brand_id: string | null
  brand_name: string
  count: number
  pending: number
  categories: ProductGroupCategory[]
}
export type ProductGroups = { brands: ProductGroupBrand[]; total: number }

type Row<R> = {
  key: string
  kind: 'brand' | 'category' | 'product' | 'more' | 'loading'
  brand?: ProductGroupBrand
  cat?: ProductGroupCategory
  item?: R
  left?: number
  children?: Row<R>[]
}

/** Склонение: 1 товар, 2 товара, 5 товаров. */
export function plural(n: number, one: string, few: string, many: string) {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}
const goods = (n: number) => tr(`${n} ${plural(n, 'товар', 'товара', 'товаров')}`, `${n} ta mahsulot`)

export type ProductView = 'tree' | 'list'

/** Переключатель «По брендам / Списком»; выбор запоминается в браузере. */
export function useProductView(): [ProductView, (v: ProductView) => void] {
  const [view, setView] = useState<ProductView>(() => {
    try {
      return localStorage.getItem('sm.products.view') === 'list' ? 'list' : 'tree'
    } catch {
      return 'tree'
    }
  })
  const set = (v: ProductView) => {
    setView(v)
    try {
      localStorage.setItem('sm.products.view', v)
    } catch {
      // браузер без хранилища — выбор живёт до перезагрузки
    }
  }
  return [view, set]
}

export function ProductViewSwitch({ value, onChange }: { value: ProductView; onChange: (v: ProductView) => void }) {
  return (
    <Segmented<ProductView>
      value={value}
      onChange={onChange}
      options={[
        { value: 'tree', label: tr('По брендам', 'Brendlar boʻyicha'), icon: <ApartmentOutlined /> },
        { value: 'list', label: tr('Списком', 'Roʻyxat'), icon: <UnorderedListOutlined /> },
      ]}
    />
  )
}

/** Клик пришёл из поля ввода, кнопки или меню внутри строки (а не по самой строке). */
export function interactive(target: EventTarget | null): boolean {
  return target instanceof Element && !!target.closest('input, button, a, .ant-input-number, .ant-dropdown-trigger, .ant-table-row-expand-icon')
}

const brandKey = (b: ProductGroupBrand) => `b|${b.brand_id ?? 'none'}`
const catKey = (b: ProductGroupBrand, c: ProductGroupCategory) => `c|${b.brand_id ?? 'none'}|${c.category_id}`

export function ProductTree<T extends { id: string }, R extends { id: string } = T>({
  groupsPath,
  itemsPath,
  params,
  columns,
  pendingText = (n) => tr(`${n} на модерации`, `${n} ta moderatsiyada`),
  pageSize = 20,
  mapItems,
  childrenOf,
  onExpandItem,
  onItemClick,
}: {
  groupsPath: string
  itemsPath: string
  params?: Params
  /** Колонки строки товара; первая — название (в ней отступ дерева). */
  columns: TableColumnType<R>[]
  pendingText?: (n: number) => string
  pageSize?: number
  /** Строки категории из её товаров (по умолчанию — сами товары). id строк уникальны в категории. */
  mapItems?: (items: T[]) => R[]
  /** Вложенные строки строки товара (раскрываются шевроном). */
  childrenOf?: (row: R) => R[] | undefined
  /** Строку товара с вложенными строками раскрыли или свернули. */
  onExpandItem?: (row: R, open: boolean) => void
  /** Клик по строке товара (без вложенных) — например, открыть его страницу. */
  onItemClick?: (row: R) => void
}) {
  const groups = useQuery({
    queryKey: [groupsPath, params],
    queryFn: () => api.get<ProductGroups>(groupsPath, params),
    placeholderData: (prev) => prev,
  })
  const brands = useMemo(() => groups.data?.brands ?? [], [groups.data])
  const [expanded, setExpanded] = useState<string[]>([])
  const [limits, setLimits] = useState<Record<string, number>>({})

  // Единственный найденный бренд раскрываем сразу.
  useEffect(() => {
    if (brands.length === 1) setExpanded((e) => (e.includes(brandKey(brands[0])) ? e : [...e, brandKey(brands[0])]))
  }, [brands])

  const open = useMemo(() => {
    const out: {
      key: string
      brand: ProductGroupBrand
      cat: ProductGroupCategory
    }[] = []
    for (const b of brands) {
      if (!expanded.includes(brandKey(b))) continue
      for (const c of b.categories) if (expanded.includes(catKey(b, c))) out.push({ key: catKey(b, c), brand: b, cat: c })
    }
    return out
  }, [brands, expanded])

  const items = useQueries({
    queries: open.map(({ key, brand, cat }) => {
      const limit = limits[key] ?? pageSize
      return {
        queryKey: [
          itemsPath,
          {
            ...params,
            brand_id: brand.brand_id ?? 'none',
            leaf_category_id: cat.category_id,
            sort: 'name',
            limit,
            offset: 0,
          },
        ],
        queryFn: () =>
          api
            .get<List<T>>(itemsPath, {
              ...params,
              brand_id: brand.brand_id ?? 'none',
              leaf_category_id: cat.category_id,
              sort: 'name',
              limit,
              offset: 0,
            })
            .then((r) => r.items ?? []),
        placeholderData: (prev: T[] | undefined) => prev,
      }
    }),
  })
  const loaded: Record<string, { items: T[]; fetching: boolean }> = {}
  open.forEach((o, i) => {
    const q = items[i]
    if (q?.data) loaded[o.key] = { items: q.data, fetching: q.isFetching }
  })

  const itemRow = (prefix: string, item: R): Row<R> => {
    const kids = childrenOf?.(item)
    return {
      key: `${prefix}|${item.id}`,
      kind: 'product',
      item,
      children: kids?.map((c) => itemRow(prefix, c)),
    }
  }

  const data: Row<R>[] = brands.map((b) => ({
    key: brandKey(b),
    kind: 'brand',
    brand: b,
    children: b.categories.map((c) => {
      const k = catKey(b, c)
      const l = loaded[k]
      const rows = l ? (mapItems ? mapItems(l.items) : (l.items as unknown as R[])) : []
      const children: Row<R>[] = l
        ? [
            ...rows.map((item) => itemRow(k, item)),
            ...(c.count > l.items.length
              ? [
                  {
                    key: `${k}|more`,
                    kind: 'more' as const,
                    cat: c,
                    brand: b,
                    left: c.count - l.items.length,
                  },
                ]
              : []),
          ]
        : [{ key: `${k}|loading`, kind: 'loading' }]
      return { key: k, kind: 'category' as const, brand: b, cat: c, children }
    }),
  }))

  const toggle = (key: string) => setExpanded((e) => (e.includes(key) ? e.filter((x) => x !== key) : [...e, key]))
  const toggleRow = (r: Row<R>) => {
    const willOpen = !expanded.includes(r.key)
    toggle(r.key)
    if (r.kind === 'product' && r.item) onExpandItem?.(r.item, willOpen)
  }

  const groupCell = (r: Row<R>): ReactNode => {
    if (r.kind === 'brand' && r.brand) {
      const b = r.brand
      const none = b.brand_id === null
      return (
        <Flex align="center" justify="space-between" gap={12} wrap>
          <Flex align="center" gap={12}>
            <div className={none ? 'sm-tree-logo sm-tree-logo-none' : 'sm-tree-logo'}>{none ? '—' : b.brand_name.trim().charAt(0).toUpperCase()}</div>
            <div>
              <Typography.Text strong style={{ fontSize: 15 }} type={none ? 'secondary' : undefined}>
                {b.brand_name}
              </Typography.Text>
              <div>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {goods(b.count)} ·{' '}
                  {tr(
                    `${b.categories.length} ${plural(b.categories.length, 'категория', 'категории', 'категорий')}`,
                    `${b.categories.length} ta kategoriya`,
                  )}
                </Typography.Text>
              </div>
            </div>
          </Flex>
          {b.pending > 0 && (
            <Tag color="orange" icon={<ClockCircleOutlined />} bordered={false}>
              {pendingText(b.pending)}
            </Tag>
          )}
        </Flex>
      )
    }
    if (r.kind === 'category' && r.cat) {
      const isOpen = expanded.includes(r.key)
      return (
        <Flex align="center" gap={8}>
          {isOpen ? <FolderOpenOutlined style={{ color: '#98A2B3' }} /> : <FolderOutlined style={{ color: '#98A2B3' }} />}
          <Typography.Text strong>{r.cat.category_name}</Typography.Text>
          <Tag bordered={false}>{r.cat.count}</Tag>
          {r.cat.pending > 0 && (
            <Tag color="orange" bordered={false}>
              {pendingText(r.cat.pending)}
            </Tag>
          )}
        </Flex>
      )
    }
    if (r.kind === 'more') {
      const k = r.key.slice(0, -'|more'.length)
      const fetching = loaded[k]?.fetching
      return (
        <Button
          type="link"
          danger
          size="small"
          loading={fetching}
          icon={<DownOutlined />}
          iconPosition="end"
          onClick={(e) => {
            e.stopPropagation()
            setLimits((l) => ({ ...l, [k]: (l[k] ?? pageSize) + pageSize }))
          }}
        >
          {tr('Показать ещё', 'Yana koʻrsatish:')} {goods(Math.min(r.left ?? 0, pageSize))}
          {(r.left ?? 0) > pageSize ? tr(` из ${r.left}`, ` (${r.left} tadan)`) : ''}
        </Button>
      )
    }
    return <Spin size="small" />
  }

  const cols: TableColumnType<Row<R>>[] = columns.map((col, i) => {
    const { dataIndex, render, onCell } = col
    return {
      title: col.title as ReactNode,
      align: col.align,
      width: col.width,
      className: col.className,
      key: String(col.key ?? (typeof dataIndex === 'string' ? dataIndex : i)),
      onCell: (r: Row<R>, idx?: number) =>
        r.kind === 'product' && r.item ? ((onCell?.(r.item, idx) ?? {}) as object) : { colSpan: i === 0 ? columns.length : 0 },
      render: (_: unknown, r: Row<R>, idx: number) => {
        if (r.kind !== 'product' || !r.item) return i === 0 ? groupCell(r) : null
        const v = typeof dataIndex === 'string' ? (r.item as Record<string, unknown>)[dataIndex] : undefined
        return render ? (render(v, r.item, idx) as ReactNode) : (v as ReactNode)
      },
    }
  })

  return (
    <>
      <LoadError error={groups.error} retry={() => groups.refetch()} />
      <Card styles={{ body: { padding: 0 } }} className="sm-tree">
        <Table<Row<R>>
          rowKey="key"
          size="middle"
          loading={groups.isLoading || (groups.isFetching && !groups.data)}
          dataSource={data}
          columns={cols}
          scroll={{ x: true }}
          rowClassName={(r) => `sm-tree-${r.kind}`}
          onRow={(r) =>
            r.kind === 'brand' || r.kind === 'category'
              ? { onClick: () => toggle(r.key), style: { cursor: 'pointer' } }
              : r.kind === 'product' && r.children
                ? {
                    // Строка с вложенными: клик раскрывает, но не по полям и кнопкам внутри неё.
                    onClick: (e) => {
                      if (!interactive(e.target)) toggleRow(r)
                    },
                    style: { cursor: 'pointer' },
                  }
                : r.kind === 'product' && r.item && onItemClick
                  ? {
                      onClick: (e) => {
                        if (!interactive(e.target)) onItemClick(r.item!)
                      },
                      style: { cursor: 'pointer' },
                    }
                  : {}
          }
          expandable={{
            expandedRowKeys: expanded,
            onExpand: (_, r) => toggleRow(r),
            indentSize: 28,
          }}
          title={
            expanded.length
              ? () => (
                  <Flex justify="flex-end">
                    <Button size="small" type="text" icon={<NodeCollapseOutlined />} onClick={() => setExpanded([])}>
                      {tr('Свернуть всё', 'Hammasini yigʻish')}
                    </Button>
                  </Flex>
                )
              : undefined
          }
          pagination={{
            pageSize: 20,
            hideOnSinglePage: true,
            showSizeChanger: false,
            showTotal: () => tr(`Брендов: ${brands.length}`, `Brendlar: ${brands.length}`) + ` · ${goods(groups.data?.total ?? 0)}`,
          }}
          locale={{ emptyText: tr('Товары не найдены', 'Mahsulotlar topilmadi') }}
          footer={brands.length && brands.length <= 20 ? () => tr(`Брендов: ${brands.length}`, `Brendlar: ${brands.length}`) + ` · ${goods(groups.data?.total ?? 0)}` : undefined}
        />
      </Card>
    </>
  )
}
