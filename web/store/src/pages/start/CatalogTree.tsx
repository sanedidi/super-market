// Общий каталог с галочками: категория → подкатегория → бренд → товар.
// Галочка на группе добавляет все её товары в список (по 1 шт), снятая — убирает.
import { useMemo, useState, type ReactNode } from 'react'
import { useQueries, useQuery } from '@tanstack/react-query'
import { Card, ConfigProvider, Empty, Flex, Input, Spin, Tree, Typography } from 'antd'
import type { DataNode } from 'antd/es/tree'
import { PictureOutlined, SearchOutlined } from '@ant-design/icons'
import { LoadError, api, money, plural, tr, useDebounced, type List } from '@sm/shared'
import { useStartApi, type Catalog, type CatalogItem } from './api'

type Node = DataNode & {
  kind: 'cat' | 'brand' | 'product' | 'loading' | 'more'
  name: string
  count: number
  selected: number
  catId?: string
  brandId?: string
  productId?: string
  item?: CatalogItem
  children?: Node[]
}

const ITEMS_LIMIT = 200
const brandKey = (catId: string, brandId: string | null) => `b:${catId}:${brandId ?? 'none'}`

export function Thumb({ src, size = 32 }: { src: string | null | undefined; size?: number }) {
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: 8,
        background: '#F2F4F7',
        flex: 'none',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
      }}
    >
      {src ? <img src={src} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain' }} /> : <PictureOutlined style={{ color: '#98A2B3' }} />}
    </div>
  )
}

export function CatalogTree({ storeId }: { storeId: string }) {
  const [text, setText] = useState('')
  const q = useDebounced(text.trim(), 350)
  const { select, setLines, deleteLine } = useStartApi(storeId)
  const [expanded, setExpanded] = useState<string[]>([])
  const [busy, setBusy] = useState<string | null>(null)

  const catalog = useQuery({
    queryKey: ['/store/start/catalog', { store_id: storeId, q }],
    queryFn: () => api.get<Catalog>('/store/start/catalog', { store_id: storeId, q }),
    placeholderData: (prev) => prev,
  })

  // Товары грузим только у раскрытых брендов.
  const openBrands = expanded.filter((k) => k.startsWith('b:'))
  const itemQueries = useQueries({
    queries: openBrands.map((k) => {
      const [, catId, brandId] = k.split(':')
      const params = { store_id: storeId, category_id: catId, brand_id: brandId, q, limit: ITEMS_LIMIT }
      return {
        queryKey: ['/store/start/catalog/items', params],
        queryFn: () => api.get<List<CatalogItem>>('/store/start/catalog/items', params).then((r) => r.items ?? []),
        placeholderData: (prev: CatalogItem[] | undefined) => prev,
      }
    }),
  })
  const items: Record<string, CatalogItem[]> = {}
  openBrands.forEach((k, i) => {
    const d = itemQueries[i]?.data
    if (d) items[k] = d
  })

  const { roots, allCats } = useMemo(() => {
    const byKey = new Map<string, Node>()
    const roots: Node[] = []
    const allCats: string[] = []
    for (const g of catalog.data?.groups ?? []) {
      let parent: Node | undefined
      g.category_ids.forEach((id, i) => {
        const key = `c:${id}`
        let n = byKey.get(key)
        if (!n) {
          n = { key, kind: 'cat', name: g.category_names[i], catId: id, count: 0, selected: 0, children: [] }
          byKey.set(key, n)
          allCats.push(key)
          if (parent) parent.children!.push(n)
          else roots.push(n)
        }
        n.count += g.count
        n.selected += g.selected
        parent = n
      })
      const leaf = g.category_ids[g.category_ids.length - 1]
      parent!.children!.push({
        key: brandKey(leaf, g.brand_id),
        kind: 'brand',
        name: g.brand_name,
        catId: leaf,
        brandId: g.brand_id ?? 'none',
        count: g.count,
        selected: g.selected,
        children: [],
      })
    }
    return { roots, allCats }
  }, [catalog.data])

  // Товары раскрытых брендов — детьми узлов.
  const withItems = (nodes: Node[]): Node[] =>
    nodes.map((n) => {
      if (n.kind === 'cat') return { ...n, children: withItems(n.children ?? []) }
      if (n.kind !== 'brand') return n
      const list = items[n.key as string]
      const children: Node[] = list
        ? list.map((it) => ({
            key: `p:${it.product_id}`,
            kind: 'product',
            name: it.name,
            productId: it.product_id,
            item: it,
            count: 1,
            selected: it.selected ? 1 : 0,
            isLeaf: true,
          }))
        : [{ key: `${n.key}:loading`, kind: 'loading', name: '', count: 0, selected: 0, isLeaf: true, checkable: false }]
      if (list && n.count > list.length)
        children.push({ key: `${n.key}:more`, kind: 'more', name: '', count: n.count - list.length, selected: 0, isLeaf: true, checkable: false })
      return { ...n, children }
    })
  const tree = withItems(roots)

  const checked: string[] = []
  const half: string[] = []
  const walk = (nodes: Node[]) =>
    nodes.forEach((n) => {
      if (n.count > 0 && n.selected === n.count) checked.push(n.key as string)
      else if (n.selected > 0) half.push(n.key as string)
      if (n.children) walk(n.children)
    })
  walk(tree)

  const toggle = async (n: Node) => {
    const on = !(n.count > 0 && n.selected === n.count)
    setBusy(n.key as string)
    try {
      if (n.kind === 'product' && n.productId) {
        if (on) await setLines([{ product_id: n.productId, qty: 1, source: 'catalog' }])
        else await deleteLine(n.productId)
      } else if (n.kind === 'brand') {
        await select({ category_id: n.catId, brand_id: n.brandId, exact: true, q: q || undefined, selected: on })
      } else if (n.kind === 'cat') {
        await select({ category_id: n.catId, q: q || undefined, selected: on })
      }
    } catch {
      // ошибка уже показана
    } finally {
      setBusy(null)
    }
  }

  const title = (n: Node): ReactNode => {
    if (n.kind === 'loading') return <Spin size="small" />
    if (n.kind === 'more')
      return (
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {tr(
            `Ещё ${n.count} ${plural(n.count, 'товар', 'товара', 'товаров')} — найдите их поиском`,
            `Yana ${n.count} ta mahsulot — ularni qidiruv orqali toping`,
          )}
        </Typography.Text>
      )
    if (n.kind === 'product' && n.item)
      return (
        <Flex align="center" justify="space-between" gap={8} style={{ width: '100%', minWidth: 0 }}>
          <Flex align="center" gap={10} style={{ minWidth: 0 }}>
            <Thumb src={n.item.image} size={28} />
            <Typography.Text ellipsis style={{ fontSize: 13 }}>
              {n.name}
            </Typography.Text>
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12, flex: 'none' }}>
            {busy === n.key ? <Spin size="small" /> : money(n.item.current_price)}
          </Typography.Text>
        </Flex>
      )
    return (
      <Flex align="center" justify="space-between" gap={8} style={{ width: '100%', minWidth: 0 }}>
        <Typography.Text strong={n.kind === 'cat'} ellipsis>
          {n.name}
        </Typography.Text>
        <Typography.Text type="secondary" style={{ fontSize: 12, flex: 'none' }}>
          {busy === n.key ? <Spin size="small" /> : tr(`${n.selected} из ${n.count}`, `${n.selected} / ${n.count}`)}
        </Typography.Text>
      </Flex>
    )
  }

  const total = catalog.data?.total ?? 0
  return (
    <Card
      title={tr('Общий каталог', 'Umumiy katalog')}
      extra={
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {tr(`${total} ${plural(total, 'товар', 'товара', 'товаров')}`, `${total} ta mahsulot`)}
        </Typography.Text>
      }
      styles={{ body: { padding: '12px 8px 12px 12px' } }}
    >
      <Input
        allowClear
        prefix={<SearchOutlined style={{ color: '#98A2B3' }} />}
        placeholder={tr('Поиск по каталогу', 'Katalog boʻyicha qidirish')}
        value={text}
        onChange={(e) => {
          setText(e.target.value)
          // При поиске раскрываем категории — найденное сразу видно.
          if (e.target.value.trim()) setExpanded((x) => Array.from(new Set([...x, ...allCats])))
        }}
        style={{ marginBottom: 12, marginRight: 4, width: 'calc(100% - 4px)' }}
      />
      <LoadError error={catalog.error} retry={() => catalog.refetch()} />
      {catalog.isLoading ? (
        <Spin style={{ display: 'block', margin: '32px auto' }} />
      ) : tree.length === 0 ? (
        <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={q ? tr('Ничего не найдено', 'Hech narsa topilmadi') : tr('Каталог пуст', 'Katalog boʻsh')} />
      ) : (
        <ConfigProvider theme={{ token: { colorPrimary: '#E11D2A' } }}>
          <Tree<Node>
            className="sm-start-tree"
            checkable
            checkStrictly
            blockNode
            selectable={false}
            height={620}
            treeData={tree}
            expandedKeys={expanded}
            onExpand={(keys) => setExpanded(keys as string[])}
            checkedKeys={{ checked, halfChecked: half }}
            onCheck={(_, info) => {
              if (!busy) toggle(info.node as unknown as Node)
            }}
            titleRender={(n) => title(n as Node)}
          />
        </ConfigProvider>
      )}
    </Card>
  )
}
