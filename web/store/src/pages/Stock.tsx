// Остатки и история движения товара.
import { useEffect, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Alert, Button, Card, Input, Space, Statistic, Table, Typography } from 'antd'
import { HistoryOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, dateTime, money, qty, useItem, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore, ProductSelect, docTypeTitles, unitPrice } from '../ui'
import type { Movement, StockRow, StockSummary, Warehouse } from '../types'

/** Виды складских документов в истории движения. */
const stockDocTitles: Record<string, string> = {
  income: 'Приход',
  supplier_return: 'Возврат поставщику',
  transfer: 'Перемещение',
  write_off: 'Списание',
  posting: 'Оприходование',
  inventory: 'Инвентаризация',
}

export function StockPage() {
  const { storeId, can } = useStore()
  const nav = useNavigate()
  const [warehouseId, setWarehouseId] = useState<string>()
  const [q, setQ] = useState('')
  useEffect(() => setWarehouseId(undefined), [storeId])
  const filters = { store_id: storeId, warehouse_id: warehouseId, q: q || undefined }
  const list = usePaged<StockRow>(storeId ? '/store/inventory/stock' : null, filters)
  // Итоги — по всем остаткам на сервере, не по странице.
  const summary = useItem<StockSummary>(storeId ? '/store/inventory/stock/summary' : null, filters)
  // Себестоимость сервер отдаёт только с этими правами.
  const seesCost = can('inventory.manage') || can('reports.view')

  return (
    <NeedStore>
      <PageTitle title="Остатки">
        <RemoteSelect<Warehouse>
          path="/store/warehouses"
          params={{ store_id: storeId }}
          value={warehouseId}
          onChange={setWarehouseId}
          allowClear
          placeholder="Все склады магазина"
        />
        <Input.Search placeholder="Товар или штрихкод" allowClear onSearch={setQ} style={{ width: 240 }} />
      </PageTitle>
      <LoadError error={summary.error} retry={() => summary.refetch()} />
      <Card style={{ marginBottom: 16 }} loading={summary.isLoading}>
        <Space size={48} wrap>
          <Statistic title="Позиций" value={summary.data?.positions ?? 0} />
          <Statistic title="Товаров" value={summary.data?.products ?? 0} />
          {seesCost && <Statistic title="Себестоимость остатков, сум" value={money(summary.data?.cost_value)} />}
        </Space>
      </Card>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<StockRow>
          rowKey={(r) => r.warehouse_id + r.product_id}
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          columns={[
            { title: 'Товар', dataIndex: 'product_name' },
            { title: 'Склад', dataIndex: 'warehouse_name' },
            {
              title: 'Остаток',
              dataIndex: 'qty',
              align: 'right',
              render: (v, r) => <Typography.Text type={Number(v) <= 0 ? 'danger' : undefined}>{qty(v, r.unit_short)}</Typography.Text>,
            },
            ...(seesCost
              ? [
                  { title: 'Ср. себестоимость', dataIndex: 'avg_cost', align: 'right' as const, render: (v: string) => money(v) },
                  { title: 'Ср. себест., $', dataIndex: 'avg_cost_usd', align: 'right' as const, render: (v: string) => unitPrice(v) },
                  { title: 'Сумма', dataIndex: 'total_cost', align: 'right' as const, render: (v: string) => money(v) },
                ]
              : []),
            {
              key: 'h',
              width: 50,
              render: (_, r) => (
                <Button
                  size="small"
                  icon={<HistoryOutlined />}
                  title="История движения"
                  onClick={() =>
                    nav(`/stock/movements?warehouse_id=${r.warehouse_id}&product_id=${r.product_id}&name=${encodeURIComponent(r.product_name)}`)
                  }
                />
              ),
            },
          ]}
        />
      </Card>
    </NeedStore>
  )
}

export function MovementsPage() {
  const { storeId, store, can } = useStore()
  const [sp, setSp] = useSearchParams()
  const [warehouseId, setWarehouseId] = useState<string | undefined>(sp.get('warehouse_id') ?? undefined)
  const [productId, setProductId] = useState<string | undefined>(sp.get('product_id') ?? undefined)
  const [productName, setProductName] = useState(sp.get('name') ?? '')
  const seesCost = can('inventory.manage') || can('reports.view')

  // Сменили магазин — склад прежнего магазина больше не подходит.
  const prevStore = useRef(storeId)
  useEffect(() => {
    if (prevStore.current && prevStore.current !== storeId) setWarehouseId(undefined)
    prevStore.current = storeId
  }, [storeId])

  useEffect(() => {
    if (!warehouseId && store?.default_warehouse_id) setWarehouseId(store.default_warehouse_id)
  }, [store, warehouseId])

  useEffect(() => {
    const p: Record<string, string> = {}
    if (warehouseId) p.warehouse_id = warehouseId
    if (productId) p.product_id = productId
    if (productName) p.name = productName
    setSp(p, { replace: true })
  }, [warehouseId, productId, productName, setSp])

  const ready = !!warehouseId && !!productId
  // Остаток после операции (balance_after) считает сервер — верен на любой странице.
  const list = usePaged<Movement>(ready ? '/store/inventory/movements' : null, {
    warehouse_id: warehouseId,
    product_id: productId,
  })

  return (
    <NeedStore>
      <PageTitle title="История движения">
        <RemoteSelect<Warehouse>
          path="/store/warehouses"
          params={{ store_id: storeId }}
          value={warehouseId}
          onChange={setWarehouseId}
          placeholder="Склад"
        />
        <div style={{ width: 280 }}>
          <ProductSelect
            value={productId}
            label={productName}
            onChange={(id, p) => {
              setProductId(id)
              setProductName(p?.name ?? '')
            }}
          />
        </div>
      </PageTitle>
      {!ready && <Alert type="info" showIcon message="Выберите склад и товар" />}
      <LoadError error={list.error} retry={() => list.refetch()} />
      {ready && (
        <Card styles={{ body: { padding: 0 } }}>
          <Table<Movement>
            rowKey={(r) => r.doc_id + r.created_at + r.qty + (r.balance_after ?? '')}
            loading={list.isLoading || list.isFetching}
            dataSource={list.items}
            scroll={{ x: true }}
            pagination={list.pagination}
            columns={[
              { title: 'Дата', dataIndex: 'created_at', render: dateTime },
              {
                title: 'Документ',
                dataIndex: 'doc_type',
                render: (v: string, r) => (
                  <>
                    {(v === 'stock_document' && stockDocTitles[r.doc_kind]) || docTypeTitles[v] || v}
                    {r.doc_number !== null && ` № ${r.doc_number}`}
                  </>
                ),
              },
              {
                title: 'Количество',
                dataIndex: 'qty',
                align: 'right',
                render: (v: string) => (
                  <Typography.Text type={Number(v) < 0 ? 'danger' : 'success'}>{(Number(v) > 0 ? '+' : '') + qty(v)}</Typography.Text>
                ),
              },
              ...(seesCost
                ? [{ title: 'Себестоимость', dataIndex: 'unit_cost', align: 'right' as const, render: (v: string) => unitPrice(v) }]
                : []),
              { title: 'Остаток после', dataIndex: 'balance_after', align: 'right', render: (v: string | null) => qty(v) },
            ]}
          />
        </Card>
      )}
    </NeedStore>
  )
}
