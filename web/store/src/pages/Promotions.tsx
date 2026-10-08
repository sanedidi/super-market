// Акции для приложения: на время акции товар продаётся онлайн по акционной цене.
import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Alert, App, Button, Card, Col, DatePicker, Form, Input, Row, Segmented, Select, Space, Switch, Table, Tag, Typography } from 'antd'
import { CloseOutlined, DeleteOutlined, PlusOutlined, SaveOutlined } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { DeleteButton, LoadError, PageTitle, api, dateTime, errorText, money, tr, useItem, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { Num, ProductSelect, trimNum } from '../ui'
import type { Promotion } from '../types'

const BASE = '/sales/promotions'

const STATUS: Record<Promotion['status'], [string, string]> = {
  running: [tr('Идёт', 'Davom etmoqda'), 'green'],
  scheduled: [tr('Запланирована', 'Rejalashtirilgan'), 'blue'],
  ended: [tr('Завершена', 'Yakunlangan'), 'default'],
  disabled: [tr('Выключена', 'Oʻchirilgan'), 'default'],
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
    !ids || ids.length === 0 ? tr('Все магазины', 'Barcha doʻkonlar') : ids.map((id) => stores.find((s) => s.id === id)?.name ?? '—').join(', ')
  return (
    <>
      <PageTitle
        title={tr('Акции в приложении', 'Ilovadagi aksiyalar')}
        extra={
          can('prices.manage') && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => nav(`${BASE}/new`)}>
              {tr('Создать акцию', 'Aksiya yaratish')}
            </Button>
          )
        }
      >
        <Segmented
          value={status}
          onChange={(v) => setStatus(String(v))}
          options={[
            { value: '', label: tr('Все', 'Hammasi') },
            { value: 'running', label: tr('Идут', 'Davom etmoqda') },
            { value: 'scheduled', label: tr('Запланированы', 'Rejalashtirilgan') },
            { value: 'ended', label: tr('Завершены', 'Yakunlangan') },
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
            { title: tr('Название', 'Nomi'), dataIndex: 'name' },
            { title: tr('Начало', 'Boshlanishi'), dataIndex: 'starts_at', render: dateTime },
            { title: tr('Окончание', 'Tugashi'), dataIndex: 'ends_at', render: dateTime },
            { title: tr('Где', 'Qayerda'), dataIndex: 'store_ids', render: storeName },
            { title: tr('Товаров', 'Mahsulotlar'), dataIndex: 'item_count', align: 'right' },
            { title: tr('Статус', 'Holat'), dataIndex: 'status', render: (s: Promotion['status']) => <PromoStatus status={s} /> },
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
      if (!items.length) throw new Error(tr('Добавьте хотя бы один товар', 'Kamida bitta mahsulot qoʻshing'))
      const bad = items.find((l) => !l.price || Number(l.price) <= 0)
      if (bad) throw new Error(tr(`Укажите акционную цену: ${bad.product_name}`, `Aksiya narxini kiriting: ${bad.product_name}`))
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
        message.success(tr('Акция создана', 'Aksiya yaratildi'))
        nav(`${BASE}/${created.id}`, { replace: true })
      } else {
        await api.patch(`/store/promotions/${id}`, body)
        message.success(tr('Акция сохранена', 'Aksiya saqlandi'))
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
            tr('Новая акция', 'Yangi aksiya')
          ) : (
            <>
              {p?.name ?? tr('Акция', 'Aksiya')} {p && <PromoStatus status={p.status} />}
            </>
          )
        }
        extra={
          <Space wrap>
            {!readOnly && (
              <Button type="primary" icon={<SaveOutlined />} loading={busy} onClick={save}>
                {tr('Сохранить', 'Saqlash')}
              </Button>
            )}
          </Space>
        }
      >
        <Button type="text" icon={<CloseOutlined />} onClick={() => nav(BASE)} title={tr('Закрыть', 'Yopish')} aria-label={tr('Закрыть', 'Yopish')} />
      </PageTitle>
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message={tr(
          'Акционная цена действует только в приложении. Если она не ниже обычной цены магазина, покупатель увидит обычную.',
          'Aksiya narxi faqat ilovada amal qiladi. Agar u doʻkonning oddiy narxidan past boʻlmasa, xaridor oddiy narxni koʻradi.',
        )}
      />
      <Card style={{ marginBottom: 16 }} loading={!isNew && promo.isLoading}>
        <Form form={form} layout="vertical" disabled={readOnly}>
          <Row gutter={16}>
            <Col xs={24} md={8}>
              <Form.Item name="name" label={tr('Название', 'Nomi')} rules={[{ required: true, message: tr('Введите название', 'Nomini kiriting') }]}>
                <Input placeholder={tr('Скидки недели', 'Hafta chegirmalari')} />
              </Form.Item>
            </Col>
            <Col xs={24} md={10}>
              <Form.Item name="period" label={tr('Период', 'Davr')} rules={[{ required: true, message: tr('Выберите период', 'Davrni tanlang') }]}>
                <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format="DD.MM.YYYY HH:mm" style={{ width: '100%' }} />
              </Form.Item>
            </Col>
            <Col xs={24} md={6}>
              <Form.Item name="is_active" label={tr('Включена', 'Yoqilgan')} valuePropName="checked">
                <Switch />
              </Form.Item>
            </Col>
            <Col xs={24}>
              <Form.Item
                name="store_ids"
                label={tr('Магазины', 'Doʻkonlar')}
                extra={me?.all_stores ? tr('Не выбрано — во всех магазинах сети', 'Tanlanmasa — tarmoqning barcha doʻkonlarida') : undefined}
                rules={me?.all_stores ? [] : [{ required: true, type: 'array', min: 1, message: tr('Выберите магазины', 'Doʻkonlarni tanlang') }]}
              >
                <Select mode="multiple" allowClear placeholder={tr('Все магазины', 'Barcha doʻkonlar')} options={stores.map((s) => ({ value: s.id, label: s.name }))} />
              </Form.Item>
            </Col>
          </Row>
          {p && <Typography.Text type="secondary">
              {tr('Создана', 'Yaratilgan')} {dateTime(p.created_at)}
            </Typography.Text>}
        </Form>
      </Card>
      <Card title={tr('Товары и акционные цены', 'Mahsulotlar va aksiya narxlari')} styles={{ body: { padding: 0 } }}>
        <Table<Line>
          rowKey="key"
          dataSource={lines}
          pagination={false}
          scroll={{ x: true }}
          columns={[
            { title: '№', key: 'n', width: 50, render: (_, __, i) => i + 1 },
            {
              title: tr('Товар', 'Mahsulot'),
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
                        message.warning(tr('Этот товар уже есть в акции', 'Bu mahsulot aksiyada allaqachon bor'))
                        return
                      }
                      update(l.key, { product_id: pid, product_name: prod?.name ?? '', regular: prod?.price ?? prod?.base_price })
                    }}
                  />
                ),
            },
            { title: tr('Обычная цена', 'Oddiy narx'), key: 'reg', align: 'right', render: (_, l) => money(l.regular) },
            {
              title: tr('Цена по акции', 'Aksiya narxi'),
              key: 'price',
              width: 180,
              render: (_, l) => (readOnly ? <b>{money(l.price)}</b> : <Num value={l.price} onChange={(v) => update(l.key, { price: v })} />),
            },
            {
              title: tr('Скидка', 'Chegirma'),
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
