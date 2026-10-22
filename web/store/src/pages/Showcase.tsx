// «Витрина приложения»: сеть настраивает свою главную в приложении поверх
// шаблона Super Market в пределах своего тарифа (Figma «Витрина ·
// монетизация»). Тарифы и что в них входит настраивает супер-админ —
// названия тарифов здесь не зашиты, «на каком тарифе есть» считается по списку.
import { useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { App, Button, Drawer, Modal, Select, Space } from 'antd'
import { BarChartOutlined, CheckOutlined, LockFilled, PictureFilled, ShopOutlined, TrophyFilled } from '@ant-design/icons'
import dayjs from 'dayjs'
import { ApiError, HomeEditor, HomeStatsPanel, api, errorText, money, tr, type HomeBlock, type LayoutEditor } from '@sm/shared'

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
        {unlimited(limit) ? `${used} · ${tr('без лимита', 'cheklovsiz')}` : tr(`${used} из ${limit}`, `${used} / ${limit}`)}
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
          {tr(`Тариф «${p.name}»`, `«${p.name}» tarifi`)}
          {data.plan.in_trial && data.plan.trial_until && (
            <small>
              {tr(
                `пробный до ${dayjs(data.plan.trial_until).format('D MMMM')}`,
                `${dayjs(data.plan.trial_until).format('D MMMM')} gacha sinov`,
              )}
            </small>
          )}
        </span>
      </div>
      {p.custom ? (
        <>
          <Meter label={tr('Фото-баннеры', 'Foto-bannerlar')} used={data.usage.banners} limit={p.banners} />
          <Meter label={tr('Свои полки', 'Oʻz javonlaringiz')} used={c.shelves} limit={p.shelves} />
          <Meter label={tr('Промо-полоска', 'Promo-chiziq')} used={c.promos} limit={p.promos} />
        </>
      ) : (
        <span className="smh-meter-label">
          {tr(
            'На вашем тарифе покупатели видят автоматическую витрину Super Market. Своя витрина — на тарифе выше.',
            'Tarifingizda xaridorlar Super Market avtomatik vitrinasini koʻradi. Oʻz vitrinangiz — yuqoriroq tarifda.',
          )}
        </span>
      )}
      <a onClick={onCompare}>{tr('Сравнить тарифы', 'Tariflarni solishtirish')}</a>
    </div>
  )
}

const FEATURE_TEXT: Record<string, { title: string; text: (i: LimitInfo, p: Plan) => string; icon?: ReactNode }> = {
  banners: {
    title: tr('Лимит баннеров на тарифе', 'Tarifdagi bannerlar cheklovi'),
    text: (i) =>
      tr(
        `У вас уже ${i.used ?? i.limit} из ${i.limit} своих баннеров. Чтобы добавить новый — выключите один из текущих или перейдите на тариф выше: баннеры без лимита, расписание и полная статистика.`,
        `Sizda allaqachon ${i.limit} ta bannerdan ${i.used ?? i.limit} tasi bor. Yangisini qoʻshish uchun mavjudlaridan birini oʻchiring yoki yuqoriroq tarifga oʻting: cheklovsiz bannerlar, jadval va toʻliq statistika.`,
      ),
    icon: <PictureFilled />,
  },
  shelves: {
    title: tr('Лимит полок на тарифе', 'Tarifdagi javonlar cheklovi'),
    text: (i) =>
      tr(
        `На главной уже ${i.used ?? i.limit} своих полки из ${i.limit}. Уберите одну или перейдите на тариф выше — там полок без лимита.`,
        `Bosh sahifada allaqachon ${i.limit} ta javondan ${i.used ?? i.limit} tasi bor. Bittasini olib tashlang yoki yuqoriroq tarifga oʻting — u yerda javonlar cheklovsiz.`,
      ),
  },
  promos: {
    title: tr('Лимит промо-полосок на тарифе', 'Tarifdagi promo-chiziqlar cheklovi'),
    text: (i) =>
      tr(
        `Своих промо-полосок можно ${i.limit}. Уберите лишнюю или перейдите на тариф выше.`,
        `Oʻz promo-chiziqlaringiz ${i.limit} tagacha boʻlishi mumkin. Ortiqchasini olib tashlang yoki yuqoriroq tarifga oʻting.`,
      ),
  },
  manual: {
    title: tr('Подборка «вручную» не входит в тариф', '«Qoʻlda» tanlash tarifga kirmaydi'),
    text: () => tr('Собирайте полки из своих товаров в нужном порядке.', 'Javonlarni oʻz mahsulotlaringizdan kerakli tartibda tuzing.'),
  },
  schedule: {
    title: tr('Расписание блоков не входит в тариф', 'Bloklar jadvali tarifga kirmaydi'),
    text: () => tr('Блок сам включится и выключится по датам: акции к праздникам без ручных правок.', 'Blok sanalar boʻyicha oʻzi yoqiladi va oʻchadi: bayram aksiyalari qoʻlda tahrirlashsiz.'),
  },
  per_store: {
    title: tr('Своя витрина у каждого магазина не входит в тариф', 'Har bir doʻkon uchun alohida vitrina tarifga kirmaydi'),
    text: () =>
      tr(
        'По умолчанию у всех магазинов сети одна витрина. На тарифе выше можно сделать отдельную для любого магазина.',
        'Odatda tarmoqning barcha doʻkonlarida bitta vitrina boʻladi. Yuqoriroq tarifda istalgan doʻkon uchun alohida vitrina qilish mumkin.',
      ),
  },
  custom: {
    title: tr('Своя витрина не входит в тариф', 'Oʻz vitrinangiz tarifga kirmaydi'),
    text: () =>
      tr(
        'Порядок блоков, свои полки, баннеры и промо-полоска. Сейчас покупатели видят автоматическую витрину Super Market.',
        'Bloklar tartibi, oʻz javonlaringiz, bannerlar va promo-chiziq. Hozir xaridorlar Super Market avtomatik vitrinasini koʻradi.',
      ),
  },
}

/** Первый по порядку тариф выше текущего, где есть функция (или лимит больше used). */
function needPlan(data: ShowcaseData, feature: string, used = 0): Plan | undefined {
  const cur = data.plan.effective
  const ok = (p: Plan) => {
    switch (feature) {
      case 'banners':
      case 'shelves':
      case 'promos':
        return p.custom && (p[feature] === null || (p[feature] as number) > used)
      case 'stats':
        return p.stats !== 'none'
      case 'stats_full':
        return p.stats === 'full'
      case 'manual':
      case 'schedule':
      case 'per_store':
      case 'custom':
        return !!p[feature]
      default:
        return p.custom
    }
  }
  return data.plans.find((p) => p.key !== cur.key && ok(p))
}

function nextPlan(data: ShowcaseData, feature: string, used = 0): Plan | undefined {
  return needPlan(data, feature, used) ?? data.plans[data.plans.length - 1]
}

/** «Тариф X» для замка в списке блоков. */
function lockName(data: ShowcaseData, feature: string, used = 0) {
  const p = needPlan(data, feature, used)
  return p ? `«${p.name}»` : tr('тариф выше', 'yuqoriroq tarif')
}

function LimitModal({ info, data, onClose, onPlans }: { info: LimitInfo | null; data?: ShowcaseData; onClose: () => void; onPlans: (key?: string) => void }) {
  if (!info || !data) return null
  const f = FEATURE_TEXT[info.feature] ?? FEATURE_TEXT.custom
  const cur = data.plan.effective
  if (info.feature === 'banners' || info.feature === 'shelves' || info.feature === 'promos') {
    const lim = info.limit ?? cur[info.feature] ?? 0
    info = { ...info, limit: lim, used: info.used ?? Math.max(data.usage[info.feature], lim) }
  }
  const target = nextPlan(data, info.feature, info.used ?? 0)
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
              <b>{tr(`Тариф «${target.name}»`, `«${target.name}» tarifi`)}</b>
              <span>{Number(target.price_uzs) > 0 ? `${money(target.price_uzs)} ${tr('сум / мес', 'soʻm / oy')}` : tr('бесплатно', 'bepul')}</span>
            </div>
            <TrophyFilled />
          </div>
        )}
        <div style={{ display: 'flex', gap: 12 }}>
          <Button size="large" block onClick={onClose}>
            {withPlan ? tr('Убрать старый', 'Eskisini olib tashlash') : tr('Понятно', 'Tushunarli')}
          </Button>
          {target && (
            <Button size="large" block type="primary" danger onClick={() => onPlans(target.key)}>
              {tr(`Перейти на «${target.name}»`, `«${target.name}» tarifiga oʻtish`)}
            </Button>
          )}
        </div>
      </div>
    </Modal>
  )
}

function planLines(p: Plan): string[] {
  const lim = (v: number | null, one: string) => (v === null ? `${one} ${tr('без лимита', 'cheklovsiz')}` : v === 0 ? '' : `${one}: ${v}`)
  return [
    tr('Автоматическая витрина (хиты, скидки, категории)', 'Avtomatik vitrina (xitlar, chegirmalar, kategoriyalar)'),
    p.custom ? tr('Свой порядок блоков', 'Bloklarning oʻz tartibi') : '',
    lim(p.banners, tr('Свои фото-баннеры', 'Oʻz foto-bannerlaringiz')),
    lim(p.shelves, tr('Свои полки товаров', 'Oʻz mahsulot javonlaringiz')),
    p.manual ? tr('Подборка «вручную»', '«Qoʻlda» tanlash') : '',
    lim(p.promos, tr('Промо-полоска', 'Promo-chiziq')),
    p.schedule ? tr('Расписание блоков', 'Bloklar jadvali') : '',
    p.stats === 'full' ? tr('Полная статистика', 'Toʻliq statistika') : p.stats === 'basic' ? tr('Базовая статистика', 'Asosiy statistika') : '',
    p.per_store ? tr('Разные витрины магазинов сети', 'Tarmoq doʻkonlari uchun turli vitrinalar') : '',
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
      title: tr(`Перейти на тариф «${p.name}»?`, `«${p.name}» tarifiga oʻtilsinmi?`),
      content:
        Number(p.price_uzs) > 0
          ? tr(
              `${money(p.price_uzs)} сум в месяц войдут в ближайший счёт за подписку${data.plan.in_trial ? ' (после пробного периода)' : ''}. Отменить можно в любой момент.`,
              `Oyiga ${money(p.price_uzs)} soʻm obuna uchun eng yaqin hisobga qoʻshiladi${data.plan.in_trial ? ' (sinov muddatidan keyin)' : ''}. Istalgan vaqtda bekor qilish mumkin.`,
            )
          : tr(
              'Свои блоки скроются, но не удалятся: при возврате на платный тариф всё вернётся как было.',
              'Oʻz bloklaringiz yashiriladi, lekin oʻchirilmaydi: pullik tarifga qaytsangiz, hammasi avvalgidek tiklanadi.',
            ),
      okText: tr('Перейти', 'Oʻtish'),
      cancelText: tr('Отмена', 'Bekor qilish'),
      onOk: async () => {
        setBusy(p.key)
        try {
          await api.post('/store/showcase/plan', { plan: p.key })
          await qc.invalidateQueries({ queryKey: [BASE] })
          onClose()
          if (Number(p.price_uzs) > 0) {
            modal.success({
              title: tr(`Тариф «${p.name}» подключён`, `«${p.name}» tarifi ulandi`),
              content: tr(
                `${money(p.price_uzs)} сум в месяц добавятся в ${data.plan.in_trial ? 'первый счёт после пробного периода' : 'ближайший счёт за подписку'}. Оплатить счёт можно с баланса платформы в разделе «Баланс и подписка». Доля с рекламы брендов уменьшает этот счёт.`,
                `Oyiga ${money(p.price_uzs)} soʻm ${data.plan.in_trial ? 'sinov muddatidan keyingi birinchi hisobga' : 'obuna uchun eng yaqin hisobga'} qoʻshiladi. Hisobni «Balans va obuna» boʻlimida platformadagi balansdan toʻlash mumkin. Brendlar reklamasidan ulush bu hisobni kamaytiradi.`,
              ),
              okText: tr('Перейти к оплате', 'Toʻlovga oʻtish'),
              onOk: () => navigate('/balance?tab=billing'),
              closable: true,
            })
          } else message.success(tr(`Тариф «${p.name}» подключён`, `«${p.name}» tarifi ulandi`))
        } catch (e) {
          message.error(errorText(e))
        } finally {
          setBusy(undefined)
        }
      },
    })
  return (
    <Modal open={open} onCancel={onClose} footer={null} width={860} title={tr('Тарифы витрины', 'Vitrina tariflari')}>
      <div className="smh-plans">
        {data.plans.map((p) => {
          const current = p.key === data.plan.chosen.key
          return (
            <div key={p.key} className={`smh-plan${p.key === highlight || (!highlight && p.recommended) ? ' rec' : ''}${current ? ' cur' : ''}`}>
              {p.recommended && <span className="smh-plan-badge">{tr('Рекомендуем', 'Tavsiya etamiz')}</span>}
              <h4>{p.name}</h4>
              <div className="smh-field-hint">{Number(p.price_uzs) > 0 ? `${money(p.price_uzs)} ${tr('сум / мес', 'soʻm / oy')}` : tr('бесплатно', 'bepul')}</div>
              <ul>
                {planLines(p).map((x) => (
                  <li key={x}>{x}</li>
                ))}
              </ul>
              {current ? (
                <Button block disabled icon={<CheckOutlined />}>
                  {data.plan.in_trial
                    ? tr(`Ваш тариф · пробный «${data.plan.effective.name}»`, `Sizning tarifingiz · sinov «${data.plan.effective.name}»`)
                    : tr('Ваш тариф', 'Sizning tarifingiz')}
                </Button>
              ) : data.can_buy ? (
                <Button block type={p.key === highlight ? 'primary' : 'default'} danger={p.key === highlight} loading={busy === p.key} onClick={() => choose(p)}>
                  {tr(`Перейти на «${p.name}»`, `«${p.name}» tarifiga oʻtish`)}
                </Button>
              ) : (
                <div className="smh-field-hint">{tr('Сменить тариф может владелец сети', 'Tarifni tarmoq egasi oʻzgartira oladi')}</div>
              )}
            </div>
          )
        })}
      </div>
      {data.plan.trial_until && (
        <div className="smh-field-hint" style={{ marginTop: 12 }}>
          {data.plan.in_trial
            ? tr(
                `Пробный период до ${dayjs(data.plan.trial_until).format('DD.MM.YYYY')}. Потом, если не перейти на платный тариф, витрина вернётся к «Старт»: свои баннеры и полки скроются, но не удалятся.`,
                `Sinov muddati ${dayjs(data.plan.trial_until).format('DD.MM.YYYY')} gacha. Keyin pullik tarifga oʻtmasangiz, vitrina «Start» tarifiga qaytadi: oʻz bannerlaringiz va javonlaringiz yashiriladi, lekin oʻchirilmaydi.`,
              )
            : tr('Пробный период закончился.', 'Sinov muddati tugadi.')}
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
              {l.store_id
                ? tr(`У магазина «${l.store_name}» своя витрина.`, `«${l.store_name}» doʻkonining oʻz vitrinasi bor.`)
                : tr('У сети своя витрина.', 'Tarmoqning oʻz vitrinasi bor.')}
              <Button
                size="small"
                onClick={() =>
                  modal.confirm({
                    title: l.store_id ? tr('Вернуть витрину сети?', 'Tarmoq vitrinasi qaytarilsinmi?') : tr('Вернуть витрину Super Market?', 'Super Market vitrinasi qaytarilsinmi?'),
                    content: tr('Ваши блоки и их версии удалятся. Свои баннеры останутся в списке баннеров.', 'Bloklaringiz va ularning versiyalari oʻchiriladi. Oʻz bannerlaringiz bannerlar roʻyxatida qoladi.'),
                    okText: tr('Вернуть', 'Qaytarish'),
                    okButtonProps: { danger: true },
                    cancelText: tr('Отмена', 'Bekor qilish'),
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
                {l.store_id ? tr('Вернуть витрину сети', 'Tarmoq vitrinasini qaytarish') : tr('Вернуть витрину Super Market', 'Super Market vitrinasini qaytarish')}
              </Button>
            </div>
          ) : null
        }
        title={tr('Витрина приложения', 'Ilova vitrinasi')}
        subtitle={tr(
          'Так покупатели видят ваш магазин на главной. Блоки Super Market закреплены и всегда на месте.',
          'Xaridorlar doʻkoningizni bosh sahifada shunday koʻradi. Super Market bloklari mahkamlangan va doim joyida.',
        )}
        base={BASE}
        params={params}
        storesPath="/store/home/stores"
        previewPath="/store/home/preview"
        storeParam="store_id"
        paths={{ products: '/store/products', productParams: { scope: 'mine', store_id: storeId || undefined }, categories: '/store/catalog/categories', banners: '/store/banners' }}
        unwrap={(raw) => (raw as ShowcaseData).layout}
        top={(raw, blocks) => <PlanBar data={raw as ShowcaseData} blocks={blocks} onCompare={() => setPlans({ open: true })} />}
        locked={(b) => !!b.pinned}
        features={{ schedule: p?.schedule ?? false, manual: p?.manual ?? false }}
        onUpgrade={(feature) => setLimit({ feature })}
        onError={onError}
        addInfo={(t, blocks, raw) => {
          const d = raw as ShowcaseData
          const plan = d.plan.effective
          if (!plan.custom) return { lock: lockName(d, 'custom'), feature: 'custom' }
          const c = ownCounts(blocks, d.template_ids)
          const left = (used: number, lim: number | null, what: string, feature: string) =>
            lim === null
              ? { hint: `${what}: ${tr('без лимита', 'cheklovsiz')}` }
              : used >= lim
                ? { lock: lockName(d, feature, used), hint: tr(`Лимит ${lim} из ${lim} — уже все`, `Cheklov ${lim} / ${lim} — hammasi band`), feature }
                : { hint: tr(`Осталось ${lim - used} из ${lim}`, `${lim} tadan ${lim - used} ta qoldi`) }
          switch (t) {
            case 'shelf':
              return left(c.shelves, plan.shelves, tr('Свои полки', 'Oʻz javonlaringiz'), 'shelves')
            case 'scheduled':
              return plan.schedule
                ? left(c.shelves, plan.shelves, tr('Свои полки', 'Oʻz javonlaringiz'), 'shelves')
                : { lock: lockName(d, 'schedule'), hint: tr('Полка сама включится и выключится по датам', 'Javon sanalar boʻyicha oʻzi yoqiladi va oʻchadi'), feature: 'schedule' }
            case 'promo':
              return left(c.promos, plan.promos, tr('Промо-полоски', 'Promo-chiziqlar'), 'promos')
            case 'banners':
              return plan.banners === 0
                ? { lock: lockName(d, 'banners'), feature: 'banners' }
                : { hint: `${tr('Свои баннеры', 'Oʻz bannerlaringiz')}: ${d.usage.banners}${plan.banners === null ? '' : tr(` из ${plan.banners}`, ` / ${plan.banners}`)}` }
            default:
              return blocks.some((b) => b.type === t) ? { hint: tr('Уже на главной', 'Bosh sahifada allaqachon bor') } : undefined
          }
        }}
        scope={
          <Space>
          <Button size="large" icon={<BarChartOutlined />} onClick={() => setStats(true)}>
            {tr('Статистика', 'Statistika')}
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
              { value: '', label: tr('Все магазины сети', 'Tarmoqning barcha doʻkonlari') },
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
          subtitle={storeId ? data?.stores.find((s) => s.id === storeId)?.name : tr('все магазины сети', 'tarmoqning barcha doʻkonlari')}
          onUpgrade={() => {
            setStats(false)
            setPlans({ open: true, highlight: data ? needPlan(data, p?.stats === 'basic' ? 'stats_full' : 'stats')?.key : undefined })
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
