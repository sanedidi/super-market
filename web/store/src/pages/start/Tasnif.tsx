// Товара нет в центральной базе — варианты из каталога ИКПУ tasnif.soliq.uz
// (Figma «Панель магазина · начало работы v3 · варианты из каталога ИКПУ»,
// Т1–Т5, Т4a/Т4b). Поиск в tasnif идёт из браузера, сервер собирает названия
// и отмечает то, что уже есть в базе. «Добавить» создаёт товар в центральной
// базе (категория — по коду ИКПУ) и ставит его в «Мои товары»; если
// категорию не определить — окно с предложением Super Market.
import { useEffect, useState } from 'react'
import { useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Flex, Input, Modal, Space, Spin, Tag, Tooltip, Typography } from 'antd'
import { CheckOutlined, DownOutlined, FileSearchOutlined, FolderAddOutlined, PlusOutlined, StarFilled, TagsOutlined } from '@ant-design/icons'
import { ApiError, RemoteSelect, api, errorText, getLang, tr } from '@sm/shared'
import { useStore } from '../../ctx'
import type { DictItem } from '../../types'
import { useStartRefresh, type CategoryRef, type NewCategory, type Similar, type TasnifAddResult, type TasnifPreview } from './api'
import { SimilarModal, type ShortProduct } from './Modals'
import { TASNIF_SITE, isGtin, searchTasnif, tasnifPhoto, type TasnifRecord } from './tasnif'
import { Thumb } from './Thumb'

const BLUE = '#175CD3'
const FIRST = 5

/** Поля записи, которые понимает сервер. */
function pick(r: TasnifRecord) {
  return {
    mxikCode: r.mxikCode,
    mxikName: r.mxikName ?? '',
    groupCode: r.groupCode ?? '',
    classCode: r.classCode ?? '',
    groupName: r.groupName ?? '',
    className: r.className ?? '',
    positionName: r.positionName ?? '',
    subPositionName: r.subPositionName ?? '',
    brandName: r.brandName ?? '',
    attributeName: r.attributeName ?? '',
    internationalCode: r.internationalCode ?? '',
    label: r.label ?? 0,
  }
}

type Payload = {
  item: ReturnType<typeof pick>
  image?: string | null
  category_id?: string
  new_category?: NewCategory
  name_uz?: string
  unit_id?: string
  confirm_similar?: boolean
}

const catText = (c: { section: string; section_uz: string; name: string; name_uz: string }) =>
  getLang() === 'uz' ? `${c.section_uz || c.section} › ${c.name_uz || c.name}` : `${c.section} › ${c.name}`

/** Ссылка на источник — условие tasnif.soliq.uz. */
export function TasnifSource() {
  return (
    <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', padding: '0 16px 14px' }}>
      {tr('Источник:', 'Manba:')}{' '}
      <a href={TASNIF_SITE} target="_blank" rel="noreferrer" style={{ textDecoration: 'underline' }}>
        tasnif.soliq.uz
      </a>
    </Typography.Text>
  )
}

/** Т5: в базе что-то нашлось, но не то. */
export function TasnifLink({ q, onClick }: { q: string; onClick: () => void }) {
  return (
    <Flex
      align="center"
      gap={6}
      role="button"
      onClick={onClick}
      style={{ padding: '12px 16px', background: '#F5FAFF', borderBottom: '1px solid #EAECF0', cursor: 'pointer', color: BLUE, fontWeight: 700, fontSize: 13 }}
    >
      <FileSearchOutlined /> {tr(`Нет нужного? Поискать «${q}» в каталоге ИКПУ`, `Keraklisi yoʻqmi? «${q}» ni MXIK katalogidan qidirish`)}
    </Flex>
  )
}

/**
 * Варианты из каталога ИКПУ по запросу q (название или штрихкод).
 * onMissingBarcode — штрихкода нет нигде (привязать к товару или создать);
 * onNew — создать свой товар.
 */
export function TasnifBlock({ q, onMissingBarcode, onNew }: { q: string; onMissingBarcode: (code: string) => void; onNew: () => void }) {
  const { storeId, can } = useStore()
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [expanded, setExpanded] = useState(false)
  const [busy, setBusy] = useState<number | null>(null)
  const [slow, setSlow] = useState(false)
  const [ask, setAsk] = useState<{ payload: Payload; res: TasnifAddResult; ikpu: string; barcode: string | null; image: string | null } | null>(null)
  const [similar, setSimilar] = useState<{ payload: Payload; item: ShortProduct; similar: Similar } | null>(null)
  const manage = can('catalog.manage')
  const gtin = isGtin(q)
  useEffect(() => setExpanded(false), [q])

  const found = useInfiniteQuery({
    queryKey: ['tasnif', q],
    queryFn: ({ pageParam, signal }) => searchTasnif(q, pageParam, signal),
    initialPageParam: 0,
    getNextPageParam: (last, all) => (all.reduce((n, p) => n + p.records.length, 0) < last.total && last.records.length > 0 ? all.length : undefined),
    staleTime: 5 * 60_000,
    retry: 1,
  })
  const records = (found.data?.pages ?? []).flatMap((p) => p.records)
  const preview = useQuery({
    queryKey: ['/store/start/tasnif/preview', storeId, q, records.length],
    queryFn: () =>
      api.post<{ items: TasnifPreview[] }>('/store/start/tasnif/preview', { store_id: storeId, items: records.slice(0, 50).map(pick) }).then((r) => r.items ?? []),
    enabled: found.isSuccess && records.length > 0,
    placeholderData: (prev) => prev,
  })
  const items = records.length === 0 ? [] : (preview.data ?? [])
  const shown = expanded ? items : items.slice(0, FIRST)
  // Пока загружено не всё — сколько всего у tasnif; иначе — сколько показываем (алкоголь отброшен).
  const total = found.hasNextPage ? (found.data?.pages[0]?.total ?? 0) : items.length

  const submit = async (p: Payload, shortItem: ShortProduct, ikpu: string): Promise<boolean> => {
    try {
      const r = await api.post<TasnifAddResult>('/store/start/tasnif', { store_id: storeId, ...p })
      if (r.status === 'need_category') {
        setAsk({ payload: p, res: r, ikpu, barcode: shortItem.barcode, image: p.image ?? null })
        return false
      }
      message.success(tr(`${r.name} — в «Моих товарах»`, `${r.name} — «Mahsulotlarim»da`))
      await refresh()
      return true
    } catch (e) {
      if (e instanceof ApiError && e.code === 'already_added') {
        message.warning(tr(`${shortItem.name} — уже добавлен`, `${shortItem.name} — allaqachon qoʻshilgan`))
        await refresh()
      } else if (e instanceof ApiError && e.code === 'similar_exists' && e.details.similar) {
        setSimilar({ payload: p, item: shortItem, similar: e.details.similar as Similar })
      } else {
        message.error(errorText(e))
      }
      return false
    }
  }

  const add = async (it: TasnifPreview) => {
    const rec = records[it.index]
    if (!rec) return
    setBusy(it.index)
    const t = setTimeout(() => setSlow(true), 1500)
    try {
      // Фото из tasnif — новому товару или товару базы без фото.
      const image = it.product_id && it.image ? null : await tasnifPhoto(it.ikpu)
      await submit({ item: pick(rec), image }, { name: it.name, image: it.image, barcode: it.barcode }, it.ikpu)
    } finally {
      clearTimeout(t)
      setSlow(false)
      setBusy(null)
    }
  }

  const head = (title: string, sub: string) => (
    <Flex gap={10} style={{ padding: '12px 16px', background: '#EFF8FF', borderBottom: '1px solid #B2DDFF' }}>
      <FileSearchOutlined style={{ color: '#1570EF', fontSize: 18, marginTop: 1 }} />
      <div>
        <Typography.Text strong style={{ color: BLUE, display: 'block', fontSize: 13 }}>
          {title}
        </Typography.Text>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {sub}
        </Typography.Text>
      </div>
    </Flex>
  )

  if (found.isLoading || (preview.isLoading && records.length > 0)) {
    return (
      <Flex align="center" gap={10} style={{ padding: '14px 16px', borderBottom: '1px solid #EAECF0' }}>
        <Spin size="small" />
        <Typography.Text type="secondary">{tr('Ищем в каталоге ИКПУ…', 'MXIK katalogidan qidirilmoqda…')}</Typography.Text>
      </Flex>
    )
  }
  if (found.isError || preview.isError) {
    return (
      <div style={{ padding: '12px 16px', borderBottom: '1px solid #EAECF0' }}>
        <Alert
          type="warning"
          showIcon
          message={tr('Каталог ИКПУ сейчас не отвечает', 'MXIK katalogi hozir javob bermayapti')}
          action={
            <Button size="small" onClick={() => (found.isError ? found.refetch() : preview.refetch())}>
              {tr('Повторить', 'Qayta urinish')}
            </Button>
          }
        />
      </div>
    )
  }

  if (items.length === 0) {
    // Т3: нет ни в центральной базе, ни в каталоге ИКПУ.
    return (
      <>
        <Flex vertical align="center" gap={8} style={{ padding: '28px 32px', textAlign: 'center', borderBottom: '1px solid #EAECF0' }}>
          <FileSearchOutlined style={{ fontSize: 32, color: '#98A2B3' }} />
          <Typography.Text strong style={{ fontSize: 15 }}>
            {tr('Нет ни в центральной базе, ни в каталоге ИКПУ', 'Na markaziy bazada, na MXIK katalogida yoʻq')}
          </Typography.Text>
          <Typography.Text type="secondary" style={{ fontSize: 13, maxWidth: 380 }}>
            {gtin
              ? tr('Если товар есть в базе без этого штрихкода — привяжите его. Иначе создайте свой товар.', 'Agar mahsulot bazada shu shtrix-kodsiz boʻlsa — uni bogʻlang. Aks holda oʻz mahsulotingizni yarating.')
              : tr('Проверьте написание или поищите по штрихкоду. Если товара правда нигде нет — создайте свой: после проверки он попадёт в центральную базу.', 'Yozilishini tekshiring yoki shtrix-kod boʻyicha qidiring. Agar mahsulot haqiqatan hech qayerda boʻlmasa — oʻzingiz yarating: tekshiruvdan soʻng u markaziy bazaga qoʻshiladi.')}
          </Typography.Text>
          {manage && (
            <Button type="primary" icon={<PlusOutlined />} style={{ marginTop: 6 }} onClick={() => (gtin ? onMissingBarcode(q) : onNew())}>
              {gtin ? tr('Привязать или создать свой', 'Bogʻlash yoki oʻzingiz yaratish') : tr('Создать свой товар', 'Oʻz mahsulotingizni yaratish')}
            </Button>
          )}
        </Flex>
        <div style={{ height: 12 }} />
        <TasnifSource />
      </>
    )
  }

  const primary = gtin && items.length === 1
  return (
    <>
      {gtin
        ? head(tr('Нашли по штрихкоду в каталоге ИКПУ', 'MXIK katalogidan shtrix-kod boʻyicha topildi'), tr('Проверьте и добавьте — товар попадёт в центральную базу со штрихкодом и ИКПУ, фото подтянем оттуда же.', 'Tekshiring va qoʻshing — mahsulot markaziy bazaga shtrix-kod va MXIK bilan tushadi, rasm ham oʻsha yerdan olinadi.'))
        : head(
            tr(`Нашли в каталоге ИКПУ · ${total}`, `MXIK katalogidan topildi · ${total}`),
            tr('Выберите свой — он добавится в центральную базу Super Market и сразу в «Мои товары».', 'Oʻzingiznikini tanlang — u Super Market markaziy bazasiga va darhol «Mahsulotlarim»ga qoʻshiladi.'),
          )}
      {shown.map((it) => {
        const locked = !it.product_id && !manage
        return (
          <div key={`${it.ikpu}-${it.barcode ?? it.index}`} style={{ borderBottom: '1px solid #EAECF0' }}>
            <Flex align="center" gap={12} style={{ padding: '10px 16px' }}>
              <Thumb src={it.image} size={40} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <Typography.Text strong style={{ fontWeight: 600, display: 'block' }}>
                  {it.name}
                </Typography.Text>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {[it.barcode, `${tr('ИКПУ', 'MXIK')}\u00a0${it.ikpu}`, it.product_id ? tr('уже в базе', 'bazada bor') : null].filter(Boolean).join(' · ')}
                </Typography.Text>
              </div>
              {it.added ? (
                <span style={{ flex: 'none', background: '#ECFDF3', color: '#027A48', borderRadius: 8, padding: '4px 10px', fontWeight: 700, fontSize: 13 }}>
                  <CheckOutlined /> {it.in_store ? tr('Уже в магазине', 'Doʻkonda bor') : tr('Добавлен', 'Qoʻshilgan')}
                </span>
              ) : (
                <Tooltip title={locked ? tr('Добавлять новые товары в базу может сотрудник с правом на каталог', 'Bazaga yangi mahsulot qoʻshishni katalog huquqiga ega xodim bajaradi') : undefined}>
                  <Button
                    size={primary ? 'middle' : 'small'}
                    type={primary ? 'primary' : 'default'}
                    icon={<PlusOutlined />}
                    disabled={locked || (busy !== null && busy !== it.index)}
                    loading={busy === it.index}
                    onClick={() => add(it)}
                    style={{ flex: 'none' }}
                  >
                    {tr('Добавить', 'Qoʻshish')}
                  </Button>
                </Tooltip>
              )}
            </Flex>
            {busy === it.index && slow && (
              <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', padding: '0 16px 10px 68px' }}>
                {tr('Super Market готовит карточку товара…', 'Super Market mahsulot kartochkasini tayyorlamoqda…')}
              </Typography.Text>
            )}
          </div>
        )
      })}
      {(items.length > shown.length || found.hasNextPage) && (
        <Flex
          align="center"
          gap={4}
          role="button"
          onClick={() => (items.length > shown.length ? setExpanded(true) : found.fetchNextPage())}
          style={{ padding: '10px 16px', borderBottom: '1px solid #EAECF0', cursor: 'pointer', fontWeight: 700, fontSize: 13, color: '#344054' }}
        >
          {found.isFetchingNextPage ? <Spin size="small" /> : null}
          {items.length > shown.length
            ? tr(`Показать ещё ${items.length - shown.length}`, `Yana ${items.length - shown.length} tasini koʻrsatish`)
            : tr('Показать ещё', 'Yana koʻrsatish')}{' '}
          <DownOutlined style={{ fontSize: 11 }} />
        </Flex>
      )}
      <Flex align="center" gap={6} style={{ padding: '12px 16px 6px' }}>
        <Typography.Text type="secondary" style={{ fontSize: 13 }}>
          {gtin ? tr('Не тот товар?', 'Bu mahsulot emasmi?') : tr('Нет подходящего?', 'Mosi yoʻqmi?')}
        </Typography.Text>
        {manage && (
          <Button type="link" danger size="small" style={{ padding: 0, fontWeight: 700 }} onClick={() => (gtin ? onMissingBarcode(q) : onNew())}>
            {gtin ? tr('Привязать к товару базы или создать свой', 'Baza mahsulotiga bogʻlash yoki oʻzingiz yaratish') : tr('Создать свой товар', 'Oʻz mahsulotingizni yaratish')}
          </Button>
        )}
      </Flex>
      <TasnifSource />
      <CategoryModal
        data={ask}
        onCancel={() => setAsk(null)}
        onSubmit={async (extra) => {
          if (!ask) return
          const ok = await submit({ ...ask.payload, ...extra }, { name: ask.res.name, image: null, barcode: ask.barcode }, ask.ikpu)
          if (ok) setAsk(null)
        }}
      />
      <SimilarModal
        data={similar}
        onCancel={() => setSimilar(null)}
        onConfirm={async () => {
          const s = similar
          setSimilar(null)
          if (s) await submit({ ...s.payload, confirm_similar: true }, s.item, s.payload.item.mxikCode)
        }}
      />
    </>
  )
}

// ---------------------------------------------------------- категория (Т4)

type Choice = { category_id: string } | { new_category: NewCategory }

/**
 * Т4a — Super Market подобрал категорию из базы (можно сменить);
 * Т4b — подходящей нет, Super Market предлагает новую подкатегорию.
 * Без предложения (ИИ не подключён) — просто выбор категории.
 */
function CategoryModal({
  data,
  onCancel,
  onSubmit,
}: {
  data: { res: TasnifAddResult; ikpu: string; barcode: string | null; image: string | null } | null
  onCancel: () => void
  onSubmit: (extra: Choice & { name_uz?: string; unit_id?: string }) => Promise<void>
}) {
  const s = data?.res.suggestion ?? null
  const [mode, setMode] = useState<'suggest' | 'new' | 'pick'>('pick')
  const [chosen, setChosen] = useState<CategoryRef | null>(null)
  const [others, setOthers] = useState<CategoryRef[]>([])
  const [picked, setPicked] = useState<string | undefined>()
  const [nc, setNc] = useState<NewCategory | null>(null)
  const [editName, setEditName] = useState(false)
  const [unit, setUnit] = useState<string | undefined>()
  const [saving, setSaving] = useState(false)
  const units = useQuery({
    queryKey: ['/store/catalog/units', 'tasnif'],
    queryFn: () => api.get<{ items: (DictItem & { short_name: string })[] }>('/store/catalog/units').then((r) => r.items ?? []),
    enabled: !!data,
  })

  useEffect(() => {
    if (!data) return
    const sg = data.res.suggestion
    setChosen(sg?.category ?? null)
    setOthers(sg?.alternatives ?? [])
    setNc(sg?.new ?? null)
    setMode(sg?.category ? 'suggest' : sg?.new ? 'new' : 'pick')
    setPicked(undefined)
    setEditName(false)
    setUnit(undefined)
  }, [data])
  // Единица по умолчанию — как определил сервер (шт, весовые — кг).
  useEffect(() => {
    if (!data || unit) return
    const want = data.res.unit_short === 'кг' ? ['кг', 'kg'] : ['шт', 'dona']
    const u = units.data?.find((x) => want.includes(x.short_name))
    if (u) setUnit(u.id)
  }, [data, units.data, unit])

  const ready = mode === 'suggest' ? !!chosen : mode === 'new' ? !!nc?.name.trim() : !!picked
  const confirm = async () => {
    if (!ready) return
    setSaving(true)
    try {
      const choice: Choice = mode === 'suggest' ? { category_id: chosen!.id } : mode === 'new' ? { new_category: nc! } : { category_id: picked! }
      await onSubmit({ ...choice, name_uz: s?.name_uz || undefined, unit_id: unit })
    } finally {
      setSaving(false)
    }
  }

  const badge = (
    <Tag color="purple" bordered={false} style={{ fontWeight: 700, marginInlineEnd: 0 }}>
      <StarFilled /> {tr('Предложил Super Market', 'Super Market taklif qildi')}
    </Tag>
  )
  const title = mode === 'new' ? tr('Новая категория для товара', 'Mahsulot uchun yangi kategoriya') : s ? tr('Подтвердите категорию', 'Kategoriyani tasdiqlang') : tr('Выберите категорию', 'Kategoriyani tanlang')
  const sub =
    mode === 'new'
      ? tr('Подходящей категории в базе нет. Super Market предлагает создать новую — она появится в центральной базе, и туда же встанет товар.', 'Bazada mos kategoriya yoʻq. Super Market yangisini yaratishni taklif qiladi — u markaziy bazada paydo boʻladi va mahsulot oʻsha yerga tushadi.')
      : s && mode === 'suggest'
        ? tr('По коду ИКПУ категорию определить не получилось — Super Market подобрал самую подходящую из базы.', 'MXIK kodi boʻyicha kategoriyani aniqlab boʻlmadi — Super Market bazadan eng moslini tanladi.')
        : tr('Товар из каталога ИКПУ попадёт в центральную базу. Категорию по коду ИКПУ определить не получилось — выберите её один раз.', 'MXIK katalogidagi mahsulot markaziy bazaga tushadi. Kategoriyani MXIK kodi boʻyicha aniqlab boʻlmadi — uni bir marta tanlang.')

  return (
    <Modal
      open={!!data}
      width={560}
      title={title}
      onCancel={onCancel}
      destroyOnHidden
      footer={
        <Space>
          <Button onClick={onCancel}>{tr('Отмена', 'Bekor qilish')}</Button>
          <Button type="primary" icon={<PlusOutlined />} disabled={!ready} loading={saving} onClick={confirm}>
            {mode === 'new' ? tr('Создать категорию и добавить', 'Kategoriya yaratish va qoʻshish') : tr('Добавить в «Мои товары»', '«Mahsulotlarim»ga qoʻshish')}
          </Button>
        </Space>
      }
    >
      {data && (
        <Flex vertical gap={16}>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            {sub}
          </Typography.Text>
          <Flex gap={12} align="center" style={{ background: '#F9FAFB', border: '1px solid #EAECF0', borderRadius: 12, padding: 14 }}>
            <Thumb src={data.image} size={64} />
            <div style={{ minWidth: 0 }}>
              <Typography.Text strong style={{ fontSize: 15, display: 'block' }}>
                {data.res.name}
              </Typography.Text>
              <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block' }}>
                {[data.barcode, `${tr('ИКПУ', 'MXIK')} ${data.ikpu}`].filter(Boolean).join(' · ')}
              </Typography.Text>
            </div>
          </Flex>

          <div>
            <Flex align="center" gap={8} style={{ marginBottom: 6 }}>
              <Typography.Text strong style={{ fontSize: 13, color: '#344054' }}>
                {tr('Категория в Super Market', 'Super Market kategoriyasi')} <span style={{ color: '#E11D2A' }}>*</span>
              </Typography.Text>
              {s && mode !== 'pick' && badge}
            </Flex>

            {mode === 'suggest' && chosen && (
              <>
                <Flex align="center" gap={12} style={{ border: '1.5px solid #84ADFF', borderRadius: 10, padding: '12px 14px' }}>
                  <TagsOutlined style={{ color: '#1570EF', fontSize: 20 }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <Typography.Text strong style={{ fontSize: 15, display: 'block' }}>
                      {chosen.section} › {chosen.name}
                    </Typography.Text>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {chosen.section_uz || chosen.section} › {chosen.name_uz || chosen.name}
                    </Typography.Text>
                  </div>
                  <Button type="link" style={{ padding: 0, fontWeight: 700 }} onClick={() => setMode('pick')}>
                    {tr('Изменить', 'Oʻzgartirish')}
                  </Button>
                </Flex>
                {others.length > 0 && (
                  <Flex align="center" gap={6} wrap style={{ marginTop: 8 }}>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {tr('Ещё подходят:', 'Yana mos keladi:')}
                    </Typography.Text>
                    {others.map((o) => (
                      <Tag
                        key={o.id}
                        bordered={false}
                        style={{ cursor: 'pointer', fontWeight: 600 }}
                        onClick={() => {
                          setOthers((list) => [...list.filter((x) => x.id !== o.id), chosen])
                          setChosen(o)
                        }}
                      >
                        {catText(o)}
                      </Tag>
                    ))}
                  </Flex>
                )}
              </>
            )}

            {mode === 'new' && nc && (
              <>
                <Flex align="start" gap={12} style={{ border: '1.5px dashed #9B8AFB', background: '#F9F8FF', borderRadius: 10, padding: '12px 14px' }}>
                  <FolderAddOutlined style={{ color: '#6938EF', fontSize: 20, marginTop: 2 }} />
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <Flex align="center" gap={8} justify="space-between">
                      <Typography.Text strong style={{ fontSize: 15 }}>
                        {nc.parent_name} › {nc.name}
                      </Typography.Text>
                      <Tag color="success" bordered={false} style={{ marginInlineEnd: 0 }}>
                        {tr('новая', 'yangi')}
                      </Tag>
                    </Flex>
                    <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block' }}>
                      {nc.parent_name_uz || nc.parent_name} › {nc.name_uz || nc.name}
                    </Typography.Text>
                    <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 4 }}>
                      {nc.parent_id
                        ? tr(`Раздел «${nc.parent_name}» уже есть — создастся только подкатегория. Название на uz и ru Super Market заполнил сам, их можно поправить.`, `«${nc.parent_name_uz || nc.parent_name}» boʻlimi allaqachon bor — faqat kichik kategoriya yaratiladi. Nomlarini (uz va ru) Super Market oʻzi toʻldirdi, ularni tuzatish mumkin.`)
                        : tr('Создастся новый раздел и подкатегория в нём. Названия на uz и ru Super Market заполнил сам, их можно поправить.', 'Yangi boʻlim va uning ichida kichik kategoriya yaratiladi. Nomlarini (uz va ru) Super Market oʻzi toʻldirdi, ularni tuzatish mumkin.')}
                    </Typography.Text>
                    {editName ? (
                      <Flex vertical gap={6} style={{ marginTop: 8 }}>
                        <Input size="small" addonBefore="ru" value={nc.name} maxLength={100} onChange={(e) => setNc({ ...nc, name: e.target.value })} />
                        <Input size="small" addonBefore="uz" value={nc.name_uz} maxLength={100} onChange={(e) => setNc({ ...nc, name_uz: e.target.value })} />
                      </Flex>
                    ) : (
                      <Button type="link" size="small" style={{ padding: 0, fontWeight: 700, marginTop: 4 }} onClick={() => setEditName(true)}>
                        {tr('Изменить название', 'Nomini oʻzgartirish')}
                      </Button>
                    )}
                  </div>
                </Flex>
                <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 8 }}>
                  {tr('Не подходит?', 'Mos emasmi?')}{' '}
                  <a onClick={() => setMode('pick')} style={{ fontWeight: 700 }}>
                    {tr('Выбрать существующую категорию', 'Mavjud kategoriyani tanlash')}
                  </a>
                </Typography.Text>
              </>
            )}

            {mode === 'pick' && (
              <>
                <RemoteSelect<DictItem & { parent_name?: string | null }>
                  path="/store/catalog/categories"
                  search
                  filter={(c) => !!c.parent_id}
                  label={(c) => (c.parent_name ? `${c.parent_name} › ${c.name}` : c.name)}
                  value={picked}
                  onChange={(v) => setPicked(v as string)}
                  placeholder={tr('Выберите категорию', 'Kategoriyani tanlang')}
                  style={{ width: '100%' }}
                  autoFocus
                />
                {s && (s.category || s.new) && (
                  <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 8 }}>
                    <a onClick={() => setMode(s.category ? 'suggest' : 'new')} style={{ fontWeight: 700 }}>
                      {tr('Вернуть предложение Super Market', 'Super Market taklifiga qaytish')}
                    </a>
                  </Typography.Text>
                )}
              </>
            )}
          </div>

          <div>
            <Typography.Text strong style={{ fontSize: 13, color: '#344054', display: 'block', marginBottom: 6 }}>
              {tr('Единица', 'Oʻlchov birligi')}
            </Typography.Text>
            <RemoteSelect<DictItem & { short_name: string }>
              path="/store/catalog/units"
              label={(u) => `${u.name} (${u.short_name})`}
              value={unit}
              onChange={(v) => setUnit(v as string)}
              style={{ width: '100%' }}
            />
          </div>
        </Flex>
      )}
    </Modal>
  )
}
