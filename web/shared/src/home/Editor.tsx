// Редактор главной приложения: блоки слева, настройки выбранного блока,
// предпросмотр телефона. Правки сохраняются в черновик сами; покупатели
// видят их после «Опубликовать».
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { App, Button, Drawer, Dropdown, Modal, Select, Spin, Switch, Tag } from 'antd'
import { CopyOutlined, DeleteOutlined, EditFilled, HistoryOutlined, HolderOutlined, LockFilled, MoreOutlined, PlusOutlined, PushpinFilled, CarFilled, LayoutFilled } from '@ant-design/icons'
import { api, query } from '../api'
import { LoadError } from '../components'
import { dateTime } from '../format'
import { errorText, useDebounced, useList } from '../hooks'
import { BLOCK_TYPES, blockSummary, blockTitle, scheduleTag, typeMeta } from './meta'
import { PhonePreview } from './Preview'
import { BlockSettings, type EditorPaths } from './Settings'
import { clean, defaultBlock, newId, type BlockType, type HomeBlock, type LayoutEditor, type LayoutVersion } from './types'

type Params = Record<string, string | undefined>

interface PreviewStore {
  id: string
  name: string
  network_name: string
}

/** Сколько блоков отличается от опубликованной версии. */
function changes(published: HomeBlock[], draft: HomeBlock[]): number {
  const pub = new Map(published.map((b) => [b.id, JSON.stringify(clean(b))]))
  let n = 0
  for (const b of draft) if (pub.get(b.id) !== JSON.stringify(clean(b))) n++
  n += published.filter((b) => !draft.some((d) => d.id === b.id)).length
  if (n === 0 && published.map((b) => b.id).join() !== draft.map((b) => b.id).join()) n = 1
  return n
}

function plural(n: number, one: string, few: string, many: string) {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}

export interface AddInfo {
  /** Замок «Про» и т.п.: блок не добавить на этом тарифе. */
  lock?: string
  /** Почему недоступно / сколько осталось. */
  hint?: string
  /** Функция для окна лимита. */
  feature?: string
}

export interface BlockFeatures {
  schedule?: boolean
  manual?: boolean
}

function AddBlockModal({
  open,
  onClose,
  onAdd,
  info,
  onLocked,
}: {
  open: boolean
  onClose: () => void
  onAdd: (t: BlockType) => void
  info?: (t: BlockType) => AddInfo | undefined
  onLocked?: (feature: string) => void
}) {
  const [picked, setPicked] = useState<BlockType>('shelf')
  const pick = (t: BlockType) => {
    const i = info?.(t)
    if (i?.lock) {
      onClose()
      onLocked?.(i.feature ?? t)
      return
    }
    setPicked(t)
  }
  return (
    <Modal
      open={open}
      onCancel={onClose}
      title={
        <div>
          Добавить блок
          <div className="smh-modal-sub">{info ? 'Недоступное на вашем тарифе отмечено замком.' : 'Блок появится в конце списка — потом его можно перетащить.'}</div>
        </div>
      }
      okText="Добавить"
      cancelText="Отмена"
      onOk={() => (info?.(picked)?.lock ? onClose() : onAdd(picked))}
      width={600}
    >
      <div className="smh-types">
        {BLOCK_TYPES.map((t) => {
          const i = info?.(t.type)
          return (
            <button
              key={t.type}
              type="button"
              className={`smh-type${picked === t.type && !i?.lock ? ' on' : ''}${i?.lock ? ' locked' : ''}`}
              onClick={() => pick(t.type)}
              onDoubleClick={() => !i?.lock && onAdd(t.type)}
            >
              {i?.lock && (
                <span className="smh-lock">
                  <LockFilled /> {i.lock}
                </span>
              )}
              <span className="smh-block-icon">{t.icon}</span>
              <b>{t.title}</b>
              <span>{i?.hint ?? t.text}</span>
            </button>
          )
        })}
      </div>
    </Modal>
  )
}

function VersionsDrawer({ open, onClose, base, params, onRestore }: { open: boolean; onClose: () => void; base: string; params: Params; onRestore: (v: number) => void }) {
  const list = useList<LayoutVersion>(open ? `${base}/versions` : null, params)
  return (
    <Drawer open={open} onClose={onClose} title="Версии главной" width={420}>
      <LoadError error={list.error} retry={list.refetch} />
      {list.isLoading && <Spin />}
      {list.data?.length === 0 && <div className="smh-field-hint">Ещё ничего не публиковали.</div>}
      {list.data?.map((v, i) => (
        <div key={v.version} className="smh-version">
          <div>
            <b>
              Версия {v.version} {i === 0 && <Tag color="green">сейчас у покупателей</Tag>}
            </b>
            <span>
              {dateTime(v.published_at)} · {v.blocks} {plural(v.blocks, 'блок', 'блока', 'блоков')}
              {v.published_by ? ` · ${v.published_by}` : ''}
            </span>
          </div>
          {i > 0 && (
            <Button size="small" onClick={() => onRestore(v.version)}>
              В черновик
            </Button>
          )}
        </div>
      ))}
      <div className="smh-field-hint" style={{ marginTop: 16 }}>
        Старая версия попадает в черновик — проверьте её в предпросмотре и опубликуйте.
      </div>
    </Drawer>
  )
}

function FixedRow({ icon, title, text }: { icon: ReactNode; title: string; text: string }) {
  return (
    <div className="smh-row-item smh-fixed">
      <LockFilled className="smh-handle" />
      <span className="smh-block-icon smh-block-icon-grey">{icon}</span>
      <div className="smh-row-text">
        <b>{title}</b>
        <span>{text}</span>
      </div>
      <span className="smh-always">всегда</span>
    </div>
  )
}

export function HomeEditor({
  title,
  subtitle,
  base,
  params,
  storesPath,
  previewPath,
  paths,
  canPin,
  scope,
  extraActions,
  unwrap = (raw) => raw as LayoutEditor,
  top,
  locked,
  addInfo,
  features,
  onUpgrade,
  onError,
  storeParam = 'store_id',
}: {
  title: string
  subtitle: string
  base: string
  params: Params
  storesPath: string
  previewPath: string
  paths: EditorPaths
  canPin?: boolean
  /** Выбор «для всех сетей / сеть» в шапке. */
  scope?: ReactNode
  /** Дополнительные пункты под плашкой (например, «Вернуть шаблон»). */
  extraActions?: (layout: LayoutEditor) => ReactNode
  /** Ответ сервера → витрина (панель магазина отдаёт ещё тариф и лимиты). */
  unwrap?: (raw: unknown) => LayoutEditor
  /** Над колонками: полоска тарифа и т.п. */
  top?: (raw: unknown, blocks: HomeBlock[]) => ReactNode
  /** Блок нельзя менять (закреплён платформой). */
  locked?: (b: HomeBlock) => boolean
  /** Для окна «Добавить блок»: замок и подсказка по тарифу. */
  addInfo?: (t: BlockType, blocks: HomeBlock[], raw: unknown) => AddInfo | undefined
  /** Что доступно в настройках блока (тариф). */
  features?: BlockFeatures
  onUpgrade?: (feature: string) => void
  /** Ошибка публикации/сохранения; true — обработана (окно лимита). */
  onError?: (e: unknown) => boolean
  /** Параметр магазина в предпросмотре списка магазинов (не используется сервером). */
  storeParam?: string
}) {
  const { message, modal } = App.useApp()
  const qc = useQueryClient()
  const key = [base, params]
  const rawQ = useQuery({ queryKey: key, queryFn: () => api.get<unknown>(base, params) })
  const layout = { ...rawQ, data: rawQ.data === undefined ? undefined : unwrap(rawQ.data) }
  const [blocks, setBlocks] = useState<HomeBlock[] | null>(null)
  const [selected, setSelected] = useState<string>()
  const [adding, setAdding] = useState(false)
  const [versions, setVersions] = useState(false)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const pending = useRef<ReturnType<typeof setTimeout>>()
  const qs = query(params)

  // Новая витрина (другая сеть) — свои блоки.
  const scopeKey = JSON.stringify(params)
  useEffect(() => {
    setBlocks(null)
    setSelected(undefined)
  }, [scopeKey])
  useEffect(() => {
    if (layout.data && blocks === null) {
      const list = layout.data.draft ?? layout.data.blocks
      setBlocks(list)
      setSelected((s) => s ?? list[0]?.id)
    }
  }, [rawQ.data, blocks]) // eslint-disable-line react-hooks/exhaustive-deps

  const apply = (raw: unknown) => {
    qc.setQueryData(key, raw)
    const l = unwrap(raw)
    const list = l.draft ?? l.blocks
    setBlocks(list)
    if (!list.some((b) => b.id === selected)) setSelected(list[0]?.id)
  }

  const save = (next: HomeBlock[]) => {
    setBlocks(next)
    clearTimeout(pending.current)
    pending.current = setTimeout(async () => {
      setSaving(true)
      try {
        const raw = await api.put<unknown>(`${base}/draft${qs}`, { blocks: next.map(clean) })
        qc.setQueryData(key, raw)
        setSaveError(null)
      } catch (e) {
        if (!onError?.(e)) setSaveError(errorText(e))
      } finally {
        setSaving(false)
      }
    }, 600)
  }
  useEffect(() => () => clearTimeout(pending.current), [])

  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    clearTimeout(pending.current)
    setBusy(true)
    try {
      apply(await fn())
      setSaveError(null)
      if (ok) message.success(ok)
    } catch (e) {
      if (!onError?.(e)) message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  // Предпросмотр: магазин и блоки с настоящими товарами.
  const stores = useList<PreviewStore>(storesPath, storeParam in params ? {} : params)
  const [storeId, setStoreId] = useState<string>()
  useEffect(() => {
    const list = stores.data ?? []
    if (list.length && !list.some((s) => s.id === storeId)) setStoreId(list[0].id)
  }, [stores.data, storeId])
  const debounced = useDebounced(blocks, 500)
  const previewBody = useMemo(() => JSON.stringify((debounced ?? []).map(clean)), [debounced])
  const preview = useQuery({
    queryKey: ['home-preview', storeId, previewBody],
    queryFn: () => api.post<{ blocks: HomeBlock[] }>(previewPath, { store_id: storeId, blocks: JSON.parse(previewBody) }).then((r) => r.blocks),
    enabled: !!storeId && debounced !== null,
    placeholderData: (prev) => prev,
    retry: false,
  })
  // Пока черновик с ошибкой — показываем последний удачный предпросмотр.
  const lastPreview = useRef<HomeBlock[]>([])
  if (preview.data && !preview.error) lastPreview.current = preview.data

  // Перетаскивание блоков.
  const drag = useRef<string | null>(null)
  const onDragOver = (overId: string) => {
    const from = drag.current
    if (!blocks || !from || from === overId) return
    const next = [...blocks]
    const i = next.findIndex((b) => b.id === from)
    const j = next.findIndex((b) => b.id === overId)
    const [x] = next.splice(i, 1)
    next.splice(j, 0, x)
    setBlocks(next)
  }

  if (layout.error && !onError?.(layout.error)) return <LoadError error={layout.error} retry={layout.refetch} />
  const l = layout.data
  if (!l || !blocks) return <Spin style={{ margin: 48 }} />

  const sel = blocks.find((b) => b.id === selected)
  const n = l.draft ? changes(l.blocks, l.draft) : 0
  const update = (b: HomeBlock) => save(blocks.map((x) => (x.id === b.id ? b : x)))
  const remove = (id: string) => {
    const next = blocks.filter((b) => b.id !== id)
    save(next)
    if (selected === id) setSelected(next[0]?.id)
  }
  const store = stores.data?.find((s) => s.id === storeId)

  return (
    <div className="smh-page">
      <div className="smh-page-head">
        <div>
          <h1>{title}</h1>
          <p>{subtitle}</p>
        </div>
        <div className="smh-page-actions">
          {scope}
          <Button size="large" icon={<HistoryOutlined />} onClick={() => setVersions(true)}>
            Версии
          </Button>
          <Button
            size="large"
            type="primary"
            className="smh-publish"
            disabled={!l.draft || !!saveError || saving}
            loading={busy}
            onClick={() =>
              modal.confirm({
                title: 'Опубликовать главную?',
                content: l.network_id ? `Покупатели магазинов «${l.network_name}» увидят её в течение минуты.` : 'Покупатели всех сетей без своей витрины увидят её в течение минуты.',
                okText: 'Опубликовать',
                cancelText: 'Отмена',
                onOk: () => act(() => api.post<LayoutEditor>(`${base}/publish${qs}`), 'Главная опубликована'),
              })
            }
          >
            Опубликовать
          </Button>
        </div>
      </div>

      {(l.draft || saveError) && (
        <div className={`smh-draft${saveError ? ' smh-draft-error' : ''}`}>
          <EditFilled />
          <span>
            {saveError
              ? `Черновик не сохранён: ${saveError}`
              : l.inherited
                ? 'Черновик витрины сети — магазины сети пока видят общий шаблон.'
                : `Черновик: ${n} ${plural(n, 'изменение', 'изменения', 'изменений')} не ${n === 1 ? 'опубликовано' : 'опубликованы'} — покупатели пока видят прошлую версию.`}
          </span>
          {l.draft && (
            <a onClick={() => act(() => api.del(`${base}/draft${qs}`).then(() => api.get<LayoutEditor>(base, params)), 'Изменения сброшены')}>Сбросить</a>
          )}
        </div>
      )}
      {!l.draft && l.inherited && (
        <div className="smh-draft smh-draft-info">
          <LayoutFilled />
          <span>
            {l.store_id
              ? 'У магазина нет своей витрины — покупатели видят витрину сети. Измените блоки, чтобы сделать витрину только для этого магазина.'
              : 'У сети нет своей витрины — магазины видят общий шаблон. Измените блоки, чтобы сделать витрину для этой сети.'}
          </span>
        </div>
      )}
      {extraActions?.(l)}
      {top?.(rawQ.data, blocks)}

      <div className="smh-grid3">
        <section className="smh-card">
          <div className="smh-card-head">
            <h2>Блоки главной</h2>
            <span>Перетащите, чтобы поменять порядок{saving ? ' · сохраняем…' : ''}</span>
          </div>
          <FixedRow icon={<LayoutFilled />} title="Шапка: адрес, время доставки, поиск" text="Всегда сверху" />
          <FixedRow icon={<CarFilled />} title="Статус заказа" text="Показывается, пока есть активный заказ" />
          {blocks.map((b) => {
            const meta = typeMeta(b.type)
            const tag = scheduleTag(b)
            if (locked?.(b)) {
              return (
                <div
                  key={b.id}
                  className={`smh-row-item smh-fixed${selected === b.id ? ' on' : ''}`}
                  onDragOver={(e) => {
                    e.preventDefault()
                    onDragOver(b.id)
                  }}
                  onClick={() => setSelected(b.id)}
                >
                  <PushpinFilled className="smh-handle" />
                  <span className="smh-block-icon">{meta.icon}</span>
                  <div className="smh-row-text">
                    <b>{blockTitle(b)} Super Market</b>
                    <span>Закреплено платформой — убрать нельзя</span>
                  </div>
                  <span className="smh-platform">платформа</span>
                </div>
              )
            }
            return (
              <div
                key={b.id}
                className={`smh-row-item${selected === b.id ? ' on' : ''}${b.disabled ? ' off' : ''}`}
                draggable
                onDragStart={(e) => {
                  drag.current = b.id
                  e.dataTransfer.effectAllowed = 'move'
                }}
                onDragOver={(e) => {
                  e.preventDefault()
                  onDragOver(b.id)
                }}
                onDragEnd={() => {
                  drag.current = null
                  save(blocks)
                }}
                onClick={() => setSelected(b.id)}
              >
                <HolderOutlined className="smh-handle" />
                <span className="smh-block-icon">{meta.icon}</span>
                <div className="smh-row-text">
                  <b>
                    {blockTitle(b)} {b.pinned && <PushpinFilled className="smh-pin" />}
                  </b>
                  <span>{blockSummary(b)}</span>
                </div>
                {tag && <span className={`smh-sched smh-sched-${tag.tone}`}>{tag.text}</span>}
                <Switch checked={!b.disabled} onClick={(_, e) => e.stopPropagation()} onChange={(v) => update({ ...b, disabled: !v })} />
                <Dropdown
                  trigger={['click']}
                  menu={{
                    items: [
                      { key: 'copy', icon: <CopyOutlined />, label: 'Дублировать' },
                      { key: 'del', icon: <DeleteOutlined />, label: 'Удалить', danger: true },
                    ],
                    onClick: ({ key, domEvent }) => {
                      domEvent.stopPropagation()
                      if (key === 'del') remove(b.id)
                      else {
                        const copy = { ...clean(b), id: newId(), pinned: false }
                        const i = blocks.findIndex((x) => x.id === b.id)
                        save([...blocks.slice(0, i + 1), copy, ...blocks.slice(i + 1)])
                        setSelected(copy.id)
                      }
                    },
                  }}
                >
                  <Button type="text" icon={<MoreOutlined />} onClick={(e) => e.stopPropagation()} />
                </Dropdown>
              </div>
            )
          })}
          <button type="button" className="smh-add" onClick={() => setAdding(true)} disabled={blocks.length >= 30}>
            <PlusOutlined /> Добавить блок
          </button>
        </section>

        <section className="smh-card">
          {sel ? (
            locked?.(sel) ? (
              <div className="smh-settings">
                <div className="smh-settings-head">
                  <span className="smh-block-icon">{typeMeta(sel.type).icon}</span>
                  <div>
                    <b>{typeMeta(sel.type).title}</b>
                    <span>Блок Super Market</span>
                  </div>
                </div>
                <div className="smh-note">
                  <PushpinFilled /> Этот блок закрепила платформа: он есть у всех магазинов, менять и убирать его нельзя. Свои блоки можно ставить выше и ниже.
                </div>
              </div>
            ) : (
              <BlockSettings key={sel.id} b={sel} onChange={update} onDelete={() => remove(sel.id)} paths={paths} canPin={canPin} features={features} onUpgrade={onUpgrade} />
            )
          ) : (
            <div className="smh-field-hint">Выберите блок слева, чтобы настроить его.</div>
          )}
        </section>

        <section className="smh-card smh-preview-card">
          <div className="smh-card-head">
            <h2>Предпросмотр</h2>
            <span>Так увидит покупатель</span>
          </div>
          <PhonePreview blocks={lastPreview.current} storeId={storeId} storeName={store?.name} selected={selected} onSelect={setSelected} loading={preview.isFetching} />
          <Select
            className="smh-preview-store"
            value={storeId}
            onChange={setStoreId}
            placeholder={stores.isLoading ? 'Загружаем магазины…' : 'Нет магазинов, принимающих заказы'}
            options={(stores.data ?? []).map((s) => ({ value: s.id, label: `${s.name} · ${s.network_name}` }))}
            showSearch
            optionFilterProp="label"
          />
          <div className="smh-field-hint">Товары и баннеры — настоящие, из выбранного магазина. Точный вид — в приложении.</div>
          {preview.error && <div className="smh-field-hint" style={{ color: '#b3261e' }}>{errorText(preview.error)}</div>}
        </section>
      </div>

      <AddBlockModal
        info={addInfo ? (t) => addInfo(t, blocks, rawQ.data) : undefined}
        onLocked={onUpgrade}
        open={adding}
        onClose={() => setAdding(false)}
        onAdd={(t) => {
          const b = defaultBlock(t)
          save([...blocks, b])
          setSelected(b.id)
          setAdding(false)
        }}
      />
      <VersionsDrawer
        open={versions}
        onClose={() => setVersions(false)}
        base={base}
        params={params}
        onRestore={(v) => {
          setVersions(false)
          act(() => api.post<LayoutEditor>(`${base}/restore${qs}`, { version: v }), `Версия ${v} в черновике`)
        }}
      />
    </div>
  )
}
