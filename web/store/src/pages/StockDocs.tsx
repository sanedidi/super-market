// Складские документы: один список и один редактор на все виды (type).
import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Alert, App, Button, Card, Col, Form, Image, Input, Popconfirm, Row, Segmented, Select, Space, Table, Typography } from 'antd'
import { CheckOutlined, CloseOutlined, DeleteOutlined, PlusOutlined, SaveOutlined } from '@ant-design/icons'
import {
  DeleteButton,
  LoadError,
  PageTitle,
  RemoteSelect,
  StatusTag,
  api,
  dateTime,
  errorText,
  money,
  qty as fmtQty,
  tr,
  useAction,
  useItem,
  useList,
  usePaged,
} from '@sm/shared'
import { useStore } from '../ctx'
import { CounterpartySelect, NeedStore, Num, ProductSelect, trimNum, unitPrice } from '../ui'
import type { StockDocType, StockDocument, Warehouse } from '../types'

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
    title: tr('Приход товара', 'Mahsulot kirimi'),
    one: tr('Приход', 'Kirim'),
    counterparty: true,
    currency: true,
    price: 'required',
    priceTitle: tr('Цена закупки', 'Xarid narxi'),
    hint: tr('Проведение создаёт партии товара и увеличивает долг поставщику.', 'Oʻtkazish mahsulot partiyalarini yaratadi va yetkazib beruvchiga qarzni oshiradi.'),
  },
  supplier_return: {
    title: tr('Возврат поставщику', 'Yetkazib beruvchiga qaytarish'),
    one: tr('Возврат поставщику', 'Yetkazib beruvchiga qaytarish'),
    counterparty: true,
    price: 'optional',
    priceTitle: tr('Цена возврата', 'Qaytarish narxi'),
    hint: tr(
      'Товар списывается по FIFO, долг поставщику уменьшается. Без цены — по себестоимости.',
      'Mahsulot FIFO boʻyicha hisobdan chiqariladi, yetkazib beruvchiga qarz kamayadi. Narxsiz — tannarx boʻyicha.',
    ),
  },
  transfer: {
    title: tr('Перемещение между складами', 'Omborlar oʻrtasida koʻchirish'),
    one: tr('Перемещение', 'Koʻchirish'),
    toWarehouse: true,
    hint: tr('Партии переезжают на другой склад со своей себестоимостью.', 'Partiyalar oʻz tannarxi bilan boshqa omborga koʻchiriladi.'),
  },
  inventory: {
    title: tr('Инвентаризация', 'Inventarizatsiya'),
    one: tr('Инвентаризация', 'Inventarizatsiya'),
    qtyTitle: tr('Факт', 'Haqiqiy'),
    hint: tr(
      'Укажите фактическое количество. Излишек приходуется по последней себестоимости, недостача списывается FIFO.',
      'Haqiqiy miqdorni kiriting. Ortiqcha oxirgi tannarx boʻyicha kirim qilinadi, kamomad FIFO boʻyicha hisobdan chiqariladi.',
    ),
  },
  write_off: {
    title: tr('Списание', 'Hisobdan chiqarish'),
    one: tr('Списание', 'Hisobdan chiqarish'),
    reason: true,
    hint: tr('Товар списывается по FIFO.', 'Mahsulot FIFO boʻyicha hisobdan chiqariladi.'),
  },
  posting: {
    title: tr('Оприходование', 'Kirimga olish'),
    one: tr('Оприходование', 'Kirimga olish'),
    price: 'required',
    priceTitle: tr('Себестоимость', 'Tannarx'),
    hint: tr('Начальные остатки и находки: товар приходуется по указанной себестоимости.', 'Boshlangʻich qoldiqlar va topilmalar: mahsulot koʻrsatilgan tannarx boʻyicha kirim qilinadi.'),
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
              {tr('Создать', 'Yaratish')}
            </Button>
          )
        }
      >
        <Segmented
          value={status}
          onChange={(v) => setStatus(String(v))}
          options={[
            { value: '', label: tr('Все', 'Hammasi') },
            { value: 'draft', label: tr('Черновики', 'Qoralamalar') },
            { value: 'posted', label: tr('Проведённые', 'Oʻtkazilganlar') },
          ]}
        />
        <RemoteSelect<Warehouse>
          path="/store/warehouses"
          params={{ store_id: storeId }}
          value={warehouseId}
          onChange={setWarehouseId}
          allowClear
          placeholder={tr('Все склады', 'Barcha omborlar')}
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
            { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
            { title: tr('Склад', 'Ombor'), dataIndex: 'warehouse_name' },
            ...(spec.toWarehouse ? [{ title: tr('Куда', 'Qayerga'), dataIndex: 'to_warehouse_name' }] : []),
            ...(spec.counterparty ? [{ title: tr('Контрагент', 'Kontragent'), dataIndex: 'counterparty_name' }] : []),
            ...(spec.reason ? [{ title: tr('Причина', 'Sabab'), dataIndex: 'reason' }] : []),
            { title: tr('Строк', 'Qatorlar'), dataIndex: 'items_count', align: 'right' as const },
            ...(spec.price
              ? [
                  {
                    title: tr('Сумма', 'Summa'),
                    dataIndex: 'total',
                    align: 'right' as const,
                    render: (v: string, r: StockDocument) => money(v, r.currency === 'USD' ? '$' : ''),
                  },
                ]
              : []),
            { title: tr('Статус', 'Holat'), dataIndex: 'status', render: (s: string) => <StatusTag status={s} /> },
            { title: tr('Автор', 'Muallif'), dataIndex: 'created_by' },
            {
              key: 'del',
              align: 'right' as const,
              render: (_: unknown, r: StockDocument) =>
                r.status === 'draft' && <DeleteButton path={`/store/inventory/documents/${r.id}`} name={tr(`Черновик № ${r.number}`, `Qoralama № ${r.number}`)} />,
            },
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
  const storeName = (sid: string) => (sid === store?.id ? '' : tr(' (другой магазин)', ' (boshqa doʻkon)'))

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
    if (!items.length) throw new Error(tr('Добавьте хотя бы один товар', 'Kamida bitta mahsulot qoʻshing'))
    for (const l of items) {
      if (!l.qty || Number(l.qty) < 0 || (type !== 'inventory' && Number(l.qty) === 0))
        throw new Error(tr(`Укажите количество: ${l.product_name}`, `Miqdorni kiriting: ${l.product_name}`))
      if (spec.price === 'required' && (l.price === null || l.price === '')) throw new Error(tr(`Укажите цену: ${l.product_name}`, `Narxni kiriting: ${l.product_name}`))
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
        message.success(tr('Документ проведён', 'Hujjat oʻtkazildi'))
      } else {
        message.success(tr('Черновик сохранён', 'Qoralama saqlandi'))
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

  const remove = useAction(() => api.del(`/store/inventory/documents/${id}`), { success: tr('Черновик удалён', 'Qoralama oʻchirildi') })

  if (!isNew && doc.error) return <Alert type="error" showIcon message={errorText(doc.error)} />

  const priceSuffix = currency === 'USD' ? '$' : ''
  const productOf = (pid: string) => lines.find((l) => l.product_id === pid)

  return (
    <>
      <PageTitle
        title={
          isNew ? (
            `${spec.one}: ${tr('новый документ', 'yangi hujjat')}`
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
                  <Popconfirm title={tr('Удалить черновик?', 'Qoralama oʻchirilsinmi?')} onConfirm={() => remove.mutate(undefined, { onSuccess: () => nav(docPaths[type]) })}>
                    <Button danger loading={remove.isPending}>
                      {tr('Удалить черновик', 'Qoralamani oʻchirish')}
                    </Button>
                  </Popconfirm>
                )}
                <Button type="primary" icon={<SaveOutlined />} loading={busy} onClick={() => run(false)}>
                  {tr('Сохранить черновик', 'Qoralamani saqlash')}
                </Button>
                <Popconfirm
                  title={tr('Провести документ? После проведения изменить его нельзя.', 'Hujjat oʻtkazilsinmi? Oʻtkazilgandan keyin uni oʻzgartirib boʻlmaydi.')}
                  onConfirm={() => run(true)}>
                  <Button className="sm-btn-blue" icon={<CheckOutlined />} loading={busy}>
                    {tr('Провести', 'Oʻtkazish')}
                  </Button>
                </Popconfirm>
              </>
            )}
          </Space>
        }
      >
        <Button type="text" icon={<CloseOutlined />} onClick={() => nav(docPaths[type])} title={tr('Закрыть', 'Yopish')} aria-label={tr('Закрыть', 'Yopish')} />
      </PageTitle>
      {spec.hint && !readOnly && <Alert type="info" showIcon message={spec.hint} style={{ marginBottom: 16 }} />}
      <Card style={{ marginBottom: 16 }} loading={!isNew && doc.isLoading}>
        <Form form={form} layout="vertical" disabled={readOnly}>
          <Row gutter={16}>
            <Col xs={24} md={12} lg={8}>
              <Form.Item name="warehouse_id" label={spec.toWarehouse ? tr('Со склада', 'Qaysi ombordan') : tr('Склад', 'Ombor')}
                rules={[{ required: true, message: tr('Выберите склад', 'Omborni tanlang') }]}
              >
                <Select
                  disabled={!isNew || readOnly}
                  placeholder={tr('Склад', 'Ombor')}
                  options={(isNew ? storeWarehouses : (allWarehouses.data ?? [])).map((w) => ({ value: w.id, label: w.name }))}
                />
              </Form.Item>
            </Col>
            {spec.toWarehouse && (
              <Col xs={24} md={12} lg={8}>
                <Form.Item name="to_warehouse_id" label={tr('На склад', 'Qaysi omborga')} rules={[{ required: true, message: tr('Выберите склад', 'Omborni tanlang') }]}>
                  <Select
                    disabled={!isNew || readOnly}
                    showSearch
                    optionFilterProp="label"
                    placeholder={tr('Склад любого магазина сети', 'Tarmoqdagi istalgan doʻkon ombori')}
                    options={(allWarehouses.data ?? [])
                      .filter((w) => w.id !== warehouseId && (w.is_active || !isNew))
                      .map((w) => ({ value: w.id, label: w.name + storeName(w.store_id) }))}
                  />
                </Form.Item>
              </Col>
            )}
            {spec.counterparty && (
              <Col xs={24} md={12} lg={8}>
                <Form.Item name="counterparty_id" label={tr('Поставщик', 'Yetkazib beruvchi')} rules={[{ required: true, message: tr('Выберите поставщика', 'Yetkazib beruvchini tanlang') }]}>
                  <CounterpartySelect
                    filter={(c) => c.is_active || c.id === d?.counterparty_id}
                    selectedLabel={d?.counterparty_name ?? undefined}
                    placeholder={tr('Поиск по названию или телефону', 'Nomi yoki telefon boʻyicha qidirish')}
                  />
                </Form.Item>
              </Col>
            )}
            {spec.currency && (
              <Col xs={12} md={6} lg={4}>
                <Form.Item name="currency" label={tr('Валюта', 'Valyuta')} rules={[{ required: true }]}>
                  <Select
                    options={[
                      { value: 'UZS', label: tr('UZS (сум)', 'UZS (soʻm)') },
                      { value: 'USD', label: 'USD' },
                    ]}
                  />
                </Form.Item>
              </Col>
            )}
            {spec.reason && (
              <Col xs={24} md={12} lg={8}>
                <Form.Item name="reason" label={tr('Причина', 'Sabab')} rules={[{ required: true, message: tr('Укажите причину', 'Sababni kiriting') }]}>
                  <Input placeholder={tr('Порча, истёк срок…', 'Buzilgan, muddati oʻtgan…')} />
                </Form.Item>
              </Col>
            )}
            <Col xs={24} lg={spec.toWarehouse || spec.reason ? 8 : 12}>
              <Form.Item name="note" label={tr('Примечание', 'Izoh')}>
                <Input />
              </Form.Item>
            </Col>
          </Row>
          {d && (
            <Typography.Text type="secondary">
              {tr('Создан', 'Yaratilgan')} {dateTime(d.created_at)} · {d.created_by}
              {d.posted_at && ` · ${tr('проведён', 'oʻtkazilgan')} ${dateTime(d.posted_at)}`}
              {d.rate && ` · ${tr('курс', 'kurs')} ${money(d.rate)}`}
            </Typography.Text>
          )}
          {d && (d.photos?.length ?? 0) > 0 && (
            <div style={{ marginTop: 12 }}>
              <Image.PreviewGroup>
                <Space wrap>
                  {d.photos!.map((u) => (
                    <Image key={u} src={u} width={96} height={96} style={{ objectFit: 'cover', borderRadius: 8 }} />
                  ))}
                </Space>
              </Image.PreviewGroup>
            </div>
          )}
        </Form>
      </Card>
      <Card title={tr('Товары', 'Mahsulotlar')} styles={{ body: { padding: 0 } }}>
        <Table<Line>
          rowKey="key"
          dataSource={lines}
          pagination={false}
          scroll={{ x: true }}
          columns={[
            { title: '№', key: 'n', width: 50, render: (_, __, i) => i + 1 },
            {
              title: tr('Товар', 'Mahsulot'),
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
                        message.warning(tr('Этот товар уже есть в документе', 'Bu mahsulot hujjatda allaqachon bor'))
                        return
                      }
                      update(l.key, { product_id: pid, product_name: p?.name ?? '', unit_short: p?.unit_short ?? '' })
                    }}
                  />
                ),
            },
            ...(type === 'inventory' && readOnly
              ? [{ title: tr('Учёт', 'Hisobda'), key: 'exp', align: 'right' as const, render: (_: unknown, l: Line) => fmtQty(l.expected_qty) }]
              : []),
            {
              title: spec.qtyTitle ?? tr('Количество', 'Miqdor'),
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
                    title: tr('Разница', 'Farq'),
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
                        <Num value={l.price} onChange={(v) => update(l.key, { price: v })} placeholder={spec.price === 'optional' ? tr('себестоимость', 'tannarx') : ''} />
                      ),
                  },
                  {
                    title: tr('Сумма', 'Summa'),
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
                  <Typography.Text strong>{tr('Итого', 'Jami')}</Typography.Text>
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
