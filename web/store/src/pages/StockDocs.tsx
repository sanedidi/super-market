// Складские документы: один список и один редактор на все виды (type).
import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Alert, App, Button, Card, Col, Form, Input, Popconfirm, Row, Segmented, Select, Space, Table, Typography } from 'antd'
import { CheckOutlined, CloseOutlined, DeleteOutlined, PlusOutlined, SaveOutlined } from '@ant-design/icons'
import {
  LoadError,
  PageTitle,
  RemoteSelect,
  StatusTag,
  api,
  dateTime,
  errorText,
  money,
  qty as fmtQty,
  useAction,
  useItem,
  useList,
  usePaged,
} from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore, Num, ProductSelect, trimNum, unitPrice } from '../ui'
import type { Counterparty, StockDocType, StockDocument, Warehouse } from '../types'

export const docPaths: Record<StockDocType, string> = {
  income: '/purchases/income',
  supplier_return: '/purchases/supplier-return',
  transfer: '/stock/transfer',
  inventory: '/stock/inventory',
  write_off: '/stock/write-off',
  posting: '/stock/posting',
}

interface TypeSpec {
  title: string
  one: string
  counterparty?: boolean
  currency?: boolean
  toWarehouse?: boolean
  reason?: boolean
  /** Цена в строках: required — обязательна, optional — можно не указывать. */
  price?: 'required' | 'optional'
  priceTitle?: string
  qtyTitle?: string
  hint?: string
}

const specs: Record<StockDocType, TypeSpec> = {
  income: {
    title: 'Приход товара',
    one: 'Приход',
    counterparty: true,
    currency: true,
    price: 'required',
    priceTitle: 'Цена закупки',
    hint: 'Проведение создаёт партии товара и увеличивает долг поставщику.',
  },
  supplier_return: {
    title: 'Возврат поставщику',
    one: 'Возврат поставщику',
    counterparty: true,
    price: 'optional',
    priceTitle: 'Цена возврата',
    hint: 'Товар списывается по FIFO, долг поставщику уменьшается. Без цены — по себестоимости.',
  },
  transfer: {
    title: 'Перемещение между складами',
    one: 'Перемещение',
    toWarehouse: true,
    hint: 'Партии переезжают на другой склад со своей себестоимостью.',
  },
  inventory: {
    title: 'Инвентаризация',
    one: 'Инвентаризация',
    qtyTitle: 'Факт',
    hint: 'Укажите фактическое количество. Излишек приходуется по последней себестоимости, недостача списывается FIFO.',
  },
  write_off: { title: 'Списание', one: 'Списание', reason: true, hint: 'Товар списывается по FIFO.' },
  posting: {
    title: 'Оприходование',
    one: 'Оприходование',
    price: 'required',
    priceTitle: 'Себестоимость',
    hint: 'Начальные остатки и находки: товар приходуется по указанной себестоимости.',
  },
}

// ------------------------------------------------------------------ список

export function StockDocsPage({ type }: { type: StockDocType }) {
  const spec = specs[type]
  const nav = useNavigate()
  const { storeId, can } = useStore()
  const [status, setStatus] = useState<string>('')
  const [warehouseId, setWarehouseId] = useState<string>()
  // Документы выбранного магазина; перемещения — и входящие на его склады (фильтрует сервер).
  const list = usePaged<StockDocument>(storeId ? '/store/inventory/documents' : null, {
    type,
    status,
    store_id: storeId,
    warehouse_id: warehouseId,
  })
  useEffect(() => setWarehouseId(undefined), [storeId])

  return (
    <NeedStore>
      <PageTitle
        title={spec.title}
        extra={
          can('inventory.manage') && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => nav(`${docPaths[type]}/new`)}>
              Создать
            </Button>
          )
        }
      >
        <Segmented
          value={status}
          onChange={(v) => setStatus(String(v))}
          options={[
            { value: '', label: 'Все' },
            { value: 'draft', label: 'Черновики' },
            { value: 'posted', label: 'Проведённые' },
          ]}
        />
        <RemoteSelect<Warehouse>
          path="/store/warehouses"
          params={{ store_id: storeId }}
          value={warehouseId}
          onChange={setWarehouseId}
          allowClear
          placeholder="Все склады"
        />
      </PageTitle>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<StockDocument>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          onRow={(r) => ({ onClick: () => nav(`${docPaths[type]}/${r.id}`), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: 'Дата', dataIndex: 'created_at', render: dateTime },
            { title: 'Склад', dataIndex: 'warehouse_name' },
            ...(spec.toWarehouse ? [{ title: 'Куда', dataIndex: 'to_warehouse_name' }] : []),
            ...(spec.counterparty ? [{ title: 'Контрагент', dataIndex: 'counterparty_name' }] : []),
            ...(spec.reason ? [{ title: 'Причина', dataIndex: 'reason' }] : []),
            { title: 'Строк', dataIndex: 'items_count', align: 'right' as const },
            ...(spec.price
              ? [
                  {
                    title: 'Сумма',
                    dataIndex: 'total',
                    align: 'right' as const,
                    render: (v: string, r: StockDocument) => money(v, r.currency === 'USD' ? '$' : ''),
                  },
                ]
              : []),
            { title: 'Статус', dataIndex: 'status', render: (s: string) => <StatusTag status={s} /> },
            { title: 'Автор', dataIndex: 'created_by' },
          ]}
        />
      </Card>
    </NeedStore>
  )
}

// ---------------------------------------------------------------- редактор

interface Line {
  key: string
  product_id: string
  product_name: string
  unit_short: string
  qty: string | null
  price: string | null
  expected_qty?: string | null
}

let seq = 0
const newLine = (): Line => ({ key: `n${++seq}`, product_id: '', product_name: '', unit_short: '', qty: null, price: null })

interface Header {
  warehouse_id?: string
  to_warehouse_id?: string
  counterparty_id?: string
  currency?: string
  reason?: string
  note?: string
}

export function StockDocEditor({ type }: { type: StockDocType }) {
  const spec = specs[type]
  const { id = 'new' } = useParams()
  const isNew = id === 'new'
  const nav = useNavigate()
  const { message } = App.useApp()
  const { storeId, store, can } = useStore()
  const doc = useItem<StockDocument>(isNew ? null : `/store/inventory/documents/${id}`)
  const [form] = Form.useForm<Header>()
  const [lines, setLines] = useState<Line[]>([newLine()])
  const [busy, setBusy] = useState(false)
  const allWarehouses = useList<Warehouse>('/store/warehouses')

  const d = doc.data
  const readOnly = !can('inventory.manage') || (!!d && d.status !== 'draft')

  useEffect(() => {
    if (isNew) {
      form.setFieldsValue({ warehouse_id: store?.default_warehouse_id ?? undefined, currency: 'UZS' })
      return
    }
    if (!d) return
    form.setFieldsValue({
      warehouse_id: d.warehouse_id,
      to_warehouse_id: d.to_warehouse_id ?? undefined,
      counterparty_id: d.counterparty_id ?? undefined,
      currency: d.currency,
      reason: d.reason,
      note: d.note,
    })
    const ls = (d.items ?? []).map((i) => ({
      key: `l${i.line}`,
      product_id: i.product_id,
      product_name: i.product_name,
      unit_short: i.unit_short,
      qty: trimNum(i.qty, 3),
      price: trimNum(i.price, 4),
      expected_qty: i.expected_qty,
    }))
    setLines(ls.length || d.status !== 'draft' ? ls : [newLine()])
  }, [d, isNew, store, form])

  const warehouseId = Form.useWatch('warehouse_id', form)
  const currency = Form.useWatch('currency', form)
  const storeWarehouses = (allWarehouses.data ?? []).filter((w) => w.store_id === (d?.store_id ?? storeId) && w.is_active)
  const storeName = (sid: string) => (sid === store?.id ? '' : ' (другой магазин)')

  const total = useMemo(() => lines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(l.price) || 0), 0), [lines])

  const update = (key: string, patch: Partial<Line>) =>
    setLines((ls) => {
      const next = ls.map((l) => (l.key === key ? { ...l, ...patch } : l))
      // Пустая строка в конце — чтобы сразу добавлять следующий товар.
      if (next[next.length - 1]?.product_id) next.push(newLine())
      return next
    })

  const body = async () => {
    const h = await form.validateFields()
    const items = lines.filter((l) => l.product_id)
    if (!items.length) throw new Error('Добавьте хотя бы один товар')
    for (const l of items) {
      if (!l.qty || Number(l.qty) < 0 || (type !== 'inventory' && Number(l.qty) === 0))
        throw new Error(`Укажите количество: ${l.product_name}`)
      if (spec.price === 'required' && (l.price === null || l.price === '')) throw new Error(`Укажите цену: ${l.product_name}`)
    }
    return {
      type,
      ...h,
      note: h.note ?? '',
      reason: h.reason ?? '',
      items: items.map((l) => ({
        product_id: l.product_id,
        qty: trimNum(l.qty, 3),
        ...(spec.price && l.price !== null && l.price !== '' ? { price: trimNum(l.price, 4) } : {}),
      })),
    }
  }

  const saveDraft = async (): Promise<string | null> => {
    const b = await body()
    if (isNew) {
      const created = await api.post<StockDocument>('/store/inventory/documents', b)
      return created.id
    }
    const { counterparty_id, currency, reason, note, items } = b
    await api.patch(`/store/inventory/documents/${id}`, { counterparty_id, currency, reason, note, items })
    return id
  }

  const run = async (post: boolean) => {
    setBusy(true)
    let docId: string | null = null
    try {
      docId = await saveDraft()
      if (post && docId) {
        await api.post(`/store/inventory/documents/${docId}/post`)
        message.success('Документ проведён')
      } else {
        message.success('Черновик сохранён')
      }
      if (isNew && docId) nav(`${docPaths[type]}/${docId}`, { replace: true })
      else void doc.refetch()
    } catch (e) {
      // ошибки валидации формы antd показывает у полей
      if (!(e && typeof e === 'object' && 'errorFields' in e)) message.error(errorText(e))
      // черновик уже создан, но не проведён — открываем его, чтобы не создать второй
      if (isNew && docId) nav(`${docPaths[type]}/${docId}`, { replace: true })
    } finally {
      setBusy(false)
    }
  }

  const remove = useAction(() => api.del(`/store/inventory/documents/${id}`), { success: 'Черновик удалён' })

  if (!isNew && doc.error) return <Alert type="error" showIcon message={errorText(doc.error)} />

  const priceSuffix = currency === 'USD' ? '$' : ''
  const productOf = (pid: string) => lines.find((l) => l.product_id === pid)

  return (
    <>
      <PageTitle
        title={
          isNew ? (
            `${spec.one}: новый документ`
          ) : (
            <>
              {spec.one} № {d?.number ?? ''} {d && <StatusTag status={d.status} />}
            </>
          )
        }
        extra={
          <Space wrap>
            {!readOnly && (
              <>
                {!isNew && (
                  <Popconfirm title="Удалить черновик?" onConfirm={() => remove.mutate(undefined, { onSuccess: () => nav(docPaths[type]) })}>
                    <Button danger loading={remove.isPending}>
                      Удалить черновик
                    </Button>
                  </Popconfirm>
                )}
                <Button type="primary" icon={<SaveOutlined />} loading={busy} onClick={() => run(false)}>
                  Сохранить черновик
                </Button>
                <Popconfirm title="Провести документ? После проведения изменить его нельзя." onConfirm={() => run(true)}>
                  <Button className="sm-btn-blue" icon={<CheckOutlined />} loading={busy}>
                    Провести
                  </Button>
                </Popconfirm>
              </>
            )}
          </Space>
        }
      >
        <Button type="text" icon={<CloseOutlined />} onClick={() => nav(docPaths[type])} title="Закрыть" aria-label="Закрыть" />
      </PageTitle>
      {spec.hint && !readOnly && <Alert type="info" showIcon message={spec.hint} style={{ marginBottom: 16 }} />}
      <Card style={{ marginBottom: 16 }} loading={!isNew && doc.isLoading}>
        <Form form={form} layout="vertical" disabled={readOnly}>
          <Row gutter={16}>
            <Col xs={24} md={12} lg={8}>
              <Form.Item name="warehouse_id" label={spec.toWarehouse ? 'Со склада' : 'Склад'} rules={[{ required: true, message: 'Выберите склад' }]}>
                <Select
                  disabled={!isNew || readOnly}
                  placeholder="Склад"
                  options={(isNew ? storeWarehouses : (allWarehouses.data ?? [])).map((w) => ({ value: w.id, label: w.name }))}
                />
              </Form.Item>
            </Col>
            {spec.toWarehouse && (
              <Col xs={24} md={12} lg={8}>
                <Form.Item name="to_warehouse_id" label="На склад" rules={[{ required: true, message: 'Выберите склад' }]}>
                  <Select
                    disabled={!isNew || readOnly}
                    showSearch
                    optionFilterProp="label"
                    placeholder="Склад любого магазина сети"
                    options={(allWarehouses.data ?? [])
                      .filter((w) => w.id !== warehouseId && (w.is_active || !isNew))
                      .map((w) => ({ value: w.id, label: w.name + storeName(w.store_id) }))}
                  />
                </Form.Item>
              </Col>
            )}
            {spec.counterparty && (
              <Col xs={24} md={12} lg={8}>
                <Form.Item name="counterparty_id" label="Поставщик" rules={[{ required: true, message: 'Выберите поставщика' }]}>
                  <RemoteSelect<Counterparty>
                    path="/store/finance/counterparties"
                    search
                    filter={(c) => c.is_active || c.id === d?.counterparty_id}
                    selectedLabel={d?.counterparty_name ?? undefined}
                    placeholder="Поиск по названию или телефону"
                  />
                </Form.Item>
              </Col>
            )}
            {spec.currency && (
              <Col xs={12} md={6} lg={4}>
                <Form.Item name="currency" label="Валюта" rules={[{ required: true }]}>
                  <Select options={[{ value: 'UZS', label: 'UZS (сум)' }, { value: 'USD', label: 'USD' }]} />
                </Form.Item>
              </Col>
            )}
            {spec.reason && (
              <Col xs={24} md={12} lg={8}>
                <Form.Item name="reason" label="Причина" rules={[{ required: true, message: 'Укажите причину' }]}>
                  <Input placeholder="Порча, истёк срок…" />
                </Form.Item>
              </Col>
            )}
            <Col xs={24} lg={spec.toWarehouse || spec.reason ? 8 : 12}>
              <Form.Item name="note" label="Примечание">
                <Input />
              </Form.Item>
            </Col>
          </Row>
          {d && (
            <Typography.Text type="secondary">
              Создан {dateTime(d.created_at)} · {d.created_by}
              {d.posted_at && ` · проведён ${dateTime(d.posted_at)}`}
              {d.rate && ` · курс ${money(d.rate)}`}
            </Typography.Text>
          )}
        </Form>
      </Card>
      <Card title="Товары" styles={{ body: { padding: 0 } }}>
        <Table<Line>
          rowKey="key"
          dataSource={lines}
          pagination={false}
          scroll={{ x: true }}
          columns={[
            { title: '№', key: 'n', width: 50, render: (_, __, i) => i + 1 },
            {
              title: 'Товар',
              key: 'product',
              render: (_, l) =>
                readOnly ? (
                  l.product_name
                ) : (
                  <ProductSelect
                    value={l.product_id}
                    label={l.product_name}
                    style={{ minWidth: 260, width: '100%' }}
                    onChange={(pid, p) => {
                      if (productOf(pid) && productOf(pid)!.key !== l.key) {
                        message.warning('Этот товар уже есть в документе')
                        return
                      }
                      update(l.key, { product_id: pid, product_name: p?.name ?? '', unit_short: p?.unit_short ?? '' })
                    }}
                  />
                ),
            },
            ...(type === 'inventory' && readOnly
              ? [{ title: 'Учёт', key: 'exp', align: 'right' as const, render: (_: unknown, l: Line) => fmtQty(l.expected_qty) }]
              : []),
            {
              title: spec.qtyTitle ?? 'Количество',
              key: 'qty',
              width: 150,
              render: (_, l) =>
                readOnly ? (
                  fmtQty(l.qty, l.unit_short)
                ) : (
                  <Num value={l.qty} onChange={(v) => update(l.key, { qty: v })} suffix={l.unit_short || undefined} />
                ),
            },
            ...(type === 'inventory' && readOnly
              ? [
                  {
                    title: 'Разница',
                    key: 'diff',
                    align: 'right' as const,
                    render: (_: unknown, l: Line) => {
                      if (l.expected_qty === null || l.expected_qty === undefined) return '—'
                      const diff = Number(l.qty) - Number(l.expected_qty)
                      return <Typography.Text type={diff < 0 ? 'danger' : diff > 0 ? 'success' : undefined}>{fmtQty(diff)}</Typography.Text>
                    },
                  },
                ]
              : []),
            ...(spec.price
              ? [
                  {
                    title: spec.priceTitle,
                    key: 'price',
                    width: 170,
                    render: (_: unknown, l: Line) =>
                      readOnly ? (
                        unitPrice(l.price, priceSuffix)
                      ) : (
                        <Num value={l.price} onChange={(v) => update(l.key, { price: v })} placeholder={spec.price === 'optional' ? 'себестоимость' : ''} />
                      ),
                  },
                  {
                    title: 'Сумма',
                    key: 'sum',
                    align: 'right' as const,
                    render: (_: unknown, l: Line) => (l.price ? money((Number(l.qty) || 0) * Number(l.price), priceSuffix) : '—'),
                  },
                ]
              : []),
            ...(!readOnly
              ? [
                  {
                    key: 'del',
                    width: 50,
                    render: (_: unknown, l: Line) =>
                      l.product_id ? (
                        <Button type="text" danger icon={<DeleteOutlined />} onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} />
                      ) : null,
                  },
                ]
              : []),
          ]}
          summary={() =>
            spec.price ? (
              <Table.Summary.Row>
                <Table.Summary.Cell index={0} colSpan={4}>
                  <Typography.Text strong>Итого</Typography.Text>
                </Table.Summary.Cell>
                <Table.Summary.Cell index={1} align="right">
                  <Typography.Text strong>{money(readOnly && d ? d.total : total, priceSuffix)}</Typography.Text>
                </Table.Summary.Cell>
                {!readOnly && <Table.Summary.Cell index={2} />}
              </Table.Summary.Row>
            ) : undefined
          }
        />
      </Card>
    </>
  )
}
