// Товары: общий каталог платформы + свои товары сети (через модерацию).
import { useState } from 'react'
import { Alert, Button, Card, Col, Form, Input, Modal, Radio, Row, Select, Table, Tag, Tooltip, Typography } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import { PageTitle, RemoteSelect, api, money, useAction, useList } from '@sm/shared'
import { useStore } from '../ctx'
import { Num } from '../ui'
import type { DictItem, Product } from '../types'

function Moderation({ p }: { p: Product }) {
  if (!p.network_id) return <Tag color="green">Общий каталог</Tag>
  if (p.moderation_status === 'pending') return <Tag color="orange">На модерации</Tag>
  if (p.moderation_status === 'rejected')
    return (
      <Tooltip title={p.rejection_reason}>
        <Tag color="red">Отклонён</Tag>
      </Tooltip>
    )
  return <Tag color="blue">Свой</Tag>
}

const priceSource: Record<string, string> = { store: 'магазин', network: 'сеть', base: 'базовая' }

export function ProductsPage() {
  const { storeId, can } = useStore()
  const [q, setQ] = useState('')
  const [categoryId, setCategoryId] = useState<string>()
  const [editing, setEditing] = useState<Product | null>(null)
  const [open, setOpen] = useState(false)
  const { data, isLoading } = useList<Product>('/store/products', {
    q,
    category_id: categoryId,
    store_id: storeId || undefined,
    limit: 200,
  })
  const manage = can('catalog.manage')

  return (
    <>
      <PageTitle
        title="Товары"
        extra={
          manage && (
            <Button
              type="primary"
              icon={<PlusOutlined />}
              onClick={() => {
                setEditing(null)
                setOpen(true)
              }}
            >
              Свой товар
            </Button>
          )
        }
      >
        <Input.Search placeholder="Название или штрихкод" allowClear onSearch={setQ} style={{ width: 240 }} />
        <RemoteSelect<DictItem> path="/store/catalog/categories" value={categoryId} onChange={setCategoryId} allowClear placeholder="Все категории" />
      </PageTitle>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Product>
          rowKey="id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          pagination={{ pageSize: 50, hideOnSinglePage: true }}
          columns={[
            {
              title: 'Товар',
              dataIndex: 'name',
              render: (v: string, r) => (
                <>
                  {v}
                  {r.brand_name && <Typography.Text type="secondary"> · {r.brand_name}</Typography.Text>}
                  {!r.is_active && <Tag style={{ marginLeft: 6 }}>Отключён</Tag>}
                </>
              ),
            },
            { title: 'Штрихкод', dataIndex: 'barcodes', render: (v: string[] | null) => (v ?? []).join(', ') || '—' },
            { title: 'Категория', dataIndex: 'category_name' },
            { title: 'Ед.', dataIndex: 'unit_short' },
            { title: 'Базовая цена', dataIndex: 'base_price', align: 'right', render: (v: string) => money(v) },
            {
              title: 'Цена в магазине',
              dataIndex: 'price',
              align: 'right',
              render: (v: string | undefined, r) =>
                v ? (
                  <>
                    {money(v)}
                    {r.price_source && <Typography.Text type="secondary"> ({priceSource[r.price_source] ?? r.price_source})</Typography.Text>}
                  </>
                ) : (
                  '—'
                ),
            },
            { title: 'Каталог', key: 'mod', render: (_, r) => <Moderation p={r} /> },
            {
              key: 'edit',
              width: 90,
              render: (_, r) =>
                manage && r.network_id ? (
                  <Button
                    size="small"
                    onClick={() => {
                      setEditing(r)
                      setOpen(true)
                    }}
                  >
                    Изменить
                  </Button>
                ) : null,
            },
          ]}
        />
      </Card>
      <ProductModal open={open} editing={editing} onClose={() => setOpen(false)} />
    </>
  )
}

function ProductModal({ open, editing, onClose }: { open: boolean; editing: Product | null; onClose: () => void }) {
  const [form] = Form.useForm()
  const save = useAction(
    (v: Record<string, unknown>) => {
      const body = {
        ...v,
        description: v.description ?? '',
        brand_id: v.brand_id ?? undefined,
        color_id: v.color_id ?? undefined,
        barcodes: v.barcodes ?? [],
        images: v.images ?? [],
      }
      return editing ? api.patch(`/store/products/${editing.id}`, body) : api.post('/store/products', body)
    },
    { success: editing ? 'Сохранено' : 'Товар отправлен на модерацию' },
  )
  return (
    <Modal
      open={open}
      title={editing ? 'Изменить товар' : 'Свой товар'}
      okText="Сохранить"
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      width={720}
      destroyOnHidden
      afterOpenChange={(v) => {
        if (!v) return
        form.resetFields()
        if (editing)
          form.setFieldsValue({
            name: editing.name,
            description: editing.description,
            brand_id: editing.brand_id ?? undefined,
            category_id: editing.category_id,
            unit_id: editing.unit_id,
            color_id: editing.color_id ?? undefined,
            base_price: editing.base_price,
            barcodes: editing.barcodes ?? [],
            images: editing.images ?? [],
            is_active: editing.is_active,
          })
      }}
    >
      {!editing && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message="Товар сразу доступен вашей сети, а после проверки администратором попадёт в общий каталог."
        />
      )}
      {editing?.moderation_status === 'rejected' && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message={`Отклонён: ${editing.rejection_reason}`}
          description="После сохранения товар снова уйдёт на модерацию."
        />
      )}
      <Form form={form} layout="vertical" preserve={false} onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Row gutter={16}>
          <Col xs={24} md={16}>
            <Form.Item name="name" label="Название" rules={[{ required: true, whitespace: true, message: 'Обязательное поле' }]}>
              <Input />
            </Form.Item>
          </Col>
          <Col xs={24} md={8}>
            <Form.Item name="base_price" label="Базовая цена" rules={[{ required: true, message: 'Укажите цену' }]}>
              <Num />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="category_id" label="Категория" rules={[{ required: true, message: 'Выберите категорию' }]}>
              <RemoteSelect<DictItem> path="/store/catalog/categories" />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="unit_id" label="Единица" rules={[{ required: true, message: 'Выберите единицу' }]}>
              <RemoteSelect<DictItem> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="brand_id" label="Бренд">
              <RemoteSelect<DictItem> path="/store/catalog/brands" allowClear />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="color_id" label="Цвет">
              <RemoteSelect<DictItem> path="/store/catalog/colors" allowClear />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="barcodes" label="Штрихкоды" extra="Введите и нажмите Enter">
              <Select mode="tags" tokenSeparators={[',', ' ']} open={false} />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="images" label="Ссылки на фото">
              <Select mode="tags" tokenSeparators={[' ']} open={false} placeholder="https://…" />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="description" label="Описание">
              <Input.TextArea rows={3} />
            </Form.Item>
          </Col>
          {editing && (
            <Col span={24}>
              <Form.Item name="is_active" label="Статус">
                <Radio.Group options={[{ value: true, label: 'Активен' }, { value: false, label: 'Отключён' }]} />
              </Form.Item>
            </Col>
          )}
        </Row>
      </Form>
    </Modal>
  )
}
