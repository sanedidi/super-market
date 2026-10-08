import { useEffect } from 'react'
import { Alert, Checkbox, Col, DatePicker, Form, InputNumber, Modal, Row, Select, Space, Spin, Tag, Typography } from 'antd'
import dayjs from 'dayjs'
import { api, money, useAction, useItem, useList } from '@sm/shared'
import { planPrice, type Plan } from './Plans'

// Тариф сети (макет A2): тариф (в т. ч. скрытый), пробный период, своя
// цена и «платит с». Открывается из «Сети и оплата» и из карточки сети.

export interface NetworkBilling {
  network_id: string
  network_name: string
  kind: string
  status: string
  stores_count: number
  plan_key: string
  plan_name: string
  effective_plan_key: string
  trial_until: string | null
  custom_price_uzs: string | null
  price_per_store: string
  monthly_uzs: string
  billing_from: string
  balance_available: string
  balance_pending: string
  unpaid_uzs: string
  overdue: boolean
}

interface Values {
  plan_key: string
  trial: boolean
  trial_until?: dayjs.Dayjs | null
  custom: boolean
  custom_price?: number | null
  billing_from?: dayjs.Dayjs | null
}

/** Тариф сети одной строкой с пометкой пробного периода. */
export function PlanCell({ b, plans }: { b: NetworkBilling; plans?: Plan[] }) {
  const trial = b.effective_plan_key !== b.plan_key
  const trialName = plans?.find((p) => p.key === b.effective_plan_key)?.name ?? b.effective_plan_key
  return (
    <Space size={4} wrap>
      <b>{b.plan_name}</b>
      {trial && b.trial_until && (
        <Tag color="gold">
          пробный «{trialName}» до {dayjs(b.trial_until).format('DD.MM')}
        </Tag>
      )}
    </Space>
  )
}

export function NetworkPlanModal({ networkId, onClose }: { networkId: string | null; onClose: () => void }) {
  const item = useItem<NetworkBilling>(networkId ? `/admin/billing/networks/${networkId}` : null)
  const plans = useList<Plan>(networkId ? '/admin/plans' : null)
  const [form] = Form.useForm<Values>()
  const b = item.data
  useEffect(() => {
    if (b)
      form.setFieldsValue({
        plan_key: b.plan_key,
        trial: !!b.trial_until,
        trial_until: b.trial_until ? dayjs(b.trial_until) : null,
        custom: b.custom_price_uzs !== null,
        custom_price: b.custom_price_uzs !== null ? Number(b.custom_price_uzs) : null,
        billing_from: dayjs(b.billing_from),
      })
  }, [b, form])
  const save = useAction(
    (v: Values) =>
      api.patch(`/admin/billing/networks/${networkId}`, {
        plan_key: v.plan_key,
        ...(v.trial && v.trial_until ? { trial_until: v.trial_until.format('YYYY-MM-DD') } : { clear_trial: true }),
        ...(v.custom ? { custom_price_uzs: String(v.custom_price ?? 0) } : { clear_custom_price: true }),
        billing_from: v.billing_from ? v.billing_from.startOf('month').format('YYYY-MM-DD') : undefined,
      }),
    { success: 'Тариф сети сохранён' },
  )
  const planKey = Form.useWatch('plan_key', form)
  const custom = Form.useWatch('custom', form)
  const customPrice = Form.useWatch('custom_price', form)
  const trial = Form.useWatch('trial', form)
  const trialUntil = Form.useWatch('trial_until', form)
  const trialActive = trial && trialUntil && !trialUntil.isBefore(dayjs(), 'day')
  const all = plans.data ?? []
  const plan = all.find((p) => p.key === planKey)
  const stores = b?.stores_count ?? 0
  const perStore = custom ? Number(customPrice ?? 0) : Number(plan?.price_uzs ?? 0)
  const listPrice = Number(plan?.price_uzs ?? 0) * stores

  return (
    <Modal
      open={networkId !== null}
      title={b ? `Тариф сети · ${b.network_name}` : 'Тариф сети'}
      okText="Сохранить"
      confirmLoading={save.isPending}
      onCancel={onClose}
      onOk={() => form.submit()}
      forceRender
    >
      {!b && <Spin style={{ display: 'block', margin: '32px auto' }} />}
      {b && (
        <Typography.Paragraph type="secondary">
          {b.kind === 'chain' ? 'Сеть магазинов' : 'Одиночный магазин'} · {stores} {stores === 1 ? 'магазин' : 'магазина(ов)'}
        </Typography.Paragraph>
      )}
      <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Form.Item
          name="plan_key"
          label="Тариф"
          rules={[{ required: true }]}
          extra="Можно назначить любой действующий тариф, в том числе скрытый. Минимум магазинов здесь не проверяется."
        >
          <Select
            options={all
              .filter((p) => p.is_active || p.key === b?.plan_key)
              .map((p) => ({
                value: p.key,
                label: (
                  <Space size={6}>
                    {p.name} — {planPrice(p)} за магазин
                    {!p.is_public && <Tag>скрытый</Tag>}
                    {!p.is_active && <Tag>в архиве</Tag>}
                  </Space>
                ),
              }))}
          />
        </Form.Item>
        <Row gutter={12} align="bottom">
          <Col span={10}>
            <Form.Item name="trial" valuePropName="checked">
              <Checkbox>Пробный период</Checkbox>
            </Form.Item>
          </Col>
          <Col span={14}>
            {trial && (
              <Form.Item name="trial_until" label="до" rules={[{ required: true }]}>
                <DatePicker format="DD.MM.YYYY" style={{ width: '100%' }} />
              </Form.Item>
            )}
          </Col>
        </Row>
        <Row gutter={12} align="bottom">
          <Col span={10}>
            <Form.Item name="custom" valuePropName="checked">
              <Checkbox>Своя цена</Checkbox>
            </Form.Item>
          </Col>
          <Col span={14}>
            {custom && (
              <Form.Item name="custom_price" label="сум за магазин в месяц" rules={[{ required: true }]}>
                <InputNumber min={0} step={1000} precision={0} style={{ width: '100%' }} />
              </Form.Item>
            )}
          </Col>
        </Row>
        <Form.Item name="billing_from" label="Платит с месяца" extra="До этого месяца подписка бесплатна.">
          <DatePicker picker="month" format="MM.YYYY" style={{ width: '100%' }} />
        </Form.Item>
        {b && plan && (
          <Alert
            type="info"
            showIcon
            message={
              <>
                В месяц: {stores} × {money(perStore)} сум{custom ? ' (своя цена)' : ''} = <b>{money(perStore * stores)} сум</b>
                {custom && ` · без своей цены — ${money(listPrice)} сум`}
                {trialActive && ' · пока идёт пробный период, подписка не начисляется'}
              </>
            }
          />
        )}
      </Form>
    </Modal>
  )
}
