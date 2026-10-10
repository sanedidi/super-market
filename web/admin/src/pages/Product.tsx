// Товар супер-админа — отдельная страница вместо модалки (Figma «Товар —
// отдельная страница вместо модалки», ТТ1, ТТ2, ТТ1а): слева — поля товара по
// карточкам, справа — статус, вид в приложении, вариации и где продаётся.
// /products/new — та же страница пустая.
import { useEffect, useMemo, useRef, useState, type DragEvent, type ReactNode } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Alert,
  App,
  Button,
  Card,
  Checkbox,
  Col,
  Flex,
  Form,
  Image,
  Input,
  InputNumber,
  Modal,
  Row,
  Segmented,
  Skeleton,
  Space,
  Switch,
  Table,
  Tag,
  Tooltip,
  Typography,
  Upload,
} from 'antd'
import {
  ArrowLeftOutlined,
  ArrowRightOutlined,
  BarcodeOutlined,
  CheckOutlined,
  ClockCircleOutlined,
  CloseOutlined,
  DeleteOutlined,
  EyeOutlined,
  LoadingOutlined,
  PictureOutlined,
  PlusOutlined,
  ShopOutlined,
  StopOutlined,
} from '@ant-design/icons'
import {
  FormTranslate,
  LoadError,
  RemoteSelect,
  StatusTag,
  api,
  date,
  dateTime,
  errorText,
  money,
  useLeaveGuard,
  useRemove,
  withRawRu,
  type Lang,
} from '@sm/shared'
import { SearchSelect } from '../components'
import { usePhotoJob, usd, type PhotoJob } from '../photoJob'

export interface Product {
  id: string
  network_id: string | null
  name: string
  description: string
  brand_id: string | null
  brand_name: string | null
  category_id: string
  category_name: string
  unit_id: string
  unit_short: string
  color_id: string | null
  base_price: string
  images: string[]
  barcodes: string[]
  moderation_status: string
  rejection_reason: string
  is_active: boolean
  created_at: string
  attributes: Record<string, unknown> | null
  name_uz?: string | null
  description_uz?: string | null
  name_ru?: string
  description_ru?: string
}

interface Overview {
  updated_at: string
  source: string
  network_name: string | null
  tax: { ikpu: string; ikpu_name: string; package_code: string; vat_rate: string; marked: boolean }
  variants: {
    group_id: string
    name: string
    weight_label: string
    flavor_label: string
    weight: string
    flavor: string
    count: number
    items: { product_id: string; name: string; weight: string; flavor: string; image: string | null }[]
  } | null
  selling: {
    stores: number
    networks: number
    min_price: string | null
    max_price: string | null
    stock: string
    list: { store_id: string; store_name: string; network_name: string; price: string; stock: string }[]
  }
}

interface PhotoSettingsBrief {
  configured: boolean
  before_after: boolean
}

// Характеристики для карточки товара в приложении.
const TEXT_ATTRS: [string, string, string?][] = [
  ['composition', 'Состав'],
  ['shelf_life', 'Срок хранения', '10 суток'],
  ['storage', 'Условия хранения', 'от +2 до +6 °C'],
  ['country', 'Страна', 'Узбекистан'],
  ['manufacturer', 'Производитель'],
  ['volume', 'Объём / вес', '900 мл'],
]
const NUTRITION: [string, string][] = [
  ['kcal', 'ккал'],
  ['protein', 'белки, г'],
  ['fat', 'жиры, г'],
  ['carbs', 'углеводы, г'],
]
const ATTR_KEYS = new Set([...TEXT_ATTRS.map(([k]) => k), 'nutrition'])

const MAX_PHOTOS = 10
const CARD = { body: { padding: 24 } }

function toForm(p: Product, tax?: Overview['tax']) {
  const a = p.attributes
  const out: Record<string, unknown> = {
    ...withRawRu(p),
    images: p.images ?? [],
    barcodes: p.barcodes ?? [],
    brand_id: p.brand_id ?? undefined,
    color_id: p.color_id ?? undefined,
    base_price: Number(p.base_price),
  }
  for (const [k] of TEXT_ATTRS) out[`attr_${k}`] = (a?.[k] as string | undefined) ?? ''
  const n = (a?.nutrition ?? {}) as Record<string, number>
  for (const [k] of NUTRITION) out[`nut_${k}`] = n[k] ?? null
  if (tax) {
    out.tax_ikpu = tax.ikpu
    out.tax_package_code = tax.package_code
    out.tax_vat_rate = tax.vat_rate === '' ? null : Number(tax.vat_rate)
    out.tax_marked = tax.marked
  }
  return out
}

const EMPTY: Record<string, unknown> = {
  name: '',
  name_uz: '',
  description: '',
  description_uz: '',
  images: [],
  barcodes: [],
  is_active: true,
  tax_ikpu: '',
  tax_package_code: '',
  tax_vat_rate: 12,
  tax_marked: false,
  ...Object.fromEntries(TEXT_ATTRS.map(([k]) => [`attr_${k}`, ''])),
  ...Object.fromEntries(NUTRITION.map(([k]) => [`nut_${k}`, null])),
}

/** Тело POST/PATCH товара; характеристики не из формы (source, ikpu_name…) сохраняются. */
function toBody(v: Record<string, unknown>, prev: Product | null) {
  const attrs: Record<string, unknown> = Object.fromEntries(Object.entries(prev?.attributes ?? {}).filter(([k]) => !ATTR_KEYS.has(k)))
  for (const [k] of TEXT_ATTRS) {
    const val = String(v[`attr_${k}`] ?? '').trim()
    if (val) attrs[k] = val
  }
  const nutrition: Record<string, number> = {}
  for (const [k] of NUTRITION) {
    const val = v[`nut_${k}`]
    if (val !== null && val !== undefined && val !== '') nutrition[k] = Number(val)
  }
  if (Object.keys(nutrition).length) attrs.nutrition = nutrition
  const body: Record<string, unknown> = {
    name: v.name,
    name_uz: v.name_uz ?? '',
    description: v.description ?? '',
    description_uz: v.description_uz ?? '',
    category_id: v.category_id,
    unit_id: v.unit_id,
    base_price: v.base_price,
    // Пустая строка — убрать бренд/цвет; null сервер понимает как «не менять».
    brand_id: v.brand_id ?? '',
    color_id: v.color_id ?? '',
    images: (v.images as string[] | undefined) ?? [],
    barcodes: (v.barcodes as string[] | undefined) ?? [],
    attributes: attrs,
  }
  if (prev) body.is_active = v.is_active
  return body
}

function taxBody(v: Record<string, unknown>) {
  return {
    ikpu: String(v.tax_ikpu ?? '').trim(),
    package_code: String(v.tax_package_code ?? '').trim(),
    vat_rate: v.tax_vat_rate === null || v.tax_vat_rate === undefined ? undefined : String(v.tax_vat_rate),
    marked: !!v.tax_marked,
  }
}

/** Значения формы в сравнимом виде (для «есть несохранённые изменения»). */
function snapshot(v: Record<string, unknown>) {
  const keys = Object.keys(v).sort()
  return JSON.stringify(keys.map((k) => [k, v[k] === undefined || v[k] === '' ? null : v[k]]))
}

// ─────────────────────────────────────────────────────────── мелкие части

function CardTitle({ title, hint, extra }: { title: string; hint?: ReactNode; extra?: ReactNode }) {
  return (
    <Flex align="center" gap={16} style={{ marginBottom: 16 }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <Typography.Text strong style={{ fontSize: 16 }}>
          {title}
        </Typography.Text>
        {hint && (
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              {hint}
            </Typography.Text>
          </div>
        )}
      </div>
      {extra}
    </Flex>
  )
}

/** Подпись поля со ссылкой «Перевести» справа. */
function TrLabel({ label, from, into, to }: { label: string; from: string; into: string; to: Lang }) {
  const form = Form.useFormInstance()
  return (
    <Flex justify="space-between" align="center" style={{ width: '100%' }}>
      <span>{label}</span>
      <FormTranslate form={form} from={from} into={into} to={to} />
    </Flex>
  )
}

function SideCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Card styles={{ body: { padding: 20 } }}>
      <Typography.Text strong style={{ fontSize: 15, display: 'block', marginBottom: 12 }}>
        {title}
      </Typography.Text>
      {children}
    </Card>
  )
}

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <Flex justify="space-between" gap={12} style={{ fontSize: 13 }}>
      <Typography.Text type="secondary">{label}</Typography.Text>
      <span style={{ textAlign: 'right' }}>{children}</span>
    </Flex>
  )
}

// ─────────────────────────────────────────────────────────── фото

/** Фото товара: первое — главное, порядок — перетаскиванием. */
function PhotoGrid({ value = [], onChange, disabled }: { value?: string[]; onChange?: (v: string[]) => void; disabled?: boolean }) {
  const { message } = App.useApp()
  const [busy, setBusy] = useState(0)
  const [drag, setDrag] = useState<number | null>(null)
  const [preview, setPreview] = useState<string | null>(null)
  const current = useRef(value)
  current.current = value

  const move = (from: number, to: number) => {
    if (from === to) return
    const next = [...value]
    const [x] = next.splice(from, 1)
    next.splice(to, 0, x)
    onChange?.(next)
  }

  const upload = async (file: File) => {
    setBusy((n) => n + 1)
    try {
      const url = await api.upload(file, file.name)
      current.current = [...current.current, url].slice(0, MAX_PHOTOS)
      onChange?.(current.current)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy((n) => n - 1)
    }
  }

  const tile = { width: 120, height: 120, borderRadius: 12, position: 'relative' as const, overflow: 'hidden' }
  return (
    <Flex gap={12} wrap>
      {value.map((u, i) => (
        <div
          key={u + i}
          draggable={!disabled}
          onDragStart={() => setDrag(i)}
          onDragOver={(e: DragEvent) => e.preventDefault()}
          onDrop={() => {
            if (drag !== null) move(drag, i)
            setDrag(null)
          }}
          onDragEnd={() => setDrag(null)}
          className="sm-photo-tile"
          style={{
            ...tile,
            border: i === 0 ? '2px solid #101828' : '1px solid #EAECF0',
            opacity: drag === i ? 0.4 : 1,
            cursor: disabled ? 'default' : 'grab',
            background: '#fff',
          }}
        >
          <img src={u} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain' }} draggable={false} />
          {i === 0 && (
            <span style={{ position: 'absolute', top: 6, left: 6, background: '#1F2937', color: '#fff', fontSize: 11, fontWeight: 700, borderRadius: 6, padding: '1px 6px' }}>
              Главное
            </span>
          )}
          <Flex className="sm-photo-actions" gap={4} style={{ position: 'absolute', right: 6, bottom: 6 }}>
            <Button size="small" icon={<EyeOutlined />} onClick={() => setPreview(u)} />
            {!disabled && <Button size="small" danger icon={<DeleteOutlined />} onClick={() => onChange?.(value.filter((_, j) => j !== i))} />}
          </Flex>
        </div>
      ))}
      {value.length + busy < MAX_PHOTOS && !disabled && (
        <Upload
          accept="image/jpeg,image/png,image/webp,image/gif"
          multiple
          showUploadList={false}
          beforeUpload={(f) => {
            if (f.size > 8 * 1024 * 1024) {
              message.error('Фото больше 8 МБ')
              return Upload.LIST_IGNORE
            }
            void upload(f)
            return false
          }}
        >
          <Flex
            vertical
            align="center"
            justify="center"
            gap={6}
            style={{ ...tile, background: '#F9FAFB', border: '1px dashed #D0D5DD', cursor: 'pointer', color: '#667085' }}
          >
            {busy > 0 ? <LoadingOutlined style={{ fontSize: 22 }} /> : <PictureOutlined style={{ fontSize: 24, color: '#98A2B3' }} />}
            <Typography.Text strong style={{ fontSize: 12, color: '#667085' }}>
              {busy > 0 ? 'Загрузка…' : 'Добавить'}
            </Typography.Text>
          </Flex>
        </Upload>
      )}
      {preview && (
        <Image style={{ display: 'none' }} src={preview} preview={{ visible: true, src: preview, onVisibleChange: (v) => !v && setPreview(null) }} />
      )}
    </Flex>
  )
}

/** ТТ1а: «до / после» Gemini с галочкой на каждом фото. */
function NormalizeResult({ job, onApply, onCancel }: { job: PhotoJob; onApply: (picked: Record<string, string>) => void; onCancel: () => void }) {
  const ok = job.items.filter((it) => it.result)
  // По умолчанию отмечено всё, что Gemini сделал; снятая галочка — «оставить своё».
  const [off, setOff] = useState<Record<string, boolean>>({})
  const picked = (src: string) => !off[src]
  const count = ok.filter((it) => picked(it.source)).length
  const thumb = { width: 88, height: 88, borderRadius: 10, objectFit: 'contain' as const, background: '#fff', border: '1px solid #EAECF0' }
  return (
    <div style={{ marginTop: 16, padding: 16, borderRadius: 12, background: '#FAF8FF', border: '1px solid #E4DBFF' }}>
      <Flex align="center" gap={8} style={{ marginBottom: 14 }}>
        <span style={{ color: '#6E56CF' }}>✦</span>
        <Typography.Text strong style={{ flex: 1 }}>
          {job.running
            ? `Gemini обрабатывает фото… ${job.items.filter((it) => it.done).length} из ${job.items.length}`
            : ok.length
              ? `Gemini подготовил ${ok.length} фото — проверьте и примените`
              : 'Gemini не смог обработать фото'}
        </Typography.Text>
        {job.cost_usd > 0 && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {usd(job.cost_usd)}
          </Typography.Text>
        )}
      </Flex>
      <Flex gap={20} wrap>
        {job.items.map((it, i) => (
          <Flex key={it.source + i} vertical gap={8}>
            <Flex align="center" gap={6}>
              <img src={it.source} alt="" style={thumb} />
              <ArrowRightOutlined style={{ color: '#98A2B3' }} />
              {it.result ? (
                <Image src={it.result} width={88} height={88} style={thumb} />
              ) : (
                <Flex align="center" justify="center" style={{ ...thumb, color: '#98A2B3' }}>
                  {it.done ? <CloseOutlined style={{ color: '#D92D20' }} /> : <LoadingOutlined />}
                </Flex>
              )}
            </Flex>
            {it.result ? (
              <Checkbox checked={picked(it.source)} onChange={(e) => setOff((p) => ({ ...p, [it.source]: !e.target.checked }))}>
                <Typography.Text style={{ fontSize: 12 }}>
                  {i === 0 ? 'Главное' : `Фото ${i + 1}`} · {picked(it.source) ? 'заменить' : 'оставить своё'}
                </Typography.Text>
              </Checkbox>
            ) : (
              it.done && (
                <Typography.Text type="danger" style={{ fontSize: 12, maxWidth: 182 }}>
                  {it.error || 'не получилось'}
                </Typography.Text>
              )
            )}
          </Flex>
        ))}
      </Flex>
      <Flex align="center" gap={10} wrap style={{ marginTop: 14 }}>
        <Typography.Text type="secondary" style={{ fontSize: 12, flex: 1, minWidth: 200 }}>
          Оригиналы сохраняются — фото можно вернуть. Настройки — «ИИ для фото».
        </Typography.Text>
        <Button onClick={onCancel}>Отменить</Button>
        <Button
          type="primary"
          icon={<CheckOutlined />}
          disabled={job.running || count === 0}
          onClick={() => onApply(Object.fromEntries(ok.filter((it) => picked(it.source)).map((it) => [it.source, it.result])))}
        >
          Применить к {count} фото
        </Button>
      </Flex>
    </div>
  )
}

/** Карточка «Фото» с «Нормализовать фото» (Gemini из «ИИ для фото»). */
function PhotosCard({ productId }: { productId?: string }) {
  const form = Form.useFormInstance()
  const { message } = App.useApp()
  const images = (Form.useWatch('images', form) as string[] | undefined) ?? []
  const photo = useQuery({ queryKey: ['/admin/ai-photo'], queryFn: () => api.get<PhotoSettingsBrief>('/admin/ai-photo') })
  const [shown, setShown] = useState(false)
  const apply = (picked: Record<string, string>) => {
    const cur = (form.getFieldValue('images') as string[] | undefined) ?? []
    form.setFieldValue(
      'images',
      cur.map((u) => picked[u] ?? u),
    )
    // setFieldValue не вызывает onValuesChange — сообщаем форме сами.
    form.validateFields(['images']).catch(() => undefined)
    form.setFields([{ name: 'images', touched: true }])
    window.dispatchEvent(new Event('sm-product-changed'))
    setShown(false)
    job.reset()
    message.success('Фото заменены — не забудьте сохранить товар')
  }
  const job = usePhotoJob((j) => {
    const ok = j.items.filter((it) => it.result)
    if (!ok.length) return
    // «До / после» выключено в настройках — ставим всё готовое сразу.
    if (photo.data && !photo.data.before_after) apply(Object.fromEntries(ok.map((it) => [it.source, it.result])))
  })
  const configured = !!photo.data?.configured
  const start = () => {
    setShown(true)
    void job.start('/admin/ai-photo/normalize', { product_id: productId, images })
  }
  const label = job.running
    ? `Gemini обрабатывает… ${job.job?.items.filter((it) => it.done).length ?? 0}/${images.length}`
    : job.job && shown
      ? `Готово · ${job.job.items.filter((it) => it.result).length} фото`
      : 'Нормализовать фото'
  const button = (
    <Button
      icon={job.running ? <LoadingOutlined /> : <span style={{ fontSize: 15 }}>✦</span>}
      disabled={!configured || !images.length || job.running}
      onClick={start}
      style={configured && images.length ? { background: '#F4F0FF', borderColor: '#C9B8FF', color: '#4B3A9E', fontWeight: 700 } : { fontWeight: 700 }}
    >
      {label}
    </Button>
  )
  return (
    <Card styles={CARD}>
      <CardTitle
        title="Фото"
        hint="До 10 фото, первое — главное. Перетащите, чтобы поменять порядок. «Нормализовать» — Gemini делает фото квадратными, на белом фоне, товар целиком."
        extra={
          configured ? (
            button
          ) : (
            <Tooltip title={photo.isLoading ? '' : 'Подключите ИИ для фото: «ИИ для фото» в меню'}>
              <span>{button}</span>
            </Tooltip>
          )
        }
      />
      <Form.Item name="images" noStyle>
        <PhotoGrid disabled={job.running} />
      </Form.Item>
      {job.error && <Alert style={{ marginTop: 16 }} type="error" showIcon message={job.error} />}
      {shown && job.job && (
        <NormalizeResult
          key={job.job.id}
          job={job.job}
          onApply={apply}
          onCancel={() => {
            setShown(false)
            job.reset()
          }}
        />
      )}
    </Card>
  )
}

/** Штрихкоды — фишки с «×» и «+ Добавить штрихкод». */
function BarcodesInput({ value = [], onChange }: { value?: string[]; onChange?: (v: string[]) => void }) {
  const [adding, setAdding] = useState<string | null>(null)
  const add = () => {
    const parts = (adding ?? '')
      .split(/[\s,;]+/)
      .map((s) => s.trim())
      .filter(Boolean)
    const next = [...value]
    for (const p of parts) if (!next.includes(p)) next.push(p)
    onChange?.(next)
    setAdding(null)
  }
  return (
    <Flex gap={8} wrap align="center">
      {value.map((b) => (
        <Tag
          key={b}
          closable
          onClose={(e) => {
            e.preventDefault()
            onChange?.(value.filter((x) => x !== b))
          }}
          icon={<BarcodeOutlined />}
          style={{ fontSize: 14, padding: '5px 10px', margin: 0, background: '#F2F4F7', border: 'none' }}
        >
          {b}
        </Tag>
      ))}
      {adding === null ? (
        <Button icon={<PlusOutlined />} style={{ borderStyle: 'dashed' }} onClick={() => setAdding('')}>
          Добавить штрихкод
        </Button>
      ) : (
        <Input
          autoFocus
          style={{ width: 220 }}
          value={adding}
          placeholder="Сканируйте или введите"
          onChange={(e) => setAdding(e.target.value)}
          onPressEnter={(e) => {
            e.preventDefault()
            add()
          }}
          onBlur={add}
          suffix={<BarcodeOutlined style={{ color: '#98A2B3' }} />}
        />
      )}
    </Flex>
  )
}

// ─────────────────────────────────────────────────────────── правая колонка

function AppPreview({ unit }: { unit: string }) {
  const form = Form.useFormInstance()
  const [lang, setLang] = useState<Lang>('ru')
  const name = Form.useWatch('name', form) as string | undefined
  const nameUz = Form.useWatch('name_uz', form) as string | undefined
  const price = Form.useWatch('base_price', form) as number | undefined
  const images = Form.useWatch('images', form) as string[] | undefined
  const shown = lang === 'uz' ? nameUz?.trim() || name : name
  return (
    <SideCard title="Как в приложении">
      <Flex gap={14}>
        <Flex align="center" justify="center" style={{ width: 110, height: 110, flex: 'none', borderRadius: 14, border: '1px solid #EAECF0', background: '#fff', overflow: 'hidden' }}>
          {images?.[0] ? (
            <img src={images[0]} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain' }} />
          ) : (
            <PictureOutlined style={{ fontSize: 28, color: '#D0D5DD' }} />
          )}
        </Flex>
        <div style={{ minWidth: 0 }}>
          <Typography.Text strong style={{ fontSize: 18, display: 'block' }}>
            {price !== undefined && price !== null ? money(price, lang === 'uz' ? ' soʻm' : ' сум') : '—'}
          </Typography.Text>
          <Typography.Text style={{ fontSize: 13, display: 'block' }}>{shown || 'Название товара'}</Typography.Text>
          {unit && (
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              1 {unit}
            </Typography.Text>
          )}
          <Typography.Text type="secondary" style={{ fontSize: 11, display: 'block', marginTop: 4 }}>
            {lang === 'uz' ? 'Doʻkonlarda narx — oʻziniki' : 'Цена в магазинах — своя'}
          </Typography.Text>
        </div>
      </Flex>
      <Segmented
        size="small"
        style={{ marginTop: 14 }}
        value={lang}
        onChange={(v) => setLang(v as Lang)}
        options={[
          { value: 'uz', label: 'Oʻzbekcha' },
          { value: 'ru', label: 'Русский' },
        ]}
      />
    </SideCard>
  )
}

function VariantsCard({ ov, go }: { ov?: Overview; go: (to: string) => void }) {
  const v = ov?.variants
  return (
    <SideCard title="Вариации">
      {!ov ? (
        <Skeleton active paragraph={{ rows: 2 }} title={false} />
      ) : !v ? (
        <Space direction="vertical" size={8}>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            Товар не в группе вариаций.
          </Typography.Text>
          <Typography.Link onClick={() => go('/catalog/variants')} style={{ color: '#E11D2A', fontWeight: 700 }}>
            <PlusOutlined /> Добавить в группу
          </Typography.Link>
        </Space>
      ) : (
        <Space direction="vertical" size={10} style={{ width: '100%' }}>
          <Flex justify="space-between" align="center">
            <Typography.Text strong>{v.name}</Typography.Text>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {v.count} товаров
            </Typography.Text>
          </Flex>
          <Flex gap={6} wrap>
            {v.weight_label && v.weight && <Tag style={{ margin: 0 }}>{`${v.weight_label} · ${v.weight}`}</Tag>}
            {v.flavor_label && v.flavor && <Tag style={{ margin: 0 }}>{`${v.flavor_label} · ${v.flavor}`}</Tag>}
          </Flex>
          {v.items.map((it) => (
            <Flex
              key={it.product_id}
              align="center"
              gap={10}
              style={{ cursor: 'pointer' }}
              onClick={() => go(`/products/${it.product_id}`)}
            >
              <Flex align="center" justify="center" style={{ width: 28, height: 28, flex: 'none', borderRadius: 6, background: '#F2F4F7', overflow: 'hidden' }}>
                {it.image ? <img src={it.image} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : <PictureOutlined style={{ color: '#D0D5DD' }} />}
              </Flex>
              <Typography.Text style={{ fontSize: 13, flex: 1 }} ellipsis>
                {[v.flavor_label ? it.flavor : '', v.weight_label ? it.weight : ''].filter(Boolean).join(' · ') || it.name}
              </Typography.Text>
              <ArrowRightOutlined style={{ fontSize: 11, color: '#98A2B3' }} />
            </Flex>
          ))}
          <Typography.Link onClick={() => go(`/catalog/variants?status=confirmed&q=${encodeURIComponent(v.name)}`)} style={{ color: '#E11D2A', fontWeight: 700 }}>
            Открыть группу <ArrowRightOutlined />
          </Typography.Link>
        </Space>
      )}
    </SideCard>
  )
}

function SellingCard({ ov, unit }: { ov?: Overview; unit: string }) {
  const [open, setOpen] = useState(false)
  const s = ov?.selling
  const price =
    s?.min_price && s.max_price
      ? s.min_price === s.max_price
        ? money(s.min_price, ' сум')
        : `от ${money(s.min_price)} до ${money(s.max_price, ' сум')}`
      : ''
  return (
    <SideCard title="Продаётся">
      {!s ? (
        <Skeleton active paragraph={{ rows: 2 }} title={false} />
      ) : s.stores === 0 ? (
        <Typography.Text type="secondary" style={{ fontSize: 13 }}>
          Пока ни в одном магазине.
        </Typography.Text>
      ) : (
        <Space direction="vertical" size={8}>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            {s.networks === 1 && ov?.network_name ? `Только в сети «${ov.network_name}»: ` : 'В '}
            {s.stores} {s.stores === 1 ? 'магазине' : 'магазинах'} · цена {price} · остаток {s.stock} {unit}
          </Typography.Text>
          <Typography.Link onClick={() => setOpen(true)} style={{ color: '#E11D2A', fontWeight: 700 }}>
            Список магазинов <ArrowRightOutlined />
          </Typography.Link>
        </Space>
      )}
      <Modal open={open} onCancel={() => setOpen(false)} footer={null} title="Где продаётся" width={640}>
        <Table
          size="small"
          rowKey="store_id"
          pagination={{ pageSize: 10, hideOnSinglePage: true }}
          dataSource={s?.list ?? []}
          columns={[
            { title: 'Магазин', dataIndex: 'store_name', render: (n: string, r) => <>{n}<div><Typography.Text type="secondary" style={{ fontSize: 12 }}>{r.network_name}</Typography.Text></div></> },
            { title: 'Цена', dataIndex: 'price', align: 'right', render: (v: string) => money(v) },
            { title: 'Остаток', dataIndex: 'stock', align: 'right', render: (v: string) => `${v} ${unit}` },
          ]}
        />
      </Modal>
    </SideCard>
  )
}

// ─────────────────────────────────────────────────────────── страница

/** Страница товара: /products/:id и /products/new. */
export function ProductPage() {
  const { id = 'new' } = useParams()
  const isNew = id === 'new'
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { message, modal } = App.useApp()
  const remove = useRemove()
  const [form] = Form.useForm()
  const product = useQuery({ queryKey: ['/admin/products', id], queryFn: () => api.get<Product>(`/admin/products/${id}`), enabled: !isNew })
  const overview = useQuery({
    queryKey: ['/admin/products', id, 'overview'],
    queryFn: () => api.get<Overview>(`/admin/products/${id}/overview`),
    enabled: !isNew,
  })
  const p = product.data
  const ov = overview.data
  const [initial, setInitial] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [unit, setUnit] = useState('')
  const go = useLeaveGuard(dirty, 'Изменения в товаре не сохранены.')

  // Форма заполняется, когда пришли товар и его налоговые поля.
  useEffect(() => {
    if (isNew) {
      form.resetFields()
      form.setFieldsValue(EMPTY)
      setInitial(snapshot(form.getFieldsValue(true)))
      setDirty(false)
      return
    }
    if (!p || !ov) return
    form.resetFields()
    form.setFieldsValue(toForm(p, ov.tax))
    setUnit(p.unit_short)
    setInitial(snapshot(form.getFieldsValue(true)))
    setDirty(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNew, p, ov])

  const recheck = () => {
    if (initial !== null) setDirty(snapshot(form.getFieldsValue(true)) !== initial)
  }
  useEffect(() => {
    const h = () => setTimeout(recheck, 0)
    window.addEventListener('sm-product-changed', h)
    return () => window.removeEventListener('sm-product-changed', h)
  })

  const network = !!p?.network_id
  const pending = p?.moderation_status === 'pending'
  const listPath = pending ? '/moderation' : '/products'
  const name = (Form.useWatch('name', form) as string | undefined) || p?.name || 'Новый товар'

  const save = async (): Promise<boolean> => {
    let v: Record<string, unknown>
    try {
      await form.validateFields()
      v = form.getFieldsValue(true)
    } catch {
      message.error('Проверьте поля, отмеченные красным')
      return false
    }
    setSaving(true)
    try {
      const body = toBody(v, p ?? null)
      const tax = taxBody(v)
      const taxChanged = isNew
        ? !!(tax.ikpu || tax.package_code || tax.marked)
        : !!ov && (tax.ikpu !== ov.tax.ikpu || tax.package_code !== ov.tax.package_code || tax.marked !== ov.tax.marked || Number(tax.vat_rate ?? 0) !== Number(ov.tax.vat_rate || 0))
      if (isNew) {
        const created = await api.post<Product>('/admin/products', body)
        if (taxChanged) await api.put(`/admin/pos/products/${created.id}/tax`, tax)
        setDirty(false)
        await qc.invalidateQueries({ queryKey: ['/admin/products'] })
        message.success('Товар создан')
        navigate(`/products/${created.id}`, { replace: true })
      } else {
        await api.patch(`/admin/products/${id}`, body)
        if (taxChanged && !network) await api.put(`/admin/pos/products/${id}/tax`, tax)
        await qc.invalidateQueries({ queryKey: ['/admin/products'] })
        message.success('Сохранено')
      }
      return true
    } catch (e) {
      message.error(errorText(e))
      return false
    } finally {
      setSaving(false)
    }
  }

  const cancel = () => {
    if (isNew) form.setFieldsValue(EMPTY)
    else if (p && ov) form.setFieldsValue(toForm(p, ov.tax))
    setDirty(false)
  }

  const approve = async () => {
    if (dirty && !(await save())) return
    try {
      await api.post(`/admin/products/${id}/approve`)
      message.success('Товар одобрен и добавлен в общий каталог')
      await qc.invalidateQueries({ queryKey: ['/admin/products'] })
    } catch (e) {
      message.error(errorText(e))
    }
  }

  const reject = async () => {
    try {
      await api.post(`/admin/products/${id}/reject`, { reason })
      message.success('Товар отклонён')
      setRejecting(false)
      setDirty(false)
      await qc.invalidateQueries({ queryKey: ['/admin/products'] })
      navigate('/moderation')
    } catch (e) {
      message.error(errorText(e))
    }
  }

  const del = () =>
    remove({
      path: `/admin/products/${id}`,
      name: p?.name ?? '',
      deactivate: () => api.patch(`/admin/products/${id}`, { is_active: false }).then(() => product.refetch()),
      onDone: () => {
        setDirty(false)
        navigate('/products')
      },
    })

  const loading = !isNew && (product.isLoading || overview.isLoading)
  const err = product.error || overview.error
  const meta = useMemo(() => {
    if (isNew || !p) return []
    return [
      [p.brand_name, p.category_name].filter(Boolean).join(' · '),
      `Создан ${date(p.created_at)}${ov ? ` — ${ov.source}` : ''}`,
      ov ? `Изменён ${dateTime(ov.updated_at)}` : '',
    ].filter(Boolean)
  }, [isNew, p, ov])

  return (
    <div className="sm-product-page">
      <div className="sm-page-head" style={{ padding: '12px 16px 14px' }}>
        <Flex align="center" gap={6} style={{ fontSize: 13, color: '#667085', marginBottom: 6 }}>
          <Typography.Link onClick={() => go(() => navigate(listPath))} style={{ color: '#667085' }}>
            <ArrowLeftOutlined /> Каталог
          </Typography.Link>
          <span>/</span>
          <Typography.Link onClick={() => go(() => navigate(listPath))} style={{ color: '#667085' }}>
            {pending ? 'Модерация' : 'Товары'}
          </Typography.Link>
          <span>/</span>
          <Typography.Text style={{ fontSize: 13, color: '#344054' }} ellipsis>
            {name}
          </Typography.Text>
        </Flex>
        <Flex align="center" gap={12} wrap>
          <h1 className="sm-head-title" style={{ margin: 0, fontSize: 20 }}>
            {name}
          </h1>
          {p && <StatusTag status={p.moderation_status} />}
          {p && (p.is_active ? <Tag color="blue">Активен</Tag> : <Tag>Отключён</Tag>)}
          <Flex gap={8} style={{ marginLeft: 'auto' }}>
            {!isNew && (
              <Button danger icon={<DeleteOutlined />} onClick={() => modal.confirm({
                title: `Удалить «${p?.name ?? ''}»?`,
                content: 'Если товар уже продавался, он не удалится, а выключится.',
                okText: 'Удалить',
                okButtonProps: { danger: true },
                cancelText: 'Отмена',
                onOk: del,
              })}>
                Удалить
              </Button>
            )}
            <Button disabled={!dirty || saving} onClick={cancel}>
              Отменить
            </Button>
            <Button type="primary" icon={<CheckOutlined />} loading={saving} disabled={!dirty && !isNew} onClick={() => void save()}>
              {isNew ? 'Создать товар' : 'Сохранить'}
            </Button>
          </Flex>
        </Flex>
        <Flex gap={16} wrap style={{ marginTop: 6, fontSize: 13, color: '#667085' }}>
          {meta.map((m) => (
            <span key={m}>{m}</span>
          ))}
          {dirty && <span style={{ color: '#DC6803', fontWeight: 700 }}>Есть несохранённые изменения</span>}
        </Flex>
      </div>

      <LoadError error={err} retry={() => (product.refetch(), overview.refetch())} />

      {pending && network && (
        <Flex
          align="center"
          gap={16}
          wrap
          style={{ background: '#FFFAEB', border: '1px solid #FEC84B', borderRadius: 12, padding: '14px 18px', marginBottom: 20 }}
        >
          <ShopOutlined style={{ fontSize: 20, color: '#B54708' }} />
          <div style={{ flex: 1, minWidth: 260 }}>
            <Typography.Text strong style={{ color: '#93370D' }}>
              Товар предложила сеть «{ov?.network_name ?? '…'}»
            </Typography.Text>
            <div>
              <Typography.Text style={{ fontSize: 12, color: '#93370D' }}>
                Сеть уже продаёт его у себя. После одобрения товар попадёт в общий каталог и станет виден всем сетям. Проверьте название, фото,
                категорию и штрихкод — их можно поправить прямо на этой странице.
              </Typography.Text>
            </div>
          </div>
          <Button danger icon={<StopOutlined />} onClick={() => setRejecting(true)}>
            Отклонить…
          </Button>
          <Button type="primary" icon={<CheckOutlined />} style={{ background: '#079455' }} onClick={() => void approve()}>
            Одобрить и добавить в каталог
          </Button>
        </Flex>
      )}
      {p?.moderation_status === 'rejected' && p.rejection_reason && (
        <Alert type="error" showIcon style={{ marginBottom: 20 }} message={`Отклонён: ${p.rejection_reason}`} />
      )}

      {loading ? (
        <Card>
          <Skeleton active paragraph={{ rows: 10 }} />
        </Card>
      ) : (
        <Form form={form} layout="vertical" requiredMark={false} onValuesChange={recheck}>
          <Row gutter={[24, 24]}>
            <Col xs={24} xl={17}>
              <Space direction="vertical" size={20} style={{ width: '100%' }}>
                <Card styles={CARD}>
                  <CardTitle title="Основное" />
                  <Form.Item name="name" label="Название" rules={[{ required: true, message: 'Введите название' }]}>
                    <Input size="large" maxLength={300} suffix={<FormTranslate form={form} from="name_uz" into="name" to="ru" />} />
                  </Form.Item>
                  <Form.Item
                    name="name_uz"
                    label="Название (узб.)"
                    extra="Латиница. Пусто — в приложении будет русское название"
                  >
                    <Input size="large" maxLength={300} suffix={<FormTranslate form={form} from="name" into="name_uz" to="uz" />} />
                  </Form.Item>
                  <Row gutter={16}>
                    <Col xs={24} md={12}>
                      <Form.Item name="brand_id" label="Бренд">
                        <SearchSelect size="large" path="/admin/catalog/brands" known={{ id: p?.brand_id, label: p?.brand_name }} allowClear placeholder="Не выбран" />
                      </Form.Item>
                    </Col>
                    <Col xs={24} md={12}>
                      <Form.Item name="category_id" label="Категория" rules={[{ required: true, message: 'Выберите категорию' }]}>
                        <SearchSelect size="large" path="/admin/catalog/categories" known={{ id: p?.category_id, label: p?.category_name }} placeholder="Выберите" />
                      </Form.Item>
                    </Col>
                  </Row>
                  <Row gutter={16}>
                    <Col xs={24} md={8}>
                      <Form.Item name="unit_id" label="Единица" rules={[{ required: true, message: 'Выберите единицу' }]}>
                        <RemoteSelect
                          size="large"
                          path="/admin/catalog/units"
                          onChange={(_, o) => {
                            const opt = Array.isArray(o) ? undefined : o
                            setUnit(String(opt?.label ?? ''))
                          }}
                        />
                      </Form.Item>
                    </Col>
                    <Col xs={24} md={8}>
                      <Form.Item name="base_price" label="Базовая цена" rules={[{ required: true, message: 'Укажите цену' }]}>
                        <InputNumber size="large" min={0} precision={2} style={{ width: '100%' }} addonAfter="сум" />
                      </Form.Item>
                    </Col>
                    <Col xs={24} md={8}>
                      <Form.Item name="color_id" label="Цвет">
                        <RemoteSelect size="large" path="/admin/catalog/colors" allowClear placeholder="Не выбран" />
                      </Form.Item>
                    </Col>
                  </Row>
                </Card>

                <PhotosCard productId={isNew ? undefined : id} />

                <Card styles={CARD}>
                  <CardTitle title="Описание" />
                  <Form.Item name="description" label={<TrLabel label="Описание" from="description_uz" into="description" to="ru" />}>
                    <Input.TextArea rows={3} maxLength={2000} />
                  </Form.Item>
                  <Form.Item name="description_uz" label={<TrLabel label="Описание (узб.)" from="description" into="description_uz" to="uz" />} style={{ marginBottom: 0 }}>
                    <Input.TextArea rows={3} maxLength={2000} />
                  </Form.Item>
                </Card>

                <Card styles={CARD}>
                  <CardTitle title="Штрихкоды" hint="Штрихкод уникален на всю платформу. Скан на кассе находит товар по любому из них." />
                  <Form.Item name="barcodes" noStyle>
                    <BarcodesInput />
                  </Form.Item>
                </Card>

                <Card styles={CARD}>
                  <CardTitle title="Для карточки в приложении" hint="Покупатель видит это в карточке товара." />
                  <Typography.Text strong style={{ fontSize: 13 }}>
                    Пищевая ценность на 100 г
                  </Typography.Text>
                  <Row gutter={16} style={{ marginTop: 8 }}>
                    {NUTRITION.map(([k, label]) => (
                      <Col key={k} xs={12} md={6}>
                        <Form.Item name={`nut_${k}`} label={label}>
                          <InputNumber size="large" min={0} max={10000} style={{ width: '100%' }} />
                        </Form.Item>
                      </Col>
                    ))}
                  </Row>
                  <Form.Item name="attr_composition" label="Состав">
                    <Input.TextArea rows={2} maxLength={500} />
                  </Form.Item>
                  <Row gutter={16}>
                    {TEXT_ATTRS.filter(([k]) => k === 'shelf_life' || k === 'storage').map(([k, label, ph]) => (
                      <Col key={k} xs={24} md={12}>
                        <Form.Item name={`attr_${k}`} label={label}>
                          <Input size="large" placeholder={ph} maxLength={500} />
                        </Form.Item>
                      </Col>
                    ))}
                  </Row>
                  <Row gutter={16}>
                    {TEXT_ATTRS.filter(([k]) => k === 'country' || k === 'manufacturer' || k === 'volume').map(([k, label, ph]) => (
                      <Col key={k} xs={24} md={8}>
                        <Form.Item name={`attr_${k}`} label={label} style={{ marginBottom: 0 }}>
                          <Input size="large" placeholder={ph} maxLength={500} />
                        </Form.Item>
                      </Col>
                    ))}
                  </Row>
                </Card>

                <Card styles={CARD}>
                  <CardTitle
                    title="Касса и налоги"
                    hint={
                      network
                        ? 'Налоговые поля товара сети правит сама сеть; после одобрения их можно поправить здесь.'
                        : 'Для фискального чека. ИКПУ и код упаковки — из каталога tasnif.soliq.uz.'
                    }
                  />
                  <Row gutter={16}>
                    <Col xs={24} md={12}>
                      <Form.Item
                        name="tax_ikpu"
                        label="ИКПУ"
                        extra={ov?.tax.ikpu_name || undefined}
                        rules={[{ pattern: /^(\d{17})?$/, message: '17 цифр из справочника tasnif.soliq.uz' }]}
                      >
                        <Input size="large" maxLength={17} disabled={network} placeholder="17 цифр" />
                      </Form.Item>
                    </Col>
                    <Col xs={12} md={6}>
                      <Form.Item name="tax_package_code" label="Код упаковки">
                        <Input size="large" maxLength={20} disabled={network} />
                      </Form.Item>
                    </Col>
                    <Col xs={12} md={6}>
                      <Form.Item name="tax_vat_rate" label="НДС">
                        <InputNumber size="large" min={0} max={100} style={{ width: '100%' }} addonAfter="%" disabled={network} />
                      </Form.Item>
                    </Col>
                  </Row>
                  <Flex align="center" gap={12}>
                    <Form.Item name="tax_marked" valuePropName="checked" noStyle>
                      <Switch disabled={network} />
                    </Form.Item>
                    <div>
                      <Typography.Text>Маркированный товар</Typography.Text>
                      <div>
                        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                          На кассе только по скану кода DataMatrix
                        </Typography.Text>
                      </div>
                    </div>
                  </Flex>
                </Card>
              </Space>
            </Col>

            <Col xs={24} xl={7}>
              <Space direction="vertical" size={16} style={{ width: '100%' }}>
                <SideCard title="Статус">
                  <Space direction="vertical" size={12} style={{ width: '100%' }}>
                    {p ? (
                      <div>
                        <StatusTag status={p.moderation_status} />
                      </div>
                    ) : (
                      <Tag icon={<ClockCircleOutlined />}>Новый</Tag>
                    )}
                    <Flex gap={12} align="flex-start">
                      <Form.Item name="is_active" valuePropName="checked" noStyle>
                        <Switch disabled={isNew} />
                      </Form.Item>
                      <div>
                        <Typography.Text>Активен</Typography.Text>
                        <div>
                          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                            Виден магазинам и в приложении. Выключите, чтобы скрыть, не удаляя.
                          </Typography.Text>
                        </div>
                      </div>
                    </Flex>
                    {p && (
                      <Space direction="vertical" size={4} style={{ width: '100%' }}>
                        <Fact label="Источник">{ov?.source ?? '…'}</Fact>
                        <Fact label="Создан">{dateTime(p.created_at)}</Fact>
                        <Fact label="ID">
                          <Typography.Text copyable={{ text: p.id }} style={{ fontSize: 13 }}>
                            {`${p.id.slice(0, 4)}…${p.id.slice(-4)}`}
                          </Typography.Text>
                        </Fact>
                      </Space>
                    )}
                  </Space>
                </SideCard>
                <AppPreview unit={unit} />
                {!isNew && (
                  <>
                    <VariantsCard ov={ov} go={(to) => go(() => navigate(to))} />
                    <SellingCard ov={ov} unit={unit} />
                  </>
                )}
              </Space>
            </Col>
          </Row>
        </Form>
      )}

      <Modal
        open={rejecting}
        title={`Отклонить «${p?.name ?? ''}»`}
        okText="Отклонить"
        okButtonProps={{ danger: true, disabled: !reason.trim() }}
        onCancel={() => setRejecting(false)}
        onOk={() => void reject()}
      >
        <Input.TextArea rows={3} placeholder="Причина — её увидит магазин" value={reason} onChange={(e) => setReason(e.target.value)} />
      </Modal>
    </div>
  )
}
