// Справочники: контрагенты, типы, каталог платформы, типы цен, склады, способы оплаты, причины.
import { useState } from 'react'
import { Form, Input, Radio, Select, Switch, Tag, Typography } from 'antd'
import { ActiveTag, CrudPage, PhoneInput, RemoteSelect, formatPhone, money, phoneRule, tr, useList } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import { EntriesTable } from './Finance'
import type { Cashbox, Counterparty, CounterpartyType, DictItem, PaymentMethod, PriceType, Reason, Warehouse } from '../types'

const required = [{ required: true, whitespace: true, message: tr('Обязательное поле', 'Majburiy maydon') }]

const activeField = (
  <Form.Item name="is_active" label={tr('Статус', 'Holat')}>
    <Radio.Group
      options={[
        { value: true, label: tr('Активен', 'Faol') },
        { value: false, label: tr('Отключён', 'Oʻchirilgan') },
      ]}
    />
  </Form.Item>
)

// ------------------------------------------------------------ контрагенты

export function CounterpartiesPage() {
  const { can } = useStore()
  const [q, setQ] = useState('')
  const manage = can('counterparties.manage')
  return (
    <CrudPage<Counterparty>
      title={tr('Контрагенты', 'Kontragentlar')}
      path="/store/finance/counterparties"
      canDelete
      params={{ q: q || undefined }}
      createLabel={tr('Новый контрагент', 'Yangi kontragent')}
      canCreate={manage}
      canEdit={manage}
      toolbar={<Input.Search placeholder={tr('Название или телефон', 'Nomi yoki telefon')} allowClear onSearch={setQ} style={{ width: 240 }} />}
      columns={[
        { title: tr('Название', 'Nomi'), dataIndex: 'name' },
        { title: tr('Тип', 'Turi'), dataIndex: 'type_name' },
        { title: tr('Телефон', 'Telefon'), dataIndex: 'phone', render: (v: string) => formatPhone(v) || '—' },
        { title: tr('ИНН', 'STIR'), dataIndex: 'inn' },
        {
          title: tr('Сальдо', 'Saldo'),
          dataIndex: 'balance',
          align: 'right',
          render: (v: string) => {
            const n = Number(v)
            if (!n) return money(0)
            return (
              <Typography.Text type={n > 0 ? 'danger' : 'success'}>
                {money(Math.abs(n))} {n > 0 ? tr('(мы должны)', '(biz qarzdormiz)') : tr('(должны нам)', '(bizga qarzdor)')}
              </Typography.Text>
            )
          },
        },
        { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      expandable={{
        expandedRowRender: (r) => (
          <>
            <Typography.Text strong>{tr('Акт сверки', 'Solishtirish dalolatnomasi')}</Typography.Text>
            <EntriesTable path={`/store/finance/counterparties/${r.id}/entries`} />
          </>
        ),
      }}
      form={(editing) => (
        <>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
            <Input />
          </Form.Item>
          <Form.Item name="type_id" label={tr('Тип', 'Turi')}>
            <RemoteSelect<CounterpartyType> path="/store/finance/counterparty-types" filter={(t) => t.is_active} allowClear />
          </Form.Item>
          <Form.Item name="phone" label={tr('Телефон', 'Telefon')} rules={[phoneRule()]}>
            <PhoneInput />
          </Form.Item>
          <Form.Item name="inn" label={tr('ИНН', 'STIR')}>
            <Input />
          </Form.Item>
          <Form.Item name="note" label={tr('Примечание', 'Izoh')}>
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
      title={tr('Типы контрагентов', 'Kontragent turlari')}
      path="/store/finance/counterparty-types"
      canDelete
      columns={[
        { title: tr('Название', 'Nomi'), dataIndex: 'name' },
        { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      form={(editing) => (
        <>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
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
    { title: tr('Название', 'Nomi'), dataIndex: 'name' },
    ...(kind === 'units'
      ? [
          { title: tr('Кратко', 'Qisqa nomi'), dataIndex: 'short_name' },
          { title: tr('Дробное', 'Kasrli'), dataIndex: 'is_fractional', render: (v: boolean) => (v ? tr('Да', 'Ha') : tr('Нет', 'Yoʻq')) },
        ]
      : []),
    ...(kind === 'colors'
      ? [
          {
            title: tr('Цвет', 'Rang'),
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
    ...(kind === 'categories' ? [{ title: tr('Родитель', 'Yuqori kategoriya'), dataIndex: 'parent_id', render: (v: string | null) => parentName(v) || '—' }] : []),
  ]
  return (
    <>
      <CrudPage<DictItem> title={title} path={`/store/catalog/${kind}`} columns={columns} />
      <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
        {tr('Справочник общий для всей платформы — его ведёт администратор.', 'Bu maʼlumotnoma butun platforma uchun umumiy — uni administrator yuritadi.')}
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
      title={tr('Типы цен', 'Narx turlari')}
      path="/store/price-types"
      canDelete={(r) => !r.is_default}
      canCreate={manage}
      canEdit={manage}
      columns={[
        { title: tr('Название', 'Nomi'), dataIndex: 'name' },
        { title: tr('По умолчанию', 'Standart'), dataIndex: 'is_default', render: (v: boolean) => (v ? <Tag color="green">{tr('Да', 'Ha')}</Tag> : '') },
        { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      form={(editing) => (
        <>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
            <Input />
          </Form.Item>
          {editing && !editing.is_default && (
            <>
              {activeField}
              <Form.Item name="is_default" label={tr('Сделать типом по умолчанию', 'Standart tur qilish')} valuePropName="checked">
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
        title={tr('Склады', 'Omborlar') + (store ? ' — ' + store.name : '')}
        path="/store/warehouses"
        canDelete={(r) => !r.is_default}
        params={{ store_id: storeId }}
        createLabel={tr('Новый склад', 'Yangi ombor')}
        canCreate={manage}
        canEdit={manage}
        columns={[
          {
            title: tr('Название', 'Nomi'),
            dataIndex: 'name',
            render: (v: string, r) => (r.is_default ? <>{v} <Tag color="blue">{tr('По умолчанию', 'Standart')}</Tag></> : v),
          },
          { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
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
        title={tr('Способы оплаты', 'Toʻlov usullari')}
        path="/store/finance/payment-methods"
        canDelete
        params={{ store_id: storeId }}
        createLabel={tr('Новый способ', 'Yangi usul')}
        columns={[
          { title: tr('Название', 'Nomi'), dataIndex: 'name' },
          { title: tr('Касса', 'Kassa'), dataIndex: 'cashbox_name' },
          { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
        ]}
        form={(editing) => (
          <>
            <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
              <Input placeholder={tr('Наличные, Терминал, Click…', 'Naqd pul, Terminal, Click…')} />
            </Form.Item>
            <Form.Item name="cashbox_id" label={tr('Касса, куда поступают деньги', 'Pul tushadigan kassa')} rules={[{ required: true, message: tr('Выберите кассу', 'Kassani tanlang') }]}>
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
      title={tr('Финансовые причины', 'Moliyaviy sabablar')}
      path="/store/finance/reasons"
      canDelete
      columns={[
        { title: tr('Название', 'Nomi'), dataIndex: 'name' },
        {
          title: tr('Вид', 'Turi'),
          dataIndex: 'kind',
          render: (v: string) => (v === 'income' ? <Tag color="green">{tr('Доход', 'Daromad')}</Tag> : <Tag color="red">{tr('Расход', 'Xarajat')}</Tag>),
        },
        { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      form={(editing) => (
        <>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={required}>
            <Input placeholder={tr('Аренда, зарплата, коммунальные…', 'Ijara, ish haqi, kommunal…')} />
          </Form.Item>
          <Form.Item name="kind" label={tr('Вид', 'Turi')} initialValue="expense" rules={[{ required: true }]}>
            <Select
              options={[
                { value: 'expense', label: tr('Расход', 'Xarajat') },
                { value: 'income', label: tr('Доход', 'Daromad') },
              ]}
            />
          </Form.Item>
          {editing && activeField}
        </>
      )}
    />
  )
}
