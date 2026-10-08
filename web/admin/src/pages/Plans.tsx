import { useEffect, useMemo, useState } from 'react'
import { Alert, Button, Card, Checkbox, Col, Empty, Form, Input, InputNumber, Modal, Popconfirm, Row, Select, Space, Spin, Switch, Tag, Typography } from 'antd'
import { ClockCircleOutlined, EyeInvisibleOutlined, InboxOutlined, PlusOutlined, ShopOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, money, useAction, useItem, useList } from '@sm/shared'

// Тарифы магазинов (макет A1/A3, Figma «Тарифы магазинов»): цена, комиссия,
// функции галочками и лимиты. Какие функции и лимиты бывают — реестр
// бэкенда (/admin/plans/registry), здесь только включаем их в тарифы.

export interface Plan {
  key: string
  name: string
  name_uz: string
  description: string
  description_uz: string
  price_uzs: string
  min_stores: number
  order_commission: string
  features: string[]
  limits: Record<string, number>
  is_public: boolean
  is_active: boolean
  recommended: boolean
  sort: number
  networks_count: number
}

interface RegistryItem {
  key: string
  group?: string
  name: string
  name_uz: string
  hint?: string
  max?: number
  default?: number
}

interface Registry {
  groups: RegistryItem[]
  features: RegistryItem[]
  limits: RegistryItem[]
}

export interface BillingSettingsData {
  grace_days: number
  auto_charge_balance: boolean
  trial_plan: string
  trial_days: number
}

const plural = (n: number, one: string, few: string, many: string) => {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}

export const networksText = (n: number) => `${n} ${plural(n, 'сеть', 'сети', 'сетей')}`

/** Цена тарифа одной строкой: «149 000 сум за магазин». */
export function planPrice(p: Pick<Plan, 'price_uzs'>) {
  return Number(p.price_uzs) > 0 ? `${money(p.price_uzs)} сум` : '0 сум'
}

function planSub(p: Plan) {
  const parts: string[] = []
  if (Number(p.order_commission) > 0) parts.push(`комиссия ${Number(p.order_commission)}% с онлайн-заказа`)
  else parts.push('за магазин · без комиссии')
  if (p.min_stores > 1) parts.push(`от ${p.min_stores} магазинов`)
  return parts.join(' · ')
}

export function Plans() {
  const list = useList<Plan>('/admin/plans')
  const registry = useItem<Registry>('/admin/plans/registry')
  const settings = useItem<BillingSettingsData>('/admin/billing/settings')
  const [selected, setSelected] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [trialOpen, setTrialOpen] = useState(false)
  const plans = useMemo(() => list.data ?? [], [list.data])
  const visible = plans.filter((p) => p.is_active && p.is_public)
  const others = plans.filter((p) => !(p.is_active && p.is_public))
  useEffect(() => {
    if (!selected && plans.length) setSelected((plans.find((p) => p.recommended) ?? plans[0]).key)
  }, [plans, selected])
  const current = plans.find((p) => p.key === selected) ?? null
  const trialPlan = plans.find((p) => p.key === settings.data?.trial_plan)

  return (
    <>
      <PageTitle title="Тарифы">
        <Button icon={<ClockCircleOutlined />} onClick={() => setTrialOpen(true)}>
          {settings.data
            ? settings.data.trial_days > 0
              ? `Пробный период: ${trialPlan?.name ?? settings.data.trial_plan} · ${settings.data.trial_days} дн.`
              : 'Пробный период: выключен'
            : 'Пробный период'}
        </Button>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreating(true)}>
          Новый тариф
        </Button>
      </PageTitle>
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        Цена за магазин, комиссия, функции и лимиты. Функции и лимиты меняются у магазинов сразу, цена — со следующего счёта.
      </Typography.Paragraph>
      <LoadError error={list.error ?? registry.error} retry={() => (list.refetch(), registry.refetch())} />
      {list.isLoading && <Spin style={{ display: 'block', margin: '48px auto' }} />}

      <Row gutter={[16, 16]}>
        {visible.map((p) => (
          <Col key={p.key} xs={24} sm={12} xl={6}>
            <Card
              hoverable
              onClick={() => setSelected(p.key)}
              style={{ height: '100%', outline: p.key === selected ? '2px solid #155EEF' : undefined, outlineOffset: -1 }}
              styles={{ body: { padding: 16 } }}
            >
              <Space size={6} wrap>
                <Typography.Text strong style={{ fontSize: 16 }}>
                  {p.name}
                </Typography.Text>
                {p.recommended && <Tag color="blue">Рекомендуемый</Tag>}
              </Space>
              <div style={{ fontSize: 22, fontWeight: 800, margin: '4px 0' }}>{planPrice(p)}</div>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {planSub(p)}
              </Typography.Text>
              <div style={{ marginTop: 8 }}>
                <Typography.Text type="secondary">
                  <ShopOutlined /> {networksText(p.networks_count)}
                </Typography.Text>
              </div>
            </Card>
          </Col>
        ))}
      </Row>

      {others.length > 0 && (
        <Space direction="vertical" style={{ width: '100%', marginTop: 12 }} size={8}>
          {others.map((p) => (
            <div
              key={p.key}
              onClick={() => setSelected(p.key)}
              style={{
                cursor: 'pointer',
                padding: '10px 16px',
                borderRadius: 12,
                border: `1px dashed ${p.key === selected ? '#155EEF' : '#D0D5DD'}`,
                background: '#F9FAFB',
              }}
            >
              <Space wrap>
                {p.is_active ? <EyeInvisibleOutlined /> : <InboxOutlined />}
                <b>{p.name}</b>
                <Tag>{p.is_active ? 'Скрытый' : 'В архиве'}</Tag>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {p.is_active
                    ? 'Не виден на сайте и в панели магазина — супер-админ назначает сети вручную'
                    : 'Выбрать и назначить нельзя; сети, которые на нём, остаются'}{' '}
                  · {planPrice(p)} · {networksText(p.networks_count)}
                </Typography.Text>
              </Space>
            </div>
          ))}
        </Space>
      )}

      {current && registry.data && <PlanEditor key={current.key + current.sort} plan={current} registry={registry.data} isTrial={settings.data?.trial_plan === current.key} />}
      {!list.isLoading && plans.length === 0 && <Empty description="Тарифов нет" />}

      <CreatePlanModal open={creating} onClose={() => setCreating(false)} onCreated={(k) => setSelected(k)} />
      <TrialModal open={trialOpen} onClose={() => setTrialOpen(false)} plans={plans} />
    </>
  )
}

type LimitValue = { value?: number | null; unlimited: boolean }

interface EditorValues {
  name: string
  name_uz: string
  description: string
  description_uz: string
  price_uzs: number
  min_stores: number
  order_commission: number
  sort: number
  is_public: boolean
  recommended: boolean
  features: Record<string, boolean>
  limits: Record<string, LimitValue>
}

function toValues(p: Plan, reg: Registry): EditorValues {
  const features: Record<string, boolean> = {}
  for (const f of reg.features) features[f.key] = p.features.includes(f.key)
  const limits: Record<string, LimitValue> = {}
  for (const l of reg.limits) {
    const v = p.limits[l.key] ?? l.default
    limits[l.key] = v === undefined ? { value: null, unlimited: true } : { value: v, unlimited: false }
  }
  return {
    name: p.name,
    name_uz: p.name_uz,
    description: p.description,
    description_uz: p.description_uz,
    price_uzs: Number(p.price_uzs),
    min_stores: p.min_stores,
    order_commission: Number(p.order_commission),
    sort: p.sort,
    is_public: p.is_public,
    recommended: p.recommended,
    features,
    limits,
  }
}

function PlanEditor({ plan, registry, isTrial }: { plan: Plan; registry: Registry; isTrial: boolean }) {
  const [form] = Form.useForm<EditorValues>()
  const initial = useMemo(() => toValues(plan, registry), [plan, registry])
  const save = useAction(
    (v: EditorValues) =>
      api.patch(`/admin/plans/${plan.key}`, {
        name: v.name,
        name_uz: v.name_uz ?? '',
        description: v.description ?? '',
        description_uz: v.description_uz ?? '',
        price_uzs: String(v.price_uzs ?? 0),
        min_stores: v.min_stores ?? 1,
        order_commission: String(v.order_commission ?? 0),
        sort: v.sort ?? 0,
        is_public: v.is_public,
        recommended: v.recommended,
        features: registry.features.filter((f) => v.features?.[f.key]).map((f) => f.key),
        limits: Object.fromEntries(
          registry.limits.map((l) => {
            const x = v.limits?.[l.key]
            return [l.key, !x || x.unlimited || x.value === null || x.value === undefined ? null : x.value]
          }),
        ),
      }),
    { success: 'Тариф сохранён' },
  )
  const archive = useAction((active: boolean) => api.patch(`/admin/plans/${plan.key}`, { is_active: active }), {
    success: plan.is_active ? 'Тариф убран в архив' : 'Тариф снова действует',
  })
  const remove = useAction(() => api.del(`/admin/plans/${plan.key}`), { success: 'Тариф удалён' })
  const features = Form.useWatch('features', form) ?? initial.features
  const enabled = registry.features.filter((f) => features[f.key]).length
  const groupName = (k: string) => registry.groups.find((g) => g.key === k)?.name ?? k
  // Витрина — отдельной колонкой справа, остальные группы слева.
  const leftGroups = registry.groups.filter((g) => g.key !== 'showcase')
  const rightGroups = registry.groups.filter((g) => g.key === 'showcase')
  const featureList = (groups: RegistryItem[]) =>
    groups.map((g) => (
      <div key={g.key} style={{ marginBottom: 16 }}>
        <Typography.Text strong>{groupName(g.key)}</Typography.Text>
        {registry.features
          .filter((f) => f.group === g.key)
          .map((f) => (
            <Form.Item key={f.key} name={['features', f.key]} valuePropName="checked" style={{ margin: '8px 0 0' }}>
              <Checkbox>
                <b>{f.name}</b>
                <div style={{ fontSize: 12, color: '#667085' }}>{f.hint}</div>
              </Checkbox>
            </Form.Item>
          ))}
      </div>
    ))

  return (
    <Card style={{ marginTop: 16 }} styles={{ body: { padding: 24 } }}>
      <Form form={form} layout="vertical" initialValues={initial} onFinish={(v) => save.mutate(v)}>
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
          <Space size={8} wrap>
            <Typography.Title level={4} style={{ margin: 0 }}>
              {plan.name}
            </Typography.Title>
            <Tag>{plan.key}</Tag>
            <Tag icon={<ShopOutlined />}>{networksText(plan.networks_count)}</Tag>
            {isTrial && <Tag color="gold">пробный период</Tag>}
            {!plan.is_active && <Tag color="default">в архиве</Tag>}
          </Space>
          <Space wrap>
            {plan.is_active ? (
              <Popconfirm
                title="Убрать тариф в архив?"
                description="Новым сетям его выбрать и назначить будет нельзя. Сети, которые на нём, остаются."
                okText="В архив"
                disabled={isTrial}
                onConfirm={() => archive.mutateAsync(false).catch(() => undefined)}
              >
                <Button icon={<InboxOutlined />} disabled={isTrial} title={isTrial ? 'Это тариф пробного периода' : undefined} loading={archive.isPending}>
                  В архив
                </Button>
              </Popconfirm>
            ) : (
              <Button onClick={() => archive.mutate(true)} loading={archive.isPending}>
                Вернуть из архива
              </Button>
            )}
            {plan.networks_count === 0 && !isTrial && (
              <Popconfirm title="Удалить тариф?" okText="Удалить" okButtonProps={{ danger: true }} onConfirm={() => remove.mutateAsync(undefined).catch(() => undefined)}>
                <Button danger loading={remove.isPending}>
                  Удалить
                </Button>
              </Popconfirm>
            )}
            <Button type="primary" htmlType="submit" loading={save.isPending}>
              Сохранить
            </Button>
          </Space>
        </div>

        <Row gutter={32}>
          <Col xs={24} lg={8}>
            <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
              ОСНОВНОЕ
            </Typography.Text>
            <Row gutter={12} style={{ marginTop: 8 }}>
              <Col span={12}>
                <Form.Item name="name" label="Название (ru)" rules={[{ required: true, whitespace: true }]}>
                  <Input />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name="name_uz" label="Название (uz)">
                  <Input />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name="description" label="Описание (ru)">
              <Input.TextArea autoSize={{ minRows: 2, maxRows: 4 }} />
            </Form.Item>
            <Form.Item name="description_uz" label="Описание (uz)">
              <Input.TextArea autoSize={{ minRows: 2, maxRows: 4 }} />
            </Form.Item>
            <Row gutter={12}>
              <Col span={12}>
                <Form.Item name="price_uzs" label="Цена за магазин, сум">
                  <InputNumber<number> min={0} step={1000} precision={0} style={{ width: '100%' }} formatter={(v) => (v === undefined || v === null ? '' : Number(v).toLocaleString('ru-RU'))} parser={(v) => Number((v ?? '').replace(/\D/g, ''))} />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name="min_stores" label="Минимум магазинов" tooltip="Сама сеть может выбрать тариф, только если магазинов не меньше. Супер-админ назначает без проверки.">
                  <InputNumber min={1} max={1000} precision={0} style={{ width: '100%' }} />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name="order_commission" label="Комиссия с заказа, %" tooltip="Удерживается с оплаченного онлайн-заказа; 0 — без комиссии">
                  <InputNumber min={0} max={50} step={0.5} precision={1} style={{ width: '100%' }} />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name="sort" label="Порядок">
                  <InputNumber precision={0} style={{ width: '100%' }} />
                </Form.Item>
              </Col>
            </Row>
            <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
              ВИДИМОСТЬ
            </Typography.Text>
            <Form.Item name="is_public" valuePropName="checked" style={{ margin: '8px 0 0' }} extra="Выключите — тариф станет скрытым: назначить его сети сможет только супер-админ.">
              <SwitchLabel label="Показывать на сайте и в панели магазина" />
            </Form.Item>
            <Form.Item name="recommended" valuePropName="checked" style={{ marginTop: 12 }} extra="Метка «Рекомендуем» на сайте и в «Моём тарифе»; только у одного тарифа.">
              <SwitchLabel label="Рекомендуемый" />
            </Form.Item>
          </Col>

          <Col xs={24} lg={16}>
            <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
              ФУНКЦИИ
            </Typography.Text>{' '}
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {enabled} из {registry.features.length} включено
            </Typography.Text>
            <Row gutter={24} style={{ marginTop: 8 }}>
              <Col xs={24} md={12}>
                {featureList(leftGroups)}
              </Col>
              <Col xs={24} md={12}>
                {featureList(rightGroups)}
              </Col>
            </Row>
            <div style={{ borderTop: '1px solid #EAECF0', paddingTop: 16 }}>
              <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
                ЛИМИТЫ
              </Typography.Text>{' '}
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                «без лимита» — не ограничено. При понижении тарифа ничего не удаляется, но добавить сверх лимита нельзя.
              </Typography.Text>
              <Row gutter={24} style={{ marginTop: 8 }}>
                {registry.limits.map((l) => (
                  <Col key={l.key} xs={24} md={12}>
                    <LimitRow item={l} />
                  </Col>
                ))}
              </Row>
            </div>
          </Col>
        </Row>
      </Form>
    </Card>
  )
}

function SwitchLabel({ label, checked, onChange }: { label: string; checked?: boolean; onChange?: (v: boolean) => void }) {
  return (
    <Space>
      <Switch checked={checked} onChange={onChange} />
      <b>{label}</b>
    </Space>
  )
}

function LimitRow({ item }: { item: RegistryItem }) {
  const unlimited = Form.useWatch(['limits', item.key, 'unlimited'])
  const capped = (item.max ?? 0) > 0
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '8px 0' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <b>{item.name}</b>
        <div style={{ fontSize: 12, color: '#667085' }}>{item.hint}</div>
      </div>
      <Form.Item name={['limits', item.key, 'value']} noStyle>
        <InputNumber min={0} max={capped ? item.max : 100000} precision={0} disabled={unlimited} placeholder="—" style={{ width: 80 }} />
      </Form.Item>
      {!capped && (
        <Space size={6}>
          <Form.Item name={['limits', item.key, 'unlimited']} valuePropName="checked" noStyle>
            <Switch size="small" />
          </Form.Item>
          <Typography.Text type="secondary" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
            без лимита
          </Typography.Text>
        </Space>
      )}
    </div>
  )
}

function CreatePlanModal({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (key: string) => void }) {
  const [form] = Form.useForm()
  const create = useAction((v: { key: string; name: string; price_uzs?: number }) => api.post<Plan>('/admin/plans', { ...v, price_uzs: String(v.price_uzs ?? 0) }), {
    success: 'Тариф создан',
  })
  return (
    <Modal
      open={open}
      title="Новый тариф"
      okText="Создать"
      confirmLoading={create.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      destroyOnHidden
    >
      <Form
        form={form}
        layout="vertical"
        preserve={false}
        onFinish={(v) =>
          create.mutate(v, {
            onSuccess: (p) => {
              onCreated(p.key)
              onClose()
            },
          })
        }
      >
        <Form.Item name="name" label="Название" rules={[{ required: true, whitespace: true }]}>
          <Input placeholder="Например, Пилот" />
        </Form.Item>
        <Form.Item
          name="key"
          label="Ключ"
          extra="Латиница в нижнем регистре, цифры и _. Не меняется."
          rules={[{ required: true }, { pattern: /^[a-z][a-z0-9_]{1,30}$/, message: 'Например: pilot, big_network' }]}
        >
          <Input placeholder="pilot" />
        </Form.Item>
        <Form.Item name="price_uzs" label="Цена, сум за магазин в месяц">
          <InputNumber min={0} step={1000} precision={0} style={{ width: '100%' }} />
        </Form.Item>
        <Alert type="info" showIcon message="Функции, лимиты и видимость настраиваются после создания." />
      </Form>
    </Modal>
  )
}

/** Пробный период и счета (макет A3) — окно на «Тарифах» и страница «Настройки». */
export function BillingSettingsForm({ plans, onSaved }: { plans: Plan[]; onSaved?: () => void }) {
  const { data } = useItem<BillingSettingsData>('/admin/billing/settings')
  const [form] = Form.useForm<BillingSettingsData>()
  useEffect(() => {
    if (data) form.setFieldsValue(data)
  }, [data, form])
  const save = useAction((v: BillingSettingsData) => api.put('/admin/billing/settings', v), { success: 'Сохранено' })
  return (
    <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: () => onSaved?.() })} id="billing-settings">
      <Row gutter={12}>
        <Col span={14}>
          <Form.Item name="trial_plan" label="Тариф пробного периода" rules={[{ required: true }]}>
            <Select options={plans.filter((p) => p.is_active).map((p) => ({ value: p.key, label: p.name }))} />
          </Form.Item>
        </Col>
        <Col span={10}>
          <Form.Item name="trial_days" label="Дней" rules={[{ required: true }]}>
            <InputNumber min={0} max={365} precision={0} style={{ width: '100%' }} />
          </Form.Item>
        </Col>
      </Row>
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        Новый одиночный магазин столько дней работает на этом тарифе и не платит, потом — на своём. 0 дней — без пробного. Тариф пробного
        нельзя убрать в архив.
      </Typography.Paragraph>
      <Form.Item name="grace_days" label="Дней на оплату счёта" rules={[{ required: true }]} extra="После этого магазины сети скрываются из приложения.">
        <InputNumber min={0} max={60} precision={0} style={{ width: '100%' }} />
      </Form.Item>
      <Form.Item name="auto_charge_balance" valuePropName="checked">
        <Checkbox>Списывать подписку с баланса магазина автоматически</Checkbox>
      </Form.Item>
      {!onSaved && (
        <Button type="primary" htmlType="submit" loading={save.isPending}>
          Сохранить
        </Button>
      )}
    </Form>
  )
}

function TrialModal({ open, onClose, plans }: { open: boolean; onClose: () => void; plans: Plan[] }) {
  return (
    <Modal open={open} title="Пробный период и счета" okText="Сохранить" onCancel={onClose} okButtonProps={{ htmlType: 'submit', form: 'billing-settings' }} destroyOnHidden>
      <BillingSettingsForm plans={plans} onSaved={onClose} />
    </Modal>
  )
}
