// Настройки выбранного блока (Figma «Админка · Главная приложения»).
import { useState, type ReactNode } from 'react'
import { App, Button, DatePicker, Input, InputNumber, Segmented, Select, Switch, Tooltip } from 'antd'
import { CloseOutlined, DeleteOutlined, PushpinFilled, UpOutlined, DownOutlined, LockFilled } from '@ant-design/icons'
import dayjs from 'dayjs'
import { api } from '../api'
import { RemoteSelect } from '../components'
import { useItem, useList, errorText } from '../hooks'
import { BannerUpload } from '../crop'
import { CATALOG_VIEWS, COLORS, ICONS, LINKS, SHAPES, SHELF_VIEWS, SOURCES, typeMeta } from './meta'
import type { BlockLink, HomeBlock } from './types'
import { tr } from '../i18n'

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
    <Field label={tr('При нажатии открыть', 'Bosilganda ochish')}>
      <Select value={t} options={LINKS} onChange={(type) => onChange({ type })} style={{ width: '100%' }} />
      {t === 'category' && (
        <RemoteSelect path={paths.categories} value={value?.id} onChange={(id) => onChange({ type: t, id: id as string })} placeholder={tr('Категория', 'Kategoriya')} style={{ width: '100%', marginTop: 8 }} />
      )}
      {t === 'product' && (
        <RemoteSelect search path={paths.products} value={value?.id} onChange={(id) => onChange({ type: t, id: id as string })} placeholder={tr('Найти товар', 'Mahsulotni topish')} style={{ width: '100%', marginTop: 8 }} />
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
      <Field label={tr('Заголовок', 'Sarlavha')}>
        <Input value={b.title} maxLength={40} onChange={(e) => change({ title: e.target.value })} />
      </Field>
      <Field label={tr('Откуда брать товары', 'Mahsulotlar qayerdan olinsin')}>
        <Segmented
          block
          options={SOURCES.map((o) => (o.value === 'manual' && manualLocked ? { ...o, label: <span><LockFilled /> {o.label}</span> } : o))}
          value={b.source}
          onChange={(v) => (v === 'manual' && manualLocked ? onUpgrade?.('manual') : change({ source: v as HomeBlock['source'] }))}
        />
      </Field>
      {b.source === 'category' && (
        <Field label={tr('Категория', 'Kategoriya')}>
          <RemoteSelect path={paths.categories} value={b.category_id} onChange={(v) => change({ category_id: v as string })} placeholder={tr('Выберите категорию', 'Kategoriyani tanlang')} style={{ width: '100%' }} />
        </Field>
      )}
      {b.source === 'manual' && (
        <Field label={tr('Товары подборки', 'Tanlov mahsulotlari')} hint={tr('Порядок — как в приложении. До 30 товаров.', 'Tartib — ilovadagidek. 30 tagacha mahsulot.')}>
          <Ordered ids={ids} onChange={(next) => change({ product_ids: next })} render={(id) => <ProductName path={paths.products} id={id} />} />
          <RemoteSelect
            search
            path={paths.products}
            value={null}
            placeholder={tr('+ Добавить товар', '+ Mahsulot qoʻshish')}
            filter={(p) => !ids.includes(String(p.id))}
            onChange={(id) => id && change({ product_ids: [...ids, id as string].slice(0, 30) })}
            style={{ width: '100%' }}
          />
        </Field>
      )}
      <div className="smh-pair">
        <Field label={tr('Сколько товаров', 'Mahsulotlar soni')}>
          <InputNumber min={1} max={20} value={b.limit} onChange={(v) => change({ limit: v ?? 6 })} style={{ width: 96 }} />
        </Field>
        <Field label={tr('Вид', 'Koʻrinish')}>
          <Segmented options={SHELF_VIEWS} value={b.view} onChange={(v) => change({ view: v as string })} />
        </Field>
      </div>
      {b.source !== 'manual' && <Toggle title={tr('Кнопка «Все»', '«Hammasi» tugmasi')} text={tr('Открывает полный список', 'Toʻliq roʻyxatni ochadi')} checked={b.show_all !== false} onChange={(v) => change({ show_all: v })} />}
      <Toggle title={tr('Скрывать, если пусто', 'Boʻsh boʻlsa, yashirish')} text={tr('Нет товаров — блок не показывается', 'Mahsulot yoʻq — blok koʻrsatilmaydi')} checked={!b.show_empty} onChange={(v) => change({ show_empty: !v })} />
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
  if (x.moderation === 'pending') return { text: tr('На модерации', 'Moderatsiyada'), ok: false }
  if (x.moderation === 'rejected') return { text: tr(`Отклонён: ${x.reject_reason}`, `Rad etilgan: ${x.reject_reason}`), ok: false }
  return { text: x.is_active ? tr('Активен', 'Faol') : tr('Выключен', 'Oʻchirilgan'), ok: x.is_active }
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
        <BannerUpload value={url} onChange={setUrl} />
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
      <Input value={title} onChange={(e) => setTitle(e.target.value)} placeholder={tr('Название, например −20% на овощи', 'Nomi, masalan, sabzavotlarga −20%')} maxLength={60} />
      <Toggle title={tr('Подпись на фото', 'Rasmdagi yozuv')} text={tr('Название поверх фото с затемнением', 'Nomi rasm ustida, qoraytirilgan holda')} checked={showText} onChange={setShowText} />
      <div style={{ display: 'flex', gap: 8 }}>
        <Button onClick={() => setUrl('')}>{tr('Отмена', 'Bekor qilish')}</Button>
        <Button type="primary" loading={busy} disabled={!title.trim()} onClick={save}>
          {tr('Добавить баннер', 'Banner qoʻshish')}
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
      <Field label={tr('Размер', 'Oʻlcham')}>
        <Segmented
          block
          options={[
            { value: 'big', label: tr('Большой · фото', 'Katta · rasm') },
            { value: 'strip', label: tr('Узкая лента', 'Tor lenta') },
          ]}
          value={b.size}
          onChange={(v) =>
            change(v === 'strip' ? { size: 'strip', title: b.title || tr('Осенняя ярмарка: −25% на фрукты', 'Kuzgi yarmarka: mevalarga −25%'), icon: b.icon ?? 'tag', color: b.color ?? 'red' } : { size: 'big' })
          }
        />
      </Field>
      {b.size === 'strip' ? (
        <>
          <Field label={tr('Текст', 'Matn')}>
            <Input value={b.title} maxLength={60} onChange={(e) => change({ title: e.target.value })} />
          </Field>
          <Field label={tr('Иконка', 'Belgi')}>
            <IconPicker value={b.icon} onChange={(icon) => change({ icon })} />
          </Field>
          <Field label={tr('Цвет', 'Rang')}>
            <ColorPicker value={b.color} onChange={(color) => change({ color })} />
          </Field>
          <LinkPicker value={b.link} onChange={(link) => change({ link })} paths={paths} />
        </>
      ) : (
        <>
          <Field label={tr('Баннеры (листаются по порядку)', 'Bannerlar (tartib bilan almashadi)')} hint={ids.length ? undefined : tr('Ничего не выбрано — показываются все активные баннеры.', 'Hech narsa tanlanmagan — barcha faol bannerlar koʻrsatiladi.')}>
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
              placeholder={tr('+ Добавить загруженный баннер', '+ Yuklangan bannerni qoʻshish')}
              options={(all.data ?? [])
                .filter((x) => !ids.includes(x.id) && x.moderation !== 'rejected')
                .map((x) => ({ value: x.id, label: `${x.title}${x.moderation === 'pending' ? tr(' · на модерации', ' · moderatsiyada') : ''}` }))}
              onChange={(id) => id && change({ banner_ids: [...ids, id].slice(0, 10) })}
              style={{ width: '100%' }}
            />
          </Field>
          <NewBanner path={paths.banners} onCreated={(id) => { all.refetch(); change({ banner_ids: [...ids, id].slice(0, 10) }) }} />
          <Toggle title={tr('Автопрокрутка', 'Avtoaylantirish')} text={tr('Листать каждые 5 секунд', 'Har 5 soniyada almashtirish')} checked={b.autoplay !== false} onChange={(v) => change({ autoplay: v })} />
        </>
      )}
    </>
  )
}

function PromoSettings({ b, change, paths }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: unknown; onUpgrade?: unknown }) {
  return (
    <>
      <Field label={tr('Что показывать', 'Nima koʻrsatilsin')}>
        <Segmented
          block
          options={[
            { value: 'custom', label: tr('Свой текст', 'Oʻz matningiz') },
            { value: 'free_delivery', label: tr('До бесплатной доставки', 'Bepul yetkazib berishgacha') },
          ]}
          value={b.kind}
          onChange={(v) => change(v === 'custom' ? { kind: 'custom', title: b.title || tr('Скидка 10% на первый заказ', 'Birinchi buyurtmaga 10% chegirma'), color: b.color ?? 'yellow', icon: b.icon ?? 'percent' } : { kind: 'free_delivery' })}
        />
      </Field>
      {b.kind === 'free_delivery' ? (
        <div className="smh-note">
          {tr(
            'Текст считается сам: «Доставка 0 сум от …» и сколько ещё набрать. Блок скрыт, если у магазина нет бесплатной доставки.',
            'Matn oʻzi hisoblanadi: «… dan yetkazib berish 0 soʻm» va yana qancha xarid qilish kerakligi. Doʻkonda bepul yetkazib berish boʻlmasa, blok yashiriladi.',
          )}
        </div>
      ) : (
        <>
          <Field label={tr('Текст', 'Matn')}>
            <Input value={b.title} maxLength={60} onChange={(e) => change({ title: e.target.value })} />
          </Field>
          <Field label={tr('Подпись', 'Izoh')}>
            <Input value={b.subtitle} maxLength={80} onChange={(e) => change({ subtitle: e.target.value })} placeholder={tr('Необязательно', 'Ixtiyoriy')} />
          </Field>
          <Field label={tr('Иконка', 'Belgi')}>
            <IconPicker value={b.icon} onChange={(icon) => change({ icon })} />
          </Field>
          <Field label={tr('Цвет', 'Rang')}>
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
      <Field label={tr('Какие разделы', 'Qaysi boʻlimlar')}>
        <Segmented
          block
          options={[
            { value: 'auto', label: tr('Все разделы магазина', 'Doʻkonning barcha boʻlimlari') },
            { value: 'manual', label: tr('Выбрать', 'Tanlash') },
          ]}
          value={b.mode}
          onChange={(v) => change({ mode: v as string })}
        />
      </Field>
      {b.mode === 'manual' && (
        <Field label={tr('Категории', 'Kategoriyalar')} hint={tr('В этом порядке; категории без товаров в магазине не показываются.', 'Shu tartibda; doʻkonda mahsuloti yoʻq kategoriyalar koʻrsatilmaydi.')}>
          <CategoryPick path={paths.categories} value={b.category_ids} onChange={(category_ids) => change({ category_ids })} placeholder={tr('Выберите категории', 'Kategoriyalarni tanlang')} />
        </Field>
      )}
      <Field label={tr('Вид', 'Koʻrinish')}>
        <Segmented block options={SHAPES} value={b.shape} onChange={(v) => change({ shape: v as HomeBlock['shape'] })} />
      </Field>
      <Toggle title={tr('«Скидки» первой иконкой', '«Chegirmalar» birinchi belgi boʻlib')} checked={b.show_deals !== false} onChange={(v) => change({ show_deals: v })} />
    </>
  )
}

function CatalogSettings({ b, change, paths }: { b: HomeBlock; change: Change; paths: EditorPaths; features?: unknown; onUpgrade?: unknown }) {
  return (
    <>
      <Field label={tr('Разделы', 'Boʻlimlar')}>
        <Segmented
          block
          options={[
            { value: 'all', label: tr('Все', 'Hammasi') },
            { value: 'selected', label: tr('Выбранные', 'Tanlanganlar') },
          ]}
          value={b.mode}
          onChange={(v) => change({ mode: v as string })}
        />
      </Field>
      {b.mode === 'selected' && (
        <Field label={tr('Разделы каталога', 'Katalog boʻlimlari')}>
          <CategoryPick path={paths.categories} value={b.category_ids} onChange={(category_ids) => change({ category_ids })} placeholder={tr('Выберите разделы', 'Boʻlimlarni tanlang')} />
        </Field>
      )}
      <Field label={tr('Вид', 'Koʻrinish')}>
        <Segmented block options={CATALOG_VIEWS} value={b.view} onChange={(v) => change({ view: v as string })} />
      </Field>
      <Toggle title={tr('Картинки категорий', 'Kategoriya rasmlari')} text={tr('Без картинки — иконка', 'Rasm boʻlmasa — belgi')} checked={b.show_images !== false} onChange={(v) => change({ show_images: v })} />
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
          <span>{tr('Настройки блока', 'Blok sozlamalari')}</span>
        </div>
      </div>
      <Body b={b} change={change} paths={paths} features={features} onUpgrade={onUpgrade} />
      <div className="smh-sep" />
      {features?.schedule === false && !scheduled ? (
        <div className="smh-locked">
          <LockFilled />
          <b>{tr('Расписание блоков', 'Bloklar jadvali')}</b>
          <span>{tr('Блок сам включится и выключится по датам. Доступно в тарифе «Про».', 'Blok sanalar boʻyicha oʻzi yoqiladi va oʻchadi. «Pro» tarifida mavjud.')}</span>
          <Button type="primary" danger onClick={() => onUpgrade?.('schedule')}>
            {tr('Перейти на «Про»', '«Pro» tarifiga oʻtish')}
          </Button>
        </div>
      ) : (
      <>
      <Field label={tr('Показывать', 'Koʻrsatish')}>
        <Segmented
          block
          options={[
            { value: 'always', label: tr('Всегда', 'Doim') },
            { value: 'schedule', label: tr('По расписанию', 'Jadval boʻyicha') },
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
          title={tr('Закрепить для магазинов', 'Doʻkonlar uchun qadash')}
          text={tr('Сети не смогут убрать или выключить блок в своей витрине', 'Tarmoqlar blokni oʻz vitrinasidan olib tashlay yoki oʻchira olmaydi')}
          checked={!!b.pinned}
          onChange={(v) => change({ pinned: v })}
        />
      )}
      <Button danger block icon={<DeleteOutlined />} onClick={onDelete} style={{ marginTop: 8 }}>
        {tr('Удалить блок', 'Blokni oʻchirish')}
      </Button>
      {b.pinned && (
        <div className="smh-field-hint" style={{ marginTop: 8 }}>
          <PushpinFilled /> {tr('Блок закреплён платформой', 'Blok platforma tomonidan qadalgan')}
        </div>
      )}
    </div>
  )
}
