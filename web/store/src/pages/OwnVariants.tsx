// Вариации своих товаров (Figma «Панель магазина · Вариации своих товаров»,
// В1–В2): вкладка «Вариации» в «Товарах» и в «Начале работы». Super Market
// предлагает группы своих товаров магазина («бренд + линейка», внутри — до
// двух переключателей: вес/объём/размер и вкус/цвет…) и вход своих товаров в
// подтверждённую группу общего каталога. Магазин правит значения, снимает
// лишние товары и подтверждает сам — это касается только его сети. У группы
// общего каталога название, переключатели и её товары не меняются.
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { App, AutoComplete, Button, Card, Checkbox, Empty, Flex, Image, Input, Modal, Pagination, Space, Spin, Table, Tag, Tooltip, Typography, type TableColumnsType } from 'antd'
import Icon, {
  CheckOutlined,
  CloseOutlined,
  DownOutlined,
  ExclamationCircleFilled,
  ForkOutlined,
  LockOutlined,
  MinusCircleOutlined,
  PictureOutlined,
  PlusCircleOutlined,
  PlusOutlined,
  RightOutlined,
  SafetyCertificateFilled,
  WarningFilled,
} from '@ant-design/icons'
import { LoadError, RemoteSelect, api, errorText, plural, tr } from '@sm/shared'
import { useStore } from '../ctx'
import type { Product } from '../types'

export type OwnStatus = 'proposed' | 'confirmed' | 'rejected'

export interface OwnItem {
  product_id: string
  name: string
  image: string | null
  barcode: string
  weight: string
  weight_uz: string
  flavor: string
  flavor_uz: string
  included: boolean
  note: string
  other_group: string | null
  /** Свой товар сети (иначе — общий каталог). */
  own: boolean
  /** Товар группы общего каталога: показывается для сверки, не меняется. */
  locked: boolean
}

export interface OwnGroup {
  id: string
  name: string
  name_uz: string
  brand_name: string | null
  category_name: string | null
  status: OwnStatus
  source: 'ai' | 'manual'
  confidence: 'high' | 'check'
  note: string
  weight_label: string
  weight_label_uz: string
  flavor_label: string
  flavor_label_uz: string
  /** Свои товары входят в эту группу общего каталога. */
  base_group_id: string | null
  base_name: string | null
  items: OwnItem[]
}

export interface OwnGroupList {
  items: OwnGroup[]
  total: number
  counts: Partial<Record<OwnStatus, number>>
}

interface SuggestResult {
  running: boolean
  created: number
  checked: number
  ai: boolean
  more: boolean
  failed: number
  error: string
}

type Labels = Pick<OwnGroup, 'weight_label' | 'weight_label_uz' | 'flavor_label' | 'flavor_label_uz'>
type ItemPatch = Partial<Pick<OwnItem, 'weight' | 'weight_uz' | 'flavor' | 'flavor_uz' | 'included'>>

export const OWN_PATH = '/store/own-variant-groups'
const PAGE = 20
const LINE = '#eaecf0'
const MAX_LABEL = 30
const NONE = () => tr('Нет', 'Yoʻq')

function SparkleSvg() {
  return (
    <svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor" aria-hidden>
      <path d="M10 2.5l1.8 5.2 5.2 1.8-5.2 1.8L10 16.5l-1.8-5.2L3 9.5l5.2-1.8L10 2.5zM18 13l.9 2.6 2.6.9-2.6.9L18 20l-.9-2.6-2.6-.9 2.6-.9L18 13zM18.5 2l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6.6-1.6z" />
    </svg>
  )
}
export const Sparkle = ({ style }: { style?: CSSProperties }) => <Icon component={SparkleSvg} style={style} />

/** Готовые названия переключателей и их перевод. */
const SIZE_PRESETS = ['Вес', 'Объём', 'Количество', 'Размер']
const VARIANT_PRESETS = ['Вкус', 'Цвет', 'Аромат', 'Модель', 'Вид']
const PRESET_UZ: Record<string, string> = {
  Вес: 'Vazn',
  Объём: 'Hajm',
  Количество: 'Soni',
  Размер: 'Oʻlcham',
  Вкус: 'Taʼm',
  Цвет: 'Rang',
  Аромат: 'Hid',
  Модель: 'Model',
  Вид: 'Tur',
}

function distinct(values: string[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const v of values) {
    const t = v.trim()
    if (t && !seen.has(t.toLowerCase())) {
      seen.add(t.toLowerCase())
      out.push(t)
    }
  }
  return out
}

const comboKey = (g: Pick<OwnGroup, 'weight_label' | 'flavor_label'>, it: OwnItem) =>
  `${g.weight_label ? it.weight.trim().toLowerCase() : ''}|${g.flavor_label ? it.flavor.trim().toLowerCase() : ''}`

const goods = (n: number) => tr(`${n} ${plural(n, 'товар', 'товара', 'товаров')}`, `${n} ta mahsulot`)
const ownGoods = (n: number) => tr(`${n} ${plural(n, 'свой товар', 'своих товара', 'своих товаров')}`, `${n} ta oʻz mahsuloti`)

// ───────────────────────────────────────────────────────────── данные

/** Группы своих товаров: вкладка и страница. */
export function useOwnGroups(status: OwnStatus, page: number, q = '') {
  const params = { status, q: q.trim() || undefined, limit: PAGE, offset: (page - 1) * PAGE }
  return useQuery({
    queryKey: [OWN_PATH, params],
    queryFn: () => api.get<OwnGroupList>(OWN_PATH, params),
    placeholderData: keepPreviousData,
  })
}

/** «Найти новые группы»: разбор идёт на сервере в фоне — запускаем и опрашиваем. */
export function useOwnSuggest(onDone?: () => void) {
  const qc = useQueryClient()
  const { message } = App.useApp()
  const [running, setRunning] = useState(false)
  const reload = () => qc.invalidateQueries({ queryKey: [OWN_PATH] })
  const wait = async (first: SuggestResult) => {
    let r = first
    while (r.running) {
      await new Promise((res) => setTimeout(res, 3000))
      r = await api.get<SuggestResult>(`${OWN_PATH}/suggest`)
      if (r.running) void reload()
    }
    return r
  }
  const finish = async (r: SuggestResult) => {
    await reload()
    if (r.error) {
      message.error(r.error, 8)
      return
    }
    const text =
      r.created > 0
        ? tr(`Super Market нашёл групп: ${r.created}`, `Super Market ${r.created} ta guruh topdi`)
        : tr('Новых групп среди ваших товаров нет', 'Mahsulotlaringiz orasida yangi guruh yoʻq')
    message.success(r.more ? `${text}. ${tr('Ещё есть товары — нажмите ещё раз.', 'Yana mahsulotlar bor — yana bosing.')}` : text, r.more ? 8 : 5)
    onDone?.()
  }
  const start = async () => {
    setRunning(true)
    try {
      await finish(await wait(await api.post<SuggestResult>(`${OWN_PATH}/suggest`, {})))
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setRunning(false)
    }
  }
  // Разбор уже идёт (запустился сам после «Провести все») — дождаться его.
  useEffect(() => {
    let alive = true
    api
      .get<SuggestResult>(`${OWN_PATH}/suggest`)
      .then(async (r) => {
        if (!r.running || !alive) return
        setRunning(true)
        try {
          const done = await wait(r)
          if (alive) await reload()
          void done
        } finally {
          if (alive) setRunning(false)
        }
      })
      .catch(() => {})
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return { running, start }
}

// ───────────────────────────────────────────────────────────── В1: вкладка в «Товарах»

export function OwnVariantsTab() {
  const { can } = useStore()
  const manage = can('catalog.manage')
  const qc = useQueryClient()
  const [status, setStatus] = useState<OwnStatus>('proposed')
  const [q, setQ] = useState('')
  const [page, setPage] = useState(1)
  const [open, setOpen] = useState<Record<string, boolean>>({})
  useEffect(() => setPage(1), [status, q])
  const list = useOwnGroups(status, page, q)
  const suggest = useOwnSuggest(() => setStatus('proposed'))
  const data = list.data
  const counts = data?.counts ?? {}
  const items = data?.items ?? []
  const reload = () => qc.invalidateQueries({ queryKey: [OWN_PATH] })
  const replace = (g: OwnGroup) =>
    qc.setQueriesData<OwnGroupList>({ queryKey: [OWN_PATH] }, (old) =>
      old && Array.isArray(old.items) ? { ...old, items: old.items.map((x) => (x.id === g.id ? g : x)) } : old,
    )

  const subTab = (key: OwnStatus, title: string) => (
    <span
      role="button"
      onClick={() => setStatus(key)}
      style={{
        cursor: 'pointer',
        paddingBottom: 6,
        fontWeight: status === key ? 700 : 500,
        color: status === key ? '#101828' : '#667085',
        borderBottom: `2px solid ${status === key ? '#E11D2A' : 'transparent'}`,
      }}
    >
      {title} · {counts[key] ?? 0}
    </span>
  )

  return (
    <>
      <Flex align="center" gap={20} wrap style={{ marginBottom: 12 }}>
        <Flex gap={20} style={{ flex: 1 }} wrap>
          {subTab('proposed', tr('Предложения', 'Takliflar'))}
          {subTab('confirmed', tr('Подтверждённые', 'Tasdiqlangan'))}
          {subTab('rejected', tr('Отклонённые', 'Rad etilgan'))}
        </Flex>
        <Input.Search placeholder={tr('Группа или товар', 'Guruh yoki mahsulot')} allowClear onSearch={setQ} style={{ width: 220 }} />
        {manage && (
          <Button type="primary" icon={<Sparkle />} loading={suggest.running} onClick={suggest.start}>
            {suggest.running ? tr('Ищем группы…', 'Guruhlar qidirilmoqda…') : tr('Найти новые группы', 'Yangi guruhlarni topish')}
          </Button>
        )}
      </Flex>
      <InfoBar>
        {suggest.running && tr('Super Market проверяет ваши товары — это может занять пару минут. ', 'Super Market mahsulotlaringizni tekshirmoqda — bu bir necha daqiqa olishi mumkin. ')}
        {tr(
          'Super Market находит ваши товары одного бренда и линейки, которые отличаются только весом, вкусом, цветом и т. п. Группа = бренд + линейка, внутри — до двух переключателей. Разные линейки (Lay\'s и Lay\'s MAXX) — разные группы. Свой товар может войти в группу общего каталога.',
          'Super Market bir brend va liniyadagi faqat vazn, taʼm, rang va h.k. bilan farq qiladigan mahsulotlaringizni topadi. Guruh = brend + liniya, ichida — ikkitagacha almashtirgich. Turli liniyalar (Lay\'s va Lay\'s MAXX) — turli guruhlar. Oʻz mahsulotingiz umumiy katalog guruhiga kirishi mumkin.',
        )}
      </InfoBar>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Spin spinning={list.isFetching && !list.isLoading} delay={300}>
        {list.isLoading ? (
          <Card>
            <Flex justify="center" style={{ padding: 40 }}>
              <Spin />
            </Flex>
          </Card>
        ) : items.length === 0 ? (
          <Card>
            <Empty
              description={
                q.trim()
                  ? tr('Ничего не нашлось', 'Hech narsa topilmadi')
                  : status === 'proposed'
                    ? tr('Новых предложений нет. Нажмите «Найти новые группы» — Super Market проверит ваши товары.', 'Yangi takliflar yoʻq. «Yangi guruhlarni topish»ni bosing — Super Market mahsulotlaringizni tekshiradi.')
                    : status === 'confirmed'
                      ? tr('Подтверждённых групп пока нет', 'Tasdiqlangan guruhlar hozircha yoʻq')
                      : tr('Отклонённых групп нет', 'Rad etilgan guruhlar yoʻq')
              }
            />
          </Card>
        ) : (
          <Flex vertical gap={16}>
            {items.map((g, i) => (
              <OwnGroupCard
                key={g.id}
                group={g}
                manage={manage}
                open={open[g.id] ?? i === 0}
                onToggle={() => setOpen((o) => ({ ...o, [g.id]: !(o[g.id] ?? i === 0) }))}
                replace={replace}
                reload={reload}
                onSplit={(ng) => setOpen((o) => ({ ...o, [ng.id]: true }))}
              />
            ))}
          </Flex>
        )}
      </Spin>
      {data && data.total > PAGE && (
        <Flex justify="flex-end" style={{ marginTop: 16 }}>
          <Pagination current={page} pageSize={PAGE} total={data.total} onChange={setPage} showSizeChanger={false} />
        </Flex>
      )}
    </>
  )
}

export function InfoBar({ children }: { children: ReactNode }) {
  return (
    <Flex align="flex-start" gap={10} style={{ background: '#F4F3FF', color: '#3E1C96', borderRadius: 12, padding: '10px 14px', marginBottom: 16, fontSize: 13 }}>
      <Sparkle style={{ color: '#6938EF', fontSize: 16, marginTop: 2 }} />
      <span>{children}</span>
    </Flex>
  )
}

// ───────────────────────────────────────────────────────────── карточка группы

export function ConfidenceChip({ g }: { g: Pick<OwnGroup, 'confidence' | 'note' | 'source'> }) {
  const base = { display: 'inline-flex', alignItems: 'center', gap: 4, padding: '1px 8px', borderRadius: 10, fontSize: 12, fontWeight: 600 } as const
  if (g.confidence === 'check') {
    return (
      <span style={{ ...base, background: '#fffaeb', color: '#b54708' }}>
        <WarningFilled /> {g.note.trim() || tr('Проверьте значения', 'Qiymatlarni tekshiring')}
      </span>
    )
  }
  if (g.source === 'manual') return <span style={{ ...base, background: '#f2f4f7', color: '#475467' }}>{tr('Собрана вручную', 'Qoʻlda yigʻilgan')}</span>
  return (
    <span style={{ ...base, background: '#ecfdf3', color: '#067647' }}>
      <SafetyCertificateFilled /> {tr('Уверенность высокая', 'Ishonch yuqori')}
    </span>
  )
}

function Thumb({ src, dim }: { src: string | null; dim?: boolean }) {
  const box = { width: 36, height: 36, borderRadius: 8, flex: 'none', opacity: dim ? 0.5 : 1 } as const
  if (src) return <Image src={src} width={36} height={36} style={{ ...box, objectFit: 'cover' }} />
  return (
    <Flex align="center" justify="center" style={{ ...box, background: '#f2f4f7', color: '#98a2b3' }}>
      <PictureOutlined />
    </Flex>
  )
}

/** Строка «2 своих товара → в группу общего каталога · 150 г, 90 г». */
export function groupSummary(g: OwnGroup) {
  const own = g.items.filter((it) => !it.locked && it.included)
  const included = g.items.filter((it) => it.included)
  const weights = distinct(own.map((it) => it.weight))
  const flavors = distinct(own.map((it) => it.flavor))
  return [
    g.brand_name,
    g.category_name,
    g.base_group_id ? `${ownGoods(own.length)} → ${tr('в группу общего каталога', 'umumiy katalog guruhiga')}` : goods(included.length),
    g.weight_label && weights.length ? `${g.weight_label}: ${weights.join(', ')}` : null,
    g.flavor_label && flavors.length ? `${g.flavor_label}: ${flavors.length === 1 ? flavors[0] : flavors.length}` : null,
  ]
    .filter(Boolean)
    .join(' · ')
}

export function OwnGroupCard({
  group: g,
  manage,
  open,
  onToggle,
  replace,
  reload,
  onSplit,
  onDecided,
}: {
  group: OwnGroup
  manage: boolean
  open: boolean
  onToggle?: () => void
  replace: (g: OwnGroup) => void
  reload: () => Promise<unknown>
  onSplit?: (g: OwnGroup) => void
  /** Группу подтвердили или отклонили (окно в «Начале работы» закрывается). */
  onDecided?: () => void
}) {
  const { message, modal } = App.useApp()
  const [busy, setBusy] = useState<'' | 'confirm' | 'reject' | 'split'>('')
  const [splitting, setSplitting] = useState(false)
  const [picked, setPicked] = useState<string[]>([])
  const [adding, setAdding] = useState(false)
  const joined = !!g.base_group_id
  const editable = manage && !splitting

  const included = g.items.filter((it) => it.included)
  const ownIncluded = included.filter((it) => !it.locked)
  const weights = distinct(included.map((it) => it.weight))
  const flavors = distinct(included.map((it) => it.flavor))
  const allWeights = distinct(g.items.map((it) => it.weight))
  const allFlavors = distinct(g.items.map((it) => it.flavor))
  const hasWeight = !!g.weight_label
  const hasFlavor = !!g.flavor_label

  const dup = useMemo(() => {
    const n = new Map<string, number>()
    for (const it of g.items) if (it.included) n.set(comboKey(g, it), (n.get(comboKey(g, it)) ?? 0) + 1)
    return new Set([...n].filter(([, c]) => c > 1).map(([k]) => k))
  }, [g])

  const restore = async (prev: OwnGroup) => {
    try {
      replace(await api.get<OwnGroup>(`${OWN_PATH}/${g.id}`))
    } catch {
      replace(prev)
    }
  }
  const patch = async (body: { name?: string; name_uz?: string; items?: (ItemPatch & { product_id: string })[] } & Partial<Labels>) => {
    const prev = g
    const { items: _items, ...fields } = body
    void _items
    replace({
      ...g,
      ...Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined)),
      items: g.items.map((it) => {
        const ch = body.items?.find((x) => x.product_id === it.product_id)
        return ch ? { ...it, ...ch } : it
      }),
    })
    try {
      replace(await api.patch<OwnGroup>(`${OWN_PATH}/${g.id}`, body))
    } catch (e) {
      message.error(errorText(e))
      await restore(prev)
    }
  }
  const patchItem = (product_id: string, ch: ItemPatch) => patch({ items: [{ product_id, ...ch }] })

  const run = async (kind: typeof busy, fn: () => Promise<void>) => {
    setBusy(kind)
    try {
      await fn()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy('')
    }
  }
  const confirm = () =>
    run('confirm', async () => {
      await api.post<OwnGroup>(`${OWN_PATH}/${g.id}/confirm`)
      message.success(tr(`Группа «${g.name}» подтверждена`, `«${g.name}» guruhi tasdiqlandi`))
      await reload()
      onDecided?.()
    })
  const reject = () =>
    run('reject', async () => {
      await api.post<OwnGroup>(`${OWN_PATH}/${g.id}/reject`)
      message.success(
        g.status === 'confirmed' ? tr(`Группа «${g.name}» расформирована`, `«${g.name}» guruhi tarqatildi`) : tr(`Предложение «${g.name}» отклонено`, `«${g.name}» taklifi rad etildi`),
      )
      await reload()
      onDecided?.()
    })
  const disband = () =>
    modal.confirm({
      title: joined ? tr(`Вывести свои товары из «${g.name}»?`, `Oʻz mahsulotlaringizni «${g.name}»dan chiqarasizmi?`) : tr(`Расформировать группу «${g.name}»?`, `«${g.name}» guruhini tarqatasizmi?`),
      content: tr(
        'Товары снова станут отдельными в приложении и на кассе. Super Market больше не будет их предлагать.',
        'Mahsulotlar ilovada va kassada yana alohida boʻladi. Super Market ularni boshqa taklif qilmaydi.',
      ),
      okText: tr('Расформировать', 'Tarqatish'),
      okButtonProps: { danger: true },
      cancelText: tr('Отмена', 'Bekor qilish'),
      onOk: reject,
    })
  const split = () =>
    run('split', async () => {
      const r = await api.post<{ group: OwnGroup; new_group: OwnGroup }>(`${OWN_PATH}/${g.id}/split`, { product_ids: picked })
      message.success(tr(`Товары отделены в новую группу «${r.new_group.name}» — переименуйте её`, `Mahsulotlar yangi «${r.new_group.name}» guruhiga ajratildi — nomini oʻzgartiring`))
      setSplitting(false)
      setPicked([])
      onSplit?.(r.new_group)
      replace(r.group)
      await reload()
    })

  const enough = joined ? ownIncluded.length >= 1 : included.length >= 2
  const canConfirm = enough && dup.size === 0
  const confirmHint = !enough
    ? joined
      ? tr('Отметьте хотя бы один свой товар', 'Kamida bitta oʻz mahsulotingizni belgilang')
      : tr('Отметьте хотя бы два товара', 'Kamida ikkita mahsulotni belgilang')
    : dup.size
      ? tr('У двух товаров одинаковые значения переключателей', 'Ikki mahsulotning almashtirgich qiymatlari bir xil')
      : ''
  const letter = (g.brand_name || g.name).trim().charAt(0).toUpperCase() || '?'

  const valueCell = (it: OwnItem, kind: 'weight' | 'flavor') => {
    const label = kind === 'weight' ? g.weight_label : g.flavor_label
    const value = kind === 'weight' ? it.weight : it.flavor
    if (it.locked || !it.included || !editable) return <Typography.Text type="secondary">{value || '—'}</Typography.Text>
    return (
      <ValueEdit
        value={value}
        uz={kind === 'weight' ? it.weight_uz : it.flavor_uz}
        options={kind === 'weight' ? allWeights : allFlavors}
        placeholder={label.toLowerCase()}
        width={kind === 'weight' ? 120 : 180}
        error={dup.has(comboKey(g, it))}
        onSave={(v) => patchItem(it.product_id, kind === 'weight' ? { weight: v } : { flavor: v })}
        onSaveUz={(v) => patchItem(it.product_id, kind === 'weight' ? { weight_uz: v } : { flavor_uz: v })}
      />
    )
  }

  const columns: TableColumnsType<OwnItem> = [
    ...(splitting
      ? []
      : [
          {
            key: 'inc',
            width: 44,
            render: (_: unknown, it: OwnItem) =>
              it.locked ? (
                <Tooltip title={tr('Товар группы общего каталога — не меняется', 'Umumiy katalog guruhi mahsuloti — oʻzgarmaydi')}>
                  <LockOutlined style={{ color: '#98a2b3' }} />
                </Tooltip>
              ) : (
                <Checkbox checked={it.included} disabled={!editable} onChange={(e) => patchItem(it.product_id, { included: e.target.checked })} />
              ),
          },
        ]),
    { key: 'img', width: 52, render: (_, it) => <Thumb src={it.image} dim={!it.included} /> },
    {
      title: tr('ТОВАР', 'MAHSULOT'),
      key: 'name',
      render: (_, it) => (
        <div style={{ minWidth: 200 }}>
          <span style={{ color: it.included ? undefined : '#98a2b3' }}>{it.name}</span>
          {it.note.trim() && (
            <div style={{ color: '#c4320a', fontSize: 12 }}>
              <ExclamationCircleFilled /> {it.note}
            </div>
          )}
          {it.other_group && (
            <div style={{ color: '#d92d20', fontSize: 12 }}>
              <WarningFilled /> {tr(`уже в группе «${it.other_group}»`, `allaqachon «${it.other_group}» guruhida`)}
            </div>
          )}
        </div>
      ),
    },
    {
      title: tr('ОТКУДА', 'QAYERDAN'),
      key: 'own',
      width: 130,
      render: (_, it) =>
        it.own ? (
          <Tag color="blue" bordered={false}>
            {tr('свой', 'oʻziniki')}
          </Tag>
        ) : (
          <Tag color="green" bordered={false}>
            {tr('общий каталог', 'umumiy katalog')}
          </Tag>
        ),
    },
    ...(hasWeight ? [{ title: g.weight_label.toUpperCase(), key: 'weight', width: 150, render: (_: unknown, it: OwnItem) => valueCell(it, 'weight') }] : []),
    ...(hasFlavor ? [{ title: g.flavor_label.toUpperCase(), key: 'flavor', width: 210, render: (_: unknown, it: OwnItem) => valueCell(it, 'flavor') }] : []),
    {
      title: tr('ШТРИХКОД', 'SHTRIX-KOD'),
      dataIndex: 'barcode',
      width: 140,
      render: (b: string, it) => <span style={{ color: it.included ? '#475467' : '#98a2b3' }}>{b || '—'}</span>,
    },
    ...(splitting || !manage
      ? []
      : [
          {
            key: 'act',
            width: 48,
            align: 'center' as const,
            render: (_: unknown, it: OwnItem) =>
              it.locked ? null : it.included ? (
                <Tooltip title={tr('Убрать из группы — товар останется отдельным', 'Guruhdan olib tashlash — mahsulot alohida qoladi')}>
                  <Button type="text" size="small" icon={<MinusCircleOutlined style={{ color: '#98a2b3' }} />} onClick={() => patchItem(it.product_id, { included: false })} />
                </Tooltip>
              ) : (
                <Tooltip title={tr('Вернуть в группу', 'Guruhga qaytarish')}>
                  <Button type="text" size="small" icon={<PlusCircleOutlined style={{ color: '#667085' }} />} onClick={() => patchItem(it.product_id, { included: true })} />
                </Tooltip>
              ),
          },
        ]),
  ]

  const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

  return (
    <Card style={{ borderRadius: 16, border: `1px solid ${LINE}` }} styles={{ body: { padding: 0 } }}>
      <Flex align="center" gap={12} wrap style={{ padding: '14px 20px', cursor: onToggle ? 'pointer' : undefined }} onClick={onToggle}>
        {onToggle && <Button type="text" size="small" icon={open ? <DownOutlined /> : <RightOutlined />} aria-label={open ? tr('Свернуть', 'Yigʻish') : tr('Развернуть', 'Ochish')} />}
        <Flex align="center" justify="center" style={{ width: 36, height: 36, borderRadius: 10, background: '#fdeced', color: '#d92d20', fontWeight: 800, fontSize: 16, flex: 'none' }}>
          {letter}
        </Flex>
        <div style={{ flex: 1, minWidth: 220 }}>
          <Flex align="center" gap={8} wrap>
            <span style={{ fontWeight: 800, fontSize: 16, color: '#101828' }}>{g.name}</span>
            <ConfidenceChip g={g} />
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {groupSummary(g)}
          </Typography.Text>
        </div>
        {manage && (
          <Space onClick={stop} wrap>
            {g.status === 'proposed' && (
              <Button icon={<CloseOutlined />} loading={busy === 'reject'} disabled={!!busy && busy !== 'reject'} onClick={reject}>
                {tr('Отклонить', 'Rad etish')}
              </Button>
            )}
            {g.status === 'confirmed' && (
              <Button icon={<CloseOutlined />} loading={busy === 'reject'} disabled={!!busy && busy !== 'reject'} onClick={disband}>
                {tr('Расформировать', 'Tarqatish')}
              </Button>
            )}
            {g.status !== 'confirmed' && (
              <Tooltip title={confirmHint}>
                <Button type="primary" icon={<CheckOutlined />} loading={busy === 'confirm'} disabled={!canConfirm || (!!busy && busy !== 'confirm') || splitting} onClick={confirm}>
                  {tr('Подтвердить группу', 'Guruhni tasdiqlash')}
                </Button>
              </Tooltip>
            )}
          </Space>
        )}
      </Flex>

      {open && (
        <>
          <Flex align="center" gap={12} wrap style={{ padding: '0 20px 16px 20px' }}>
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              {tr('Название группы', 'Guruh nomi')}
            </Typography.Text>
            {joined || !editable ? (
              <>
                <Input value={g.name} disabled style={{ width: 240 }} />
                {joined && <Typography.Text type="secondary" style={{ fontSize: 12 }}>{tr('общий каталог — не меняется', 'umumiy katalog — oʻzgarmaydi')}</Typography.Text>}
              </>
            ) : (
              <>
                <TextEdit value={g.name} placeholder={tr('Название', 'Nomi')} width={240} required onSave={(v) => patch({ name: v })} />
                <TextEdit value={g.name_uz} placeholder="Nomi (oʻzbekcha)" prefix="uz:" width={220} onSave={(v) => patch({ name_uz: v })} />
              </>
            )}
            <Typography.Text type="secondary" style={{ fontSize: 13, marginLeft: 8 }}>
              {tr('Переключатели', 'Almashtirgichlar')}
            </Typography.Text>
            {joined || !editable ? (
              <Space size={6}>
                {[g.weight_label, g.flavor_label].filter(Boolean).map((l) => (
                  <Tag key={l} bordered={false} style={{ fontWeight: 600 }}>
                    {l}
                  </Tag>
                ))}
              </Space>
            ) : (
              <>
                <SwitchEdit kind="size" label={g.weight_label} uz={g.weight_label_uz} other={g.flavor_label} values={weights.length} onSave={(l, u) => patch({ weight_label: l, weight_label_uz: u })} />
                <SwitchEdit kind="variant" label={g.flavor_label} uz={g.flavor_label_uz} other={g.weight_label} values={flavors.length} onSave={(l, u) => patch({ flavor_label: l, flavor_label_uz: u })} />
              </>
            )}
          </Flex>
          <div style={{ borderTop: `1px solid ${LINE}` }}>
            <Table<OwnItem>
              rowKey="product_id"
              size="middle"
              columns={columns}
              dataSource={g.items}
              pagination={false}
              scroll={{ x: true }}
              onRow={(it) => ({ style: it.included ? undefined : { background: '#fcfcfd' } })}
              rowSelection={
                splitting ? { selectedRowKeys: picked, onChange: (keys) => setPicked(keys.map(String)), getCheckboxProps: (it) => ({ disabled: it.locked }) } : undefined
              }
            />
          </div>
          <Flex align="center" gap={12} wrap style={{ padding: '10px 20px', borderTop: `1px solid ${LINE}` }}>
            {splitting ? (
              <>
                <Typography.Text>{tr('Отметьте товары, которые уйдут в новую группу', 'Yangi guruhga oʻtadigan mahsulotlarni belgilang')}</Typography.Text>
                <Button type="primary" icon={<ForkOutlined />} loading={busy === 'split'} disabled={picked.length === 0 || picked.length >= g.items.length} onClick={split}>
                  {tr('Отделить', 'Ajratish')}
                  {picked.length ? ` (${picked.length})` : ''}
                </Button>
                <Button
                  onClick={() => {
                    setSplitting(false)
                    setPicked([])
                  }}
                >
                  {tr('Отмена', 'Bekor qilish')}
                </Button>
              </>
            ) : (
              manage && (
                <>
                  <Button type="link" danger icon={<PlusOutlined />} style={{ paddingLeft: 0, fontWeight: 600 }} onClick={() => setAdding(true)}>
                    {tr('Добавить свой товар в группу', 'Guruhga oʻz mahsulotini qoʻshish')}
                  </Button>
                  {g.status === 'proposed' && !joined && g.items.length > 1 && (
                    <Button type="text" icon={<ForkOutlined />} style={{ fontWeight: 600 }} onClick={() => setSplitting(true)}>
                      {tr('Разбить группу', 'Guruhni boʻlish')}
                    </Button>
                  )}
                </>
              )
            )}
            <Typography.Text type="secondary" style={{ fontSize: 12, marginLeft: 'auto', maxWidth: 520 }}>
              {joined
                ? tr(
                    'Значения Super Market взял из названий — их можно поправить. Снятая галочка — товар остаётся отдельным. У товаров общего каталога значения не меняются.',
                    'Qiymatlarni Super Market nomlardan oldi — ularni tuzatish mumkin. Belgi olib tashlansa — mahsulot alohida qoladi. Umumiy katalog mahsulotlarining qiymatlari oʻzgarmaydi.',
                  )
                : tr(
                    'Значения Super Market взял из названий — их можно поправить. Снятая галочка — товар остаётся отдельным.',
                    'Qiymatlarni Super Market nomlardan oldi — ularni tuzatish mumkin. Belgi olib tashlansa — mahsulot alohida qoladi.',
                  )}
            </Typography.Text>
          </Flex>
        </>
      )}
      <AddOwnItemModal
        open={adding}
        group={g}
        onClose={() => setAdding(false)}
        onAdded={(ng) => {
          setAdding(false)
          replace(ng)
        }}
      />
    </Card>
  )
}

// ───────────────────────────────────────────────────────────── поля правки

function SwitchEdit({
  kind,
  label,
  uz,
  other,
  values,
  onSave,
}: {
  kind: 'size' | 'variant'
  label: string
  uz: string
  other: string
  values: number
  onSave: (label: string, uz: string) => void
}) {
  const { message } = App.useApp()
  const presets = kind === 'size' ? SIZE_PRESETS : VARIANT_PRESETS
  const none = NONE()
  const shown = label || none
  const [v, setV] = useState(shown)
  const focused = useRef(false)
  const latest = useRef(shown)
  const sent = useRef<string | null>(null)
  useEffect(() => {
    sent.current = null
    if (!focused.current) {
      setV(shown)
      latest.current = shown
    }
  }, [shown])
  const change = (x: string) => {
    latest.current = x
    setV(x)
  }
  const revert = () => change(shown)
  const commit = () => {
    const raw = latest.current.trim()
    if (!raw) return revert()
    const preset = presets.find((p) => p.toLowerCase() === raw.toLowerCase())
    const off = raw.toLowerCase() === none.toLowerCase() || raw.toLowerCase() === 'нет'
    const next = off ? '' : (preset ?? raw.charAt(0).toUpperCase() + raw.slice(1)).slice(0, MAX_LABEL)
    if (next === label || next === sent.current) {
      if (next !== raw) change(next || none)
      return
    }
    if (!next && !other) {
      message.error(tr('У группы должен остаться хотя бы один переключатель', 'Guruhda kamida bitta almashtirgich qolishi kerak'))
      return revert()
    }
    const nextUz = !next ? '' : (PRESET_UZ[next] ?? (label && !PRESET_UZ[label] ? uz : ''))
    sent.current = next
    if (next !== raw) change(next || none)
    onSave(next, nextUz)
  }
  const custom = !!label && !PRESET_UZ[label]
  const hint = !label
    ? kind === 'size'
      ? tr('У группы нет переключателя веса, объёма или размера', 'Guruhda vazn, hajm yoki oʻlcham almashtirgichi yoʻq')
      : tr('У группы нет переключателя вкуса, цвета и т. п.', 'Guruhda taʼm, rang va h.k. almashtirgichi yoʻq')
    : values > 1
      ? tr(`В приложении будет переключатель «${label.toLowerCase()}»`, `Ilovada «${label.toLowerCase()}» almashtirgichi boʻladi`)
      : tr(`У всех отмеченных товаров одно значение «${label.toLowerCase()}»`, `Belgilangan barcha mahsulotlarda «${label.toLowerCase()}» qiymati bitta`)
  return (
    <Flex align="center" gap={6}>
      <Tooltip title={hint}>
        <AutoComplete
          value={v}
          size="small"
          style={{ width: 130 }}
          placeholder={kind === 'size' ? tr('вес, объём…', 'vazn, hajm…') : tr('вкус, цвет…', 'taʼm, rang…')}
          maxLength={MAX_LABEL}
          variant={label ? 'outlined' : 'filled'}
          options={[...presets.map((p) => ({ value: p })), { value: none, disabled: !other, label: <span style={{ color: '#98a2b3' }}>{none} — {tr('без переключателя', 'almashtirgichsiz')}</span> }]}
          filterOption={false}
          onChange={change}
          onSelect={(x: string) => {
            change(x)
            commit()
          }}
          onFocus={() => (focused.current = true)}
          onBlur={() => {
            focused.current = false
            commit()
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') setTimeout(commit, 0)
          }}
        />
      </Tooltip>
      {custom && <TextEdit value={uz} placeholder="nomi" prefix="uz:" width={110} maxLength={MAX_LABEL} onSave={(x) => onSave(label, x)} />}
    </Flex>
  )
}

function TextEdit({
  value,
  onSave,
  placeholder,
  prefix,
  width,
  required,
  maxLength = 120,
}: {
  value: string
  onSave: (v: string) => void
  placeholder?: string
  prefix?: ReactNode
  width: number
  required?: boolean
  maxLength?: number
}) {
  const [v, setV] = useState(value)
  const focused = useRef(false)
  useEffect(() => {
    if (!focused.current) setV(value)
  }, [value])
  const commit = () => {
    const t = v.trim()
    if (required && !t) {
      setV(value)
      return
    }
    if (t !== value.trim()) onSave(t)
  }
  return (
    <Input
      value={v}
      placeholder={placeholder}
      prefix={prefix ? <Typography.Text type="secondary" style={{ fontSize: 12 }}>{prefix}</Typography.Text> : undefined}
      maxLength={maxLength}
      style={{ width }}
      onChange={(e) => setV(e.target.value)}
      onFocus={() => (focused.current = true)}
      onBlur={() => {
        focused.current = false
        commit()
      }}
      onPressEnter={(e) => e.currentTarget.blur()}
    />
  )
}

function ValueEdit({
  value,
  uz,
  options,
  placeholder,
  width,
  error,
  onSave,
  onSaveUz,
}: {
  value: string
  uz: string
  options: string[]
  placeholder: string
  width: number
  error?: boolean
  onSave: (v: string) => void
  onSaveUz: (v: string) => void
}) {
  const [v, setV] = useState(value)
  const focused = useRef(false)
  const sent = useRef<string | null>(null)
  const latest = useRef(value)
  useEffect(() => {
    sent.current = null
    if (!focused.current) {
      setV(value)
      latest.current = value
    }
  }, [value])
  const change = (x: string) => {
    latest.current = x
    setV(x)
  }
  const commit = () => {
    const t = latest.current.trim()
    if (t === value.trim() || t === sent.current) return
    sent.current = t
    onSave(t)
  }
  return (
    <div>
      <Tooltip title={error ? tr('Такие значения уже есть у другого товара группы', 'Bunday qiymatlar guruhning boshqa mahsulotida bor') : ''}>
        <AutoComplete
          value={v}
          size="small"
          placeholder={placeholder}
          status={error ? 'error' : undefined}
          style={{ width }}
          options={options.map((o) => ({ value: o }))}
          filterOption={false}
          onChange={change}
          onSelect={(x: string) => {
            change(x)
            commit()
          }}
          onFocus={() => (focused.current = true)}
          onBlur={() => {
            focused.current = false
            commit()
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') setTimeout(commit, 0)
          }}
        />
      </Tooltip>
      <Typography.Text
        type="secondary"
        style={{ fontSize: 11, display: 'block', marginTop: 2 }}
        editable={{
          text: uz,
          tooltip: tr('Перевод на узбекский', 'Oʻzbekcha tarjima'),
          triggerType: ['text', 'icon'],
          onChange: (x) => {
            if (x.trim() !== uz.trim()) onSaveUz(x.trim())
          },
        }}
      >
        {uz.trim() ? `uz: ${uz}` : 'uz: —'}
      </Typography.Text>
    </div>
  )
}

// ───────────────────────────────────────────────────────────── добавить свой товар

function AddOwnItemModal({ open, group, onClose, onAdded }: { open: boolean; group: OwnGroup; onClose: () => void; onAdded: (g: OwnGroup) => void }) {
  const { message } = App.useApp()
  const { storeId } = useStore()
  const [id, setId] = useState<string>()
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (open) setId(undefined)
  }, [open])
  const exclude = useMemo(() => new Set(group.items.map((it) => it.product_id)), [group.items])
  const add = async () => {
    if (!id) return
    setBusy(true)
    try {
      const g = await api.post<OwnGroup>(`${OWN_PATH}/${group.id}/items`, { product_id: id })
      message.success(tr('Товар добавлен — проверьте значения переключателей', 'Mahsulot qoʻshildi — almashtirgich qiymatlarini tekshiring'))
      onAdded(g)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <Modal
      open={open}
      title={tr(`Добавить свой товар в «${group.name}»`, `«${group.name}»ga oʻz mahsulotini qoʻshish`)}
      okText={tr('Добавить', 'Qoʻshish')}
      cancelText={tr('Отмена', 'Bekor qilish')}
      okButtonProps={{ disabled: !id }}
      confirmLoading={busy}
      onOk={add}
      onCancel={onClose}
      destroyOnHidden
    >
      <Typography.Paragraph type="secondary">
        {tr('Только свои товары магазина. Значения переключателей Super Market возьмёт из названия — их можно поправить.', 'Faqat doʻkonning oʻz mahsulotlari. Almashtirgich qiymatlarini Super Market nomdan oladi — ularni tuzatish mumkin.')}
      </Typography.Paragraph>
      <RemoteSelect<Product & Record<string, unknown>>
        path="/store/products"
        params={{ store_id: storeId }}
        search
        label={(p) => p.name}
        filter={(p) => !!p.network_id && !exclude.has(p.id)}
        placeholder={tr('Название или штрихкод', 'Nomi yoki shtrix-kod')}
        value={id}
        onChange={(v) => setId(v as string | undefined)}
        allowClear
        style={{ width: '100%' }}
      />
    </Modal>
  )
}

// ───────────────────────────────────────────────────────────── В2: «Начало работы»

/**
 * Вкладка «Вариации» в правой колонке шага 1: найденные группы коротким
 * списком, «Проверить» открывает группу окном поверх (как во вкладке
 * «Вариации» в «Товарах»).
 */
export function OwnVariantsStart() {
  const { can } = useStore()
  const manage = can('catalog.manage')
  const qc = useQueryClient()
  const [page, setPage] = useState(1)
  const list = useOwnGroups('proposed', page)
  const suggest = useOwnSuggest()
  const [openId, setOpenId] = useState<string | null>(null)
  const items = list.data?.items ?? []
  const total = list.data?.total ?? 0
  const opened = items.find((g) => g.id === openId) ?? null
  const reload = () => qc.invalidateQueries({ queryKey: [OWN_PATH] })
  const replace = (g: OwnGroup) =>
    qc.setQueriesData<OwnGroupList>({ queryKey: [OWN_PATH] }, (old) =>
      old && Array.isArray(old.items) ? { ...old, items: old.items.map((x) => (x.id === g.id ? g : x)) } : old,
    )
  useEffect(() => {
    if (page > 1 && total > 0 && (page - 1) * PAGE >= total) setPage(Math.ceil(total / PAGE))
  }, [page, total])
  return (
    <>
      <div style={{ padding: '12px 20px 0' }}>
        <InfoBar>
          {tr(
            'Super Market нашёл товары одного бренда и линейки, которые отличаются только весом, вкусом или цветом. Объедините их — в приложении покупатель увидит одну карточку с выбором, а цену можно ставить на вес.',
            'Super Market faqat vazn, taʼm yoki rang bilan farq qiladigan bir brend va liniyadagi mahsulotlarni topdi. Ularni birlashtiring — ilovada xaridor tanlovli bitta kartochkani koʻradi, narxni esa vaznga qoʻyish mumkin.',
          )}
        </InfoBar>
      </div>
      <LoadError error={list.error} retry={() => list.refetch()} />
      {list.isLoading ? (
        <Flex justify="center" style={{ padding: 24 }}>
          <Spin />
        </Flex>
      ) : items.length === 0 ? (
        <Typography.Paragraph type="secondary" style={{ padding: '4px 20px 12px', margin: 0 }}>
          {tr('Групп для проверки нет.', 'Tekshiriladigan guruhlar yoʻq.')}
        </Typography.Paragraph>
      ) : (
        items.map((g) => (
          <Flex key={g.id} align="center" gap={14} style={{ padding: '12px 20px', borderBottom: `1px solid ${LINE}` }}>
            <Flex align="center" justify="center" style={{ width: 40, height: 40, borderRadius: 10, background: '#fdeced', color: '#d92d20', fontWeight: 800, fontSize: 16, flex: 'none' }}>
              {(g.brand_name || g.name).trim().charAt(0).toUpperCase() || '?'}
            </Flex>
            <div style={{ flex: 1, minWidth: 0 }}>
              <Flex align="center" gap={8} wrap>
                <Typography.Text strong>{g.name}</Typography.Text>
                <ConfidenceChip g={g} />
              </Flex>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {groupSummary(g)}
              </Typography.Text>
            </div>
            <Button type="primary" size="small" onClick={() => setOpenId(g.id)}>
              {tr('Проверить', 'Tekshirish')}
            </Button>
          </Flex>
        ))
      )}
      {total > PAGE && (
        <Flex justify="center" style={{ padding: '12px 20px' }}>
          <Pagination size="small" current={page} pageSize={PAGE} total={total} onChange={setPage} showSizeChanger={false} />
        </Flex>
      )}
      <Flex align="center" gap={12} wrap style={{ padding: '12px 20px 14px' }}>
        <Typography.Text type="secondary" style={{ fontSize: 12, flex: 1, minWidth: 220 }}>
          {tr('Новые свои товары Super Market проверяет сам — после «Провести все» и раз в день.', 'Yangi oʻz mahsulotlarini Super Market oʻzi tekshiradi — «Hammasini oʻtkazish»dan soʻng va kuniga bir marta.')}
        </Typography.Text>
        {manage && (
          <Button icon={<Sparkle />} size="small" loading={suggest.running} onClick={suggest.start}>
            {suggest.running ? tr('Ищем группы…', 'Guruhlar qidirilmoqda…') : tr('Найти новые группы', 'Yangi guruhlarni topish')}
          </Button>
        )}
      </Flex>
      <Modal open={!!opened} width={1100} footer={null} title={null} onCancel={() => setOpenId(null)} destroyOnHidden styles={{ body: { paddingTop: 24 } }}>
        {opened && <OwnGroupCard group={opened} manage={manage} open replace={replace} reload={reload} onDecided={() => setOpenId(null)} />}
      </Modal>
    </>
  )
}
