// Установка цен: документы с новыми ценами по типу цены.
import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Alert, App, Button, Card, Col, Form, Input, Popconfirm, Row, Select, Space, Table, Typography } from 'antd'
import { DeleteOutlined, PlusOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, StatusTag, api, dateTime, errorText, money, useItem, useList, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { Num, ProductSelect, trimNum } from '../ui'
import type { PriceDocument, PriceType } from '../types'

const BASE = '/sales/prices'

export function PriceDocsPage() {
  const nav = useNavigate()
  const { can } = useStore()
  const list = usePaged<PriceDocument>('/store/price-documents')
  return (
    <>
      <PageTitle
        title="Установка цен"
        extra={
          can('prices.manage') && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => nav(`${BASE}/new`)}>
              Создать
            </Button>
          )
        }
      />
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<PriceDocument>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          onRow={(r) => ({ onClick: () => nav(`${BASE}/${r.id}`), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: 'Дата', dataIndex: 'created_at', render: dateTime },
            { title: 'Тип цены', dataIndex: 'price_type_name' },
            { title: 'Магазин', dataIndex: 'store_name', render: (v: string | null) => v ?? 'Вся сеть' },
            { title: 'Товаров', dataIndex: 'items_count', align: 'right' },
            { title: 'Примечание', dataIndex: 'note' },
            { title: 'Статус', dataIndex: 'status', render: (s: string) => <StatusTag status={s} /> },
            { title: 'Проведён', dataIndex: 'posted_at', render: dateTime },
            { title: 'Автор', dataIndex: 'created_by' },
          ]}
        />
      </Card>
    </>
  )
}

interface Line {
  key: string
  product_id: string
  product_name: string
  current?: string
  new_price: string | null
  previous_price?: string | null
}

let seq = 0
const blank = (): Line => ({ key: `n${++seq}`, product_id: '', product_name: '', new_price: null })

export function PriceDocEditor() {
  const { id = 'new' } = useParams()
  const isNew = id === 'new'
  const nav = useNavigate()
  const { message } = App.useApp()
  const { storeId, stores, can, me } = useStore()
  const doc = useItem<PriceDocument>(isNew ? null : `/store/price-documents/${id}`)
  const d = doc.data
  const [form] = Form.useForm<{ price_type_id: string; store_id: string; note: string }>()
  const [lines, setLines] = useState<Line[]>([blank()])
  const [busy, setBusy] = useState(false)
  const types = useList<PriceType>('/store/price-types')
  const readOnly = !can('prices.manage') || (!!d && d.status !== 'draft')
  const priceTypeId = Form.useWatch('price_type_id', form)

  useEffect(() => {
    if (isNew) {
      const def = (types.data ?? []).find((t) => t.is_default)
      form.setFieldsValue({ store_id: storeId, price_type_id: form.getFieldValue('price_type_id') ?? def?.id })
      return
    }
    if (!d) return
    form.setFieldsValue({ price_type_id: d.price_type_id, store_id: d.store_id ?? '', note: d.note })
    const ls = (d.items ?? []).map((i, n) => ({
      key: `l${n}`,
      product_id: i.product_id,
      product_name: i.product_name,
      new_price: trimNum(i.new_price),
      previous_price: i.previous_price,
      current: i.current_price,
    }))
    setLines(d.status === 'draft' ? [...ls, blank()] : ls)
  }, [d, isNew, types.data, storeId, form])

  const update = (key: string, patch: Partial<Line>) =>
    setLines((ls) => {
      const next = ls.map((l) => (l.key === key ? { ...l, ...patch } : l))
      if (next[next.length - 1]?.product_id) next.push(blank())
      return next
    })

  const run = async (post: boolean) => {
    setBusy(true)
    let docId = id
    try {
      const h = await form.validateFields()
      const items = lines.filter((l) => l.product_id)
      if (!items.length) throw new Error('Добавьте хотя бы один товар')
      const bad = items.find((l) => !l.new_price)
      if (bad) throw new Error(`Укажите новую цену: ${bad.product_name}`)
      const body = { note: h.note ?? '', items: items.map((l) => ({ product_id: l.product_id, new_price: trimNum(l.new_price) })) }
      if (isNew) {
        const created = await api.post<PriceDocument>('/store/price-documents', {
          ...body,
          price_type_id: h.price_type_id,
          store_id: h.store_id || null,
        })
        docId = created.id
      } else {
        await api.patch(`/store/price-documents/${id}`, body)
      }
      if (post) {
        await api.post(`/store/price-documents/${docId}/post`)
        message.success('Цены установлены')
      } else message.success('Черновик сохранён')
      if (isNew) nav(`${BASE}/${docId}`, { replace: true })
      else void doc.refetch()
    } catch (e) {
      if (!(e && typeof e === 'object' && 'errorFields' in e)) message.error(errorText(e))
      if (isNew && docId !== 'new') nav(`${BASE}/${docId}`, { replace: true })
    } finally {
      setBusy(false)
    }
  }

  if (!isNew && doc.error) return <Alert type="error" showIcon message={errorText(doc.error)} />

  return (
    <>
      <PageTitle
        title={
          isNew ? (
            'Установка цен: новый документ'
          ) : (
            <>
              Установка цен № {d?.number ?? ''} {d && <StatusTag status={d.status} />}
            </>
          )
        }
        extra={
          <Space wrap>
            <Button onClick={() => nav(BASE)}>К списку</Button>
            {!readOnly && (
              <>
                <Button loading={busy} onClick={() => run(false)}>
                  Сохранить черновик
                </Button>
                <Popconfirm title="Провести документ и установить цены?" onConfirm={() => run(true)}>
                  <Button type="primary" loading={busy}>
                    Провести
                  </Button>
                </Popconfirm>
              </>
            )}
          </Space>
        }
      />
      <Card style={{ marginBottom: 16 }} loading={!isNew && doc.isLoading}>
        <Form form={form} layout="vertical" disabled={readOnly}>
          <Row gutter={16}>
            <Col xs={24} md={8}>
              <Form.Item name="price_type_id" label="Тип цены" rules={[{ required: true, message: 'Выберите тип цены' }]}>
                <RemoteSelect<PriceType> path="/store/price-types" disabled={!isNew || readOnly} filter={(t) => t.is_active} />
              </Form.Item>
            </Col>
            <Col xs={24} md={8}>
              <Form.Item name="store_id" label="Где действует">
                <Select
                  disabled={!isNew || readOnly}
                  options={[
                    ...(me?.all_stores ? [{ value: '', label: 'Вся сеть' }] : []),
                    ...stores.map((s) => ({ value: s.id, label: s.name })),
                  ]}
                />
              </Form.Item>
            </Col>
            <Col xs={24} md={8}>
              <Form.Item name="note" label="Примечание">
                <Input />
              </Form.Item>
            </Col>
          </Row>
          {d && (
            <Typography.Text type="secondary">
              Создан {dateTime(d.created_at)} · {d.created_by}
              {d.posted_at && ` · проведён ${dateTime(d.posted_at)}`}
            </Typography.Text>
          )}
        </Form>
      </Card>
      <Card title="Товары и цены" styles={{ body: { padding: 0 } }}>
        <Table<Line>
          rowKey="key"
          dataSource={lines}
          pagination={false}
          scroll={{ x: true }}
          columns={[
            { title: '№', key: 'n', width: 50, render: (_, __, i) => i + 1 },
            {
              title: 'Товар',
              key: 'p',
              render: (_, l) =>
                readOnly ? (
                  l.product_name
                ) : (
                  <ProductSelect
                    value={l.product_id}
                    label={l.product_name}
                    priceTypeId={priceTypeId}
                    style={{ minWidth: 260, width: '100%' }}
                    onChange={(pid, p) => {
                      if (lines.some((x) => x.product_id === pid && x.key !== l.key)) {
                        message.warning('Этот товар уже есть в документе')
                        return
                      }
                      update(l.key, { product_id: pid, product_name: p?.name ?? '', current: p?.price ?? p?.base_price })
                    }}
                  />
                ),
            },
            // Проведённый документ — цена до него; черновик — действующая сейчас.
            d && d.status !== 'draft'
              ? { title: 'Прежняя цена', key: 'prev', align: 'right', render: (_, l) => money(l.previous_price) }
              : { title: 'Текущая цена', key: 'cur', align: 'right', render: (_, l) => money(l.current) },
            {
              title: 'Новая цена',
              key: 'np',
              width: 180,
              render: (_, l) =>
                readOnly ? (
                  <b>{money(l.new_price)}</b>
                ) : (
                  <Num value={l.new_price} onChange={(v) => update(l.key, { new_price: v })} />
                ),
            },
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
        />
      </Card>
    </>
  )
}
