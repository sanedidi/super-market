// Продажи POS и возвраты покупателей.
import { useEffect, useState } from 'react'
import {
  Alert,
  Button,
  Card,
  Descriptions,
  Drawer,
  Form,
  Grid,
  Input,
  Modal,
  Space,
  Statistic,
  Switch,
  Table,
  Tag,
  Typography,
} from 'antd'
import { PlusOutlined, RollbackOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, api, dateTime, formatPhone, money, periodParams, qty, tr, useAction, useItem, useList, usePaged } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore, Num, RangeFilter, today, type Range } from '../ui'
import { FiscalModal } from './Orders'
import type { CustomerReturn, PaymentMethod, Sale, SaleItem, SalesSummary } from '../types'

function FiscalTag({ status }: { status: string }) {
  return status === 'registered' ? <Tag color="green">{tr('Пробит', 'Urilgan')}</Tag> : <Tag color="orange">{tr('Не пробит', 'Urilmagan')}</Tag>
}

export function SalesPage() {
  const { storeId } = useStore()
  const [range, setRange] = useState<Range | null>(today)
  const [pending, setPending] = useState(false)
  const [q, setQ] = useState('')
  const [openId, setOpenId] = useState<string | null>(null)
  const filters = { store_id: storeId, fiscal: pending ? 'pending' : undefined, ...periodParams(range) }
  const list = usePaged<Sale>(storeId ? '/store/sales' : null, { ...filters, q: q || undefined })
  // Итоги считает сервер по всем чекам периода, а не по странице.
  const summary = useItem<SalesSummary>(storeId ? '/store/sales/summary' : null, filters)
  const t = summary.data

  return (
    <NeedStore>
      <PageTitle title={tr('Продажи POS', 'POS sotuvlari')}>
        <RangeFilter value={range} onChange={setRange} allowClear />
        <Input.Search placeholder={tr('№ чека или телефон', 'Chek № yoki telefon')} allowClear onSearch={(v) => setQ(v.trim())} style={{ width: 220 }} />
        <Space>
          <Switch checked={pending} onChange={setPending} />
          {tr('Только непробитые', 'Faqat urilmaganlar')}
        </Space>
      </PageTitle>
      <LoadError error={summary.error} retry={() => summary.refetch()} />
      <Card style={{ marginBottom: 16 }} loading={summary.isLoading}>
        <Space size={48} wrap>
          <Statistic title={tr('Чеков', 'Cheklar')} value={t?.sales_count ?? 0} />
          <Statistic title={tr('Выручка, сум', 'Tushum, soʻm')} value={money(t?.revenue)} />
          <Statistic title={tr('Скидки, сум', 'Chegirmalar, soʻm')} value={money(t?.discount)} />
          <Statistic title={tr(`Возвраты (${t?.returns_count ?? 0}), сум`, `Qaytarishlar (${t?.returns_count ?? 0}), soʻm`)} value={money(t?.returns)} />
          <Statistic title={tr('За вычетом возвратов, сум', 'Qaytarishlarsiz, soʻm')} value={money(t?.net)} />
        </Space>
        {q && <Typography.Paragraph type="secondary" style={{ margin: '12px 0 0' }}>{tr('Итоги — за весь период, без учёта поиска.', 'Jami — butun davr uchun, qidiruvni hisobga olmagan holda.')}</Typography.Paragraph>}
      </Card>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Sale>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          onRow={(r) => ({ onClick: () => setOpenId(r.id), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: tr('Время', 'Vaqt'), dataIndex: 'sold_at', render: dateTime },
            { title: tr('Кассир', 'Kassir'), dataIndex: 'cashier' },
            { title: tr('Покупатель', 'Xaridor'), dataIndex: 'customer_phone', render: (v: string) => formatPhone(v) || '—' },
            { title: tr('Скидка', 'Chegirma'), dataIndex: 'discount', align: 'right', render: (v: string) => money(v) },
            { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            { title: tr('Чек', 'Chek'), dataIndex: 'fiscal_status', render: (v: string) => <FiscalTag status={v} /> },
          ]}
        />
      </Card>
      <SaleDrawer id={openId} onClose={() => setOpenId(null)} />
    </NeedStore>
  )
}

function SaleDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const screens = Grid.useBreakpoint()
  const { can } = useStore()
  const { data: s, isLoading } = useItem<Sale>(id ? `/store/sales/${id}` : null)
  const returns = useList<CustomerReturn>(s ? '/store/sales/returns' : null, { sale_id: s?.id, limit: 200 })
  const saleReturns = returns.data ?? []
  const [fiscal, setFiscal] = useState(false)
  const [ret, setRet] = useState(false)
  const canReturn = s && can('sales.return') && (s.items ?? []).some((i) => Number(i.returned_qty) < Number(i.qty))

  return (
    <Drawer
      open={!!id}
      onClose={onClose}
      width={screens.md ? 720 : '100%'}
      title={s ? tr(`Чек № ${s.number}`, `Chek № ${s.number}`) : tr('Чек', 'Chek')}
      loading={isLoading}
      extra={
        s && (
          <Space>
            {s.fiscal_status !== 'registered' && can('sales.pos') && <Button onClick={() => setFiscal(true)}>{tr('Пробить чек', 'Chekni urish')}</Button>}
            {canReturn && (
              <Button icon={<RollbackOutlined />} onClick={() => setRet(true)}>
                {tr('Возврат', 'Qaytarish')}
              </Button>
            )}
          </Space>
        )
      }
    >
      {s && (
        <>
          <Descriptions size="small" bordered column={{ xs: 1, sm: 2, md: 2, lg: 2, xl: 2, xxl: 2 }} style={{ marginBottom: 16 }}>
            <Descriptions.Item label={tr('Время', 'Vaqt')}>{dateTime(s.sold_at)}</Descriptions.Item>
            <Descriptions.Item label={tr('Магазин', 'Doʻkon')}>{s.store_name}</Descriptions.Item>
            <Descriptions.Item label={tr('Кассир', 'Kassir')}>{s.cashier}</Descriptions.Item>
            <Descriptions.Item label={tr('Покупатель', 'Xaridor')}>{formatPhone(s.customer_phone) || '—'}</Descriptions.Item>
            <Descriptions.Item label={tr('Чек', 'Chek')}>
              <FiscalTag status={s.fiscal_status} />
              {s.fiscal_number && `№ ${s.fiscal_number} · ${s.fiscal_sign}`}
            </Descriptions.Item>
            {s.note && <Descriptions.Item label={tr('Примечание', 'Izoh')}>{s.note}</Descriptions.Item>}
          </Descriptions>
          <Table<SaleItem>
            rowKey="line"
            size="small"
            pagination={false}
            dataSource={s.items}
            scroll={{ x: true }}
            style={{ marginBottom: 16 }}
            columns={[
              { title: tr('Товар', 'Mahsulot'), dataIndex: 'product_name' },
              { title: tr('Кол-во', 'Miqdor'), dataIndex: 'qty', align: 'right', render: (v: string) => qty(v) },
              { title: tr('Цена', 'Narx'), dataIndex: 'price', align: 'right', render: (v: string) => money(v) },
              { title: tr('Скидка', 'Chegirma'), dataIndex: 'discount', align: 'right', render: (v: string) => money(v) },
              { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
              {
                title: tr('Возвращено', 'Qaytarilgan'),
                dataIndex: 'returned_qty',
                align: 'right',
                render: (v: string) => (Number(v) > 0 ? <Typography.Text type="danger">{qty(v)}</Typography.Text> : '—'),
              },
            ]}
            summary={() => (
              <Table.Summary.Row>
                <Table.Summary.Cell index={0} colSpan={4}>
                  <b>{tr('Итого', 'Jami')}</b>{' '}
                  {tr(
                    `(без скидки ${money(s.subtotal)}, скидка ${money(s.discount)})`,
                    `(chegirmasiz ${money(s.subtotal)}, chegirma ${money(s.discount)})`,
                  )}
                </Table.Summary.Cell>
                <Table.Summary.Cell index={1} align="right">
                  <b>{money(s.total)}</b>
                </Table.Summary.Cell>
                <Table.Summary.Cell index={2} />
              </Table.Summary.Row>
            )}
          />
          <Typography.Title level={5}>{tr('Оплата', 'Toʻlov')}</Typography.Title>
          <Table
            rowKey="payment_method_id"
            size="small"
            pagination={false}
            dataSource={s.payments}
            style={{ marginBottom: 16 }}
            columns={[
              { title: tr('Способ', 'Usul'), dataIndex: 'name' },
              { title: tr('Сумма', 'Summa'), dataIndex: 'amount', align: 'right', render: (v: string) => money(v) },
            ]}
          />
          <Typography.Title level={5}>{tr('Возвраты', 'Qaytarishlar')}</Typography.Title>
          <Table<CustomerReturn>
            rowKey="id"
            size="small"
            pagination={false}
            dataSource={saleReturns}
            loading={returns.isLoading}
            locale={{ emptyText: tr('Возвратов нет', 'Qaytarishlar yoʻq') }}
            columns={[
              { title: '№', dataIndex: 'number' },
              { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
              { title: tr('Причина', 'Sabab'), dataIndex: 'reason' },
              { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            ]}
          />
          <FiscalModal path={`/store/sales/${s.id}/fiscal`} open={fiscal} onClose={() => setFiscal(false)} />
          <ReturnModal open={ret} onClose={() => setRet(false)} saleId={s.id} />
        </>
      )}
    </Drawer>
  )
}

// ---------------------------------------------------------------- возвраты

export function ReturnsPage() {
  const { storeId, can } = useStore()
  const [range, setRange] = useState<Range | null>(null)
  const [pending, setPending] = useState(false)
  const [creating, setCreating] = useState(false)
  const [openId, setOpenId] = useState<string | null>(null)
  const list = usePaged<CustomerReturn>(storeId ? '/store/sales/returns' : null, {
    store_id: storeId,
    fiscal: pending ? 'pending' : undefined,
    ...periodParams(range),
  })
  return (
    <NeedStore>
      <PageTitle
        title={tr('Возвраты', 'Qaytarishlar')}
        extra={
          can('sales.return') && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreating(true)}>
              {tr('Оформить возврат', 'Qaytarishni rasmiylashtirish')}
            </Button>
          )
        }
      >
        <RangeFilter value={range} onChange={setRange} allowClear />
        <Space>
          <Switch checked={pending} onChange={setPending} />
          {tr('Только непробитые', 'Faqat urilmaganlar')}
        </Space>
      </PageTitle>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<CustomerReturn>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          scroll={{ x: true }}
          pagination={list.pagination}
          onRow={(r) => ({ onClick: () => setOpenId(r.id), style: { cursor: 'pointer' } })}
          columns={[
            { title: '№', dataIndex: 'number', width: 70 },
            { title: tr('Дата', 'Sana'), dataIndex: 'created_at', render: dateTime },
            { title: tr('Чек продажи', 'Sotuv cheki'), dataIndex: 'sale_number', render: (v: number) => `№ ${v}` },
            { title: tr('Способ возврата', 'Qaytarish usuli'), dataIndex: 'payment_method' },
            { title: tr('Причина', 'Sabab'), dataIndex: 'reason' },
            { title: tr('Кто оформил', 'Kim rasmiylashtirgan'), dataIndex: 'created_by' },
            { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            { title: tr('Чек', 'Chek'), dataIndex: 'fiscal_status', render: (v: string) => <FiscalTag status={v} /> },
          ]}
        />
      </Card>
      <ReturnModal open={creating} onClose={() => setCreating(false)} />
      <ReturnDrawer id={openId} onClose={() => setOpenId(null)} />
    </NeedStore>
  )
}

function ReturnDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const { can } = useStore()
  const { data: r, isLoading } = useItem<CustomerReturn>(id ? `/store/sales/returns/${id}` : null)
  const [fiscal, setFiscal] = useState(false)
  return (
    <Drawer
      open={!!id}
      onClose={onClose}
      width={560}
      title={r ? tr(`Возврат № ${r.number}`, `Qaytarish № ${r.number}`) : tr('Возврат', 'Qaytarish')}
      loading={isLoading}
      extra={r && r.fiscal_status !== 'registered' && can('sales.pos') && <Button onClick={() => setFiscal(true)}>{tr('Пробить чек', 'Chekni urish')}</Button>}
    >
      {r && (
        <>
          <Descriptions size="small" bordered column={1} style={{ marginBottom: 16 }}>
            <Descriptions.Item label={tr('Дата', 'Sana')}>{dateTime(r.created_at)}</Descriptions.Item>
            <Descriptions.Item label={tr('Чек продажи', 'Sotuv cheki')}>№ {r.sale_number}</Descriptions.Item>
            <Descriptions.Item label={tr('Способ возврата', 'Qaytarish usuli')}>{r.payment_method}</Descriptions.Item>
            <Descriptions.Item label={tr('Причина', 'Sabab')}>{r.reason || '—'}</Descriptions.Item>
            <Descriptions.Item label={tr('Кто оформил', 'Kim rasmiylashtirgan')}>{r.created_by}</Descriptions.Item>
            <Descriptions.Item label={tr('Чек', 'Chek')}>
              <FiscalTag status={r.fiscal_status} />
            </Descriptions.Item>
          </Descriptions>
          <Table
            rowKey="sale_line"
            size="small"
            pagination={false}
            dataSource={r.items}
            columns={[
              { title: tr('Товар', 'Mahsulot'), dataIndex: 'product_name' },
              { title: tr('Кол-во', 'Miqdor'), dataIndex: 'qty', align: 'right', render: (v: string) => qty(v) },
              { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
            ]}
            summary={() => (
              <Table.Summary.Row>
                <Table.Summary.Cell index={0} colSpan={2}>
                  <b>{tr('Итого', 'Jami')}</b>
                </Table.Summary.Cell>
                <Table.Summary.Cell index={1} align="right">
                  <b>{money(r.total)}</b>
                </Table.Summary.Cell>
              </Table.Summary.Row>
            )}
          />
          <FiscalModal path={`/store/sales/returns/${r.id}/fiscal`} open={fiscal} onClose={() => setFiscal(false)} />
        </>
      )}
    </Drawer>
  )
}

/** Оформление возврата по чеку: выбор чека, строк и количества. */
function ReturnModal({ open, onClose, saleId }: { open: boolean; onClose: () => void; saleId?: string }) {
  const { storeId } = useStore()
  const [sale, setSale] = useState<string | undefined>(saleId)
  const [amounts, setAmounts] = useState<Record<number, string | null>>({})
  const [form] = Form.useForm<{ payment_method_id: string; reason: string }>()
  useEffect(() => {
    if (open) {
      setSale(saleId)
      setAmounts({})
      form.resetFields()
    }
  }, [open, saleId, form])
  const detail = useItem<Sale>(open && sale ? `/store/sales/${sale}` : null)
  const s = detail.data
  const save = useAction(
    (v: { payment_method_id: string; reason: string }) =>
      api.post('/store/sales/returns', {
        sale_id: sale,
        payment_method_id: v.payment_method_id,
        reason: v.reason ?? '',
        items: Object.entries(amounts)
          .filter(([, q]) => q && Number(q) > 0)
          .map(([line, q]) => ({ sale_line: Number(line), qty: q })),
      }),
    { success: tr('Возврат оформлен', 'Qaytarish rasmiylashtirildi') },
  )
  const chosen = Object.values(amounts).some((q) => q && Number(q) > 0)
  const estimate = (s?.items ?? []).reduce((acc, i) => {
    const q = Number(amounts[i.line] ?? 0)
    return acc + (Number(i.qty) ? (Number(i.total) / Number(i.qty)) * q : 0)
  }, 0)

  return (
    <Modal
      open={open}
      title={tr('Возврат по чеку', 'Chek boʻyicha qaytarish')}
      okText={tr('Оформить возврат', 'Qaytarishni rasmiylashtirish')}
      okButtonProps={{ disabled: !chosen }}
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      width={760}
      destroyOnHidden
    >
      {!saleId && (
        <div style={{ marginBottom: 16 }}>
          <Typography.Paragraph style={{ marginBottom: 8 }}>{tr('Чек продажи', 'Sotuv cheki')}</Typography.Paragraph>
          <RemoteSelect<Sale>
            path="/store/sales"
            params={{ store_id: storeId }}
            search
            value={sale}
            onChange={(v: string) => {
              setSale(v)
              setAmounts({})
            }}
            label={(x) => `№ ${x.number} — ${dateTime(x.sold_at)} — ${money(x.total)}`}
            selectedLabel={s ? `№ ${s.number} — ${dateTime(s.sold_at)} — ${money(s.total)}` : undefined}
            placeholder={tr('Номер чека или телефон покупателя', 'Chek raqami yoki xaridor telefoni')}
            notFoundContent={tr('Чек не найден', 'Chek topilmadi')}
            style={{ width: '100%' }}
          />
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Без поиска — последние чеки магазина', 'Qidiruvsiz — doʻkonning soʻnggi cheklari')}
          </Typography.Text>
        </div>
      )}
      {s && (
        <>
          <Table<SaleItem>
            rowKey="line"
            size="small"
            pagination={false}
            dataSource={s.items}
            scroll={{ x: true }}
            style={{ marginBottom: 16 }}
            columns={[
              { title: tr('Товар', 'Mahsulot'), dataIndex: 'product_name' },
              { title: tr('Продано', 'Sotilgan'), dataIndex: 'qty', align: 'right', render: (v: string) => qty(v) },
              { title: tr('Возвращено', 'Qaytarilgan'), dataIndex: 'returned_qty', align: 'right', render: (v: string) => qty(v) },
              { title: tr('Сумма', 'Summa'), dataIndex: 'total', align: 'right', render: (v: string) => money(v) },
              {
                title: tr('Вернуть', 'Qaytarish'),
                key: 'ret',
                width: 130,
                render: (_, i) => {
                  const left = Number(i.qty) - Number(i.returned_qty)
                  return left > 0 ? (
                    <Num value={amounts[i.line] ?? null} max={String(left)} onChange={(v) => setAmounts((a) => ({ ...a, [i.line]: v }))} />
                  ) : (
                    <Typography.Text type="secondary">—</Typography.Text>
                  )
                },
              },
            ]}
          />
          <Alert type="info" showIcon message={tr(
              `К возврату примерно: ${money(estimate)} сум (точная сумма — с учётом скидки по строке)`,
              `Qaytariladigan summa taxminan: ${money(estimate)} soʻm (aniq summa — qatordagi chegirma hisobga olingan holda)`,
            )} style={{ marginBottom: 16 }} />
          <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
            <Form.Item name="payment_method_id" label={tr('Способ возврата денег', 'Pulni qaytarish usuli')} rules={[{ required: true, message: tr('Выберите способ', 'Usulni tanlang') }]}>
              <RemoteSelect<PaymentMethod>
                path="/store/finance/payment-methods"
                params={{ store_id: s.store_id }}
                filter={(m) => m.is_active}
                label={(m) => `${m.name} (${m.cashbox_name})`}
              />
            </Form.Item>
            <Form.Item name="reason" label={tr('Причина', 'Sabab')}>
              <Input placeholder={tr('Брак, не подошло…', 'Nuqsonli, mos kelmadi…')} />
            </Form.Item>
          </Form>
        </>
      )}
      {!s && sale && detail.isLoading && <Typography.Text type="secondary">{tr('Загрузка чека…', 'Chek yuklanmoqda…')}</Typography.Text>}
    </Modal>
  )
}

