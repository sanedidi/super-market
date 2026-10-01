// Настройки выбранного блока (Figma «Админка · Главная приложения»).
import { useState, type ReactNode } from 'react'
import { App, Button, DatePicker, Input, InputNumber, Segmented, Select, Switch, Tooltip } from 'antd'
import { CloseOutlined, DeleteOutlined, PushpinFilled, UpOutlined, DownOutlined, CloudUploadOutlined, LockFilled } from '@ant-design/icons'
import dayjs from 'dayjs'
import { api } from '../api'
import { RemoteSelect } from '../components'
import { useItem, useList, errorText } from '../hooks'
import { ImageUpload } from '../upload'
import { CATALOG_VIEWS, COLORS, ICONS, LINKS, SHAPES, SHELF_VIEWS, SOURCES, typeMeta } from './meta'
import type { BlockLink, HomeBlock } from './types'

export interface EditorPaths {
  products: string
  categories: string
  banners: string
}

type Change = (patch: Partial<HomeBlock>) => void

function Field({ label, hint, children }: { label: ReactNode; hint?: ReactNode; children: ReactNode }) {
  return (
    <div className="smh-field">
      <div className="smh-field-label">{label}</div>
      {children}
      {hint && <div className="smh-field-hint">{hint}</div>}
    </div>
  )
}

function Toggle({ title, text, checked, onChange }: { title: string; text?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="smh-toggle">
      <div>
        <b>{title}</b>
        {text && <span>{text}</span>}
      </div>
      <Switch checked={checked} onChange={onChange} />
    </div>
  )
}

/** Упорядоченный список выбранного: вверх, вниз, убрать. */
function Ordered({ ids, render, onChange }: { ids: string[]; render: (id: string) => ReactNode; onChange: (ids: string[]) => void }) {
  const move = (i: number, d: number) => {
    const next = [...ids]
    const [x] = next.splice(i, 1)
    next.splice(i + d, 0, x)
    onChange(next)
  }
  return (
    <div className="smh-ordered">
      {ids.map((id, i) => (
        <div key={id} className="smh-ordered-row">
          <div className="smh-ordered-body">{render(id)}</div>
          <Button type="text" size="small" icon={<UpOutlined />} disabled={i === 0} onClick={() => move(i, -1)} />
          <Button type="text" size="small" icon={<DownOutlined />} disabled={i === ids.length - 1} onClick={() => move(i, 1)} />
          <Button type="text" size="small" icon={<CloseOutlined />} onClick={() => onChange(ids.filter((x) => x !== id))} />
        </div>
      ))}
    </div>
  )
}

function ProductName({ path, id }: { path: string; id: string }) {
  const { data } = useItem<{ name: string; images?: string[] }>(`${path}/${id}`)
  return (
    <span className="smh-thumb-row">
      {data?.images?.[0] ? <img src={data.images[0]} alt="" /> : <i />}
      {data?.name ?? '…'}
    </span>
  )
}

function IconPicker({ value, onChange }: { value?: string; onChange: (v: string) => void }) {
  return (
    <div className="smh-icon-picker">
      {ICONS.map((i) => (
        <button key={i.value} type="button" className={value === i.value ? 'on' : ''} onClick={() => onChange(i.value)}>
          {i.icon}
        </button>
      ))}
    </div>
  )
}

function ColorPicker({ value, onChange }: { value?: string; onChange: (v: HomeBlock['color']) => void }) {
  return (
    <div className="smh-color-picker">
      {Object.entries(COLORS).map(([k, c]) => (
        <Tooltip key={k} title={c.label}>
          <button type="button" className={value === k ? 'on' : ''} style={{ background: c.swatch }} onClick={() => onChange(k as HomeBlock['color'])} />
        </Tooltip>
      ))}
    </div>
  )
}

function LinkPicker({ value, onChange, paths }: { value?: BlockLink | null; onChange: (v: BlockLink) => void; paths: EditorPaths }) {
  const t = value?.type ?? 'none'
  return (
    <Field label="При нажатии открыть">
      <Select value={t} options={LINKS} onChange={(type) => onChange({ type })} style={{ width: '100%' }} />
      {t === 'category' && (
        <RemoteSelect path={paths.categories} value={value?.id} onChange={(id) => onChange({ type: t, id: id as string })} placeholder="Категория" style={{ width: '100%', marginTop: 8 }} />
      )}
      {t === 'product' && (
        <RemoteSelect search path={paths.products} value={value?.id} onChange={(id) => onChange({ type: t, id: id as string })} placeholder="Найти товар" style={{ width: '100%', marginTop: 8 }} />
      )}
      {t === 'url' && (
        <Input value={value?.url} onChange={(e) => onChange({ type: t, url: e.target.value })} placeholder="https://" style={{ marginTop: 8 }} />
      )}
    </Field>
  )
}

function ShelfSettings({ b, change, paths, features, onUpgrade }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: { manual?: boolean }; onUpgrade?: (f: string) => void }) {
  const manualLocked = features?.manual === false
  const ids = b.product_ids ?? []
  return (
    <>
      <Field label="Заголовок">
        <Input value={b.title} maxLength={40} onChange={(e) => change({ title: e.target.value })} />
      </Field>
      <Field label="Откуда брать товары">
        <Segmented
          block
          options={SOURCES.map((o) => (o.value === 'manual' && manualLocked ? { ...o, label: <span><LockFilled /> {o.label}</span> } : o))}
          value={b.source}
          onChange={(v) => (v === 'manual' && manualLocked ? onUpgrade?.('manual') : change({ source: v as HomeBlock['source'] }))}
        />
      </Field>
      {b.source === 'category' && (
        <Field label="Категория">
          <RemoteSelect path={paths.categories} value={b.category_id} onChange={(v) => change({ category_id: v as string })} placeholder="Выберите категорию" style={{ width: '100%' }} />
        </Field>
      )}
      {b.source === 'manual' && (
        <Field label="Товары подборки" hint="Порядок — как в приложении. До 30 товаров.">
          <Ordered ids={ids} onChange={(next) => change({ product_ids: next })} render={(id) => <ProductName path={paths.products} id={id} />} />
          <RemoteSelect
            search
            path={paths.products}
            value={null}
            placeholder="+ Добавить товар"
            filter={(p) => !ids.includes(String(p.id))}
            onChange={(id) => id && change({ product_ids: [...ids, id as string].slice(0, 30) })}
            style={{ width: '100%' }}
          />
        </Field>
      )}
      <div className="smh-pair">
        <Field label="Сколько товаров">
          <InputNumber min={1} max={20} value={b.limit} onChange={(v) => change({ limit: v ?? 6 })} style={{ width: 96 }} />
        </Field>
        <Field label="Вид">
          <Segmented options={SHELF_VIEWS} value={b.view} onChange={(v) => change({ view: v as string })} />
        </Field>
      </div>
      {b.source !== 'manual' && <Toggle title="Кнопка «Все»" text="Открывает полный список" checked={b.show_all !== false} onChange={(v) => change({ show_all: v })} />}
      <Toggle title="Скрывать, если пусто" text="Нет товаров — блок не показывается" checked={!b.show_empty} onChange={(v) => change({ show_empty: !v })} />
    </>
  )
}

interface AdminBanner {
  id: string
  title: string
  image_url: string
  color: string
  is_active: boolean
  owner?: 'platform' | 'network'
  moderation?: 'pending' | 'approved' | 'rejected'
  reject_reason?: string
}

function bannerState(x?: AdminBanner): { text: string; ok: boolean } {
  if (!x) return { text: '', ok: false }
  if (x.moderation === 'pending') return { text: 'На модерации', ok: false }
  if (x.moderation === 'rejected') return { text: `Отклонён: ${x.reject_reason}`, ok: false }
  return { text: x.is_active ? 'Активен' : 'Выключен', ok: x.is_active }
}

/** Новый баннер из фото: загрузка, название, подпись на фото. */
function NewBanner({ path, onCreated }: { path: string; onCreated: (id: string) => void }) {
  const { message } = App.useApp()
  const [url, setUrl] = useState('')
  const [title, setTitle] = useState('')
  const [showText, setShowText] = useState(false)
  const [busy, setBusy] = useState(false)
  if (!url) {
    return (
      <div className="smh-upload">
        <ImageUpload value={url} onChange={setUrl} hint="Загрузить фото баннера" />
        <span>
          <CloudUploadOutlined /> JPG или PNG · 1080 × 450
        </span>
      </div>
    )
  }
  const save = async () => {
    setBusy(true)
    try {
      const b = await api.post<AdminBanner>(path, { title: title.trim(), image_url: url, show_text: showText, color: '#E11D2A' })
      onCreated(b.id)
      setUrl('')
      setTitle('')
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="smh-new-banner">
      <img src={url} alt="" />
      <Input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Название, например −20% на овощи" maxLength={60} />
      <Toggle title="Подпись на фото" text="Название поверх фото с затемнением" checked={showText} onChange={setShowText} />
      <div style={{ display: 'flex', gap: 8 }}>
        <Button onClick={() => setUrl('')}>Отмена</Button>
        <Button type="primary" loading={busy} disabled={!title.trim()} onClick={save}>
          Добавить баннер
        </Button>
      </div>
    </div>
  )
}

function BannerSettings({ b, change, paths }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: unknown; onUpgrade?: unknown }) {
  const all = useList<AdminBanner>(paths.banners, { limit: 200 })
  const ids = b.banner_ids ?? []
  const byId = new Map((all.data ?? []).map((x) => [x.id, x]))
  return (
    <>
      <Field label="Размер">
        <Segmented
          block
          options={[
            { value: 'big', label: 'Большой · фото' },
            { value: 'strip', label: 'Узкая лента' },
          ]}
          value={b.size}
          onChange={(v) =>
            change(v === 'strip' ? { size: 'strip', title: b.title || 'Осенняя ярмарка: −25% на фрукты', icon: b.icon ?? 'tag', color: b.color ?? 'red' } : { size: 'big' })
          }
        />
      </Field>
      {b.size === 'strip' ? (
        <>
          <Field label="Текст">
            <Input value={b.title} maxLength={60} onChange={(e) => change({ title: e.target.value })} />
          </Field>
          <Field label="Иконка">
            <IconPicker value={b.icon} onChange={(icon) => change({ icon })} />
          </Field>
          <Field label="Цвет">
            <ColorPicker value={b.color} onChange={(color) => change({ color })} />
          </Field>
          <LinkPicker value={b.link} onChange={(link) => change({ link })} paths={paths} />
        </>
      ) : (
        <>
          <Field label="Баннеры (листаются по порядку)" hint={ids.length ? undefined : 'Ничего не выбрано — показываются все активные баннеры.'}>
            <Ordered
              ids={ids}
              onChange={(next) => change({ banner_ids: next })}
              render={(id) => {
                const x = byId.get(id)
                return (
                  <span className="smh-thumb-row">
                    {x?.image_url ? <img src={x.image_url} alt="" /> : <i style={{ background: x?.color }} />}
                    <span>
                      {x?.title ?? '…'}
                      <small className={bannerState(x).ok ? 'ok' : ''}>{bannerState(x).text}</small>
                    </span>
                  </span>
                )
              }}
            />
            <Select
              value={null}
              placeholder="+ Добавить загруженный баннер"
              options={(all.data ?? [])
                .filter((x) => !ids.includes(x.id) && x.moderation !== 'rejected')
                .map((x) => ({ value: x.id, label: `${x.title}${x.moderation === 'pending' ? ' · на модерации' : ''}` }))}
              onChange={(id) => id && change({ banner_ids: [...ids, id].slice(0, 10) })}
              style={{ width: '100%' }}
            />
          </Field>
          <NewBanner path={paths.banners} onCreated={(id) => { all.refetch(); change({ banner_ids: [...ids, id].slice(0, 10) }) }} />
          <Toggle title="Автопрокрутка" text="Листать каждые 5 секунд" checked={b.autoplay !== false} onChange={(v) => change({ autoplay: v })} />
        </>
      )}
    </>
  )
}

function PromoSettings({ b, change, paths }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: unknown; onUpgrade?: unknown }) {
  return (
    <>
      <Field label="Что показывать">
        <Segmented
          block
          options={[
            { value: 'custom', label: 'Свой текст' },
            { value: 'free_delivery', label: 'До бесплатной доставки' },
          ]}
          value={b.kind}
          onChange={(v) => change(v === 'custom' ? { kind: 'custom', title: b.title || 'Скидка 10% на первый заказ', color: b.color ?? 'yellow', icon: b.icon ?? 'percent' } : { kind: 'free_delivery' })}
        />
      </Field>
      {b.kind === 'free_delivery' ? (
        <div className="smh-note">Текст считается сам: «Доставка 0 сум от …» и сколько ещё набрать. Блок скрыт, если у магазина нет бесплатной доставки.</div>
      ) : (
        <>
          <Field label="Текст">
            <Input value={b.title} maxLength={60} onChange={(e) => change({ title: e.target.value })} />
          </Field>
          <Field label="Подпись">
            <Input value={b.subtitle} maxLength={80} onChange={(e) => change({ subtitle: e.target.value })} placeholder="Необязательно" />
          </Field>
          <Field label="Иконка">
            <IconPicker value={b.icon} onChange={(icon) => change({ icon })} />
          </Field>
          <Field label="Цвет">
            <ColorPicker value={b.color} onChange={(color) => change({ color })} />
          </Field>
          <LinkPicker value={b.link} onChange={(link) => change({ link })} paths={paths} />
        </>
      )}
    </>
  )
}

function CategoryPick({ value, onChange, path, placeholder }: { value?: string[]; onChange: (v: string[]) => void; path: string; placeholder: string }) {
  return (
    <RemoteSelect
      mode="multiple"
      path={path}
      value={value ?? []}
      onChange={(v) => onChange(v as string[])}
      placeholder={placeholder}
      style={{ width: '100%' }}
    />
  )
}

function IconsSettings({ b, change, paths }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: unknown; onUpgrade?: unknown }) {
  return (
    <>
      <Field label="Какие разделы">
        <Segmented
          block
          options={[
            { value: 'auto', label: 'Все разделы магазина' },
            { value: 'manual', label: 'Выбрать' },
          ]}
          value={b.mode}
          onChange={(v) => change({ mode: v as string })}
        />
      </Field>
      {b.mode === 'manual' && (
        <Field label="Категории" hint="В этом порядке; категории без товаров в магазине не показываются.">
          <CategoryPick path={paths.categories} value={b.category_ids} onChange={(category_ids) => change({ category_ids })} placeholder="Выберите категории" />
        </Field>
      )}
      <Field label="Вид">
        <Segmented block options={SHAPES} value={b.shape} onChange={(v) => change({ shape: v as HomeBlock['shape'] })} />
      </Field>
      <Toggle title="«Скидки» первой иконкой" checked={b.show_deals !== false} onChange={(v) => change({ show_deals: v })} />
    </>
  )
}

function CatalogSettings({ b, change, paths }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: unknown; onUpgrade?: unknown }) {
  return (
    <>
      <Field label="Разделы">
        <Segmented
          block
          options={[
            { value: 'all', label: 'Все' },
            { value: 'selected', label: 'Выбранные' },
          ]}
          value={b.mode}
          onChange={(v) => change({ mode: v as string })}
        />
      </Field>
      {b.mode === 'selected' && (
        <Field label="Разделы каталога">
          <CategoryPick path={paths.categories} value={b.category_ids} onChange={(category_ids) => change({ category_ids })} placeholder="Выберите разделы" />
        </Field>
      )}
      <Field label="Вид">
        <Segmented block options={CATALOG_VIEWS} value={b.view} onChange={(v) => change({ view: v as string })} />
      </Field>
      <Toggle title="Картинки категорий" text="Без картинки — иконка" checked={b.show_images !== false} onChange={(v) => change({ show_images: v })} />
    </>
  )
}

/** Панель настроек блока. */
export function BlockSettings({
  b,
  onChange,
  onDelete,
  paths,
  canPin,
  features,
  onUpgrade,
}: {
  b: HomeBlock
  onChange: (b: HomeBlock) => void
  onDelete: () => void
  paths: EditorPaths
  canPin?: boolean
  features?: { schedule?: boolean; manual?: boolean }
  onUpgrade?: (feature: string) => void
}) {
  const change: Change = (patch) => onChange({ ...b, ...patch })
  const meta = typeMeta(b.type)
  const scheduled = !!(b.starts_at || b.ends_at)
  const body = {
    shelf: ShelfSettings,
    banners: BannerSettings,
    promo: PromoSettings,
    category_icons: IconsSettings,
    catalog_sections: CatalogSettings,
  }[b.type]
  const Body = body
  return (
    <div className="smh-settings">
      <div className="smh-settings-head">
        <span className="smh-block-icon">{meta.icon}</span>
        <div>
          <b>{meta.title}</b>
          <span>Настройки блока</span>
        </div>
      </div>
      <Body b={b} change={change} paths={paths} features={features} onUpgrade={onUpgrade} />
      <div className="smh-sep" />
      {features?.schedule === false && !scheduled ? (
        <div className="smh-locked">
          <LockFilled />
          <b>Расписание блоков</b>
          <span>Блок сам включится и выключится по датам. Доступно в тарифе «Про».</span>
          <Button type="primary" danger onClick={() => onUpgrade?.('schedule')}>
            Перейти на «Про»
          </Button>
        </div>
      ) : (
      <>
      <Field label="Показывать">
        <Segmented
          block
          options={[
            { value: 'always', label: 'Всегда' },
            { value: 'schedule', label: 'По расписанию' },
          ]}
          value={scheduled ? 'schedule' : 'always'}
          onChange={(v) =>
            change(v === 'always' ? { starts_at: null, ends_at: null } : { starts_at: dayjs().startOf('day').toISOString(), ends_at: dayjs().add(7, 'day').endOf('day').toISOString() })
          }
        />
      </Field>
      {scheduled && (
        <DatePicker.RangePicker
          style={{ width: '100%', marginBottom: 16 }}
          format="DD.MM.YYYY"
          allowEmpty={[true, true]}
          value={[b.starts_at ? dayjs(b.starts_at) : null, b.ends_at ? dayjs(b.ends_at) : null]}
          onChange={(r) => change({ starts_at: r?.[0] ? r[0].startOf('day').toISOString() : null, ends_at: r?.[1] ? r[1].endOf('day').toISOString() : null })}
        />
      )}
      </>
      )}
      {canPin && (
        <Toggle
          title="Закрепить для магазинов"
          text="Сети не смогут убрать или выключить блок в своей витрине"
          checked={!!b.pinned}
          onChange={(v) => change({ pinned: v })}
        />
      )}
      <Button danger block icon={<DeleteOutlined />} onClick={onDelete} style={{ marginTop: 8 }}>
        Удалить блок
      </Button>
      {b.pinned && (
        <div className="smh-field-hint" style={{ marginTop: 8 }}>
          <PushpinFilled /> Блок закреплён платформой
        </div>
      )}
    </div>
  )
}
