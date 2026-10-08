import { useRef, useState, type ReactNode } from 'react'
import { Alert, Button, Card, Form, Modal, Select, Space, Table, Tag, type FormInstance, type SelectProps, type PaginationProps, type TableColumnsType, type TableProps } from 'antd'
import { LeftOutlined, PlusOutlined, RightOutlined } from '@ant-design/icons'
import { useShell } from './shell'
import { api } from './api'
import { errorText, useAction, useDebounced, useList, usePaged } from './hooks'
import { DeleteButton } from './remove'
import { tr } from './i18n'

type Params = Record<string, string | number | boolean | undefined | null>

/**
 * Шапка страницы в стиле Hamroh: белая полоса с названием (справа — общие
 * элементы оболочки: выбор магазина и т.п.), под ней панель инструментов:
 * кнопки действий слева (extra), фильтры и поиск справа (children).
 * tabs — вкладки страницы прямо под шапкой.
 */
export function PageTitle({ title, extra, children, tabs }: { title: ReactNode; extra?: ReactNode; children?: ReactNode; tabs?: ReactNode }) {
  const { headerExtra } = useShell()
  return (
    <div className="sm-page-head">
      <div className="sm-head">
        <h1 className="sm-head-title">{title}</h1>
        {headerExtra && <div className="sm-head-actions">{headerExtra}</div>}
      </div>
      {tabs}
      {(extra || children) && (
        <div className="sm-toolbar">
          {extra && <div className="sm-toolbar-left">{extra}</div>}
          {children && <div className="sm-toolbar-right">{children}</div>}
        </div>
      )}
    </div>
  )
}

/** Кнопки «Назад / Далее» в пагинации таблиц. */
export const pageItemRender: PaginationProps['itemRender'] = (_page, type, el) => {
  if (type === 'prev') return <span className="sm-page-nav"><LeftOutlined style={{ fontSize: 11 }} /> {tr('Назад', 'Orqaga')}</span>
  if (type === 'next') return <span className="sm-page-nav">{tr('Далее', 'Keyingi')} <RightOutlined style={{ fontSize: 11 }} /></span>
  return el
}

/** Ошибка загрузки с кнопкой «Повторить». */
export function LoadError({ error, retry }: { error: unknown; retry?: () => void }) {
  if (!error) return null
  return (
    <Alert
      type="error"
      showIcon
      style={{ marginBottom: 12 }}
      message={tr('Не удалось загрузить данные', 'Maʼlumotlarni yuklab boʻlmadi')}
      description={errorText(error)}
      action={retry && <Button size="small" onClick={() => retry()}>{tr('Повторить', 'Qayta urinish')}</Button>}
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
        pagination={{ ...list.pagination, itemRender: pageItemRender }}
      />
    </>
  )
}

const statusColors: Record<string, string> = {
  draft: 'overdue',
  posted: 'completed',
  active: 'completed',
  blocked: 'cancelled',
  pending: 'pending',
  approved: 'completed',
  rejected: 'cancelled',
  registered: 'completed',
  paid: 'completed',
  unpaid: 'pending',
  cancelled: 'overdue',
  expired: 'overdue',
  requested: 'info',
  refund_pending: 'pending',
  refunded: 'purple',
  awaiting_payment: 'overdue',
  accepted: 'info',
  picking: 'info',
  picked: 'info',
  delivering: 'pending',
  delivered: 'completed',
  available: 'completed',
  created: 'info',
}

const statusTitles: Record<string, string> = {
  draft: tr('Черновик', 'Qoralama'),
  posted: tr('Проведён', 'Oʻtkazilgan'),
  active: tr('Активен', 'Faol'),
  blocked: tr('Заблокирован', 'Bloklangan'),
  pending: tr('Ожидает', 'Kutilmoqda'),
  approved: tr('Одобрен', 'Maʼqullangan'),
  rejected: tr('Отклонён', 'Rad etilgan'),
  registered: tr('Чек пробит', 'Chek urilgan'),
  paid: tr('Оплачен', 'Toʻlangan'),
  unpaid: tr('Не оплачен', 'Toʻlanmagan'),
  cancelled: tr('Отменён', 'Bekor qilingan'),
  expired: tr('Истёк', 'Muddati oʻtgan'),
  requested: tr('Запрошен', 'Soʻralgan'),
  refund_pending: tr('Ждёт возврата', 'Qaytarish kutilmoqda'),
  refunded: tr('Возвращён', 'Qaytarilgan'),
  awaiting_payment: tr('Ждёт оплаты', 'Toʻlov kutilmoqda'),
  accepted: tr('Принят', 'Qabul qilindi'),
  picking: tr('Собирается', 'Yigʻilmoqda'),
  picked: tr('Собран', 'Yigʻildi'),
  delivering: tr('В пути', 'Yoʻlda'),
  delivered: tr('Доставлен', 'Yetkazildi'),
  available: tr('Доступно', 'Mavjud'),
  created: tr('Создан', 'Yaratilgan'),
}

export function StatusTag({ status, title }: { status: string; title?: string }) {
  return <Tag bordered className={`sm-status sm-status-${statusColors[status] ?? 'overdue'}`}>{title ?? statusTitles[status] ?? status}</Tag>
}

export function ActiveTag({ active }: { active: boolean }) {
  return active ? <Tag color="green">{tr('Активен', 'Faol')}</Tag> : <Tag>{tr('Отключён', 'Oʻchirilgan')}</Tag>
}

export interface CrudConfig<T> {
  title: ReactNode
  /** GET-путь списка; тот же путь для POST, `${path}/${id}` — для PATCH. */
  path: string
  params?: Params
  columns: TableColumnsType<T>
  /** Поля формы (одни для создания и правки); form — для <FormTranslate>. */
  form?: (editing: T | null, form: FormInstance) => ReactNode
  toForm?: (row: T) => Record<string, unknown>
  toBody?: (values: Record<string, unknown>, editing: T | null) => unknown
  canCreate?: boolean
  canEdit?: boolean
  createLabel?: string
  toolbar?: ReactNode
  rowKey?: string
  expandable?: Parameters<typeof Table<T>>[0]['expandable']
  /** Ширина окна формы (по умолчанию 520). */
  modalWidth?: number
  /** Вместо таблицы — свой вид списка (например, дерево товаров); получает колонки с «Изменить». */
  renderList?: (columns: TableColumnsType<T>) => ReactNode
  /** «Удалить» в строке: DELETE `${path}/${id}`; функция — для каких строк. */
  canDelete?: boolean | ((row: T) => boolean)
  /** Название строки для подтверждения (по умолчанию поле name). */
  rowName?: (row: T) => string
  /** После успешного сохранения: ответ сервера, редактируемая запись (null — новая) и значения формы. */
  onSaved?: (result: unknown, editing: T | null, values: Record<string, unknown>) => void
  /** Тело PATCH «Отключить», если запись уже используется (по умолчанию { is_active: false }; null — без кнопки). */
  deactivate?: ((row: T) => Record<string, unknown>) | null
}

/**
 * Значения формы правки из строки API: в ответах для редактирования есть сырые
 * name_ru/description_ru/… — в поле без суффикса кладём русский вариант
 * (name в ответе уже на языке запроса).
 */
export function withRawRu<T extends object>(row: T): Record<string, unknown> {
  const src = row as unknown as Record<string, unknown>
  const out: Record<string, unknown> = { ...src }
  for (const [k, v] of Object.entries(src)) {
    if (k.endsWith('_ru') && typeof v === 'string') out[k.slice(0, -3)] = v
  }
  return out
}

/** Список + модальное окно создания/правки — для справочников. */
export function CrudPage<T extends { id: string }>(cfg: CrudConfig<T>) {
  const list = usePaged<T>(cfg.renderList ? null : cfg.path, cfg.params)
  const [editing, setEditing] = useState<T | null>(null)
  const [open, setOpen] = useState(false)
  const [form] = Form.useForm()
  const save = useAction(
    (values: Record<string, unknown>) => {
      const body = cfg.toBody ? cfg.toBody(values, editing) : values
      return editing ? api.patch(`${cfg.path}/${editing.id}`, body) : api.post(cfg.path, body)
    },
    { success: tr('Сохранено', 'Saqlandi') },
  )

  const openForm = (row: T | null) => {
    setEditing(row)
    form.resetFields()
    if (row) form.setFieldsValue(cfg.toForm ? cfg.toForm(row) : withRawRu(row))
    setOpen(true)
  }

  const columns = [...cfg.columns]
  const editable = !!cfg.form && cfg.canEdit !== false
  const deletable = (row: T) => (typeof cfg.canDelete === 'function' ? cfg.canDelete(row) : !!cfg.canDelete)
  if (editable || cfg.canDelete) {
    columns.push({
      key: '_edit',
      width: cfg.canDelete ? 190 : 90,
      align: 'right',
      render: (_: unknown, row: T) => (
        <Space size={8}>
          {editable && (
            <Button size="small" onClick={() => openForm(row)}>
              {tr('Изменить', 'Tahrirlash')}
            </Button>
          )}
          {deletable(row) && (
            <DeleteButton
              path={`${cfg.path}/${row.id}`}
              name={cfg.rowName ? cfg.rowName(row) : String((row as Record<string, unknown>).name ?? '')}
              deactivate={
                cfg.deactivate === null ? undefined : () => api.patch(`${cfg.path}/${row.id}`, cfg.deactivate ? cfg.deactivate(row) : { is_active: false })
              }
            />
          )}
        </Space>
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
              {cfg.createLabel ?? tr('Добавить', 'Qoʻshish')}
            </Button>
          )
        }
      >
        {cfg.toolbar}
      </PageTitle>
      {cfg.renderList ? (
        cfg.renderList(columns)
      ) : (
        <>
          <LoadError error={list.error} retry={() => list.refetch()} />
          <Card styles={{ body: { padding: 0 } }}>
            <Table<T>
              rowKey={cfg.rowKey ?? 'id'}
              loading={list.isLoading || list.isFetching}
              dataSource={list.items}
              columns={columns}
              pagination={{ ...list.pagination, itemRender: pageItemRender }}
              scroll={{ x: true }}
              expandable={cfg.expandable}
            />
          </Card>
        </>
      )}
      {cfg.form && (
        <Modal
          open={open}
          title={editing ? tr('Изменить', 'Tahrirlash') : cfg.createLabel ?? tr('Добавить', 'Qoʻshish')}
          onCancel={() => setOpen(false)}
          onOk={() => form.submit()}
          okText={tr('Сохранить', 'Saqlash')}
          confirmLoading={save.isPending}
          width={cfg.modalWidth}
          forceRender
        >
          <Form
            form={form}
            layout="vertical"
            onFinish={(v) =>
              save.mutate(v, {
                onSuccess: (res) => {
                  setOpen(false)
                  cfg.onSaved?.(res, editing, v)
                },
              })
            }
          >
            {cfg.form(editing, form)}
          </Form>
        </Modal>
      )}
    </>
  )
}
