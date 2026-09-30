// Настройки: магазины, роли, сотрудники.
import { useState } from 'react'
import { Alert, Button, Card, Checkbox, Form, Input, Modal, Radio, Select, Switch, Table, Tag, Typography } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import { CrudPage, ImageUpload, MapPointPicker, PageTitle, RemoteSelect, StatusTag, api, useAction, useList, type LatLng } from '@sm/shared'
import { useStore } from '../ctx'
import type { Employee, Permission, PriceType, Role, Store, Warehouse } from '../types'

const required = [{ required: true, whitespace: true, message: 'Обязательное поле' }]

// ---------------------------------------------------------------- магазины

/** Точка магазина; пустой адрес заполняется адресом с карты. */
function StorePoint({ value, onChange }: { value?: LatLng | null; onChange?: (v: LatLng | null) => void }) {
  const form = Form.useFormInstance()
  return (
    <MapPointPicker
      value={value}
      onChange={onChange}
      onAddress={(a) => {
        if (!String(form.getFieldValue('address') ?? '').trim()) form.setFieldValue('address', a)
      }}
    />
  )
}

export function StoresPage() {
  const { me, stores, storesLoading, can } = useStore()
  const single = me?.network.kind === 'single'
  // У одиночной сети магазин только один; новый магазин увидит лишь тот, кто видит все магазины.
  const seesAll = !!me && (me.is_owner || me.all_stores)
  const canCreate = can('stores.manage') && seesAll && !storesLoading && !(single && stores.length > 0)
  return (
    <>
      {single && stores.length > 0 && (
        <Alert type="info" showIcon style={{ marginBottom: 16 }} message="Сеть с одним магазином: создать второй магазин нельзя." />
      )}
      <CrudPage<Store>
        title="Магазины"
        path="/store/stores"
        modalWidth={640}
        createLabel="Новый магазин"
        canCreate={canCreate}
        columns={[
          { title: 'Название', dataIndex: 'name' },
          { title: 'Адрес', dataIndex: 'address' },
          { title: 'Телефон', dataIndex: 'phone' },
          {
            title: 'Точка',
            key: 'geo',
            render: (_, r) => (r.lat !== null && r.lng !== null ? <Tag color="green">На карте</Tag> : <Tag color="orange">Не указана</Tag>),
          },
          { title: 'Статус', dataIndex: 'status', render: (v: string) => (v === 'active' ? <StatusTag status="active" /> : <Tag>Закрыт</Tag>) },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={required}>
              <Input />
            </Form.Item>
            <Form.Item name="address" label="Адрес">
              <Input />
            </Form.Item>
            <Form.Item name="phone" label="Телефон">
              <Input placeholder="+998 …" />
            </Form.Item>
            {editing && (
              <Form.Item name="logo_url" label="Логотип для приложения" extra="Квадратная картинка, JPG или PNG">
                <ImageUpload hint="Логотип" />
              </Form.Item>
            )}
            <Form.Item name="geo" label="Точка магазина на карте" extra="Нажмите на карту, найдите адрес через поиск или перетащите метку. Нужна для онлайн-заказов">
              <StorePoint />
            </Form.Item>
            {editing && (
              <>
                <Form.Item name="default_warehouse_id" label="Склад по умолчанию">
                  <RemoteSelect<Warehouse> path="/store/warehouses" params={{ store_id: editing.id }} filter={(w) => w.is_active} />
                </Form.Item>
                <Form.Item name="online_price_type_id" label="Тип цены для приложения" extra="Если не выбран — тип цены сети по умолчанию">
                  <RemoteSelect<PriceType> path="/store/price-types" filter={(t) => t.is_active} allowClear />
                </Form.Item>
                <Form.Item name="status" label="Статус">
                  <Radio.Group
                    options={[
                      { value: 'active', label: 'Работает' },
                      { value: 'inactive', label: 'Закрыт' },
                    ]}
                  />
                </Form.Item>
              </>
            )}
          </>
        )}
        toForm={(r) => ({
          name: r.name,
          address: r.address,
          phone: r.phone,
          geo: r.lat !== null && r.lng !== null ? { lat: r.lat, lng: r.lng } : null,
          status: r.status,
          logo_url: r.logo_url,
          default_warehouse_id: r.default_warehouse_id ?? undefined,
          online_price_type_id: r.online_price_type_id ?? undefined,
        })}
        toBody={(v, editing) => {
          const p = v.geo as LatLng | null | undefined
          const geo = p ? { lat: p.lat, lng: p.lng } : {}
          const base = { name: v.name, address: v.address ?? '', phone: v.phone ?? '', ...geo }
          if (!editing) return base
          return {
            ...base,
            status: v.status,
            logo_url: v.logo_url ?? '',
            default_warehouse_id: v.default_warehouse_id || undefined,
            // пустая строка сбрасывает тип цены
            online_price_type_id: v.online_price_type_id ?? '',
          }
        }}
      />
    </>
  )
}

// ------------------------------------------------------------------- роли

export function RolesPage() {
  const { data, isLoading } = useList<Role>('/store/roles')
  const perms = useList<Permission>('/store/permissions')
  const title = (code: string) => perms.data?.find((p) => p.code === code)?.title ?? code
  const [editing, setEditing] = useState<Role | null>(null)
  const [open, setOpen] = useState(false)
  const [form] = Form.useForm<{ name: string; permissions: string[] }>()
  const save = useAction(
    (v: { name: string; permissions: string[] }) =>
      editing ? api.patch(`/store/roles/${editing.id}`, v) : api.post('/store/roles', { ...v, permissions: v.permissions ?? [] }),
    { success: 'Роль сохранена' },
  )
  const openForm = (r: Role | null) => {
    setEditing(r)
    form.resetFields()
    if (r) form.setFieldsValue({ name: r.name, permissions: r.permissions ?? [] })
    setOpen(true)
  }
  return (
    <>
      <PageTitle
        title="Роли"
        extra={
          <Button type="primary" icon={<PlusOutlined />} onClick={() => openForm(null)}>
            Новая роль
          </Button>
        }
      />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Role>
          rowKey="id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          pagination={false}
          columns={[
            { title: 'Роль', dataIndex: 'name', render: (v: string, r) => (r.is_owner ? <>{v} <Tag color="gold">Владелец</Tag></> : v) },
            {
              title: 'Права',
              dataIndex: 'permissions',
              render: (v: string[] | null, r) =>
                r.is_owner ? (
                  <Typography.Text type="secondary">Все права</Typography.Text>
                ) : (
                  (v ?? []).map((c) => (
                    <Tag key={c} style={{ marginBottom: 4 }}>
                      {title(c)}
                    </Tag>
                  ))
                ),
            },
            {
              key: 'e',
              width: 90,
              render: (_, r) =>
                !r.is_owner && (
                  <Button size="small" onClick={() => openForm(r)}>
                    Изменить
                  </Button>
                ),
            },
          ]}
        />
      </Card>
      <Modal
        open={open}
        title={editing ? 'Изменить роль' : 'Новая роль'}
        okText="Сохранить"
        onOk={() => form.submit()}
        confirmLoading={save.isPending}
        onCancel={() => setOpen(false)}
        width={560}
      >
        <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: () => setOpen(false) })}>
          <Form.Item name="name" label="Название" rules={required}>
            <Input placeholder="Кассир, кладовщик…" />
          </Form.Item>
          <Form.Item name="permissions" label="Права">
            <Checkbox.Group style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {(perms.data ?? []).map((p) => (
                <Checkbox key={p.code} value={p.code}>
                  {p.title}
                </Checkbox>
              ))}
            </Checkbox.Group>
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}

// -------------------------------------------------------------- сотрудники

export function EmployeesPage() {
  const { stores } = useStore()
  const visible = (id: string) => stores.some((s) => s.id === id)
  const storeName = (id: string) => stores.find((s) => s.id === id)?.name
  const storesText = (ids: string[]) => {
    const names = ids.map(storeName).filter(Boolean)
    const hidden = ids.length - names.length
    return [...names, ...(hidden ? [`ещё ${hidden} (нет доступа)`] : [])].join(', ') || '—'
  }
  return (
    <CrudPage<Employee>
      title="Сотрудники"
      path="/store/employees"
      createLabel="Новый сотрудник"
      columns={[
        { title: 'Имя', dataIndex: 'full_name', render: (v: string, r) => (r.is_owner ? <>{v} <Tag color="gold">Владелец</Tag></> : v) },
        { title: 'Телефон', dataIndex: 'phone' },
        { title: 'Роль', dataIndex: 'role_name' },
        {
          title: 'Магазины',
          key: 'stores',
          render: (_, r) => (r.all_stores ? 'Все магазины' : storesText(r.store_ids ?? [])),
        },
        { title: 'Статус', dataIndex: 'status', render: (v: string) => (v === 'active' ? <StatusTag status="active" /> : <Tag>Отключён</Tag>) },
      ]}
      form={(editing) => <EmployeeFields editing={editing} />}
      toForm={(r) => ({
        full_name: r.full_name,
        role_id: r.role_id,
        all_stores: r.all_stores,
        // В форме — только видимые магазины; остальные сервер сохранит сам.
        store_ids: (r.store_ids ?? []).filter(visible),
        status: r.status,
      })}
      toBody={(v, editing) => {
        // У владельца сервер разрешает менять только имя.
        if (editing?.is_owner) return { full_name: v.full_name }
        const body: Record<string, unknown> = {
          full_name: v.full_name,
          role_id: v.role_id,
          all_stores: !!v.all_stores,
          store_ids: v.all_stores ? [] : (v.store_ids ?? []),
        }
        if (editing) body.status = v.status
        else body.phone = v.phone
        return body
      }}
    />
  )
}

function EmployeeFields({ editing }: { editing: Employee | null }) {
  const { stores, me } = useStore()
  const form = Form.useFormInstance()
  const all = Form.useWatch('all_stores', form)
  // Доступ ко всем магазинам выдаёт только тот, кто сам их видит.
  const seesAll = !!me && (me.is_owner || me.all_stores)
  const hidden = editing && !editing.all_stores ? (editing.store_ids ?? []).filter((id) => !stores.some((s) => s.id === id)).length : 0
  return (
    <>
      {!editing && (
        <Form.Item name="phone" label="Телефон" rules={required} extra="Сотрудник войдёт по этому номеру через Telegram-бот">
          <Input placeholder="+998 90 123 45 67" inputMode="tel" />
        </Form.Item>
      )}
      <Form.Item name="full_name" label="Имя" rules={required}>
        <Input />
      </Form.Item>
      <Form.Item name="role_id" label="Роль" rules={[{ required: true, message: 'Выберите роль' }]}>
        <RemoteSelect<Role> path="/store/roles" disabled={editing?.is_owner} filter={(r) => !r.is_owner || !!editing?.is_owner} />
      </Form.Item>
      <Form.Item name="all_stores" label="Доступ ко всем магазинам" valuePropName="checked" initialValue={false}>
        <Switch disabled={editing?.is_owner || !seesAll} />
      </Form.Item>
      {!all && !editing?.is_owner && (
        <Form.Item
          name="store_ids"
          label="Магазины"
          rules={[{ required: !hidden, message: 'Выберите магазины' }]}
          extra={hidden ? `Ещё магазинов, к которым у вас нет доступа: ${hidden}. Они сохранятся.` : undefined}
        >
          <Select mode="multiple" options={stores.map((s) => ({ value: s.id, label: s.name }))} />
        </Form.Item>
      )}
      {editing && !editing.is_owner && (
        <Form.Item name="status" label="Статус">
          <Radio.Group
            options={[
              { value: 'active', label: 'Активен' },
              { value: 'inactive', label: 'Отключён' },
            ]}
          />
        </Form.Item>
      )}
    </>
  )
}
