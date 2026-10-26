// Весы и товары без штрихкода (Figma «Панель магазина · Весы и товары без
// штрихкода», В1–В5).
//
// Весовой товар (кг): номер на весах (PLU). Весы печатают наклейку
// «22 · номер · вес», касса находит товар по номеру и берёт цену отсюда.
// Штучный без заводского штрихкода: свой штрихкод Super Market «20…»,
// наклейки 58×40 или лист А4 у кассы. Номера и коды — свои у сети.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { Alert, App, Button, Card, Checkbox, Col, Form, Input, InputNumber, Modal, Radio, Row, Select, Space, Switch, Table, Tag, Typography } from 'antd'
import { BarcodeOutlined, CheckCircleFilled, PlusOutlined, PrinterOutlined, SettingOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, api, errorText, money, qty as fmtQty, tr, useAction, useItem, useList } from '@sm/shared'
import { useStore } from '../ctx'
import type { Product } from '../types'

// ------------------------------------------------------------------ типы

export type ScaleSettings = { enabled: boolean; prefix: string; item_digits: number; value: 'weight' | 'sum'; weight_step: 1 | 10 }

export type ScaleItem = {
  product_id: string
  name: string
  unit: string
  plu: number | null
  price: string
  price_at: string | null
  stock: string
  /** entered — введено, changed — обновите в весах, new — введите в весы, no_plu — нет номера. */
  status: 'entered' | 'changed' | 'new' | 'no_plu'
  entered_at: string | null
  from_pos: boolean
  own: boolean
}

type ScaleList = { items: ScaleItem[]; next_plu: number }

export type NoBarcodeItem = { product_id: string; name: string; unit: string; price: string; own_barcode: string | null; own: boolean }

export type ScaleCounts = { scales: number; no_barcode: number; to_update: number }

type SellMode = { product_id: string; mode: 'piece' | 'weight'; unit: string; plu: number | null; own_barcode: string | null; own: boolean }

/** Что открыть в карточке «Как продаётся». */
export type SellTarget = { id: string; name: string; price?: string; mode?: 'piece' | 'weight' }

const SCALES = '/store/scales/products'
const NO_BARCODE = '/store/scales/no-barcode'
const COUNTS = '/store/scales/counts'
const SETTINGS = '/store/scales/settings'

export function useScaleCounts(storeId: string | undefined, enabled = true) {
  return useItem<ScaleCounts>(storeId && enabled ? COUNTS : null, { store_id: storeId })
}

const short = (d: string | null) => (d ? new Date(d).toLocaleDateString(tr('ru-RU', 'uz-UZ'), { day: 'numeric', month: 'short' }).replace('.', '') : '')

const pad = (n: number, len: number) => String(n).padStart(len, '0')

// ------------------------------------------------------------ EAN-13

const L = ['0001101', '0011001', '0010011', '0111101', '0100011', '0110001', '0101111', '0111011', '0110111', '0001011']
const G = ['0100111', '0110011', '0011011', '0100001', '0011101', '0111001', '0000101', '0010001', '0001001', '0010111']
const R = ['1110010', '1100110', '1101100', '1000010', '1011100', '1001110', '1010000', '1000100', '1001000', '1110100']
const PARITY = ['LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG', 'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL']

export function validEan13(c: string) {
  if (!/^[0-9]{13}$/.test(c)) return false
  let sum = 0
  for (let i = 0; i < 12; i++) sum += Number(c[i]) * (i % 2 ? 3 : 1)
  return (10 - (sum % 10)) % 10 === Number(c[12])
}

/** SVG штрихкода EAN-13 с цифрами снизу; height — высота штрихов в модулях. */
export function ean13Svg(code: string, height = 50): string {
  if (!validEan13(code)) return ''
  const d = code.split('').map(Number)
  let bits = '101'
  const par = PARITY[d[0]]
  for (let i = 1; i <= 6; i++) bits += (par[i - 1] === 'L' ? L : G)[d[i]]
  bits += '01010'
  for (let i = 7; i <= 12; i++) bits += R[d[i]]
  bits += '101'
  const quiet = 9
  const w = bits.length + quiet * 2
  const guard = new Set([0, 1, 2, 45, 46, 47, 48, 49, 92, 93, 94])
  let rects = ''
  for (let i = 0; i < bits.length; i++) {
    if (bits[i] !== '1') continue
    const h = guard.has(i) ? height + 5 : height
    rects += `<rect x="${i + quiet}" y="0" width="1" height="${h}"/>`
  }
  const txt = (x: number, s: string) => `<text x="${x}" y="${height + 12}" font-size="10" font-family="monospace" text-anchor="middle">${s}</text>`
  const digits = txt(quiet - 4, code[0]) + txt(quiet + 3 + 21, code.slice(1, 7)) + txt(quiet + 50 + 21, code.slice(7))
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${height + 14}" preserveAspectRatio="none">${rects}${digits}</svg>`
}

export function Barcode({ code, width = 150 }: { code: string; width?: number }) {
  const svg = ean13Svg(code)
  if (!svg) return <Typography.Text code>{code}</Typography.Text>
  return <span style={{ display: 'inline-block', width, lineHeight: 0 }} dangerouslySetInnerHTML={{ __html: svg }} />
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)

/** Печать в отдельном окне: свой размер страницы, без шапки панели. */
function printHtml(title: string, css: string, body: string) {
  const w = window.open('', '_blank', 'width=900,height=700')
  if (!w) return false
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${esc(title)}</title>
<style>*{box-sizing:border-box}body{margin:0;font-family:Inter,Arial,sans-serif;color:#111}${css}</style></head>
<body>${body}<script>window.onload=function(){setTimeout(function(){window.print()},200)}</script></body></html>`)
  w.document.close()
  return true
}

// ------------------------------------------------------ формат наклейки

export type ParsedSticker = { prefix: string; item: string; value: string; check: string; plu: number; raw: number; digits: number }

/** Разбор наклейки при известном числе цифр номера. */
export function parseSticker(code: string, digits: number): ParsedSticker | null {
  if (!validEan13(code)) return null
  const prefix = code.slice(0, 2)
  const item = code.slice(2, 2 + digits)
  const value = code.slice(2 + digits, 12)
  return { prefix, item, value, check: code[12], plu: Number(item), raw: Number(value), digits }
}

/** Формат по одной наклейке: число цифр номера, при котором номер есть в «На весах». */
export function detectSticker(code: string, known: (plu: number) => boolean, fallback = 5): ParsedSticker | null {
  for (const d of [fallback, 5, 4, 6]) {
    const p = parseSticker(code, d)
    if (p && known(p.plu)) return p
  }
  return parseSticker(code, fallback)
}

// =================================================== В1 · «На весах»

const statusCell = (r: ScaleItem, onEntered: (id: string) => void, onPLU: (r: ScaleItem) => void, can: boolean) => {
  switch (r.status) {
    case 'entered':
      return (
        <Space size={4} direction="vertical">
          <Tag color="green" bordered={false}>
            ✓ {tr('введено', 'kiritilgan')}
          </Tag>
          {r.from_pos && <Typography.Text type="secondary" style={{ fontSize: 12 }}>{tr('номер запомнила касса', 'raqamni kassa eslab qoldi')}</Typography.Text>}
        </Space>
      )
    case 'changed':
    case 'new':
      return (
        <Space size={6} wrap>
          <Space size={2} direction="vertical">
            <Tag color={r.status === 'new' ? 'blue' : 'orange'} bordered={false}>
              {r.status === 'new' ? tr('новый', 'yangi') : r.price_at ? tr(`цена изменена ${short(r.price_at)}`, `narx oʻzgardi ${short(r.price_at)}`) : tr('изменён', 'oʻzgargan')}
            </Tag>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {r.status === 'new' ? tr('введите в весы', 'taroziga kiriting') : tr('обновите в весах', 'tarozida yangilang')}
            </Typography.Text>
          </Space>
          {can && (
            <Button size="small" onClick={() => onEntered(r.product_id)}>
              {tr('Введено', 'Kiritildi')}
            </Button>
          )}
        </Space>
      )
    default:
      return can ? (
        <Button size="small" onClick={() => onPLU(r)}>
          {tr('Выдать номер', 'Raqam berish')}
        </Button>
      ) : (
        <Typography.Text type="secondary">{tr('нет номера', 'raqam yoʻq')}</Typography.Text>
      )
  }
}

export function ScalesTab({ onOpen }: { onOpen: (t: SellTarget) => void }) {
  const { storeId, store, can } = useStore()
  const list = useItem<ScaleList>(storeId ? SCALES : null, { store_id: storeId })
  const settings = useItem<ScaleSettings>(SETTINGS)
  const manage = can('catalog.manage')
  const canEnter = manage || can('prices.manage')
  const [adding, setAdding] = useState(false)
  const entered = useAction((ids: string[]) => api.post('/store/scales/entered', { store_id: storeId, product_ids: ids }), {
    invalidate: [[SCALES], [COUNTS]],
    success: tr('Отмечено: введено в весы', 'Belgilandi: taroziga kiritildi'),
  })
  const givePLU = useAction((id: string) => api.put(`/store/products/${id}/sell-mode`, { mode: 'weight' }), {
    invalidate: [[SCALES], [COUNTS]],
    success: tr('Номер выдан', 'Raqam berildi'),
  })
  if (!storeId) return <Alert type="info" showIcon message={tr('Выберите магазин вверху.', 'Yuqorida doʻkonni tanlang.')} />
  const items = list.data?.items ?? []
  const todo = items.filter((r) => r.status === 'new' || r.status === 'changed')
  const prefix = settings.data?.prefix ?? '22'
  const digits = settings.data?.item_digits ?? 5

  const printList = () => {
    const rows = items
      .filter((r) => r.plu !== null)
      .map((r) => `<tr><td class="n">${r.plu}</td><td>${esc(r.name)}</td><td class="p">${money(r.price)}</td><td class="c">${r.status === 'entered' ? '✓' : ''}</td></tr>`)
      .join('')
    printHtml(
      tr('Список для весов', 'Tarozi uchun roʻyxat'),
      `@page{size:A4;margin:14mm}h1{font-size:18px;margin:0 0 4px}p{margin:0 0 12px;color:#555;font-size:12px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{border:1px solid #bbb;padding:6px 8px;text-align:left}
th{background:#f2f2f2}.n{width:70px;font-weight:700;text-align:center}.p{width:110px;text-align:right}.c{width:60px;text-align:center}`,
      `<h1>${esc(tr('Список для весов', 'Tarozi uchun roʻyxat'))} · ${esc(store?.name ?? '')}</h1>
<p>${esc(tr(`Номер → название → цена за кг. Префикс наклейки ${prefix}, номер ${digits} цифр. Цену касса всё равно берёт из Super Market.`, `Raqam → nom → 1 kg narxi. Yorliq prefiksi ${prefix}, raqam ${digits} xona. Narxni kassa baribir Super Marketdan oladi.`))}</p>
<table><thead><tr><th>№</th><th>${esc(tr('Товар', 'Mahsulot'))}</th><th>${esc(tr('Цена за кг', '1 kg narxi'))}</th><th>${esc(tr('В весах', 'Tarozida'))}</th></tr></thead><tbody>${rows}</tbody></table>`,
    )
  }

  return (
    <>
      <Space style={{ marginBottom: 12, width: '100%', justifyContent: 'flex-end' }} wrap>
        <Link to="/settings/scales">
          <Button icon={<SettingOutlined />}>{tr('Весы', 'Tarozi')}</Button>
        </Link>
        <Button icon={<PrinterOutlined />} onClick={printList} disabled={!items.some((r) => r.plu !== null)}>
          {tr('Список для весов', 'Tarozi uchun roʻyxat')}
        </Button>
        {manage && (
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setAdding(true)}>
            {tr('Добавить', 'Qoʻshish')}
          </Button>
        )}
      </Space>
      {settings.data && !settings.data.enabled && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 12 }}
          message={tr('Весы с наклейками не включены', 'Yorliqli tarozi yoqilmagan')}
          description={
            <>
              {tr('Касса не будет понимать наклейки, пока не включите их в ', 'Kassa yorliqlarni tushunmaydi, ularni shu yerda yoqing: ')}
              <Link to="/settings/scales">{tr('Настройки → Весы', 'Sozlamalar → Tarozi')}</Link>.
            </>
          }
        />
      )}
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 12 }}
        message={tr('Номер здесь = номер товара в весах (PLU)', 'Bu yerdagi raqam = tarozidagi mahsulot raqami (PLU)')}
        description={tr(
          'Введите список в весы один раз: номер → название → цена за кг. Весы печатают на наклейке номер и вес, касса по номеру находит товар и берёт цену отсюда — даже если в весах цена старая.',
          'Roʻyxatni taroziga bir marta kiriting: raqam → nom → 1 kg narxi. Tarozi yorliqqa raqam va vaznni chop etadi, kassa raqam boʻyicha mahsulotni topadi va narxni shu yerdan oladi — tarozidagi narx eski boʻlsa ham.',
        )}
      />
      {todo.length > 1 && canEnter && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 12 }}
          message={tr(`${todo.length} товаров надо ввести или обновить в весах`, `${todo.length} ta mahsulotni taroziga kiritish yoki yangilash kerak`)}
          action={
            <Button size="small" loading={entered.isPending} onClick={() => entered.mutate(todo.map((r) => r.product_id))}>
              {tr('Все введены', 'Hammasi kiritildi')}
            </Button>
          }
        />
      )}
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<ScaleItem>
          rowKey="product_id"
          loading={list.isLoading || list.isFetching}
          dataSource={items}
          scroll={{ x: true }}
          pagination={{ pageSize: 50, hideOnSinglePage: true, showSizeChanger: false }}
          locale={{ emptyText: tr('Весовых товаров нет. «Добавить» — выбрать товар и дать ему номер.', 'Tortiladigan mahsulot yoʻq. «Qoʻshish» — mahsulotni tanlab, raqam bering.') }}
          onRow={(r) => ({ onClick: (e) => !(e.target as HTMLElement).closest('button') && onOpen({ id: r.product_id, name: r.name, price: r.price, mode: 'weight' }), style: { cursor: 'pointer' } })}
          columns={[
            {
              title: tr('№ на весах', 'Tarozidagi №'),
              key: 'plu',
              width: 110,
              render: (_, r) => (r.plu !== null ? <Typography.Text strong style={{ fontSize: 16 }}>{r.plu}</Typography.Text> : <Typography.Text type="secondary">—</Typography.Text>),
            },
            {
              title: tr('Товар', 'Mahsulot'),
              key: 'name',
              render: (_, r) => (
                <>
                  <div>{r.name}</div>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {r.unit} · {tr('без заводского штрихкода', 'zavod shtrix-kodisiz')}
                  </Typography.Text>
                </>
              ),
            },
            { title: tr(`Цена за ${'кг'}`, '1 kg narxi'), key: 'price', align: 'right', render: (_, r) => money(r.price) },
            { title: tr('Остаток', 'Qoldiq'), key: 'stock', align: 'right', render: (_, r) => fmtQty(r.stock, r.unit) },
            {
              title: tr('В весах', 'Tarozida'),
              key: 'status',
              render: (_, r) => statusCell(r, (id) => entered.mutate([id]), (x) => givePLU.mutate(x.product_id), canEnter && (r.status !== 'no_plu' || manage)),
            },
          ]}
        />
      </Card>
      {list.data && (
        <Typography.Paragraph type="secondary" style={{ marginTop: 12, fontSize: 12 }}>
          {tr(`Номер выдаётся сам, следующий свободный — ${list.data.next_plu}. Нажмите на строку — поменять номер или «Как продаётся».`, `Raqam oʻzi beriladi, keyingi boʻsh raqam — ${list.data.next_plu}. Qatorni bosing — raqamni yoki «Qanday sotiladi»ni oʻzgartirish.`)}
        </Typography.Paragraph>
      )}
      <AddToScales open={adding} onClose={() => setAdding(false)} onPick={(t) => onOpen({ ...t, mode: 'weight' })} />
    </>
  )
}

/** «Добавить»: выбрать товар магазина — дальше карточка «Как продаётся: На развес». */
function AddToScales({ open, onClose, onPick }: { open: boolean; onClose: () => void; onPick: (t: SellTarget) => void }) {
  const { storeId } = useStore()
  const [id, setId] = useState<string>()
  const picked = useRef<Product | null>(null)
  return (
    <Modal
      open={open}
      title={tr('Добавить товар на весы', 'Mahsulotni taroziga qoʻshish')}
      okText={tr('Дальше', 'Keyingi')}
      okButtonProps={{ disabled: !id }}
      onCancel={onClose}
      onOk={() => {
        if (!id) return
        onClose()
        onPick({ id, name: picked.current?.name ?? '', price: picked.current?.price ?? undefined })
        setId(undefined)
      }}
      destroyOnHidden
    >
      <Typography.Paragraph type="secondary">
        {tr('Товар из «Моих товаров», который продаётся на развес. Номер на весах Super Market выдаст сам.', '«Mening mahsulotlarim»dan tortib sotiladigan mahsulot. Tarozi raqamini Super Market oʻzi beradi.')}
      </Typography.Paragraph>
      <RemoteSelect<Product & Record<string, unknown>>
        path="/store/products"
        params={{ scope: 'mine', store_id: storeId || undefined }}
        search
        showSearch
        filterOption={false}
        style={{ width: '100%' }}
        placeholder={tr('Название или штрихкод', 'Nomi yoki shtrix-kod')}
        value={id}
        label={(p) => `${p.name} · ${p.unit_short}`}
        onChange={(v, opt) => {
          setId(v as string)
          picked.current = { id: v, name: String((opt as { label?: ReactNode })?.label ?? '').split(' · ')[0] } as Product
        }}
      />
    </Modal>
  )
}

// ============================================ В3 · «Без штрихкода»

export function NoBarcodeTab({ onOpen }: { onOpen: (t: SellTarget) => void }) {
  const { storeId, can } = useStore()
  const list = useList<NoBarcodeItem>(storeId ? NO_BARCODE : null, { store_id: storeId })
  const manage = can('catalog.manage')
  const [selected, setSelected] = useState<string[]>([])
  const [printing, setPrinting] = useState<NoBarcodeItem[] | null>(null)
  const issue = useAction((ids: string[]) => api.post('/store/own-barcodes', { product_ids: ids }), {
    invalidate: [[NO_BARCODE]],
    success: tr('Штрихкоды выданы', 'Shtrix-kodlar berildi'),
  })
  if (!storeId) return <Alert type="info" showIcon message={tr('Выберите магазин вверху.', 'Yuqorida doʻkonni tanlang.')} />
  const items = list.data ?? []
  const missing = items.filter((r) => !r.own_barcode)
  const chosen = items.filter((r) => selected.includes(r.product_id))
  const chosenMissing = chosen.filter((r) => !r.own_barcode)

  return (
    <>
      <Space style={{ marginBottom: 12, width: '100%', justifyContent: 'flex-end' }} wrap>
        {manage && (
          <Button icon={<BarcodeOutlined />} disabled={missing.length === 0} loading={issue.isPending} onClick={() => issue.mutate(missing.map((r) => r.product_id))}>
            {tr('Выдать всем без кода', 'Kodsizlarning hammasiga berish')}
          </Button>
        )}
        <Button type="primary" icon={<PrinterOutlined />} disabled={chosen.length === 0} onClick={() => setPrinting(chosen)}>
          {tr('Печать штрихкодов', 'Shtrix-kodlarni chop etish')}
          {chosen.length > 0 ? ` · ${chosen.length}` : ''}
        </Button>
      </Space>
      <Alert
        type="info"
        showIcon
        icon={<BarcodeOutlined />}
        style={{ marginBottom: 12 }}
        message={tr('Штучный товар без заводского штрихкода', 'Zavod shtrix-kodi yoʻq donali mahsulot')}
        description={tr(
          'Super Market выдаёт свой штрихкод «20…» — он работает только в вашем магазине. Наклейте его на товар или положите у кассы лист со штрихкодами: кассир сканирует с листа.',
          'Super Market oʻz «20…» shtrix-kodini beradi — u faqat sizning doʻkoningizda ishlaydi. Uni mahsulotga yopishtiring yoki kassa yoniga shtrix-kodlar varagʻini qoʻying: kassir varaqdan skanerlaydi.',
        )}
      />
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<NoBarcodeItem>
          rowKey="product_id"
          loading={list.isLoading || list.isFetching}
          dataSource={items}
          scroll={{ x: true }}
          pagination={{ pageSize: 50, hideOnSinglePage: true, showSizeChanger: false }}
          rowSelection={{ selectedRowKeys: selected, onChange: (k) => setSelected(k as string[]) }}
          locale={{ emptyText: tr('У всех штучных товаров есть штрихкод', 'Barcha donali mahsulotlarda shtrix-kod bor') }}
          onRow={(r) => ({
            onClick: (e) => {
              const el = e.target as HTMLElement
              if (!el.closest('button') && !el.closest('.ant-checkbox-wrapper') && !el.closest('.ant-table-selection-column')) onOpen({ id: r.product_id, name: r.name, price: r.price, mode: 'piece' })
            },
            style: { cursor: 'pointer' },
          })}
          columns={[
            {
              title: tr('Товар', 'Mahsulot'),
              key: 'name',
              render: (_, r) => (
                <>
                  <div>{r.name}</div>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {tr('штучно', 'donalab')} · {r.unit}
                  </Typography.Text>
                </>
              ),
            },
            { title: tr('Цена', 'Narx'), key: 'price', align: 'right', render: (_, r) => money(r.price) },
            {
              title: tr('Штрихкод Super Market', 'Super Market shtrix-kodi'),
              key: 'code',
              render: (_, r) => (r.own_barcode ? <Barcode code={r.own_barcode} width={130} /> : <Typography.Text type="secondary">{tr('нет штрихкода', 'shtrix-kod yoʻq')}</Typography.Text>),
            },
            {
              key: 'act',
              align: 'right',
              render: (_, r) =>
                r.own_barcode ? (
                  <Button size="small" icon={<PrinterOutlined />} onClick={() => setPrinting([r])}>
                    {tr('Печать', 'Chop etish')}
                  </Button>
                ) : manage ? (
                  <Button size="small" loading={issue.isPending} onClick={() => issue.mutate([r.product_id])}>
                    {tr('Выдать', 'Berish')}
                  </Button>
                ) : null,
            },
          ]}
        />
      </Card>
      {chosen.length > 0 && (
        <Card size="small" style={{ marginTop: 12 }}>
          <Space style={{ width: '100%', justifyContent: 'space-between' }} wrap>
            <Typography.Text>
              {tr(`Выбрано ${chosen.length}`, `Tanlandi: ${chosen.length}`)}
              {chosenMissing.length > 0 &&
                tr(
                  ` · ${chosenMissing.length === 1 ? `у «${chosenMissing[0].name}» штрихкода нет` : `у ${chosenMissing.length} товаров штрихкода нет`} — выдадим при печати`,
                  ` · ${chosenMissing.length} ta mahsulotda shtrix-kod yoʻq — chop etishda beramiz`,
                )}
            </Typography.Text>
            <Button type="primary" icon={<PrinterOutlined />} onClick={() => setPrinting(chosen)}>
              {tr(`Печать штрихкодов · ${chosen.length}`, `Shtrix-kodlarni chop etish · ${chosen.length}`)}
            </Button>
          </Space>
        </Card>
      )}
      <PrintModal items={printing} onClose={() => setPrinting(null)} />
    </>
  )
}

// ======================================================== В4 · печать

type PrintTarget = 'stickers' | 'a4'

function PrintModal({ items, onClose }: { items: NoBarcodeItem[] | null; onClose: () => void }) {
  const { store, can } = useStore()
  const { message } = App.useApp()
  const [target, setTarget] = useState<PrintTarget>('stickers')
  const [counts, setCounts] = useState<Record<string, number>>({})
  const [show, setShow] = useState({ name: true, price: true, date: false })
  const [busy, setBusy] = useState(false)
  const open = !!items && items.length > 0
  useEffect(() => {
    if (items) setCounts(Object.fromEntries(items.map((i) => [i.product_id, 20])))
  }, [items])
  // Новые коды, которые выдадим при печати, — чтобы показать номер заранее нельзя
  // (его даёт сервер), поэтому для них пишем «новый».
  const missing = (items ?? []).filter((i) => !i.own_barcode)
  const total = target === 'a4' ? (items?.length ?? 0) : (items ?? []).reduce((s, i) => s + (counts[i.product_id] ?? 0), 0)
  const sample = items?.find((i) => i.own_barcode) ?? items?.[0]

  const run = async () => {
    if (!items) return
    setBusy(true)
    try {
      let codes: Record<string, string> = Object.fromEntries(items.filter((i) => i.own_barcode).map((i) => [i.product_id, i.own_barcode!]))
      if (missing.length) {
        if (!can('catalog.manage')) {
          message.error(tr('Выдать штрихкод может сотрудник с правом «Товары»', 'Shtrix-kodni «Mahsulotlar» huquqiga ega xodim beradi'))
          return
        }
        const res = await api.post<{ items: { product_id: string; barcode: string }[] }>('/store/own-barcodes', { product_ids: missing.map((i) => i.product_id) })
        codes = { ...codes, ...Object.fromEntries(res.items.map((x) => [x.product_id, x.barcode])) }
      }
      const today = new Date().toLocaleDateString('ru-RU')
      const label = (i: NoBarcodeItem) => {
        const code = codes[i.product_id]
        return `<div class="lbl">${show.name ? `<div class="nm">${esc(i.name)}</div>` : ''}${show.price ? `<div class="pr">${money(i.price)} ${esc(tr('сум', 'soʻm'))}</div>` : ''}<div class="bc">${ean13Svg(code)}</div><div class="ft">${esc(store?.name ?? '')}${show.date ? ' · ' + today : ''}</div></div>`
      }
      let body = ''
      let css = ''
      if (target === 'stickers') {
        css = `@page{size:58mm 40mm;margin:0}.lbl{width:58mm;height:40mm;padding:2mm 3mm;display:flex;flex-direction:column;page-break-after:always;overflow:hidden}
.nm{font-size:10pt;font-weight:700;line-height:1.15;max-height:2.3em;overflow:hidden}.pr{font-size:12pt;font-weight:800;margin-top:1mm}
.bc{flex:1;display:flex;align-items:flex-end}.bc svg{width:100%;height:17mm}.ft{font-size:6.5pt;color:#444;margin-top:0.5mm}`
        for (const i of items) for (let k = 0; k < (counts[i.product_id] ?? 0); k++) body += label(i)
      } else {
        css = `@page{size:A4;margin:10mm}h1{font-size:14pt;margin:0 0 6mm}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:4mm}
.lbl{border:1px dashed #999;border-radius:2mm;padding:3mm;break-inside:avoid}.nm{font-size:11pt;font-weight:700}.pr{font-size:11pt;margin-top:1mm}
.bc svg{width:100%;height:20mm;margin-top:2mm}.ft{font-size:7pt;color:#555;margin-top:1mm}`
        body = `<h1>${esc(tr('Штрихкоды для кассы', 'Kassa uchun shtrix-kodlar'))} · ${esc(store?.name ?? '')}</h1><div class="grid">${items.map(label).join('')}</div>`
      }
      if (!printHtml(tr('Печать штрихкодов', 'Shtrix-kodlarni chop etish'), css, body)) message.error(tr('Браузер не открыл окно печати — разрешите всплывающие окна', 'Brauzer chop etish oynasini ochmadi — qalqib chiquvchi oynalarga ruxsat bering'))
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      width={720}
      title={
        <>
          {tr('Печать штрихкодов', 'Shtrix-kodlarni chop etish')}
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 13, fontWeight: 400 }}>
              {tr(`${items?.length ?? 0} товара`, `${items?.length ?? 0} ta mahsulot`)}
              {missing.length > 0 && tr(` · ${missing.length === 1 ? `у «${missing[0].name}»` : `у ${missing.length} товаров`} будет новый штрихкод`, ` · ${missing.length} ta mahsulotga yangi shtrix-kod beriladi`)}
            </Typography.Text>
          </div>
        </>
      }
      onCancel={onClose}
      okText={target === 'stickers' ? tr(`Печать · ${total} наклеек`, `Chop etish · ${total} ta yorliq`) : tr('Печать листа А4', 'A4 varagʻini chop etish')}
      okButtonProps={{ icon: <PrinterOutlined />, loading: busy, disabled: total === 0 }}
      cancelText={tr('Отмена', 'Bekor qilish')}
      onOk={run}
      destroyOnHidden
    >
      <Row gutter={20}>
        <Col xs={24} md={14}>
          <Typography.Text strong>{tr('Куда печатать', 'Qayerga chop etish')}</Typography.Text>
          <Radio.Group value={target} onChange={(e) => setTarget(e.target.value)} style={{ display: 'flex', flexDirection: 'column', gap: 8, margin: '8px 0 16px' }}>
            <Radio value="stickers">
              <b>{tr('Наклейки', 'Yorliqlar')}</b>
              <div>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {tr('принтер этикеток · 58×40 мм — клеить на товар', 'yorliq printeri · 58×40 mm — mahsulotga yopishtirish')}
                </Typography.Text>
              </div>
            </Radio>
            <Radio value="a4">
              <b>{tr('Лист А4', 'A4 varagʻi')}</b>
              <div>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {tr('все штрихкоды на одном листе — положить у кассы', 'barcha shtrix-kodlar bitta varaqda — kassa yoniga qoʻyish')}
                </Typography.Text>
              </div>
            </Radio>
          </Radio.Group>
          {target === 'stickers' && (
            <>
              <Typography.Text strong>{tr('Сколько наклеек', 'Nechta yorliq')}</Typography.Text>
              <div style={{ margin: '8px 0 16px', display: 'flex', flexDirection: 'column', gap: 8 }}>
                {(items ?? []).map((i) => (
                  <Space key={i.product_id} style={{ justifyContent: 'space-between', width: '100%' }}>
                    <span>
                      {i.name}
                      <div>
                        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                          {i.own_barcode ?? tr('новый штрихкод', 'yangi shtrix-kod')}
                        </Typography.Text>
                      </div>
                    </span>
                    <InputNumber min={0} max={500} value={counts[i.product_id] ?? 0} onChange={(v) => setCounts((c) => ({ ...c, [i.product_id]: v ?? 0 }))} style={{ width: 90 }} />
                  </Space>
                ))}
              </div>
            </>
          )}
          <Typography.Text strong>{tr('На наклейке', 'Yorliqda')}</Typography.Text>
          <div style={{ marginTop: 8 }}>
            <Checkbox checked={show.name} onChange={(e) => setShow((s) => ({ ...s, name: e.target.checked }))}>
              {tr('Название', 'Nomi')}
            </Checkbox>
            <Checkbox checked={show.price} onChange={(e) => setShow((s) => ({ ...s, price: e.target.checked }))}>
              {tr('Цена', 'Narx')}
            </Checkbox>
            <Checkbox checked={show.date} onChange={(e) => setShow((s) => ({ ...s, date: e.target.checked }))}>
              {tr('Дата', 'Sana')}
            </Checkbox>
          </div>
        </Col>
        <Col xs={24} md={10}>
          <Typography.Text strong>{tr('Так будет выглядеть', 'Shunday koʻrinadi')}</Typography.Text>
          {sample && (
            <div style={{ marginTop: 8, border: '1px solid #d9d9d9', borderRadius: 8, padding: '10px 12px', width: 232, minHeight: 160, background: '#fff' }}>
              {show.name && <div style={{ fontWeight: 700, fontSize: 14, lineHeight: 1.2 }}>{sample.name}</div>}
              {show.price && <div style={{ fontWeight: 800, fontSize: 16, marginTop: 2 }}>{money(sample.price)} {tr('сум', 'soʻm')}</div>}
              <div style={{ marginTop: 6 }}>{sample.own_barcode ? <Barcode code={sample.own_barcode} width={200} /> : <Typography.Text type="secondary">{tr('штрихкод выдадим при печати', 'shtrix-kod chop etishda beriladi')}</Typography.Text>}</div>
              <div style={{ fontSize: 11, color: '#666', marginTop: 4 }}>
                58 × 40 {tr('мм', 'mm')} · {store?.name}
                {show.date ? ` · ${new Date().toLocaleDateString('ru-RU')}` : ''}
              </div>
            </div>
          )}
        </Col>
      </Row>
    </Modal>
  )
}

// ============================================ В5 · «Как продаётся»

export function SellModeModal({ target, onClose }: { target: SellTarget | null; onClose: () => void }) {
  const { storeId, can } = useStore()
  const { message } = App.useApp()
  const cur = useItem<SellMode>(target ? `/store/products/${target.id}/sell-mode` : null)
  const scales = useItem<ScaleList>(target && storeId ? SCALES : null, { store_id: storeId })
  const settings = useItem<ScaleSettings>(target ? SETTINGS : null)
  const [mode, setMode] = useState<'piece' | 'weight'>('piece')
  const [plu, setPlu] = useState<number | null>(null)
  const [scan, setScan] = useState('')
  const [scanning, setScanning] = useState(false)
  const manage = can('catalog.manage')
  useEffect(() => {
    if (!cur.data) return
    setMode(target?.mode === 'weight' ? 'weight' : cur.data.mode)
    setPlu(cur.data.plu)
    setScan('')
    setScanning(false)
  }, [cur.data, target])
  const save = useAction((v: { mode: string; plu?: number | null }) => api.put<SellMode>(`/store/products/${target!.id}/sell-mode`, v), {
    invalidate: [[SCALES], [COUNTS], [NO_BARCODE], ['/store/products'], [`/store/products/${target?.id}/sell-mode`]],
    success: tr('Сохранено', 'Saqlandi'),
  })
  const issue = useAction((id: string) => api.post('/store/own-barcodes', { product_ids: [id] }), {
    invalidate: [[NO_BARCODE], [`/store/products/${target?.id}/sell-mode`]],
    success: tr('Штрихкод выдан', 'Shtrix-kod berildi'),
  })
  const factory = useAction((code: string) => api.patch(`/store/products/${target!.id}`, { barcodes: [code] }), {
    invalidate: [[NO_BARCODE], [COUNTS], ['/store/products']],
    success: tr('Заводской штрихкод сохранён', 'Zavod shtrix-kodi saqlandi'),
  })
  const row = scales.data?.items.find((r) => r.product_id === target?.id)
  const price = row?.price ?? target?.price
  const next = scales.data?.next_plu
  const shownPLU = plu ?? next ?? null
  const prefix = settings.data?.prefix ?? '22'
  const digits = settings.data?.item_digits ?? 5
  const name = target?.name ?? ''
  const shared = !!cur.data && !cur.data.own

  return (
    <Modal
      open={!!target}
      width={520}
      title={
        <>
          {name}
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 13, fontWeight: 400 }}>
              {tr('Товары → карточка товара', 'Mahsulotlar → mahsulot kartochkasi')}
            </Typography.Text>
          </div>
        </>
      }
      onCancel={onClose}
      okText={tr('Сохранить', 'Saqlash')}
      cancelText={tr('Отмена', 'Bekor qilish')}
      okButtonProps={{ disabled: !manage || !cur.data, loading: save.isPending }}
      onOk={() =>
        save.mutate(
          { mode, plu: mode === 'weight' ? (plu ?? undefined) : undefined },
          {
            onSuccess: () => onClose(),
          },
        )
      }
      destroyOnHidden
    >
      <LoadError error={cur.error} retry={() => cur.refetch()} />
      {cur.data && (
        <Form layout="vertical" disabled={!manage}>
          <Form.Item label={tr('Как продаётся', 'Qanday sotiladi')}>
            <Radio.Group value={mode} onChange={(e) => setMode(e.target.value)} optionType="button" buttonStyle="solid">
              <Radio.Button value="piece">{tr('Штучно', 'Donalab')}</Radio.Button>
              <Radio.Button value="weight">{tr('На развес', 'Tortib')}</Radio.Button>
            </Radio.Group>
            {mode !== cur.data.mode && shared && (
              <Alert
                style={{ marginTop: 8 }}
                type="warning"
                showIcon
                message={tr('Это товар общей базы — единицу меняет Super Market. Напишите в поддержку.', 'Bu umumiy baza mahsuloti — birlikni Super Market oʻzgartiradi. Qoʻllab-quvvatlashga yozing.')}
              />
            )}
          </Form.Item>
          <Row gutter={12}>
            <Col span={12}>
              <Form.Item label={mode === 'weight' ? tr('Цена за кг', '1 kg narxi') : tr('Цена', 'Narx')} extra={tr('меняется в «Установке цен»', '«Narx belgilash»da oʻzgaradi')}>
                <Input value={price ? money(price) : '—'} suffix={tr('сум', 'soʻm')} readOnly />
              </Form.Item>
            </Col>
            {mode === 'weight' ? (
              <Col span={12}>
                <Form.Item label={tr('Номер на весах', 'Tarozidagi raqam')} extra={cur.data.plu ? tr('можно поменять', 'oʻzgartirish mumkin') : tr('выдан сам, можно поменять', 'oʻzi beriladi, oʻzgartirish mumkin')}>
                  <InputNumber min={1} max={Number('9'.repeat(digits))} value={shownPLU} onChange={(v) => setPlu(v)} addonAfter="PLU" style={{ width: '100%' }} />
                </Form.Item>
              </Col>
            ) : (
              <Col span={12}>
                <Form.Item label={tr('Штрихкод', 'Shtrix-kod')}>
                  {cur.data.own_barcode ? <Barcode code={cur.data.own_barcode} width={170} /> : <Typography.Text type="secondary">{tr('нет', 'yoʻq')}</Typography.Text>}
                </Form.Item>
              </Col>
            )}
          </Row>
          {mode === 'weight' ? (
            <Alert
              type="info"
              showIcon
              message={tr(
                `Штрихкод не нужен: весы печатают наклейку «${prefix} · ${pad(shownPLU ?? 0, digits)} · вес». Введите в весы: ${shownPLU ?? '…'} → ${name} → ${price ? money(price) : '…'}.`,
                `Shtrix-kod kerak emas: tarozi «${prefix} · ${pad(shownPLU ?? 0, digits)} · vazn» yorligʻini chop etadi. Taroziga kiriting: ${shownPLU ?? '…'} → ${name} → ${price ? money(price) : '…'}.`,
              )}
            />
          ) : (
            !cur.data.own_barcode && (
              <>
                <Space wrap style={{ marginBottom: 8 }}>
                  <Button icon={<BarcodeOutlined />} loading={issue.isPending} disabled={cur.data.mode !== 'piece'} onClick={() => issue.mutate(target!.id)}>
                    {tr('Выдать штрихкод', 'Shtrix-kod berish')}
                  </Button>
                  <Button onClick={() => setScanning(true)} disabled={shared}>
                    {tr('Сканировать', 'Skanerlash')}
                  </Button>
                </Space>
                {scanning && (
                  <Input.Search
                    autoFocus
                    placeholder={tr('Отсканируйте заводской штрихкод', 'Zavod shtrix-kodini skanerlang')}
                    enterButton={tr('Сохранить', 'Saqlash')}
                    value={scan}
                    onChange={(e) => setScan(e.target.value.trim())}
                    loading={factory.isPending}
                    onPressEnter={(e) => e.preventDefault()}
                    onSearch={(v) => {
                      if (!/^[0-9A-Za-z-]{4,32}$/.test(v.trim())) return message.error(tr('Это не похоже на штрихкод', 'Bu shtrix-kodga oʻxshamaydi'))
                      factory.mutate(v.trim(), { onSuccess: () => onClose() })
                    }}
                    style={{ marginBottom: 8 }}
                  />
                )}
                <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginBottom: 0 }}>
                  {tr('Если на товаре есть заводской штрихкод — отсканируйте его. Если нет — Super Market выдаст свой «20…» и предложит напечатать.', 'Agar mahsulotda zavod shtrix-kodi boʻlsa — uni skanerlang. Boʻlmasa — Super Market oʻz «20…» kodini beradi va chop etishni taklif qiladi.')}
                </Typography.Paragraph>
              </>
            )
          )}
        </Form>
      )}
    </Modal>
  )
}

// ================================================ В2 · Настройки → Весы

export function ScaleSettingsPage() {
  const { storeId, can } = useStore()
  const settings = useItem<ScaleSettings>(SETTINGS)
  const scales = useItem<ScaleList>(storeId ? SCALES : null, { store_id: storeId })
  const [form] = Form.useForm<ScaleSettings>()
  const [code, setCode] = useState('')
  const [parsed, setParsed] = useState<ParsedSticker | null>(null)
  const [scanErr, setScanErr] = useState('')
  const scanRef = useRef<{ focus: () => void } | null>(null)
  const readOnly = !(can('stores.manage') || can('catalog.manage'))
  const save = useAction((v: ScaleSettings) => api.put<ScaleSettings>(SETTINGS, v), {
    invalidate: [[SETTINGS], [SCALES]],
    success: tr('Настройки весов сохранены', 'Tarozi sozlamalari saqlandi'),
  })
  const byPlu = useMemo(() => new Map((scales.data?.items ?? []).filter((r) => r.plu !== null).map((r) => [r.plu!, r])), [scales.data])
  const enabled = Form.useWatch('enabled', form)
  const value = Form.useWatch('value', form) ?? 'weight'
  const step = Form.useWatch('weight_step', form) ?? 1
  const digits = Form.useWatch('item_digits', form) ?? 5

  const onScan = (raw: string) => {
    const c = raw.trim()
    setCode(c)
    setScanErr('')
    if (!validEan13(c)) {
      setParsed(null)
      setScanErr(tr('Это не штрихкод весов: нужен EAN-13 из 13 цифр с верной контрольной цифрой', 'Bu tarozi shtrix-kodi emas: toʻgʻri nazorat raqamli 13 xonali EAN-13 kerak'))
      return
    }
    if (c.startsWith('20')) {
      setParsed(null)
      setScanErr(tr('Код начинается с 20 — это штрихкод Super Market, а не наклейка весов. Перенастройте весы на префикс 21–29 (обычно 22).', '20 bilan boshlanadi — bu Super Market shtrix-kodi, tarozi yorligʻi emas. Tarozini 21–29 prefiksga sozlang (odatda 22).'))
      return
    }
    const p = detectSticker(c, (n) => byPlu.has(n), digits)
    setParsed(p)
    if (p) form.setFieldsValue({ prefix: p.prefix, item_digits: p.digits })
  }

  const formatted = (p: ParsedSticker) => {
    const row = byPlu.get(p.plu)
    if (value === 'sum') {
      const sum = p.raw
      if (!row) return { ok: false, text: tr(`№${p.plu} — такого номера нет в «На весах». Сумма на наклейке: ${money(sum)}.`, `№${p.plu} — «Tarozida» bunday raqam yoʻq. Yorliqdagi summa: ${money(sum)}.`) }
      const kg = Number(row.price) > 0 ? sum / Number(row.price) : 0
      return { ok: true, text: tr(`Формат понятен: на наклейке №${p.plu} — ${row.name}, ${money(sum)} ÷ ${money(row.price)} = ${fmtQty(kg.toFixed(3), 'кг')}`, `Format tushunarli: yorliqda №${p.plu} — ${row.name}, ${money(sum)} ÷ ${money(row.price)} = ${fmtQty(kg.toFixed(3), 'kg')}`) }
    }
    const kg = (p.raw * step) / 1000
    if (!row) return { ok: false, text: tr(`№${p.plu} — такого номера нет в «На весах». Вес: ${fmtQty(kg, 'кг')}. Проверьте номер в весах или дайте его товару.`, `№${p.plu} — «Tarozida» bunday raqam yoʻq. Vazn: ${fmtQty(kg, 'kg')}. Tarozidagi raqamni tekshiring yoki uni mahsulotga bering.`) }
    const sum = Math.round(kg * Number(row.price))
    return { ok: true, text: tr(`Формат понятен: на наклейке №${p.plu} — ${row.name}, ${fmtQty(kg, 'кг')} × ${money(row.price)} = ${money(sum)}`, `Format tushunarli: yorliqda №${p.plu} — ${row.name}, ${fmtQty(kg, 'kg')} × ${money(row.price)} = ${money(sum)}`) }
  }

  if (!settings.data) return <LoadError error={settings.error} retry={() => settings.refetch()} />
  const box = (val: string, label: string, note: string, color: string) => (
    <div style={{ textAlign: 'center', minWidth: 90 }}>
      <div style={{ fontFamily: 'monospace', fontSize: 22, fontWeight: 700, padding: '6px 10px', borderRadius: 8, background: color }}>{val}</div>
      <div style={{ fontSize: 12, marginTop: 4 }}>{label}</div>
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
        {note}
      </Typography.Text>
    </div>
  )
  const f = parsed ? formatted(parsed) : null
  const valueNote = parsed
    ? value === 'sum'
      ? money(parsed.raw)
      : fmtQty((parsed.raw * step) / 1000, 'кг')
    : ''

  return (
    <>
      <PageTitle title={tr('Весы', 'Tarozi')} />
      <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
        {tr('Настройка для всей сети: как касса читает наклейку с весов. Номера товаров — в ', 'Butun tarmoq uchun sozlama: kassa tarozi yorligʻini qanday oʻqiydi. Mahsulot raqamlari — ')}
        <Link to="/dirs/products?tab=scales">{tr('Товары → На весах', 'Mahsulotlar → Tarozida')}</Link>.
      </Typography.Paragraph>
      <Form form={form} layout="vertical" disabled={readOnly} initialValues={settings.data} onFinish={(v) => save.mutate({ ...settings.data, ...v })} style={{ maxWidth: 820 }}>
        <Card style={{ marginBottom: 16 }}>
          <Space align="start" style={{ width: '100%', justifyContent: 'space-between' }}>
            <div>
              <Typography.Text strong>{tr('В магазине есть весы, которые печатают наклейки', 'Doʻkonda yorliq chop etadigan tarozi bor')}</Typography.Text>
              <div>
                <Typography.Text type="secondary">{tr('Подойдут любые: Kuanyi, CAS, Штрих-Принт, Масса-К… Касса будет понимать штрихкод с наклейки.', 'Har qandayi mos: Kuanyi, CAS, Shtrix-Print, Massa-K… Kassa yorliqdagi shtrix-kodni tushunadi.')}</Typography.Text>
              </div>
            </div>
            <Form.Item name="enabled" valuePropName="checked" noStyle>
              <Switch />
            </Form.Item>
          </Space>
        </Card>
        {enabled && (
          <Card style={{ marginBottom: 16 }}>
            <Space align="start" style={{ width: '100%', justifyContent: 'space-between' }} wrap>
              <div>
                <Typography.Text strong>{tr('Формат штрихкода на наклейке', 'Yorliqdagi shtrix-kod formati')}</Typography.Text>
                <div>
                  <Typography.Text type="secondary">{tr('Отсканируйте любую наклейку с весов — Super Market сам поймёт формат.', 'Tarozidan istalgan yorliqni skanerlang — Super Market formatni oʻzi tushunadi.')}</Typography.Text>
                </div>
              </div>
              <Button icon={<BarcodeOutlined />} onClick={() => scanRef.current?.focus()}>
                {tr('Сканировать наклейку', 'Yorliqni skanerlash')}
              </Button>
            </Space>
            <Input.Search
              ref={(el) => {
                scanRef.current = el
              }}
              style={{ marginTop: 12 }}
              placeholder={tr('Наведите сканер на наклейку или введите 13 цифр', 'Skanerni yorliqqa qarating yoki 13 raqamni kiriting')}
              enterButton={tr('Разобрать', 'Tahlil qilish')}
              value={code}
              onChange={(e) => setCode(e.target.value)}
              onSearch={onScan}
              // Сканер шлёт Enter после кода — разбираем наклейку, а не сохраняем форму.
              onPressEnter={(e) => e.preventDefault()}
              disabled={false}
            />
            {scanErr && <Alert style={{ marginTop: 12 }} type="error" showIcon message={scanErr} />}
            {parsed && (
              <div style={{ marginTop: 16, padding: 16, background: '#fafafa', borderRadius: 12 }}>
                <div>
                  <Typography.Text type="secondary">{tr(`Отсканировано: ${code}`, `Skanerlandi: ${code}`)}</Typography.Text>
                </div>
                <Space size={12} wrap style={{ marginTop: 12 }}>
                  {box(parsed.prefix, tr('Весовой', 'Tarozi'), tr('префикс', 'prefiks'), '#FEE4E2')}
                  {box(parsed.item, tr('Номер товара', 'Mahsulot raqami'), byPlu.get(parsed.plu) ? `№${parsed.plu} → ${byPlu.get(parsed.plu)!.name}` : `№${parsed.plu}`, '#EAECF0')}
                  {box(parsed.value, value === 'sum' ? tr('Сумма', 'Summa') : tr('Вес', 'Vazn'), valueNote, '#F2F4F7')}
                  {box(parsed.check, tr('Контроль', 'Nazorat'), tr('цифра', 'raqam'), '#F9FAFB')}
                </Space>
                {f && <Alert style={{ marginTop: 12 }} type={f.ok ? 'success' : 'warning'} showIcon icon={f.ok ? <CheckCircleFilled /> : undefined} message={f.text} />}
              </div>
            )}
            <Row gutter={16} style={{ marginTop: 16 }}>
              <Col xs={12} md={6}>
                <Form.Item name="prefix" label={tr('Префикс', 'Prefiks')} extra={tr('обычно 21–29', 'odatda 21–29')}>
                  <Select options={['21', '22', '23', '24', '25', '26', '27', '28', '29'].map((v) => ({ value: v, label: v }))} />
                </Form.Item>
              </Col>
              <Col xs={12} md={6}>
                <Form.Item name="item_digits" label={tr('Номер товара', 'Mahsulot raqami')} extra={tr('после префикса', 'prefiksdan keyin')}>
                  <Select options={[4, 5, 6].map((v) => ({ value: v, label: tr(`${v} цифр${v === 4 ? 'ы' : ''}`, `${v} xona`) }))} />
                </Form.Item>
              </Col>
              <Col xs={12} md={6}>
                <Form.Item name="value" label={tr('В штрихкоде', 'Shtrix-kodda')} extra={tr('рекомендуем «Вес»', '«Vazn»ni tavsiya qilamiz')}>
                  <Radio.Group optionType="button" options={[{ value: 'weight', label: tr('Вес', 'Vazn') }, { value: 'sum', label: tr('Сумма', 'Summa') }]} />
                </Form.Item>
              </Col>
              {value === 'weight' && (
                <Col xs={12} md={6}>
                  <Form.Item name="weight_step" label={tr('Вес указан в', 'Vazn birligi')} extra={step === 10 ? tr('01234 = 12,34 кг', '01234 = 12,34 kg') : tr('01234 = 1,234 кг', '01234 = 1,234 kg')}>
                    <Radio.Group optionType="button" options={[{ value: 1, label: tr('граммах', 'grammda') }, { value: 10, label: tr('10 г', '10 g') }]} />
                  </Form.Item>
                </Col>
              )}
            </Row>
            <Alert
              type="info"
              showIcon
              message={tr(
                'В меню весов выберите штрихкод «с весом». Тогда цену всегда берёт Super Market: если в весах цена старая, в чек всё равно попадёт правильная.',
                'Tarozi menyusida «vazn bilan» shtrix-kodni tanlang. Shunda narxni doim Super Market oladi: tarozida narx eski boʻlsa ham, chekka toʻgʻrisi tushadi.',
              )}
            />
          </Card>
        )}
        {!readOnly && (
          <Button type="primary" htmlType="submit" loading={save.isPending}>
            {tr('Сохранить', 'Saqlash')}
          </Button>
        )}
      </Form>
    </>
  )
}
