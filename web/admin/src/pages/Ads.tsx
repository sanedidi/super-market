// «Каталог → Реклама брендов» (Figma «Витрина · монетизация», раздел 4):
// кампании брендов, правила для сетей, счета и акты рекламодателям.
import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import {
  App,
  Button,
  Card,
  DatePicker,
  Divider,
  Form,
  Input,
  InputNumber,
  Modal,
  Segmented,
  Select,
  Space,
  Switch,
  Table,
  Tabs,
  Tag,
  Typography,
} from 'antd'
import { PlusOutlined, SettingOutlined, WarningFilled } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { BannerUpload, CrudPage, LoadError, PageTitle, RemoteSelect, api, date, errorText, money, useAction, useItem, useList } from '@sm/shared'
import { SearchSelect } from '../components'

interface Named {
  id: string
  name: string
}

interface Campaign {
  id: string
  advertiser_id: string
  advertiser_name: string
  brand_id: string
  brand_name: string
  format: 'shelf' | 'banner'
  title: string
  subtitle: string
  image_url: string
  products: Named[]
  networks: Named[]
  cities: string[]
  place: 'after_platform' | 'end'
  starts_at: string
  ends_at: string
  pricing: 'period' | 'cpm'
  price: string
  impression_limit: number | null
  paused: boolean
  status: 'scheduled' | 'running' | 'paused' | 'limit' | 'finished'
  views: number
  billable_views: number
  clicks: number
  orders: number
  sales: string
  accrued: string
  invoiced: string
}

interface Summary {
  active: number
  views_7d: number
  clicks_7d: number
  accrued_month: string
  invoiced_month: string
}

const STATUS: Record<Campaign['status'], { color: string; label: string }> = {
  running: { color: 'green', label: 'Идёт' },
  scheduled: { color: 'blue', label: 'Скоро' },
  paused: { color: 'default', label: 'Пауза' },
  limit: { color: 'gold', label: 'Лимит показов' },
  finished: { color: 'default', label: 'Завершена' },
}

const TONES = ['#E11D2A', '#3B6FD8', '#E8850C', '#2E9E5B', '#7C5CD6']
const num = (v: number) => v.toLocaleString('ru-RU')

function Kpi({ label, value, note }: { label: string; value: string; note?: string }) {
  return (
    <Card style={{ flex: '1 1 200px' }} styles={{ body: { padding: 18 } }}>
      <Typography.Text type="secondary">{label}</Typography.Text>
      <div style={{ fontSize: 26, fontWeight: 800, lineHeight: 1.3 }}>{value}</div>
      {note && <Typography.Text style={{ color: '#17b26a', fontSize: 12 }}>{note}</Typography.Text>}
    </Card>
  )
}

/** Правила рекламы для сетей и реквизиты платформы для счетов и актов. */
function RulesModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { data } = useItem<Record<string, unknown>>(open ? '/admin/ads/settings' : null)
  const [form] = Form.useForm()
  useEffect(() => {
    if (data) form.setFieldsValue({ ...data, network_share_pct: Number(data.network_share_pct) })
  }, [data, form])
  const save = useAction((v: Record<string, unknown>) => api.put('/admin/ads/settings', { ...v, network_share_pct: String(v.network_share_pct ?? 0) }), {
    success: 'Правила сохранены',
  })
  return (
    <Modal open={open} onCancel={onClose} title="Правила рекламы для сетей" okText="Сохранить" cancelText="Отмена" onOk={() => form.submit()} width={620}
      confirmLoading={save.isPending}>
      <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Form.Item name="network_share_pct" label="Доля сети с рекламы в её магазинах" extra="От оплаты бренда за показы в магазинах сети. 0% — сети ничего не получают.">
          <InputNumber min={0} max={100} precision={2} addonAfter="%" style={{ width: 180 }} />
        </Form.Item>
        <Form.Item name="share_to_subscription" valuePropName="checked" label="Доля — в зачёт подписки" extra="Сумма уменьшает ближайший счёт; остаток — на баланс платформы сети. Выключено — вся доля на баланс.">
          <Switch />
        </Form.Item>
        <Form.Item name="allow_hide_brands" valuePropName="checked" label="Сети могут скрывать бренды" extra="Кампания не показывается в магазинах сети, доля с неё не начисляется.">
          <Switch />
        </Form.Item>
        <Form.Item name="allow_exclude_categories" valuePropName="checked" label="Сети могут исключать категории" extra="Например, своя марка воды — чужая вода не рекламируется.">
          <Switch />
        </Form.Item>
        <Typography.Paragraph type="secondary">
          Сколько рекламных блоков на главной по тарифу и можно ли меньше — в «Подписка → Тарифы витрины».
        </Typography.Paragraph>
        <Divider orientation="left">Реквизиты Super Market для счетов и актов</Divider>
        <Form.Item name="company_name" label="Исполнитель (юрлицо)">
          <Input placeholder="ООО «Super Market»" />
        </Form.Item>
        <Space wrap>
          <Form.Item name="company_inn" label="ИНН">
            <Input style={{ width: 180 }} />
          </Form.Item>
          <Form.Item name="company_mfo" label="МФО">
            <Input style={{ width: 120 }} />
          </Form.Item>
          <Form.Item name="company_account" label="Расчётный счёт">
            <Input style={{ width: 240 }} />
          </Form.Item>
        </Space>
        <Form.Item name="company_bank" label="Банк">
          <Input />
        </Form.Item>
        <Form.Item name="company_address" label="Адрес">
          <Input />
        </Form.Item>
        <Form.Item name="company_director" label="Директор (подпись)">
          <Input />
        </Form.Item>
      </Form>
    </Modal>
  )
}

/** Рекламодатель: юрлицо бренда и договор. */
function AdvertiserForm() {
  return (
    <>
      <Form.Item name="name" label="Юрлицо" rules={[{ required: true, message: 'Укажите юрлицо' }]}>
        <Input placeholder="ООО «Sharq Ichimliklari»" />
      </Form.Item>
      <Space wrap>
        <Form.Item name="inn" label="ИНН">
          <Input style={{ width: 180 }} />
        </Form.Item>
        <Form.Item name="mfo" label="МФО">
          <Input style={{ width: 120 }} />
        </Form.Item>
        <Form.Item name="account" label="Расчётный счёт">
          <Input style={{ width: 240 }} />
        </Form.Item>
      </Space>
      <Form.Item name="bank" label="Банк">
        <Input />
      </Form.Item>
      <Form.Item name="address" label="Адрес">
        <Input />
      </Form.Item>
      <Space wrap>
        <Form.Item name="contract_number" label="Договор №">
          <Input style={{ width: 160 }} />
        </Form.Item>
        <Form.Item name="contract_date" label="от">
          <Input type="date" style={{ width: 170 }} />
        </Form.Item>
      </Space>
      <Form.Item name="contact" label="Контакт">
        <Input placeholder="Имя, телефон" />
      </Form.Item>
    </>
  )
}

function NewAdvertiser({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (a: Named) => void }) {
  const [form] = Form.useForm()
  const save = useAction((v: Record<string, unknown>) => api.post<Named>('/admin/ads/advertisers', v), { success: 'Рекламодатель добавлен' })
  return (
    <Modal open={open} onCancel={onClose} title="Новый рекламодатель" okText="Добавить" cancelText="Отмена" onOk={() => form.submit()}
      confirmLoading={save.isPending} destroyOnClose>
      <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: (a) => { onCreated(a); onClose() } })}>
        <AdvertiserForm />
      </Form>
    </Modal>
  )
}

/** Редактор кампании (правая панель макета). */
function CampaignEditor({ campaign, onSaved }: { campaign: Campaign | null; onSaved: (c: Campaign) => void }) {
  const [form] = Form.useForm()
  const { message } = App.useApp()
  const [newAdv, setNewAdv] = useState(false)
  const [busy, setBusy] = useState(false)
  const [invoice, setInvoice] = useState(false)
  const brand = Form.useWatch('brand_id', form) as string | undefined
  const format = (Form.useWatch('format', form) as string | undefined) ?? 'shelf'
  const pricing = (Form.useWatch('pricing', form) as string | undefined) ?? 'period'
  useEffect(() => {
    form.resetFields()
    if (campaign) {
      form.setFieldsValue({
        ...campaign,
        product_ids: campaign.products.map((p) => p.id),
        network_ids: campaign.networks.map((n) => n.id),
        period: [dayjs(campaign.starts_at), dayjs(campaign.ends_at)],
        price: Number(campaign.price),
        impression_limit: campaign.impression_limit ?? undefined,
      })
    } else {
      form.setFieldsValue({ format: 'shelf', place: 'after_platform', pricing: 'period', network_ids: [], cities: [] })
    }
  }, [campaign, form])
  const cities = useList<string>('/admin/ads/cities')
  const report = useList<{ network_id: string; network_name: string; billable_views: number; views: number; clicks: number; orders: number; sales: string; suspicious: boolean }>(
    campaign ? `/admin/ads/campaigns/${campaign.id}/report` : null,
  )

  const submit = async (v: Record<string, unknown>) => {
    const period = v.period as [Dayjs, Dayjs]
    const body = {
      advertiser_id: v.advertiser_id,
      brand_id: v.brand_id,
      format: v.format,
      title: v.title,
      subtitle: v.subtitle ?? '',
      image_url: v.image_url ?? '',
      product_ids: v.product_ids ?? [],
      network_ids: v.network_ids ?? [],
      cities: v.cities ?? [],
      place: v.place,
      starts_at: period[0].startOf('day').toISOString(),
      ends_at: period[1].endOf('day').toISOString(),
      pricing: v.pricing,
      price: String(v.price ?? 0),
      impression_limit: v.impression_limit ?? 0,
      paused: v.paused ?? false,
    }
    setBusy(true)
    try {
      const c = campaign ? await api.patch<Campaign>(`/admin/ads/campaigns/${campaign.id}`, body) : await api.post<Campaign>('/admin/ads/campaigns', body)
      message.success(campaign ? 'Кампания сохранена' : 'Кампания создана')
      onSaved(c)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card title={campaign ? `Кампания · ${campaign.brand_name}` : 'Новая кампания'} style={{ flex: '0 0 420px', minWidth: 340 }}>
      <Form form={form} layout="vertical" onFinish={submit} requiredMark={false}>
        <Form.Item label="Рекламодатель" required>
          <Space.Compact style={{ width: '100%' }}>
            <Form.Item name="advertiser_id" noStyle rules={[{ required: true, message: 'Выберите' }]}>
              <SearchSelect path="/admin/ads/advertisers" known={{ id: campaign?.advertiser_id, label: campaign?.advertiser_name }} style={{ width: '100%' }} placeholder="Юрлицо бренда" />
            </Form.Item>
            <Button icon={<PlusOutlined />} onClick={() => setNewAdv(true)} />
          </Space.Compact>
        </Form.Item>
        <Form.Item name="brand_id" label="Бренд" rules={[{ required: true, message: 'Выберите бренд' }]}>
          <SearchSelect path="/admin/catalog/brands" known={{ id: campaign?.brand_id, label: campaign?.brand_name }} placeholder="Бренд товаров"
            onChange={() => form.setFieldValue('product_ids', [])} />
        </Form.Item>
        <Form.Item name="format" label="Формат">
          <Segmented block options={[{ value: 'shelf', label: 'Полка товаров' }, { value: 'banner', label: 'Фото-баннер' }]} />
        </Form.Item>
        <Form.Item name="title" label={format === 'banner' ? 'Подпись на баннере' : 'Заголовок полки'} rules={[{ required: true, message: 'Введите заголовок' }]}>
          <Input maxLength={60} placeholder="Освежиться" />
        </Form.Item>
        {format === 'banner' && (
          <>
            <Form.Item name="subtitle" label="Подзаголовок">
              <Input maxLength={80} />
            </Form.Item>
            <Form.Item name="image_url" label="Фото баннера" rules={[{ required: true, message: 'Загрузите фото' }]} extra="1080 × 450; нажатие откроет первый товар бренда в магазине">
              <BannerUpload hint="Фото баннера" />
            </Form.Item>
          </>
        )}
        <Form.Item name="product_ids" label="Товары бренда" rules={[{ required: true, message: 'Выберите товары' }]}
          extra="Блок показывается только в магазинах, где эти товары есть в наличии.">
          <RemoteSelect key={brand ?? 'none'} mode="multiple" search path="/admin/products" params={{ brand_id: brand }} disabled={!brand}
            placeholder={brand ? 'Найти товар' : 'Сначала выберите бренд'} style={{ width: '100%' }} />
        </Form.Item>
        <Form.Item name="network_ids" label="Где показывать" extra="Пусто — во всех сетях">
          <RemoteSelect mode="multiple" path="/admin/networks" placeholder="Все сети" style={{ width: '100%' }} />
        </Form.Item>
        <Form.Item name="cities" label="Города" extra="Пусто — во всех городах. Город магазина задаётся в его настройках.">
          <Select mode="tags" options={(cities.data ?? []).map((c) => ({ value: c, label: c }))} placeholder="Все города" style={{ width: '100%' }} />
        </Form.Item>
        <Form.Item name="place" label="Место на главной">
          <Segmented block options={[{ value: 'after_platform', label: 'После блоков платформы' }, { value: 'end', label: 'В конце' }]} />
        </Form.Item>
        <Form.Item name="period" label="Даты" rules={[{ required: true, message: 'Укажите даты' }]}>
          <DatePicker.RangePicker format="DD.MM.YYYY" style={{ width: '100%' }} />
        </Form.Item>
        <Form.Item name="pricing" label="Оплата">
          <Segmented block options={[{ value: 'period', label: 'За период' }, { value: 'cpm', label: 'За 1000 показов' }]} />
        </Form.Item>
        <Space.Compact block>
          <Form.Item name="price" rules={[{ required: true, message: 'Цена' }]} style={{ flex: 1 }}>
            <InputNumber min={1} step={100000} addonAfter={pricing === 'cpm' ? 'сум / 1000' : 'сум'} style={{ width: '100%' }} />
          </Form.Item>
        </Space.Compact>
        <Form.Item name="impression_limit" label="Лимит оплачиваемых показов" extra="Пусто — без лимита; кампания остановится сама">
          <InputNumber min={0} step={10000} style={{ width: '100%' }} placeholder="без лимита" />
        </Form.Item>
        {campaign && (
          <Form.Item name="paused" label="Пауза" valuePropName="checked">
            <Switch />
          </Form.Item>
        )}
        <div className="ads-note">
          <WarningFilled /> Показ — только где есть товар, всегда с пометкой «Реклама», не больше двух на главной. Сеть может скрыть бренд или категорию у себя —
          там кампания не показывается и доля сети не начисляется. Оплачиваемый показ — вошедший покупатель, один раз в день.
        </div>
        <Space style={{ marginTop: 16 }}>
          <Button type="primary" htmlType="submit" loading={busy}>
            {campaign ? 'Сохранить' : 'Создать кампанию'}
          </Button>
          {campaign && <Button onClick={() => setInvoice(true)}>Выставить счёт</Button>}
        </Space>
      </Form>
      {campaign && (
        <>
          <Divider orientation="left">По сетям</Divider>
          <LoadError error={report.error} retry={report.refetch} />
          <Table
            size="small"
            rowKey="network_id"
            pagination={false}
            dataSource={report.data ?? []}
            locale={{ emptyText: 'Показов пока нет' }}
            columns={[
              { title: 'Сеть', dataIndex: 'network_name', render: (v, r) => <>{v} {r.suspicious && <Tag color="red">проверить</Tag>}</> },
              { title: 'Показы', dataIndex: 'billable_views', align: 'right', render: num },
              { title: 'Нажатия', dataIndex: 'clicks', align: 'right', render: num },
              { title: 'Заказы', dataIndex: 'orders', align: 'right' },
            ]}
          />
          {(report.data ?? []).some((r) => r.suspicious) && (
            <Typography.Paragraph type="danger" style={{ marginTop: 8, fontSize: 12 }}>
              «Проверить» — много оплачиваемых показов, а нажатий и покупок почти нет. Возможна накрутка показов.
            </Typography.Paragraph>
          )}
          <InvoiceModal campaign={campaign} open={invoice} onClose={() => setInvoice(false)} />
        </>
      )}
      <NewAdvertiser open={newAdv} onClose={() => setNewAdv(false)} onCreated={(a) => form.setFieldValue('advertiser_id', a.id)} />
    </Card>
  )
}

function InvoiceModal({ campaign, open, onClose }: { campaign: Campaign; open: boolean; onClose: () => void }) {
  const [range, setRange] = useState<[Dayjs, Dayjs]>([dayjs().subtract(1, 'month').startOf('month'), dayjs().subtract(1, 'month').endOf('month')])
  const [amount, setAmount] = useState<number | null>(null)
  const from = range[0].format('YYYY-MM-DD')
  const to = range[1].format('YYYY-MM-DD')
  const est = useItem<{ views: number; amount: string }>(open ? `/admin/ads/campaigns/${campaign.id}/estimate` : null, { from, to })
  const create = useAction(() => api.post('/admin/ads/invoices', { campaign_id: campaign.id, period_from: from, period_to: to, amount: amount ? String(amount) : undefined }), {
    success: 'Счёт выставлен — он в разделе «Счета и акты»',
  })
  return (
    <Modal open={open} onCancel={onClose} title={`Счёт бренду · ${campaign.brand_name}`} okText="Выставить" cancelText="Отмена" confirmLoading={create.isPending}
      onOk={() => create.mutate(undefined, { onSuccess: onClose })}>
      <Form layout="vertical">
        <Form.Item label="Период">
          <DatePicker.RangePicker value={range} onChange={(v) => v && setRange(v as [Dayjs, Dayjs])} format="DD.MM.YYYY" />
        </Form.Item>
        <Form.Item label="Сумма, сум" extra={est.data ? `По расчёту: ${money(est.data.amount)} сум · оплачиваемых показов ${num(est.data.views)}` : ' '}>
          <InputNumber value={amount ?? (est.data ? Number(est.data.amount) : null)} onChange={(v) => setAmount(v)} min={1} style={{ width: 220 }} />
        </Form.Item>
        <Typography.Text type="secondary">Предмет: «Размещение рекламных материалов за {range[0].format('DD.MM.YYYY')}–{range[1].format('DD.MM.YYYY')}».</Typography.Text>
      </Form>
    </Modal>
  )
}

function Campaigns() {
  const qc = useQueryClient()
  const summary = useItem<Summary>('/admin/ads/summary')
  const list = useList<Campaign>('/admin/ads/campaigns', { limit: 200 })
  const [selected, setSelected] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const current = creating ? null : (list.data ?? []).find((c) => c.id === selected) ?? null
  const s = summary.data
  return (
    <>
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
        <Kpi label="Активных кампаний" value={s ? String(s.active) : '…'} />
        <Kpi label="Показы за 7 дней" value={s ? num(s.views_7d) : '…'} />
        <Kpi label="Нажатия" value={s ? num(s.clicks_7d) : '…'} note={s && s.views_7d ? `${((s.clicks_7d / s.views_7d) * 100).toFixed(1)}% от показов` : undefined} />
        <Kpi label="Начислено за месяц" value={s ? `${money(s.accrued_month)} сум` : '…'} note={s ? `выставлено счетов на ${money(s.invoiced_month)} сум` : undefined} />
      </div>
      <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        <Card title="Кампании" style={{ flex: '1 1 560px' }} styles={{ body: { padding: 0 } }}
          extra={<Button type="primary" icon={<PlusOutlined />} onClick={() => { setCreating(true); setSelected(null) }}>Новая кампания</Button>}>
          <LoadError error={list.error} retry={list.refetch} />
          <Table<Campaign>
            rowKey="id"
            loading={list.isLoading}
            dataSource={list.data ?? []}
            pagination={false}
            onRow={(c) => ({ onClick: () => { setCreating(false); setSelected(c.id) }, style: { cursor: 'pointer', background: c.id === selected && !creating ? '#f5f8ff' : undefined } })}
            locale={{ emptyText: 'Кампаний пока нет' }}
            columns={[
              {
                title: 'Бренд',
                render: (_, c, i) => (
                  <Space>
                    <span style={{ display: 'inline-flex', width: 32, height: 32, borderRadius: 8, background: TONES[i % TONES.length], color: '#fff', fontWeight: 700, alignItems: 'center', justifyContent: 'center' }}>
                      {c.brand_name.slice(0, 1)}
                    </span>
                    <span>
                      <b>{c.brand_name}</b>
                      <br />
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>{c.title}</Typography.Text>
                    </span>
                  </Space>
                ),
              },
              { title: 'Формат', dataIndex: 'format', render: (v) => (v === 'shelf' ? 'Полка' : 'Фото-баннер') },
              {
                title: 'Где',
                render: (_, c) => (
                  <>
                    {c.networks.length ? c.networks.map((n) => n.name).join(', ') : 'Все сети'}
                    {c.cities.length > 0 && (
                      <>
                        <br />
                        <Typography.Text type="secondary" style={{ fontSize: 12 }}>{c.cities.join(', ')}</Typography.Text>
                      </>
                    )}
                  </>
                ),
              },
              { title: 'Даты', render: (_, c) => `${dayjs(c.starts_at).format('D MMM')} – ${dayjs(c.ends_at).subtract(1, 'second').format('D MMM')}` },
              { title: 'Показы', dataIndex: 'billable_views', align: 'right', render: (v: number) => (v ? num(v) : '—') },
              { title: 'Начислено', dataIndex: 'accrued', align: 'right', render: (v: string) => money(v) },
              { title: 'Статус', dataIndex: 'status', render: (v: Campaign['status']) => <Tag color={STATUS[v].color}>{STATUS[v].label}</Tag> },
            ]}
          />
        </Card>
        {(creating || current) && (
          <CampaignEditor
            key={current?.id ?? 'new'}
            campaign={current}
            onSaved={(c) => {
              qc.invalidateQueries({ queryKey: ['/admin/ads/campaigns'] })
              qc.invalidateQueries({ queryKey: ['/admin/ads/summary'] })
              setCreating(false)
              setSelected(c.id)
            }}
          />
        )}
      </div>
    </>
  )
}

interface AdInvoice {
  id: string
  number: number
  campaign_title: string
  brand_name: string
  advertiser_name: string
  period_from: string
  period_to: string
  views: number
  amount: string
  status: 'unpaid' | 'paid' | 'cancelled'
  act_number: number | null
  subject: string
  created_at: string
}

interface AdDocument {
  kind: 'invoice' | 'act'
  number: number
  date: string
  subject: string
  invoice: AdInvoice
  platform: Record<string, string>
  advertiser: Record<string, string | null>
}

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)

/** Печатная форма счёта или акта в новом окне. */
async function printDocument(id: string, kind: 'invoice' | 'act') {
  const d = await api.get<AdDocument>(`/admin/ads/invoices/${id}/document`, { kind })
  const p = d.platform
  const a = d.advertiser
  const party = (title: string, x: Record<string, unknown>, pre = '') =>
    `<p><b>${title}:</b> ${esc(x[pre + 'name'])}, ИНН ${esc(x[pre + 'inn'])}, ${esc(x[pre + 'address'])}<br/>р/с ${esc(x[pre + 'account'])} в ${esc(x[pre + 'bank'])}, МФО ${esc(x[pre + 'mfo'])}</p>`
  const contract = a.contract_number ? `по договору № ${esc(a.contract_number)}${a.contract_date ? ` от ${date(a.contract_date)}` : ''}` : ''
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${kind === 'act' ? 'Акт' : 'Счёт'} № ${d.number}</title>
<style>body{font-family:Arial,sans-serif;font-size:13px;margin:32px;color:#111}h1{font-size:18px}table{border-collapse:collapse;width:100%;margin:16px 0}td,th{border:1px solid #333;padding:6px 8px;text-align:left}th{background:#f2f2f2}.r{text-align:right}.sign{display:flex;justify-content:space-between;margin-top:48px}</style></head><body>
<h1>${kind === 'act' ? 'Акт оказанных услуг' : 'Счёт на оплату'} № ${d.number} от ${date(d.date)}</h1>
${party('Исполнитель', p, 'company_')}${party('Заказчик', a)}
${contract ? `<p>Основание: ${contract}</p>` : ''}
<table><tr><th>№</th><th>Наименование</th><th class="r">Кол-во</th><th class="r">Сумма, сум</th></tr>
<tr><td>1</td><td>${esc(d.subject)} (кампания «${esc(d.invoice.campaign_title)}», бренд ${esc(d.invoice.brand_name)})</td><td class="r">1</td><td class="r">${money(d.invoice.amount)}</td></tr>
<tr><td colspan="3" class="r"><b>Итого</b></td><td class="r"><b>${money(d.invoice.amount)}</b></td></tr></table>
<p>Оплачиваемых показов за период: ${num(d.invoice.views)}. Реклама размещена с пометкой «Реклама».</p>
${kind === 'act' ? '<p>Услуги оказаны полностью и в срок. Заказчик претензий по объёму, качеству и срокам не имеет.</p>' : ''}
<div class="sign"><div>Исполнитель ____________ ${esc(p.company_director)}</div><div>Заказчик ____________</div></div>
<script>window.onload=()=>window.print()</script></body></html>`
  const w = window.open('', '_blank')
  if (w) {
    w.document.write(html)
    w.document.close()
  }
}

function Invoices() {
  const { message } = App.useApp()
  const list = useList<AdInvoice>('/admin/ads/invoices', { limit: 200 })
  const act = useAction((v: { id: string; to: 'paid' | 'cancel' }) => api.post(`/admin/ads/invoices/${v.id}/${v.to}`), { success: 'Готово' })
  const print = (id: string, kind: 'invoice' | 'act') => printDocument(id, kind).catch((e) => message.error(errorText(e)))
  return (
    <Card styles={{ body: { padding: 0 } }}>
      <LoadError error={list.error} retry={list.refetch} />
      <Table<AdInvoice>
        rowKey="id"
        loading={list.isLoading}
        dataSource={list.data ?? []}
        pagination={false}
        locale={{ emptyText: 'Счетов пока нет — выставьте из карточки кампании' }}
        columns={[
          { title: '№', dataIndex: 'number' },
          { title: 'Заказчик', render: (_, i) => <>{i.advertiser_name}<br /><Typography.Text type="secondary" style={{ fontSize: 12 }}>{i.brand_name} · {i.campaign_title}</Typography.Text></> },
          { title: 'Период', render: (_, i) => `${date(i.period_from)} – ${date(i.period_to)}` },
          { title: 'Показы', dataIndex: 'views', align: 'right', render: num },
          { title: 'Сумма', dataIndex: 'amount', align: 'right', render: (v: string) => `${money(v)} сум` },
          { title: 'Статус', dataIndex: 'status', render: (v: AdInvoice['status']) => <Tag color={v === 'paid' ? 'green' : v === 'unpaid' ? 'gold' : 'default'}>{v === 'paid' ? 'Оплачен' : v === 'unpaid' ? 'Ждёт оплаты' : 'Отменён'}</Tag> },
          {
            title: '',
            render: (_, i) => (
              <Space wrap>
                <Button size="small" onClick={() => print(i.id, 'invoice')}>Счёт</Button>
                {i.act_number && <Button size="small" onClick={() => print(i.id, 'act')}>Акт</Button>}
                {i.status === 'unpaid' && (
                  <>
                    <Button size="small" type="primary" onClick={() => act.mutate({ id: i.id, to: 'paid' })}>Оплачен</Button>
                    <Button size="small" danger onClick={() => act.mutate({ id: i.id, to: 'cancel' })}>Отменить</Button>
                  </>
                )}
              </Space>
            ),
          },
        ]}
      />
    </Card>
  )
}

function Advertisers() {
  return (
    <CrudPage<{ id: string; name: string; inn: string; contract_number: string; contract_date: string | null; contact: string }>
      title="Рекламодатели"
      path="/admin/ads/advertisers"
      createLabel="Новый рекламодатель"
      columns={[
        { title: 'Юрлицо', dataIndex: 'name' },
        { title: 'ИНН', dataIndex: 'inn' },
        { title: 'Договор', render: (_, a) => (a.contract_number ? `№ ${a.contract_number}${a.contract_date ? ` от ${date(a.contract_date)}` : ''}` : '—') },
        { title: 'Контакт', dataIndex: 'contact' },
      ]}
      form={() => <AdvertiserForm />}
      toForm={(a) => ({ ...a, contract_date: a.contract_date ?? '' })}
    />
  )
}

export function Ads() {
  const [rules, setRules] = useState(false)
  const [tab, setTab] = useState('campaigns')
  return (
    <>
      <PageTitle
        title="Реклама брендов"
        extra={<Button icon={<SettingOutlined />} onClick={() => setRules(true)}>Правила</Button>}
      >
        <Typography.Text type="secondary">Платные полки и баннеры брендов на главной. Всегда с пометкой «Реклама», не больше 2 на главной.</Typography.Text>
      </PageTitle>
      <Tabs
        activeKey={tab}
        onChange={setTab}
        items={[
          { key: 'campaigns', label: 'Кампании', children: <Campaigns /> },
          { key: 'invoices', label: 'Счета и акты', children: <Invoices /> },
          { key: 'advertisers', label: 'Рекламодатели', children: <Advertisers /> },
        ]}
      />
      <RulesModal open={rules} onClose={() => setRules(false)} />
    </>
  )
}

