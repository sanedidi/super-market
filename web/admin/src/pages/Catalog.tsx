import { useState } from 'react'
import { useParams } from 'react-router-dom'
import { Button, ColorPicker, Flex, Form, Image, Input, InputNumber, Modal, Segmented, Space, Switch, Tag, Typography, type TableColumnType } from 'antd'
import { PictureOutlined } from '@ant-design/icons'
import { ActiveTag, CrudPage, ImageUpload, ProductTree, ProductViewSwitch, RemoteSelect, StatusTag, api, money, useAction, useProductView } from '@sm/shared'
import { SearchSelect } from '../components'

interface Dict {
  id: string
  name: string
  is_active: boolean
  parent_id?: string | null
  parent_name?: string | null
  sort?: string | number
  hex?: string | null
  short_name?: string
  is_fractional?: boolean
}

const dictTitles: Record<string, string> = {
  categories: 'Категории товаров',
  brands: 'Бренды',
  colors: 'Цвета',
  units: 'Единицы измерения',
}

/** Общие справочники платформы: категории, бренды, цвета, единицы. */
export function Dictionary() {
  const { kind = 'brands' } = useParams()
  return <DictionaryPage key={kind} kind={kind} />
}

function DictionaryPage({ kind }: { kind: string }) {
  const path = `/admin/catalog/${kind}`
  const [q, setQ] = useState('')
  const columns = [
    ...(kind === 'categories'
      ? [
          {
            title: '',
            dataIndex: 'image_url',
            width: 56,
            render: (u: string | null) => (u ? <Image src={u} width={40} height={40} style={{ objectFit: 'cover', borderRadius: 8 }} /> : null),
          },
        ]
      : []),
    { title: 'Название', dataIndex: 'name' },
    ...(kind === 'categories'
      ? [
          { title: 'Родитель', dataIndex: 'parent_name', render: (n: string | null) => n || '—' },
          { title: 'Порядок', dataIndex: 'sort' },
        ]
      : []),
    ...(kind === 'colors'
      ? [{ title: 'Цвет', dataIndex: 'hex', render: (h: string | null) => (h ? <Tag color={h}>{h}</Tag> : '—') }]
      : []),
    ...(kind === 'units'
      ? [
          { title: 'Кратко', dataIndex: 'short_name' },
          { title: 'Дробное', dataIndex: 'is_fractional', render: (v: boolean) => (v ? 'Да' : 'Нет') },
        ]
      : []),
    { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
  ]
  return (
    <CrudPage<Dict>
      title={dictTitles[kind] ?? kind}
      path={path}
      canDelete
      params={{ q: q || undefined }}
      toolbar={<Input.Search placeholder="Поиск по названию" allowClear onSearch={setQ} style={{ width: 240 }} />}
      columns={columns}
      toBody={(v) => {
        const body: Record<string, unknown> = { ...v }
        if (kind === 'colors' && v.hex && typeof v.hex === 'object') {
          body.hex = (v.hex as { toHexString: () => string }).toHexString().slice(0, 7).toUpperCase()
        }
        if (kind === 'categories' && body.parent_id === undefined) body.parent_id = null
        if (kind === 'categories') body.image_url = (v.image_url as string | undefined) ?? ''
        return body
      }}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={[{ required: true }]}>
            <Input />
          </Form.Item>
          {kind === 'categories' && (
            <>
              <Form.Item name="parent_id" label="Родительская категория">
                <SearchSelect
                  path={path}
                  params={editing ? { exclude_tree: editing.id } : undefined}
                  known={{ id: editing?.parent_id, label: editing?.parent_name }}
                  allowClear
                  placeholder="Без родителя"
                />
              </Form.Item>
              <Form.Item name="sort" label="Порядок">
                <InputNumber precision={0} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item name="image_url" label="Картинка" extra="Плитка категории в приложении. Лучше квадратная, на светлом фоне">
                <ImageUpload hint="Картинка" />
              </Form.Item>
            </>
          )}
          {kind === 'colors' && (
            <Form.Item name="hex" label="Цвет">
              <ColorPicker format="hex" />
            </Form.Item>
          )}
          {kind === 'units' && (
            <>
              <Form.Item name="short_name" label="Кратко (шт, кг)" rules={[{ required: true }]}>
                <Input />
              </Form.Item>
              <Form.Item name="is_fractional" label="Дробное количество" valuePropName="checked">
                <Switch />
              </Form.Item>
            </>
          )}
          {editing && (
            <Form.Item name="is_active" label="Активен" valuePropName="checked">
              <Switch />
            </Form.Item>
          )}
        </>
      )}
    />
  )
}

interface Product {
  id: string
  network_id: string | null
  name: string
  description: string
  brand_id: string | null
  brand_name: string | null
  category_id: string
  category_name: string
  unit_id: string
  unit_short: string
  color_id: string | null
  base_price: string
  images: string[]
  barcodes: string[]
  moderation_status: string
  rejection_reason: string
  is_active: boolean
  attributes: Record<string, unknown> | null
}

// Характеристики для карточки товара в приложении.
const TEXT_ATTRS: [string, string, string?][] = [
  ['composition', 'Состав'],
  ['shelf_life', 'Срок хранения', '10 суток'],
  ['storage', 'Условия хранения', 'от +2 до +6 °C'],
  ['country', 'Страна', 'Узбекистан'],
  ['manufacturer', 'Производитель'],
  ['volume', 'Объём / вес', '900 мл'],
]
const NUTRITION: [string, string][] = [
  ['kcal', 'ккал'],
  ['protein', 'белки, г'],
  ['fat', 'жиры, г'],
  ['carbs', 'углеводы, г'],
]

function attrsToForm(a: Record<string, unknown> | null) {
  const out: Record<string, unknown> = {}
  for (const [k] of TEXT_ATTRS) out[`attr_${k}`] = a?.[k] ?? ''
  const n = (a?.nutrition ?? {}) as Record<string, number>
  for (const [k] of NUTRITION) out[`nut_${k}`] = n[k] ?? null
  return out
}

function formToAttrs(v: Record<string, unknown>) {
  const attrs: Record<string, unknown> = {}
  for (const [k] of TEXT_ATTRS) {
    const val = String(v[`attr_${k}`] ?? '').trim()
    if (val) attrs[k] = val
  }
  const nutrition: Record<string, number> = {}
  for (const [k] of NUTRITION) {
    const val = v[`nut_${k}`]
    if (val !== null && val !== undefined && val !== '') nutrition[k] = Number(val)
  }
  if (Object.keys(nutrition).length) attrs.nutrition = nutrition
  const rest = Object.fromEntries(Object.entries(v).filter(([k]) => !k.startsWith('attr_') && !k.startsWith('nut_')))
  return { rest, attrs }
}

/** Общий каталог товаров; moderation — очередь товаров от сетей. */
const treeName: TableColumnType<Product> = {
  title: 'Бренд · категория · товар',
  key: 'name',
  render: (_, p) => (
    <Flex align="center" gap={12}>
      {p.images?.[0] ? (
        <Image src={p.images[0]} width={40} height={40} style={{ objectFit: 'cover', borderRadius: 8 }} />
      ) : (
        <Flex align="center" justify="center" style={{ width: 40, height: 40, borderRadius: 8, background: '#F2F4F7', color: '#98A2B3', flex: 'none' }}>
          <PictureOutlined />
        </Flex>
      )}
      <div>
        {p.name}
        {p.network_id && (
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              товар сети
            </Typography.Text>
          </div>
        )}
      </div>
    </Flex>
  ),
}

export function Products({ moderation = false }: { moderation?: boolean }) {
  const [q, setQ] = useState('')
  const [category, setCategory] = useState<string>()
  const [tab, setTab] = useState('all')
  const [view, setView] = useProductView()
  const tree = view === 'tree' && !moderation
  const params = {
    q: q.trim() || undefined,
    category_id: category,
    status: moderation ? 'pending' : tab === 'all' ? undefined : tab,
  }
  const [rejecting, setRejecting] = useState<Product | null>(null)
  const [reason, setReason] = useState('')
  const closeReject = () => {
    setRejecting(null)
    setReason('')
  }
  const approve = useAction((id: string) => api.post(`/admin/products/${id}/approve`), { success: 'Товар одобрен и добавлен в общий каталог' })
  const reject = useAction((v: { id: string; reason: string }) => api.post(`/admin/products/${v.id}/reject`, { reason: v.reason }), {
    success: 'Товар отклонён',
  })

  return (
    <>
      <CrudPage<Product>
        title={moderation ? 'Модерация товаров' : 'Товары'}
        path="/admin/products"
        canDelete
        params={params}
        renderList={
          tree
            ? (cols) => (
                <ProductTree<Product>
                  groupsPath="/admin/products/groups"
                  itemsPath="/admin/products"
                  params={params}
                  // В дереве фото — в колонке названия, бренд и категория — в группах.
                  columns={[treeName, ...(cols.slice(2) as TableColumnType<Product>[])]}
                />
              )
            : undefined
        }
        canCreate={!moderation}
        createLabel="Новый товар"
        toolbar={
          <>
            {!moderation && (
              <Segmented
                value={tab}
                onChange={(v) => setTab(String(v))}
                options={[
                  { value: 'all', label: 'Все' },
                  { value: 'approved', label: 'В каталоге' },
                  { value: 'pending', label: 'На модерации' },
                  { value: 'rejected', label: 'Отклонённые' },
                ]}
              />
            )}
            <Input.Search placeholder="Название или штрихкод" allowClear onSearch={setQ} style={{ width: 240 }} />
            <SearchSelect path="/admin/catalog/categories" placeholder="Категория" allowClear value={category} onChange={(v) => setCategory(v as string | undefined)} />
            {!moderation && <ProductViewSwitch value={view} onChange={setView} />}
          </>
        }
        columns={[
          {
            title: '',
            dataIndex: 'images',
            width: 56,
            render: (imgs: string[]) => (imgs?.[0] ? <Image src={imgs[0]} width={40} height={40} style={{ objectFit: 'cover' }} /> : null),
          },
          {
            title: 'Товар',
            render: (_, p) => (
              <>
                {p.name}
                <br />
                <Typography.Text type="secondary">{[p.brand_name, p.category_name].filter(Boolean).join(' · ')}</Typography.Text>
              </>
            ),
          },
          { title: 'Ед.', dataIndex: 'unit_short' },
          { title: 'Базовая цена', dataIndex: 'base_price', align: 'right', render: (v) => money(v) },
          { title: 'Штрихкоды', dataIndex: 'barcodes', render: (b: string[]) => b?.join(', ') },
          {
            title: 'Статус',
            render: (_, p) => (
              <Space direction="vertical" size={0}>
                <StatusTag status={p.moderation_status} />
                {p.network_id && <Typography.Text type="secondary">от сети</Typography.Text>}
                {p.rejection_reason && <Typography.Text type="danger">{p.rejection_reason}</Typography.Text>}
                {!p.is_active && <ActiveTag active={false} />}
              </Space>
            ),
          },
          ...(moderation
            ? [
                {
                  key: 'mod',
                  render: (_: unknown, p: Product) => (
                    <Space>
                      <Button
                        size="small"
                        type="primary"
                        loading={approve.isPending && approve.variables === p.id}
                        disabled={approve.isPending && approve.variables !== p.id}
                        onClick={() => approve.mutate(p.id)}
                      >
                        Одобрить
                      </Button>
                      <Button size="small" danger onClick={() => setRejecting(p)}>
                        Отклонить
                      </Button>
                    </Space>
                  ),
                },
              ]
            : []),
        ]}
        toForm={(p) => ({ ...p, ...attrsToForm(p.attributes), images: p.images ?? [], barcodes: p.barcodes?.join('\n') })}
        toBody={(raw) => {
          const { rest: v, attrs } = formToAttrs(raw)
          return {
          ...v,
          attributes: attrs,
          // Пустая строка — убрать бренд/цвет; null сервер понимает как «не менять».
          brand_id: v.brand_id ?? '',
          color_id: v.color_id ?? '',
          images: (v.images as string[] | undefined) ?? [],
          barcodes: String(v.barcodes ?? '')
            .split(/[\n,]/)
            .map((s) => s.trim())
            .filter(Boolean),
          }
        }}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={[{ required: true }]}>
              <Input />
            </Form.Item>
            <Form.Item name="category_id" label="Категория" rules={[{ required: true }]}>
              <SearchSelect path="/admin/catalog/categories" known={{ id: editing?.category_id, label: editing?.category_name }} />
            </Form.Item>
            <Space wrap>
              <Form.Item name="unit_id" label="Единица" rules={[{ required: true }]}>
                <RemoteSelect path="/admin/catalog/units" style={{ width: 150 }} />
              </Form.Item>
              <Form.Item name="base_price" label="Базовая цена, сум" rules={[{ required: true }]}>
                <InputNumber min={0} precision={2} style={{ width: 170 }} />
              </Form.Item>
            </Space>
            <Space wrap>
              <Form.Item name="brand_id" label="Бренд">
                <SearchSelect
                  path="/admin/catalog/brands"
                  known={{ id: editing?.brand_id, label: editing?.brand_name }}
                  allowClear
                  style={{ width: 200 }}
                />
              </Form.Item>
              <Form.Item name="color_id" label="Цвет">
                <RemoteSelect path="/admin/catalog/colors" allowClear style={{ width: 200 }} />
              </Form.Item>
            </Space>
            <Form.Item name="description" label="Описание">
              <Input.TextArea rows={2} />
            </Form.Item>
            <Form.Item name="barcodes" label="Штрихкоды" extra="По одному в строке">
              <Input.TextArea rows={2} />
            </Form.Item>
            <Form.Item name="images" label="Фото" extra="До 10 фото, первое — главное. JPG, PNG, WEBP до 8 МБ">
              <ImageUpload multiple max={10} />
            </Form.Item>
            <Typography.Title level={5}>Для карточки в приложении</Typography.Title>
            <Form.Item label="Пищевая ценность на 100 г" style={{ marginBottom: 0 }}>
              <Space wrap>
                {NUTRITION.map(([k, label]) => (
                  <Form.Item key={k} name={`nut_${k}`} extra={label}>
                    <InputNumber min={0} max={10000} style={{ width: 100 }} />
                  </Form.Item>
                ))}
              </Space>
            </Form.Item>
            {TEXT_ATTRS.map(([k, label, ph]) => (
              <Form.Item key={k} name={`attr_${k}`} label={label}>
                <Input placeholder={ph} maxLength={500} />
              </Form.Item>
            ))}
            {editing && (
              <Form.Item name="is_active" label="Активен" valuePropName="checked">
                <Switch />
              </Form.Item>
            )}
          </>
        )}
      />
      <Modal
        open={rejecting !== null}
        title={`Отклонить «${rejecting?.name}»`}
        okText="Отклонить"
        okButtonProps={{ danger: true, disabled: !reason.trim() }}
        confirmLoading={reject.isPending}
        onCancel={closeReject}
        onOk={() => reject.mutate({ id: rejecting!.id, reason }, { onSuccess: closeReject })}
      >
        <Input.TextArea rows={3} placeholder="Причина — её увидит магазин" value={reason} onChange={(e) => setReason(e.target.value)} />
      </Modal>
    </>
  )
}
