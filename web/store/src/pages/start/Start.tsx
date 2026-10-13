// «Начало работы» (Figma «Панель магазина · начало работы v2», V1–V4).
// Черновик общий с «SM Магазин» и идёт в два шага:
//  1. «Мои товары» — поиск по центральной базе (название, штрихкод, USB-сканер),
//     фото полок, свой товар. Тот же товар второй раз не добавляется, на
//     похожий — предупреждение (один раз на пару). Штрихкод, который уже
//     в «Требуют внимания», — подсказка «уже в «Требуют внимания»» вместо
//     «Создать свой товар» (Figma «без дублей», В1).
//  2. «Инвентаризация: Начало работы» — количество и цена продажи (обязательны,
//     можно 0), себестоимость — по желанию. «Записать и закрыть» проводит
//     черновик, после этого «Начало работы» больше не показывается.
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert, App, Button, Card, Col, Flex, Input, InputNumber, Modal, Pagination, Result, Row, Segmented, Space, Table, Tag, Tooltip, Typography, type InputRef, type TableColumnsType } from 'antd'
import {
  ArrowRightOutlined,
  CameraOutlined,
  CheckCircleOutlined,
  CheckOutlined,
  CopyOutlined,
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
import { photoPoll, plainNum, useStartApi, useStartRefresh, type Draft, type Line, type LineInput, type LineVariant, type LinesResult, type NewItem, type PostResult, type SearchItem, type Similar } from './api'
import { BarcodeModal, NewProductModal, PhotoModal, SimilarModal, sum } from './Modals'
import { TasnifBlock, TasnifLink } from './Tasnif'
import { NEW_PAGE, NewByPhotoModal, NewItemsList, ReviewModal, RightTabs, newItemBadge, newItemState, newItemThumb, useNewItems, type RightTab } from './NewItems'
import { OwnVariantsStart, useOwnGroups } from '../OwnVariants'
import { CountDrawer, ScanCard } from './CountScan'
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
  const urlStep = params.get('step')
  // Шаг запоминается в черновике — «SM Магазин» на главной показывает тот же.
  const setStep = (s: 1 | 2) => {
    setParams({ step: String(s) })
    api.post('/store/start/step', { store_id: storeId, step: s }).catch(() => {})
  }
  const [result, setResult] = useState<PostResult | null>(null)

  // Шапка черновика: закрыт ли, итоги, склад.
  const head = useQuery({
    queryKey: ['/store/start', { store_id: storeId, limit: 1 }],
    queryFn: () => api.get<Draft>('/store/start', { store_id: storeId, limit: 1 }),
    placeholderData: keepPreviousData,
  })
  const d = head.data
  const step = urlStep === '2' ? 2 : urlStep === '1' ? 1 : d?.step === 2 ? 2 : 1

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
  const [tab, setTab] = useState<RightTab>('mine')
  // Группы вариаций своих товаров, которые ждут проверки (вкладка «Вариации»).
  const variantsCount = useOwnGroups('proposed', 1).data?.total ?? 0
  const [freshPage, setFreshPage] = useState(1)
  const fresh = useNewItems(storeId, freshPage)
  const freshCount = fresh.data?.total ?? 0
  // Очередь сократилась (провели, проверили) — страницы за концом больше нет.
  const freshPages = Math.max(1, Math.ceil(freshCount / NEW_PAGE))
  useEffect(() => {
    if (fresh.data && freshPage > freshPages) setFreshPage(freshPages)
  }, [fresh.data, freshPage, freshPages])
  // Super Market добавляет распознанные товары в «Мои товары» сам: очередь
  // сдвинулась — перечитать черновик.
  const qc = useQueryClient()
  const queueSig = fresh.data ? `${fresh.data.counts.processing}/${fresh.data.total}` : ''
  const prevSig = useRef(queueSig)
  useEffect(() => {
    if (prevSig.current && queueSig && prevSig.current !== queueSig) qc.invalidateQueries({ queryKey: ['/store/start'] })
    prevSig.current = queueSig
  }, [queueSig, qc])
  const tabs = (
    <RightTabs tab={tab} onTab={setTab} mine={d.totals.products} fresh={freshCount} ready={(fresh.data?.counts.ready ?? 0) > 0} variants={variantsCount} />
  )
  // Повтор: подсвеченная строка «Моих товаров».
  const [highlight, setHighlight] = useState<string | null>(null)
  // Штрихкод уже в «Новых»: подсвеченная карточка и открытая проверка.
  const [freshHighlight, setFreshHighlight] = useState<string | null>(null)
  const [review, setReview] = useState<NewItem | null>(null)
  const showQueued = (it: NewItem, open: boolean) => {
    setTab('new')
    setFreshHighlight(it.id)
    if (open) setReview(it)
  }
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
          <SearchCard onDuplicate={setHighlight} onNew={() => setByPhoto(true)} onQueued={showQueued} />
        </Col>
        <Col xs={24} xl={14}>
          {tab === 'new' ? (
            <Card title={tabs} styles={{ body: { padding: 0 } }}>
              <NewItemsList
                list={fresh.data}
                loading={fresh.isLoading}
                highlight={freshHighlight}
                page={freshPage}
                onPage={setFreshPage}
              />
            </Card>
          ) : tab === 'variants' ? (
            <Card title={tabs} styles={{ body: { padding: 0 } }}>
              <OwnVariantsStart />
            </Card>
          ) : (
            <MyGoods highlight={highlight} title={tabs} />
          )}
        </Col>
      </Row>
      <PhotoModal open={photoOpen} onClose={() => setPhotoOpen(false)} />
      <ReviewModal item={review} onClose={() => setReview(null)} />
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
function SearchCard({
  onDuplicate,
  onNew,
  onQueued,
}: {
  onDuplicate: (id: string | null) => void
  onNew: () => void
  /** Штрихкод уже в «Новых»: показать карточку справа (open — сразу открыть проверку). */
  onQueued: (it: NewItem, open: boolean) => void
}) {
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
  // Штрихкода нет в базе — может, его уже отправили Super Market («Новые»)?
  const lookup = isBarcode(q) && searched && items.length === 0
  const queued = useQuery({
    queryKey: ['/store/start/new-items', 'by-barcode', storeId, q],
    queryFn: () => api.get<{ item: NewItem | null }>('/store/start/new-items/by-barcode', { store_id: storeId, code: q }),
    enabled: lookup,
    // Пока карточка распознаётся — подсказка обновится сама.
    refetchInterval: (r) => (r.state.data?.item?.status === 'processing' ? 3000 : false),
  })
  const inQueue = lookup ? (queued.data?.item ?? null) : null
  const onQueuedRef = useRef(onQueued)
  onQueuedRef.current = onQueued
  // Один раз на карточку: справа — вкладка «Новые» с подсвеченной карточкой.
  const inQueueId = inQueue?.id
  useEffect(() => {
    if (inQueue) onQueuedRef.current(inQueue, false)
  }, [inQueueId]) // eslint-disable-line react-hooks/exhaustive-deps
  const tasnif = searched && !inQueue && !(lookup && queued.isLoading) && (items.length === 0 || tasnifAsked)

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
            {inQueue && <QueuedCallout item={inQueue} onOpen={() => onQueued(inQueue, true)} />}
            {searched && items.length > 0 && !tasnifAsked && <TasnifLink q={q} onClick={() => setTasnifAsked(true)} />}
            {tasnif && <TasnifBlock q={q} onMissingBarcode={(code) => setMissing(code)} onNew={onNew} />}
          </div>
        </>
      )}
      {can('catalog.manage') && !tasnif && !inQueue && (
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

/** В1: штрихкод уже в «Новых от Super Market» — вторую карточку не заводим. */
function QueuedCallout({ item, onOpen }: { item: NewItem; onOpen: () => void }) {
  const name =
    item.status === 'ready' ? item.result?.name : item.status === 'processing' ? tr('Распознаётся…', 'Aniqlanmoqda…') : tr('Не удалось распознать', 'Aniqlab boʻlmadi')
  return (
    <div style={{ padding: '12px 16px 16px' }}>
      <Flex vertical gap={10} style={{ background: '#FFFAEB', border: '1px solid #FEDF89', borderRadius: 12, padding: 14 }}>
        <Flex align="center" gap={8}>
          <CopyOutlined style={{ color: '#DC6803' }} />
          <Typography.Text strong style={{ color: '#93370D' }}>
            {tr('Этот товар уже в «Требуют внимания»', 'Bu mahsulot allaqachon «Eʼtibor talab qiladi»da')}
          </Typography.Text>
        </Flex>
        <Typography.Text style={{ fontSize: 13, color: '#475467' }}>
          {tr(
            `Штрихкод ${item.barcode} уже отправлен Super Market. Второй раз добавлять не нужно — проверьте его карточку.`,
            `${item.barcode} shtrix-kodi Super Market’ga allaqachon yuborilgan. Qayta qoʻshish shart emas — kartochkasini tekshiring.`,
          )}
        </Typography.Text>
        <Flex align="center" gap={12} style={{ background: '#fff', borderRadius: 10, padding: '10px 12px' }}>
          <Thumb src={newItemThumb(item)} size={44} badge={newItemBadge(item)} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <Typography.Text strong style={{ display: 'block', fontWeight: 600 }}>
              {name}
            </Typography.Text>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {[newItemState(item.status), tr(`${item.images.length} фото`, `${item.images.length} ta rasm`)].join(' · ')}
            </Typography.Text>
          </div>
          {item.status === 'processing' ? (
            <Button size="small" disabled style={{ flex: 'none' }}>
              Super Market…
            </Button>
          ) : (
            <Button size="small" type={item.status === 'ready' ? 'primary' : 'default'} onClick={onOpen} style={{ flex: 'none' }}>
              {item.status === 'ready' ? tr('Проверить', 'Tekshirish') : tr('Заполнить', 'Toʻldirish')}
            </Button>
          )}
        </Flex>
      </Flex>
    </div>
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
      <Thumb src={l.image} size={36} badge={l.photo} />
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
  const draft = useQuery({ queryKey: ['/store/start', params], queryFn: () => api.get<Draft>('/store/start', params), placeholderData: keepPreviousData, refetchInterval: photoPoll })
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

type Only = '' | 'unfilled' | 'no_cost' | 'no_photo'

/** V4: документ «Инвентаризация: Начало работы». */
function StepCount({ d, back, onPosted }: { d: Draft; back: () => void; onPosted: (r: PostResult) => void }) {
  const { storeId } = useStore()
  const { modal, message } = App.useApp()
  const { setLines, deleteLine, refresh } = useStartApi(storeId)
  const [only, setOnly] = useState<Only>('')
  const [page, setPage] = useState(1)
  // Товар, который открыт в шторке ввода (скан или поиск по названию).
  const [sheet, setSheet] = useState<Line | null>(null)
  useEffect(() => setPage(1), [only, storeId])
  // Сначала группы вариаций (группа → вес → вариант), потом обычные товары.
  const params = { store_id: storeId, only: only || undefined, order: 'groups', limit: PAGE + 1, offset: (page - 1) * PAGE }
  const draft = useQuery({ queryKey: ['/store/start', params], queryFn: () => api.get<Draft>('/store/start', params), placeholderData: keepPreviousData, refetchInterval: photoPoll })
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
    if (t.no_photo > 0) {
      setOnly('no_photo')
      message.error(tr(`Добавьте фото: товаров без фото — ${t.no_photo}`, `Rasm qoʻshing: rasmsiz mahsulotlar — ${t.no_photo}`))
      return
    }
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
          if (e instanceof ApiError && e.code === 'lines_no_photo') setOnly('no_photo')
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
      <div style={{ marginBottom: 16 }}>
        <ScanCard onFound={setSheet} />
      </div>
      <Row gutter={[12, 12]} style={{ marginBottom: 16 }}>
        <Stat title={tr('Товаров', 'Mahsulotlar')} value={String(t.products)} />
        <Stat title={tr('Заполнено', 'Toʻldirilgan')} value={tr(`${filled} из ${t.products}`, `${filled} / ${t.products}`)} warn={t.unfilled > 0} />
        <Stat title={tr('По себестоимости', 'Tannarxda')} value={sum(t.cost_total)} />
        <Stat title={tr('По цене продажи', 'Sotish narxida')} value={sum(t.price_total)} />
      </Row>
      {t.no_photo > 0 && (
        <Alert
          type="error"
          showIcon
          style={{ marginBottom: 16 }}
          message={tr(`Без фото: ${goods(t.no_photo)}`, `Rasmsiz: ${goods(t.no_photo)}`)}
          description={tr(
            'Покупатель не увидит товар без фото, поэтому «Записать и закрыть» с такими товарами не пройдёт. Откройте товар и загрузите снимок.',
            'Xaridor rasmsiz mahsulotni koʻrmaydi, shuning uchun «Yozish va yopish» oʻtmaydi. Mahsulotni oching va rasm yuklang.',
          )}
          action={
            <Button size="small" onClick={() => setOnly('no_photo')}>
              {tr('Показать', 'Koʻrsatish')}
            </Button>
          }
        />
      )}
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
              { value: 'no_cost', label: `${tr('Без цены закупки', 'Xarid narxisiz')} · ${t.no_cost}` },
              { value: 'no_photo', label: `${tr('Без фото', 'Rasmsiz')} · ${t.no_photo}` },
            ]}
          />
        }
        styles={{ body: { padding: 0 } }}
      >
        <LoadError error={draft.error} retry={() => draft.refetch()} />
        <LineTables
          lines={lines}
          loading={draft.isLoading}
          empty={only ? tr('Таких товаров нет', 'Bunday mahsulotlar yoʻq') : tr('Нет товаров — добавьте их на шаге 1', 'Mahsulotlar yoʻq — ularni 1-qadamda qoʻshing')}
          save={save}
          onSheet={setSheet}
          onDelete={(l) => deleteLine(l.product_id).catch(() => {})}
          refresh={refresh}
        />
        {lines.length > 0 && (
          <Flex justify="space-between" align="center" wrap gap={8} style={{ padding: '12px 16px', borderTop: '1px solid #EAECF0' }}>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr(`Показано ${(page - 1) * PAGE + 1}–${(page - 1) * PAGE + lines.length}`, `Koʻrsatilgan: ${(page - 1) * PAGE + 1}–${(page - 1) * PAGE + lines.length}`)}
            </Typography.Text>
            {(page > 1 || hasMore) && (
              <Pagination size="small" current={page} pageSize={PAGE} total={(page - 1) * PAGE + lines.length + (hasMore ? 1 : 0)} onChange={setPage} showSizeChanger={false} />
            )}
            <Typography.Text strong>
              {tr(`Итого: себестоимость ${sum(t.cost_total)} · продажа ${sum(t.price_total)}`, `Jami: tannarx ${sum(t.cost_total)} · sotish ${sum(t.price_total)}`)}
            </Typography.Text>
          </Flex>
        )}
      </Card>
      <CountDrawer
        line={sheet}
        onClose={() => setSheet(null)}
        onSaved={async () => {
          setSheet(null)
          await refresh()
          await draft.refetch()
        }}
      />
    </>
  )
}

// ------------------------------------------------ инвентаризация по группам

/** Кусок страницы: группа вариаций подряд или обычные товары. */
type Segment = { kind: 'group'; v: LineVariant; lines: Line[] } | { kind: 'plain'; lines: Line[] }

function segments(lines: Line[]): Segment[] {
  const out: Segment[] = []
  for (const l of lines) {
    const last = out[out.length - 1]
    if (l.variant) {
      if (last?.kind === 'group' && last.v.group_id === l.variant.group_id) last.lines.push(l)
      else out.push({ kind: 'group', v: l.variant, lines: [l] })
    } else if (last?.kind === 'plain') last.lines.push(l)
    else out.push({ kind: 'plain', lines: [l] })
  }
  return out
}

const fold = (s: string) => s.trim().toLowerCase().replace(/ё/g, 'е')

/** «4 вкуса», «3 цвета», иначе «Аромат: 3». */
function counted(label: string, n: number) {
  const l = label.toLowerCase()
  if (l === 'вкус') return tr(`${n} ${plural(n, 'вкус', 'вкуса', 'вкусов')}`, `${n} ta taʼm`)
  if (l === 'цвет') return tr(`${n} ${plural(n, 'цвет', 'цвета', 'цветов')}`, `${n} ta rang`)
  if (l === 'вес') return tr(`${n} ${plural(n, 'вес', 'веса', 'весов')}`, `${n} ta vazn`)
  return label ? `${label}: ${n}` : tr(`${n} ${plural(n, 'вариант', 'варианта', 'вариантов')}`, `${n} ta variant`)
}

/** «для всех вкусов» / «для всех цветов» / «для всех вариантов». */
function forAll(label: string) {
  const l = label.toLowerCase()
  const ru = l === 'вкус' ? 'вкусов' : l === 'цвет' ? 'цветов' : l === 'аромат' ? 'ароматов' : l === 'размер' ? 'размеров' : 'вариантов'
  return tr(`для всех ${ru}`, 'barcha variantlar uchun')
}

/** «Все цвета» / «Все вкусы» / «Все варианты» — строка цены группы без веса. */
function allOf(label: string) {
  const l = label.toLowerCase()
  const ru = l === 'вкус' ? 'вкусы' : l === 'цвет' ? 'цвета' : l === 'аромат' ? 'ароматы' : l === 'размер' ? 'размеры' : 'варианты'
  return tr(`Все ${ru}`, 'Barcha variantlar')
}

/** Общая цена строк без «своей цены»; null — разные или ещё не введены. */
function commonPrice(lines: Line[]): string | null {
  let common: string | null = null
  for (const l of lines) {
    if (l.variant?.own_price) continue
    if (l.price === null) return null
    if (common === null) common = l.price
    else if (Number(common) !== Number(l.price)) return null
  }
  return common
}

type GRow = { key: string; head?: { label: string; lines: Line[] }; line?: Line }

/**
 * Строки инвентаризации таблицами друг над другом (Figma «Вариации своих
 * товаров», В3): группа вариаций — своя таблица с колонками своих
 * переключателей, цена продажи — один раз на вес (или на группу, если веса
 * нет), количество — у каждого варианта; обычные товары — последней таблицей.
 */
function LineTables({
  lines,
  loading,
  empty,
  save,
  onSheet,
  onDelete,
  refresh,
}: {
  lines: Line[]
  loading: boolean
  empty: string
  save: (l: Line, patch: Omit<LineInput, 'product_id'>) => Promise<unknown>
  onSheet: (l: Line) => void
  onDelete: (l: Line) => void
  refresh: () => Promise<unknown>
}) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const segs = segments(lines)
  const call = async (p: Promise<unknown>) => {
    try {
      await p
    } catch (e) {
      message.error(errorText(e))
      throw e
    } finally {
      await refresh()
    }
  }
  const groupPrice = (v: LineVariant, weight: string, price: string | null) =>
    price === null ? Promise.resolve() : call(api.post('/store/start/group-price', { store_id: storeId, group_id: v.group_id, weight, price }))
  const ownPrice = (l: Line, own: boolean, price?: string | null) =>
    call(api.post(`/store/start/lines/${l.product_id}/own-price`, { store_id: storeId, own, price: price ?? undefined }))

  const unfilled = (l: Line) => l.qty === null || l.price === null
  const tail: TableColumnsType<GRow> = [
    {
      title: tr('Штрихкод', 'Shtrix-kod'),
      key: 'barcode',
      width: 140,
      render: (_, r) =>
        r.line && (
          <Typography.Text type="secondary" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
            {r.line.barcode ?? '—'}
          </Typography.Text>
        ),
    },
    {
      title: `${tr('Кол-во', 'Miqdor')} *`,
      key: 'qty',
      width: 130,
      render: (_, r) => r.line && <NumCell value={r.line.qty} required placeholder={tr('обязательно', 'majburiy')} onSave={(v) => save(r.line!, { qty: v })} />,
    },
    {
      title: tr('Цена закупки', 'Xarid narxi'),
      key: 'cost',
      width: 140,
      render: (_, r) => r.line && <NumCell value={r.line.cost} placeholder={tr('необязательно', 'ixtiyoriy')} onSave={(v) => save(r.line!, { cost: v })} />,
    },
  ]
  const actions: TableColumnsType<GRow> = [
    {
      key: 'fill',
      width: 44,
      render: (_, r) =>
        r.line && (
          <Tooltip title={r.line.image ? tr('Количество и цены', 'Miqdor va narxlar') : tr('Нужно фото товара', 'Mahsulot rasmi kerak')}>
            <Button type="text" size="small" danger={!r.line.image} icon={r.line.image ? <RightOutlined /> : <CameraOutlined />} onClick={() => onSheet(r.line!)} />
          </Tooltip>
        ),
    },
    {
      key: 'del',
      width: 44,
      render: (_, r) =>
        r.line && (
          <Tooltip title={tr('Убрать из списка', 'Roʻyxatdan olib tashlash')}>
            <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => onDelete(r.line!)} />
          </Tooltip>
        ),
    },
  ]
  const plainPrice: TableColumnsType<GRow>[number] = {
    title: `${tr('Цена продажи', 'Sotish narxi')} *`,
    key: 'price',
    width: 150,
    render: (_, r) =>
      r.line && (
        <NumCell
          value={r.line.price}
          required
          placeholder={tr('обязательно', 'majburiy')}
          title={Number(r.line.current_price) > 0 ? tr(`В базе: ${money(r.line.current_price)}`, `Bazada: ${money(r.line.current_price)}`) : undefined}
          onSave={(v) => save(r.line!, { price: v })}
        />
      ),
  }
  const table = (rows: GRow[], columns: TableColumnsType<GRow>) => (
    <Table<GRow>
      rowKey="key"
      size="middle"
      dataSource={rows}
      columns={columns}
      pagination={false}
      scroll={{ x: 900 }}
      rowClassName={(r) => (r.line && unfilled(r.line) ? 'sm-start-unfilled' : r.head ? 'sm-variant-weight' : '')}
      onRow={(r) => (r.head ? { style: { background: '#FCFCFD' } } : {})}
    />
  )

  if (loading && lines.length === 0) return table([], [{ key: 'x', title: tr('Товар', 'Mahsulot') }])
  if (lines.length === 0)
    return (
      <Typography.Paragraph type="secondary" style={{ padding: 24, margin: 0, textAlign: 'center' }}>
        {empty}
      </Typography.Paragraph>
    )
  const many = segs.length > 1
  return (
    <Flex vertical gap={16} style={{ padding: many ? 16 : 0 }}>
      {segs.map((seg, i) => {
        if (seg.kind === 'plain') {
          const rows = seg.lines.map((l) => ({ key: l.product_id, line: l }))
          const cols: TableColumnsType<GRow> = [{ title: tr('Товар', 'Mahsulot'), key: 'name', render: (_, r) => r.line && <NameCell l={r.line} /> }, ...tail, plainPrice, ...actions]
          return many ? (
            <Card key={`plain-${i}`} size="small" title={tr('Товары без вариаций', 'Variatsiyasiz mahsulotlar')} styles={{ body: { padding: 0 } }}>
              {table(rows, cols)}
            </Card>
          ) : (
            <div key={`plain-${i}`}>{table(rows, cols)}</div>
          )
        }
        const v = seg.v
        const hasWeight = !!v.weight_label
        // Строки группы: заголовок веса (или «Все цвета» без веса), под ним варианты.
        const rows: GRow[] = []
        if (hasWeight) {
          let cur: GRow | null = null
          for (const l of seg.lines) {
            const w = l.variant?.weight ?? ''
            if (!cur || fold(cur.head!.label) !== fold(w)) {
              cur = { key: `w-${v.group_id}-${w}`, head: { label: w, lines: [] } }
              rows.push(cur)
            }
            cur.head!.lines.push(l)
            rows.push({ key: l.product_id, line: l })
          }
        } else {
          rows.push({ key: `all-${v.group_id}`, head: { label: '', lines: seg.lines } })
          for (const l of seg.lines) rows.push({ key: l.product_id, line: l })
        }
        const weights = new Set(seg.lines.map((l) => fold(l.variant?.weight ?? ''))).size
        const sub = [
          tr('Переключатели', 'Almashtirgichlar') + ': ' + [v.weight_label, v.flavor_label].filter(Boolean).join(' → '),
          hasWeight ? counted(v.weight_label, weights) : null,
          v.flavor_label ? counted(v.flavor_label, seg.lines.length) : null,
          hasWeight ? null : tr('цена одна на группу', 'narx guruh uchun bitta'),
        ]
          .filter(Boolean)
          .join(' · ')
        const firstTitle = [v.weight_label, v.flavor_label].filter(Boolean).join(' · ') || tr('Товар', 'Mahsulot')
        const cols: TableColumnsType<GRow> = [
          {
            title: firstTitle,
            key: 'name',
            render: (_, r) => {
              if (r.head) {
                return (
                  <Flex align="center" gap={8}>
                    <Typography.Text strong>{r.head.label || allOf(v.flavor_label)}</Typography.Text>
                    {hasWeight && v.flavor_label && (
                      <Tag bordered={false} style={{ marginInlineEnd: 0 }}>
                        {counted(v.flavor_label, r.head.lines.length)}
                      </Tag>
                    )}
                  </Flex>
                )
              }
              const l = r.line!
              return (
                <Flex align="center" gap={10} style={{ paddingLeft: 20 }}>
                  <Thumb src={l.image} size={32} badge={l.photo} />
                  <div style={{ minWidth: 0 }}>
                    <Typography.Text style={{ fontWeight: 600 }}>{l.variant?.flavor || l.variant?.weight || l.name}</Typography.Text>
                    <Typography.Text type="secondary" style={{ display: 'block', fontSize: 12 }}>
                      {l.name}
                      {l.own ? ` · ${tr('свой', 'oʻziniki')}` : ''}
                    </Typography.Text>
                  </div>
                </Flex>
              )
            },
          },
          ...tail.map((c) => ({ ...c })),
          {
            title: `${tr('Цена продажи', 'Sotish narxi')} *`,
            key: 'price',
            width: 170,
            render: (_, r) => {
              if (r.head) {
                const common = commonPrice(r.head.lines)
                const mixed = common === null && r.head.lines.some((l) => !l.variant?.own_price && l.price !== null)
                return (
                  <div>
                    <NumCell
                      value={common}
                      required={!mixed}
                      placeholder={mixed ? tr('разные цены', 'turli narxlar') : tr('обязательно', 'majburiy')}
                      onSave={(p) => groupPrice(v, r.head!.label, p)}
                    />
                    <Typography.Text type="secondary" style={{ fontSize: 11 }}>
                      {forAll(v.flavor_label)}
                    </Typography.Text>
                  </div>
                )
              }
              const l = r.line!
              const own = !!l.variant?.own_price
              const where = hasWeight ? tr(`как у ${l.variant?.weight}`, `${l.variant?.weight} kabi`) : tr('как у группы', 'guruhdagidek')
              return (
                <div>
                  <NumCell
                    value={l.price}
                    required
                    placeholder={tr('обязательно', 'majburiy')}
                    title={own ? undefined : tr('Другая цена — станет «своей ценой» этого варианта', 'Boshqa narx — bu variantning «oʻz narxi» boʻladi')}
                    onSave={(p) => (own ? save(l, { price: p }) : ownPrice(l, true, p))}
                  />
                  {own ? (
                    <Typography.Text style={{ fontSize: 11, color: '#B54708' }}>
                      {tr('своя цена', 'oʻz narxi')} ·{' '}
                      <a onClick={() => ownPrice(l, false).catch(() => {})}>{hasWeight ? tr('вернуть цену веса', 'vazn narxini qaytarish') : tr('вернуть цену группы', 'guruh narxini qaytarish')}</a>
                    </Typography.Text>
                  ) : (
                    <Typography.Text type="secondary" style={{ fontSize: 11 }}>
                      {where}
                    </Typography.Text>
                  )}
                </div>
              )
            },
          },
          ...actions,
        ]
        return (
          <Card
            key={`g-${v.group_id}-${i}`}
            size="small"
            styles={{ body: { padding: 0 } }}
            title={
              <Flex align="center" gap={10} style={{ padding: '6px 0' }}>
                <Flex align="center" justify="center" style={{ width: 30, height: 30, borderRadius: 8, background: '#FEF3F2', color: '#E11D2A', fontWeight: 800, flex: 'none' }}>
                  {v.group_name.trim().charAt(0).toUpperCase() || '?'}
                </Flex>
                <div>
                  <Flex align="center" gap={8} wrap>
                    <Typography.Text strong style={{ fontSize: 14 }}>
                      {v.group_name}
                    </Typography.Text>
                    <Tag color="blue" bordered={false} style={{ marginInlineEnd: 0 }}>
                      {tr('Группа вариаций', 'Variatsiyalar guruhi')}
                    </Tag>
                  </Flex>
                  <Typography.Text type="secondary" style={{ fontSize: 12, fontWeight: 400 }}>
                    {sub}
                  </Typography.Text>
                </div>
              </Flex>
            }
          >
            {table(rows, cols)}
          </Card>
        )
      })}
    </Flex>
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
