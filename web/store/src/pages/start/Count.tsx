// «Посчитать остатки» (Figma «начало работы v5», Н-W5): товары «Остаток не
// посчитан» после «Только товары и цены» или «Остальное посчитаю потом».
// Досчитывать по чуть-чуть: сначала товары в минусе, «Сегодня — 15 самых
// продаваемых», одна полка (категория) или все. Подсчёт — инвентаризация
// основного склада (POST /store/start/count), пометка снимается.
import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert, App, Button, Card, Flex, Input, InputNumber, Progress, Result, Segmented, Select, Space, Table, Tag, Typography } from 'antd'
import { CheckCircleOutlined, SaveOutlined, SearchOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, plural, qty as fmtQty, tr, useDebounced } from '@sm/shared'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { Thumb } from './Thumb'
import type { CountCategory, CountItem, CountResult, CountSet, CountSummary } from './api'

const goods = (n: number) => tr(`${n} ${plural(n, 'товар', 'товара', 'товаров')}`, `${n} ta mahsulot`)

type Tab = 'negative' | 'top' | 'shelf' | 'uncounted'

export function StockCountPage() {
  return (
    <NeedStore>
      <StockCount />
    </NeedStore>
  )
}

/** Сводка «Посчитано N из M» — общая для главной и этой страницы. */
export function useCountSummary(storeId: string, enabled = true) {
  return useQuery({
    queryKey: ['/store/start/count', storeId],
    queryFn: () => api.get<CountSummary>('/store/start/count', { store_id: storeId }),
    enabled: enabled && !!storeId,
  })
}

function StockCount() {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const nav = useNavigate()
  const qc = useQueryClient()
  const [params, setParams] = useSearchParams()
  const summary = useCountSummary(storeId)
  const s = summary.data
  const initial = (params.get('set') as Tab | null) ?? null
  const [tab, setTab] = useState<Tab>(initial ?? 'top')
  // Сначала — то, что ушло в минус.
  useEffect(() => {
    if (!initial && s && s.negative > 0) setTab('negative')
  }, [initial, s])
  const [category, setCategory] = useState<string | undefined>(params.get('category_id') ?? undefined)
  const [text, setText] = useState('')
  const q = useDebounced(text.trim(), 250)
  // Введённые количества: product_id → «сколько сейчас на полке».
  const [counts, setCounts] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)

  const cats = useQuery({
    queryKey: ['/store/start/count/categories', storeId],
    queryFn: () => api.get<{ items: CountCategory[] }>('/store/start/count/categories', { store_id: storeId }).then((r) => r.items),
    enabled: !!storeId,
  })
  const set: CountSet = tab === 'negative' ? 'negative' : tab === 'top' ? 'top' : 'uncounted'
  const listParams = {
    store_id: storeId,
    set,
    category_id: tab === 'shelf' ? category : undefined,
    q: tab === 'uncounted' || tab === 'shelf' ? q || undefined : undefined,
    limit: tab === 'top' ? 15 : 100,
  }
  const list = useQuery({
    queryKey: ['/store/start/count/items', listParams],
    queryFn: () => api.get<{ items: CountItem[]; total: number }>('/store/start/count/items', listParams),
    enabled: !!storeId && (tab !== 'shelf' || !!category),
    placeholderData: keepPreviousData,
  })
  const items = useMemo(() => list.data?.items ?? [], [list.data])
  const entered = Object.entries(counts).filter(([, v]) => v !== '' && v !== null)

  const save = async () => {
    if (entered.length === 0) return
    setBusy(true)
    try {
      const r = await api.post<CountResult>('/store/start/count', { store_id: storeId, items: entered.map(([product_id, qty]) => ({ product_id, qty })) })
      message.success(tr(`Посчитано: ${goods(r.counted)} · инвентаризация №${r.document.number}`, `Sanaldi: ${goods(r.counted)} · №${r.document.number} inventarizatsiya`))
      setCounts({})
      await Promise.all(['/store/start/count', '/store/start/count/items', '/store/start/count/categories'].map((k) => qc.invalidateQueries({ queryKey: [k] })))
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  if (summary.error) return <LoadError error={summary.error} retry={() => summary.refetch()} />
  if (s && s.uncounted === 0 && s.negative === 0)
    return (
      <Card>
        <Result
          status="success"
          title={tr('Все остатки посчитаны', 'Barcha qoldiqlar sanalgan')}
          subTitle={tr('Склад, прибыль и подсказки агентам — по точным остаткам.', 'Ombor, foyda va agentlarga maslahatlar — aniq qoldiqlar boʻyicha.')}
          extra={
            <Button type="primary" onClick={() => nav('/')}>
              {tr('На главную', 'Bosh sahifaga')}
            </Button>
          }
        />
      </Card>
    )

  return (
    <>
      <PageTitle
        title={tr('Посчитать остатки', 'Qoldiqlarni sanash')}
        extra={
          <Button type="primary" icon={<SaveOutlined />} loading={busy} disabled={entered.length === 0} onClick={save}>
            {entered.length > 0 ? tr(`Записать подсчёт · ${goods(entered.length)}`, `Sanashni yozish · ${goods(entered.length)}`) : tr('Записать подсчёт', 'Sanashni yozish')}
          </Button>
        }
      />
      {s && (
        <Card style={{ marginBottom: 16 }} styles={{ body: { padding: '14px 20px' } }}>
          <Flex align="center" gap={24} wrap>
            <div style={{ flex: 1, minWidth: 260 }}>
              <Typography.Text strong style={{ fontSize: 16 }}>
                {tr(`Посчитано ${s.counted} из ${s.products}`, `${s.products} tadan ${s.counted} tasi sanalgan`)}
              </Typography.Text>
              <div>
                <Typography.Text type="secondary" style={{ fontSize: 13 }}>
                  {tr(
                    'Введите, сколько сейчас на полке, — остаток станет точным. Не обязательно всё сразу: можно по 10–20 товаров в день.',
                    'Javonda hozir qanchaligini kiriting — qoldiq aniq boʻladi. Hammasini birdaniga shart emas: kuniga 10–20 tadan mumkin.',
                  )}
                </Typography.Text>
              </div>
            </div>
            <Progress percent={s.percent} strokeColor="#F79009" style={{ width: 240, margin: 0 }} />
          </Flex>
        </Card>
      )}
      {s && s.negative > 0 && tab !== 'negative' && (
        <Alert
          type="error"
          showIcon
          style={{ marginBottom: 16 }}
          message={tr(`${goods(s.negative)} ушли в минус: продали больше, чем было посчитано. Посчитайте их первыми.`, `${goods(s.negative)} minusga ketdi: sanalganidan koʻp sotildi. Ularni birinchi sanang.`)}
          action={
            <Button size="small" danger onClick={() => setTab('negative')}>
              {tr('Показать', 'Koʻrsatish')}
            </Button>
          }
        />
      )}
      <Card
        title={
          <Segmented<Tab>
            value={tab}
            onChange={(v) => {
              setTab(v)
              setParams(v === 'shelf' && category ? { set: v, category_id: category } : { set: v })
            }}
            options={[
              ...(s && s.negative > 0 ? [{ value: 'negative' as Tab, label: `${tr('В минусе', 'Minusda')} · ${s.negative}` }] : []),
              { value: 'top', label: tr('Сегодня — 15 самых продаваемых', 'Bugun — eng koʻp sotiladigan 15 ta') },
              { value: 'shelf', label: tr('По одной полке', 'Bitta javon boʻyicha') },
              { value: 'uncounted', label: `${tr('Все непосчитанные', 'Barcha sanalmaganlar')}${s ? ` · ${s.uncounted}` : ''}` },
            ]}
          />
        }
        extra={
          <Space wrap>
            {tab === 'shelf' && (
              <Select
                showSearch
                allowClear
                style={{ width: 280 }}
                placeholder={tr('Выберите полку (категорию)', 'Javonni (kategoriyani) tanlang')}
                value={category}
                onChange={(v) => {
                  setCategory(v)
                  setParams(v ? { set: 'shelf', category_id: v } : { set: 'shelf' })
                }}
                optionFilterProp="label"
                options={(cats.data ?? []).map((c) => ({
                  value: c.id,
                  label: `${c.section ? c.section + ' › ' : ''}${c.name} · ${c.uncounted}`,
                }))}
              />
            )}
            {(tab === 'uncounted' || tab === 'shelf') && (
              <Input allowClear prefix={<SearchOutlined />} style={{ width: 240 }} placeholder={tr('Название или штрихкод', 'Nomi yoki shtrix-kod')} value={text} onChange={(e) => setText(e.target.value)} />
            )}
          </Space>
        }
        styles={{ body: { padding: 0 } }}
      >
        <LoadError error={list.error} retry={() => list.refetch()} />
        {tab === 'shelf' && !category ? (
          <Typography.Paragraph type="secondary" style={{ padding: 24, margin: 0, textAlign: 'center' }}>
            {tr('Выберите полку — например «Напитки» — и посчитайте только её.', 'Javonni tanlang — masalan, «Ichimliklar» — va faqat uni sanang.')}
          </Typography.Paragraph>
        ) : (
          <Table<CountItem>
            rowKey="product_id"
            size="middle"
            loading={list.isFetching && items.length === 0}
            dataSource={items}
            pagination={false}
            scroll={{ x: 900 }}
            locale={{ emptyText: tr('Здесь всё посчитано', 'Bu yerda hammasi sanalgan') }}
            columns={[
              {
                title: tr('Товар', 'Mahsulot'),
                key: 'name',
                render: (_, it) => (
                  <Flex align="center" gap={10}>
                    <Thumb src={it.image} />
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontWeight: 600 }}>{it.name}</div>
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                        {[it.barcode, it.category].filter(Boolean).join(' · ')}
                      </Typography.Text>
                    </div>
                  </Flex>
                ),
              },
              {
                title: tr('По учёту', 'Hisob boʻyicha'),
                key: 'stock',
                width: 150,
                render: (_, it) =>
                  it.uncounted ? (
                    <Tag bordered={false}>{tr('не посчитан', 'sanalmagan')}</Tag>
                  ) : (
                    <span>
                      {fmtQty(it.stock, it.unit_short)}
                      {Number(it.short) > 0 && (
                        <Typography.Text type="danger" style={{ display: 'block', fontSize: 12 }}>
                          {tr(`в минусе на ${fmtQty(it.short, it.unit_short)}`, `${fmtQty(it.short, it.unit_short)} minusda`)}
                        </Typography.Text>
                      )}
                    </span>
                  ),
              },
              {
                title: tr('Продано за 30 дней', '30 kunda sotildi'),
                key: 'sold',
                width: 150,
                render: (_, it) => (Number(it.sold_30d) > 0 ? fmtQty(it.sold_30d, it.unit_short) : <Typography.Text type="secondary">—</Typography.Text>),
              },
              {
                title: tr('Сейчас на полке', 'Hozir javonda'),
                key: 'count',
                width: 190,
                render: (_, it) => (
                  <InputNumber<string>
                    stringMode
                    min="0"
                    step={it.is_fractional ? '0.001' : '1'}
                    style={{ width: '100%' }}
                    addonAfter={it.unit_short}
                    placeholder={tr('сколько есть', 'qancha bor')}
                    value={counts[it.product_id] ?? undefined}
                    onChange={(v) => setCounts((c) => ({ ...c, [it.product_id]: v ?? '' }))}
                    onPressEnter={(e) => (e.target as HTMLInputElement).blur()}
                  />
                ),
              },
            ]}
          />
        )}
        {entered.length > 0 && (
          <Flex justify="flex-end" style={{ padding: '12px 16px', borderTop: '1px solid #EAECF0' }}>
            <Button type="primary" icon={<CheckCircleOutlined />} loading={busy} onClick={save}>
              {tr(`Записать подсчёт · ${goods(entered.length)}`, `Sanashni yozish · ${goods(entered.length)}`)}
            </Button>
          </Flex>
        )}
      </Card>
    </>
  )
}
