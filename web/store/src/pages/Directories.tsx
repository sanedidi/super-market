// Справочники: контрагенты, типы, каталог платформы, типы цен, склады, способы оплаты, причины.
import { useState } from 'react'
import { Form, Input, Radio, Select, Switch, Tag, Typography } from 'antd'
import { ActiveTag, CrudPage, PhoneInput, RemoteSelect, formatPhone, money, phoneRule, useList } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import { EntriesTable } from './Finance'
import type { Cashbox, Counterparty, CounterpartyType, DictItem, PaymentMethod, PriceType, Reason, Warehouse } from '../types'

const required = [{ required: true, whitespace: true, message: 'Обязательное поле' }]

const activeField = (
  <Form.Item name="is_active" label="Статус">
    <Radio.Group options={[{ value: true, label: 'Активен' }, { value: false, label: 'Отключён' }]} />
  </Form.Item>
)

// ------------------------------------------------------------ контрагенты

export function CounterpartiesPage() {
  const { can } = useStore()
  const [q, setQ] = useState('')
  const manage = can('counterparties.manage')
  return (
    <CrudPage<Counterparty>
      title="Контрагенты"
      path="/store/finance/counterparties"
      canDelete
      params={{ q: q || undefined }}
      createLabel="Новый контрагент"
      canCreate={manage}
      canEdit={manage}
      toolbar={<Input.Search placeholder="Название или телефон" allowClear onSearch={setQ} style={{ width: 240 }} />}
      columns={[
        { title: 'Название', dataIndex: 'name' },
        { title: 'Тип', dataIndex: 'type_name' },
        { title: 'Телефон', dataIndex: 'phone', render: (v: string) => formatPhone(v) || '—' },
        { title: 'ИНН', dataIndex: 'inn' },
        {
          title: 'Сальдо',
          dataIndex: 'balance',
          align: 'right',
          render: (v: string) => {
            const n = Number(v)
            if (!n) return money(0)
            return (
              <Typography.Text type={n > 0 ? 'danger' : 'success'}>
                {money(Math.abs(n))} {n > 0 ? '(мы должны)' : '(должны нам)'}
              </Typography.Text>
            )
          },
        },
        { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      expandable={{
        expandedRowRender: (r) => (
          <>
            <Typography.Text strong>Акт сверки</Typography.Text>
            <EntriesTable path={`/store/finance/counterparties/${r.id}/entries`} />
          </>
        ),
      }}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={required}>
            <Input />
          </Form.Item>
          <Form.Item name="type_id" label="Тип">
            <RemoteSelect<CounterpartyType> path="/store/finance/counterparty-types" filter={(t) => t.is_active} allowClear />
          </Form.Item>
          <Form.Item name="phone" label="Телефон" rules={[phoneRule()]}>
            <PhoneInput />
          </Form.Item>
          <Form.Item name="inn" label="ИНН">
            <Input />
          </Form.Item>
          <Form.Item name="note" label="Примечание">
            <Input.TextArea rows={2} />
          </Form.Item>
          {editing && activeField}
        </>
      )}
      // Пустая строка снимает тип (очищенное поле формы — undefined).
      toBody={(v) => ({ ...v, type_id: v.type_id ?? '' })}
    />
  )
}

export function CounterpartyTypesPage() {
  return (
    <CrudPage<CounterpartyType>
      title="Типы контрагентов"
      path="/store/finance/counterparty-types"
      canDelete
      columns={[
        { title: 'Название', dataIndex: 'name' },
        { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={required}>
            <Input />
          </Form.Item>
          {editing && activeField}
        </>
      )}
    />
  )
}

// ------------------------------------------------- справочники платформы

export function DictPage({ kind, title }: { kind: 'brands' | 'colors' | 'categories' | 'units'; title: string }) {
  const all = useList<DictItem>(kind === 'categories' ? '/store/catalog/categories' : null)
  const parentName = (id?: string | null) => (id ? ((all.data ?? []).find((c) => c.id === id)?.name ?? '') : '')
  const columns = [
    { title: 'Название', dataIndex: 'name' },
    ...(kind === 'units'
      ? [
          { title: 'Кратко', dataIndex: 'short_name' },
          { title: 'Дробное', dataIndex: 'is_fractional', render: (v: boolean) => (v ? 'Да' : 'Нет') },
        ]
      : []),
    ...(kind === 'colors'
      ? [
          {
            title: 'Цвет',
            dataIndex: 'hex',
            render: (v: string) =>
              v ? (
                <Tag>
                  <span style={{ display: 'inline-block', width: 12, height: 12, background: v, borderRadius: 3, marginRight: 6, verticalAlign: -2 }} />
                  {v}
                </Tag>
              ) : (
                '—'
              ),
          },
        ]
      : []),
    ...(kind === 'categories' ? [{ title: 'Родитель', dataIndex: 'parent_id', render: (v: string | null) => parentName(v) || '—' }] : []),
  ]
  return (
    <>
      <CrudPage<DictItem> title={title} path={`/store/catalog/${kind}`} columns={columns} />
      <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
        Справочник общий для всей платформы — его ведёт администратор.
      </Typography.Paragraph>
    </>
  )
}

// -------------------------------------------------------------- типы цен

export function PriceTypesPage() {
  const { can } = useStore()
  const manage = can('catalog.manage')
  return (
    <CrudPage<PriceType>
      title="Типы цен"
      path="/store/price-types"
      canDelete={(r) => !r.is_default}
      canCreate={manage}
      canEdit={manage}
      columns={[
        { title: 'Название', dataIndex: 'name' },
        { title: 'По умолчанию', dataIndex: 'is_default', render: (v: boolean) => (v ? <Tag color="green">Да</Tag> : '') },
        { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={required}>
            <Input />
          </Form.Item>
          {editing && !editing.is_default && (
            <>
              {activeField}
              <Form.Item name="is_default" label="Сделать типом по умолчанию" valuePropName="checked">
                <Switch />
              </Form.Item>
            </>
          )}
        </>
      )}
      toForm={(r) => ({ name: r.name, is_active: r.is_active, is_default: false })}
      toBody={(v, editing) => {
        if (!editing) return { name: v.name }
        return { name: v.name, is_active: v.is_active, ...(v.is_default ? { is_default: true } : {}) }
      }}
    />
  )
}

// ----------------------------------------------------------------- склады

export function WarehousesPage() {
  const { storeId, store, can } = useStore()
  const manage = can('stores.manage')
  return (
    <NeedStore>
      <CrudPage<Warehouse>
        title={`Склады${store ? ' — ' + store.name : ''}`}
        path="/store/warehouses"
        canDelete={(r) => !r.is_default}
        params={{ store_id: storeId }}
        createLabel="Новый склад"
        canCreate={manage}
        canEdit={manage}
        columns={[
          { title: 'Название', dataIndex: 'name', render: (v: string, r) => (r.is_default ? <>{v} <Tag color="blue">По умолчанию</Tag></> : v) },
          { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={required}>
              <Input />
            </Form.Item>
            {editing && !editing.is_default && activeField}
          </>
        )}
        toBody={(v, editing) => (editing ? v : { ...v, store_id: storeId })}
      />
    </NeedStore>
  )
}

// --------------------------------------------------------- способы оплаты

export function PaymentMethodsPage() {
  const { storeId } = useStore()
  return (
    <NeedStore>
      <CrudPage<PaymentMethod>
        title="Способы оплаты"
        path="/store/finance/payment-methods"
        canDelete
        params={{ store_id: storeId }}
        createLabel="Новый способ"
        columns={[
          { title: 'Название', dataIndex: 'name' },
          { title: 'Касса', dataIndex: 'cashbox_name' },
          { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label="Название" rules={required}>
              <Input placeholder="Наличные, Терминал, Click…" />
            </Form.Item>
            <Form.Item name="cashbox_id" label="Касса, куда поступают деньги" rules={[{ required: true, message: 'Выберите кассу' }]}>
              <RemoteSelect<Cashbox>
                path="/store/finance/cashboxes"
                filter={(c) => c.is_active && c.store_id === storeId}
                label={(c) => `${c.name} (${c.currency})`}
              />
            </Form.Item>
            {editing && activeField}
          </>
        )}
      />
    </NeedStore>
  )
}

// ------------------------------------------------------ финансовые причины

export function ReasonsPage() {
  return (
    <CrudPage<Reason>
      title="Финансовые причины"
      path="/store/finance/reasons"
      canDelete
      columns={[
        { title: 'Название', dataIndex: 'name' },
        {
          title: 'Вид',
          dataIndex: 'kind',
          render: (v: string) => (v === 'income' ? <Tag color="green">Доход</Tag> : <Tag color="red">Расход</Tag>),
        },
        { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={required}>
            <Input placeholder="Аренда, зарплата, коммунальные…" />
          </Form.Item>
          <Form.Item name="kind" label="Вид" initialValue="expense" rules={[{ required: true }]}>
            <Select
              options={[
                { value: 'expense', label: 'Расход' },
                { value: 'income', label: 'Доход' },
              ]}
            />
          </Form.Item>
          {editing && activeField}
        </>
      )}
    />
  )
}
