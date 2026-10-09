// ИИ-сервис платформы (Figma «Админка · ИИ-сервис»): сервис, адрес, ключ, модель.
// Сервисы: OpenAI и совместимые, Anthropic, Google Vertex AI (Gemini).
// Ключ хранится на сервере зашифрованным и обратно не показывается.
import { useEffect, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Alert, App, AutoComplete, Badge, Button, Card, Col, Flex, Input, Radio, Row, Segmented, Space, Statistic, Tag, Typography } from 'antd'
import { ApiOutlined, CheckCircleFilled, KeyOutlined, LinkOutlined, LockOutlined, ReloadOutlined, ThunderboltOutlined } from '@ant-design/icons'
import { useSearchParams } from 'react-router-dom'
import { LoadError, PageTitle, api, dateTime, errorText, useItem } from '@sm/shared'
import { AIUsage } from './AIUsage'

type Provider = 'openai' | 'anthropic' | 'vertex'

interface Settings {
  provider: Provider
  base_url: string
  model: string
  has_key: boolean
  key_last4: string
  configured: boolean
  checked_at: string | null
  check_ok: boolean | null
  check_message: string
  month_scans: number
  month_failed: number
}

interface Model {
  id: string
  vision: boolean | null
}

interface TestResult {
  ok: boolean
  message: string
  ms: number
}

const DEFAULT_URL: Record<Provider, string> = {
  openai: 'https://api.openai.com/v1',
  anthropic: 'https://api.anthropic.com',
  vertex: 'https://aiplatform.googleapis.com/v1',
}

const PROVIDER_NAME: Record<Provider, string> = {
  openai: 'OpenAI-совместимый',
  anthropic: 'Anthropic',
  vertex: 'Vertex AI (Gemini)',
}

const MODEL_PLACEHOLDER: Record<Provider, string> = {
  openai: 'gpt-…',
  anthropic: 'claude-…',
  vertex: 'gemini-…',
}

// Vertex AI: регионы для быстрого выбора. Gemini 3 (preview) — только global.
const VERTEX_REGIONS = [
  { label: 'global', value: 'global' },
  { label: 'Франкфурт', value: 'europe-west3' },
  { label: 'Нидерланды', value: 'europe-west4' },
  { label: 'Айова (США)', value: 'us-central1' },
]

const vertexURL = (project: string, region: string) =>
  `https://${region === 'global' ? '' : `${region}-`}aiplatform.googleapis.com/v1/projects/${project}/locations/${region}`
const vertexProject = (url: string) => /\/projects\/([^/]+)/.exec(url)?.[1] ?? ''
const vertexRegion = (url: string) => /\/locations\/([^/]+)/.exec(url)?.[1] ?? 'global'

interface ServiceAccount {
  project_id: string
  client_email: string
}

/** JSON-ключ сервисного аккаунта Google, если вставили его. */
function parseServiceAccount(key: string): ServiceAccount | null {
  if (!key.trim().startsWith('{')) return null
  try {
    const j = JSON.parse(key)
    return j?.type === 'service_account' && j.client_email ? { project_id: j.project_id ?? '', client_email: j.client_email } : null
  } catch {
    return null
  }
}

// Совместимые с OpenAI сервисы — быстрый выбор адреса.
const PRESETS = [
  { label: 'OpenAI', url: 'https://api.openai.com/v1' },
  { label: 'OpenRouter', url: 'https://openrouter.ai/api/v1' },
  { label: 'DeepSeek', url: 'https://api.deepseek.com/v1' },
  { label: 'Groq', url: 'https://api.groq.com/openai/v1' },
]

function Step({ n, title, children }: { n: number; title: string; children: ReactNode }) {
  return (
    <Space direction="vertical" size={10} style={{ width: '100%' }}>
      <Flex align="center" gap={10}>
        <Flex align="center" justify="center" style={{ width: 24, height: 24, borderRadius: 12, background: '#101828', color: '#fff', fontWeight: 800, fontSize: 12 }}>
          {n}
        </Flex>
        <Typography.Text strong style={{ fontSize: 16 }}>
          {title}
        </Typography.Text>
      </Flex>
      {children}
    </Space>
  )
}

function Hint({ children }: { children: ReactNode }) {
  return (
    <Typography.Text type="secondary" style={{ fontSize: 13 }}>
      {children}
    </Typography.Text>
  )
}

function ProviderCard({ active, title, text, onClick }: { active: boolean; title: string; text: string; onClick: () => void }) {
  return (
    <Card
      hoverable
      onClick={onClick}
      style={{ height: '100%', borderColor: active ? '#E11D2A' : undefined, borderWidth: active ? 2 : 1, background: active ? '#FEF3F2' : undefined }}
      styles={{ body: { padding: 16 } }}
    >
      <Radio checked={active}>
        <Typography.Text strong style={{ fontSize: 15 }}>
          {title}
        </Typography.Text>
      </Radio>
      <div style={{ marginTop: 6 }}>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {text}
        </Typography.Text>
      </div>
    </Card>
  )
}

function AIConnection() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const { data: s, error, refetch, isLoading } = useItem<Settings>('/admin/ai')
  const [provider, setProvider] = useState<Provider>('openai')
  const [baseURL, setBaseURL] = useState(DEFAULT_URL.openai)
  const [key, setKey] = useState('')
  const [replacing, setReplacing] = useState(false)
  const [model, setModel] = useState('')
  // Текст, который человек печатает в поле модели; пусто — показываем весь список.
  const [search, setSearch] = useState('')
  const [models, setModels] = useState<Model[] | null>(null)
  const [busy, setBusy] = useState<'' | 'models' | 'test' | 'save'>('')
  const [test, setTest] = useState<TestResult | null>(null)

  useEffect(() => {
    if (!s) return
    setProvider(s.provider)
    setBaseURL(s.base_url)
    setModel(s.model)
    setKey('')
    setReplacing(false)
  }, [s])

  // Сохранённый ключ годится, только пока сервис и адрес те же.
  const savedKeyUsable = !!s?.has_key && s.provider === provider && s.base_url === baseURL.trim().replace(/\/+$/, '')
  const showSavedKey = savedKeyUsable && !replacing
  const body = () => ({ provider, base_url: baseURL.trim(), api_key: showSavedKey ? '' : key.trim(), model: model.trim() })
  const dirty = !!s && (s.provider !== provider || s.base_url !== baseURL.trim().replace(/\/+$/, '') || s.model !== model.trim() || !showSavedKey)

  const sa = provider === 'vertex' ? parseServiceAccount(key) : null
  const changeKey = (v: string) => {
    setKey(v)
    // Vertex: по JSON-ключу сразу подставляем адрес его проекта (регион сохраняем).
    const acc = provider === 'vertex' ? parseServiceAccount(v) : null
    if (acc?.project_id) setBaseURL(vertexURL(acc.project_id, vertexProject(baseURL) ? vertexRegion(baseURL) : 'global'))
  }

  const switchProvider = (p: Provider) => {
    if (p === provider) return
    setProvider(p)
    setBaseURL(p === s?.provider ? s.base_url : DEFAULT_URL[p])
    setModel(p === s?.provider ? s.model : '')
    setModels(null)
    setKey('')
    setTest(null)
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
      const r = await api.post<{ items: Model[] | null }>('/admin/ai/models', body())
      setModels(r.items ?? [])
      const first = (r.items ?? []).find((m) => m.vision === true)
      if (!model.trim() && first) setModel(first.id)
      if (!r.items?.length) message.info('Сервис не вернул ни одной модели — впишите название вручную')
    })

  const check = () =>
    run('test', async () => {
      const r = await api.post<TestResult>('/admin/ai/test', dirty ? body() : {})
      setTest(r)
      if (!dirty) qc.invalidateQueries({ queryKey: ['/admin/ai'] })
    })

  const save = () =>
    run('save', async () => {
      await api.put<Settings>('/admin/ai', body())
      message.success('Сохранено')
      setTest(null)
      await refetch()
    })

  const options = (models ?? [])
    .filter((m) => !search || m.id.toLowerCase().includes(search.toLowerCase()))
    .map((m) => ({
    value: m.id,
    label: (
      <Flex justify="space-between" gap={8}>
        <span style={{ color: m.vision === false ? '#98A2B3' : undefined }}>{m.id}</span>
        {m.vision === true && <Tag color="green">видит фото</Tag>}
        {m.vision === false && <Tag>без фото — не подойдёт</Tag>}
      </Flex>
    ),
  }))

  return (
    <>
      <LoadError error={error} retry={() => refetch()} />
      <Row gutter={[24, 24]}>
        <Col xs={24} xl={16}>
          <Card loading={isLoading} styles={{ body: { padding: 24 } }}>
            <Space direction="vertical" size={24} style={{ width: '100%' }}>
              <Step n={1} title="Сервис">
                <Row gutter={[12, 12]}>
                  <Col xs={24} md={8}>
                    <ProviderCard
                      active={provider === 'openai'}
                      title="OpenAI и совместимые"
                      text="OpenRouter, DeepSeek, Groq, своя модель — любой сервис с протоколом OpenAI. По умолчанию — сам OpenAI"
                      onClick={() => switchProvider('openai')}
                    />
                  </Col>
                  <Col xs={24} md={8}>
                    <ProviderCard
                      active={provider === 'anthropic'}
                      title="Anthropic (Claude)"
                      text="У Claude свой формат запроса, поэтому его выбирают отдельно"
                      onClick={() => switchProvider('anthropic')}
                    />
                  </Col>
                  <Col xs={24} md={8}>
                    <ProviderCard
                      active={provider === 'vertex'}
                      title="Google Vertex AI (Gemini)"
                      text="Gemini через Google Cloud: ключ сервисного аккаунта (JSON) или API-ключ Vertex AI"
                      onClick={() => switchProvider('vertex')}
                    />
                  </Col>
                </Row>
              </Step>

              <Step n={2} title="Адрес сервиса">
                {provider === 'openai' && (
                  <Space wrap>
                    {PRESETS.map((p) => (
                      <Button key={p.url} type={baseURL === p.url ? 'primary' : 'default'} size="small" onClick={() => setBaseURL(p.url)}>
                        {p.label}
                      </Button>
                    ))}
                    <Button size="small" type={PRESETS.some((p) => p.url === baseURL) ? 'default' : 'primary'} onClick={() => setBaseURL('')}>
                      Свой адрес
                    </Button>
                  </Space>
                )}
                {provider === 'vertex' && vertexProject(baseURL) && (
                  <Space wrap>
                    {VERTEX_REGIONS.map((r) => (
                      <Button
                        key={r.value}
                        size="small"
                        type={vertexRegion(baseURL) === r.value ? 'primary' : 'default'}
                        onClick={() => setBaseURL(vertexURL(vertexProject(baseURL), r.value))}
                      >
                        {r.label}
                      </Button>
                    ))}
                  </Space>
                )}
                <Input size="large" prefix={<LinkOutlined />} value={baseURL} onChange={(e) => setBaseURL(e.target.value)} placeholder="https://…/v1" />
                <Hint>
                  {provider === 'openai'
                    ? 'Подставляется автоматически по выбранному сервису. Для другого совместимого сервиса впишите его адрес.'
                    : provider === 'anthropic'
                      ? 'Подставлен адрес Anthropic. Менять нужно, только если вы ходите через свой прокси.'
                      : 'Адрес проекта Google Cloud подставится сам, когда вставите JSON-ключ. Регион global — все модели Gemini, включая Gemini 3; для API-ключа Vertex AI (express) оставьте https://aiplatform.googleapis.com/v1.'}
                </Hint>
              </Step>

              <Step n={3} title="Ключ API">
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
                ) : provider === 'vertex' ? (
                  <Input.TextArea
                    rows={4}
                    value={key}
                    onChange={(e) => changeKey(e.target.value)}
                    placeholder={'Вставьте JSON-ключ сервисного аккаунта целиком: { "type": "service_account", … }\nили API-ключ Vertex AI'}
                    autoComplete="off"
                    spellCheck={false}
                    style={{ fontFamily: 'monospace', fontSize: 12 }}
                  />
                ) : (
                  <Input.Password
                    size="large"
                    prefix={<KeyOutlined />}
                    value={key}
                    onChange={(e) => setKey(e.target.value)}
                    placeholder={provider === 'anthropic' ? 'sk-ant-…' : 'sk-…'}
                    autoComplete="off"
                  />
                )}
                <Hint>
                  {provider === 'vertex'
                    ? 'Google Cloud → IAM → Сервисные аккаунты: создайте аккаунт с ролью «Vertex AI User», затем Ключи → Добавить ключ → JSON. В проекте должен быть включён Vertex AI API. Ключ хранится зашифрованным и обратно не показывается.'
                    : 'Ключ берётся в личном кабинете сервиса. Он хранится в вашей организации и обратно не показывается.'}
                </Hint>
              </Step>

              <Step n={4} title="Модель">
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
                    placeholder={MODEL_PLACEHOLDER[provider]}
                  />
                  <Button size="large" icon={<ReloadOutlined />} loading={busy === 'models'} onClick={loadModels}>
                    Показать доступные
                  </Button>
                </Flex>
                <Hint>
                  Нажмите «Показать доступные», чтобы выбрать из списка вашего ключа. Для накладных нужна модель, которая видит изображения.
                  {models && ` Моделей вашего ключа: ${models.length}.`}
                </Hint>
              </Step>

              {test && <Alert showIcon type={test.ok ? 'success' : 'error'} message={test.ok ? `Подключение работает: ${test.message}` : test.message} />}

              <Flex justify="space-between" gap={12} wrap style={{ borderTop: '1px solid #EAECF0', paddingTop: 20 }}>
                <Button size="large" icon={<ThunderboltOutlined />} loading={busy === 'test'} onClick={check} disabled={!model.trim()}>
                  Проверить подключение
                </Button>
                <Button size="large" type="primary" loading={busy === 'save'} onClick={save} disabled={!dirty || !model.trim() || !baseURL.trim()}>
                  Сохранить
                </Button>
              </Flex>
            </Space>
          </Card>
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
                        ? 'Не настроено'
                        : `${s.check_ok === false ? 'Ошибка' : s.check_ok ? 'Подключено' : 'Не проверено'} · ${PROVIDER_NAME[s.provider] ?? s.provider}`}
                    </Typography.Text>
                  }
                />
                <Hint>
                  {!s?.configured
                    ? 'Пока ИИ не подключён, приход по фото накладной в приложении магазина недоступен — остаётся сканирование товаров вручную.'
                    : s.checked_at
                      ? `Проверено ${dateTime(s.checked_at)}: ${s.check_message}`
                      : 'Нажмите «Проверить подключение», чтобы убедиться, что модель читает накладные.'}
                </Hint>
                {s?.configured && (
                  <Row gutter={12}>
                    <Col span={12}>
                      <Card size="small" style={{ background: '#F8FAFC' }}>
                        <Statistic title="Накладных за месяц" value={s.month_scans} />
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
            <Card title="Где используется">
              <Space direction="vertical" size={12}>
                <div>
                  <Typography.Text strong>
                    <ApiOutlined /> Приход по фото накладной
                  </Typography.Text>
                  <div>
                    <Hint>читает поставщика, строки и итог</Hint>
                  </div>
                </div>
                <div>
                  <Typography.Text strong>
                    <ApiOutlined /> Сопоставление с каталогом
                  </Typography.Text>
                  <div>
                    <Hint>подсказывает товар для строки накладной</Hint>
                  </div>
                </div>
              </Space>
            </Card>
            <Alert
              type="info"
              icon={<LockOutlined />}
              showIcon
              message="Фото накладных уходят только в выбранный сервис. Расходы на ИИ оплачиваются по вашему ключу."
            />
          </Space>
        </Col>
      </Row>
    </>
  )
}

/** ИИ-сервис: вкладки «Подключение» и «Расход» (Figma А1–А3). */
export function AISettings() {
  const [sp, setSp] = useSearchParams()
  const tab = sp.get('tab') === 'usage' ? 'usage' : 'connection'
  return (
    <>
      <PageTitle
        title="ИИ-сервис"
        tabs={
          <Segmented
            style={{ marginTop: 12 }}
            value={tab}
            onChange={(v) => setSp(v === 'usage' ? { tab: 'usage' } : {}, { replace: true })}
            options={[
              { value: 'connection', label: 'Подключение' },
              { value: 'usage', label: 'Расход' },
            ]}
          />
        }
      />
      {tab === 'usage' ? <AIUsage /> : <AIConnection />}
    </>
  )
}
