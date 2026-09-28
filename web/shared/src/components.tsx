import { useState, type ReactNode } from 'react'
import { Button, Card, Flex, Form, Modal, Select, Space, Table, Tag, Typography, type SelectProps, type TableColumnsType } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import { api } from './api'
import { useAction, useList } from './hooks'

type Params = Record<string, string | number | boolean | undefined | null>

/** Заголовок страницы с кнопками справа. */
export function PageTitle({ title, extra, children }: { title: ReactNode; extra?: ReactNode; children?: ReactNode }) {
  return (
    <Flex justify="space-between" align="center" wrap gap={12} style={{ marginBottom: 16 }}>
      <Typography.Title level={3} style={{ margin: 0 }}>
        {title}
      </Typography.Title>
      <Space wrap>
        {children}
        {extra}
      </Space>
    </Flex>
  )
}

/** Выпадающий список из API ({items: [...]}) */
export function RemoteSelect<T extends Record<string, unknown>>({
  path,
  params,
  label = (x: T) => String(x.name ?? x.id),
  filter,
  ...props
}: { path: string; params?: Params; label?: (x: T) => ReactNode; filter?: (x: T) => boolean } & Omit<SelectProps, 'options'>) {
  const { data, isLoading } = useList<T>(path, params)
  const options = (data ?? [])
    .filter((x) => (filter ? filter(x) : true))
    .map((x) => ({ value: String(x.id), label: label(x) }))
  return (
    <Select
      showSearch
      optionFilterProp="label"
      loading={isLoading}
      options={options as SelectProps['options']}
      style={{ minWidth: 200 }}
      {...props}
    />
  )
}

const statusColors: Record<string, string> = {
  draft: 'default',
  posted: 'green',
  active: 'green',
  blocked: 'red',
  pending: 'orange',
  approved: 'green',
  rejected: 'red',
  registered: 'green',
  paid: 'green',
  unpaid: 'orange',
  cancelled: 'default',
  expired: 'default',
  requested: 'blue',
  refund_pending: 'orange',
  refunded: 'purple',
  awaiting_payment: 'default',
  accepted: 'blue',
  picking: 'blue',
  picked: 'cyan',
  delivering: 'geekblue',
  delivered: 'green',
}

const statusTitles: Record<string, string> = {
  draft: 'Черновик',
  posted: 'Проведён',
  active: 'Активен',
  blocked: 'Заблокирован',
  pending: 'Ожидает',
  approved: 'Одобрен',
  rejected: 'Отклонён',
  registered: 'Чек пробит',
  paid: 'Оплачен',
  unpaid: 'Не оплачен',
  cancelled: 'Отменён',
  expired: 'Истёк',
  requested: 'Запрошен',
  refund_pending: 'Ждёт возврата',
  refunded: 'Возвращён',
  awaiting_payment: 'Ждёт оплаты',
  accepted: 'Принят',
  picking: 'Собирается',
  picked: 'Собран',
  delivering: 'В пути',
  delivered: 'Доставлен',
  available: 'Доступно',
}

export function StatusTag({ status, title }: { status: string; title?: string }) {
  return <Tag color={statusColors[status] ?? 'default'}>{title ?? statusTitles[status] ?? status}</Tag>
}

export function ActiveTag({ active }: { active: boolean }) {
  return active ? <Tag color="green">Активен</Tag> : <Tag>Отключён</Tag>
}

export interface CrudConfig<T> {
  title: ReactNode
  /** GET-путь списка; тот же путь для POST, `${path}/${id}` — для PATCH. */
  path: string
  params?: Params
  columns: TableColumnsType<T>
  /** Поля формы (одни для создания и правки). */
  form?: (editing: T | null) => ReactNode
  toForm?: (row: T) => Record<string, unknown>
  toBody?: (values: Record<string, unknown>, editing: T | null) => unknown
  canCreate?: boolean
  canEdit?: boolean
  createLabel?: string
  toolbar?: ReactNode
  rowKey?: string
  expandable?: Parameters<typeof Table<T>>[0]['expandable']
}

/** Список + модальное окно создания/правки — для справочников. */
export function CrudPage<T extends { id: string }>(cfg: CrudConfig<T>) {
  const { data, isLoading } = useList<T>(cfg.path, cfg.params)
  const [editing, setEditing] = useState<T | null>(null)
  const [open, setOpen] = useState(false)
  const [form] = Form.useForm()
  const save = useAction(
    (values: Record<string, unknown>) => {
      const body = cfg.toBody ? cfg.toBody(values, editing) : values
      return editing ? api.patch(`${cfg.path}/${editing.id}`, body) : api.post(cfg.path, body)
    },
    { success: 'Сохранено' },
  )

  const openForm = (row: T | null) => {
    setEditing(row)
    form.resetFields()
    if (row) form.setFieldsValue(cfg.toForm ? cfg.toForm(row) : row)
    setOpen(true)
  }

  const columns = [...cfg.columns]
  if (cfg.form && cfg.canEdit !== false) {
    columns.push({
      key: '_edit',
      width: 90,
      render: (_: unknown, row: T) => (
        <Button size="small" onClick={() => openForm(row)}>
          Изменить
        </Button>
      ),
    })
  }

  return (
    <>
      <PageTitle
        title={cfg.title}
        extra={
          cfg.form &&
          cfg.canCreate !== false && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => openForm(null)}>
              {cfg.createLabel ?? 'Добавить'}
            </Button>
          )
        }
      >
        {cfg.toolbar}
      </PageTitle>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<T>
          rowKey={cfg.rowKey ?? 'id'}
          loading={isLoading}
          dataSource={data}
          columns={columns}
          pagination={{ pageSize: 50, hideOnSinglePage: true }}
          scroll={{ x: true }}
          expandable={cfg.expandable}
        />
      </Card>
      {cfg.form && (
        <Modal
          open={open}
          title={editing ? 'Изменить' : cfg.createLabel ?? 'Добавить'}
          onCancel={() => setOpen(false)}
          onOk={() => form.submit()}
          okText="Сохранить"
          confirmLoading={save.isPending}
          destroyOnClose
        >
          <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: () => setOpen(false) })}>
            {cfg.form(editing)}
          </Form>
        </Modal>
      )}
    </>
  )
}
