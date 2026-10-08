// Первая настройка магазина (Figma «Панель магазина · первая настройка», ВН1–ВН5).
// Пока в сети нет магазина с точкой на карте и часами работы, панель
// показывает только мастер; доставку можно пропустить — тогда на главной
// чек-лист. Прогресс общий с приложением «SM Магазин».
/* eslint-disable @typescript-eslint/no-explicit-any */
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Alert, App, Button, Flex, Form, Input, InputNumber, Result, Segmented, Spin, Switch, TimePicker, Typography } from 'antd'
import {
  ArrowLeftOutlined,
  ArrowRightOutlined,
  CarOutlined,
  CheckCircleFilled,
  CheckOutlined,
  CopyOutlined,
  HeartFilled,
  HomeOutlined,
  HourglassOutlined,
  InfoCircleOutlined,
  LogoutOutlined,
  MobileOutlined,
  MoonOutlined,
  ReloadOutlined,
  ShopOutlined,
} from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { Brand, LangSwitch, MapPointPicker, PhoneInput, errorText, phoneRule, tr, useAuth, useFitMap, useYmaps, type LatLng } from '@sm/shared'
import { useStore } from '../../ctx'
import { buyers, firstStep, hoursText, setupApi, type SetupState, type WorkingHours } from './api'

const KEY = '/store/setup'

// ------------------------------------------------------------------ гейт

/** Состояние настройки магазина для главной (чек-лист). */
export function useSetupState(storeId: string, enabled: boolean) {
  return useQuery({
    queryKey: [KEY, 'store', storeId],
    queryFn: () => setupApi.get(storeId),
    enabled: enabled && !!storeId,
  })
}

/** Пока мастер не пройден — вместо панели мастер (или ожидание для сотрудников). */
export function SetupGate({ children }: { children: ReactNode }) {
  const { me } = useStore()
  const st = useQuery({
    queryKey: [KEY],
    queryFn: () => setupApi.get(),
    enabled: !!me,
    refetchOnWindowFocus: false,
  })
  if (!me || st.isLoading) return <Spin style={{ display: 'block', marginTop: 96 }} />
  if (st.data?.required) {
    return st.data.can_setup ? <SetupWizard initial={st.data} required /> : <SetupWaiting onRefresh={() => void st.refetch()} loading={st.isFetching} />
  }
  return <>{children}</>
}

/** /setup?step=3&store_id=… — вернуться к шагу из чек-листа на главной. */
export function SetupPage() {
  const [sp] = useSearchParams()
  const storeId = sp.get('store_id') ?? undefined
  const st = useQuery({
    queryKey: [KEY, 'edit', storeId],
    queryFn: () => setupApi.get(storeId),
    refetchOnWindowFocus: false,
    gcTime: 0,
  })
  if (st.isLoading) return <Spin style={{ display: 'block', marginTop: 96 }} />
  if (st.error || !st.data) return <Result status="warning" title={tr('Не удалось открыть настройку', 'Sozlamani ochib boʻlmadi')} subTitle={errorText(st.error)} />
  if (!st.data.can_setup) return <Result status="403" title={tr('Нет доступа', 'Ruxsat yoʻq')} subTitle={tr('Настраивать магазин может владелец или сотрудник с правом «Магазины».', 'Doʻkonni egasi yoki «Doʻkonlar» huquqiga ega xodim sozlashi mumkin.')} />
  const step = Number(sp.get('step'))
  return <SetupWizard initial={st.data} startStep={step === 1 || step === 2 || step === 3 ? step : undefined} />
}

// ------------------------------------------------------------------ каркас

function Top({ right }: { right: ReactNode }) {
  const { me } = useStore()
  const who = [me?.full_name, me?.is_owner ? tr('владелец', 'egasi') : me?.role_name?.toLowerCase()].filter(Boolean).join(' · ')
  return (
    <div className="sm-setup-top">
      <Brand title="Super Market" subtitle={tr('Панель магазина', 'Doʻkon paneli')} />
      <span className="sm-setup-top-user">{who}</span>
      <LangSwitch size="middle" />
      {right}
    </div>
  )
}

function SetupWaiting({ onRefresh, loading }: { onRefresh: () => void; loading: boolean }) {
  const { logout } = useAuth()
  return (
    <div className="sm-setup">
      <Top
        right={
          <Button icon={<LogoutOutlined />} onClick={() => void logout()}>
            {tr('Выйти', 'Chiqish')}
          </Button>
        }
      />
      <Flex justify="center" style={{ padding: '96px 16px' }}>
        <div className="sm-setup-main" style={{ width: 520, textAlign: 'center' }}>
          <HourglassOutlined style={{ fontSize: 40, color: '#667085' }} />
          <h2 style={{ marginTop: 16 }}>{tr('Магазин ещё настраивается', 'Doʻkon hali sozlanmoqda')}</h2>
          <Typography.Paragraph type="secondary" style={{ margin: '8px 0 20px' }}>
            {tr('Владелец указывает адрес и часы работы. Как только он закончит, здесь появятся заказы, склад и касса.', 'Egasi manzil va ish vaqtini kiritmoqda. U tugatishi bilan bu yerda buyurtmalar, ombor va kassa paydo boʻladi.')}
          </Typography.Paragraph>
          <Button icon={<ReloadOutlined />} loading={loading} onClick={onRefresh}>
            {tr('Обновить', 'Yangilash')}
          </Button>
        </div>
      </Flex>
    </div>
  )
}

const STEPS = [
  [tr('Магазин и адрес', 'Doʻkon va manzil'), tr('Название, телефон, точка', 'Nomi, telefon, nuqta')],
  [tr('Часы работы', 'Ish vaqti'), tr('Когда открыт магазин', 'Doʻkon qachon ochiq')],
  [tr('Доставка', 'Yetkazib berish'), tr('Можно настроить позже', 'Keyinroq sozlash mumkin')],
] as const

function StepsCard({ step, s }: { step: number; s: SetupState }) {
  const done = [s.steps.store, s.steps.hours, s.steps.delivery]
  return (
    <aside className="sm-setup-steps">
      <h3>{tr('Настройка магазина', 'Doʻkonni sozlash')}</h3>
      <Typography.Text type="secondary" style={{ fontSize: 13 }}>
        {tr('3 шага · около 3 минут', '3 qadam · taxminan 3 daqiqa')}
      </Typography.Text>
      <Flex vertical gap={4} style={{ marginTop: 12 }}>
        {STEPS.map(([t, sub], i) => {
          const n = i + 1
          const cls = n === step ? 'is-current' : done[i] ? 'is-done' : n > step ? 'is-next' : ''
          return (
            <div key={t} className={`sm-setup-step ${cls}`}>
              <span className="sm-setup-dot">{n !== step && done[i] ? <CheckOutlined /> : n}</span>
              <span>
                <b>{t}</b>
                <small>{sub}</small>
              </span>
            </div>
          )
        })}
      </Flex>
      <Flex
        gap={8}
        style={{
          borderTop: '1px solid #EAECF0',
          marginTop: 12,
          paddingTop: 12,
          fontSize: 12,
          color: '#667085',
        }}
      >
        <MobileOutlined style={{ fontSize: 16 }} />
        <span>{tr('Всё сохраняется по шагам — можно продолжить в приложении «SM Магазин»', 'Hammasi qadamma-qadam saqlanadi — «SM Магазин» ilovasida davom ettirish mumkin')}</span>
      </Flex>
    </aside>
  )
}

function SetupWizard({ initial, required = false, startStep }: { initial: SetupState; required?: boolean; startStep?: 1 | 2 | 3 }) {
  const [s, setS] = useState(initial)
  const [step, setStep] = useState<1 | 2 | 3>(startStep ?? firstStep(initial))
  const qc = useQueryClient()
  const nav = useNavigate()
  const { message } = App.useApp()
  const { logout } = useAuth()

  const finish = async (msg?: string) => {
    if (msg) message.success(msg)
    await qc.invalidateQueries()
    nav('/')
  }
  // Шаг сохранён — следующий; в правке с главной ещё не пройденный шаг тоже показываем.
  const saved = (next: SetupState, to: 1 | 2 | 3 | 'done') => {
    setS(next)
    if (to === 'done') void finish()
    else setStep(to)
  }

  return (
    <div className="sm-setup">
      <Top
        right={
          required ? (
            <Button icon={<LogoutOutlined />} onClick={() => void logout()}>
              {tr('Выйти', 'Chiqish')}
            </Button>
          ) : (
            <Button icon={<HomeOutlined />} onClick={() => nav('/')}>
              {tr('На главную', 'Bosh sahifaga')}
            </Button>
          )
        }
      />
      <div className="sm-setup-wrap">
        <StepsCard step={step} s={s} />
        <section className="sm-setup-main">
          {step === 1 && <StoreStep s={s} onSaved={(n) => saved(n, startStep && n.steps.hours ? 'done' : 2)} />}
          {step === 2 && <HoursStep s={s} onBack={() => setStep(1)} onSaved={(n) => saved(n, startStep && n.steps.delivery ? 'done' : 3)} />}
          {step === 3 && <DeliveryStep s={s} onBack={() => setStep(2)} onFinish={finish} />}
        </section>
      </div>
    </div>
  )
}

function Head({ title, sub }: { title: string; sub: string }) {
  return (
    <div style={{ marginBottom: 20 }}>
      <h2>{title}</h2>
      <Typography.Text type="secondary">{sub}</Typography.Text>
    </div>
  )
}

function useSave() {
  const { message } = App.useApp()
  const [busy, setBusy] = useState(false)
  const run = async <T,>(fn: () => Promise<T>, ok: (v: T) => void) => {
    setBusy(true)
    try {
      ok(await fn())
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  return { busy, run }
}

// ------------------------------------------------------------ шаг 1

type StoreForm = {
  name: string
  phone?: string
  address: string
  geo: LatLng | null
}

function StoreStep({ s, onSaved }: { s: SetupState; onSaved: (n: SetupState) => void }) {
  const { me } = useStore()
  const [form] = Form.useForm<StoreForm>()
  const city = useRef<string | undefined>(undefined)
  const { busy, run } = useSave()
  const st = s.store
  const submit = (v: StoreForm) =>
    run(
      () =>
        setupApi.store({
          store_id: st?.id,
          name: v.name,
          phone: v.phone ?? '',
          address: v.address,
          lat: v.geo!.lat,
          lng: v.geo!.lng,
          city: city.current,
        }),
      onSaved,
    )
  return (
    <Form<StoreForm>
      form={form}
      layout="vertical"
      requiredMark={false}
      onFinish={submit}
      initialValues={{
        name: st?.name || me?.network.name || '',
        phone: st?.phone || undefined,
        address: st?.address ?? '',
        geo: st && st.lat !== null && st.lng !== null ? { lat: st.lat, lng: st.lng } : null,
      }}
    >
      <Head title={tr('Ваш магазин', 'Doʻkoningiz')} sub={tr('Так его увидят покупатели в приложении Super Market', 'Xaridorlar uni Super Market ilovasida shunday koʻradi')} />
      <Flex gap={16} wrap>
        <Form.Item
          name="name"
          label={tr('Название магазина', 'Doʻkon nomi')}
          style={{ flex: 1, minWidth: 220 }}
          rules={[{ required: true, whitespace: true, message: tr('Укажите название', 'Nomini kiriting') }]}
        >
          <Input maxLength={120} />
        </Form.Item>
        <Form.Item name="phone" label={tr('Телефон магазина', 'Doʻkon telefoni')} extra={tr('Покупатели и курьеры смогут позвонить', 'Xaridorlar va kuryerlar qoʻngʻiroq qila oladi')} style={{ flex: 1, minWidth: 220 }} rules={[phoneRule()]}>
          <PhoneInput />
        </Form.Item>
      </Flex>
      <Form.Item name="address" label={tr('Адрес', 'Manzil')} rules={[{ required: true, whitespace: true, message: tr('Укажите адрес', 'Manzilni kiriting') }]}>
        <Input placeholder={tr('Чиланзар, 9-й квартал, 12', 'Chilonzor, 9-mavze, 12')} allowClear />
      </Form.Item>
      <Form.Item
        name="geo"
        label={tr('Точка на карте', 'Xaritadagi nuqta')}
        extra={tr('Нажмите на карту, найдите адрес через поиск или перетащите метку на вход — по ней покупатели найдут магазин, а курьер подъедет к двери', 'Xaritani bosing, manzilni qidiruv orqali toping yoki belgini kirish joyiga suring — u orqali xaridorlar doʻkonni topadi, kuryer esa eshik oldiga keladi')}
        rules={[{ required: true, message: tr('Поставьте метку на вход в магазин', 'Belgini doʻkon kirish joyiga qoʻying') }]}
      >
        <MapPointPicker
          height={300}
          onAddress={(a) => {
            if (!String(form.getFieldValue('address') ?? '').trim()) form.setFieldValue('address', a)
          }}
          onCity={(c) => {
            city.current = c
          }}
        />
      </Form.Item>
      <div className="sm-setup-foot">
        <span className="sm-grow" />
        <Button type="primary" htmlType="submit" loading={busy} icon={<ArrowRightOutlined />} iconPosition="end">
          {tr('Дальше', 'Keyingi')}
        </Button>
      </div>
    </Form>
  )
}

// ------------------------------------------------------------ шаг 2

type Day = { on: boolean; opens: Dayjs; closes: Dayjs }
type Preset = 'daily' | 'mon_sat' | 'round' | 'custom'

const WEEK = [1, 2, 3, 4, 5, 6, 0] // понедельник первым
const DAY_NAME = tr(
  'Воскресенье Понедельник Вторник Среда Четверг Пятница Суббота',
  'Yakshanba Dushanba Seshanba Chorshanba Payshanba Juma Shanba',
).split(' ')
const t = (v: string) => dayjs(v, 'HH:mm')
const fmt = (d: Dayjs) => d.format('HH:mm')

function initHours(s: SetupState): { preset: Preset; days: Day[] } {
  const def = (): Day[] =>
    Array.from({ length: 7 }, () => ({
      on: true,
      opens: t('08:00'),
      closes: t('22:00'),
    }))
  if (s.steps.hours && s.working_hours.length === 0) return { preset: 'round', days: def() }
  if (s.working_hours.length === 0) return { preset: 'daily', days: def() }
  const days = def().map((d) => ({ ...d, on: false }))
  s.working_hours.forEach((h) => (days[h.weekday] = { on: true, opens: t(h.opens), closes: t(h.closes) }))
  const key = (d: Day) => (d.on ? fmt(d.opens) + fmt(d.closes) : 'off')
  const mon = key(days[1])
  const sameWeek = [1, 2, 3, 4, 5, 6].every((w) => key(days[w]) === mon)
  const preset: Preset = sameWeek && key(days[0]) === mon ? 'daily' : sameWeek && !days[0].on ? 'mon_sat' : 'custom'
  return { preset, days }
}

function HoursStep({ s, onBack, onSaved }: { s: SetupState; onBack: () => void; onSaved: (n: SetupState) => void }) {
  const [{ preset, days }, set] = useState(() => initHours(s))
  const { message } = App.useApp()
  const { busy, run } = useSave()

  const choose = (p: Preset) => {
    const base = days[1].on ? days[1] : { on: true, opens: t('08:00'), closes: t('22:00') }
    if (p === 'daily') set({ preset: p, days: days.map(() => ({ ...base, on: true })) })
    else if (p === 'mon_sat') set({ preset: p, days: days.map((_, w) => ({ ...base, on: w !== 0 })) })
    else set({ preset: p, days })
  }
  const edit = (w: number, patch: Partial<Day>) =>
    set({
      preset: 'custom',
      days: days.map((d, i) => (i === w ? { ...d, ...patch } : d)),
    })

  const submit = () => {
    let hours: WorkingHours[] = []
    if (preset !== 'round') {
      hours = days.flatMap((d, w) => (d.on ? [{ weekday: w, opens: fmt(d.opens), closes: fmt(d.closes) }] : []))
      if (hours.length === 0) return void message.error(tr('Отметьте хотя бы один рабочий день или выберите «Круглосуточно»', 'Kamida bitta ish kunini belgilang yoki «Kecha-kunduz» ni tanlang'))
      const bad = hours.find((h) => h.opens === h.closes)
      if (bad) return void message.error(tr(`${DAY_NAME[bad.weekday]}: время открытия и закрытия совпадает`, `${DAY_NAME[bad.weekday]}: ochilish va yopilish vaqti bir xil`))
    }
    void run(() => setupApi.hours(s.store!.id, hours), onSaved)
  }

  return (
    <>
      <Head title={tr('Часы работы', 'Ish vaqti')} sub={tr('Покупатели увидят «открыто» или «закрыто», а заказы ко времени — только в эти часы', 'Xaridorlar «ochiq» yoki «yopiq» ni koʻradi, vaqtga buyurtmalar esa faqat shu soatlarda')} />
      <Segmented<Preset>
        value={preset}
        onChange={choose}
        options={[
          { label: tr('Каждый день', 'Har kuni'), value: 'daily' },
          { label: tr('Пн–Сб', 'Du–Sh'), value: 'mon_sat' },
          { label: tr('Круглосуточно', 'Kecha-kunduz'), value: 'round' },
          { label: tr('По дням', 'Kunlar boʻyicha'), value: 'custom' },
        ]}
        style={{ marginBottom: 16 }}
      />
      {preset === 'round' ? (
        <Alert type="info" showIcon message={tr('Магазин работает 24 часа без выходных', 'Doʻkon dam olish kunlarisiz 24 soat ishlaydi')} description={tr('Покупатели всегда видят «открыто».', 'Xaridorlar doim «ochiq» ni koʻradi.')} />
      ) : (
        <>
          <div className="sm-setup-days">
            <div className="sm-setup-day">
              <span>{tr('День', 'Kun')}</span>
              <span>{tr('Работает', 'Ishlaydi')}</span>
              <span>{tr('Открытие', 'Ochilish')}</span>
              <span>{tr('Закрытие', 'Yopilish')}</span>
            </div>
            {WEEK.map((w) => {
              const d = days[w]
              return (
                <div key={w} className="sm-setup-day">
                  <Typography.Text strong={d.on} type={d.on ? undefined : 'secondary'}>
                    {DAY_NAME[w]}
                  </Typography.Text>
                  <Switch checked={d.on} onChange={(on) => edit(w, { on })} aria-label={tr(`${DAY_NAME[w]} — работает`, `${DAY_NAME[w]} — ishlaydi`)} />
                  <TimePicker
                    format="HH:mm"
                    minuteStep={5}
                    value={d.opens}
                    disabled={!d.on}
                    allowClear={false}
                    needConfirm={false}
                    onChange={(v) => v && edit(w, { opens: v })}
                  />
                  <TimePicker
                    format="HH:mm"
                    minuteStep={5}
                    value={d.closes}
                    disabled={!d.on}
                    allowClear={false}
                    needConfirm={false}
                    onChange={(v) => v && edit(w, { closes: v })}
                  />
                </div>
              )
            })}
          </div>
          <Flex gap={24} wrap align="center" style={{ marginTop: 12 }}>
            <Button
              type="link"
              icon={<CopyOutlined />}
              style={{ padding: 0, color: '#E11D2A' }}
              onClick={() =>
                set({
                  preset: 'custom',
                  days: days.map(() => ({ ...days[1] })),
                })
              }
            >
              {tr('Скопировать понедельник на все дни', 'Dushanbani barcha kunlarga nusxalash')}
            </Button>
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              <MoonOutlined /> {tr('После полуночи: например, 08:00 – 02:00', 'Yarim tundan keyin: masalan, 08:00 – 02:00')}
            </Typography.Text>
          </Flex>
        </>
      )}
      <div className="sm-setup-foot">
        <span className="sm-grow" />
        <Button icon={<ArrowLeftOutlined />} onClick={onBack}>
          {tr('Назад', 'Orqaga')}
        </Button>
        <Button type="primary" loading={busy} icon={<ArrowRightOutlined />} iconPosition="end" onClick={submit}>
          {tr('Дальше', 'Keyingi')}
        </Button>
      </div>
    </>
  )
}

// ------------------------------------------------------------ шаг 3

const RADII = [1000, 2000, 3000, 5000]
const ETAS: [number, number][] = [
  [15, 25],
  [25, 35],
  [35, 50],
  [60, 120],
]
const etaLabel = ([a, b]: [number, number]) => (a >= 60 ? tr(`${a / 60}–${b / 60} часа`, `${a / 60}–${b / 60} soat`) : tr(`${a}–${b} мин`, `${a}–${b} daqiqa`))
const plain = (v: string | null | undefined) => (v ? String(Number(v)) : '')

function DeliveryStep({ s, onBack, onFinish }: { s: SetupState; onBack: () => void; onFinish: (msg?: string) => Promise<void> }) {
  const d = s.delivery
  const [mode, setMode] = useState<'deliver' | 'none'>(d.declined && !d.accepts_online ? 'none' : 'deliver')
  const [radius, setRadius] = useState(d.delivery_radius_m > 0 ? d.delivery_radius_m : 3000)
  const [other, setOther] = useState(!RADII.includes(radius))
  const [fee, setFee] = useState<string>(d.fee !== null ? plain(d.fee) : '10000')
  const [freeFrom, setFreeFrom] = useState<string>(plain(d.free_from))
  const [minOrder, setMinOrder] = useState<string>(plain(d.min_order_amount) || '0')
  const [eta, setEta] = useState<[number, number]>(() => ETAS.find(([a, b]) => a === d.eta_min && b === d.eta_max) ?? ETAS[1])
  const { message } = App.useApp()
  const { busy, run } = useSave()
  const st = s.store!

  const submit = () => {
    if (mode === 'none') {
      return void run(
        () => setupApi.delivery({ store_id: st.id, mode: 'none' }),
        () => void onFinish(tr('Магазин настроен. Покупатели видят его в приложении, заказы — когда включите доставку', 'Doʻkon sozlandi. Xaridorlar uni ilovada koʻradi, buyurtmalar — yetkazib berishni yoqqaningizda')),
      )
    }
    if (fee === '') return void message.error(tr('Укажите стоимость доставки — 0, если бесплатно', 'Yetkazib berish narxini kiriting — bepul boʻlsa, 0'))
    void run(
      () =>
        setupApi.delivery({
          store_id: st.id,
          mode: 'deliver',
          delivery_radius_m: radius,
          fee,
          free_from: freeFrom === '' ? null : freeFrom,
          min_order_amount: minOrder || '0',
          eta_min: eta[0],
          eta_max: eta[1],
        }),
      () => void onFinish(tr('Магазин настроен — покупатели рядом могут заказывать', 'Doʻkon sozlandi — yaqin atrofdagi xaridorlar buyurtma bera oladi')),
    )
  }

  const option = (v: 'deliver' | 'none', icon: ReactNode, title: string, text: string) => (
    <button type="button" className={`sm-setup-option ${mode === v ? 'is-on' : ''}`} onClick={() => setMode(v)} aria-pressed={mode === v}>
      <span className="ic">{icon}</span>
      <span style={{ flex: 1 }}>
        <b>{title}</b>
        <span>{text}</span>
      </span>
      {mode === v ? (
        <CheckCircleFilled style={{ color: '#E11D2A', fontSize: 20 }} />
      ) : (
        <span
          style={{
            width: 20,
            height: 20,
            borderRadius: 10,
            border: '1.5px solid #D0D5DD',
          }}
        />
      )}
    </button>
  )

  return (
    <>
      <Head title={tr('Доставка', 'Yetkazib berish')} sub={tr('Можно пропустить — магазин всё равно появится у покупателей, но заказать из него будет нельзя', 'Oʻtkazib yuborish mumkin — doʻkon baribir xaridorlarda koʻrinadi, lekin undan buyurtma berib boʻlmaydi')} />
      <Flex gap={16} wrap>
        {option('deliver', <CarOutlined />, tr('Доставляем сами', 'Oʻzimiz yetkazamiz'), tr('Своими курьерами или курьерами по пути', 'Oʻz kuryerlarimiz yoki yoʻlakay kuryerlar'))}
        {option('none', <ShopOutlined />, tr('Пока без доставки', 'Hozircha yetkazib berishsiz'), tr('Покупатели увидят магазин и цены. Кнопка «Хочу доставку» покажет, сколько людей её ждут', 'Xaridorlar doʻkon va narxlarni koʻradi. «Yetkazib berishni xohlayman» tugmasi uni qancha odam kutayotganini koʻrsatadi'))}
      </Flex>
      {mode === 'deliver' && (
        <Flex gap={24} wrap style={{ marginTop: 20 }}>
          <Flex vertical gap={16} style={{ flex: 1, minWidth: 280 }}>
            <div>
              <Label>{tr('Куда доставляем', 'Qayergacha yetkazamiz')}</Label>
              <Flex gap={8} wrap align="center">
                <Segmented<number | 'other'>
                  value={other ? 'other' : radius}
                  onChange={(v) => {
                    if (v === 'other') setOther(true)
                    else {
                      setOther(false)
                      setRadius(v)
                    }
                  }}
                  options={[
                    ...RADII.map((r) => ({
                      label: `${r / 1000} ${tr('км', 'km')}`,
                      value: r,
                    })),
                    { label: tr('Другое', 'Boshqa'), value: 'other' as const },
                  ]}
                />
                {other && (
                  <InputNumber<number>
                    min={0.1}
                    max={100}
                    step={0.5}
                    value={radius / 1000}
                    onChange={(v) => v && setRadius(Math.round(v * 1000))}
                    suffix={tr('км', 'km')}
                    style={{ width: 130 }}
                  />
                )}
              </Flex>
            </div>
            <Flex gap={12} wrap>
              <div style={{ flex: 1, minWidth: 140 }}>
                <Label>{tr('Стоимость доставки', 'Yetkazib berish narxi')}</Label>
                <Money value={fee} onChange={setFee} />
              </div>
              <div style={{ flex: 1, minWidth: 140 }}>
                <Label>{tr('Бесплатно от', 'Bepul (summadan)')}</Label>
                <Money value={freeFrom} onChange={setFreeFrom} placeholder={tr('не нужно', 'kerak emas')} />
              </div>
            </Flex>
            <div>
              <Label>{tr('Минимальный заказ', 'Minimal buyurtma')}</Label>
              <Money value={minOrder} onChange={setMinOrder} />
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {tr('Заказ на меньшую сумму оформить нельзя', 'Kamroq summaga buyurtma berib boʻlmaydi')}
              </Typography.Text>
            </div>
            <div>
              <Label>{tr('Привезём за', 'Yetkazish vaqti')}</Label>
              <Segmented<string>
                value={eta.join('-')}
                onChange={(v) => setEta(ETAS.find((e) => e.join('-') === v)!)}
                options={ETAS.map((e) => ({
                  label: etaLabel(e),
                  value: e.join('-'),
                }))}
              />
            </div>
          </Flex>
          {st.lat !== null && st.lng !== null && <RadiusMap lat={st.lat} lng={st.lng} radius={radius} />}
        </Flex>
      )}
      <Typography.Text type="secondary" style={{ display: 'block', marginTop: 16, fontSize: 13 }}>
        <InfoCircleOutlined />{' '}
        {tr(
          'Зоны на карте, цену по расстоянию и доставку ко времени можно настроить потом в разделе «Доставка»',
          'Xaritadagi hududlar, masofaga qarab narx va vaqtga yetkazib berishni keyinroq «Yetkazib berish» boʻlimida sozlash mumkin',
        )}
      </Typography.Text>
      <div className="sm-setup-foot">
        {!s.steps.delivery && (
          <Button type="link" style={{ paddingLeft: 0, color: '#667085' }} onClick={() => void onFinish()}>
            {tr('Пропустить, настрою позже', 'Oʻtkazib yuborish, keyinroq sozlayman')}
          </Button>
        )}
        <span className="sm-grow" />
        <Button icon={<ArrowLeftOutlined />} onClick={onBack}>
          {tr('Назад', 'Orqaga')}
        </Button>
        <Button type="primary" loading={busy} icon={<CheckOutlined />} onClick={submit}>
          {tr('Готово', 'Tayyor')}
        </Button>
      </div>
    </>
  )
}

function Label({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        fontSize: 13,
        fontWeight: 600,
        color: '#344054',
        marginBottom: 6,
      }}
    >
      {children}
    </div>
  )
}

function Money({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder?: string }) {
  return (
    <InputNumber<string>
      stringMode
      min="0"
      max="100000000"
      precision={0}
      value={value === '' ? null : value}
      onChange={(v) => onChange(v ?? '')}
      placeholder={placeholder}
      suffix={tr('сум', 'soʻm')}
      formatter={(v) => (v ? String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ' ') : '')}
      parser={(v) => (v ?? '').replace(/\s/g, '')}
      style={{ width: '100%' }}
    />
  )
}

/** Карта с кругом доставки вокруг магазина. */
function RadiusMap({ lat, lng, radius }: { lat: number; lng: number; radius: number }) {
  const { ymaps, error } = useYmaps()
  const box = useRef<HTMLDivElement>(null)
  const [map, setMap] = useState<any>(null)
  const circle = useRef<any>(null)
  useEffect(() => {
    if (!ymaps || !box.current) return
    const m = new ymaps.Map(box.current, { center: [lat, lng], zoom: 13, controls: ['zoomControl'] }, { suppressMapOpenBlock: true })
    const c = new ymaps.Circle(
      [[lat, lng], 1000],
      {},
      {
        fillColor: '#E11D2A14',
        strokeColor: '#E11D2A',
        strokeWidth: 2,
        strokeStyle: 'dash',
      },
    )
    m.geoObjects.add(c)
    m.geoObjects.add(new ymaps.Placemark([lat, lng], { hintContent: tr('Магазин', 'Doʻkon') }, { preset: 'islands#redShoppingIcon' }))
    circle.current = c
    setMap(m)
    return () => {
      m.destroy()
      circle.current = null
      setMap(null)
    }
  }, [ymaps, lat, lng])
  useFitMap(box, map)
  useEffect(() => {
    const c = circle.current
    if (!map || !c) return
    c.geometry.setRadius(radius)
    map.setBounds(c.geometry.getBounds(), {
      checkZoomRange: true,
      zoomMargin: 12,
    })
  }, [map, radius])
  if (error) return null
  return (
    <div className="sm-map" style={{ width: 280, height: 300, flexShrink: 0 }}>
      <div ref={box} style={{ position: 'absolute', inset: 0 }} />
      {!ymaps && <Spin style={{ position: 'absolute', inset: 0, margin: 'auto', height: 32 }} />}
    </div>
  )
}

// ------------------------------------------------------------ чек-лист на главной

/** «Настройка магазина · 2 из 3» — пока не пройдены все шаги (ВН4). */
export function SetupChecklist({ s }: { s: SetupState }) {
  const nav = useNavigate()
  const qc = useQueryClient()
  const { busy, run } = useSave()
  const st = s.store
  if (s.required || s.steps.done || !s.can_setup || !st) return null
  const go = (step: number) => nav(`/setup?step=${step}&store_id=${st.id}`)
  const n = [s.steps.store, s.steps.hours, s.steps.delivery].filter(Boolean).length
  const onlyDelivery = s.steps.store && s.steps.hours

  const col = (done: boolean, title: string, text: string, actions: ReactNode) => (
    <div className={done ? '' : 'is-todo'}>
      <Flex align="center" gap={8}>
        {done ? (
          <CheckCircleFilled style={{ color: '#17B26A', fontSize: 18 }} />
        ) : (
          <span
            style={{
              width: 16,
              height: 16,
              borderRadius: 8,
              border: '2px solid #E11D2A',
            }}
          />
        )}
        <Typography.Text strong style={{ fontSize: 15 }}>
          {title}
        </Typography.Text>
      </Flex>
      <Typography.Paragraph type="secondary" style={{ margin: '8px 0 10px', fontSize: 13 }}>
        {text}
      </Typography.Paragraph>
      {actions}
    </div>
  )

  return (
    <div
      style={{
        background: '#fff',
        borderRadius: 16,
        padding: '20px 24px',
        marginBottom: 16,
      }}
    >
      <Flex justify="space-between" align="center" gap={12} wrap style={{ marginBottom: 16 }}>
        <div>
          <Typography.Title level={5} style={{ margin: 0 }}>
            {tr(`Настройка магазина · ${n} из 3`, `Doʻkonni sozlash · ${n} / 3`)}
          </Typography.Title>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            {onlyDelivery ? tr('Осталась доставка — без неё покупатели видят «Магазин не доставляет»', 'Yetkazib berish qoldi — usiz xaridorlar «Doʻkon yetkazib bermaydi» ni koʻradi') : tr('Заполните, чтобы покупатели нашли магазин в приложении', 'Xaridorlar doʻkonni ilovada topishi uchun toʻldiring')}
          </Typography.Text>
        </div>
        <Flex gap={6}>
          {[0, 1, 2].map((i) => (
            <span
              key={i}
              style={{
                width: 60,
                height: 6,
                borderRadius: 3,
                background: i < n ? '#17B26A' : '#EAECF0',
              }}
            />
          ))}
        </Flex>
      </Flex>
      <div className="sm-setup-check">
        {col(
          s.steps.store,
          tr('Магазин и адрес', 'Doʻkon va manzil'),
          s.steps.store
            ? [st.address, st.phone && st.phone.replace(/^\+998(\d\d)(\d{3})(\d\d)(\d\d)$/, '+998 $1 $2 $3 $4')].filter(Boolean).join(' · ')
            : tr('Поставьте точку на карте — без неё покупатели не найдут магазин', 'Xaritada nuqta qoʻying — usiz xaridorlar doʻkonni topa olmaydi'),
          <Button type={s.steps.store ? 'link' : 'primary'} style={s.steps.store ? { padding: 0, color: '#E11D2A' } : undefined} onClick={() => go(1)}>
            {s.steps.store ? tr('Изменить', 'Tahrirlash') : tr('Указать', 'Koʻrsatish')}
          </Button>,
        )}
        {col(
          s.steps.hours,
          tr('Часы работы', 'Ish vaqti'),
          s.steps.hours ? hoursText(s.working_hours) : tr('Укажите, когда магазин открыт', 'Doʻkon qachon ochiqligini koʻrsating'),
          <Button type={s.steps.hours ? 'link' : 'primary'} style={s.steps.hours ? { padding: 0, color: '#E11D2A' } : undefined} onClick={() => go(2)}>
            {s.steps.hours ? tr('Изменить', 'Tahrirlash') : tr('Указать', 'Koʻrsatish')}
          </Button>,
        )}
        {col(
          s.steps.delivery,
          tr('Доставка', 'Yetkazib berish'),
          s.steps.delivery ? tr('Готово', 'Tayyor') : onlyDelivery ? tr('Сейчас покупатели видят «Магазин не доставляет»', 'Hozir xaridorlar «Doʻkon yetkazib bermaydi» ni koʻradi') : tr('Радиус, цена и за сколько привезёте', 'Radius, narx va qancha vaqtda yetkazasiz'),
          !s.steps.delivery && (
            <Flex vertical gap={10} align="flex-start">
              {s.wishes > 0 && (
                <span
                  style={{
                    background: '#FDECED',
                    color: '#E11D2A',
                    borderRadius: 8,
                    padding: '4px 10px',
                    fontWeight: 700,
                    fontSize: 13,
                  }}
                >
                  <HeartFilled />{' '}
                  {tr(
                    `${buyers(s.wishes)} рядом ${s.wishes % 10 === 1 && s.wishes % 100 !== 11 ? 'ждёт' : 'ждут'} доставку`,
                    `Yaqin atrofda ${buyers(s.wishes)} yetkazib berishni kutmoqda`,
                  )}
                </span>
              )}
              <Flex gap={12} align="center" wrap>
                <Button type="primary" onClick={() => go(3)} disabled={!s.steps.store}>
                  {tr('Настроить доставку', 'Yetkazib berishni sozlash')}
                </Button>
                <Button
                  type="link"
                  style={{ padding: 0, color: '#667085' }}
                  loading={busy}
                  onClick={() =>
                    void run(
                      () => setupApi.delivery({ store_id: st.id, mode: 'none' }),
                      () => void qc.invalidateQueries({ queryKey: [KEY] }),
                    )
                  }
                >
                  {tr('Без доставки', 'Yetkazib berishsiz')}
                </Button>
              </Flex>
            </Flex>
          ),
        )}
      </div>
    </div>
  )
}
