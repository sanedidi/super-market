// Акции для приложения: на время акции товар продаётся онлайн по акционной цене.
import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Alert, App, Button, Card, Col, DatePicker, Form, Input, Row, Segmented, Select, Space, Switch, Table, Tag, Typography } from 'antd'
import { CloseOutlined, DeleteOutlined, PlusOutlined, SaveOutlined } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { DeleteButton, LoadError, PageTitle, api, dateTime, errorText, money, useItem, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { Num, ProductSelect, trimNum } from '../ui'
import type { Promotion } from '../types'

const BASE = '/sales/promotions'

const STATUS: Record<Promotion['status'], [string, string]> = {
  running: ['Идёт', 'green'],
  scheduled: ['Запланирована', 'blue'],
  ended: ['Завершена', 'default'],
  disabled: ['Выключена', 'default'],
}

export function PromoStatus({ status }: { status: Promotion['status'] }) {
  const [title, color] = STATUS[status]
  return <Tag color={color}>{title}</Tag>
}

export function PromotionsPage() {
  const nav = useNavigate()
  const { can, stores } = useStore()
  const [status, setStatus] = useState<string>('')
  const list = usePaged<Promotion>('/store/promotions', { status: status || undefined })
  const storeName = (ids: string[] | null) =>
    !ids || ids.length === 0 ? 'Все магазины' : ids.map((id) => stores.find((s) => s.id === id)?.name ?? '—').join(', ')
  return (
    <>
      <PageTitle
        title="Акции в приложении"
        extra={
          can('prices.manage') && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => nav(`${BASE}/new`)}>
              Создать акцию
            </Button>
          )
        }
      >
        <Segmented
          value={status}
          onChange={(v) => setStatus(String(v))}
          options={[
            { value: '', label: 'Все' },
            { value: 'running', label: 'Идут' },
            { value: 'scheduled', label: 'Запланированы' },
            { value: 'ended', label: 'Завершены' },
          ]}
        />
      </PageTitle>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Promotion>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          onRow={(r) => ({ onClick: () => nav(`${BASE}/${r.id}`), style: { cursor: 'pointer' } })}
          columns={[
            { title: 'Название', dataIndex: 'name' },
            { title: 'Начало', dataIndex: 'starts_at', render: dateTime },
            { title: 'Окончание', dataIndex: 'ends_at', render: dateTime },
            { title: 'Где', dataIndex: 'store_ids', render: storeName },
            { title: 'Товаров', dataIndex: 'item_count', align: 'right' },
            { title: 'Статус', dataIndex: 'status', render: (s: Promotion['status']) => <PromoStatus status={s} /> },
            { key: 'del', align: 'right', render: (_, r) => <DeleteButton path={`/store/promotions/${r.id}`} name={r.name} /> },
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
  regular?: string
  price: string | null
}

let seq = 0
const blank = (): Line => ({ key: `n${++seq}`, product_id: '', product_name: '', price: null })

type Head = { name: string; period: [Dayjs, Dayjs]; store_ids: string[]; is_active: boolean }

export function PromotionEditor() {
  const { id = 'new' } = useParams()
  const isNew = id === 'new'
  const nav = useNavigate()
  const { message } = App.useApp()
  const { stores, can, me } = useStore()
  const promo = useItem<Promotion>(isNew ? null : `/store/promotions/${id}`)
  const p = promo.data
  const [form] = Form.useForm<Head>()
  const [lines, setLines] = useState<Line[]>([blank()])
  const [busy, setBusy] = useState(false)
  const readOnly = !can('prices.manage')

  useEffect(() => {
    if (isNew) {
      form.setFieldsValue({
        period: [dayjs().startOf('day'), dayjs().add(7, 'day').endOf('day')],
        store_ids: me?.all_stores ? [] : stores.map((s) => s.id),
        is_active: true,
      })
      return
    }
    if (!p) return
    form.setFieldsValue({ name: p.name, period: [dayjs(p.starts_at), dayjs(p.ends_at)], store_ids: p.store_ids ?? [], is_active: p.is_active })
    const ls = (p.items ?? []).map((i, n) => ({
      key: `l${n}`,
      product_id: i.product_id,
      product_name: i.product_name,
      regular: i.regular_price,
      price: trimNum(i.price),
    }))
    setLines(readOnly ? ls : [...ls, blank()])
  }, [p, isNew, form, me, stores, readOnly])

  const update = (key: string, patch: Partial<Line>) =>
    setLines((ls) => {
      const next = ls.map((l) => (l.key === key ? { ...l, ...patch } : l))
      if (next[next.length - 1]?.product_id) next.push(blank())
      return next
    })

  const save = async () => {
    setBusy(true)
    try {
      const h = await form.validateFields()
      const items = lines.filter((l) => l.product_id)
      if (!items.length) throw new Error('Добавьте хотя бы один товар')
      const bad = items.find((l) => !l.price || Number(l.price) <= 0)
      if (bad) throw new Error(`Укажите акционную цену: ${bad.product_name}`)
      const body = {
        name: h.name,
        starts_at: h.period[0].toISOString(),
        ends_at: h.period[1].toISOString(),
        store_ids: h.store_ids ?? [],
        is_active: h.is_active,
        items: items.map((l) => ({ product_id: l.product_id, price: trimNum(l.price) })),
      }
      if (isNew) {
        const created = await api.post<Promotion>('/store/promotions', body)
        message.success('Акция создана')
        nav(`${BASE}/${created.id}`, { replace: true })
      } else {
        await api.patch(`/store/promotions/${id}`, body)
        message.success('Акция сохранена')
        void promo.refetch()
      }
    } catch (e) {
      if (!(e && typeof e === 'object' && 'errorFields' in e)) message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  if (!isNew && promo.error) return <Alert type="error" showIcon message={errorText(promo.error)} />

  return (
    <>
      <PageTitle
        title={
          isNew ? (
            'Новая акция'
          ) : (
            <>
              {p?.name ?? 'Акция'} {p && <PromoStatus status={p.status} />}
            </>
          )
        }
        extra={
          <Space wrap>
            {!readOnly && (
              <Button type="primary" icon={<SaveOutlined />} loading={busy} onClick={save}>
                Сохранить
              </Button>
            )}
          </Space>
        }
      >
        <Button type="text" icon={<CloseOutlined />} onClick={() => nav(BASE)} title="Закрыть" aria-label="Закрыть" />
      </PageTitle>
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message="Акционная цена действует только в приложении. Если она не ниже обычной цены магазина, покупатель увидит обычную."
      />
      <Card style={{ marginBottom: 16 }} loading={!isNew && promo.isLoading}>
        <Form form={form} layout="vertical" disabled={readOnly}>
          <Row gutter={16}>
            <Col xs={24} md={8}>
              <Form.Item name="name" label="Название" rules={[{ required: true, message: 'Введите название' }]}>
                <Input placeholder="Скидки недели" />
              </Form.Item>
            </Col>
            <Col xs={24} md={10}>
              <Form.Item name="period" label="Период" rules={[{ required: true, message: 'Выберите период' }]}>
                <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format="DD.MM.YYYY HH:mm" style={{ width: '100%' }} />
              </Form.Item>
            </Col>
            <Col xs={24} md={6}>
              <Form.Item name="is_active" label="Включена" valuePropName="checked">
                <Switch />
              </Form.Item>
            </Col>
            <Col xs={24}>
              <Form.Item
                name="store_ids"
                label="Магазины"
                extra={me?.all_stores ? 'Не выбрано — во всех магазинах сети' : undefined}
                rules={me?.all_stores ? [] : [{ required: true, type: 'array', min: 1, message: 'Выберите магазины' }]}
              >
                <Select mode="multiple" allowClear placeholder="Все магазины" options={stores.map((s) => ({ value: s.id, label: s.name }))} />
              </Form.Item>
            </Col>
          </Row>
          {p && <Typography.Text type="secondary">Создана {dateTime(p.created_at)}</Typography.Text>}
        </Form>
      </Card>
      <Card title="Товары и акционные цены" styles={{ body: { padding: 0 } }}>
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
                    style={{ minWidth: 260, width: '100%' }}
                    onChange={(pid, prod) => {
                      if (lines.some((x) => x.product_id === pid && x.key !== l.key)) {
                        message.warning('Этот товар уже есть в акции')
                        return
                      }
                      update(l.key, { product_id: pid, product_name: prod?.name ?? '', regular: prod?.price ?? prod?.base_price })
                    }}
                  />
                ),
            },
            { title: 'Обычная цена', key: 'reg', align: 'right', render: (_, l) => money(l.regular) },
            {
              title: 'Цена по акции',
              key: 'price',
              width: 180,
              render: (_, l) => (readOnly ? <b>{money(l.price)}</b> : <Num value={l.price} onChange={(v) => update(l.key, { price: v })} />),
            },
            {
              title: 'Скидка',
              key: 'd',
              align: 'right',
              render: (_, l) => {
                const r = Number(l.regular), n = Number(l.price)
                return r > 0 && n > 0 && n < r ? <Tag color="orange">−{Math.round((1 - n / r) * 100)}%</Tag> : null
              },
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
