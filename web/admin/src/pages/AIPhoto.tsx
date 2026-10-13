// «ИИ для фото» (Figma «Супер-админ · ИИ для фото товаров», Ф1–Ф2): своё
// подключение к Google Gemini — отдельно от «ИИ-сервиса» накладных. Gemini
// генерирует и редактирует фото товаров («Нормализовать фото» на странице товара).
// Ключ хранится на сервере зашифрованным и обратно не показывается.
import { useEffect, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Alert, App, AutoComplete, Badge, Button, Card, Checkbox, Col, Flex, Image, Input, InputNumber, Modal, Row, Segmented, Space, Statistic, Switch, Tag, Typography, Upload } from 'antd'
import {
  ArrowRightOutlined,
  CameraOutlined,
  CheckCircleFilled,
  CloudOutlined,
  ContainerOutlined,
  KeyOutlined,
  LinkOutlined,
  LoadingOutlined,
  LockOutlined,
  ReloadOutlined,
  ShopOutlined,
  ThunderboltOutlined,
  UploadOutlined,
} from '@ant-design/icons'
import { Link } from 'react-router-dom'
import { LoadError, PageTitle, api, dateTime, errorText, useItem, useList } from '@sm/shared'
import type { Plan } from './Plans'
import { Hint, ProviderCard, Step, VERTEX_REGIONS, isGoogleVertexURL, parseServiceAccount, vertexProject, vertexRegion, vertexURL } from './AI'
import { usePhotoJob, usd } from '../photoJob'

type Mode = 'gemini' | 'vertex'
type Background = 'white' | 'light' | 'transparent'

interface PhotoSettings {
  mode: Mode
  base_url: string
  model: string
  has_key: boolean
  key_last4: string
  configured: boolean
  background: Background
  size: 1000 | 1500 | 2000
  outpaint: boolean
  web_search: boolean
  before_after: boolean
  prompt: string
  default_prompt: string
  checked_at: string | null
  check_ok: boolean | null
  check_message: string
  month_photos: number
  month_failed: number
  month_cost_usd: number
  // «Фото для магазинов»: Super Market сам делает фото новых товаров и строк инвентаризации.
  store_enabled: boolean
  store_new_items: boolean
  store_lines: boolean
  store_model: string
  store_photos: number
  store_failed: number
  store_cost_usd: number
  store_networks: number
  store_top: { network_id: string; name: string; photos: number; used: number; limit: number | null; cost_usd: number }[]
}

/** Лимит тарифа «Фото от Super Market в месяц» и его значение по умолчанию. */
const PHOTO_LIMIT = 'ai_photos'
const PHOTO_LIMIT_DEFAULT = 300

interface Model {
  id: string
}

const GEMINI_URL = 'https://generativelanguage.googleapis.com/v1beta'
const VERTEX_URL = 'https://aiplatform.googleapis.com/v1'
const DEFAULT_URL: Record<Mode, string> = { gemini: GEMINI_URL, vertex: VERTEX_URL }

// Цена одного фото 1K по прайсу Google (Standard), для карточки «Цена за фото».
const PRICES: [string, number][] = [
  ['gemini-3-pro-image', 0.134],
  ['gemini-nano-banana-2.1', 0.034],
]

const isGoogleGeminiURL = (url: string) => {
  try {
    const u = new URL(url)
    return u.protocol === 'https:' && !u.port && u.hostname === 'generativelanguage.googleapis.com'
  } catch {
    return false
  }
}

/** Логотип Gemini: градиентная плитка со «звёздочками». */
function GeminiLogo({ size = 44 }: { size?: number }) {
  return (
    <Flex
      align="center"
      justify="center"
      style={{
        width: size,
        height: size,
        flex: 'none',
        borderRadius: 12,
        color: '#fff',
        fontSize: size * 0.5,
        background: 'linear-gradient(135deg, #4285F4 0%, #9B72CB 55%, #D96570 100%)',
      }}
    >
      ✦
    </Flex>
  )
}

/** Строка настройки фото: название, пояснение и управление справа. */
function SettingRow({ title, text, children }: { title: string; text: string; children: ReactNode }) {
  return (
    <Flex align="center" gap={16} style={{ borderTop: '1px solid #EAECF0', padding: '12px 0' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <Typography.Text strong>{title}</Typography.Text>
        <div>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {text}
          </Typography.Text>
        </div>
      </div>
      {children}
    </Flex>
  )
}

/** «До / после» проверки. */
function BeforeAfter({ before, after, busy }: { before?: string; after?: string; busy: boolean }) {
  const tile = { width: 220, height: 220, borderRadius: 12, objectFit: 'cover' as const }
  return (
    <Flex align="center" justify="center" gap={16} wrap style={{ background: '#F8FAFC', borderRadius: 12, padding: 16 }}>
      <Flex vertical align="center" gap={8}>
        {before ? (
          <Image src={before} style={{ ...tile, display: 'block' }} />
        ) : (
          <Flex align="center" justify="center" style={{ ...tile, background: '#EAECF0', color: '#667085', textAlign: 'center', padding: 16 }}>
            Стандартное фото: сок без крышки в кадре
          </Flex>
        )}
        <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
          Снято в магазине
        </Typography.Text>
      </Flex>
      <ArrowRightOutlined style={{ fontSize: 22, color: '#98A2B3' }} />
      <Flex vertical align="center" gap={8}>
        {after ? (
          <Image
            src={after}
            style={{
              ...tile,
              display: 'block',
              objectFit: 'contain',
              border: '1px solid #EAECF0',
              // Шахматка — видно прозрачный фон.
              background: 'repeating-conic-gradient(#EAECF0 0% 25%, #fff 0% 50%) 50% / 20px 20px',
            }}
          />
        ) : (
          <Flex align="center" justify="center" style={{ ...tile, background: '#fff', border: '1px dashed #D0D5DD', color: '#98A2B3' }}>
            {busy ? <LoadingOutlined style={{ fontSize: 28 }} /> : 'Фото от Gemini'}
          </Flex>
        )}
        <Typography.Text strong style={{ fontSize: 12 }}>
          После Gemini
        </Typography.Text>
      </Flex>
    </Flex>
  )
}

/** Н5 (Figma «Нормализация фото для магазина»): блок «Фото для магазинов». */
function StorePhotosCard({ s, models, onSaved }: { s: PhotoSettings; models: Model[] | null; onSaved: () => void }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const plans = useList<Plan>('/admin/plans')
  const [enabled, setEnabled] = useState(s.store_enabled)
  const [newItems, setNewItems] = useState(s.store_new_items)
  const [lines, setLines] = useState(s.store_lines)
  const [model, setModel] = useState(s.store_model)
  const [limits, setLimits] = useState<Record<string, number | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    setEnabled(s.store_enabled)
    setNewItems(s.store_new_items)
    setLines(s.store_lines)
    setModel(s.store_model)
  }, [s])
  useEffect(() => {
    const out: Record<string, number | null> = {}
    for (const p of plans.data ?? []) out[p.key] = p.limits[PHOTO_LIMIT] ?? null
    setLimits(out)
  }, [plans.data])

  const active = (plans.data ?? []).filter((p) => p.is_active)
  const changedPlans = active.filter((p) => (p.limits[PHOTO_LIMIT] ?? null) !== (limits[p.key] ?? null))
  const dirty = enabled !== s.store_enabled || newItems !== s.store_new_items || lines !== s.store_lines || model.trim() !== s.store_model || changedPlans.length > 0

  const save = async () => {
    setBusy(true)
    try {
      await api.put<PhotoSettings>('/admin/ai-photo/store', { store_enabled: enabled, store_new_items: newItems, store_lines: lines, store_model: model.trim() })
      for (const p of changedPlans) {
        const next: Record<string, number | null> = { ...p.limits }
        const v = limits[p.key]
        if (v === null || v === undefined) delete next[PHOTO_LIMIT]
        else next[PHOTO_LIMIT] = v
        await api.patch(`/admin/plans/${p.key}`, { limits: next })
      }
      await qc.invalidateQueries({ queryKey: ['/admin/plans'] })
      message.success('Сохранено')
      onSaved()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  const check = (on: boolean, set: (v: boolean) => void, title: string, text: string, disabled?: boolean) => (
    <Flex gap={10} align="flex-start">
      <Checkbox checked={on} disabled={disabled} onChange={(e) => set(e.target.checked)} style={{ marginTop: 2 }} />
      <div>
        <Typography.Text strong style={{ color: disabled ? '#98A2B3' : undefined }}>
          {title}
        </Typography.Text>
        <div>
          <Hint>{text}</Hint>
        </div>
      </div>
    </Flex>
  )
  const price = PRICES.find(([m]) => (model.trim() || s.model).includes(m))?.[1]
  const stat = (title: string, value: ReactNode) => (
    <Card size="small" style={{ background: '#F8FAFC', flex: 1, minWidth: 130 }}>
      <Statistic title={title} value={value as string} groupSeparator=" " />
    </Card>
  )

  return (
    <Card style={{ marginTop: 24 }} styles={{ body: { padding: 24 } }}>
      <Space direction="vertical" size={20} style={{ width: '100%' }}>
        <Flex align="center" gap={12}>
          <div style={{ flex: 1 }}>
            <Space size={8}>
              <ShopOutlined style={{ fontSize: 18 }} />
              <Typography.Text strong style={{ fontSize: 16 }}>
                Фото для магазинов
              </Typography.Text>
              {enabled && s.configured ? <Tag color="green">Включено</Tag> : <Tag>Выключено</Tag>}
            </Space>
            <div>
              <Hint>Super Market сам нормализует фото магазинов — по правилам из «Каким делать фото». Магазину ничего нажимать не нужно.</Hint>
            </div>
          </div>
          <Switch checked={enabled} onChange={setEnabled} />
        </Flex>
        {!s.configured && <Alert type="warning" showIcon message="Сначала подключите Gemini выше — без него фото магазинам не делаются." />}

        <Space direction="vertical" size={10}>
          <Typography.Text strong>Когда запускать</Typography.Text>
          {check(newItems, setNewItems, 'Новый товар по фото', 'После распознавания карточки. Из 1–3 фото магазина — одно фото лицевой стороны')}
          {check(lines, setLines, 'Фото строки на «Инвентаризации»', 'Только если у товара не было фото')}
          {check(false, () => undefined, 'Кнопка «Сделать фото Super Market» у своего товара', 'Вторая очередь', true)}
        </Space>

        <Space direction="vertical" size={6} style={{ width: '100%' }}>
          <Typography.Text strong>Модель для магазинов</Typography.Text>
          <AutoComplete
            size="large"
            style={{ maxWidth: 460, width: '100%' }}
            value={model}
            onChange={setModel}
            options={(models ?? []).map((m) => ({ value: m.id }))}
            placeholder={`Как у супер-админа: ${s.model || '—'}`}
            allowClear
          />
          <Hint>
            {price !== undefined ? `${usd(price)} за фото. ` : ''}Пусто — та же модель, что выше. Nano Banana и Flash Image дешевле, gemini-3-pro-image
            точнее рисует надписи на упаковке.
          </Hint>
        </Space>

        <Space direction="vertical" size={8} style={{ width: '100%' }}>
          <Typography.Text strong>Фото в месяц по тарифу</Typography.Text>
          <Flex gap={12} wrap>
            {active.map((p) => (
              <div key={p.key}>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {p.name}
                </Typography.Text>
                <div>
                  <InputNumber
                    style={{ width: 160 }}
                    min={0}
                    max={1000000}
                    value={limits[p.key] ?? null}
                    placeholder={String(PHOTO_LIMIT_DEFAULT)}
                    addonAfter="фото / мес"
                    onChange={(v) => setLimits((l) => ({ ...l, [p.key]: v === null ? null : Number(v) }))}
                  />
                </div>
              </div>
            ))}
          </Flex>
          <Hint>Пусто — {PHOTO_LIMIT_DEFAULT}. 0 — на тарифе выключено. «Переделать» тоже считается. Закончились — товары остаются с фото магазина. То же поле — в{' '}
            <Link to="/billing/tariffs">«Тарифах»</Link>.
          </Hint>
        </Space>

        <Space direction="vertical" size={8} style={{ width: '100%' }}>
          <Typography.Text strong>Магазины в этом месяце</Typography.Text>
          <Flex gap={10} wrap>
            {stat('Фото', s.store_photos)}
            {stat('Не вышло', s.store_failed)}
            {stat('Расход', usd(s.store_cost_usd))}
            {stat('Сетей', s.store_networks)}
          </Flex>
          {s.store_top.length > 0 && (
            <div>
              {s.store_top.map((t) => (
                <Flex key={t.network_id} gap={12} align="center" style={{ borderTop: '1px solid #EAECF0', padding: '8px 0' }}>
                  <Typography.Text style={{ flex: 1 }}>{t.name}</Typography.Text>
                  <Typography.Text type="secondary">{t.limit !== null ? `${t.used} из ${t.limit}` : t.used}</Typography.Text>
                  <Typography.Text strong style={{ width: 80, textAlign: 'right' }}>
                    {usd(t.cost_usd)}
                  </Typography.Text>
                </Flex>
              ))}
            </div>
          )}
        </Space>

        <Flex justify="space-between" align="center" gap={12} wrap style={{ borderTop: '1px solid #EAECF0', paddingTop: 16 }}>
          <Hint>
            Подробно — <Link to="/ai?tab=usage">«ИИ-сервис» → Расход</Link>, строка «фото магазинов».
          </Hint>
          <Button size="large" type="primary" loading={busy} disabled={!dirty} onClick={save}>
            Сохранить
          </Button>
        </Flex>
      </Space>
    </Card>
  )
}

function PhotoConnection() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const { data: s, error, refetch, isLoading } = useItem<PhotoSettings>('/admin/ai-photo')
  const [mode, setMode] = useState<Mode>('gemini')
  const [baseURL, setBaseURL] = useState(GEMINI_URL)
  const [key, setKey] = useState('')
  const [replacing, setReplacing] = useState(false)
  const [model, setModel] = useState('')
  const [search, setSearch] = useState('')
  const [models, setModels] = useState<Model[] | null>(null)
  const [background, setBackground] = useState<Background>('white')
  const [size, setSize] = useState<1000 | 1500 | 2000>(1000)
  const [outpaint, setOutpaint] = useState(true)
  const [webSearch, setWebSearch] = useState(true)
  const [beforeAfter, setBeforeAfter] = useState(true)
  const [prompt, setPrompt] = useState('')
  const [promptDraft, setPromptDraft] = useState<string | null>(null)
  const [testImage, setTestImage] = useState('')
  const [busy, setBusy] = useState<'' | 'models' | 'save' | 'upload'>('')
  const test = usePhotoJob((j) => {
    if (!j.ok) return
    qc.invalidateQueries({ queryKey: ['/admin/ai-photo'] })
  })

  useEffect(() => {
    if (!s) return
    setMode(s.mode)
    setBaseURL(s.base_url)
    setModel(s.model)
    setBackground(s.background)
    setSize(s.size)
    setOutpaint(s.outpaint)
    setWebSearch(s.web_search)
    setBeforeAfter(s.before_after)
    setPrompt(s.prompt)
    setKey('')
    setReplacing(false)
  }, [s])

  const cleanURL = baseURL.trim().replace(/\/+$/, '')
  const savedKeyUsable =
    !!s?.has_key &&
    s.mode === mode &&
    (s.base_url === cleanURL ||
      (mode === 'vertex' && isGoogleVertexURL(s.base_url) && isGoogleVertexURL(cleanURL)) ||
      (mode === 'gemini' && isGoogleGeminiURL(s.base_url) && isGoogleGeminiURL(cleanURL)))
  const showSavedKey = savedKeyUsable && !replacing
  const conn = () => ({ mode, base_url: baseURL.trim(), api_key: showSavedKey ? '' : key.trim(), model: model.trim() })
  const body = () => ({ ...conn(), background, size, outpaint, web_search: webSearch, before_after: beforeAfter, prompt })
  const connDirty = !!s && (s.mode !== mode || s.base_url !== cleanURL || s.model !== model.trim() || !showSavedKey)
  const dirty =
    !!s &&
    (connDirty ||
      s.background !== background ||
      s.size !== size ||
      s.outpaint !== outpaint ||
      s.web_search !== webSearch ||
      s.before_after !== beforeAfter ||
      s.prompt !== prompt)

  const sa = mode === 'vertex' ? parseServiceAccount(key) : null
  const changeKey = (v: string) => {
    setKey(v)
    const acc = mode === 'vertex' ? parseServiceAccount(v) : null
    if (acc?.project_id) setBaseURL(vertexURL(acc.project_id, vertexProject(baseURL) ? vertexRegion(baseURL) : 'global'))
  }

  const switchMode = (m: Mode) => {
    if (m === mode) return
    setMode(m)
    setBaseURL(m === s?.mode ? s.base_url : DEFAULT_URL[m])
    setModel(m === s?.mode ? s.model : '')
    setModels(null)
    setKey('')
    test.reset()
  }

  const run = async <T,>(kind: typeof busy, fn: () => Promise<T>) => {
    setBusy(kind)
    try {
      return await fn()
    } catch (e) {
      message.error(errorText(e))
      return undefined
    } finally {
      setBusy('')
    }
  }

  const loadModels = () =>
    run('models', async () => {
      const r = await api.post<{ items: Model[] | null }>('/admin/ai-photo/models', conn())
      setModels(r.items ?? [])
      if (!model.trim() && r.items?.length) setModel(r.items[0].id)
      if (!r.items?.length) message.info('Ключ не вернул ни одной модели, которая рисует фото — впишите название вручную')
    })

  const check = () => test.start('/admin/ai-photo/test', { ...(dirty ? body() : {}), image: testImage || undefined })

  const save = () =>
    run('save', async () => {
      await api.put<PhotoSettings>('/admin/ai-photo', body())
      message.success(s?.configured ? 'Сохранено' : 'Gemini подключён')
      test.reset()
      await refetch()
    })

  const uploadTest = (file: File) => {
    run('upload', async () => {
      setTestImage(await api.upload(file, file.name))
      test.reset()
    })
    return false
  }

  const options = (models ?? [])
    .filter((m) => !search || m.id.toLowerCase().includes(search.toLowerCase()))
    .map((m) => ({
      value: m.id,
      label: (
        <Flex justify="space-between" gap={8}>
          <span>{m.id}</span>
          <Tag color="green">рисует фото</Tag>
        </Flex>
      ),
    }))

  const tested = !!s?.configured && s.checked_at !== null
  const item = test.job?.items[0]
  const showCheck = !!s?.configured || !!test.job
  const searchModel = !/lite|2\.5-flash-image/i.test(model)

  return (
    <>
      <LoadError error={error} retry={() => refetch()} />
      <Row gutter={[24, 24]}>
        <Col xs={24} xl={16}>
          <Card loading={isLoading} styles={{ body: { padding: 24 } }}>
            <Space direction="vertical" size={24} style={{ width: '100%' }}>
              <Flex
                align="center"
                gap={14}
                style={{ padding: '14px 16px', borderRadius: 12, background: 'linear-gradient(90deg, #EEF4FF 0%, #F5F0FF 100%)' }}
              >
                <GeminiLogo />
                <div style={{ flex: 1 }}>
                  <Typography.Text strong style={{ fontSize: 17 }}>
                    Google Gemini
                  </Typography.Text>
                  <div>
                    <Typography.Text style={{ fontSize: 13, color: '#344054' }}>
                      Генерирует и редактирует фото товаров: убирает фон, выравнивает, дорисовывает то, что не попало в кадр
                    </Typography.Text>
                  </div>
                </div>
                <Tag color="geekblue" style={{ marginInlineEnd: 0 }}>
                  Только Gemini
                </Tag>
              </Flex>

              <Step n={1} title="Как подключить Gemini">
                <Row gutter={[12, 12]}>
                  <Col xs={24} md={12}>
                    <ProviderCard
                      active={mode === 'gemini'}
                      title="Gemini API"
                      text="Ключ из Google AI Studio — самый простой способ, хватает одного ключа"
                      onClick={() => switchMode('gemini')}
                    />
                  </Col>
                  <Col xs={24} md={12}>
                    <ProviderCard
                      active={mode === 'vertex'}
                      title="Vertex AI"
                      text="Через Google Cloud: проект и ключ сервисного аккаунта (JSON). Тот же Gemini"
                      onClick={() => switchMode('vertex')}
                    />
                  </Col>
                </Row>
              </Step>

              {mode === 'vertex' && (
                <Step n={2} title="Проект Google Cloud">
                  <Input
                    size="large"
                    addonBefore="Project ID"
                    value={vertexProject(baseURL)}
                    onChange={(e) => {
                      const p = e.target.value.trim()
                      setBaseURL(p ? vertexURL(p, vertexRegion(baseURL)) : VERTEX_URL)
                    }}
                    placeholder="my-project-123456 или номер проекта"
                  />
                  <Flex align="center" gap={8} wrap>
                    <Typography.Text type="secondary">Регион:</Typography.Text>
                    {VERTEX_REGIONS.map((r) => (
                      <Button
                        key={r.value}
                        size="small"
                        disabled={!vertexProject(baseURL)}
                        type={vertexProject(baseURL) && vertexRegion(baseURL) === r.value ? 'primary' : 'default'}
                        onClick={() => setBaseURL(vertexURL(vertexProject(baseURL), r.value))}
                      >
                        {r.label}
                      </Button>
                    ))}
                  </Flex>
                  <Input size="large" prefix={<LinkOutlined />} value={baseURL} onChange={(e) => setBaseURL(e.target.value)} />
                  <Hint>Модели Gemini для картинок (preview) работают в регионе global. Project ID подставится сам из JSON-ключа.</Hint>
                </Step>
              )}

              <Step n={mode === 'vertex' ? 3 : 2} title={mode === 'vertex' ? 'Ключ сервисного аккаунта' : 'Ключ Gemini API'}>
                {showSavedKey ? (
                  <Input
                    size="large"
                    readOnly
                    prefix={<CheckCircleFilled style={{ color: '#12B76A' }} />}
                    value={`Ключ сохранён · заканчивается на …${s?.key_last4}`}
                    suffix={
                      <Button type="link" danger onClick={() => setReplacing(true)} style={{ padding: 0 }}>
                        Заменить
                      </Button>
                    }
                  />
                ) : sa ? (
                  <Input
                    size="large"
                    readOnly
                    prefix={<CheckCircleFilled style={{ color: '#12B76A' }} />}
                    value={`Сервисный аккаунт ${sa.client_email}${sa.project_id ? ` · проект ${sa.project_id}` : ''}`}
                    suffix={
                      <Button type="link" danger onClick={() => setKey('')} style={{ padding: 0 }}>
                        Очистить
                      </Button>
                    }
                  />
                ) : mode === 'vertex' ? (
                  <Input.TextArea
                    rows={4}
                    value={key}
                    onChange={(e) => changeKey(e.target.value)}
                    placeholder={'Вставьте JSON-ключ целиком: { "type": "service_account", … }\nили API-ключ Vertex AI'}
                    autoComplete="off"
                    spellCheck={false}
                    style={{ fontFamily: 'monospace', fontSize: 12 }}
                  />
                ) : (
                  <Input.Password size="large" prefix={<KeyOutlined />} value={key} onChange={(e) => setKey(e.target.value)} placeholder="AQ.… (или старый AIza…)" autoComplete="off" />
                )}
                <Hint>
                  {mode === 'vertex'
                    ? 'IAM → Сервисные аккаунты: роль «Vertex AI User», Ключи → Добавить ключ → JSON. В проекте включите Vertex AI API.'
                    : 'Google AI Studio → Get API key. Можно ключ того же Google-проекта, что и в «ИИ-сервис», — расход на фото всё равно считается отдельно.'}{' '}
                  Ключ хранится зашифрованным и обратно не показывается.
                </Hint>
              </Step>

              <Step n={mode === 'vertex' ? 4 : 3} title="Модель для фото">
                <Flex gap={12} wrap>
                  <AutoComplete
                    size="large"
                    style={{ flex: 1, minWidth: 240 }}
                    value={model}
                    onChange={setModel}
                    onSearch={setSearch}
                    onSelect={() => setSearch('')}
                    onDropdownVisibleChange={(open) => open && setSearch('')}
                    options={options}
                    filterOption={false}
                    placeholder="Выберите модель"
                  />
                  <Button size="large" icon={<ReloadOutlined />} loading={busy === 'models'} onClick={loadModels}>
                    Показать доступные
                  </Button>
                </Flex>
                <Hint>
                  В списке — только модели Gemini, которые возвращают картинку. Pro Image точнее рисует надписи на упаковке и умеет искать товар в
                  интернете, Nano Banana и Flash Image — быстрее и дешевле.
                  {models && ` Моделей вашего ключа: ${models.length}.`}
                </Hint>
              </Step>

              <Step n={mode === 'vertex' ? 5 : 4} title="Каким делать фото">
                <div>
                  <SettingRow
                    title="Фон"
                    text={background === 'transparent' ? 'Фона нет: товар вырезается, фото сохраняется в PNG с прозрачностью' : 'Товар вырезается и кладётся на однотонный фон'}
                  >
                    <Segmented
                      value={background}
                      onChange={(v) => setBackground(v as Background)}
                      options={[
                        { value: 'white', label: 'Белый' },
                        { value: 'light', label: 'Светло-серый' },
                        { value: 'transparent', label: 'Прозрачный' },
                      ]}
                    />
                  </SettingRow>
                  <SettingRow title="Размер" text="Всегда квадрат 1:1, товар по центру с полями">
                    <Segmented
                      value={size}
                      onChange={(v) => setSize(v as 1000 | 1500 | 2000)}
                      options={[1000, 1500, 2000].map((v) => ({ value: v, label: `${v} px` }))}
                    />
                  </SettingRow>
                  <SettingRow title="Дорисовывать то, что не попало в кадр" text="Крышку, край упаковки, обрезанную этикетку">
                    <Switch checked={outpaint} onChange={setOutpaint} />
                  </SettingRow>
                  <SettingRow
                    title="Искать товар в интернете"
                    text={`По названию и штрихкоду находит упаковку и дорисовывает точно${searchModel ? '' : ' — выбранная модель поиска не умеет'}`}
                  >
                    <Switch checked={webSearch} onChange={setWebSearch} />
                  </SettingRow>
                  <SettingRow title="Показывать «до / после» перед сохранением" text="Фото от Gemini ставится, только когда его выбрали">
                    <Switch checked={beforeAfter} onChange={setBeforeAfter} />
                  </SettingRow>
                  <SettingRow title="Инструкция для Gemini" text="Что делать с фото: не менять надписи и цвета упаковки, не добавлять лишнего">
                    <Space size={8}>
                      <Typography.Text type="secondary" style={{ fontSize: 13 }}>
                        {prompt ? 'Своя' : 'Стандартная · 12 правил'}
                      </Typography.Text>
                      <Button type="link" danger style={{ padding: 0 }} onClick={() => setPromptDraft(prompt || s?.default_prompt || '')}>
                        Изменить
                      </Button>
                    </Space>
                  </SettingRow>
                </div>
              </Step>

              {showCheck && (
                <Step n={mode === 'vertex' ? 6 : 5} title="Проверка на фото">
                  <BeforeAfter before={testImage || item?.source} after={item?.result || undefined} busy={test.running} />
                  <Flex align="center" gap={12} wrap>
                    <Upload accept="image/jpeg,image/png,image/webp" showUploadList={false} beforeUpload={uploadTest}>
                      <Button size="large" icon={<UploadOutlined />} loading={busy === 'upload'}>
                        Загрузить своё фото
                      </Button>
                    </Upload>
                    <Hint>
                      {testImage ? (
                        <>
                          Проверим на вашем фото.{' '}
                          <Typography.Link onClick={() => setTestImage('')}>Вернуть стандартное</Typography.Link>
                        </>
                      ) : (
                        'или проверить на стандартном фото — сок без крышки в кадре'
                      )}
                    </Hint>
                  </Flex>
                </Step>
              )}

              {test.error && <Alert showIcon type="error" message={test.error} />}
              {test.job && !test.running && (
                <Alert
                  showIcon
                  type={test.job.ok ? 'success' : 'error'}
                  message={test.job.ok ? `${test.job.message}${outpaint ? ' — фон убран, товар целиком' : ' — фон убран'}` : test.job.message}
                />
              )}

              <Flex justify="space-between" gap={12} wrap style={{ borderTop: '1px solid #EAECF0', paddingTop: 20 }}>
                <Button size="large" icon={<ThunderboltOutlined />} loading={test.running} onClick={check} disabled={!model.trim()}>
                  Проверить на фото
                </Button>
                <Button size="large" type="primary" loading={busy === 'save'} onClick={save} disabled={!dirty || !model.trim() || !baseURL.trim()}>
                  {s?.configured ? 'Сохранить' : 'Подключить Gemini'}
                </Button>
              </Flex>
            </Space>
          </Card>
          {s && <StorePhotosCard s={s} models={models} onSaved={() => refetch()} />}
        </Col>
        <Col xs={24} xl={8}>
          <Space direction="vertical" size={16} style={{ width: '100%' }}>
            <Card loading={isLoading}>
              <Space direction="vertical" size={12} style={{ width: '100%' }}>
                <Badge
                  status={!s?.configured ? 'default' : s.check_ok === false ? 'error' : s.check_ok ? 'success' : 'warning'}
                  text={
                    <Typography.Text strong style={{ fontSize: 15 }}>
                      {!s?.configured
                        ? 'Gemini не подключён'
                        : `${s.check_ok === false ? 'Ошибка' : s.check_ok ? 'Подключено' : 'Не проверено'} · ${s.mode === 'vertex' ? 'Vertex AI' : 'Gemini API'}`}
                    </Typography.Text>
                  }
                />
                <Hint>
                  {!s?.configured
                    ? 'Пока фото товаров обрабатываются без ИИ: только уменьшаются до 1000 px и кладутся на белый фон.'
                    : tested
                      ? `Проверено ${dateTime(s.checked_at!)}: ${s.check_message}`
                      : 'Нажмите «Проверить на фото», чтобы убедиться, что Gemini рисует фото.'}
                </Hint>
                {s?.configured && (
                  <Row gutter={12}>
                    <Col span={12}>
                      <Card size="small" style={{ background: '#F8FAFC' }}>
                        <Statistic title="Фото за месяц" value={s.month_photos} groupSeparator=" " />
                      </Card>
                    </Col>
                    <Col span={12}>
                      <Card size="small" style={{ background: '#F8FAFC' }}>
                        <Statistic title="Ошибок" value={s.month_failed} />
                      </Card>
                    </Col>
                  </Row>
                )}
              </Space>
            </Card>
            <Card title="Цена за фото">
              <Space direction="vertical" size={8} style={{ width: '100%' }}>
                {PRICES.map(([m, p]) => (
                  <Flex key={m} justify="space-between" gap={8}>
                    <Typography.Text style={{ color: '#344054' }}>{m}</Typography.Text>
                    <Typography.Text strong>{usd(p)}</Typography.Text>
                  </Flex>
                ))}
                {!!s?.configured && (
                  <Flex justify="space-between" gap={8} style={{ borderTop: '1px solid #EAECF0', paddingTop: 8 }}>
                    <Typography.Text strong>За этот месяц</Typography.Text>
                    <Typography.Text strong>{usd(s.month_cost_usd)}</Typography.Text>
                  </Flex>
                )}
                <Hint>
                  По прайсу Google, фото 1K. Платите вы — по своему ключу. Подробный расход — <Link to="/ai?tab=usage">«ИИ-сервис» → Расход</Link>.
                </Hint>
              </Space>
            </Card>
            <Card title="Где используется">
              <Space direction="vertical" size={12}>
                <div>
                  <Typography.Text strong>
                    <CameraOutlined /> Редактирование фото
                  </Typography.Text>
                  <div>
                    <Hint>«Нормализовать фото» на странице товара: убрать фон, выровнять, поправить свет, дорисовать край</Hint>
                  </div>
                </div>
                <div>
                  <Typography.Text strong>
                    <ShopOutlined /> Фото для магазинов
                  </Typography.Text>{' '}
                  {s?.configured && s.store_enabled ? <Tag color="green">включено</Tag> : <Tag>выключено</Tag>}
                  <div>
                    <Hint>Super Market сам делает чистое фото нового товара и товара без фото на инвентаризации — блок слева</Hint>
                  </div>
                </div>
              </Space>
            </Card>
            <Alert
              type="info"
              icon={<ContainerOutlined />}
              showIcon
              message={
                <>
                  Приход по фото накладной и сопоставление с каталогом остаются на «ИИ-сервис» — эта страница на них не влияет.{' '}
                  <Link to="/ai">Открыть ИИ-сервис →</Link>
                </>
              }
            />
            <Alert
              type="info"
              icon={<LockOutlined />}
              showIcon
              message="Фото уходят только в Google Gemini по вашему ключу. Если Gemini не ответил — фото остаётся как было."
            />
            {mode === 'vertex' && (
              <Alert type="info" icon={<CloudOutlined />} showIcon message="Vertex AI: модели для картинок — в регионе global." />
            )}
          </Space>
        </Col>
      </Row>
      <Modal
        open={promptDraft !== null}
        title="Инструкция для Gemini"
        width={720}
        okText="Готово"
        onCancel={() => setPromptDraft(null)}
        onOk={() => {
          const v = (promptDraft ?? '').trim()
          setPrompt(v === (s?.default_prompt ?? '').trim() ? '' : v)
          setPromptDraft(null)
        }}
        footer={(_, { OkBtn, CancelBtn }) => (
          <Flex justify="space-between">
            <Button onClick={() => setPromptDraft(s?.default_prompt ?? '')}>Вернуть стандартную</Button>
            <Space>
              <CancelBtn />
              <OkBtn />
            </Space>
          </Flex>
        )}
      >
        <Space direction="vertical" size={8} style={{ width: '100%' }}>
          <Hint>
            Правила обработки фото. Фон, дорисовку, название товара и поиск в интернете Super Market добавит сам — по настройкам выше. Изменения
            применятся после «Сохранить».
          </Hint>
          <Input.TextArea
            rows={16}
            maxLength={4000}
            showCount
            value={promptDraft ?? ''}
            onChange={(e) => setPromptDraft(e.target.value)}
            style={{ fontFamily: 'monospace', fontSize: 12 }}
          />
        </Space>
      </Modal>
    </>
  )
}

/** «ИИ для фото»: подключение Gemini (Figma Ф1–Ф2). */
export function AIPhoto() {
  return (
    <>
      <PageTitle
        title="ИИ для фото"
        tabs={
          <Typography.Text type="secondary" style={{ display: 'block', padding: '0 16px 12px' }}>
            Gemini генерирует и редактирует фото товаров. Приход по фото накладной и сопоставление с каталогом остаются на «ИИ-сервис»
          </Typography.Text>
        }
      />
      <PhotoConnection />
    </>
  )
}
