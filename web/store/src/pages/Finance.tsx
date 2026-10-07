// Финансы: кассы, кассовые операции, сдача кассы, перемещения, курс.
import { useState } from 'react'
import { Button, Card, Form, Input, Modal, Radio, Select, Space, Statistic, Table, Tag, Typography } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import {
  ActiveTag,
  CrudPage,
  LoadError,
  PageTitle,
  RemoteSelect,
  api,
  dateTime,
  money,
  periodParams,
  tr,
  useAction,
  useList,
  usePaged,
} from '@sm/shared'
import { useStore } from '../ctx'
import { Num, RangeFilter, Signed, docTypeTitles, kindTitles, thisMonth, type Range } from '../ui'
import type { Cashbox, CashOperation, CashTransfer, Counterparty, Entry, Rate, Reason } from '../types'

const cashboxLabel = (c: Cashbox) => `${c.name} (${c.currency})${c.store_name ? ' · ' + c.store_name : ''}`

/** Выписка по кассе или акт сверки: движения со знаком. */
export function EntriesTable({ path }: { path: string }) {
  const list = usePaged<Entry>(path, undefined, 20)
  return (
    <>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Table<Entry>
        rowKey={(r) => r.doc_id + r.created_at + r.amount}
        size="small"
        loading={list.isLoading || list.isFetching}
        dataSource={list.items}
        pagination={list.pagination}
        locale={{ emptyText: tr('Движений нет', 'Harakatlar yoʻq') }}
        columns={[
          { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
          { title: tr('Документ', 'Hujjat'), dataIndex: 'doc_type', render: (v: string) => docTypeTitles[v] ?? v },
          { title: tr('Сумма', 'Summa'), dataIndex: 'amount', align: 'right', render: (v: string) => <Signed v={v} /> },
        ]}
      />
    </>
  )
}

export function CashboxesPage() {
  const { stores, me } = useStore()
  return (
    <CrudPage<Cashbox>
      title={tr('Кассы', 'Kassalar')}
      path="/store/finance/cashboxes"
      canDelete={(r) => !r.is_main}
      createLabel={tr('Новая касса', 'Yangi kassa')}
      columns={[
        { title: tr('Касса', 'Kassa'), dataIndex: 'name', render: (v: string, r) => (r.is_main ? <b>{v}</b> : v) },
        {
          title: tr('Магазин', 'Doʻkon'),
          dataIndex: 'store_name',
          render: (v: string | null, r) => v ?? (r.is_main ? tr('Главная касса сети', 'Tarmoqning asosiy kassasi') : '—'),
        },
        { title: tr('Валюта', 'Valyuta'), dataIndex: 'currency' },
        { title: tr('Остаток', 'Qoldiq'), dataIndex: 'balance', align: 'right', render: (v: string, r) => <b>{money(v, r.currency === 'USD' ? '$' : '')}</b> },
        { title: tr('Статус', 'Holat'), dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      expandable={{ expandedRowRender: (r) => <EntriesTable path={`/store/finance/cashboxes/${r.id}/entries`} /> }}
      form={(editing) => (
        <>
          <Form.Item name="name" label={tr('Название', 'Nomi')} rules={[{ required: true, message: tr('Обязательное поле', 'Majburiy maydon') }]}>
            <Input />
          </Form.Item>
          {!editing && (
            <>
              <Form.Item name="currency" label={tr('Валюта', 'Valyuta')} initialValue="UZS">
                <Select
                  options={[
                    { value: 'UZS', label: tr('UZS (сум)', 'UZS (soʻm)') },
                    { value: 'USD', label: 'USD' },
                  ]}
                />
              </Form.Item>
              <Form.Item
                name="store_id"
                label={tr('Магазин', 'Doʻkon')}
                extra={tr('Без магазина — главная касса сети (например, долларовая)', 'Doʻkonsiz — tarmoqning asosiy kassasi (masalan, dollar kassasi)')}
              >
                <Select
                  allowClear
                  options={stores.map((s) => ({ value: s.id, label: s.name }))}
                  placeholder={me?.all_stores ? tr('Главная касса', 'Asosiy kassa') : tr('Выберите магазин', 'Doʻkonni tanlang')}
                />
              </Form.Item>
            </>
          )}
          {editing && (
            <Form.Item name="is_active" label={tr('Статус', 'Holat')}>
              <Radio.Group
                options={[
                  { value: true, label: tr('Активна', 'Faol') },
                  { value: false, label: tr('Отключена', 'Oʻchirilgan') },
                ]}
              />
            </Form.Item>
          )}
        </>
      )}
      toForm={(r) => ({ name: r.name, is_active: r.is_active })}
      toBody={(v, editing) => (editing ? { name: v.name, is_active: v.is_active } : { ...v, store_id: v.store_id || undefined })}
    />
  )
}

// --------------------------------------------------------- кассовые операции

export function OperationsPage() {
  const [range, setRange] = useState<Range | null>(thisMonth)
  const [cashboxId, setCashboxId] = useState<string>()
  const [open, setOpen] = useState(false)
  const list = usePaged<CashOperation>('/store/finance/operations', {
    cashbox_id: cashboxId,
    ...periodParams(range),
  })
  return (
    <>
      <PageTitle
        title={tr('Кассовые операции', 'Kassa operatsiyalari')}
        extra={
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>
            {tr('Новая операция', 'Yangi operatsiya')}
          </Button>
        }
      >
        <RangeFilter value={range} onChange={setRange} allowClear />
        <RemoteSelect<Cashbox> path="/store/finance/cashboxes" label={cashboxLabel} value={cashboxId} onChange={setCashboxId} allowClear placeholder={tr('Все кассы', 'Barcha kassalar')} />
      </PageTitle>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<CashOperation>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
            {
              title: tr('Вид', 'Turi'),
              dataIndex: 'kind',
              render: (v: string) => <Tag color={v === 'income' ? 'green' : 'red'}>{kindTitles[v] ?? v}</Tag>,
            },
            { title: tr('Касса', 'Kassa'), dataIndex: 'cashbox_name' },
            {
              title: tr('Статья', 'Modda'),
              key: 'what',
              render: (_, r) => r.reason_name ?? (r.counterparty_name ? tr(`Контрагент: ${r.counterparty_name}`, `Kontragent: ${r.counterparty_name}`) : '—'),
            },
            {
              title: tr('Сумма', 'Summa'),
              dataIndex: 'amount',
              align: 'right',
              render: (v: string, r) => <Signed v={r.kind === 'expense' ? -Number(v) : v} />,
            },
            { title: tr('Валюта', 'Valyuta'), dataIndex: 'currency' },
            { title: tr('Примечание', 'Izoh'), dataIndex: 'note' },
            { title: tr('Автор', 'Muallif'), dataIndex: 'created_by' },
          ]}
        />
      </Card>
      <OperationModal open={open} onClose={() => setOpen(false)} />
    </>
  )
}

interface OpForm {
  kind: 'income' | 'expense'
  cashbox_id: string
  amount: string
  source: 'reason' | 'counterparty'
  reason_id?: string
  counterparty_id?: string
  note?: string
}

function OperationModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [form] = Form.useForm<OpForm>()
  const kind = Form.useWatch('kind', form) ?? 'income'
  const source = Form.useWatch('source', form) ?? 'reason'
  const save = useAction(
    (v: OpForm) =>
      api.post('/store/finance/operations', {
        kind: v.kind,
        cashbox_id: v.cashbox_id,
        amount: v.amount,
        note: v.note ?? '',
        ...(v.source === 'reason' ? { reason_id: v.reason_id } : { counterparty_id: v.counterparty_id }),
      }),
    { success: tr('Операция проведена', 'Operatsiya oʻtkazildi') },
  )
  return (
    <Modal
      open={open}
      title={tr('Кассовая операция', 'Kassa operatsiyasi')}
      okText={tr('Провести', 'Oʻtkazish')}
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      destroyOnHidden
    >
      <Form<OpForm>
        form={form}
        layout="vertical"
        preserve={false}
        initialValues={{ kind: 'income', source: 'reason' }}
        onFinish={(v) => save.mutate(v, { onSuccess: onClose })}
        onValuesChange={(changed) => {
          // причина другого вида не подходит
          if ('kind' in changed) form.setFieldValue('reason_id', undefined)
        }}
      >
        <Form.Item name="kind">
          <Radio.Group
            optionType="button"
            buttonStyle="solid"
            options={[
              { value: 'income', label: tr('Приход', 'Kirim') },
              { value: 'expense', label: tr('Расход', 'Chiqim') },
            ]}
          />
        </Form.Item>
        <Form.Item name="cashbox_id" label={tr('Касса', 'Kassa')} rules={[{ required: true, message: tr('Выберите кассу', 'Kassani tanlang') }]}>
          <RemoteSelect<Cashbox> path="/store/finance/cashboxes" label={cashboxLabel} filter={(c) => c.is_active} />
        </Form.Item>
        <Form.Item name="amount" label={tr('Сумма', 'Summa')} rules={[{ required: true, message: tr('Укажите сумму', 'Summani kiriting') }]}>
          <Num min="0.01" />
        </Form.Item>
        <Form.Item name="source" label={tr('Основание', 'Asos')}>
          <Radio.Group
            options={[
              { value: 'reason', label: tr('Финансовая причина', 'Moliyaviy sabab') },
              {
                value: 'counterparty',
                label: kind === 'income' ? tr('От контрагента', 'Kontragentdan') : tr('Оплата контрагенту', 'Kontragentga toʻlov'),
              },
            ]}
          />
        </Form.Item>
        {source === 'reason' ? (
          <Form.Item name="reason_id" label={tr('Причина', 'Sabab')} rules={[{ required: true, message: tr('Выберите причину', 'Sababni tanlang') }]}>
            <RemoteSelect<Reason> path="/store/finance/reasons" filter={(r) => r.is_active && r.kind === kind} />
          </Form.Item>
        ) : (
          <Form.Item name="counterparty_id" label={tr('Контрагент', 'Kontragent')} rules={[{ required: true, message: tr('Выберите контрагента', 'Kontragentni tanlang') }]}>
            <RemoteSelect<Counterparty>
              path="/store/finance/counterparties"
              search
              placeholder={tr('Поиск по названию или телефону', 'Nomi yoki telefon boʻyicha qidirish')}
              filter={(c) => c.is_active}
              label={(c) => `${c.name} · ${tr('сальдо', 'saldo')} ${money(c.balance)}`}
            />
          </Form.Item>
        )}
        <Form.Item name="note" label={tr('Примечание', 'Izoh')}>
          <Input />
        </Form.Item>
      </Form>
    </Modal>
  )
}

// ------------------------------------------- сдача кассы / из кассы в кассу

export function TransfersPage({ kind }: { kind: 'handover' | 'transfer' }) {
  const path = kind === 'handover' ? '/store/finance/handovers' : '/store/finance/transfers'
  const title = kind === 'handover' ? tr('Сдача кассы', 'Kassani topshirish') : tr('Из кассы в кассу', 'Kassadan kassaga')
  const [open, setOpen] = useState(false)
  const list = usePaged<CashTransfer>(path)
  const [form] = Form.useForm()
  const save = useAction((v: Record<string, unknown>) => api.post(path, { ...v, note: v.note ?? '' }), { success: tr('Проведено', 'Oʻtkazildi') })
  const cashboxes = useList<Cashbox>('/store/finance/cashboxes')
  const fromId = Form.useWatch('from_id', form)
  const from = (cashboxes.data ?? []).find((c) => c.id === fromId)
  const opts = (f: (c: Cashbox) => boolean) =>
    (cashboxes.data ?? []).filter((c) => c.is_active && f(c)).map((c) => ({ value: c.id, label: `${cashboxLabel(c)} — ${money(c.balance)}` }))

  return (
    <>
      <PageTitle
        title={title}
        extra={
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>
            {kind === 'handover' ? tr('Сдать кассу', 'Kassani topshirish') : tr('Перевести', 'Oʻtkazish')}
          </Button>
        }
      />
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<CashTransfer>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
            { title: tr('Откуда', 'Qayerdan'), dataIndex: 'from_name' },
            { title: tr('Сумма', 'Summa'), dataIndex: 'amount_from', align: 'right', render: (v: string, r) => `${money(v)} ${r.from_currency}` },
            { title: tr('Куда', 'Qayerga'), dataIndex: 'to_name' },
            { title: tr('Зачислено', 'Tushdi'), dataIndex: 'amount_to', align: 'right', render: (v: string, r) => `${money(v)} ${r.to_currency}` },
            { title: tr('Курс', 'Kurs'), dataIndex: 'rate', render: (v: string | null) => (v ? money(v) : '—') },
            { title: tr('Примечание', 'Izoh'), dataIndex: 'note' },
            { title: tr('Автор', 'Muallif'), dataIndex: 'created_by' },
          ]}
        />
      </Card>
      <Modal
        open={open}
        title={title}
        okText={tr('Провести', 'Oʻtkazish')}
        onOk={() => form.submit()}
        confirmLoading={save.isPending}
        onCancel={() => setOpen(false)}
        destroyOnHidden
      >
        <Form form={form} layout="vertical" preserve={false} onFinish={(v) => save.mutate(v, { onSuccess: () => setOpen(false) })}>
          <Form.Item name="from_id" label={tr('Из кассы', 'Qaysi kassadan')} rules={[{ required: true, message: tr('Выберите кассу', 'Kassani tanlang') }]}>
            <Select options={opts((c) => (kind === 'handover' ? !c.is_main : true))} />
          </Form.Item>
          {kind === 'transfer' && (
            <Form.Item
              name="to_id"
              label={tr('В кассу', 'Qaysi kassaga')}
              rules={[{ required: true, message: tr('Выберите кассу', 'Kassani tanlang') }]}
              extra={from ? tr('Между разными валютами — по текущему курсу', 'Turli valyutalar oʻrtasida — joriy kurs boʻyicha') : undefined}
            >
              <Select options={opts((c) => c.id !== fromId)} />
            </Form.Item>
          )}
          {kind === 'handover' && (
            <Typography.Paragraph type="secondary">
              {tr('Деньги поступят в главную кассу сети в той же валюте.', 'Pul tarmoqning asosiy kassasiga xuddi shu valyutada tushadi.')}
            </Typography.Paragraph>
          )}
          <Form.Item name="amount" label={tr('Сумма', 'Summa') + (from ? ', ' + from.currency : '')}
            rules={[{ required: true, message: tr('Укажите сумму', 'Summani kiriting') }]}
          >
            <Num min="0.01" max={from?.balance} />
          </Form.Item>
          <Form.Item name="note" label={tr('Примечание', 'Izoh')}>
            <Input />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}

// ------------------------------------------------------------------- курс

export function RatesPage() {
  const list = usePaged<Rate>('/store/finance/rates', undefined, 20)
  const latest = useList<Rate>('/store/finance/rates', { limit: 1 })
  const [form] = Form.useForm<{ rate: string }>()
  const save = useAction((v: { rate: string }) => api.post('/store/finance/rates', v), { success: tr('Курс установлен', 'Kurs belgilandi') })
  const current = latest.data?.[0]
  return (
    <>
      <PageTitle title={tr('Курс валюты', 'Valyuta kursi')} />
      <Card style={{ marginBottom: 16 }}>
        <Space size={48} wrap align="end">
          <Statistic title={tr('Текущий курс, сум за 1 USD', 'Joriy kurs, 1 USD uchun soʻm')} value={current ? money(current.rate) : '—'} />
          <Form form={form} layout="inline" onFinish={(v) => save.mutate(v, { onSuccess: () => form.resetFields() })}>
            <Form.Item name="rate" rules={[{ required: true, message: tr('Укажите курс', 'Kursni kiriting') }]}>
              <Num min="1" placeholder={tr('Новый курс', 'Yangi kurs')} style={{ width: 180 }} />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={save.isPending}>
              {tr('Установить', 'Belgilash')}
            </Button>
          </Form>
        </Space>
      </Card>
      <LoadError error={list.error ?? latest.error} retry={() => void list.refetch()} />
      <Card title={tr('История', 'Tarix')} styles={{ body: { padding: 0 } }}>
        <Table<Rate>
          rowKey={(r) => r.created_at}
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          columns={[
            { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
            { title: tr('Курс', 'Kurs'), dataIndex: 'rate', align: 'right', render: (v: string) => money(v) },
          ]}
        />
      </Card>
    </>
  )
}
