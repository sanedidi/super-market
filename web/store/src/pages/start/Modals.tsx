// Окна «Начала работы»: новый товар, неизвестный штрихкод, фото полок.
import { useEffect, useMemo, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Col, Flex, Form, Input, InputNumber, Modal, Row, Segmented, Select, Space, Table, Tag, Typography } from 'antd'
import { CheckCircleFilled, ExclamationCircleFilled, PlusOutlined, QuestionCircleFilled } from '@ant-design/icons'
import { ImageUpload, RemoteSelect, api, errorText, money, plural, useList } from '@sm/shared'
import { useStore } from '../../ctx'
import { Num, ProductSelect } from '../../ui'
import type { DictItem, Product } from '../../types'
import { useStartApi, type Candidate, type Photo, type PhotoItem } from './api'
import { Thumb } from './CatalogTree'

const goods = (n: number) => `${n} ${plural(n, 'товар', 'товара', 'товаров')}`

// ------------------------------------------------------------ новый товар

export type NewProductInit = {
  name?: string
  barcode?: string
  brand_id?: string | null
  category_id?: string | null
  qty?: string | number
}

/**
 * Свой товар, которого нет в каталоге: сразу доступен сети и попадает в
 * список, в общий каталог — после проверки. withLine — сразу в черновик с
 * количеством и закупкой (иначе только создать и вернуть).
 */
export function NewProductModal({
  open,
  init,
  withLine = true,
  onClose,
  onCreated,
}: {
  open: boolean
  init?: NewProductInit
  withLine?: boolean
  onClose: () => void
  onCreated?: (p: Product) => void
}) {
  const { storeId } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [form] = Form.useForm()
  const [saving, setSaving] = useState(false)
  const units = useList<DictItem & { short_name: string }>(open ? '/store/catalog/units' : null)

  // Поля заполняем при открытии окна (init мог пересоздаться при перерисовке).
  const initRef = useRef(init)
  initRef.current = init
  useEffect(() => {
    if (!open) return
    const init = initRef.current
    form.resetFields()
    form.setFieldsValue({
      name: init?.name,
      brand_id: init?.brand_id ?? undefined,
      category_id: init?.category_id ?? undefined,
      barcodes: init?.barcode ? [init.barcode] : [],
      qty: init?.qty ? String(init.qty) : '1',
    })
  }, [open, form])
  // Единица по умолчанию — штука.
  useEffect(() => {
    const pcs = units.data?.find((u) => u.short_name === 'шт')
    if (open && pcs && !form.getFieldValue('unit_id')) form.setFieldValue('unit_id', pcs.id)
  }, [open, units.data, form])

  const submit = async (v: Record<string, unknown>) => {
    setSaving(true)
    try {
      const p = await api.post<Product>('/store/products', {
        name: v.name,
        category_id: v.category_id,
        unit_id: v.unit_id,
        brand_id: v.brand_id || undefined,
        base_price: v.base_price,
        barcodes: v.barcodes ?? [],
        images: v.images ?? [],
        description: '',
      })
      if (withLine) {
        await setLines([{ product_id: p.id, qty: v.qty as string, cost: (v.cost as string) || undefined, source: 'new' }])
        message.success('Товар создан и добавлен в список')
      }
      onCreated?.(p)
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      open={open}
      title="Новый товар"
      okText={withLine ? 'Создать и добавить' : 'Создать'}
      onOk={() => form.submit()}
      confirmLoading={saving}
      onCancel={onClose}
      width={680}
      destroyOnHidden
    >
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message="Товара нет в каталоге? Создайте его: он сразу встанет в ваш список, а после проверки попадёт в общий каталог и станет виден покупателям."
      />
      <Form form={form} layout="vertical" onFinish={submit}>
        <Row gutter={16}>
          <Col span={24}>
            <Form.Item name="name" label="Название" rules={[{ required: true, whitespace: true, message: 'Обязательное поле' }]}>
              <Input placeholder="Вид товара, бренд, вкус, объём — например «Квас Navruz 1,5 л»" />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="category_id" label="Категория" rules={[{ required: true, message: 'Выберите категорию' }]}>
              <RemoteSelect<DictItem> path="/store/catalog/categories" />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="brand_id" label="Бренд">
              <RemoteSelect<DictItem> path="/store/catalog/brands" allowClear />
            </Form.Item>
          </Col>
          <Col xs={24} md={8}>
            <Form.Item name="unit_id" label="Единица" rules={[{ required: true, message: 'Выберите единицу' }]}>
              <RemoteSelect<DictItem & { short_name: string }> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} />
            </Form.Item>
          </Col>
          {withLine && (
            <>
              <Col xs={12} md={8}>
                <Form.Item name="qty" label="Количество" rules={[{ required: true, message: 'Укажите количество' }]}>
                  <Num min="0.001" />
                </Form.Item>
              </Col>
              <Col xs={12} md={8}>
                <Form.Item name="cost" label="Закупочная цена">
                  <Num placeholder="сум за единицу" />
                </Form.Item>
              </Col>
            </>
          )}
          <Col xs={24} md={withLine ? 8 : 16}>
            <Form.Item name="base_price" label="Цена продажи" rules={[{ required: true, message: 'Укажите цену' }]}>
              <Num min="1" placeholder="сум" />
            </Form.Item>
          </Col>
          <Col xs={24} md={withLine ? 16 : 24}>
            <Form.Item name="barcodes" label="Штрихкод" extra="Отсканируйте или введите и нажмите Enter">
              <Select mode="tags" tokenSeparators={[',', ' ']} open={false} />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="images" label="Фото" extra="Первое — главное. JPG, PNG, WEBP до 8 МБ">
              <ImageUpload multiple max={5} />
            </Form.Item>
          </Col>
        </Row>
      </Form>
    </Modal>
  )
}

// ------------------------------------------------------ неизвестный штрихкод

/** Штрихкода нет в каталоге: привязать к найденному товару или создать новый. */
export function BarcodeModal({ code, onClose }: { code: string | null; onClose: () => void }) {
  const { storeId, can } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [mode, setMode] = useState<'bind' | 'new'>('bind')
  const [product, setProduct] = useState<{ id: string; name: string }>()
  const [saving, setSaving] = useState(false)
  const [creating, setCreating] = useState(false)
  useEffect(() => {
    if (code) {
      setMode('bind')
      setProduct(undefined)
    }
  }, [code])
  const manage = can('catalog.manage')

  const bind = async () => {
    if (!product || !code) return
    setSaving(true)
    try {
      await setLines([{ product_id: product.id, add: true, barcode: code, source: 'barcode' }])
      message.success(`Штрихкод привязан · ${product.name} +1`)
      onClose()
    } catch {
      // ошибка уже показана
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      <Modal
        open={!!code && !creating}
        title={`Штрихкод ${code ?? ''} не найден`}
        onCancel={onClose}
        footer={
          mode === 'bind' ? (
            <Space>
              <Button onClick={onClose}>Отмена</Button>
              <Button type="primary" disabled={!product || !manage} loading={saving} onClick={bind}>
                Привязать и добавить
              </Button>
            </Space>
          ) : (
            <Space>
              <Button onClick={onClose}>Отмена</Button>
              <Button type="primary" icon={<PlusOutlined />} disabled={!manage} onClick={() => setCreating(true)}>
                Создать товар
              </Button>
            </Space>
          )
        }
        destroyOnHidden
      >
        <Typography.Paragraph type="secondary">
          Такого штрихкода нет в каталоге. Если товар в каталоге есть, но без этого штрихкода — привяжите его, и в следующий раз товар найдётся сканером.
        </Typography.Paragraph>
        {!manage && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message="Привязывать штрихкоды и создавать товары может сотрудник с правом на каталог." />}
        <Segmented
          block
          value={mode}
          onChange={(v) => setMode(v as 'bind' | 'new')}
          options={[
            { value: 'bind', label: 'Привязать к товару' },
            { value: 'new', label: 'Создать новый товар' },
          ]}
          style={{ marginBottom: 16 }}
        />
        {mode === 'bind' ? (
          <ProductSelect value={product?.id} label={product?.name} onChange={(id, p) => setProduct({ id, name: p?.name ?? '' })} autoFocus />
        ) : (
          <Typography.Text>Создайте свой товар со штрихкодом {code}. Он сразу встанет в список.</Typography.Text>
        )}
      </Modal>
      <NewProductModal
        open={creating}
        init={{ barcode: code ?? undefined }}
        onClose={() => {
          setCreating(false)
          onClose()
        }}
      />
    </>
  )
}

// --------------------------------------------------------------- фото полок

const SKIP = '__skip'
const NEW = '__new'

const stateIcon: Record<PhotoItem['state'], JSX.Element> = {
  found: <CheckCircleFilled style={{ color: '#12B76A' }} />,
  choose: <QuestionCircleFilled style={{ color: '#F79009' }} />,
  missing: <ExclamationCircleFilled style={{ color: '#F04438' }} />,
}

/**
 * Фото полок: Super Market находит на фото товары каталога и считает штуки.
 * Найденное проверяют, выбирают из похожих или создают новый товар — и
 * добавляют в список одним нажатием (повторно — штуки прибавляются).
 */
export function PhotoModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { storeId, can } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [images, setImages] = useState<string[]>([])
  const [photoId, setPhotoId] = useState<string | null>(null)
  const [starting, setStarting] = useState(false)
  const [adding, setAdding] = useState(false)
  // Выбор по строкам фото: id товара, SKIP или пусто.
  const [choice, setChoice] = useState<Record<number, string>>({})
  const [qtys, setQtys] = useState<Record<number, string>>({})
  const [created, setCreated] = useState<Record<number, Candidate>>({})
  const [creating, setCreating] = useState<PhotoItem | null>(null)

  const reset = () => {
    setImages([])
    setPhotoId(null)
    setChoice({})
    setQtys({})
    setCreated({})
  }
  useEffect(() => {
    if (open) reset()
  }, [open])

  const photo = useQuery({
    queryKey: ['/store/start/photos', photoId],
    queryFn: () => api.get<Photo>(`/store/start/photos/${photoId}`),
    enabled: !!photoId,
    refetchInterval: (q) => (q.state.data?.status === 'processing' || !q.state.data ? 1500 : false),
  })
  const ph = photo.data
  const ready = ph?.status === 'ready'

  // Найденное уверенно — выбрано сразу.
  useEffect(() => {
    if (!ready || !ph) return
    setChoice((c) => {
      const next = { ...c }
      for (const it of ph.items) if (next[it.n] === undefined && it.state === 'found' && it.product) next[it.n] = it.product.product_id
      return next
    })
    setQtys((q) => {
      const next = { ...q }
      for (const it of ph.items) if (next[it.n] === undefined) next[it.n] = String(Number(it.qty))
      return next
    })
  }, [ready, ph])

  const start = async () => {
    setStarting(true)
    try {
      const r = await api.post<Photo>('/store/start/photos', { store_id: storeId, images })
      setPhotoId(r.id)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setStarting(false)
    }
  }
  const retry = async () => {
    if (!photoId) return
    try {
      await api.post(`/store/start/photos/${photoId}/retry`)
      photo.refetch()
    } catch (e) {
      message.error(errorText(e))
    }
  }

  const chosen = useMemo(() => {
    if (!ph) return []
    const sum = new Map<string, number>()
    for (const it of ph.items) {
      const id = choice[it.n]
      const q = Number(qtys[it.n] ?? it.qty)
      if (!id || id === SKIP || !(q > 0)) continue
      sum.set(id, (sum.get(id) ?? 0) + q)
    }
    return Array.from(sum, ([product_id, qty]) => ({ product_id, qty: String(qty) }))
  }, [ph, choice, qtys])

  const add = async () => {
    setAdding(true)
    try {
      await setLines(chosen.map((c) => ({ ...c, add: true, source: 'photo' as const })))
      message.success(`В список добавлено: ${goods(chosen.length)}`)
      onClose()
    } catch {
      // ошибка уже показана
    } finally {
      setAdding(false)
    }
  }

  const options = (it: PhotoItem) => {
    const list: Candidate[] = []
    const seen = new Set<string>()
    for (const c of [created[it.n], it.product, ...it.candidates]) {
      if (c && !seen.has(c.product_id)) {
        seen.add(c.product_id)
        list.push(c)
      }
    }
    return [
      ...list.map((c) => ({
        value: c.product_id,
        label: (
          <Flex align="center" gap={8} style={{ minWidth: 0 }}>
            <Thumb src={c.image} size={22} />
            <Typography.Text ellipsis>
              {c.name}
              {c.score > 0 && c.score < 100 && <Typography.Text type="secondary"> · {c.score}%</Typography.Text>}
            </Typography.Text>
          </Flex>
        ),
        search: c.name,
      })),
      ...(can('catalog.manage') ? [{ value: NEW, label: <Typography.Text type="danger"><PlusOutlined /> Нет в каталоге — создать товар</Typography.Text>, search: '' }] : []),
      { value: SKIP, label: <Typography.Text type="secondary">Не добавлять</Typography.Text>, search: '' },
    ]
  }

  const counts = ph?.counts
  return (
    <>
      <Modal
        open={open && !creating}
        width={880}
        title={
          <div>
            Фото полок — Super Market найдёт товары
            <Typography.Paragraph type="secondary" style={{ fontSize: 13, fontWeight: 400, margin: '4px 0 0' }}>
              Загрузите фото полок или отдельных товаров. Super Market сопоставит их с общим каталогом и посчитает штуки.
            </Typography.Paragraph>
          </div>
        }
        onCancel={onClose}
        destroyOnHidden
        footer={
          <Space>
            {ph && (
              <Button onClick={reset} disabled={adding}>
                Новые фото
              </Button>
            )}
            <Button onClick={onClose}>Отмена</Button>
            {ready ? (
              <Button type="primary" disabled={chosen.length === 0} loading={adding} onClick={add}>
                Добавить {goods(chosen.length)} в список
              </Button>
            ) : (
              <Button type="primary" disabled={images.length === 0 || !!photoId} loading={starting || ph?.status === 'processing'} onClick={start}>
                Найти товары
              </Button>
            )}
          </Space>
        }
      >
        <ImageUpload multiple max={6} value={images} onChange={setImages} disabled={!!photoId} hint="Фото полки" />
        {!photoId && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            До 6 фото одной полки или разных полок. Снимайте ближе и при хорошем свете — так Super Market точнее посчитает штуки.
          </Typography.Text>
        )}
        {ph?.status === 'processing' && (
          <Alert style={{ marginTop: 12 }} type="info" showIcon message="Super Market ищет товары на фото…" description="Обычно это занимает 10–30 секунд." />
        )}
        {ph?.status === 'failed' && (
          <Alert
            style={{ marginTop: 12 }}
            type="error"
            showIcon
            message="Не удалось найти товары"
            description={ph.error}
            action={<Button size="small" onClick={retry}>Повторить</Button>}
          />
        )}
        {ready && ph && counts && (
          <>
            <Space size={8} wrap style={{ margin: '12px 0' }}>
              <Tag bordered={false}>
                Распознано {ph.images.length} {plural(ph.images.length, 'фото', 'фото', 'фото')}
              </Tag>
              <Tag bordered={false} color="green">
                {counts.found} найдено
              </Tag>
              {counts.choose > 0 && (
                <Tag bordered={false} color="orange">
                  {counts.choose} выбрать
                </Tag>
              )}
              {counts.missing > 0 && (
                <Tag bordered={false} color="red">
                  {counts.missing} нет в каталоге
                </Tag>
              )}
            </Space>
            <Table<PhotoItem>
              rowKey="n"
              size="small"
              pagination={false}
              dataSource={ph.items}
              scroll={{ y: 380 }}
              columns={[
                {
                  title: 'На фото',
                  key: 'name',
                  width: '34%',
                  render: (_, it) => (
                    <Flex align="center" gap={8}>
                      {stateIcon[it.state]}
                      <div style={{ minWidth: 0 }}>
                        <Typography.Text>{it.name}</Typography.Text>
                        {it.in_draft && (
                          <div>
                            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                              уже в списке — штуки прибавятся
                            </Typography.Text>
                          </div>
                        )}
                      </div>
                    </Flex>
                  ),
                },
                {
                  title: 'Товар в каталоге',
                  key: 'product',
                  render: (_, it) => {
                    const v = choice[it.n]
                    const status = !v ? (it.state === 'missing' ? 'error' : 'warning') : undefined
                    return (
                      <Select
                        value={v || undefined}
                        status={status}
                        style={{ width: '100%' }}
                        placeholder={
                          it.state === 'missing'
                            ? 'Нет в каталоге — выберите действие'
                            : `Выберите: ${it.candidates.length} ${plural(it.candidates.length, 'вариант', 'варианта', 'вариантов')}`
                        }
                        options={options(it)}
                        optionFilterProp="search"
                        showSearch
                        onChange={(id: string) => {
                          if (id === NEW) setCreating(it)
                          else setChoice((c) => ({ ...c, [it.n]: id }))
                        }}
                      />
                    )
                  },
                },
                {
                  title: 'Шт',
                  key: 'qty',
                  width: 100,
                  render: (_, it) => (
                    <InputNumber<string>
                      stringMode
                      min="0"
                      value={qtys[it.n]}
                      onChange={(v) => setQtys((q) => ({ ...q, [it.n]: v ?? '' }))}
                      style={{ width: '100%' }}
                    />
                  ),
                },
              ]}
            />
          </>
        )}
      </Modal>
      <NewProductModal
        open={!!creating}
        withLine={false}
        init={creating ? { name: creating.name, barcode: creating.barcode || undefined, brand_id: creating.brand_id, category_id: creating.category_id } : undefined}
        onClose={() => setCreating(null)}
        onCreated={(p) => {
          if (!creating) return
          const n = creating.n
          setCreated((c) => ({
            ...c,
            [n]: { product_id: p.id, name: p.name, image: p.images?.[0] ?? null, unit_short: p.unit_short, current_price: p.base_price, barcode: p.barcodes?.[0] ?? null, score: 0 },
          }))
          setChoice((c) => ({ ...c, [n]: p.id }))
          message.success('Товар создан — он на проверке, но в список его добавить можно')
        }}
      />
    </>
  )
}

/** Сумма для подписей: «18 450 000 сум». */
export const sum = (v: string | null | undefined) => `${money(v)} сум`
