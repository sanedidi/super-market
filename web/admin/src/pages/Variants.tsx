// Каталог → Вариации (Figma «ВВ2 · Супер-админ: Вариации»): Super Market
// предлагает группы «бренд + линейка», внутри которых товары отличаются
// только весом и вкусом; супер-админ правит вес/вкус, снимает лишние товары
// и подтверждает группу (или отклоняет / расформировывает).
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  App,
  AutoComplete,
  Button,
  Card,
  Checkbox,
  Empty,
  Flex,
  Form,
  Image,
  Input,
  Modal,
  Pagination,
  Space,
  Spin,
  Table,
  Tabs,
  Tooltip,
  Typography,
  type TableColumnsType,
} from 'antd'
import Icon, {
  CheckOutlined,
  CloseOutlined,
  DownOutlined,
  ExclamationCircleFilled,
  ForkOutlined,
  MinusCircleOutlined,
  PictureOutlined,
  PlusCircleOutlined,
  PlusOutlined,
  RightOutlined,
  SafetyCertificateFilled,
  ThunderboltOutlined,
  WarningFilled,
} from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, api, errorText, pageItemRender } from '@sm/shared'
import { useUrlState } from '../hooks'

type Status = 'proposed' | 'confirmed' | 'rejected'

interface Item {
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
  /** Название другой подтверждённой группы, где товар уже есть. */
  other_group: string | null
}

interface Group {
  id: string
  name: string
  name_uz: string
  brand_id: string | null
  brand_name: string | null
  category_id: string | null
  category_name: string | null
  status: Status
  source: 'ai' | 'manual'
  confidence: 'high' | 'check'
  note: string
  decided_at: string | null
  created_at: string
  stores_count: number
  items: Item[]
}

interface GroupList {
  items: Group[]
  total: number
  counts: Partial<Record<Status, number>>
}

/** Состояние фонового разбора «Найти новые группы». */
interface SuggestResult {
  running: boolean
  created: number
  checked: number
  ai: boolean
  more: boolean
  failed: number
  error: string
  started_at: string | null
  finished_at: string | null
}

/** Товар общего каталога из /admin/products (для поиска). */
interface CatalogProduct extends Record<string, unknown> {
  id: string
  name: string
  network_id: string | null
  brand_name: string | null
  images: string[] | null
  barcodes: string[] | null
}

type ItemPatch = Partial<Pick<Item, 'weight' | 'weight_uz' | 'flavor' | 'flavor_uz' | 'included'>>

/** Значок «искры» (ИИ) из макета — в @ant-design/icons такого нет. */
function SparkleSvg() {
  return (
    <svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor" aria-hidden>
      <path d="M10 2.5l1.8 5.2 5.2 1.8-5.2 1.8L10 16.5l-1.8-5.2L3 9.5l5.2-1.8L10 2.5zM18 13l.9 2.6 2.6.9-2.6.9L18 20l-.9-2.6-2.6-.9 2.6-.9L18 13zM18.5 2l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6.6-1.6z" />
    </svg>
  )
}
const Sparkle = ({ style }: { style?: CSSProperties }) => <Icon component={SparkleSvg} style={style} />

const PATH = '/admin/variant-groups'
const PAGE = 20
const LINE = '#eaecf0'

function plural(n: number, one: string, few: string, many: string) {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}

/** Различные непустые значения (без учёта регистра), в порядке появления. */
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

const comboKey = (it: Item) => `${it.weight.trim().toLowerCase()}|${it.flavor.trim().toLowerCase()}`

// ───────────────────────────────────────────────────────────── страница

export function Variants() {
  const qc = useQueryClient()
  const { message } = App.useApp()
  const [status = 'proposed', setStatus] = useUrlState('status', 'proposed')
  const [q, setQ] = useState('')
  const [page, setPage] = useState(1)
  const [open, setOpen] = useState<Record<string, boolean>>({})
  const [suggesting, setSuggesting] = useState(false)
  const [creating, setCreating] = useState(false)

  useEffect(() => setPage(1), [status, q])

  const params = { status, q: q.trim() || undefined, limit: PAGE, offset: (page - 1) * PAGE }
  const list = useQuery({
    queryKey: [PATH, params],
    queryFn: () => api.get<GroupList>(PATH, params),
    placeholderData: keepPreviousData,
  })
  const data = list.data
  const counts = data?.counts ?? {}

  /** Подставить группу из ответа сервера во все загруженные страницы списка. */
  const replace = (g: Group) =>
    qc.setQueriesData<GroupList>({ queryKey: [PATH] }, (old) =>
      old && Array.isArray(old.items) ? { ...old, items: old.items.map((x) => (x.id === g.id ? g : x)) } : old,
    )
  const reload = () => qc.invalidateQueries({ queryKey: [PATH] })

  // Разбор идёт на сервере в фоне (минуты): запускаем и опрашиваем состояние.
  const finishSuggest = async (r: SuggestResult) => {
    if (r.error) {
      message.error(r.error, 8)
      return
    }
    let text = `Найдено групп: ${r.created}`
    if (!r.ai) text += ' — по названиям, ИИ-сервис не подключён'
    text += '.'
    if (r.failed > 0) text += ` ИИ не смог разобрать наборов товаров: ${r.failed}.`
    if (r.more) text += ' Ещё есть товары — нажмите ещё раз.'
    if (r.failed > 0) message.warning(text, 8)
    else message.success(text, r.more ? 8 : 5)
    if (status !== 'proposed') setStatus('proposed')
    await reload()
  }

  const waitSuggest = async (first: SuggestResult) => {
    let r = first
    while (r.running) {
      await new Promise((res) => setTimeout(res, 3000))
      r = await api.get<SuggestResult>(`${PATH}/suggest`)
      // Новые предложения видно сразу, не дожидаясь конца разбора.
      if (r.running) void reload()
    }
    return r
  }

  const suggest = async () => {
    setSuggesting(true)
    try {
      const r = await waitSuggest(await api.post<SuggestResult>(`${PATH}/suggest`, {}))
      await finishSuggest(r)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSuggesting(false)
    }
  }

  // Открыли страницу, пока разбор ещё идёт (например, после перезагрузки) — ждём его.
  useEffect(() => {
    let alive = true
    api
      .get<SuggestResult>(`${PATH}/suggest`)
      .then(async (r) => {
        if (!r.running || !alive) return
        setSuggesting(true)
        try {
          const done = await waitSuggest(r)
          if (alive) await finishSuggest(done)
        } finally {
          if (alive) setSuggesting(false)
        }
      })
      .catch(() => {})
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const tabLabel = (title: string, n: number | undefined) => (
    <span>
      {title}
      {n !== undefined && (
        <span style={{ marginLeft: 6, padding: '1px 8px', borderRadius: 10, background: '#f2f4f7', color: '#475467', fontSize: 12, fontWeight: 600 }}>{n}</span>
      )}
    </span>
  )

  const items = data?.items ?? []

  return (
    <>
      <PageTitle
        title={
          <>
            Вариации товаров
            <Typography.Text type="secondary" style={{ display: 'block', fontSize: 13, fontWeight: 400, marginTop: 2 }}>
              Super Market находит товары одного бренда и линейки, которые отличаются только весом или вкусом. Проверьте и подтвердите группы.
            </Typography.Text>
          </>
        }
        extra={
          <Space wrap>
            <Button type="primary" icon={<Sparkle />} loading={suggesting} onClick={suggest}>
              {suggesting ? 'Ищем группы…' : 'Найти новые группы'}
            </Button>
            <Button icon={<PlusOutlined />} onClick={() => setCreating(true)}>
              Собрать группу
            </Button>
          </Space>
        }
        tabs={
          <Tabs
            activeKey={status}
            onChange={(k) => setStatus(k)}
            items={[
              { key: 'proposed', label: tabLabel('Предложения', counts.proposed) },
              { key: 'confirmed', label: tabLabel('Подтверждённые', counts.confirmed) },
              { key: 'rejected', label: tabLabel('Отклонённые', counts.rejected) },
            ]}
          />
        }
      >
        <Input.Search placeholder="Группа или товар" allowClear onSearch={setQ} style={{ width: 260 }} />
      </PageTitle>

      <Flex
        align="flex-start"
        gap={10}
        style={{ background: '#eff4ff', border: '1px solid #d1e0ff', color: '#1d2939', borderRadius: 12, padding: '12px 16px', marginBottom: 16 }}
      >
        <Sparkle style={{ color: '#155eef', fontSize: 18, marginTop: 2 }} />
        <span style={{ color: '#1746a2' }}>
          {suggesting && 'Super Market разбирает товары общего каталога — это может занять несколько минут, страницу можно закрыть. '}
          Правило: группа = бренд + линейка, внутри — вес и вкус. Разные линейки (Lay's и Lay's MAXX) — разные группы.
        </span>
      </Flex>

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
                  ? 'Ничего не нашлось'
                  : status === 'proposed'
                    ? 'Новых предложений нет. Нажмите «Найти новые группы», чтобы Super Market проверил каталог.'
                    : status === 'confirmed'
                      ? 'Подтверждённых групп пока нет'
                      : 'Отклонённых групп нет'
              }
            />
          </Card>
        ) : (
          <Flex vertical gap={16}>
            {items.map((g, i) => (
              <GroupCard
                key={g.id}
                group={g}
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
          <Pagination current={page} pageSize={PAGE} total={data.total} onChange={setPage} showSizeChanger={false} itemRender={pageItemRender} />
        </Flex>
      )}

      <CreateGroupModal
        open={creating}
        onClose={() => setCreating(false)}
        onCreated={(g) => {
          setCreating(false)
          setOpen((o) => ({ ...o, [g.id]: true }))
          if (status !== 'proposed') setStatus('proposed')
          reload()
        }}
      />
    </>
  )
}

// ───────────────────────────────────────────────────────────── карточка группы

function ConfidenceChip({ g }: { g: Group }) {
  const base = { display: 'inline-flex', alignItems: 'center', gap: 4, padding: '1px 8px', borderRadius: 10, fontSize: 12, fontWeight: 600 } as const
  if (g.confidence === 'check') {
    return (
      <span style={{ ...base, background: '#fffaeb', color: '#b54708' }}>
        <WarningFilled /> {g.note.trim() || 'Проверьте вкусы'}
      </span>
    )
  }
  if (g.source === 'manual') return <span style={{ ...base, background: '#f2f4f7', color: '#475467' }}>Собрана вручную</span>
  return (
    <span style={{ ...base, background: '#ecfdf3', color: '#067647' }}>
      <SafetyCertificateFilled /> Уверенность высокая
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

function GroupCard({
  group: g,
  open,
  onToggle,
  replace,
  reload,
  onSplit,
}: {
  group: Group
  open: boolean
  onToggle: () => void
  replace: (g: Group) => void
  reload: () => Promise<unknown>
  onSplit: (g: Group) => void
}) {
  const { message, modal } = App.useApp()
  const [busy, setBusy] = useState<'' | 'confirm' | 'reject' | 'split'>('')
  const [splitting, setSplitting] = useState(false)
  const [picked, setPicked] = useState<string[]>([])
  const [adding, setAdding] = useState(false)

  const included = g.items.filter((it) => it.included)
  const weights = distinct(included.map((it) => it.weight))
  const flavors = distinct(included.map((it) => it.flavor))
  const allWeights = distinct(g.items.map((it) => it.weight))
  const allFlavors = distinct(g.items.map((it) => it.flavor))

  // Два отмеченных товара с одинаковыми весом и вкусом — подтвердить нельзя.
  const dup = useMemo(() => {
    const n = new Map<string, number>()
    for (const it of g.items) if (it.included) n.set(comboKey(it), (n.get(comboKey(it)) ?? 0) + 1)
    return new Set([...n].filter(([, c]) => c > 1).map(([k]) => k))
  }, [g.items])

  const sub = [
    g.brand_name,
    g.category_name,
    `${included.length} ${plural(included.length, 'товар', 'товара', 'товаров')}`,
    weights.length === 1 ? weights[0] : weights.length > 1 ? `${weights.length} ${plural(weights.length, 'вес', 'веса', 'весов')}` : null,
    flavors.length === 1 ? flavors[0] : flavors.length > 1 ? `${flavors.length} ${plural(flavors.length, 'вкус', 'вкуса', 'вкусов')}` : null,
    g.stores_count > 0 ? `есть в ${g.stores_count} ${plural(g.stores_count, 'магазине', 'магазинах', 'магазинах')}` : null,
  ]
    .filter(Boolean)
    .join(' · ')

  /** Откат после ошибки: свежая группа с сервера (или прежнее состояние). */
  const restore = async (prev: Group) => {
    try {
      replace(await api.get<Group>(`${PATH}/${g.id}`))
    } catch {
      replace(prev)
    }
  }

  /** PATCH с оптимистичным обновлением. */
  const patch = async (body: { name?: string; name_uz?: string; items?: (ItemPatch & { product_id: string })[] }) => {
    const prev = g
    const next: Group = {
      ...g,
      ...(body.name !== undefined ? { name: body.name } : {}),
      ...(body.name_uz !== undefined ? { name_uz: body.name_uz } : {}),
      items: g.items.map((it) => {
        const ch = body.items?.find((x) => x.product_id === it.product_id)
        return ch ? { ...it, ...ch } : it
      }),
    }
    replace(next)
    try {
      replace(await api.patch<Group>(`${PATH}/${g.id}`, body))
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
      await api.post<Group>(`${PATH}/${g.id}/confirm`)
      message.success(`Группа «${g.name}» подтверждена`)
      await reload()
    })

  const reject = () =>
    run('reject', async () => {
      await api.post<Group>(`${PATH}/${g.id}/reject`)
      message.success(g.status === 'confirmed' ? `Группа «${g.name}» расформирована` : `Предложение «${g.name}» отклонено`)
      await reload()
    })

  const disband = () =>
    modal.confirm({
      title: `Расформировать группу «${g.name}»?`,
      content: 'Товары снова станут отдельными в приложении и на кассах. Super Market больше не будет предлагать эту группу.',
      okText: 'Расформировать',
      okButtonProps: { danger: true },
      cancelText: 'Отмена',
      onOk: reject,
    })

  const split = () =>
    run('split', async () => {
      const r = await api.post<{ group: Group; new_group: Group }>(`${PATH}/${g.id}/split`, { product_ids: picked })
      message.success(`Товары отделены в новую группу «${r.new_group.name}» — переименуйте её`)
      setSplitting(false)
      setPicked([])
      onSplit(r.new_group)
      replace(r.group)
      await reload()
    })

  const canConfirm = included.length >= 2 && dup.size === 0
  const confirmHint = included.length < 2 ? 'Отметьте хотя бы два товара' : dup.size ? 'У двух товаров одинаковые вес и вкус' : ''
  const letter = (g.brand_name || g.name).trim().charAt(0).toUpperCase() || '?'

  const columns: TableColumnsType<Item> = [
    ...(splitting
      ? []
      : [
          {
            key: 'inc',
            width: 44,
            render: (_: unknown, it: Item) => <Checkbox checked={it.included} onChange={(e) => patchItem(it.product_id, { included: e.target.checked })} />,
          },
        ]),
    { key: 'img', width: 52, render: (_, it) => <Thumb src={it.image} dim={!it.included} /> },
    {
      title: 'ТОВАР — КАК В ЦЕНТРАЛЬНОЙ БАЗЕ',
      key: 'name',
      render: (_, it) => (
        <div style={{ minWidth: 220 }}>
          <span style={{ color: it.included ? undefined : '#98a2b3' }}>{it.name}</span>
          {it.note.trim() && (
            <div style={{ color: '#c4320a', fontSize: 12 }}>
              <ExclamationCircleFilled /> {it.note}
            </div>
          )}
          {it.other_group && (
            <div style={{ color: '#d92d20', fontSize: 12 }}>
              <WarningFilled /> уже в группе «{it.other_group}»
            </div>
          )}
        </div>
      ),
    },
    {
      title: 'ВЕС',
      key: 'weight',
      width: 150,
      render: (_, it) =>
        it.included && !splitting ? (
          <ValueEdit
            value={it.weight}
            uz={it.weight_uz}
            options={allWeights}
            placeholder="вес"
            width={120}
            error={dup.has(comboKey(it))}
            onSave={(v) => patchItem(it.product_id, { weight: v })}
            onSaveUz={(v) => patchItem(it.product_id, { weight_uz: v })}
          />
        ) : (
          <Typography.Text type="secondary">{it.weight || '—'}</Typography.Text>
        ),
    },
    {
      title: 'ВКУС',
      key: 'flavor',
      width: 220,
      render: (_, it) =>
        it.included && !splitting ? (
          <ValueEdit
            value={it.flavor}
            uz={it.flavor_uz}
            options={allFlavors}
            placeholder="вкус"
            width={190}
            error={dup.has(comboKey(it))}
            onSave={(v) => patchItem(it.product_id, { flavor: v })}
            onSaveUz={(v) => patchItem(it.product_id, { flavor_uz: v })}
          />
        ) : (
          <Typography.Text type="secondary">{it.flavor || '—'}</Typography.Text>
        ),
    },
    {
      title: 'ШТРИХКОД',
      dataIndex: 'barcode',
      width: 150,
      render: (b: string, it) => <span style={{ color: it.included ? '#475467' : '#98a2b3' }}>{b || '—'}</span>,
    },
    ...(splitting
      ? []
      : [
          {
            key: 'act',
            width: 48,
            align: 'center' as const,
            render: (_: unknown, it: Item) =>
              it.included ? (
                <Tooltip title="Убрать из группы — товар останется отдельным">
                  <Button type="text" size="small" icon={<MinusCircleOutlined style={{ color: '#98a2b3' }} />} onClick={() => patchItem(it.product_id, { included: false })} />
                </Tooltip>
              ) : (
                <Tooltip title="Вернуть в группу">
                  <Button type="text" size="small" icon={<PlusCircleOutlined style={{ color: '#667085' }} />} onClick={() => patchItem(it.product_id, { included: true })} />
                </Tooltip>
              ),
          },
        ]),
  ]

  const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

  return (
    <Card style={{ borderRadius: 16, border: `1px solid ${LINE}` }} styles={{ body: { padding: 0 } }}>
      <Flex align="center" gap={12} wrap style={{ padding: '14px 20px', cursor: 'pointer' }} onClick={onToggle}>
        <Button type="text" size="small" icon={open ? <DownOutlined /> : <RightOutlined />} aria-label={open ? 'Свернуть' : 'Развернуть'} />
        <Flex align="center" justify="center" style={{ width: 36, height: 36, borderRadius: 10, background: '#fdeced', color: '#d92d20', fontWeight: 800, fontSize: 16, flex: 'none' }}>
          {letter}
        </Flex>
        <div style={{ flex: 1, minWidth: 220 }}>
          <Flex align="center" gap={8} wrap>
            <span style={{ fontWeight: 800, fontSize: 16, color: '#101828' }}>{g.name}</span>
            <ConfidenceChip g={g} />
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {sub}
          </Typography.Text>
        </div>
        <Space onClick={stop} wrap>
          {g.status === 'proposed' && (
            <Button icon={<CloseOutlined />} loading={busy === 'reject'} disabled={!!busy && busy !== 'reject'} onClick={reject}>
              Отклонить
            </Button>
          )}
          {g.status === 'confirmed' && (
            <Button icon={<CloseOutlined />} loading={busy === 'reject'} disabled={!!busy && busy !== 'reject'} onClick={disband}>
              Расформировать
            </Button>
          )}
          {g.status !== 'confirmed' && (
            <Tooltip title={confirmHint}>
              <Button
                type="primary"
                icon={<CheckOutlined />}
                loading={busy === 'confirm'}
                disabled={!canConfirm || (!!busy && busy !== 'confirm') || splitting}
                onClick={confirm}
              >
                Подтвердить группу
              </Button>
            </Tooltip>
          )}
        </Space>
      </Flex>

      {open && (
        <>
          <Flex align="center" gap={12} wrap style={{ padding: '0 20px 16px 68px' }}>
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              Название группы
            </Typography.Text>
            <TextEdit value={g.name} placeholder="Название" width={260} required onSave={(v) => patch({ name: v })} />
            <TextEdit value={g.name_uz} placeholder="Nomi (oʻzbekcha)" prefix="uz:" width={240} onSave={(v) => patch({ name_uz: v })} />
            <Typography.Text type="secondary" style={{ fontSize: 13, marginLeft: 8 }}>
              Переключатели
            </Typography.Text>
            <SwitchChip label="Вес" on={weights.length > 1} />
            <SwitchChip label="Вкус" on={flavors.length > 1} />
          </Flex>
          <div style={{ borderTop: `1px solid ${LINE}` }}>
            <Table<Item>
              rowKey="product_id"
              size="middle"
              columns={columns}
              dataSource={g.items}
              pagination={false}
              scroll={{ x: true }}
              onRow={(it) => ({ style: it.included ? undefined : { background: '#fcfcfd' } })}
              rowSelection={splitting ? { selectedRowKeys: picked, onChange: (keys) => setPicked(keys.map(String)) } : undefined}
            />
          </div>
          <Flex align="center" gap={12} wrap style={{ padding: '10px 20px', borderTop: `1px solid ${LINE}` }}>
            {splitting ? (
              <>
                <Typography.Text>Отметьте товары, которые уйдут в новую группу</Typography.Text>
                <Button
                  type="primary"
                  icon={<ForkOutlined />}
                  loading={busy === 'split'}
                  disabled={picked.length === 0 || picked.length >= g.items.length}
                  onClick={split}
                >
                  Отделить{picked.length ? ` (${picked.length})` : ''}
                </Button>
                <Button
                  onClick={() => {
                    setSplitting(false)
                    setPicked([])
                  }}
                >
                  Отмена
                </Button>
              </>
            ) : (
              <>
                <Button type="link" danger icon={<PlusOutlined />} style={{ paddingLeft: 0, fontWeight: 600 }} onClick={() => setAdding(true)}>
                  Добавить товар в группу
                </Button>
                {g.status === 'proposed' && g.items.length > 1 && (
                  <Button type="text" icon={<ForkOutlined />} style={{ fontWeight: 600 }} onClick={() => setSplitting(true)}>
                    Разбить группу
                  </Button>
                )}
              </>
            )}
            <Typography.Text type="secondary" style={{ fontSize: 12, marginLeft: 'auto' }}>
              Вес и вкус Super Market взял из названий — их можно поправить. Снятая галочка — товар остаётся отдельным.
            </Typography.Text>
          </Flex>
        </>
      )}

      <AddItemModal
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

function SwitchChip({ label, on }: { label: string; on: boolean }) {
  return (
    <Tooltip title={on ? `В приложении будет переключатель «${label.toLowerCase()}»` : `У всех отмеченных товаров один ${label.toLowerCase()}`}>
      <span
        style={{
          padding: '2px 10px',
          borderRadius: 12,
          fontSize: 12,
          fontWeight: 600,
          background: on ? '#f2f4f7' : '#fff',
          color: on ? '#344054' : '#98a2b3',
          border: `1px solid ${on ? '#f2f4f7' : LINE}`,
        }}
      >
        {label}
      </span>
    </Tooltip>
  )
}

// ───────────────────────────────────────────────────────────── поля правки

/** Текстовое поле, сохраняемое по Enter и при потере фокуса. */
function TextEdit({
  value,
  onSave,
  placeholder,
  prefix,
  width,
  required,
}: {
  value: string
  onSave: (v: string) => void
  placeholder?: string
  prefix?: ReactNode
  width: number
  required?: boolean
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
      maxLength={120}
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

/**
 * Вес или вкус: поле с вариантами, которые уже есть в группе, и
 * узбекский перевод строкой ниже (правится по клику).
 */
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
  // Последнее введённое или выбранное значение: Enter и выбор варианта из
  // списка приходят в одном событии — сохраняем один раз.
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
      <Tooltip title={error ? 'Такие вес и вкус уже есть у другого товара группы' : ''}>
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
            // После выбора варианта Enter-ом onSelect уже сработал.
            if (e.key === 'Enter') setTimeout(commit, 0)
          }}
        />
      </Tooltip>
      <Typography.Text
        type="secondary"
        style={{ fontSize: 11, display: 'block', marginTop: 2 }}
        editable={{
          text: uz,
          tooltip: 'Перевод на узбекский',
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

// ───────────────────────────────────────────────────────────── поиск товаров

function productLabel(p: CatalogProduct) {
  const img = p.images?.[0]
  return (
    <Flex align="center" gap={8}>
      {img ? (
        <img src={img} alt="" width={24} height={24} style={{ objectFit: 'cover', borderRadius: 4, flex: 'none' }} />
      ) : (
        <PictureOutlined style={{ color: '#98a2b3', width: 24 }} />
      )}
      <span>
        {p.name}
        {p.barcodes?.[0] && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {' '}
            · {p.barcodes[0]}
          </Typography.Text>
        )}
      </span>
    </Flex>
  )
}

/** Поиск по общему каталогу (одобренные товары без сети). */
function ProductSearch({ exclude, ...props }: { exclude?: Set<string> } & Omit<Parameters<typeof RemoteSelect<CatalogProduct>>[0], 'path'>) {
  return (
    <RemoteSelect<CatalogProduct>
      path="/admin/products"
      params={{ status: 'approved' }}
      search
      label={productLabel}
      filter={(p) => !p.network_id && !exclude?.has(p.id)}
      placeholder="Название или штрихкод"
      notFoundContent="Ничего не нашлось"
      style={{ width: '100%' }}
      {...props}
    />
  )
}

function AddItemModal({ open, group, onClose, onAdded }: { open: boolean; group: Group; onClose: () => void; onAdded: (g: Group) => void }) {
  const { message } = App.useApp()
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
      const g = await api.post<Group>(`${PATH}/${group.id}/items`, { product_id: id })
      message.success('Товар добавлен — проверьте вес и вкус')
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
      title={`Добавить товар в «${group.name}»`}
      okText="Добавить"
      cancelText="Отмена"
      okButtonProps={{ disabled: !id }}
      confirmLoading={busy}
      onOk={add}
      onCancel={onClose}
      destroyOnClose
    >
      <Typography.Paragraph type="secondary">Товар из общего каталога. Вес и вкус Super Market возьмёт из названия — их можно поправить.</Typography.Paragraph>
      <ProductSearch exclude={exclude} value={id} onChange={(v) => setId(v as string | undefined)} allowClear />
    </Modal>
  )
}

function CreateGroupModal({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (g: Group) => void }) {
  const { message } = App.useApp()
  const [form] = Form.useForm()
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (open) form.resetFields()
  }, [open, form])
  const submit = async (v: { name: string; name_uz?: string; products?: { value: string }[] }) => {
    setBusy(true)
    try {
      const g = await api.post<Group>(PATH, {
        name: v.name.trim(),
        name_uz: (v.name_uz ?? '').trim(),
        product_ids: (v.products ?? []).map((p) => p.value),
      })
      message.success(`Группа «${g.name}» собрана — проверьте вес и вкус и подтвердите`)
      onCreated(g)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <Modal
      open={open}
      title="Собрать группу"
      okText="Собрать"
      cancelText="Отмена"
      confirmLoading={busy}
      onOk={() => form.submit()}
      onCancel={onClose}
      width={600}
      forceRender
    >
      <Form form={form} layout="vertical" onFinish={submit}>
        <Form.Item name="name" label="Название группы" rules={[{ required: true, whitespace: true, message: 'Введите название' }]} extra="Бренд + линейка, например «Чипсы Lay's»">
          <Input maxLength={120} />
        </Form.Item>
        <Form.Item name="name_uz" label="Название (узб.)">
          <Input maxLength={120} placeholder="Lay's chipslari" />
        </Form.Item>
        <Form.Item
          name="products"
          label="Товары"
          extra="Товары одной линейки, которые отличаются только весом или вкусом"
          rules={[{ validator: (_, v: unknown[] | undefined) => ((v?.length ?? 0) >= 2 ? Promise.resolve() : Promise.reject(new Error('Выберите хотя бы два товара'))) }]}
        >
          <ProductSearch mode="multiple" labelInValue />
        </Form.Item>
      </Form>
      <Flex gap={6} style={{ color: '#667085', fontSize: 12 }}>
        <ThunderboltOutlined />
        Вес и вкус Super Market возьмёт из названий товаров.
      </Flex>
    </Modal>
  )
}
