// «Витрина приложения»: сеть настраивает свою главную в приложении поверх
// шаблона Super Market в пределах тарифа «Старт / Бизнес / Про» (Figma
// «Витрина · монетизация»).
import { useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { App, Button, Drawer, Modal, Select, Space } from 'antd'
import { BarChartOutlined, CheckOutlined, LockFilled, PictureFilled, ShopOutlined, TrophyFilled } from '@ant-design/icons'
import { ApiError, HomeEditor, HomeStatsPanel, api, errorText, money, type HomeBlock, type LayoutEditor } from '@sm/shared'

interface Plan {
  key: 'start' | 'business' | 'pro'
  name: string
  price_uzs: string
  custom: boolean
  banners: number | null
  shelves: number | null
  promos: number | null
  manual: boolean
  schedule: boolean
  per_store: boolean
  stats: 'none' | 'basic' | 'full'
  recommended: boolean
}

interface ShowcaseData {
  layout: LayoutEditor
  plan: { chosen: Plan; effective: Plan; trial_plan: string; trial_until: string | null; in_trial: boolean }
  plans: Plan[]
  usage: { banners: number; shelves: number; promos: number }
  template_ids: string[]
  pinned_ids: string[]
  can_buy: boolean
  stores: { id: string; name: string; online: boolean }[]
}

interface LimitInfo {
  feature: string
  limit?: number
  used?: number
}

const BASE = '/store/home'

function ownCounts(blocks: HomeBlock[], template: string[]) {
  const own = blocks.filter((b) => !b.pinned && !template.includes(b.id))
  return {
    shelves: own.filter((b) => b.type === 'shelf').length,
    promos: own.filter((b) => (b.type === 'promo' && b.kind === 'custom') || (b.type === 'banners' && b.size === 'strip')).length,
  }
}

const unlimited = (v: number | null) => v === null

function Meter({ label, used, limit }: { label: string; used: number; limit: number | null }) {
  const full = !unlimited(limit) && used >= (limit ?? 0)
  const pct = unlimited(limit) ? Math.min(100, used * 10) : limit ? Math.min(100, (used / limit) * 100) : 100
  return (
    <div className={`smh-meter${full ? ' full' : ''}`}>
      <div className="smh-meter-label">{label}</div>
      <div className="smh-meter-row">
        <span className="smh-meter-bar">
          <i style={{ width: `${pct}%` }} />
        </span>
        {unlimited(limit) ? `${used} · без лимита` : `${used} из ${limit}`}
      </div>
    </div>
  )
}

function PlanBar({ data, blocks, onCompare }: { data: ShowcaseData; blocks: HomeBlock[]; onCompare: () => void }) {
  const p = data.plan.effective
  const c = ownCounts(blocks, data.template_ids)
  return (
    <div className="smh-plan-bar">
      <div className="smh-plan-name">
        <TrophyFilled />
        <span>
          Тариф «{p.name}»
          {data.plan.in_trial && data.plan.trial_until && <small>пробный до {new Date(data.plan.trial_until).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })}</small>}
        </span>
      </div>
      {p.custom ? (
        <>
          <Meter label="Фото-баннеры" used={data.usage.banners} limit={p.banners} />
          <Meter label="Свои полки" used={c.shelves} limit={p.shelves} />
          <Meter label="Промо-полоска" used={c.promos} limit={p.promos} />
        </>
      ) : (
        <span className="smh-meter-label">На тарифе «Старт» покупатели видят автоматическую витрину Super Market. Своя витрина — с тарифа «Бизнес».</span>
      )}
      <a onClick={onCompare}>Сравнить тарифы</a>
    </div>
  )
}

const FEATURE_TEXT: Record<string, { title: string; text: (i: LimitInfo, p: Plan) => string; icon?: ReactNode }> = {
  banners: {
    title: 'Лимит баннеров на тарифе',
    text: (i) => `У вас уже ${i.used ?? i.limit} из ${i.limit} своих баннеров. Чтобы добавить новый — выключите один из текущих или перейдите на тариф выше: баннеры без лимита, расписание и полная статистика.`,
    icon: <PictureFilled />,
  },
  shelves: {
    title: 'Лимит полок на тарифе',
    text: (i) => `На главной уже ${i.used ?? i.limit} своих полки из ${i.limit}. Уберите одну или перейдите на тариф выше — там полок без лимита.`,
  },
  promos: {
    title: 'Лимит промо-полосок на тарифе',
    text: (i) => `Своих промо-полосок можно ${i.limit}. Уберите лишнюю или перейдите на тариф выше.`,
  },
  manual: { title: 'Подборка «вручную» не входит в тариф', text: () => 'Собирайте полки из своих товаров в нужном порядке — с тарифа «Бизнес».' },
  schedule: { title: 'Расписание блоков — в тарифе «Про»', text: () => 'Блок сам включится и выключится по датам: акции к праздникам без ручных правок.' },
  per_store: { title: 'Своя витрина у каждого магазина — в тарифе «Про»', text: () => 'По умолчанию у всех магазинов сети одна витрина. На «Про» можно сделать отдельную для любого магазина.' },
  custom: { title: 'Своя витрина — с тарифа «Бизнес»', text: () => 'Порядок блоков, свои полки, баннеры и промо-полоска. Сейчас покупатели видят автоматическую витрину Super Market.' },
}

function nextPlan(data: ShowcaseData, feature: string): Plan | undefined {
  const cur = data.plan.effective
  const order = data.plans
  const need = feature === 'schedule' || feature === 'per_store' || cur.key === 'business' ? 'pro' : 'business'
  return order.find((p) => p.key === need) ?? order[order.length - 1]
}

function LimitModal({ info, data, onClose, onPlans }: { info: LimitInfo | null; data?: ShowcaseData; onClose: () => void; onPlans: (key?: string) => void }) {
  if (!info || !data) return null
  const f = FEATURE_TEXT[info.feature] ?? FEATURE_TEXT.custom
  const cur = data.plan.effective
  if (info.feature === 'banners' || info.feature === 'shelves' || info.feature === 'promos') {
    const lim = info.limit ?? cur[info.feature] ?? 0
    info = { ...info, limit: lim, used: info.used ?? Math.max(data.usage[info.feature], lim) }
  }
  const target = nextPlan(data, info.feature)
  const withPlan = ['banners', 'shelves', 'promos'].includes(info.feature)
  return (
    <Modal open onCancel={onClose} footer={null} width={480} centered>
      <div className="smh-limit">
        <span className="smh-block-icon">{f.icon ?? <LockFilled />}</span>
        <h3>{withPlan ? `${f.title} «${cur.name}»` : f.title}</h3>
        <p>{f.text(info, cur)}</p>
        {target && (
          <div className="smh-limit-plan">
            <div>
              <b>Тариф «{target.name}»</b>
              <span>{Number(target.price_uzs) > 0 ? `${money(target.price_uzs)} сум / мес` : 'бесплатно'}</span>
            </div>
            <TrophyFilled />
          </div>
        )}
        <div style={{ display: 'flex', gap: 12 }}>
          <Button size="large" block onClick={onClose}>
            {withPlan ? 'Убрать старый' : 'Понятно'}
          </Button>
          {target && (
            <Button size="large" block type="primary" danger onClick={() => onPlans(target.key)}>
              Перейти на «{target.name}»
            </Button>
          )}
        </div>
      </div>
    </Modal>
  )
}

function planLines(p: Plan): string[] {
  const lim = (v: number | null, one: string) => (v === null ? `${one} без лимита` : v === 0 ? '' : `${one}: ${v}`)
  return [
    'Автоматическая витрина (хиты, скидки, категории)',
    p.custom ? 'Свой порядок блоков' : '',
    lim(p.banners, 'Свои фото-баннеры'),
    lim(p.shelves, 'Свои полки товаров'),
    p.manual ? 'Подборка «вручную»' : '',
    lim(p.promos, 'Промо-полоска'),
    p.schedule ? 'Расписание блоков' : '',
    p.stats === 'full' ? 'Полная статистика' : p.stats === 'basic' ? 'Базовая статистика' : '',
    p.per_store ? 'Разные витрины магазинов сети' : '',
  ].filter(Boolean)
}

function PlansModal({ open, data, highlight, onClose }: { open: boolean; data?: ShowcaseData; highlight?: string; onClose: () => void }) {
  const { message, modal } = App.useApp()
  const qc = useQueryClient()
  const [busy, setBusy] = useState<string>()
  const navigate = useNavigate()
  if (!data) return null
  const choose = (p: Plan) =>
    modal.confirm({
      title: `Перейти на тариф «${p.name}»?`,
      content:
        Number(p.price_uzs) > 0
          ? `${money(p.price_uzs)} сум в месяц войдут в ближайший счёт за подписку${data.plan.in_trial ? ' (после пробного периода)' : ''}. Отменить можно в любой момент.`
          : 'Свои блоки скроются, но не удалятся: при возврате на платный тариф всё вернётся как было.',
      okText: 'Перейти',
      cancelText: 'Отмена',
      onOk: async () => {
        setBusy(p.key)
        try {
          await api.post('/store/showcase/plan', { plan: p.key })
          await qc.invalidateQueries({ queryKey: [BASE] })
          onClose()
          if (Number(p.price_uzs) > 0) {
            modal.success({
              title: `Тариф «${p.name}» подключён`,
              content: `${money(p.price_uzs)} сум в месяц добавятся в ${data.plan.in_trial ? 'первый счёт после пробного периода' : 'ближайший счёт за подписку'}. Оплатить счёт можно с баланса платформы в разделе «Баланс и подписка». Доля с рекламы брендов уменьшает этот счёт.`,
              okText: 'Перейти к оплате',
              onOk: () => navigate('/balance?tab=billing'),
              closable: true,
            })
          } else message.success(`Тариф «${p.name}» подключён`)
        } catch (e) {
          message.error(errorText(e))
        } finally {
          setBusy(undefined)
        }
      },
    })
  return (
    <Modal open={open} onCancel={onClose} footer={null} width={860} title="Тарифы витрины">
      <div className="smh-plans">
        {data.plans.map((p) => {
          const current = p.key === data.plan.chosen.key
          return (
            <div key={p.key} className={`smh-plan${p.key === highlight || (!highlight && p.recommended) ? ' rec' : ''}${current ? ' cur' : ''}`}>
              {p.recommended && <span className="smh-plan-badge">Рекомендуем</span>}
              <h4>{p.name}</h4>
              <div className="smh-field-hint">{Number(p.price_uzs) > 0 ? `${money(p.price_uzs)} сум / мес` : 'бесплатно'}</div>
              <ul>
                {planLines(p).map((x) => (
                  <li key={x}>{x}</li>
                ))}
              </ul>
              {current ? (
                <Button block disabled icon={<CheckOutlined />}>
                  {data.plan.in_trial ? `Ваш тариф · пробный «${data.plan.effective.name}»` : 'Ваш тариф'}
                </Button>
              ) : data.can_buy ? (
                <Button block type={p.key === highlight ? 'primary' : 'default'} danger={p.key === highlight} loading={busy === p.key} onClick={() => choose(p)}>
                  Перейти на «{p.name}»
                </Button>
              ) : (
                <div className="smh-field-hint">Сменить тариф может владелец сети</div>
              )}
            </div>
          )
        })}
      </div>
      {data.plan.trial_until && (
        <div className="smh-field-hint" style={{ marginTop: 12 }}>
          {data.plan.in_trial
            ? `Пробный период до ${new Date(data.plan.trial_until).toLocaleDateString('ru-RU')}. Потом, если не перейти на платный тариф, витрина вернётся к «Старт»: свои баннеры и полки скроются, но не удалятся.`
            : 'Пробный период закончился.'}
        </div>
      )}
    </Modal>
  )
}

export function ShowcasePage() {
  const [storeId, setStoreId] = useState<string>('')
  const [reload, setReload] = useState(0)
  const [stats, setStats] = useState(false)
  const { message, modal } = App.useApp()
  const qc = useQueryClient()
  const [limit, setLimit] = useState<LimitInfo | null>(null)
  const [plans, setPlans] = useState<{ open: boolean; highlight?: string }>({ open: false })
  const params = { store_id: storeId || undefined }
  // Тот же ключ, что у редактора: данные общие.
  const q = useQuery({ queryKey: [BASE, params], queryFn: () => api.get<ShowcaseData>(BASE, params) })
  const data = q.data
  const p = data?.plan.effective

  const onError = (e: unknown) => {
    if (e instanceof ApiError && e.code === 'tariff_limit') {
      setLimit({ feature: String(e.details.feature ?? 'custom'), limit: e.details.limit as number, used: e.details.used as number })
      return true
    }
    return false
  }

  return (
    <>
      <HomeEditor
        key={`${storeId || 'network'}-${reload}`}
        extraActions={(l) =>
          l.version > 0 ? (
            <div className="smh-reset">
              {l.store_id ? `У магазина «${l.store_name}» своя витрина.` : 'У сети своя витрина.'}
              <Button
                size="small"
                onClick={() =>
                  modal.confirm({
                    title: l.store_id ? 'Вернуть витрину сети?' : 'Вернуть витрину Super Market?',
                    content: 'Ваши блоки и их версии удалятся. Свои баннеры останутся в списке баннеров.',
                    okText: 'Вернуть',
                    okButtonProps: { danger: true },
                    cancelText: 'Отмена',
                    onOk: async () => {
                      try {
                        await api.del(`${BASE}${storeId ? `?store_id=${storeId}` : ''}`)
                        await qc.invalidateQueries({ queryKey: [BASE] })
                        setReload((n) => n + 1)
                      } catch (e) {
                        message.error(errorText(e))
                      }
                    },
                  })
                }
              >
                {l.store_id ? 'Вернуть витрину сети' : 'Вернуть витрину Super Market'}
              </Button>
            </div>
          ) : null
        }
        title="Витрина приложения"
        subtitle="Так покупатели видят ваш магазин на главной. Блоки Super Market закреплены и всегда на месте."
        base={BASE}
        params={params}
        storesPath="/store/home/stores"
        previewPath="/store/home/preview"
        storeParam="store_id"
        paths={{ products: '/store/products', categories: '/store/catalog/categories', banners: '/store/banners' }}
        unwrap={(raw) => (raw as ShowcaseData).layout}
        top={(raw, blocks) => <PlanBar data={raw as ShowcaseData} blocks={blocks} onCompare={() => setPlans({ open: true })} />}
        locked={(b) => !!b.pinned}
        features={{ schedule: p?.schedule ?? false, manual: p?.manual ?? false }}
        onUpgrade={(feature) => setLimit({ feature })}
        onError={onError}
        addInfo={(t, blocks, raw) => {
          const d = raw as ShowcaseData
          const plan = d.plan.effective
          if (!plan.custom) return { lock: '«Бизнес»', feature: 'custom' }
          const c = ownCounts(blocks, d.template_ids)
          const left = (used: number, lim: number | null, what: string, feature: string) =>
            lim === null
              ? { hint: `${what}: без лимита` }
              : used >= lim
                ? { lock: '«Про»', hint: `Лимит ${lim} из ${lim} — уже все`, feature }
                : { hint: `Осталось ${lim - used} из ${lim}` }
          switch (t) {
            case 'shelf':
              return left(c.shelves, plan.shelves, 'Свои полки', 'shelves')
            case 'scheduled':
              return plan.schedule ? left(c.shelves, plan.shelves, 'Свои полки', 'shelves') : { lock: '«Про»', hint: 'Полка сама включится и выключится по датам', feature: 'schedule' }
            case 'promo':
              return left(c.promos, plan.promos, 'Промо-полоски', 'promos')
            case 'banners':
              return plan.banners === 0 ? { lock: '«Бизнес»', feature: 'banners' } : { hint: `Свои баннеры: ${d.usage.banners}${plan.banners === null ? '' : ` из ${plan.banners}`}` }
            default:
              return blocks.some((b) => b.type === t) ? { hint: 'Уже на главной' } : undefined
          }
        }}
        scope={
          <Space>
          <Button size="large" icon={<BarChartOutlined />} onClick={() => setStats(true)}>
            Статистика
          </Button>
          <Select
            size="large"
            value={storeId}
            style={{ width: 260 }}
            suffixIcon={<ShopOutlined />}
            onChange={(v: string) => {
              if (v && p && !p.per_store) {
                setLimit({ feature: 'per_store' })
                return
              }
              setStoreId(v)
            }}
            options={[
              { value: '', label: 'Все магазины сети' },
              ...(data?.stores ?? []).map((s) => ({
                value: s.id,
                label: (
                  <span>
                    {p && !p.per_store && <LockFilled style={{ color: '#98a2b3', marginRight: 6 }} />}
                    {s.name}
                  </span>
                ),
              })),
            ]}
          />
          </Space>
        }
      />
      <Drawer open={stats} onClose={() => setStats(false)} width={980} title={null}>
        <HomeStatsPanel
          path="/store/home/stats"
          params={{ store_id: storeId || undefined }}
          subtitle={storeId ? data?.stores.find((s) => s.id === storeId)?.name : 'все магазины сети'}
          onUpgrade={() => {
            setStats(false)
            setPlans({ open: true, highlight: p?.key === 'business' ? 'pro' : 'business' })
          }}
        />
      </Drawer>
      <LimitModal
        info={limit}
        data={data}
        onClose={() => setLimit(null)}
        onPlans={(key) => {
          setLimit(null)
          setPlans({ open: true, highlight: key })
        }}
      />
      <PlansModal open={plans.open} highlight={plans.highlight} data={data} onClose={() => setPlans({ open: false })} />
    </>
  )
}
