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
        locale={{ emptyText: 'Движений нет' }}
        columns={[
          { title: 'Дата', dataIndex: 'created_at', render: dateTime },
          { title: 'Документ', dataIndex: 'doc_type', render: (v: string) => docTypeTitles[v] ?? v },
          { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v: string) => <Signed v={v} /> },
        ]}
      />
    </>
  )
}

export function CashboxesPage() {
  const { stores, me } = useStore()
  return (
    <CrudPage<Cashbox>
      title="Кассы"
      path="/store/finance/cashboxes"
      canDelete={(r) => !r.is_main}
      createLabel="Новая касса"
      columns={[
        { title: 'Касса', dataIndex: 'name', render: (v: string, r) => (r.is_main ? <b>{v}</b> : v) },
        { title: 'Магазин', dataIndex: 'store_name', render: (v: string | null, r) => v ?? (r.is_main ? 'Главная касса сети' : '—') },
        { title: 'Валюта', dataIndex: 'currency' },
        { title: 'Остаток', dataIndex: 'balance', align: 'right', render: (v: string, r) => <b>{money(v, r.currency === 'USD' ? '$' : '')}</b> },
        { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
      ]}
      expandable={{ expandedRowRender: (r) => <EntriesTable path={`/store/finance/cashboxes/${r.id}/entries`} /> }}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={[{ required: true, message: 'Обязательное поле' }]}>
            <Input />
          </Form.Item>
          {!editing && (
            <>
              <Form.Item name="currency" label="Валюта" initialValue="UZS">
                <Select options={[{ value: 'UZS', label: 'UZS (сум)' }, { value: 'USD', label: 'USD' }]} />
              </Form.Item>
              <Form.Item name="store_id" label="Магазин" extra="Без магазина — главная касса сети (например, долларовая)">
                <Select
                  allowClear
                  options={stores.map((s) => ({ value: s.id, label: s.name }))}
                  placeholder={me?.all_stores ? 'Главная касса' : 'Выберите магазин'}
                />
              </Form.Item>
            </>
          )}
          {editing && (
            <Form.Item name="is_active" label="Статус">
              <Radio.Group options={[{ value: true, label: 'Активна' }, { value: false, label: 'Отключена' }]} />
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
        title="Кассовые операции"
        extra={
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>
            Новая операция
          </Button>
        }
      >
        <RangeFilter value={range} onChange={setRange} allowClear />
        <RemoteSelect<Cashbox> path="/store/finance/cashboxes" label={cashboxLabel} value={cashboxId} onChange={setCashboxId} allowClear placeholder="Все кассы" />
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
            { title: 'Дата', dataIndex: 'created_at', render: dateTime },
            {
              title: 'Вид',
              dataIndex: 'kind',
              render: (v: string) => <Tag color={v === 'income' ? 'green' : 'red'}>{kindTitles[v] ?? v}</Tag>,
            },
            { title: 'Касса', dataIndex: 'cashbox_name' },
            {
              title: 'Статья',
              key: 'what',
              render: (_, r) => r.reason_name ?? (r.counterparty_name ? `Контрагент: ${r.counterparty_name}` : '—'),
            },
            {
              title: 'Сумма',
              dataIndex: 'amount',
              align: 'right',
              render: (v: string, r) => <Signed v={r.kind === 'expense' ? -Number(v) : v} />,
            },
            { title: 'Валюта', dataIndex: 'currency' },
            { title: 'Примечание', dataIndex: 'note' },
            { title: 'Автор', dataIndex: 'created_by' },
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
    { success: 'Операция проведена' },
  )
  return (
    <Modal
      open={open}
      title="Кассовая операция"
      okText="Провести"
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
              { value: 'income', label: 'Приход' },
              { value: 'expense', label: 'Расход' },
            ]}
          />
        </Form.Item>
        <Form.Item name="cashbox_id" label="Касса" rules={[{ required: true, message: 'Выберите кассу' }]}>
          <RemoteSelect<Cashbox> path="/store/finance/cashboxes" label={cashboxLabel} filter={(c) => c.is_active} />
        </Form.Item>
        <Form.Item name="amount" label="Сумма" rules={[{ required: true, message: 'Укажите сумму' }]}>
          <Num min="0.01" />
        </Form.Item>
        <Form.Item name="source" label="Основание">
          <Radio.Group
            options={[
              { value: 'reason', label: 'Финансовая причина' },
              { value: 'counterparty', label: kind === 'income' ? 'От контрагента' : 'Оплата контрагенту' },
            ]}
          />
        </Form.Item>
        {source === 'reason' ? (
          <Form.Item name="reason_id" label="Причина" rules={[{ required: true, message: 'Выберите причину' }]}>
            <RemoteSelect<Reason> path="/store/finance/reasons" filter={(r) => r.is_active && r.kind === kind} />
          </Form.Item>
        ) : (
          <Form.Item name="counterparty_id" label="Контрагент" rules={[{ required: true, message: 'Выберите контрагента' }]}>
            <RemoteSelect<Counterparty>
              path="/store/finance/counterparties"
              search
              placeholder="Поиск по названию или телефону"
              filter={(c) => c.is_active}
              label={(c) => `${c.name} · сальдо ${money(c.balance)}`}
            />
          </Form.Item>
        )}
        <Form.Item name="note" label="Примечание">
          <Input />
        </Form.Item>
      </Form>
    </Modal>
  )
}

// ------------------------------------------- сдача кассы / из кассы в кассу

export function TransfersPage({ kind }: { kind: 'handover' | 'transfer' }) {
  const path = kind === 'handover' ? '/store/finance/handovers' : '/store/finance/transfers'
  const title = kind === 'handover' ? 'Сдача кассы' : 'Из кассы в кассу'
  const [open, setOpen] = useState(false)
  const list = usePaged<CashTransfer>(path)
  const [form] = Form.useForm()
  const save = useAction((v: Record<string, unknown>) => api.post(path, { ...v, note: v.note ?? '' }), { success: 'Проведено' })
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
            {kind === 'handover' ? 'Сдать кассу' : 'Перевести'}
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
            { title: 'Дата', dataIndex: 'created_at', render: dateTime },
            { title: 'Откуда', dataIndex: 'from_name' },
            { title: 'Сумма', dataIndex: 'amount_from', align: 'right', render: (v: string, r) => `${money(v)} ${r.from_currency}` },
            { title: 'Куда', dataIndex: 'to_name' },
            { title: 'Зачислено', dataIndex: 'amount_to', align: 'right', render: (v: string, r) => `${money(v)} ${r.to_currency}` },
            { title: 'Курс', dataIndex: 'rate', render: (v: string | null) => (v ? money(v) : '—') },
            { title: 'Примечание', dataIndex: 'note' },
            { title: 'Автор', dataIndex: 'created_by' },
          ]}
        />
      </Card>
      <Modal
        open={open}
        title={title}
        okText="Провести"
        onOk={() => form.submit()}
        confirmLoading={save.isPending}
        onCancel={() => setOpen(false)}
        destroyOnHidden
      >
        <Form form={form} layout="vertical" preserve={false} onFinish={(v) => save.mutate(v, { onSuccess: () => setOpen(false) })}>
          <Form.Item name="from_id" label="Из кассы" rules={[{ required: true, message: 'Выберите кассу' }]}>
            <Select options={opts((c) => (kind === 'handover' ? !c.is_main : true))} />
          </Form.Item>
          {kind === 'transfer' && (
            <Form.Item
              name="to_id"
              label="В кассу"
              rules={[{ required: true, message: 'Выберите кассу' }]}
              extra={from ? 'Между разными валютами — по текущему курсу' : undefined}
            >
              <Select options={opts((c) => c.id !== fromId)} />
            </Form.Item>
          )}
          {kind === 'handover' && (
            <Typography.Paragraph type="secondary">Деньги поступят в главную кассу сети в той же валюте.</Typography.Paragraph>
          )}
          <Form.Item name="amount" label={`Сумма${from ? ', ' + from.currency : ''}`} rules={[{ required: true, message: 'Укажите сумму' }]}>
            <Num min="0.01" max={from?.balance} />
          </Form.Item>
          <Form.Item name="note" label="Примечание">
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
  const save = useAction((v: { rate: string }) => api.post('/store/finance/rates', v), { success: 'Курс установлен' })
  const current = latest.data?.[0]
  return (
    <>
      <PageTitle title="Курс валюты" />
      <Card style={{ marginBottom: 16 }}>
        <Space size={48} wrap align="end">
          <Statistic title="Текущий курс, сум за 1 USD" value={current ? money(current.rate) : '—'} />
          <Form form={form} layout="inline" onFinish={(v) => save.mutate(v, { onSuccess: () => form.resetFields() })}>
            <Form.Item name="rate" rules={[{ required: true, message: 'Укажите курс' }]}>
              <Num min="1" placeholder="Новый курс" style={{ width: 180 }} />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={save.isPending}>
              Установить
            </Button>
          </Form>
        </Space>
      </Card>
      <LoadError error={list.error ?? latest.error} retry={() => void list.refetch()} />
      <Card title="История" styles={{ body: { padding: 0 } }}>
        <Table<Rate>
          rowKey={(r) => r.created_at}
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          columns={[
            { title: 'Дата', dataIndex: 'created_at', render: dateTime },
            { title: 'Курс', dataIndex: 'rate', align: 'right', render: (v: string) => money(v) },
          ]}
        />
      </Card>
    </>
  )
}
