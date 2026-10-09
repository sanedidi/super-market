// «Начало работы» (Figma «Панель магазина · начало работы v2», V1–V4).
// Черновик общий с «SM Магазин» и идёт в два шага:
//  1. «Мои товары» — поиск по центральной базе (название, штрихкод, USB-сканер),
//     фото полок, свой товар. Тот же товар второй раз не добавляется, на
//     похожий — предупреждение (один раз на пару).
//  2. «Инвентаризация: Начало работы» — количество и цена продажи (обязательны,
//     можно 0), себестоимость — по желанию. «Записать и закрыть» проводит
//     черновик, после этого «Начало работы» больше не показывается.
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Card, Col, Flex, Input, InputNumber, Modal, Result, Row, Segmented, Space, Table, Tooltip, Typography, type InputRef } from 'antd'
import {
  ArrowRightOutlined,
  CameraOutlined,
  CheckCircleOutlined,
  CheckOutlined,
  DeleteOutlined,
  ExclamationCircleFilled,
  PlusOutlined,
  RightOutlined,
  SaveOutlined,
  ScanOutlined,
  SearchOutlined,
} from '@ant-design/icons'
import { ApiError, LoadError, PageTitle, api, errorText, money, plural, qty as fmtQty, tr, useDebounced, useList } from '@sm/shared'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { docPaths } from '../StockDocs'
import { plainNum, useStartApi, useStartRefresh, type Draft, type Line, type LineInput, type LinesResult, type PostResult, type SearchItem, type Similar } from './api'
import { BarcodeModal, NewProductModal, PhotoModal, SimilarModal, sum } from './Modals'
import { TasnifBlock, TasnifLink } from './Tasnif'
import { NewByPhotoModal, NewItemsList, RightTabs, useNewItems } from './NewItems'
import { Thumb } from './Thumb'

const PAGE = 50
const RED = '#E11D2A'
const goods = (n: number) => tr(`${n} ${plural(n, 'товар', 'товара', 'товаров')}`, `${n} ta mahsulot`)
const rows = (n: number) => tr(`${n} ${plural(n, 'строку', 'строки', 'строк')}`, `${n} ta qator`)

export function StartPage() {
  return (
    <NeedStore>
      <Start />
    </NeedStore>
  )
}

function Start() {
  const { storeId } = useStore()
  const [params, setParams] = useSearchParams()
  const step = params.get('step') === '2' ? 2 : 1
  const setStep = (s: 1 | 2) => setParams(s === 2 ? { step: '2' } : {})
  const [result, setResult] = useState<PostResult | null>(null)

  // Шапка черновика: закрыт ли, итоги, склад.
  const head = useQuery({
    queryKey: ['/store/start', { store_id: storeId, limit: 1 }],
    queryFn: () => api.get<Draft>('/store/start', { store_id: storeId, limit: 1 }),
    placeholderData: keepPreviousData,
  })
  const d = head.data

  if (result) return <Posted r={result} />
  if (head.error) return <LoadError error={head.error} retry={() => head.refetch()} />
  if (!d) return null
  if (d.closed && !d.id) return <Closed d={d} />
  if (d.status === 'posting')
    return <Alert type="info" showIcon message={tr('«Начало работы» записывается — подождите несколько секунд', '«Ishni boshlash» yozilmoqda — bir necha soniya kuting')} />
  return (
    <>
      <style>{rowStyles}</style>
      {step === 1 ? <StepGoods d={d} next={() => setStep(2)} /> : <StepCount d={d} back={() => setStep(1)} onPosted={setResult} />}
    </>
  )
}

// Подсветка строк: повтор (V2) и незаполненная строка (V4).
const rowStyles = `
.sm-start-dup > td { background: #FEF3F2 !important; }
.sm-start-dup > td:first-child { box-shadow: inset 3px 0 0 ${RED}; }
.sm-start-unfilled > td { background: #FFFBFA !important; }
`

/** Шаги «1 · Выбор товаров › 2 · Инвентаризация». */
function Steps({ step, go }: { step: 1 | 2; go?: (s: 1 | 2) => void }) {
  const items = [tr('Выбор товаров', 'Mahsulotlarni tanlash'), tr('Инвентаризация: Начало работы', 'Inventarizatsiya: Ishni boshlash')]
  return (
    <Flex align="center" gap={8} wrap style={{ marginBottom: 16 }}>
      {items.map((label, i) => {
        const n = (i + 1) as 1 | 2
        const on = n === step
        const done = n < step
        return (
          <Flex key={n} align="center" gap={8}>
            {i > 0 && <RightOutlined style={{ fontSize: 11, color: '#98A2B3' }} />}
            <Flex
              align="center"
              gap={8}
              onClick={done && go ? () => go(n) : undefined}
              style={{
                padding: '4px 12px 4px 4px',
                borderRadius: 20,
                background: on ? '#1F2937' : '#fff',
                border: on ? '1px solid #1F2937' : '1px solid #D0D5DD',
                cursor: done && go ? 'pointer' : undefined,
              }}
            >
              <span
                style={{
                  width: 22,
                  height: 22,
                  borderRadius: 11,
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 12,
                  fontWeight: 800,
                  background: on ? '#fff' : done ? '#ECFDF3' : '#F2F4F7',
                  color: on ? '#1F2937' : done ? '#027A48' : '#667085',
                }}
              >
                {done ? <CheckOutlined /> : n}
              </span>
              <Typography.Text strong style={{ fontSize: 13, color: on ? '#fff' : done ? '#027A48' : '#667085' }}>
                {label}
              </Typography.Text>
            </Flex>
          </Flex>
        )
      })}
    </Flex>
  )
}

// ================================================================ шаг 1

function StepGoods({ d, next }: { d: Draft; next: () => void }) {
  const { can, storeId } = useStore()
  const [photoOpen, setPhotoOpen] = useState(false)
  const [newOpen, setNewOpen] = useState(false)
  // «Новый товар»: сначала фото для Super Market, ручная форма — по ссылке.
  const [byPhoto, setByPhoto] = useState(false)
  const [tab, setTab] = useState<'mine' | 'new'>('mine')
  const fresh = useNewItems(storeId)
  const freshCount = fresh.data?.items.length ?? 0
  const tabs = <RightTabs tab={tab} onTab={setTab} mine={d.totals.products} fresh={freshCount} ready={(fresh.data?.counts.ready ?? 0) > 0} />
  // Повтор: подсвеченная строка «Моих товаров».
  const [highlight, setHighlight] = useState<string | null>(null)
  const n = d.totals.products

  return (
    <>
      <PageTitle
        title={tr('Начало работы', 'Ishni boshlash')}
        extra={
          <Space wrap>
            <Button icon={<CameraOutlined />} onClick={() => setPhotoOpen(true)}>
              {tr('Фото полок', 'Javon rasmlari')}
            </Button>
            {can('catalog.manage') && (
              <Button icon={<PlusOutlined />} onClick={() => setByPhoto(true)}>
                {tr('Новый товар', 'Yangi mahsulot')}
              </Button>
            )}
            <Button type="primary" disabled={n === 0} onClick={next}>
              {tr('Дальше: инвентаризация', 'Keyingi: inventarizatsiya')} <ArrowRightOutlined />
            </Button>
          </Space>
        }
      />
      <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
        {tr(
          `Шаг 1 из 2 — найдите в центральной базе товары, которые есть в магазине «${d.store_name}». Количество и цены — на шаге 2. Список общий с приложением «SM Магазин».`,
          `1-qadam (2 tadan) — «${d.store_name}» doʻkonida bor mahsulotlarni markaziy bazadan toping. Miqdor va narxlar — 2-qadamda. Roʻyxat «SM Магазин» ilovasi bilan umumiy.`,
        )}
      </Typography.Paragraph>
      <Steps step={1} />
      <Row gutter={[16, 16]}>
        <Col xs={24} xl={10}>
          <SearchCard onDuplicate={setHighlight} onNew={() => setByPhoto(true)} />
        </Col>
        <Col xs={24} xl={14}>
          {tab === 'new' ? (
            <Card title={tabs} styles={{ body: { padding: 0 } }}>
              <NewItemsList list={fresh.data} loading={fresh.isLoading} />
            </Card>
          ) : (
            <MyGoods highlight={highlight} title={tabs} />
          )}
        </Col>
      </Row>
      <PhotoModal open={photoOpen} onClose={() => setPhotoOpen(false)} />
      <NewProductModal open={newOpen} onClose={() => setNewOpen(false)} />
      <NewByPhotoModal
        open={byPhoto}
        onClose={() => setByPhoto(false)}
        onSent={() => setTab('new')}
        onManual={() => {
          setByPhoto(false)
          setNewOpen(true)
        }}
      />
    </>
  )
}

const isBarcode = (s: string) => /^\d{6,14}$/.test(s)

type Duplicate = { name: string; inStore: boolean }

/**
 * Поиск по центральной базе (V1). USB-сканер «печатает» штрихкод и Enter —
 * найденный товар сразу добавляется. Тот же товар — ошибка и подсветка
 * строки в «Моих товарах» (V2); похожий — окно с выбором (V3).
 * В базе ничего нет — сразу варианты из каталога ИКПУ (Т1–Т3); нашлось, но
 * не то — ссылка «Поискать в каталоге ИКПУ» (Т5).
 */
function SearchCard({ onDuplicate, onNew }: { onDuplicate: (id: string | null) => void; onNew: () => void }) {
  const { storeId, can } = useStore()
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [text, setText] = useState('')
  const [dup, setDup] = useState<Duplicate | null>(null)
  const [similar, setSimilar] = useState<{ item: SearchItem; similar: Similar } | null>(null)
  const [missing, setMissing] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const ref = useRef<InputRef>(null)
  const q = useDebounced(text.trim(), 250)
  const found = useList<SearchItem>(q.length >= 2 ? '/store/start/search' : null, { store_id: storeId, q, limit: 30 })
  const items = found.data ?? []
  // Каталог ИКПУ: сам — когда в базе пусто, по ссылке — когда нашлось не то.
  const [tasnifAsked, setTasnifAsked] = useState(false)
  useEffect(() => setTasnifAsked(false), [q])
  const searched = q.length >= 2 && !!found.data
  // Варианты остаются на экране, даже когда добавленный товар появился в базе.
  useEffect(() => {
    if (searched && items.length === 0) setTasnifAsked(true)
  }, [searched, items.length])
  const tasnif = searched && (items.length === 0 || tasnifAsked)

  const add = async (it: SearchItem, source: LineInput['source'], confirm = false) => {
    setBusy(it.product_id)
    try {
      await api.post<LinesResult>('/store/start/lines', {
        store_id: storeId,
        items: [{ product_id: it.product_id, add: true, source, confirm_similar: confirm || undefined }],
      })
      setDup(null)
      onDuplicate(null)
      message.success(tr(`${it.name} — в «Моих товарах»`, `${it.name} — «Mahsulotlarim»da`))
    } catch (e) {
      if (e instanceof ApiError && e.code === 'already_added') {
        setDup({ name: it.name, inStore: e.details.in_store === true })
        onDuplicate(it.product_id)
      } else if (e instanceof ApiError && e.code === 'similar_exists' && e.details.similar) {
        setSimilar({ item: it, similar: e.details.similar as Similar })
      } else {
        message.error(errorText(e))
      }
    } finally {
      setBusy(null)
      await refresh()
    }
  }

  // Скан: штрихкод и Enter — добавить сразу, если товар один.
  const scan = async (code: string) => {
    try {
      const r = await api.get<{ items: SearchItem[] }>('/store/start/search', { store_id: storeId, q: code, limit: 2 })
      const exact = (r.items ?? []).filter((x) => x.barcode === code)
      // Нет в базе — ниже появятся варианты из каталога ИКПУ (или «привязать / создать»).
      if (exact.length === 1) await add(exact[0], 'barcode')
    } catch (e) {
      message.error(errorText(e))
    }
  }

  return (
    <Card styles={{ body: { padding: 0 } }}>
      <div style={{ padding: '14px 16px' }}>
        <Flex justify="space-between" align="baseline" style={{ marginBottom: 10 }}>
          <Typography.Text strong style={{ fontSize: 15 }}>
            {tr('Поиск по центральной базе', 'Markaziy bazadan qidirish')}
          </Typography.Text>
        </Flex>
        <Input
          ref={ref}
          autoFocus
          size="large"
          allowClear
          value={text}
          prefix={<SearchOutlined style={{ color: '#667085' }} />}
          suffix={<ScanOutlined style={{ color: '#667085' }} />}
          placeholder={tr('Название или штрихкод', 'Nomi yoki shtrix-kod')}
          onChange={(e) => {
            setText(e.target.value)
            setDup(null)
          }}
          onKeyDown={(e) => {
            const v = text.trim()
            if (e.key === 'Enter' && isBarcode(v)) {
              e.preventDefault()
              scan(v)
            }
          }}
        />
        <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 6 }}>
          {tr('По названию (uz / ru) или штрихкоду. USB-сканер работает в этом поле.', 'Nomi (uz / ru) yoki shtrix-kod boʻyicha. USB-skaner shu maydonda ishlaydi.')}
        </Typography.Text>
        {dup && (
          <Alert
            style={{ marginTop: 10 }}
            type="error"
            showIcon
            message={tr('Товар уже добавлен', 'Mahsulot allaqachon qoʻshilgan')}
            description={
              dup.inStore
                ? tr(`${dup.name} — уже есть в товарах магазина.`, `${dup.name} — doʻkon mahsulotlarida allaqachon bor.`)
                : tr(`${dup.name} — уже в «Моих товарах». Строка подсвечена в списке.`, `${dup.name} — allaqachon «Mahsulotlarim»da. Qator roʻyxatda belgilangan.`)
            }
          />
        )}
      </div>
      {q.length >= 2 && (
        <>
          <div style={{ background: '#FCFCFD', padding: '8px 16px', borderTop: '1px solid #EAECF0', borderBottom: '1px solid #EAECF0' }}>
            <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
              {found.isFetching && !found.data
                ? tr('Ищем…', 'Qidirilmoqda…')
                : items.length >= 30
                  ? tr(`Найдено больше 30 · уточните запрос`, `30 tadan koʻp topildi · soʻrovni aniqlashtiring`)
                  : items.length === 0
                    ? isBarcode(q)
                      ? tr(`Штрихкода ${q} нет в центральной базе`, `${q} shtrix-kodi markaziy bazada yoʻq`)
                      : tr(`В центральной базе не найдено · по запросу «${q}»`, `Markaziy bazada topilmadi · «${q}» soʻrovi boʻyicha`)
                    : tr(`Найдено ${items.length} · по запросу «${q}»`, `Topildi: ${items.length} · «${q}» soʻrovi boʻyicha`)}
            </Typography.Text>
          </div>
          <div style={{ maxHeight: 560, overflowY: 'auto' }}>
            {items.map((it) => (
              <Flex key={it.product_id} align="center" gap={12} style={{ padding: '10px 16px', borderBottom: '1px solid #EAECF0' }}>
                <Thumb src={it.image} size={40} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <Typography.Text strong style={{ fontWeight: 600, display: 'block' }}>
                    {it.name}
                  </Typography.Text>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {[it.barcode, it.own ? tr('свой товар', 'oʻz mahsulot') : null].filter(Boolean).join(' · ') || it.unit_short}
                  </Typography.Text>
                </div>
                {it.added ? (
                  <span style={{ flex: 'none', background: '#ECFDF3', color: '#027A48', borderRadius: 8, padding: '4px 10px', fontWeight: 700, fontSize: 13 }}>
                    <CheckOutlined /> {it.in_store ? tr('Уже в магазине', 'Doʻkonda bor') : tr('Добавлен', 'Qoʻshilgan')}
                  </span>
                ) : (
                  <Button size="small" icon={<PlusOutlined />} loading={busy === it.product_id} onClick={() => add(it, isBarcode(q) ? 'barcode' : 'search')} style={{ flex: 'none' }}>
                    {tr('Добавить', 'Qoʻshish')}
                  </Button>
                )}
              </Flex>
            ))}
            {searched && items.length > 0 && !tasnifAsked && <TasnifLink q={q} onClick={() => setTasnifAsked(true)} />}
            {tasnif && <TasnifBlock q={q} onMissingBarcode={(code) => setMissing(code)} onNew={onNew} />}
          </div>
        </>
      )}
      {can('catalog.manage') && !tasnif && (
        <Flex align="center" gap={6} style={{ padding: '12px 16px 14px' }}>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            {tr('Нет в базе?', 'Bazada yoʻqmi?')}
          </Typography.Text>
          <Button type="link" danger size="small" icon={<PlusOutlined />} style={{ padding: 0, fontWeight: 700 }} onClick={onNew}>
            {tr('Создать свой товар', 'Oʻz mahsulotingizni yaratish')}
          </Button>
        </Flex>
      )}
      <SimilarModal
        data={similar}
        onCancel={() => setSimilar(null)}
        onConfirm={async () => {
          const s = similar
          setSimilar(null)
          if (s) await add(s.item, isBarcode(q) ? 'barcode' : 'search', true)
        }}
      />
      <BarcodeModal
        code={missing}
        onClose={() => {
          setMissing(null)
          setTimeout(() => ref.current?.focus(), 0)
        }}
      />
    </Card>
  )
}

function sourceText(l: Line) {
  if (!l.own) return { text: tr('центральная база', 'markaziy baza') }
  if (l.moderation === 'approved') return { text: tr('свой товар', 'oʻz mahsulotingiz') }
  if (l.moderation === 'rejected') return { text: tr('новый · отклонён', 'yangi · rad etilgan'), color: '#D92D20' }
  if (l.moderation === 'draft') return { text: tr('новый · на проверку после инвентаризации', 'yangi · inventarizatsiyadan soʻng tekshiruvga'), color: '#B54708' }
  return { text: tr('новый · на модерации', 'yangi · moderatsiyada'), color: '#C4320A' }
}

/** Название товара целиком (без обрезки) и подпись под ним. */
function NameCell({ l, note }: { l: Line; note?: { text: string; color?: string } }) {
  const s = note ?? sourceText(l)
  return (
    <Flex align="center" gap={10} style={{ minWidth: 200 }}>
      <Thumb src={l.image} size={36} />
      <div style={{ minWidth: 0 }}>
        <Typography.Text strong style={{ fontWeight: 600, display: 'block', whiteSpace: 'normal' }}>
          {l.name}
        </Typography.Text>
        <Typography.Text style={{ fontSize: 12, color: s.color }} type={s.color ? undefined : 'secondary'}>
          {s.text}
          {!note && ` · ${l.unit_short}`}
        </Typography.Text>
      </div>
    </Flex>
  )
}

/** «Мои товары» шага 1: фото, полное название, штрихкод, убрать. */
function MyGoods({ highlight, title }: { highlight: string | null; title?: ReactNode }) {
  const { storeId, can } = useStore()
  const { deleteLine } = useStartApi(storeId)
  const [page, setPage] = useState(1)
  const [bind, setBind] = useState<Line | null>(null)
  useEffect(() => setPage(1), [storeId])
  const params = { store_id: storeId, limit: PAGE + 1, offset: (page - 1) * PAGE }
  const draft = useQuery({ queryKey: ['/store/start', params], queryFn: () => api.get<Draft>('/store/start', params), placeholderData: keepPreviousData })
  const raw = draft.data?.lines ?? []
  const hasMore = raw.length > PAGE
  const lines = hasMore ? raw.slice(0, PAGE) : raw
  const total = draft.data?.totals.products ?? 0

  return (
    <Card
      title={title ?? `${tr('Мои товары', 'Mahsulotlarim')} · ${total}`}
      extra={
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {tr('последние добавленные сверху', 'oxirgi qoʻshilganlar yuqorida')}
        </Typography.Text>
      }
      styles={{ body: { padding: 0 } }}
    >
      <LoadError error={draft.error} retry={() => draft.refetch()} />
      <Table<Line>
        rowKey="product_id"
        size="middle"
        loading={draft.isLoading}
        dataSource={lines}
        rowClassName={(l) => (l.product_id === highlight ? 'sm-start-dup' : '')}
        pagination={
          page > 1 || hasMore
            ? { current: page, pageSize: PAGE, total: (page - 1) * PAGE + lines.length + (hasMore ? 1 : 0), onChange: setPage, showSizeChanger: false }
            : false
        }
        locale={{
          emptyText: tr('Пока пусто — найдите товары слева, отсканируйте штрихкод или загрузите фото полок', 'Hozircha boʻsh — mahsulotlarni chapda toping, shtrix-kodni skanerlang yoki javon rasmlarini yuklang'),
        }}
        columns={[
          {
            title: tr('Товар', 'Mahsulot'),
            key: 'name',
            render: (_, l) => (
              <NameCell
                l={l}
                note={l.product_id === highlight ? { text: tr('уже добавлен — повтор не добавлен', 'allaqachon qoʻshilgan — takror qoʻshilmadi'), color: RED } : undefined}
              />
            ),
          },
          {
            title: tr('Штрихкод', 'Shtrix-kod'),
            key: 'barcode',
            width: 150,
            render: (_, l) =>
              l.barcode ? (
                <Typography.Text type="secondary" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
                  {l.barcode}
                </Typography.Text>
              ) : can('catalog.manage') ? (
                <Button type="link" danger size="small" icon={<ScanOutlined />} style={{ padding: 0 }} onClick={() => setBind(l)}>
                  {tr('Привязать', 'Bogʻlash')}
                </Button>
              ) : (
                '—'
              ),
          },
          {
            key: 'del',
            width: 44,
            render: (_, l) => (
              <Tooltip title={tr('Убрать из списка', 'Roʻyxatdan olib tashlash')}>
                <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => deleteLine(l.product_id).catch(() => {})} />
              </Tooltip>
            ),
          },
        ]}
        footer={
          lines.length
            ? () => (
                <Flex justify="space-between" wrap gap={8}>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {tr(`Показано ${(page - 1) * PAGE + 1}–${(page - 1) * PAGE + lines.length} из ${total}`, `Koʻrsatilgan: ${(page - 1) * PAGE + 1}–${(page - 1) * PAGE + lines.length} / ${total}`)}
                  </Typography.Text>
                  <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
                    {tr('Количество, себестоимость и цены — на шаге 2', 'Miqdor, tannarx va narxlar — 2-qadamda')}
                  </Typography.Text>
                </Flex>
              )
            : undefined
        }
      />
      <BindModal line={bind} onClose={() => setBind(null)} />
    </Card>
  )
}

/** Привязать штрихкод к товару списка (сканером или вручную). */
function BindModal({ line, onClose }: { line: Line | null; onClose: () => void }) {
  const { storeId } = useStore()
  const { setLines } = useStartApi(storeId)
  const [code, setCode] = useState('')
  const [saving, setSaving] = useState(false)
  useEffect(() => setCode(''), [line])
  const ok = async () => {
    if (!line || !code.trim()) return
    setSaving(true)
    try {
      await setLines([{ product_id: line.product_id, barcode: code.trim() }])
      onClose()
    } catch {
      // ошибка уже показана
    } finally {
      setSaving(false)
    }
  }
  return (
    <Modal open={!!line} title={tr('Привязать штрихкод', 'Shtrix-kodni bogʻlash')} okText={tr('Привязать', 'Bogʻlash')} onOk={ok} confirmLoading={saving} okButtonProps={{ disabled: !code.trim() }} onCancel={onClose} destroyOnHidden>
      <Typography.Paragraph type="secondary">{line?.name}</Typography.Paragraph>
      <Input autoFocus value={code} onChange={(e) => setCode(e.target.value)} onPressEnter={ok} placeholder={tr('Отсканируйте или введите штрихкод', 'Shtrix-kodni skanerlang yoki kiriting')} prefix={<ScanOutlined />} />
    </Modal>
  )
}

// ================================================================ шаг 2

/** Число в ячейке: сохраняется по Enter или уходу из поля; пустое — null. */
function NumCell({
  value,
  required,
  placeholder,
  title,
  onSave,
}: {
  value: string | null
  required?: boolean
  placeholder: string
  title?: string
  onSave: (v: string | null) => Promise<unknown>
}) {
  const [v, setV] = useState<string | null>(plainNum(value) || null)
  useEffect(() => setV(plainNum(value) || null), [value])
  const empty = v === null || v === ''
  const err = required && empty
  const commit = () => {
    const next = empty ? null : v
    if ((next === null ? null : Number(next)) !== (value === null ? null : Number(value))) onSave(next).catch(() => setV(plainNum(value) || null))
  }
  return (
    <Tooltip title={title}>
      <InputNumber<string>
        stringMode
        min="0"
        value={v ?? undefined}
        placeholder={placeholder}
        status={err ? 'error' : undefined}
        style={{ width: '100%', background: err ? '#FEF3F2' : undefined }}
        formatter={(x) => {
          if (!x) return ''
          const [a, b] = String(x).split('.')
          return a.replace(/\B(?=(\d{3})+(?!\d))/g, ' ') + (b !== undefined ? '.' + b : '')
        }}
        parser={(x) => (x ?? '').replace(/\s/g, '').replace(',', '.')}
        onChange={(x) => setV(x)}
        onBlur={commit}
        onPressEnter={(e) => {
          commit()
          ;(e.target as HTMLInputElement).blur()
        }}
      />
    </Tooltip>
  )
}

type Only = '' | 'unfilled' | 'no_cost'

/** V4: документ «Инвентаризация: Начало работы». */
function StepCount({ d, back, onPosted }: { d: Draft; back: () => void; onPosted: (r: PostResult) => void }) {
  const { storeId } = useStore()
  const { modal, message } = App.useApp()
  const { setLines, deleteLine, refresh } = useStartApi(storeId)
  const [only, setOnly] = useState<Only>('')
  const [page, setPage] = useState(1)
  useEffect(() => setPage(1), [only, storeId])
  const params = { store_id: storeId, only: only || undefined, limit: PAGE + 1, offset: (page - 1) * PAGE }
  const draft = useQuery({ queryKey: ['/store/start', params], queryFn: () => api.get<Draft>('/store/start', params), placeholderData: keepPreviousData })
  const t = draft.data?.totals ?? d.totals
  const raw = draft.data?.lines ?? []
  const hasMore = raw.length > PAGE
  const lines = hasMore ? raw.slice(0, PAGE) : raw
  const save = (l: Line, patch: Omit<LineInput, 'product_id'>) => setLines([{ ...patch, product_id: l.product_id }])
  const filled = t.products - t.unfilled

  // «Сохранить»: значения сохраняются при уходе из поля — дождаться и сказать об этом.
  const saveAll = async () => {
    ;(document.activeElement as HTMLElement | null)?.blur()
    await new Promise((r) => setTimeout(r, 300))
    await refresh()
    message.success(tr('Черновик сохранён — можно вернуться к нему позже', 'Qoralama saqlandi — keyinroq unga qaytish mumkin'))
  }

  const post = () => {
    ;(document.activeElement as HTMLElement | null)?.blur()
    if (t.unfilled > 0) {
      setOnly('unfilled')
      message.error(tr(`Заполните ${rows(t.unfilled)}: количество и цена продажи обязательны`, `${rows(t.unfilled)}ni toʻldiring: miqdor va sotish narxi majburiy`))
      return
    }
    modal.confirm({
      title: tr('Записать и закрыть «Начало работы»?', '«Ishni boshlash» yozilib, yopilsinmi?'),
      width: 540,
      okText: tr('Записать и закрыть', 'Yozish va yopish'),
      cancelText: tr('Отмена', 'Bekor qilish'),
      content: (
        <div>
          <Typography.Paragraph>
            {tr(
              `Остатки встанут на склад «${d.warehouse_name}», цены продажи — в магазин «${d.store_name}». После этого документ больше не появится: новые товары добавляйте приходом, инвентаризацией или установкой цен.`,
              `Qoldiqlar «${d.warehouse_name}» omboriga, sotish narxlari «${d.store_name}» doʻkoniga tushadi. Shundan soʻng hujjat boshqa chiqmaydi: yangi mahsulotlarni kirim, inventarizatsiya yoki narx belgilash orqali qoʻshing.`,
            )}
          </Typography.Paragraph>
          <Typography.Paragraph style={{ marginBottom: 0 }}>
            {tr(
              `${goods(t.products)} · ${fmtQty(t.qty)} шт · по себестоимости ${sum(t.cost_total)} · по цене продажи ${sum(t.price_total)}`,
              `${goods(t.products)} · ${fmtQty(t.qty)} dona · tannarxda ${sum(t.cost_total)} · sotish narxida ${sum(t.price_total)}`,
            )}
          </Typography.Paragraph>
          {t.no_cost > 0 && (
            <Alert
              style={{ marginTop: 12 }}
              type="warning"
              showIcon
              message={tr(`Без себестоимости: ${goods(t.no_cost)}`, `Tannarxsiz: ${goods(t.no_cost)}`)}
              description={tr('Их себестоимость будет 0 — прибыль по ним в отчётах будет завышена.', 'Ularning tannarxi 0 boʻladi — hisobotlarda ular boʻyicha foyda oshirib koʻrsatiladi.')}
            />
          )}
        </div>
      ),
      onOk: async () => {
        try {
          const r = await api.post<PostResult>('/store/start/post', { store_id: storeId })
          onPosted(r)
          await refresh()
        } catch (e) {
          message.error(errorText(e))
          if (e instanceof ApiError && e.code === 'lines_unfilled') setOnly('unfilled')
          await refresh()
          throw e
        }
      },
    })
  }

  return (
    <>
      <PageTitle
        title={tr('Инвентаризация: Начало работы', 'Inventarizatsiya: Ishni boshlash')}
        extra={
          <Space wrap>
            <Button icon={<PlusOutlined />} onClick={back}>
              {tr('Добавить товар', 'Mahsulot qoʻshish')}
            </Button>
            <Button icon={<SaveOutlined />} onClick={saveAll}>
              {tr('Сохранить', 'Saqlash')}
            </Button>
            <Button type="primary" icon={<CheckCircleOutlined />} disabled={t.products === 0} onClick={post}>
              {tr('Записать и закрыть', 'Yozish va yopish')}
            </Button>
          </Space>
        }
      />
      <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
        {tr(
          `Шаг 2 из 2 · склад «${d.warehouse_name}». Документ виден, пока вы не нажмёте «Записать и закрыть».`,
          `2-qadam (2 tadan) · «${d.warehouse_name}» ombori. Hujjat «Yozish va yopish» tugmasini bosmaguningizcha koʻrinadi.`,
        )}
      </Typography.Paragraph>
      <Steps step={2} go={back} />
      <Row gutter={[12, 12]} style={{ marginBottom: 16 }}>
        <Stat title={tr('Товаров', 'Mahsulotlar')} value={String(t.products)} />
        <Stat title={tr('Заполнено', 'Toʻldirilgan')} value={tr(`${filled} из ${t.products}`, `${filled} / ${t.products}`)} warn={t.unfilled > 0} />
        <Stat title={tr('По себестоимости', 'Tannarxda')} value={sum(t.cost_total)} />
        <Stat title={tr('По цене продажи', 'Sotish narxida')} value={sum(t.price_total)} />
      </Row>
      {t.unfilled > 0 && (
        <Card style={{ borderColor: RED, borderWidth: 1.5, marginBottom: 16 }} styles={{ body: { padding: '12px 14px' } }}>
          <Flex gap={10} align="start">
            <ExclamationCircleFilled style={{ color: RED, fontSize: 20, marginTop: 2 }} />
            <div>
              <Typography.Text strong>{tr(`Заполните ${rows(t.unfilled)}, чтобы записать и закрыть`, `Yozib, yopish uchun ${rows(t.unfilled)}ni toʻldiring`)}</Typography.Text>
              <div>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {tr(
                    'Количество и цена продажи обязательны в каждой строке — можно 0. Себестоимость — по желанию: без неё прибыль по товару будет считаться неточно.',
                    'Har bir qatorda miqdor va sotish narxi majburiy — 0 boʻlishi mumkin. Tannarx — ixtiyoriy: usiz mahsulot boʻyicha foyda notoʻgʻri hisoblanadi.',
                  )}
                </Typography.Text>
              </div>
            </div>
          </Flex>
        </Card>
      )}
      <Card
        title={`${tr('Товары', 'Mahsulotlar')} · ${t.products}`}
        extra={
          <Segmented<Only>
            size="small"
            value={only}
            onChange={setOnly}
            options={[
              { value: '', label: `${tr('Все', 'Hammasi')} · ${t.products}` },
              { value: 'unfilled', label: `${tr('Не заполнено', 'Toʻldirilmagan')} · ${t.unfilled}` },
              { value: 'no_cost', label: `${tr('Без себестоимости', 'Tannarxsiz')} · ${t.no_cost}` },
            ]}
          />
        }
        styles={{ body: { padding: 0 } }}
      >
        <LoadError error={draft.error} retry={() => draft.refetch()} />
        <Table<Line>
          rowKey="product_id"
          size="middle"
          loading={draft.isLoading}
          dataSource={lines}
          scroll={{ x: 900 }}
          rowClassName={(l) => (l.qty === null || l.price === null ? 'sm-start-unfilled' : '')}
          pagination={
            page > 1 || hasMore
              ? { current: page, pageSize: PAGE, total: (page - 1) * PAGE + lines.length + (hasMore ? 1 : 0), onChange: setPage, showSizeChanger: false }
              : false
          }
          locale={{ emptyText: only ? tr('Таких товаров нет', 'Bunday mahsulotlar yoʻq') : tr('Нет товаров — добавьте их на шаге 1', 'Mahsulotlar yoʻq — ularni 1-qadamda qoʻshing') }}
          columns={[
            { title: tr('Товар', 'Mahsulot'), key: 'name', render: (_, l) => <NameCell l={l} /> },
            {
              title: tr('Штрихкод', 'Shtrix-kod'),
              key: 'barcode',
              width: 140,
              render: (_, l) => (
                <Typography.Text type="secondary" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
                  {l.barcode ?? '—'}
                </Typography.Text>
              ),
            },
            {
              title: `${tr('Кол-во', 'Miqdor')} *`,
              key: 'qty',
              width: 130,
              render: (_, l) => <NumCell value={l.qty} required placeholder={tr('обязательно', 'majburiy')} onSave={(v) => save(l, { qty: v })} />,
            },
            {
              title: tr('Себестоимость', 'Tannarx'),
              key: 'cost',
              width: 140,
              render: (_, l) => <NumCell value={l.cost} placeholder={tr('необязательно', 'ixtiyoriy')} onSave={(v) => save(l, { cost: v })} />,
            },
            {
              title: `${tr('Цена продажи', 'Sotish narxi')} *`,
              key: 'price',
              width: 140,
              render: (_, l) => (
                <NumCell
                  value={l.price}
                  required
                  placeholder={tr('обязательно', 'majburiy')}
                  title={Number(l.current_price) > 0 ? tr(`В базе: ${money(l.current_price)}`, `Bazada: ${money(l.current_price)}`) : undefined}
                  onSave={(v) => save(l, { price: v })}
                />
              ),
            },
            {
              key: 'del',
              width: 44,
              render: (_, l) => (
                <Tooltip title={tr('Убрать из списка', 'Roʻyxatdan olib tashlash')}>
                  <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => deleteLine(l.product_id).catch(() => {})} />
                </Tooltip>
              ),
            },
          ]}
          footer={
            lines.length
              ? () => (
                  <Flex justify="space-between" wrap gap={8}>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {tr(`Показано ${(page - 1) * PAGE + 1}–${(page - 1) * PAGE + lines.length}`, `Koʻrsatilgan: ${(page - 1) * PAGE + 1}–${(page - 1) * PAGE + lines.length}`)}
                    </Typography.Text>
                    <Typography.Text strong>
                      {tr(`Итого: себестоимость ${sum(t.cost_total)} · продажа ${sum(t.price_total)}`, `Jami: tannarx ${sum(t.cost_total)} · sotish ${sum(t.price_total)}`)}
                    </Typography.Text>
                  </Flex>
                )
              : undefined
          }
        />
      </Card>
    </>
  )
}

function Stat({ title, value, warn }: { title: string; value: string; warn?: boolean }) {
  return (
    <Col xs={12} lg={6}>
      <Card styles={{ body: { padding: '12px 16px' } }}>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {title}
        </Typography.Text>
        <div style={{ fontSize: 18, fontWeight: 800, color: warn ? '#B42318' : undefined }}>{value}</div>
      </Card>
    </Col>
  )
}

// ========================================================= записано / закрыто

function Posted({ r }: { r: PostResult }) {
  const nav = useNavigate()
  return (
    <Card>
      <Result
        status="success"
        title={tr('Магазин готов к работе', 'Doʻkon ishga tayyor')}
        subTitle={tr(
          `${goods(r.products)} · ${fmtQty(r.qty)} шт на складе · по себестоимости ${sum(r.cost_total)}`,
          `${goods(r.products)} · omborda ${fmtQty(r.qty)} dona · tannarxda ${sum(r.cost_total)}`,
        )}
        extra={
          <Space wrap>
            <Button type="primary" onClick={() => nav('/')}>
              {tr('На главную', 'Bosh sahifaga')}
            </Button>
            <Button onClick={() => nav('/dirs/products')}>{tr('Мои товары', 'Mahsulotlarim')}</Button>
          </Space>
        }
      >
        <Space direction="vertical" size={6}>
          {r.documents.map((doc) => (
            <Link key={doc.id} to={`${docPaths.posting}/${doc.id}`}>
              {tr('Оприходование', 'Kirim qilish')} №{doc.number}
            </Link>
          ))}
          {r.price_document && (
            <Link to={`/sales/prices/${r.price_document.id}`}>
              {tr('Установка цен', 'Narxlarni belgilash')} №{r.price_document.number}
            </Link>
          )}
          <Typography.Text>
            {tr(`Покупатели видят ${goods(r.visible)}`, `Xaridorlar ${goods(r.visible)}ni koʻradi`)}
            {r.pending > 0 && tr(` · ещё ${r.pending} — после проверки новых товаров`, ` · yana ${r.pending} ta — yangi mahsulotlar tekshirilgandan keyin`)}
          </Typography.Text>
        </Space>
      </Result>
    </Card>
  )
}

function Closed({ d }: { d: Draft }) {
  const nav = useNavigate()
  return (
    <Card>
      <Result
        status="success"
        title={tr('«Начало работы» завершено', '«Ishni boshlash» yakunlangan')}
        subTitle={tr(
          `Начальные остатки магазина «${d.store_name}» записаны. Новые товары добавляйте приходом, инвентаризацией или установкой цен — они сами появятся в «Моих товарах».`,
          `«${d.store_name}» doʻkonining boshlangʻich qoldiqlari yozilgan. Yangi mahsulotlarni kirim, inventarizatsiya yoki narx belgilash orqali qoʻshing — ular «Mahsulotlarim»da oʻzi paydo boʻladi.`,
        )}
        extra={
          <Space wrap>
            <Button type="primary" onClick={() => nav('/dirs/products')}>
              {tr('Мои товары', 'Mahsulotlarim')}
            </Button>
            <Button onClick={() => nav(docPaths.income)}>{tr('Приход товара', 'Mahsulot kirimi')}</Button>
            <Button onClick={() => nav(docPaths.inventory)}>{tr('Инвентаризация', 'Inventarizatsiya')}</Button>
          </Space>
        }
      />
    </Card>
  )
}
