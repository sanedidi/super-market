// «Подписка → Тарифы витрины»: цены и лимиты «Старт / Бизнес / Про».
import { useEffect } from 'react'
import { Button, Card, Checkbox, Form, Input, InputNumber, Radio, Space, Switch, Typography } from 'antd'
import { LoadError, PageTitle, api, useAction, useList } from '@sm/shared'

interface Plan {
  key: string
  name: string
  price_uzs: string
  custom: boolean
  banners: number | null
  shelves: number | null
  promos: number | null
  manual: boolean
  schedule: boolean
  per_store: boolean
  stats: string
  recommended: boolean
  ads_max: number
  ads_reducible: boolean
}

const LIMITS = [
  { name: 'banners', label: 'Свои фото-баннеры' },
  { name: 'shelves', label: 'Свои полки товаров' },
  { name: 'promos', label: 'Промо-полоски' },
] as const

function PlanCard({ plan }: { plan: Plan }) {
  const [form] = Form.useForm()
  useEffect(() => {
    form.setFieldsValue({
      ...plan,
      price_uzs: Number(plan.price_uzs),
      ...Object.fromEntries(LIMITS.flatMap((l) => [[l.name, plan[l.name] ?? 0], [`${l.name}_unlimited`, plan[l.name] === null]])),
    })
  }, [plan, form])
  const save = useAction(
    (v: Record<string, unknown>) =>
      api.patch(`/admin/showcase/plans/${plan.key}`, {
        name: v.name,
        price_uzs: String(v.price_uzs ?? 0),
        custom: v.custom,
        manual: v.manual,
        schedule: v.schedule,
        per_store: v.per_store,
        stats: v.stats,
        recommended: v.recommended,
        ads_max: v.ads_max,
        ads_reducible: v.ads_reducible,
        ...Object.fromEntries(LIMITS.map((l) => [l.name, v[`${l.name}_unlimited`] ? -1 : (v[l.name] ?? 0)])),
      }),
    { success: `Тариф «${plan.name}» сохранён` },
  )
  return (
    <Card title={plan.name} style={{ flex: '1 1 300px', maxWidth: 420 }} styles={{ body: { paddingTop: 12 } }}>
      <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v)} size="middle">
        <Form.Item name="name" label="Название" rules={[{ required: true }]}>
          <Input />
        </Form.Item>
        <Form.Item name="price_uzs" label="Цена в месяц, сум" extra="Входит в ежемесячный счёт за подписку. 0 — бесплатно.">
          <InputNumber min={0} step={10000} style={{ width: '100%' }} />
        </Form.Item>
        <Form.Item name="custom" valuePropName="checked">
          <Checkbox>Своя витрина (порядок блоков, свои блоки)</Checkbox>
        </Form.Item>
        {LIMITS.map((l) => (
          <Form.Item key={l.name} label={l.name === 'banners' ? `${l.label} (одновременно)` : l.label}>
            <Space>
              <Form.Item noStyle shouldUpdate>
                {({ getFieldValue }) => (
                  <Form.Item name={l.name} noStyle>
                    <InputNumber min={0} max={1000} precision={0} disabled={getFieldValue(`${l.name}_unlimited`)} style={{ width: 230 }} />
                  </Form.Item>
                )}
              </Form.Item>
              <Form.Item name={`${l.name}_unlimited`} valuePropName="checked" noStyle>
                <Checkbox>без лимита</Checkbox>
              </Form.Item>
            </Space>
          </Form.Item>
        ))}
        <Form.Item name="manual" valuePropName="checked" style={{ marginBottom: 4 }}>
          <Checkbox>Подборка «вручную»</Checkbox>
        </Form.Item>
        <Form.Item name="schedule" valuePropName="checked" style={{ marginBottom: 4 }}>
          <Checkbox>Расписание блоков</Checkbox>
        </Form.Item>
        <Form.Item name="per_store" valuePropName="checked">
          <Checkbox>Разные витрины магазинов сети</Checkbox>
        </Form.Item>
        <Form.Item name="stats" label="Статистика">
          <Radio.Group
            optionType="button"
            options={[
              { value: 'none', label: 'Нет' },
              { value: 'basic', label: 'Базовая' },
              { value: 'full', label: 'Полная' },
            ]}
          />
        </Form.Item>
        <Form.Item label="Реклама брендов на главной">
          <Space>
            <Form.Item name="ads_max" noStyle>
              <InputNumber min={0} max={2} precision={0} addonAfter="блоков" style={{ width: 150 }} />
            </Form.Item>
            <Form.Item name="ads_reducible" valuePropName="checked" noStyle>
              <Checkbox>сеть может меньше или выключить</Checkbox>
            </Form.Item>
          </Space>
        </Form.Item>
        <Form.Item name="recommended" label="Метка «Рекомендуем»" valuePropName="checked">
          <Switch />
        </Form.Item>
        <Button type="primary" htmlType="submit" loading={save.isPending}>
          Сохранить
        </Button>
      </Form>
    </Card>
  )
}

export function ShowcasePlans() {
  const list = useList<Plan>('/admin/showcase/plans')
  return (
    <>
      <PageTitle title="Тарифы витрины" />
      <Typography.Paragraph type="secondary" style={{ maxWidth: 760 }}>
        Что сеть может настроить на главной приложения. Лимиты проверяются при публикации витрины; при понижении тарифа лишнее скрывается, но не удаляется.
        Пробный период — в «Настройках подписки».
      </Typography.Paragraph>
      <LoadError error={list.error} retry={list.refetch} />
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start' }}>
        {list.data?.map((p) => <PlanCard key={p.key} plan={p} />)}
      </div>
    </>
  )
}
