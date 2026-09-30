import { useRef, useState, type ReactNode } from 'react'
import { Alert, Button, Card, Flex, Form, Modal, Select, Space, Table, Tag, Typography, type SelectProps, type TableColumnsType, type TableProps } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import { api } from './api'
import { errorText, useAction, useDebounced, useList, usePaged } from './hooks'

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

/** Ошибка загрузки с кнопкой «Повторить». */
export function LoadError({ error, retry }: { error: unknown; retry?: () => void }) {
  if (!error) return null
  return (
    <Alert
      type="error"
      showIcon
      style={{ marginBottom: 12 }}
      message="Не удалось загрузить данные"
      description={errorText(error)}
      action={retry && <Button size="small" onClick={() => retry()}>Повторить</Button>}
    />
  )
}

/**
 * Выпадающий список из API ({items: [...]}).
 * search — искать на сервере по параметру q (для больших списков);
 * без него грузится до 200 записей и фильтруется в браузере.
 */
export function RemoteSelect<T extends Record<string, unknown>>({
  path,
  params,
  label = (x: T) => String(x.name ?? x.id),
  filter,
  search = false,
  selectedLabel,
  ...props
}: {
  path: string
  params?: Params
  label?: (x: T) => ReactNode
  filter?: (x: T) => boolean
  search?: boolean
  /** Подпись выбранного значения, если его нет в текущей выдаче поиска. */
  selectedLabel?: ReactNode
} & Omit<SelectProps, 'options'>) {
  const [q, setQ] = useState('')
  const debounced = useDebounced(q.trim())
  const { data, isLoading, isFetching } = useList<T>(path, search ? { ...params, q: debounced || undefined, limit: 50 } : { limit: 200, ...params })
  const options = (data ?? [])
    .filter((x) => (filter ? filter(x) : true))
    .map((x) => ({ value: String(x.id), label: label(x) }))
  // Подписи уже виденных вариантов: выбранное значение не превращается в id после нового поиска.
  const seen = useRef(new Map<string, ReactNode>())
  options.forEach((o) => seen.current.set(o.value, o.label))
  const v = props.value
  if (search && typeof v === 'string' && v && !options.some((o) => o.value === v)) {
    options.unshift({ value: v, label: seen.current.get(v) ?? selectedLabel ?? v })
  }
  return (
    <Select
      showSearch
      optionFilterProp="label"
      loading={isLoading || (search && isFetching)}
      options={options as SelectProps['options']}
      style={{ minWidth: 200 }}
      {...(search ? { filterOption: false, onSearch: setQ } : {})}
      {...props}
    />
  )
}

/** Таблица со страницами с сервера, загрузкой и ошибкой. */
export function PagedTable<T extends object>({
  path,
  params,
  pageSize = 50,
  refetchInterval,
  ...table
}: { path: string | null; params?: Params; pageSize?: number; refetchInterval?: number } & Omit<TableProps<T>, 'dataSource' | 'loading' | 'pagination'>) {
  const list = usePaged<T>(path, params, pageSize, { refetchInterval })
  return (
    <>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Table<T>
        rowKey="id"
        scroll={{ x: true }}
        {...table}
        loading={list.isLoading || list.isFetching}
        dataSource={list.items}
        pagination={list.pagination}
      />
    </>
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
  created: 'Создан',
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
  const list = usePaged<T>(cfg.path, cfg.params)
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
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<T>
          rowKey={cfg.rowKey ?? 'id'}
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          columns={columns}
          pagination={list.pagination}
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
          forceRender
        >
          <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: () => setOpen(false) })}>
            {cfg.form(editing)}
          </Form>
        </Modal>
      )}
    </>
  )
}
