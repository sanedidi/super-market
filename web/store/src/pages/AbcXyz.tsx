// ABC/XYZ-анализ: какие товары приносят деньги (ABC) и насколько ровно
// они продаются (XYZ). Матрица 3×3 подсказывает, что делать с товаром.
import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import { Alert, Button, Card, Checkbox, Col, Empty, Input, Modal, Row, Segmented, Space, Table, Tooltip, TreeSelect, Typography } from 'antd'
import type { ColumnsType } from 'antd/es/table'
import {
  CloseOutlined,
  DeleteOutlined,
  DownloadOutlined,
  InboxOutlined,
  LineChartOutlined,
  QuestionCircleOutlined,
  SearchOutlined,
  ShoppingOutlined,
  StopOutlined,
  WalletOutlined,
} from '@ant-design/icons'
import dayjs from 'dayjs'
import { PageTitle, date, errorText, money, qty, useItem, useList } from '@sm/shared'
import { useReportFilters } from './Reports'
import type { Range } from '../ui'
import type { AbcBy, AbcItem, AbcLetter, AbcNoSaleItem, AbcXyz, DictItem } from '../types'

const last12Weeks = (): Range => [dayjs().subtract(83, 'day').startOf('day'), dayjs().startOf('day')]

const GROUP: Record<AbcLetter, { color: string; bg: string; text: string; hint: string; name: string }> = {
  A: { color: '#17b26a', bg: '#ecfdf3', text: '#067647', name: 'Главные товары', hint: 'Главные товары — не допускать отсутствия' },
  B: { color: '#f79009', bg: '#fffaeb', text: '#b54708', name: 'Середина', hint: 'Середина — следить за остатком' },
  C: { color: '#98a2b3', bg: '#f2f4f7', text: '#475467', name: 'Мало денег', hint: 'Мало денег — держать минимум' },
}

const TONE = {
  green: { bg: '#ecfdf3', fg: '#067647' },
  amber: { bg: '#fffaeb', fg: '#b54708' },
  rose: { bg: '#fef3f2', fg: '#b42318' },
}
const CELL: Record<string, { tone: keyof typeof TONE; action: string }> = {
  AX: { tone: 'green', action: 'Автозаказ, всегда в наличии' },
  AY: { tone: 'green', action: 'Запас с учётом сезона и акций' },
  AZ: { tone: 'amber', action: 'Заказывать вручную, следить' },
  BX: { tone: 'green', action: 'Автозаказ' },
  BY: { tone: 'amber', action: 'Средний запас' },
  BZ: { tone: 'rose', action: 'Небольшой запас' },
  CX: { tone: 'amber', action: 'Минимальный запас' },
  CY: { tone: 'rose', action: 'Под заказ' },
  CZ: { tone: 'rose', action: 'Кандидаты на вывод' },
}
const ROWS: Record<AbcLetter, string> = { A: 'много денег', B: 'середина', C: 'мало денег' }
const COLS = [
  { k: 'X', d: 'стабильный спрос · вариация до 10%' },
  { k: 'Y', d: 'колеблется · 10–25%' },
  { k: 'Z', d: 'случайный · больше 25%' },
]
const BY_WORD: Record<AbcBy, string> = { revenue: 'выручки', profit: 'прибыли', qty: 'продаж' }

const RED = '#e11d2a'
const MUTED = '#667085'

const pct = (n: number) => n.toLocaleString('ru-RU', { maximumFractionDigits: 1 }) + '%'
const plural = (n: number, one: string, few: string, many: string) => {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return `${n} ${one}`
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return `${n} ${few}`
  return `${n} ${many}`
}
const products = (n: number) => plural(n, 'товар', 'товара', 'товаров')
const days = (n: number) => plural(n, 'день', 'дня', 'дней')

// Окно справки само открывается, пока не отмечено «Не открывать автоматически».
const HELP_KEY = 'sm.abcXyz.helpHidden'
function helpHidden(): boolean {
  try {
    return localStorage.getItem(HELP_KEY) === '1'
  } catch {
    return false
  }
}
function setHelpHidden(v: boolean) {
  try {
    if (v) localStorage.setItem(HELP_KEY, '1')
    else localStorage.removeItem(HELP_KEY)
  } catch {
    /* хранилище недоступно — просто откроем окно в следующий раз */
  }
}

type View = 'all' | AbcLetter | 'nosale'

export function AbcXyzPage() {
  const { params, filters } = useReportFilters(last12Weeks)
  const [by, setBy] = useState<AbcBy>('revenue')
  const [category, setCategory] = useState<string | undefined>()
  const cats = useList<DictItem>('/store/catalog/categories')
  const { data, isLoading, error } = useItem<AbcXyz>('/store/reports/abc-xyz', { ...params, by, category_id: category })
  const [view, setView] = useState<View>('all')
  const [cell, setCell] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [help, setHelp] = useState(false)
  useEffect(() => {
    if (!helpHidden()) setHelp(true)
  }, [])

  const tree = useMemo(() => categoryTree(cats.data ?? []), [cats.data])
  const items = useMemo(() => {
    const q = search.trim().toLowerCase()
    return (data?.items ?? []).filter(
      (i) =>
        (view === 'all' || view === 'nosale' || i.abc === view) &&
        (!cell || i.abc + (i.xyz ?? '') === cell) &&
        (!q || i.name.toLowerCase().includes(q) || i.category.toLowerCase().includes(q)),
    )
  }, [data, view, cell, search])
  const noSale = useMemo(() => {
    const q = search.trim().toLowerCase()
    return (data?.no_sale_items ?? []).filter((i) => !q || i.name.toLowerCase().includes(q) || i.category.toLowerCase().includes(q))
  }, [data, search])

  const pick = (v: View) => {
    setView(v)
    setCell(null)
  }
  const pickCell = (c: string) => {
    setView('all')
    setCell(cell === c ? null : c)
  }

  return (
    <>
      <PageTitle
        title={
          <Space size={12} wrap>
            ABC/XYZ-анализ
            <Button size="small" shape="round" icon={<QuestionCircleOutlined />} onClick={() => setHelp(true)} style={{ color: RED, background: '#fff1f2', borderColor: '#fff1f2', fontWeight: 700 }}>
              Что это и как пользоваться?
            </Button>
          </Space>
        }
      >
        {filters}
        <TreeSelect
          allowClear
          showSearch
          treeNodeFilterProp="title"
          placeholder="Все категории"
          value={category}
          onChange={(v) => setCategory(v || undefined)}
          treeData={tree}
          style={{ minWidth: 200 }}
          popupMatchSelectWidth={false}
        />
        <Space size={6}>
          <Typography.Text type="secondary">ABC по:</Typography.Text>
          <Segmented<AbcBy>
            value={by}
            onChange={setBy}
            options={[
              { value: 'revenue', label: 'Выручке' },
              { value: 'profit', label: 'Прибыли' },
              { value: 'qty', label: 'Количеству' },
            ]}
          />
        </Space>
        <Button icon={<DownloadOutlined />} disabled={!data} onClick={() => data && downloadCsv(data)}>
          Excel
        </Button>
      </PageTitle>
      <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
        Какие товары приносят деньги (ABC) и насколько стабильно они продаются (XYZ). Подсказывает, что держать всегда, что заказывать
        осторожно и что убрать.
      </Typography.Paragraph>

      {error && <Alert type="error" showIcon message={errorText(error)} style={{ marginBottom: 16 }} />}
      {data && !data.xyz_available && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message={
            data.weeks === 0 && data.totals.products === 0
              ? 'За этот период продаж нет'
              : `Продажи есть только за ${plural(data.weeks, 'неделю', 'недели', 'недель')} — XYZ появится через ${days(data.xyz_days_left)}`
          }
          description={
            data.weeks === 0 && data.totals.products === 0
              ? 'Выберите другой период или магазин. Анализ появится, когда на кассе или в приложении пройдут продажи.'
              : `ABC уже считается. Для XYZ нужно минимум ${data.min_weeks} полные недели продаж, чтобы увидеть, насколько спрос скачет. Пока в колонке «Вариация» — «—», а матрица 3×3 скрыта.`
          }
        />
      )}

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        {(['A', 'B', 'C'] as const).map((k) => {
          const g = data?.groups[k]
          const total = data?.totals.products || 0
          return (
            <Col key={k} xs={24} sm={12} xl={6}>
              <Card loading={isLoading} hoverable onClick={() => pick(view === k ? 'all' : k)} style={cardStyle(view === k, GROUP[k].color)} styles={{ body: { padding: '14px 18px' } }}>
                <Space size={10}>
                  <Letter v={k} />
                  <Typography.Text type="secondary" strong>
                    Группа {k} · {products(g?.count ?? 0)} · {pct(total ? ((g?.count ?? 0) / total) * 100 : 0)}
                  </Typography.Text>
                </Space>
                <div style={{ margin: '6px 0 0' }}>
                  <span style={{ fontSize: 24, fontWeight: 800 }}>{pct(g?.share ?? 0)}</span> <Typography.Text type="secondary">{BY_WORD[by]}</Typography.Text>
                </div>
                <div style={{ fontWeight: 600, marginBottom: 2 }}>
                  {by === 'profit' ? `${money(g?.profit ?? 0)} сум прибыли` : `${money(g?.revenue ?? 0)} сум`}
                </div>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {GROUP[k].hint}
                </Typography.Text>
              </Card>
            </Col>
          )
        })}
        <Col xs={24} sm={12} xl={6}>
          <Card
            loading={isLoading}
            hoverable
            onClick={() => pick(view === 'nosale' ? 'all' : 'nosale')}
            style={{ ...cardStyle(view === 'nosale', RED), background: '#fff1f2' }}
            styles={{ body: { padding: '14px 18px' } }}
          >
            <Space size={10}>
              <span style={{ ...badgeBox, background: '#fff', color: RED }}>
                <StopOutlined />
              </span>
              <Typography.Text type="secondary" strong>
                Без продаж за период
              </Typography.Text>
            </Space>
            <div style={{ margin: '6px 0 2px', fontSize: 24, fontWeight: 800, color: RED }}>{products(data?.no_sales.count ?? 0)}</div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              На складе на {money(data?.no_sales.stock_value ?? 0)} сум по закупке
            </Typography.Text>
          </Card>
        </Col>
      </Row>

      {data?.xyz_available && (
        <Card style={{ marginBottom: 16 }} styles={{ body: { padding: '18px 20px 20px' } }}>
          <Space size={10} align="baseline" wrap style={{ marginBottom: 14 }}>
            <Typography.Text strong style={{ fontSize: 16 }}>
              Матрица ABC × XYZ
            </Typography.Text>
            <Typography.Text type="secondary">Нажмите на клетку — в таблице останутся её товары</Typography.Text>
          </Space>
          <div style={{ overflowX: 'auto' }}>
            <div style={{ display: 'grid', gridTemplateColumns: '110px repeat(3, minmax(170px, 1fr))', gap: 8, minWidth: 640 }}>
              <div />
              {COLS.map((c) => (
                <div key={c.k} style={{ paddingLeft: 4 }}>
                  <b style={{ fontSize: 15 }}>{c.k}</b> <Typography.Text type="secondary" style={{ fontSize: 12 }}>{c.d}</Typography.Text>
                </div>
              ))}
              {(['A', 'B', 'C'] as const).map((r) => (
                <MatrixRow key={r} r={r} data={data} by={by} cell={cell} onPick={pickCell} />
              ))}
            </div>
          </div>
        </Card>
      )}

      <Card styles={{ body: { padding: '18px 20px' } }}>
        <Space wrap size={8} style={{ marginBottom: 12, width: '100%' }}>
          <Typography.Text strong style={{ fontSize: 16, marginRight: 4 }}>
            Товары
          </Typography.Text>
          {cell && (
            <Button size="small" shape="round" type="primary" onClick={() => setCell(null)}>
              {cell} · {items.length} <CloseOutlined />
            </Button>
          )}
          <Chip active={!cell && view === 'all'} onClick={() => pick('all')}>
            Все {data?.totals.products ?? 0}
          </Chip>
          {(['A', 'B', 'C'] as const).map((k) => (
            <Chip key={k} active={!cell && view === k} onClick={() => pick(k)}>
              {k} {data?.groups[k].count ?? 0}
            </Chip>
          ))}
          <Chip active={view === 'nosale'} onClick={() => pick('nosale')} danger>
            Без продаж {data?.no_sales.count ?? 0}
          </Chip>
        </Space>
        <Input
          allowClear
          prefix={<SearchOutlined />}
          placeholder="Поиск товара"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ maxWidth: 280, marginBottom: 12 }}
        />
        {view === 'nosale' ? (
          <NoSaleTable rows={noSale} loading={isLoading} />
        ) : (
          <ItemsTable rows={items} loading={isLoading} xyz={!!data?.xyz_available} />
        )}
        {data && (
          <Typography.Paragraph type="secondary" style={{ fontSize: 12, margin: '8px 0 0' }}>
            Анализ с {date(data.analysis_from)} · полных недель: {data.weeks} · «Остаток · на N дн.» — на сколько дней хватит при среднем
            спросе за период. Продажи POS и доставленные онлайн-заказы минус возвраты.
          </Typography.Paragraph>
        )}
      </Card>

      <AbcHelpModal open={help} onClose={() => setHelp(false)} />
    </>
  )
}

function MatrixRow({ r, data, by, cell, onPick }: { r: AbcLetter; data: AbcXyz; by: AbcBy; cell: string | null; onPick: (c: string) => void }) {
  return (
    <>
      <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center', paddingLeft: 4 }}>
        <b style={{ fontSize: 18 }}>{r}</b>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {ROWS[r]}
        </Typography.Text>
      </div>
      {['X', 'Y', 'Z'].map((x) => {
        const k = r + x
        const c = data.matrix.find((m) => m.cell === k)
        const t = TONE[CELL[k].tone]
        const active = cell === k
        return (
          <button
            key={k}
            type="button"
            onClick={() => onPick(k)}
            style={{
              textAlign: 'left',
              cursor: 'pointer',
              background: t.bg,
              border: `2px solid ${active ? t.fg : 'transparent'}`,
              borderRadius: 12,
              padding: '10px 14px',
              font: 'inherit',
              opacity: c?.count ? 1 : 0.6,
            }}
          >
            <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', flexWrap: 'wrap' }}>
              <b style={{ fontSize: 18, color: t.fg }}>{k}</b>
              <b>{products(c?.count ?? 0)}</b>
              <span style={{ color: MUTED, fontSize: 13 }}>
                · {pct(c?.share ?? 0)} {BY_WORD[by]}
              </span>
            </div>
            <div style={{ color: t.fg, fontWeight: 600, fontSize: 13 }}>{CELL[k].action}</div>
          </button>
        )
      })}
    </>
  )
}

function ItemsTable({ rows, loading, xyz }: { rows: AbcItem[]; loading: boolean; xyz: boolean }) {
  const num = (k: keyof AbcItem) => (a: AbcItem, b: AbcItem) => Number(a[k] ?? -1) - Number(b[k] ?? -1)
  const columns: ColumnsType<AbcItem> = [
    { title: 'Товар', key: 'name', render: (_, r) => <ProductCell name={r.name} category={r.category} image={r.image} />, sorter: (a, b) => a.name.localeCompare(b.name) },
    { title: 'Группа', key: 'group', width: 80, render: (_, r) => <GroupTag abc={r.abc} xyz={r.xyz} /> },
    { title: 'Выручка', dataIndex: 'revenue', align: 'right', render: (v) => <b>{money(v)}</b>, sorter: num('revenue') },
    { title: 'Доля', dataIndex: 'share', align: 'right', render: pct, sorter: num('share') },
    { title: 'Накопл.', dataIndex: 'cum_share', align: 'right', render: (v) => <Typography.Text type="secondary">{pct(v)}</Typography.Text> },
    { title: 'Прибыль', dataIndex: 'profit', align: 'right', render: (v) => money(v), sorter: num('profit') },
    { title: 'Продано', dataIndex: 'qty', align: 'right', render: (v, r) => qty(v, r.unit), sorter: num('qty') },
    {
      title: (
        <Tooltip title="Насколько скачут продажи по неделям: до 10% — X, 10–25% — Y, больше — Z">
          Вариация
        </Tooltip>
      ),
      dataIndex: 'variation',
      align: 'right',
      render: (v: number | null) => (v === null ? <Typography.Text type="secondary">—</Typography.Text> : pct(Math.round(v))),
      sorter: num('variation'),
      hidden: !xyz,
    },
    { title: 'Остаток', key: 'stock', align: 'right', render: (_, r) => <StockCell r={r} />, sorter: num('days_cover') },
  ]
  return (
    <Table<AbcItem>
      rowKey="product_id"
      size="middle"
      loading={loading}
      dataSource={rows}
      columns={columns}
      scroll={{ x: 900 }}
      pagination={{ pageSize: 50, hideOnSinglePage: true, showSizeChanger: false }}
      onRow={(r) => (Number(r.stock) <= 0 ? { style: { background: '#fff1f2' } } : {})}
      locale={{ emptyText: <Empty description="Нет товаров" /> }}
    />
  )
}

function NoSaleTable({ rows, loading }: { rows: AbcNoSaleItem[]; loading: boolean }) {
  return (
    <>
      <Alert
        type="warning"
        showIcon
        style={{ marginBottom: 12 }}
        message="Эти товары лежат на складе и за период не продались ни разу"
        description="Это деньги на полке: их можно продать по акции, вернуть поставщику или больше не закупать."
      />
      <Table<AbcNoSaleItem>
        rowKey="product_id"
        size="middle"
        loading={loading}
        dataSource={rows}
        scroll={{ x: 600 }}
        pagination={{ pageSize: 50, hideOnSinglePage: true, showSizeChanger: false }}
        locale={{ emptyText: <Empty description="Всё на складе продавалось" /> }}
        columns={[
          { title: 'Товар', key: 'name', render: (_, r) => <ProductCell name={r.name} category={r.category} image={r.image} /> },
          { title: 'Остаток', dataIndex: 'stock', align: 'right', render: (v, r) => qty(v, r.unit) },
          {
            title: 'По закупке, сум',
            dataIndex: 'stock_value',
            align: 'right',
            render: (v) => <b>{money(v)}</b>,
            sorter: (a, b) => Number(a.stock_value) - Number(b.stock_value),
          },
        ]}
      />
    </>
  )
}

function ProductCell({ name, category, image }: { name: string; category: string; image: string | null }) {
  return (
    <Space size={10}>
      <span style={{ width: 32, height: 32, borderRadius: 8, background: '#f2f4f7', display: 'grid', placeItems: 'center', overflow: 'hidden', flex: 'none', color: '#98a2b3' }}>
        {image ? <img src={image} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : <ShoppingOutlined />}
      </span>
      <span>
        <b>{name}</b>
        {category && (
          <>
            <br />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {category}
            </Typography.Text>
          </>
        )}
      </span>
    </Space>
  )
}

function StockCell({ r }: { r: AbcItem }) {
  if (Number(r.stock) <= 0) return <b style={{ color: RED }}>нет в наличии</b>
  const low = r.days_cover !== null && r.days_cover < 7
  return (
    <span style={{ color: low ? RED : undefined, fontWeight: low ? 700 : undefined, whiteSpace: 'nowrap' }}>
      {qty(r.stock, r.unit)}
      {r.days_cover !== null && ` · ${r.days_cover > 999 ? '999+' : r.days_cover} дн.`}
    </span>
  )
}

function GroupTag({ abc, xyz }: { abc: AbcLetter; xyz: string | null }) {
  const k = abc + (xyz ?? '')
  const t = xyz ? TONE[CELL[k].tone] : { bg: GROUP[abc].bg, fg: GROUP[abc].text }
  return <span style={{ background: t.bg, color: t.fg, fontWeight: 800, fontSize: 12, padding: '2px 8px', borderRadius: 999 }}>{k}</span>
}

const badgeBox: CSSProperties = { width: 30, height: 30, borderRadius: 8, display: 'inline-grid', placeItems: 'center', fontWeight: 800, fontSize: 16 }

function Letter({ v }: { v: AbcLetter }) {
  return <span style={{ ...badgeBox, background: GROUP[v].bg, color: GROUP[v].text }}>{v}</span>
}

function cardStyle(active: boolean, color: string): CSSProperties {
  return { height: '100%', borderColor: active ? color : undefined, boxShadow: active ? `0 0 0 1px ${color}` : undefined }
}

function Chip({ active, danger, onClick, children }: { active: boolean; danger?: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <Button
      size="small"
      shape="round"
      onClick={onClick}
      style={{
        background: active ? '#0f172a' : '#f2f4f7',
        color: active ? '#fff' : danger ? RED : undefined,
        borderColor: 'transparent',
        fontWeight: active ? 700 : 600,
      }}
    >
      {children}
    </Button>
  )
}

type TreeNode = { value: string; title: string; children?: TreeNode[] }
function categoryTree(list: DictItem[]): TreeNode[] {
  const byParent = new Map<string, DictItem[]>()
  for (const c of list) {
    const p = c.parent_id ?? ''
    byParent.set(p, [...(byParent.get(p) ?? []), c])
  }
  const build = (p: string, depth: number): TreeNode[] =>
    (byParent.get(p) ?? []).map((c) => ({ value: c.id, title: c.name, children: depth < 6 ? build(c.id, depth + 1) : undefined }))
  return build('', 0)
}

// ------------------------------------------------------------ выгрузка

function downloadCsv(d: AbcXyz) {
  const n = (v: string | number | null) => (v === null ? '' : String(v).replace('.', ','))
  const head = ['Товар', 'Категория', 'ABC', 'XYZ', 'Выручка, сум', 'Прибыль, сум', 'Продано', 'Ед.', 'Доля, %', 'Накопл., %', 'Вариация, %', 'Остаток', 'Хватит на, дн.', 'Что делать']
  const rows = d.items.map((i) => [
    i.name,
    i.category,
    i.abc,
    i.xyz ?? '',
    n(i.revenue),
    n(i.profit),
    n(i.qty),
    i.unit,
    n(i.share),
    n(i.cum_share),
    n(i.variation),
    n(i.stock),
    n(i.days_cover),
    i.xyz ? CELL[i.abc + i.xyz].action : GROUP[i.abc].hint,
  ])
  const none = d.no_sale_items.map((i) => [i.name, i.category, '', '', '', '', '', i.unit, '', '', '', n(i.stock), '', `Без продаж, по закупке ${n(i.stock_value)} сум`])
  const esc = (v: unknown) => `"${String(v).replace(/"/g, '""')}"`
  const lines = [
    [`ABC/XYZ-анализ ${date(d.from)} — ${date(dayjs(d.to).subtract(1, 'second').toISOString())}, ABC по ${BY_WORD[d.by]}`],
    head,
    ...rows,
    ...(none.length ? [[], ['Без продаж за период'], ...none] : []),
  ].map((r) => r.map(esc).join(';'))
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `ABC-XYZ_${dayjs(d.from).format('YYYY-MM-DD')}.csv`
  a.click()
  URL.revokeObjectURL(a.href)
}

// ------------------------------------------------- «Что это и как пользоваться?»

export function AbcHelpModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [hide, setHide] = useState(true)
  const close = () => {
    setHelpHidden(hide)
    onClose()
  }
  return (
    <Modal open={open} onCancel={close} footer={null} width={960} centered styles={{ body: { padding: '4px 8px' } }}>
      <Space align="start" size={14} style={{ marginBottom: 18 }}>
        <span style={{ width: 44, height: 44, borderRadius: 12, background: '#fff1f2', color: RED, display: 'grid', placeItems: 'center', fontSize: 22 }}>
          <LineChartOutlined />
        </span>
        <div>
          <Typography.Title level={4} style={{ margin: 0 }}>
            ABC/XYZ-анализ — что это и зачем
          </Typography.Title>
          <Typography.Text type="secondary">
            Помогает понять, на каких товарах магазин зарабатывает, какие нужно держать всегда, а какие просто занимают полку и
            замораживают деньги.
          </Typography.Text>
        </div>
      </Space>

      <Row gutter={[12, 12]} style={{ marginBottom: 16 }}>
        {[
          { icon: <InboxOutlined />, t: 'Нужный товар не кончается', d: 'Видно, какие товары приносят больше всего денег — их нельзя упускать с полки.' },
          { icon: <WalletOutlined />, t: 'Деньги не стоят на полке', d: 'Видно, что продаётся редко — такого товара не нужно закупать много.' },
          { icon: <DeleteOutlined />, t: 'Понятно, что убрать', d: 'Товары, которые почти не продаются, можно заменить на те, что продаются.' },
        ].map((x) => (
          <Col key={x.t} xs={24} md={8}>
            <div style={{ ...box, background: '#f9fafb', height: '100%' }}>
              <div style={{ color: RED, fontSize: 20 }}>{x.icon}</div>
              <b style={{ fontSize: 15 }}>{x.t}</b>
              <div style={hint}>{x.d}</div>
            </div>
          </Col>
        ))}
      </Row>

      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} md={12}>
          <div style={{ ...box, height: '100%' }}>
            <b style={{ fontSize: 16 }}>ABC — сколько товар приносит денег</b>
            <div style={hint}>Super Market складывает выручку каждого товара за период и выстраивает товары от самого денежного к самому слабому.</div>
            <ShareBar label="Товары" parts={[15, 25, 60]} />
            <ShareBar label="Выручка" parts={[80, 15, 5]} />
            <div style={{ ...hint, fontSize: 12 }}>Обычно 15–20% товаров дают 80% всех денег магазина</div>
            <HelpItem letter="A" tone={GROUP.A} title="Главные товары" text="Вместе дают 80% выручки. Например: хлеб, молоко, вода, масло." />
            <HelpItem letter="B" tone={GROUP.B} title="Середина" text="Следующие 15% выручки. Продаются, но не решают всё." />
            <HelpItem letter="C" tone={GROUP.C} title="Мало денег" text="Последние 5% выручки, хотя таких товаров больше половины. Например: специи, редкие соусы." />
          </div>
        </Col>
        <Col xs={24} md={12}>
          <div style={{ ...box, height: '100%' }}>
            <b style={{ fontSize: 16 }}>XYZ — насколько ровно продаётся</b>
            <div style={hint}>Super Market смотрит продажи товара по неделям: каждую неделю примерно одинаково или то густо, то пусто.</div>
            <HelpItem letter="X" tone={GROUP.A} title="Стабильный спрос" text="Каждую неделю продаётся почти одинаково — легко понять, сколько заказать. Например: молоко, хлеб." weeks={[12, 13, 12, 13, 12, 12, 13, 12]} />
            <HelpItem letter="Y" tone={GROUP.B} title="Спрос колеблется" text="То больше, то меньше: зависит от сезона, погоды, акций. Например: мороженое, вода летом." weeks={[8, 12, 17, 10, 6, 14, 16, 9]} />
            <HelpItem letter="Z" tone={GROUP.C} title="Случайный спрос" text="Продаётся редко и непредсказуемо — то неделю ничего, то сразу много. Например: торт на заказ." weeks={[2, 15, 0, 5, 18, 1, 0, 11]} />
            <div style={{ ...hint, fontSize: 12, fontWeight: 600 }}>Для XYZ нужно минимум 4 недели продаж</div>
          </div>
        </Col>
      </Row>

      <Row gutter={[16, 16]} style={{ marginBottom: 20 }}>
        <Col xs={24} md={12}>
          <div style={{ ...box, height: '100%' }}>
            <b style={{ fontSize: 16 }}>Две буквы вместе — что делать с товаром</b>
            <div style={hint}>Каждый товар получает две буквы, например AX. В матрице 9 клеток, цвет клетки подсказывает действие.</div>
            {[
              { tone: TONE.green, cells: 'AX · AY · BX', t: 'Держите всегда', d: 'Приносят много и продаются ровно. Заказывайте регулярно, не допускайте, чтобы закончились.' },
              { tone: TONE.amber, cells: 'AZ · BY · CX', t: 'Следите', d: 'Заказывайте небольшими партиями и чаще. AZ — дорогие для магазина, но спрос скачет.' },
              { tone: TONE.rose, cells: 'BZ · CY · CZ', t: 'Не держите большой запас', d: 'Продаются мало и случайно. CZ — подумайте, не убрать ли с полки и поставить то, что продаётся.' },
            ].map((x) => (
              <div key={x.cells} style={{ background: x.tone.bg, borderRadius: 10, padding: '10px 14px' }}>
                <b style={{ color: x.tone.fg }}>{x.cells}</b> <b>— {x.t}</b>
                <div style={{ ...hint, fontSize: 12 }}>{x.d}</div>
              </div>
            ))}
          </div>
        </Col>
        <Col xs={24} md={12}>
          <div style={{ ...box, height: '100%' }}>
            <b style={{ fontSize: 16 }}>Как пользоваться — 4 шага</b>
            {[
              ['Выберите период', 'Лучше 8–12 недель: так видно и праздники, и обычные недели. Смотрите раз в месяц, перед закупкой.'],
              ['Нажмите на клетку матрицы', 'В таблице останутся только её товары. Начните с AX — это самое важное.'],
              ['Проверьте «Остаток · на N дн.»', 'Красным — то, что закончится меньше чем за неделю. Это нужно заказать в первую очередь.'],
              ['Загляните в «Без продаж»', 'Товары, которые лежат и ни разу не продались. Это деньги на полке — их можно продать по акции или вернуть поставщику.'],
            ].map(([t, d], i) => (
              <div key={t} style={{ display: 'flex', gap: 12 }}>
                <span style={{ flex: 'none', width: 26, height: 26, borderRadius: 999, background: RED, color: '#fff', display: 'grid', placeItems: 'center', fontWeight: 800, fontSize: 13 }}>
                  {i + 1}
                </span>
                <div>
                  <b>{t}</b>
                  <div style={{ ...hint, fontSize: 12 }}>{d}</div>
                </div>
              </div>
            ))}
          </div>
        </Col>
      </Row>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <Checkbox checked={hide} onChange={(e) => setHide(e.target.checked)}>
          Не открывать автоматически
        </Checkbox>
        <Typography.Text type="secondary" style={{ fontSize: 12, flex: 1 }}>
          · окно всегда можно открыть снова кнопкой «Что это и как пользоваться?»
        </Typography.Text>
        <Button type="primary" size="large" onClick={close}>
          Понятно
        </Button>
      </div>
    </Modal>
  )
}

const box: CSSProperties = { boxSizing: 'border-box', border: '1px solid #eaecf0', borderRadius: 14, padding: '16px 18px', display: 'flex', flexDirection: 'column', gap: 10 }
const hint: CSSProperties = { color: MUTED, fontSize: 13 }

function ShareBar({ label, parts }: { label: string; parts: number[] }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      <span style={{ width: 60, color: MUTED, fontSize: 12, fontWeight: 600 }}>{label}</span>
      <div style={{ flex: 1, display: 'flex', gap: 2, height: 22 }}>
        {(['A', 'B', 'C'] as const).map((k, i) => (
          <div
            key={k}
            style={{ flex: `${Math.max(parts[i], 5)} 0 0`, background: GROUP[k].color, borderRadius: 4, color: '#fff', fontSize: 11, fontWeight: 700, display: 'grid', placeItems: 'center', overflow: 'hidden', whiteSpace: 'nowrap' }}
          >
            {parts[i] >= 10 ? `${k} ${parts[i]}%` : ''}
          </div>
        ))}
      </div>
    </div>
  )
}

function HelpItem({ letter, tone, title, text, weeks }: { letter: string; tone: { bg: string; text: string }; title: string; text: string; weeks?: number[] }) {
  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
      <span style={{ ...badgeBox, flex: 'none', background: tone.bg, color: tone.text }}>{letter}</span>
      <div style={{ flex: 1 }}>
        <b>{title}</b>
        <div style={{ ...hint, fontSize: 12 }}>{text}</div>
      </div>
      {weeks && (
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 3, height: 30, flex: 'none' }} aria-hidden>
          {weeks.map((v, i) => (
            <span key={i} style={{ width: 9, height: Math.max(2, v * 1.6), background: '#155eef', borderRadius: 2 }} />
          ))}
        </div>
      )}
    </div>
  )
}
