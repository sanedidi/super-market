import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Button, ColorPicker, Flex, Form, Image, Input, InputNumber, Modal, Segmented, Space, Switch, Tag, Typography, type TableColumnType } from 'antd'
import { PictureOutlined } from '@ant-design/icons'
import {
  ActiveTag,
  CrudPage,
  FormTranslate,
  ImageUpload,
  ProductTree,
  ProductViewSwitch,
  StatusTag,
  api,
  money,
  useAction,
  useProductView,
  type Lang,
} from '@sm/shared'
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
  // Узбекский перевод (у брендов его нет).
  name_uz?: string | null
  short_name_uz?: string | null
}

/** Справочники, у которых есть узбекские названия. */
const TRANSLATED = ['categories', 'colors', 'units']

/** Кнопка автоперевода внутри формы CrudPage: форма берётся из контекста. */
function Tr({ from, into, to }: { from: string; into: string; to: Lang }) {
  const form = Form.useFormInstance()
  return <FormTranslate form={form} from={from} into={into} to={to} />
}

/** Значок «нет перевода» — только если сервер прислал поле, а оно пустое. */
function NoUz({ v }: { v: string | null | undefined }) {
  if (v === undefined || (v ?? '').trim()) return null
  return <Tag color="orange">нет перевода</Tag>
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
  const uz = TRANSLATED.includes(kind)
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
    ...(uz
      ? [
          {
            title: 'Перевод',
            key: 'uz',
            render: (_: unknown, r: Dict) =>
              (r.name_uz ?? '').trim() ? (
                <>
                  {r.name_uz}
                  {kind === 'units' && r.short_name_uz ? ` (${r.short_name_uz})` : ''}
                </>
              ) : (
                <NoUz v={r.name_uz} />
              ),
          },
        ]
      : []),
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
            <Input suffix={uz ? <Tr from="name_uz" into="name" to="ru" /> : undefined} />
          </Form.Item>
          {uz && (
            <Form.Item name="name_uz" label="Название (узб.)" extra="Латиница. Пусто — в приложении будет русское название">
              <Input suffix={<Tr from="name" into="name_uz" to="uz" />} />
            </Form.Item>
          )}
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
                <Input suffix={<Tr from="short_name_uz" into="short_name" to="ru" />} />
              </Form.Item>
              <Form.Item name="short_name_uz" label="Сокр. (узб.)">
                <Input placeholder="dona, kg" suffix={<Tr from="short_name" into="short_name_uz" to="uz" />} />
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

import type { Product } from './Product'

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
        {p.name} <NoUz v={p.name_uz} />
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
  const navigate = useNavigate()
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
                  onItemClick={(p) => navigate(`/products/${p.id}`)}
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
                {p.name} <NoUz v={p.name_uz} />
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
        onOpen={(p) => navigate(p ? `/products/${p.id}` : '/products/new')}
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
