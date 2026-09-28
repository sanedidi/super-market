// Остатки и история движения товара.
import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Alert, Button, Card, Input, Space, Statistic, Table, Typography } from 'antd'
import { HistoryOutlined } from '@ant-design/icons'
import { PageTitle, RemoteSelect, dateTime, errorText, money, qty, useList } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore, ProductSelect, docTypeTitles, sum } from '../ui'
import type { Movement, StockRow, Warehouse } from '../types'

export function StockPage() {
  const { storeId } = useStore()
  const nav = useNavigate()
  const [warehouseId, setWarehouseId] = useState<string>()
  const [q, setQ] = useState('')
  const { data, isLoading, error } = useList<StockRow>('/store/inventory/stock', {
    store_id: storeId,
    warehouse_id: warehouseId,
    q,
    limit: 200,
  })
  const total = sum((data ?? []).map((r) => r.total_cost))

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
      {error && <Alert type="error" showIcon message={errorText(error)} style={{ marginBottom: 16 }} />}
      <Card style={{ marginBottom: 16 }}>
        <Space size={48} wrap>
          <Statistic title="Позиций" value={data?.length ?? 0} />
          <Statistic title="Себестоимость остатков, сум" value={money(total)} />
        </Space>
      </Card>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<StockRow>
          rowKey={(r) => r.warehouse_id + r.product_id}
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          pagination={{ pageSize: 50, hideOnSinglePage: true }}
          columns={[
            { title: 'Товар', dataIndex: 'product_name', sorter: (a, b) => a.product_name.localeCompare(b.product_name) },
            { title: 'Склад', dataIndex: 'warehouse_name' },
            {
              title: 'Остаток',
              dataIndex: 'qty',
              align: 'right',
              sorter: (a, b) => Number(a.qty) - Number(b.qty),
              render: (v, r) => <Typography.Text type={Number(v) <= 0 ? 'danger' : undefined}>{qty(v, r.unit_short)}</Typography.Text>,
            },
            { title: 'Ср. себестоимость', dataIndex: 'avg_cost', align: 'right', render: (v) => money(v) },
            { title: 'Ср. себест., $', dataIndex: 'avg_cost_usd', align: 'right', render: (v) => money(v) },
            {
              title: 'Сумма',
              dataIndex: 'total_cost',
              align: 'right',
              sorter: (a, b) => Number(a.total_cost) - Number(b.total_cost),
              render: (v) => money(v),
            },
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
  const { storeId, store } = useStore()
  const [sp, setSp] = useSearchParams()
  const [warehouseId, setWarehouseId] = useState<string | undefined>(sp.get('warehouse_id') ?? undefined)
  const [productId, setProductId] = useState<string | undefined>(sp.get('product_id') ?? undefined)
  const [productName, setProductName] = useState(sp.get('name') ?? '')

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
  const { data, isLoading, error } = useList<Movement>(ready ? '/store/inventory/movements' : null, {
    warehouse_id: warehouseId,
    product_id: productId,
    limit: 200,
  })

  // Остаток после каждой операции: список от новых к старым.
  const rows = data ?? []
  const totalNow = sum(rows.map((m) => m.qty))
  let running = totalNow
  const withBalance = rows.map((m) => {
    const after = running
    running -= Number(m.qty)
    return { ...m, after }
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
      {error && <Alert type="error" showIcon message={errorText(error)} />}
      {ready && (
        <Card styles={{ body: { padding: 0 } }}>
          <Table
            rowKey={(r) => r.doc_id + r.created_at + r.qty + r.unit_cost}
            loading={isLoading}
            dataSource={withBalance}
            scroll={{ x: true }}
            pagination={{ pageSize: 50, hideOnSinglePage: true }}
            columns={[
              { title: 'Дата', dataIndex: 'created_at', render: dateTime },
              { title: 'Документ', dataIndex: 'doc_type', render: (v: string) => docTypeTitles[v] ?? v },
              {
                title: 'Количество',
                dataIndex: 'qty',
                align: 'right',
                render: (v: string) => (
                  <Typography.Text type={Number(v) < 0 ? 'danger' : 'success'}>{(Number(v) > 0 ? '+' : '') + qty(v)}</Typography.Text>
                ),
              },
              { title: 'Себестоимость', dataIndex: 'unit_cost', align: 'right', render: (v: string) => money(v) },
              // Остаток после операции считаем, только если видна вся история.
              ...(rows.length < 200 ? [{ title: 'Остаток после', dataIndex: 'after', align: 'right' as const, render: (v: number) => qty(v) }] : []),
            ]}
          />
        </Card>
      )}
    </NeedStore>
  )
}
