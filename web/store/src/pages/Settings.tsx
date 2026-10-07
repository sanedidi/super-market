// Настройки: магазины, роли, сотрудники.
import { useState } from 'react'
import { Alert, Button, Card, Checkbox, Form, Input, Modal, Radio, Select, Space, Switch, Table, Tag, Typography } from 'antd'
import { LockOutlined, PlusOutlined } from '@ant-design/icons'
import { CrudPage, DeleteButton, ImageUpload, MapPointPicker, PageTitle, PhoneInput, RemoteSelect, StatusTag, api, formatPhone, phoneRule, tr, useAction, useList, type LatLng } from '@sm/shared'
import { useStore } from '../ctx'
import { EmployeeLoginModal } from './EmployeeLogin'
import type { Employee, Permission, PriceType, Role, Store, Warehouse } from '../types'

const required = [{ required: true, whitespace: true, message: tr('Обязательное поле', 'Majburiy maydon') }]

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
      onCity={(c) => form.setFieldValue('city', c)}
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
        <Alert type="info" showIcon style={{ marginBottom: 16 }} message={tr('Сеть с одним магазином: создать второй магазин нельзя.', 'Bitta doʻkonli tarmoq: ikkinchi doʻkon yaratib boʻlmaydi.')} />
      )}
      <CrudPage<Store>
        title={tr('Магазины', 'Doʻkonlar')}
        path="/store/stores"
        modalWidth={640}
        createLabel={tr('Новый магазин', 'Yangi doʻkon')}
        canCreate={canCreate}
        columns={[
          { title: tr('Название', 'Nomi'), dataIndex: 'name' },
          { title: tr('Адрес', 'Manzil'), dataIndex: 'address' },
          { title: tr('Телефон', 'Telefon'), dataIndex: 'phone', render: (v: string) => formatPhone(v) || '—' },
          {
            title: tr('Точка', 'Joylashuv'),
            key: 'geo',
            render: (_, r) => (r.lat !== null && r.lng !== null ? <Tag color="green">{tr('На карте', 'Xaritada')}</Tag> : <Tag color="orange">{tr('Не указана', 'Koʻrsatilmagan')}</Tag>),
          },
          {
            title: tr('Статус', 'Holat'),
            dataIndex: 'status',
            render: (v: string) => (v === 'active' ? <StatusTag status="active" /> : <Tag>{tr('Закрыт', 'Yopilgan')}</Tag>),
          },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
              <Input />
            </Form.Item>
            <Form.Item name="address" label={tr('Адрес', 'Manzil')}>
              <Input />
            </Form.Item>
            <Form.Item
              name="city"
              label={tr('Город', 'Shahar')}
              extra={tr(
                'Заполняется по точке на карте. Нужен, чтобы бренды могли рекламироваться в вашем городе.',
                'Xaritadagi joylashuv boʻyicha toʻldiriladi. Brendlar shahringizda reklama qila olishi uchun kerak.',
              )}
            >
              <Input placeholder={tr('Ташкент', 'Toshkent')} />
            </Form.Item>
            <Form.Item name="phone" label={tr('Телефон', 'Telefon')} rules={[phoneRule()]}>
              <PhoneInput />
            </Form.Item>
            {editing && (
              <Form.Item name="logo_url" label={tr('Логотип для приложения', 'Ilova uchun logotip')} extra={tr('Квадратная картинка, JPG или PNG', 'Kvadrat rasm, JPG yoki PNG')}>
                <ImageUpload hint={tr('Логотип', 'Logotip')} />
              </Form.Item>
            )}
            <Form.Item
              name="geo"
              label={tr('Точка магазина на карте', 'Doʻkonning xaritadagi joylashuvi')}
              extra={tr(
                'Нажмите на карту, найдите адрес через поиск или перетащите метку. Нужна для онлайн-заказов',
                'Xaritani bosing, manzilni qidiruv orqali toping yoki belgini suring. Onlayn buyurtmalar uchun kerak',
              )}
            >
              <StorePoint />
            </Form.Item>
            {editing && (
              <>
                <Form.Item name="default_warehouse_id" label={tr('Склад по умолчанию', 'Standart ombor')}>
                  <RemoteSelect<Warehouse> path="/store/warehouses" params={{ store_id: editing.id }} filter={(w) => w.is_active} />
                </Form.Item>
                <Form.Item
                  name="online_price_type_id"
                  label={tr('Тип цены для приложения', 'Ilova uchun narx turi')}
                  extra={tr('Если не выбран — тип цены сети по умолчанию', 'Tanlanmasa — tarmoqning standart narx turi')}
                >
                  <RemoteSelect<PriceType> path="/store/price-types" filter={(t) => t.is_active} allowClear />
                </Form.Item>
                <Form.Item name="status" label={tr('Статус', 'Holat')}>
                  <Radio.Group
                    options={[
                      { value: 'active', label: tr('Работает', 'Ishlamoqda') },
                      { value: 'inactive', label: tr('Закрыт', 'Yopilgan') },
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
          city: r.city,
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
          const base = { name: v.name, address: v.address ?? '', city: v.city ?? '', phone: v.phone ?? '', ...geo }
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
    { success: tr('Роль сохранена', 'Rol saqlandi') },
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
        title={tr('Роли', 'Rollar')}
        extra={
          <Button type="primary" icon={<PlusOutlined />} onClick={() => openForm(null)}>
            {tr('Новая роль', 'Yangi rol')}
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
            { title: tr('Роль', 'Rol'), dataIndex: 'name', render: (v: string, r) => (r.is_owner ? <>{v} <Tag color="gold">{tr('Владелец', 'Egasi')}</Tag></> : v) },
            {
              title: tr('Права', 'Huquqlar'),
              dataIndex: 'permissions',
              render: (v: string[] | null, r) =>
                r.is_owner ? (
                  <Typography.Text type="secondary">{tr('Все права', 'Barcha huquqlar')}</Typography.Text>
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
              width: 190,
              align: 'right',
              render: (_, r) =>
                !r.is_owner && (
                  <Space size={8}>
                    <Button size="small" onClick={() => openForm(r)}>
                      {tr('Изменить', 'Tahrirlash')}
                    </Button>
                    <DeleteButton path={`/store/roles/${r.id}`} name={r.name} />
                  </Space>
                ),
            },
          ]}
        />
      </Card>
      <Modal
        open={open}
        title={editing ? tr('Изменить роль', 'Rolni tahrirlash') : tr('Новая роль', 'Yangi rol')}
        okText={tr('Сохранить', 'Saqlash')}
        onOk={() => form.submit()}
        confirmLoading={save.isPending}
        onCancel={() => setOpen(false)}
        width={560}
      >
        <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: () => setOpen(false) })}>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
            <Input placeholder={tr('Кассир, кладовщик…', 'Kassir, omborchi…')} />
          </Form.Item>
          <Form.Item name="permissions" label={tr('Права', 'Huquqlar')}>
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
  const { stores, can } = useStore()
  const [loginFor, setLoginFor] = useState<Employee | null>(null)
  const visible = (id: string) => stores.some((s) => s.id === id)
  const storeName = (id: string) => stores.find((s) => s.id === id)?.name
  const storesText = (ids: string[]) => {
    const names = ids.map(storeName).filter(Boolean)
    const hidden = ids.length - names.length
    return [...names, ...(hidden ? [tr(`ещё ${hidden} (нет доступа)`, `yana ${hidden} ta (ruxsat yoʻq)`)] : [])].join(', ') || '—'
  }
  return (
    <>
      <CrudPage<Employee>
        title={tr('Сотрудники', 'Xodimlar')}
        path="/store/employees"
        canDelete={(r) => !r.is_owner}
        rowName={(r) => r.full_name}
        deactivate={() => ({ status: 'inactive' })}
        createLabel={tr('Новый сотрудник', 'Yangi xodim')}
        columns={[
          { title: tr('Имя', 'Ism'), dataIndex: 'full_name', render: (v: string, r) => (r.is_owner ? <>{v} <Tag color="gold">{tr('Владелец', 'Egasi')}</Tag></> : v) },
          { title: tr('Телефон', 'Telefon'), dataIndex: 'phone', render: (v: string) => formatPhone(v) || '—' },
          { title: tr('Роль', 'Rol'), dataIndex: 'role_name' },
          {
            title: tr('Магазины', 'Doʻkonlar'),
            key: 'stores',
            render: (_, r) => (r.all_stores ? tr('Все магазины', 'Barcha doʻkonlar') : storesText(r.store_ids ?? [])),
          },
          {
            title: tr('Статус', 'Holat'),
            dataIndex: 'status',
            render: (v: string) => (v === 'active' ? <StatusTag status="active" /> : <Tag>{tr('Отключён', 'Oʻchirilgan')}</Tag>),
          },
          {
            title: tr('Вход', 'Kirish'),
            key: 'login',
            render: (_, r) => (
              <Space direction="vertical" size={2}>
                {r.login ? (
                  <span>
                    <b>{r.login}</b>
                    {r.temp_password && <Tag style={{ marginLeft: 6 }}>{tr('временный пароль', 'vaqtinchalik parol')}</Tag>}
                  </span>
                ) : (
                  <Typography.Text type="secondary">{tr('нет входа', 'kirish yoʻq')}</Typography.Text>
                )}
                {r.is_owner ? (
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {tr('меняет Super Market', 'Super Market oʻzgartiradi')}
                  </Typography.Text>
                ) : (
                  can('staff.manage') &&
                  r.status === 'active' && (
                    <Button size="small" icon={<LockOutlined />} onClick={() => setLoginFor(r)}>
                      {r.login ? tr('Логин и пароль', 'Login va parol') : tr('Выдать логин', 'Login berish')}
                    </Button>
                  )
                )}
              </Space>
            ),
          },
        ]}
        onSaved={(res, editing) => {
          // Новому сотруднику сразу предлагаем выдать логин.
          if (!editing) setLoginFor(res as Employee)
        }}
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
      <EmployeeLoginModal employee={loginFor} onClose={() => setLoginFor(null)} />
    </>
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
        <Form.Item
          name="phone"
          label={tr('Телефон', 'Telefon')}
          rules={[phoneRule(true)]}
          extra={tr(
            'Для связи. В панель сотрудник входит по логину и паролю — выдадите после сохранения',
            'Aloqa uchun. Xodim panelga login va parol bilan kiradi — ularni saqlagandan keyin berasiz',
          )}
        >
          <PhoneInput />
        </Form.Item>
      )}
      <Form.Item name="full_name" label={tr('Имя', 'Ism')} rules={required}>
        <Input />
      </Form.Item>
      <Form.Item name="role_id" label={tr('Роль', 'Rol')} rules={[{ required: true, message: tr('Выберите роль', 'Rolni tanlang') }]}>
        <RemoteSelect<Role> path="/store/roles" disabled={editing?.is_owner} filter={(r) => !r.is_owner || !!editing?.is_owner} />
      </Form.Item>
      <Form.Item name="all_stores" label={tr('Доступ ко всем магазинам', 'Barcha doʻkonlarga ruxsat')} valuePropName="checked" initialValue={false}>
        <Switch disabled={editing?.is_owner || !seesAll} />
      </Form.Item>
      {!all && !editing?.is_owner && (
        <Form.Item
          name="store_ids"
          label={tr('Магазины', 'Doʻkonlar')}
          rules={[{ required: !hidden, message: tr('Выберите магазины', 'Doʻkonlarni tanlang') }]}
          extra={
            hidden
              ? tr(`Ещё магазинов, к которым у вас нет доступа: ${hidden}. Они сохранятся.`, `Sizda ruxsat boʻlmagan yana ${hidden} ta doʻkon bor. Ular saqlanib qoladi.`)
              : undefined
          }
        >
          <Select mode="multiple" options={stores.map((s) => ({ value: s.id, label: s.name }))} />
        </Form.Item>
      )}
      {editing && !editing.is_owner && (
        <Form.Item name="status" label={tr('Статус', 'Holat')}>
          <Radio.Group
            options={[
              { value: 'active', label: tr('Активен', 'Faol') },
              { value: 'inactive', label: tr('Отключён', 'Oʻchirilgan') },
            ]}
          />
        </Form.Item>
      )}
    </>
  )
}
