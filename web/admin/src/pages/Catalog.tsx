import { useState } from 'react'
import { useParams } from 'react-router-dom'
import { Button, ColorPicker, Form, Image, Input, InputNumber, Modal, Space, Switch, Tag, Typography } from 'antd'
import { ActiveTag, CrudPage, RemoteSelect, StatusTag, api, money, useAction, useList } from '@sm/shared'

interface Dict {
  id: string
  name: string
  is_active: boolean
  parent_id?: string | null
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
  const path = `/admin/catalog/${kind}`
  const { data: all } = useList<Dict>(kind === 'categories' ? path : null)
  const names = new Map((all ?? []).map((c) => [c.id, c.name]))
  const columns = [
    { title: 'Название', dataIndex: 'name' },
    ...(kind === 'categories'
      ? [
          { title: 'Родитель', dataIndex: 'parent_id', render: (id: string | null) => (id ? names.get(id) ?? '—' : '—') },
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
      key={kind}
      title={dictTitles[kind] ?? kind}
      path={path}
      columns={columns}
      toBody={(v) => {
        const body: Record<string, unknown> = { ...v }
        if (kind === 'colors' && v.hex && typeof v.hex === 'object') {
          body.hex = (v.hex as { toHexString: () => string }).toHexString().slice(0, 7).toUpperCase()
        }
        if (kind === 'categories' && body.parent_id === undefined) body.parent_id = null
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
                <RemoteSelect path={path} allowClear filter={(c) => c.id !== editing?.id} />
              </Form.Item>
              <Form.Item name="sort" label="Порядок">
                <InputNumber style={{ width: '100%' }} />
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
}

/** Общий каталог товаров; moderation — очередь товаров от сетей. */
export function Products({ moderation = false }: { moderation?: boolean }) {
  const [q, setQ] = useState('')
  const [category, setCategory] = useState<string>()
  const [rejecting, setRejecting] = useState<Product | null>(null)
  const [reason, setReason] = useState('')
  const approve = useAction((id: string) => api.post(`/admin/products/${id}/approve`), { success: 'Товар одобрен и добавлен в общий каталог' })
  const reject = useAction((v: { id: string; reason: string }) => api.post(`/admin/products/${v.id}/reject`, { reason: v.reason }), {
    success: 'Товар отклонён',
  })

  return (
    <>
      <CrudPage<Product>
        key={moderation ? 'moderation' : 'products'}
        title={moderation ? 'Модерация товаров' : 'Товары'}
        path="/admin/products"
        params={{ q, category_id: category, status: moderation ? 'pending' : undefined, limit: 200 }}
        canCreate={!moderation}
        createLabel="Новый товар"
        toolbar={
          <>
            <Input.Search placeholder="Название или штрихкод" allowClear onSearch={setQ} style={{ width: 240 }} />
            <RemoteSelect path="/admin/catalog/categories" placeholder="Категория" allowClear value={category} onChange={setCategory} />
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
                      <Button size="small" type="primary" onClick={() => approve.mutate(p.id)}>
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
        toForm={(p) => ({ ...p, images: p.images?.join('\n'), barcodes: p.barcodes?.join('\n') })}
        toBody={(v) => ({
          ...v,
          brand_id: v.brand_id ?? null,
          color_id: v.color_id ?? null,
          images: String(v.images ?? '')
            .split('\n')
            .map((s) => s.trim())
            .filter(Boolean),
          barcodes: String(v.barcodes ?? '')
            .split(/[\n,]/)
            .map((s) => s.trim())
            .filter(Boolean),
        })}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={[{ required: true }]}>
              <Input />
            </Form.Item>
            <Form.Item name="category_id" label="Категория" rules={[{ required: true }]}>
              <RemoteSelect path="/admin/catalog/categories" />
            </Form.Item>
            <Space wrap>
              <Form.Item name="unit_id" label="Единица" rules={[{ required: true }]}>
                <RemoteSelect path="/admin/catalog/units" style={{ width: 150 }} />
              </Form.Item>
              <Form.Item name="base_price" label="Базовая цена, сум" rules={[{ required: true }]}>
                <InputNumber min={0} style={{ width: 170 }} />
              </Form.Item>
            </Space>
            <Space wrap>
              <Form.Item name="brand_id" label="Бренд">
                <RemoteSelect path="/admin/catalog/brands" allowClear style={{ width: 200 }} />
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
            <Form.Item name="images" label="Фото (ссылки)" extra="По одной ссылке в строке">
              <Input.TextArea rows={2} />
            </Form.Item>
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
        onCancel={() => setRejecting(null)}
        onOk={() => reject.mutate({ id: rejecting!.id, reason }, { onSuccess: () => (setRejecting(null), setReason('')) })}
      >
        <Input.TextArea rows={3} placeholder="Причина — её увидит магазин" value={reason} onChange={(e) => setReason(e.target.value)} />
      </Modal>
    </>
  )
}
