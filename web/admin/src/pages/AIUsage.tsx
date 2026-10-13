// Расход ИИ (Figma «Админка · ИИ-сервис» → А3): токены и деньги за период,
// по дням и по сетям / магазинам / сотрудникам; цена токенов.
import { useMemo, useState, type ReactNode } from 'react'
import dayjs from 'dayjs'
import { Button, Card, Col, DatePicker, Empty, Flex, Form, InputNumber, Modal, Row, Segmented, Select, Table, Tooltip, Typography } from 'antd'
import { CalculatorOutlined, DollarOutlined, DownloadOutlined, FileSearchOutlined, InfoCircleOutlined, ThunderboltOutlined } from '@ant-design/icons'
import { LoadError, api, money, useAction, useItem } from '@sm/shared'

type Group = 'network' | 'store' | 'employee'
type Currency = 'USD' | 'RUB' | 'UZS'

interface Prices {
  price_in: number
  price_out: number
  currency: Currency
  rate_uzs: number
}

interface Totals {
  requests: number
  invoices: number
  photos: number
  product_photos?: number
  /** Фото, которые Super Market сделал магазинам сам. */
  store_photos?: number
  errors: number
  tests: number
  input_tokens: number
  output_tokens: number
  cost_uzs: number
}

interface Day {
  date: string
  requests: number
  input_tokens: number
  output_tokens: number
  cost_uzs: number
}

interface Item {
  id: string
  name: string
  sub: string
  network_id: string
  stores: number
  employees: number
  requests: number
  invoices: number
  photos: number
  product_photos?: number
  /** Фото, которые Super Market сделал магазинам сам. */
  store_photos?: number
  errors: number
  input_tokens: number
  output_tokens: number
  cost_uzs: number
  share: number
}

interface Report {
  from: string
  to: string
  totals: Totals
  days: Day[]
  items: Item[]
  prices: Prices
  model: string
}

const SIGN: Record<Currency, string> = { USD: '$', RUB: '₽', UZS: 'сум' }

/** 12 400 000 → «12,4 млн», 640 000 → «640 тыс.». */
export function tokens(n: number): string {
  if (n >= 1_000_000) return (Math.round(n / 100_000) / 10).toLocaleString('ru-RU') + ' млн'
  if (n >= 10_000) return Math.round(n / 1000).toLocaleString('ru-RU') + ' тыс.'
  return n.toLocaleString('ru-RU')
}

function sum(v: number) {
  return money(Math.round(v)) + ' сум'
}

/** Сумма в валюте цены: «$101,52», «7 600 ₽». */
function inCurrency(uzs: number, p: Prices) {
  if (p.currency === 'UZS' || !p.rate_uzs) return ''
  const v = uzs / p.rate_uzs
  const s = v.toLocaleString('ru-RU', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  return p.currency === 'USD' ? '$' + s : s + ' ₽'
}

function plural(n: number, one: string, few: string, many: string) {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}

type Preset = 'today' | 'week' | 'month' | 'prev'

function presetRange(p: Preset): [dayjs.Dayjs, dayjs.Dayjs] {
  const t = dayjs().startOf('day')
  switch (p) {
    case 'today':
      return [t, t]
    case 'week':
      return [t.subtract(6, 'day'), t]
    case 'prev':
      return [t.subtract(1, 'month').startOf('month'), t.subtract(1, 'month').endOf('month').startOf('day')]
    default:
      return [t.startOf('month'), t]
  }
}

function Kpi({ icon, bg, fg, title, value, sub }: { icon: ReactNode; bg: string; fg: string; title: string; value: string; sub: string }) {
  return (
    <Card styles={{ body: { padding: '18px 20px' } }} style={{ height: '100%' }}>
      <Flex align="center" gap={8}>
        <Flex align="center" justify="center" style={{ width: 28, height: 28, borderRadius: 8, background: bg, color: fg }}>
          {icon}
        </Flex>
        <Typography.Text type="secondary" strong style={{ fontSize: 13 }}>
          {title}
        </Typography.Text>
      </Flex>
      <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{value}</div>
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
        {sub}
      </Typography.Text>
    </Card>
  )
}

function Chart({ days, mode, prices }: { days: Day[]; mode: 'money' | 'tokens'; prices: Prices }) {
  const val = (d: Day) => (mode === 'money' ? d.cost_uzs : d.input_tokens + d.output_tokens)
  const max = Math.max(1, ...days.map(val))
  const peak = days.reduce((b, d, i) => (val(d) > val(days[b] ?? d) ? i : b), 0)
  const today = dayjs().format('YYYY-MM-DD')
  if (!days.some((d) => val(d) > 0)) return <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="За этот период запросов к ИИ не было" />
  const step = Math.max(1, Math.ceil(days.length / 6))
  return (
    <>
      <Flex align="flex-end" gap={days.length > 40 ? 2 : 6} style={{ height: 170 }}>
        {days.map((d, i) => {
          const v = val(d)
          const future = d.date > today
          return (
            <Tooltip
              key={d.date}
              title={`${dayjs(d.date).format('D MMMM')} · ${sum(d.cost_uzs)}${inCurrency(d.cost_uzs, prices) ? ' (' + inCurrency(d.cost_uzs, prices) + ')' : ''} · ${tokens(d.input_tokens + d.output_tokens)} токенов · запросов ${d.requests}`}
            >
              <div
                style={{
                  flex: 1,
                  minWidth: 2,
                  height: Math.max(2, (v / max) * 170),
                  borderRadius: '3px 3px 0 0',
                  background: future || v === 0 ? '#EAECF0' : i === peak ? '#E11D2A' : '#F7A7AD',
                }}
              />
            </Tooltip>
          )
        })}
      </Flex>
      <Flex justify="space-between" style={{ marginTop: 8 }}>
        {days
          .filter((_, i) => i % step === 0 || i === days.length - 1)
          .map((d) => (
            <Typography.Text key={d.date} type="secondary" style={{ fontSize: 11 }}>
              {dayjs(d.date).format('D MMM')}
            </Typography.Text>
          ))}
      </Flex>
    </>
  )
}

function PricesModal({ open, prices, onClose }: { open: boolean; prices: Prices; onClose: () => void }) {
  const [form] = Form.useForm<Prices>()
  const currency = Form.useWatch('currency', form) ?? prices.currency
  const save = useAction((v: Prices) => api.put<Prices>('/admin/ai/prices', v), { success: 'Цена сохранена', invalidate: [['/admin/ai/usage']] })
  return (
    <Modal
      title="Цена токенов"
      open={open}
      onCancel={onClose}
      okText="Сохранить"
      cancelText="Отмена"
      confirmLoading={save.isPending}
      onOk={() => form.validateFields().then((v) => save.mutateAsync(v).then(onClose))}
      destroyOnClose
    >
      <Typography.Paragraph type="secondary">
        Цена за 1 млн токенов из прайса вашего сервиса. У посредников (OpenRouter, RelayModels) — их цена с учётом множителя модели.
        Новые запросы считаются по новой цене, старые не пересчитываются.
      </Typography.Paragraph>
      <Form form={form} layout="vertical" initialValues={prices} requiredMark={false} preserve={false}>
        <Form.Item name="currency" label="Валюта цены">
          <Select
            options={[
              { value: 'USD', label: 'Доллары ($)' },
              { value: 'RUB', label: 'Рубли (₽)' },
              { value: 'UZS', label: 'Сумы' },
            ]}
          />
        </Form.Item>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item name="price_in" label="Вход (запрос и фото) за 1 млн" rules={[{ required: true, message: 'Укажите цену' }]}>
              <InputNumber min={0} step={0.01} style={{ width: '100%' }} addonAfter={SIGN[currency as Currency]} />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="price_out" label="Выход (ответ модели) за 1 млн" rules={[{ required: true, message: 'Укажите цену' }]}>
              <InputNumber min={0} step={0.01} style={{ width: '100%' }} addonAfter={SIGN[currency as Currency]} />
            </Form.Item>
          </Col>
        </Row>
        {currency !== 'UZS' && (
          <Form.Item name="rate_uzs" label={`Курс: сколько сумов в 1 ${SIGN[currency as Currency]}`} rules={[{ required: true, message: 'Укажите курс' }]}>
            <InputNumber min={0.0001} style={{ width: '100%' }} addonAfter="сум" />
          </Form.Item>
        )}
      </Form>
    </Modal>
  )
}

/** Магазины сети — раскрытая строка таблицы «по сетям». */
function NetworkStores({ networkId, params, prices, total }: { networkId: string; params: Record<string, string>; prices: Prices; total: number }) {
  const { data, isLoading } = useItem<Report>('/admin/ai/usage', { ...params, group: 'store', network_id: networkId })
  return (
    <Table<Item>
      size="small"
      rowKey={(r) => r.id || 'test'}
      loading={isLoading}
      pagination={false}
      showHeader={false}
      dataSource={data?.items ?? []}
      columns={columns('store', prices, total)}
    />
  )
}

function columns(group: Group, prices: Prices, total: number) {
  const title = { network: 'Сеть', store: 'Магазин', employee: 'Сотрудник' }[group]
  return [
    {
      title,
      key: 'name',
      render: (_: unknown, r: Item) => {
        const sub =
          group === 'network' && r.id
            ? `${r.stores} ${plural(r.stores, 'магазин', 'магазина', 'магазинов')} · ${r.employees} ${plural(r.employees, 'сотрудник', 'сотрудника', 'сотрудников')}`
            : r.sub
        return (
          <Flex vertical>
            <Typography.Text strong={group === 'network'}>
              {!r.id && <ThunderboltOutlined style={{ color: '#B54708', marginRight: 6 }} />}
              {r.name}
            </Typography.Text>
            {sub && (
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {sub}
              </Typography.Text>
            )}
          </Flex>
        )
      },
    },
    {
      title: 'Накладных',
      key: 'invoices',
      width: 180,
      render: (_: unknown, r: Item) =>
        (r.id ? r.invoices : r.requests) + (r.photos ? ` · фото полок ${r.photos}` : '') + (r.product_photos ? ` · фото товаров ${r.product_photos}` : '') + (r.store_photos ? ` · фото магазинов ${r.store_photos}` : '') + (r.errors ? ` · ошибок ${r.errors}` : ''),
    },
    { title: 'Токены вход', dataIndex: 'input_tokens', width: 120, render: tokens },
    { title: 'Токены выход', dataIndex: 'output_tokens', width: 120, render: tokens },
    {
      title: 'Стоимость',
      dataIndex: 'cost_uzs',
      width: 170,
      render: (v: number) => (
        <Flex vertical>
          <Typography.Text strong>{sum(v)}</Typography.Text>
          {inCurrency(v, prices) && (
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {inCurrency(v, prices)}
            </Typography.Text>
          )}
        </Flex>
      ),
    },
    {
      title: 'Доля',
      key: 'share',
      width: 220,
      render: (_: unknown, r: Item) => {
        const share = total > 0 ? Math.round((r.cost_uzs / total) * 1000) / 10 : r.share
        return (
          <Flex align="center" gap={8}>
            <div style={{ width: 140, height: 6, borderRadius: 3, background: '#F2F4F7' }}>
              <div style={{ width: `${Math.min(100, share)}%`, minWidth: 2, height: 6, borderRadius: 3, background: '#E11D2A' }} />
            </div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {share.toLocaleString('ru-RU')}%
            </Typography.Text>
          </Flex>
        )
      },
    },
  ]
}

function downloadCsv(rep: Report, group: Group) {
  const head = ['Название', 'Где', 'Запросов', 'Накладных', 'Фото полок', 'Ошибок', 'Токены вход', 'Токены выход', 'Стоимость, сум']
  const rows = rep.items.map((r) => [r.name, r.sub, r.requests, r.invoices, r.photos, r.errors, r.input_tokens, r.output_tokens, r.cost_uzs.toFixed(2).replace('.', ',')])
  const days = rep.days.map((d) => [d.date, '', d.requests, '', '', '', d.input_tokens, d.output_tokens, d.cost_uzs.toFixed(2).replace('.', ',')])
  const esc = (v: unknown) => `"${String(v).replace(/"/g, '""')}"`
  const lines = [head, ...rows, [], ['По дням'], ...days].map((r) => r.map(esc).join(';'))
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `ИИ-расход_${group}_${rep.from.slice(0, 10)}.csv`
  a.click()
  URL.revokeObjectURL(a.href)
}

export function AIUsage() {
  const [preset, setPreset] = useState<Preset | 'custom'>('month')
  const [range, setRange] = useState<[dayjs.Dayjs, dayjs.Dayjs]>(presetRange('month'))
  const [group, setGroup] = useState<Group>('network')
  const [mode, setMode] = useState<'money' | 'tokens'>('money')
  const [editPrices, setEditPrices] = useState(false)
  const params = useMemo(() => ({ from: range[0].format('YYYY-MM-DD'), to: range[1].add(1, 'day').format('YYYY-MM-DD') }), [range])
  const { data: rep, error, refetch, isLoading } = useItem<Report>('/admin/ai/usage', { ...params, group })

  const t = rep?.totals
  const p = rep?.prices ?? { price_in: 0, price_out: 0, currency: 'USD' as Currency, rate_uzs: 1 }
  const noPrice = !!rep && p.price_in === 0 && p.price_out === 0
  const perInvoice = t && t.requests > 0 ? t.cost_uzs / t.requests : 0
  const perInvoiceTokens = t && t.requests > 0 ? (t.input_tokens + t.output_tokens) / t.requests : 0
  // Прогноз — только для текущего месяца: расход в день × дней в месяце.
  const now = dayjs()
  const thisMonth = range[0].isSame(now.startOf('month'), 'day') && !range[1].isBefore(now, 'day')
  const forecast = t && thisMonth ? (t.cost_uzs / now.date()) * now.daysInMonth() : null

  return (
    <>
      <LoadError error={error} retry={() => refetch()} />
      <Flex gap={12} wrap="wrap" align="center" style={{ marginBottom: 16 }}>
        <Segmented<Preset | 'custom'>
          value={preset}
          onChange={(v) => {
            setPreset(v)
            if (v !== 'custom') setRange(presetRange(v))
          }}
          options={[
            { value: 'today', label: 'Сегодня' },
            { value: 'week', label: '7 дней' },
            { value: 'month', label: 'Этот месяц' },
            { value: 'prev', label: 'Прошлый месяц' },
          ]}
        />
        <DatePicker.RangePicker
          value={range}
          format="DD.MM.YYYY"
          allowClear={false}
          onChange={(v) => {
            if (v?.[0] && v[1]) {
              setRange([v[0].startOf('day'), v[1].startOf('day')])
              setPreset('custom')
            }
          }}
        />
        <div style={{ flex: 1 }} />
        <Button icon={<DownloadOutlined />} disabled={!rep} onClick={() => rep && downloadCsv(rep, group)}>
          Excel
        </Button>
      </Flex>

      <Row gutter={[16, 16]}>
        <Col xs={24} sm={12} xl={6}>
          <Kpi
            icon={<DollarOutlined />}
            bg="#FEF3F2"
            fg="#E11D2A"
            title="Потрачено"
            value={t ? sum(t.cost_uzs) : '…'}
            sub={noPrice ? 'Укажите цену токенов — справа' : t ? [inCurrency(t.cost_uzs, p), p.currency !== 'UZS' ? `курс 1 ${SIGN[p.currency]} = ${money(p.rate_uzs)} сум` : ''].filter(Boolean).join(' · ') : ''}
          />
        </Col>
        <Col xs={24} sm={12} xl={6}>
          <Kpi
            icon={<CalculatorOutlined />}
            bg="#EEF3FB"
            fg="#3B6FD8"
            title="Токенов"
            value={t ? tokens(t.input_tokens + t.output_tokens) : '…'}
            sub={t ? `вход ${tokens(t.input_tokens)} · выход ${tokens(t.output_tokens)}` : ''}
          />
        </Col>
        <Col xs={24} sm={12} xl={6}>
          <Kpi
            icon={<FileSearchOutlined />}
            bg="#ECFDF3"
            fg="#12B76A"
            title="Накладных прочитано"
            value={t ? money(t.invoices) : '…'}
            sub={t ? `фото полок ${t.photos} · фото товаров ${t.product_photos ?? 0} · фото магазинов ${t.store_photos ?? 0} · ошибок ${t.errors} · проверок ${t.tests}` : ''}
          />
        </Col>
        <Col xs={24} sm={12} xl={6}>
          <Kpi
            icon={<InfoCircleOutlined />}
            bg="#FFFAEB"
            fg="#B54708"
            title="Одна накладная"
            value={t ? (perInvoice > 0 ? '≈ ' + sum(perInvoice) : '—') : '…'}
            sub={t && t.requests > 0 ? [`≈ ${tokens(Math.round(perInvoiceTokens))} токенов`, forecast !== null && forecast > 0 ? `прогноз ${sum(forecast)}` : ''].filter(Boolean).join(' · ') : 'нет запросов'}
          />
        </Col>

        <Col xs={24} xl={16}>
          <Card
            loading={isLoading}
            title="Расход по дням"
            extra={
              <Segmented
                size="small"
                value={mode}
                onChange={(v) => setMode(v as 'money' | 'tokens')}
                options={[
                  { value: 'money', label: 'Сумы' },
                  { value: 'tokens', label: 'Токены' },
                ]}
              />
            }
          >
            {rep && <Chart days={rep.days} mode={mode} prices={p} />}
          </Card>
        </Col>
        <Col xs={24} xl={8}>
          <Card
            title="Цена токенов"
            extra={
              <Button type="link" danger onClick={() => setEditPrices(true)} disabled={!rep}>
                Изменить
              </Button>
            }
          >
            <Typography.Paragraph type="secondary" style={{ fontSize: 12 }}>
              По ней считаем деньги. Укажите цену из прайса вашего сервиса — она у каждой модели своя.
            </Typography.Paragraph>
            {[
              ['Модель', rep?.model || '—'],
              ['Вход (запрос и фото)', noPrice ? 'не указана' : `${SIGN[p.currency] === '$' ? '$' + p.price_in : p.price_in + ' ' + SIGN[p.currency]} за 1 млн`],
              ['Выход (ответ модели)', noPrice ? 'не указана' : `${SIGN[p.currency] === '$' ? '$' + p.price_out : p.price_out + ' ' + SIGN[p.currency]} за 1 млн`],
              ...(p.currency !== 'UZS' ? [['Курс для сумов', `1 ${SIGN[p.currency]} = ${money(p.rate_uzs)} сум`]] : []),
            ].map(([k, v]) => (
              <Flex key={k} justify="space-between" style={{ padding: '9px 0', borderBottom: '1px solid #EAECF0' }}>
                <Typography.Text type="secondary">{k}</Typography.Text>
                <Typography.Text strong>{v}</Typography.Text>
              </Flex>
            ))}
            <Flex gap={8} style={{ marginTop: 12, padding: '10px 12px', background: '#F2F4F7', borderRadius: 10 }}>
              <InfoCircleOutlined style={{ color: '#667085', marginTop: 3 }} />
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                Сменили модель или цену — новые запросы считаются по новой цене, старые не пересчитываются.
              </Typography.Text>
            </Flex>
          </Card>
        </Col>

        <Col span={24}>
          <Card
            title="Кто сколько использует"
            extra={
              <Segmented
                size="small"
                value={group}
                onChange={(v) => setGroup(v as Group)}
                options={[
                  { value: 'network', label: 'По сетям' },
                  { value: 'store', label: 'По магазинам' },
                  { value: 'employee', label: 'По сотрудникам' },
                ]}
              />
            }
          >
            <Table<Item>
              rowKey={(r) => r.id || 'test'}
              loading={isLoading}
              pagination={false}
              dataSource={rep?.items ?? []}
              locale={{ emptyText: 'За этот период запросов к ИИ не было' }}
              columns={columns(group, p, t?.cost_uzs ?? 0)}
              expandable={
                group === 'network'
                  ? {
                      rowExpandable: (r) => !!r.id && r.stores > 0,
                      expandedRowRender: (r) => <NetworkStores networkId={r.id} params={params} prices={p} total={t?.cost_uzs ?? 0} />,
                    }
                  : undefined
              }
            />
          </Card>
        </Col>
      </Row>
      {rep && <PricesModal open={editPrices} prices={p} onClose={() => setEditPrices(false)} />}
    </>
  )
}
