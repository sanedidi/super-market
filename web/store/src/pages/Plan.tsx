// Тариф сети (макеты B1–B3, Figma «Тарифы магазинов»): «Tarif» — свой
// тариф, занятые лимиты и смена тарифа; закрытая функция с замком;
// окно «Лимит тарифа» на ошибки plan_feature / tariff_limit.
import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Alert, App, Button, Card, Col, Progress, Result, Row, Space, Tag, Typography } from 'antd'
import { CheckCircleFilled, ClockCircleOutlined, InfoCircleOutlined, LockOutlined } from '@ant-design/icons'
import { type ApiError, PageTitle, api, date, money, setPlanErrorHandler, tr, useAction } from '@sm/shared'
import { useStore } from '../ctx'
import type { MyPlan, PlanLimit, PlanView } from '../types'

const C = { blue: '#155EEF', blueBg: '#EFF4FF', green: '#12B76A', muted: '#667085', gray: '#D0D5DD', red: '#D92D20' }

/** Функции тарифа, которые закрывают страницы панели целиком. */
export const FEATURE_BY_PATH: Record<string, string> = {
  '/debts': 'debts',
  '/settings/debts': 'debts',
  '/reports/cash-flow': 'reports_pro',
  '/reports/profit-loss': 'reports_pro',
  '/reports/abc-xyz': 'abc_xyz',
  '/crowd': 'crowd',
  '/brand-ads': 'brand_ads',
}

const soum = (v: string | number) => `${money(v)} ${tr('сум', 'soʻm')}`

/** Первый по порядку открытый тариф, где функция есть. */
function needPlan(plan: MyPlan | undefined, feature: string): PlanView | undefined {
  return plan?.plans.find((p) => p.features.some((f) => f.key === feature && f.included))
}

function priceLine(p: PlanView) {
  const parts = [p.min_stores > 1 ? tr('за каждый магазин в месяц', 'har bir doʻkon uchun / oy') : tr('за магазин в месяц', 'doʻkon uchun / oy')]
  if (Number(p.order_commission) > 0) parts.push(tr(`${Number(p.order_commission)}% с онлайн-заказа`, `onlayn buyurtmadan ${Number(p.order_commission)}% komissiya`))
  else parts.push(tr('без комиссии', 'komissiyasiz'))
  if (p.min_stores > 1) parts.push(tr(`от ${p.min_stores} магазинов`, `${p.min_stores} ta doʻkondan`))
  return parts.join(' · ')
}

function limitsLine(p: PlanView) {
  const short: Record<string, [string, string]> = {
    stores: ['магазин', 'doʻkon'],
    registers: ['касс', 'kassa'],
    staff: ['сотрудн.', 'xodim'],
    couriers: ['курьер', 'kuryer'],
  }
  const parts = p.limits
    .filter((l) => short[l.key])
    .map((l) => (l.value === null ? tr(`${short[l.key][0]} без лимита`, `${short[l.key][1]} cheklovsiz`) : `${l.value} ${tr(short[l.key][0], short[l.key][1])}`))
  return parts.join(' · ')
}

// -------------------------------------------------------------- B1 · Tarif

export function PlanPage() {
  const { plan } = useStore()
  const { modal } = App.useApp()
  const choose = useAction((key: string) => api.post<MyPlan>('/store/plan', { plan: key }), { success: tr('Тариф изменён', 'Tarif oʻzgartirildi') })
  if (!plan) return <Card loading />
  const cur = plan.current
  const chosen = plan.plans.find((p) => p.key === plan.chosen.key)
  const chosenName = chosen?.name ?? tr(plan.chosen.name, plan.chosen.name_uz || plan.chosen.name)
  const confirm = (p: PlanView) =>
    modal.confirm({
      title: tr(`Перейти на тариф «${p.name}»?`, `«${p.name}» tarifiga oʻtilsinmi?`),
      content:
        Number(p.price_uzs) > 0
          ? tr(
              `${soum(Number(p.price_uzs) * Math.max(1, plan.stores_count))} в месяц войдут в ближайший счёт за подписку${plan.in_trial ? ' после пробного периода' : ''}. Функции меняются сразу.`,
              `Oyiga ${soum(Number(p.price_uzs) * Math.max(1, plan.stores_count))} obuna uchun eng yaqin hisobga qoʻshiladi${plan.in_trial ? ' (sinov davridan keyin)' : ''}. Funksiyalar darhol oʻzgaradi.`,
            )
          : tr('Закрытые функции скроются, но данные не удалятся — при возврате всё будет на месте.', 'Yopilgan funksiyalar yashiriladi, lekin maʼlumotlar oʻchmaydi — qaytsangiz, hammasi joyida boʻladi.'),
      okText: tr('Перейти', 'Oʻtish'),
      cancelText: tr('Отмена', 'Bekor qilish'),
      onOk: () => choose.mutateAsync(p.key),
    })

  return (
    <>
      <PageTitle title={tr('Тариф', 'Tarif')} />
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        {tr(
          'Ваш тариф, лимиты и другие тарифы. Тариф меняет владелец или сотрудник с правом на деньги.',
          'Tarifingiz, limitlar va boshqa tariflar. Tarifni doʻkon egasi yoki pul huquqi bor xodim oʻzgartiradi.',
        )}
      </Typography.Paragraph>

      {plan.in_trial && plan.trial_until && (
        <Alert
          type="warning"
          showIcon
          icon={<ClockCircleOutlined />}
          style={{ marginBottom: 16 }}
          message={<b>{tr(`Пробный период: тариф «${cur.name}» бесплатно до ${date(plan.trial_until)}`, `Sinov davri: «${cur.name}» tarifi ${date(plan.trial_until)} gacha bepul`)}</b>}
          description={tr(
            `Потом — тариф «${chosenName}». Выбрать тариф можно уже сейчас.`,
            `Keyin «${chosenName}» tarifiga oʻtasiz. Tarifni hozir tanlashingiz mumkin.`,
          )}
        />
      )}

      <Card style={{ marginBottom: 16 }}>
        <Row gutter={[40, 16]}>
          <Col xs={24} md={8}>
            <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
              {tr('ТЕКУЩИЙ ТАРИФ', 'HOZIRGI TARIF')}
            </Typography.Text>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, margin: '4px 0' }}>
              <span style={{ fontSize: 24, fontWeight: 800 }}>{cur.name}</span>
              {plan.in_trial && <Tag color="gold">{tr('пробный', 'sinov')}</Tag>}
            </div>
            <div style={{ fontWeight: 600 }}>
              {soum(plan.custom_price_uzs ?? cur.price_uzs)} · {priceLine(cur)}
            </div>
            {plan.in_trial && (
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {tr(`Выбранный тариф: «${chosenName}»`, `Tanlangan tarif: «${chosenName}»`)}
              </Typography.Text>
            )}
            {plan.custom_price_uzs !== null && (
              <div>
                <Tag color="blue">{tr('индивидуальная цена', 'individual narx')}</Tag>
              </div>
            )}
          </Col>
          <Col xs={24} md={16}>
            <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
              {tr('ЛИМИТЫ', 'LIMITLAR')}
            </Typography.Text>
            <Row gutter={[32, 12]} style={{ marginTop: 8 }}>
              {cur.limits
                .filter((l) => l.key !== 'ads' && !(l.used === undefined && l.value === null))
                .map((l) => (
                  <Col key={l.key} xs={24} sm={12}>
                    <LimitBar l={l} />
                  </Col>
                ))}
            </Row>
          </Col>
        </Row>
      </Card>

      <Space align="baseline" style={{ marginBottom: 12 }}>
        <Typography.Title level={4} style={{ margin: 0 }}>
          {tr('Тарифы', 'Tariflar')}
        </Typography.Title>
        <Typography.Text type="secondary">{tr('Цена — со следующего счёта, функции — сразу', 'Narx keyingi hisobdan, funksiyalar — darhol')}</Typography.Text>
      </Space>
      <Row gutter={[16, 16]}>
        {plan.plans.map((p) => (
          <Col key={p.key} xs={24} sm={12} xl={6}>
            <PlanCard p={p} plan={plan} onChoose={() => confirm(p)} busy={choose.isPending && choose.variables === p.key} />
          </Col>
        ))}
      </Row>
    </>
  )
}

function LimitBar({ l }: { l: PlanLimit }) {
  const used = l.used
  const full = l.value !== null && used !== undefined && used >= l.value
  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
        <span style={{ fontWeight: 600 }}>{l.name}</span>
        <b style={{ color: full ? C.red : undefined }}>
          {used === undefined
            ? l.value === null
              ? tr('без лимита', 'cheklovsiz')
              : tr(`до ${l.value}`, `${l.value} tagacha`)
            : l.value === null
              ? `${used} · ${tr('без лимита', 'cheklovsiz')}`
              : `${used} / ${l.value}`}
        </b>
      </div>
      <Progress
        percent={l.value === null ? 15 : used === undefined ? 0 : l.value === 0 ? 100 : Math.min(100, (used / l.value) * 100)}
        showInfo={false}
        size="small"
        strokeColor={full ? C.red : l.value === null ? C.gray : C.blue}
      />
    </div>
  )
}

const SHOWN_FEATURES = ['debts', 'promotions', 'invoice_scans', 'reports_pro', 'abc_xyz', 'crowd', 'showcase_custom', 'showcase_per_store', 'brand_ads']

function PlanCard({ p, plan, onChoose, busy }: { p: PlanView; plan: MyPlan; onChoose: () => void; busy: boolean }) {
  const isChosen = p.key === plan.chosen.key
  const tooFew = plan.stores_count < p.min_stores
  return (
    <Card
      style={{ height: '100%', borderColor: p.recommended ? C.blue : undefined, borderWidth: p.recommended ? 2 : 1 }}
      styles={{ body: { padding: 18, display: 'flex', flexDirection: 'column', gap: 12, height: '100%' } }}
    >
      <Space size={6} wrap>
        <span style={{ fontSize: 17, fontWeight: 800 }}>{p.name}</span>
        {p.recommended && <Tag color="blue">{tr('Рекомендуем', 'Tavsiya etamiz')}</Tag>}
        {isChosen && <Tag>{tr('Выбран', 'Tanlangan')}</Tag>}
      </Space>
      <div>
        <div style={{ fontSize: 22, fontWeight: 800 }}>{soum(p.price_uzs)}</div>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {priceLine(p)}
        </Typography.Text>
      </div>
      {p.description && <Typography.Text style={{ fontSize: 12 }}>{p.description}</Typography.Text>}
      <div style={{ borderTop: '1px solid #EAECF0', paddingTop: 12, display: 'flex', flexDirection: 'column', gap: 7 }}>
        {p.features
          .filter((f) => SHOWN_FEATURES.includes(f.key))
          .map((f) => (
            <div key={f.key} style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 12 }} title={f.hint}>
              {f.included ? <CheckCircleFilled style={{ color: C.green }} /> : <LockOutlined style={{ color: C.gray }} />}
              <span style={{ fontWeight: f.included ? 600 : 400, color: f.included ? undefined : C.muted }}>{f.name}</span>
            </div>
          ))}
      </div>
      <Typography.Text type="secondary" strong style={{ fontSize: 12 }}>
        {limitsLine(p)}
      </Typography.Text>
      <div style={{ marginTop: 'auto' }}>
        {isChosen ? (
          <Button block disabled>
            {tr('Ваш тариф', 'Hozirgi tarifingiz')}
          </Button>
        ) : tooFew ? (
          <Button block disabled icon={<InfoCircleOutlined />}>
            {tr(`От ${p.min_stores} магазинов · у вас ${plan.stores_count}`, `${p.min_stores} ta doʻkondan · sizda ${plan.stores_count} ta`)}
          </Button>
        ) : (
          <Button block type={p.recommended ? 'primary' : 'default'} disabled={!plan.can_change} loading={busy} onClick={onChoose}>
            {tr(`Перейти на «${p.name}»`, `${p.name} tarifiga oʻtish`)}
          </Button>
        )}
      </div>
    </Card>
  )
}

// ------------------------------------------------- B2 · закрытая функция

export function LockedFeature({ feature }: { feature: string }) {
  const { plan } = useStore()
  const nav = useNavigate()
  const f = plan?.current.features.find((x) => x.key === feature)
  const need = needPlan(plan, feature)
  return (
    <>
      <PageTitle title={f?.name ?? tr('Функция недоступна', 'Funksiya mavjud emas')} />
      <Card>
        <Result
          icon={
            <span style={{ display: 'inline-grid', placeItems: 'center', width: 72, height: 72, borderRadius: 36, background: C.blueBg }}>
              <LockOutlined style={{ fontSize: 32, color: C.blue }} />
            </span>
          }
          title={tr(`«${f?.name ?? feature}» нет на тарифе «${plan?.current.name ?? ''}»`, `«${f?.name ?? feature}» «${plan?.current.name ?? ''}» tarifida yoʻq`)}
          subTitle={
            <>
              {f?.hint}
              {need &&
                tr(
                  ` — с тарифа «${need.name}», ${soum(need.price_uzs)} в месяц.`,
                  ` — «${need.name}» tarifidan boshlab, oyiga ${soum(need.price_uzs)}.`,
                )}
              <div style={{ marginTop: 8, fontSize: 12 }}>
                {tr('Данные не удаляются — включите тариф, и всё будет на месте.', 'Maʼlumotlar oʻchmaydi — tarifni yoqsangiz, hammasi joyida boʻladi.')}
              </div>
            </>
          }
          extra={
            <Space>
              <Button type="primary" onClick={() => nav('/plan')}>
                {need ? tr(`Перейти на «${need.name}»`, `${need.name} tarifiga oʻtish`) : tr('Тарифы', 'Tariflar')}
              </Button>
              <Button onClick={() => nav('/plan')}>{tr('Сравнить тарифы', 'Tariflarni solishtirish')}</Button>
            </Space>
          }
        />
      </Card>
    </>
  )
}

// ---------------------------------------------- B3 · окно «Лимит тарифа»

/** Ловит ошибки тарифа из действий панели и показывает окно с переходом в «Tarif». */
export function PlanErrorHost() {
  const { modal } = App.useApp()
  const nav = useNavigate()
  const { plan } = useStore()
  useEffect(() => {
    setPlanErrorHandler((e: ApiError) => {
      const d = e.details as Record<string, unknown>
      const needName = (d.need_plan_name as string) || undefined
      const title =
        e.code === 'tariff_limit'
          ? tr(`Лимит: ${String(d.limit_name ?? d.feature ?? '')}`, `Limit: ${String(d.limit_name ?? d.feature ?? '')}`)
          : e.code === 'plan_min_stores'
            ? tr('Тариф для сетей побольше', 'Kattaroq tarmoqlar uchun tarif')
            : tr('Нет на вашем тарифе', 'Tarifingizda yoʻq')
      modal.confirm({
        icon: <LockOutlined style={{ color: '#B54708' }} />,
        title,
        content: (
          <>
            <p style={{ margin: 0 }}>{e.message}</p>
            {e.code === 'tariff_limit' && d.limit !== undefined && (
              <p style={{ margin: '8px 0 0' }}>
                <b>
                  {String(d.used)} / {String(d.limit)}
                </b>
              </p>
            )}
          </>
        ),
        okText: needName ? tr(`Перейти на «${needName}»`, `${needName} tarifiga oʻtish`) : tr('Тарифы', 'Tariflar'),
        cancelText: tr('Закрыть', 'Yopish'),
        onOk: () => nav('/plan'),
      })
    })
    return () => setPlanErrorHandler(null)
  }, [modal, nav, plan])
  return null
}
