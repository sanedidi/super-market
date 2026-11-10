// «Фото из сети» (Figma «Супер-админ · Фото из сети — «чужие» фото каталога
// заменяются настоящими», ФС1 список и ФС2 карточка замены). Super Market сам
// проверяет фото общего каталога; чертёж, крышку, оборот, не тот товар —
// заменяет настоящим фото: Open Food Facts по штрихкоду, потом картинки Google.
// Gemini сверяет найденное с товаром и делает чистое фото. Старое фото не
// удаляется — «Вернуть старое» ставит его обратно.
import { useState, type CSSProperties, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Alert, App, Button, Card, Drawer, Empty, Flex, Image, Input, Popconfirm, Progress, Segmented, Space, Table, Typography, Upload } from 'antd'
import {
  ArrowRightOutlined,
  CaretRightOutlined,
  CheckCircleFilled,
  CheckOutlined,
  CloseCircleFilled,
  ExportOutlined,
  FileSearchOutlined,
  LoadingOutlined,
  LockOutlined,
  PauseOutlined,
  QuestionCircleFilled,
  ReloadOutlined,
  RollbackOutlined,
  ScanOutlined,
  SearchOutlined,
  SyncOutlined,
  UploadOutlined,
} from '@ant-design/icons'
import { Link } from 'react-router-dom'
import dayjs from 'dayjs'
import { LoadError, PageTitle, api, errorText, useItem } from '@sm/shared'
import { useInterval, useUrlState } from '../hooks'
import { usd } from '../photoJob'

// ─── Данные ───────────────────────────────────────────────────────────────

type Status = 'queued' | 'processing' | 'ok' | 'replaced' | 'pending' | 'not_found' | 'failed' | 'reverted'
type Source = '' | 'off' | 'google' | 'own'

interface Candidate {
  url: string
  source: 'off' | 'google'
  page: string
  title: string
  ok: boolean
  note: string
  best: boolean
}

interface WebJob {
  id: string
  product_id: string
  name: string
  barcode: string
  origin: 'ikpu' | 'store' | 'catalog'
  category: string
  status: Status
  reason: string
  reason_text: string
  old_image: string
  found_source: Source
  found_image: string
  found_page: string
  result_image: string
  candidates: Candidate[]
  verdict: { seen_name?: string; name?: boolean | null; brand?: boolean | null; barcode?: boolean | null; volume?: boolean | null }
  placed: boolean
  attempts: number
  max_attempts: number
  next_at: string | null
  error: string
  cost_usd: number
  updated_at: string
  finished_at: string | null
}

interface Summary {
  configured: boolean
  enabled: boolean
  has_serper: boolean
  total: number
  checked: number
  bad: number
  replaced: number
  replaced_off: number
  replaced_google: number
  replaced_own: number
  not_found: number
  pending: number
  reverted: number
  failed: number
  queued: number
  per_hour: number
  eta_hours: number | null
  month_cost_usd: number
  month_search_usd: number
  month_gemini_usd: number
  limit_usd: number
  paused: boolean
  // Сначала — товары, которые есть в магазинах; остальной каталог — после одобрения.
  stores_total: number
  stores_checked: number
  stores_queued: number
  rest: boolean
  rest_queued: number
  avg_cost_usd: number
}

interface Page {
  items: WebJob[]
  total: number
}

// ─── Тексты и цвета ───────────────────────────────────────────────────────

const C = {
  ink: '#101828',
  text: '#344054',
  mute: '#667085',
  faint: '#98A2B3',
  line: '#EAECF0',
  red: '#D92D20',
  redInk: '#B42318',
  redBg: '#FEF3F2',
  green: '#067647',
  greenBg: '#ECFDF3',
  grayBg: '#F2F4F7',
  soft: '#F9FAFB',
}

const ORIGIN: Record<WebJob['origin'], string> = { ikpu: 'из каталога ИКПУ', store: 'от магазина', catalog: 'каталог' }
const SOURCE: Record<Exclude<Source, ''>, string> = { off: 'Open Food Facts', google: 'Google', own: 'Своё фото' }

function sourceHint(j: WebJob): string {
  switch (j.found_source) {
    case 'off':
      return 'по штрихкоду · бесплатно'
    case 'google':
      return j.verdict.volume ? 'совпали название и объём' : 'совпали название и бренд'
    case 'own':
      return 'в сети не нашли — лицевая сторона из своего фото'
    default:
      return ''
  }
}

const time = (v: string) => (dayjs(v).isSame(dayjs(), 'day') ? `сегодня, ${dayjs(v).format('HH:mm')}` : dayjs(v).format('DD.MM.YYYY, HH:mm'))

function statusOf(j: WebJob): { label: string; bg: string; fg: string; icon: ReactNode; sub: string } {
  switch (j.status) {
    case 'replaced':
      return { label: 'Заменено', bg: C.greenBg, fg: C.green, icon: <CheckCircleFilled />, sub: time(j.finished_at ?? j.updated_at) }
    case 'pending':
      return { label: 'Ждёт решения', bg: C.grayBg, fg: C.ink, icon: <QuestionCircleFilled />, sub: 'нажмите «Поставить»' }
    case 'not_found':
      return {
        label: 'Не нашли',
        bg: C.redBg,
        fg: C.redInk,
        icon: <CloseCircleFilled />,
        sub: j.next_at ? `попытка ${j.attempts} из ${j.max_attempts}, ещё раз ${dayjs(j.next_at).format('DD.MM HH:mm')}` : `${j.attempts} попытки`,
      }
    case 'failed':
      return { label: 'Ошибка', bg: C.redBg, fg: C.redInk, icon: <CloseCircleFilled />, sub: j.error || 'повторите' }
    case 'processing':
      return { label: 'Ищем', bg: C.grayBg, fg: C.text, icon: <LoadingOutlined />, sub: 'Gemini проверяет и рисует' }
    case 'queued':
      return { label: 'В очереди', bg: C.grayBg, fg: C.text, icon: <SyncOutlined />, sub: j.error ? `повтор: ${j.error}` : 'ждёт очереди' }
    case 'reverted':
      return { label: 'Вернули старое', bg: C.grayBg, fg: C.text, icon: <RollbackOutlined />, sub: 'больше не трогаем' }
    default:
      return { label: 'В порядке', bg: C.greenBg, fg: C.green, icon: <CheckCircleFilled />, sub: 'фото того товара' }
  }
}

const running = (j: WebJob) => j.status === 'queued' || j.status === 'processing'

// ─── Мелкие части ─────────────────────────────────────────────────────────

function Pill({ label, bg, fg, icon }: { label: ReactNode; bg: string; fg: string; icon?: ReactNode }) {
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        padding: '2px 8px',
        borderRadius: 999,
        background: bg,
        color: fg,
        fontSize: 12,
        fontWeight: 600,
        maxWidth: '100%',
      }}
    >
      {icon}
      <span style={{ overflowWrap: 'anywhere' }}>{label}</span>
    </span>
  )
}

function Photo({ src, size, empty }: { src?: string; size: number; empty?: ReactNode }) {
  const box: CSSProperties = { width: size, height: size, borderRadius: size > 100 ? 12 : 8, border: `1px solid ${C.line}`, background: '#fff', flex: 'none' }
  if (!src)
    return (
      <Flex align="center" justify="center" style={{ ...box, background: C.soft, color: C.faint, fontSize: 12, textAlign: 'center', padding: 6 }}>
        {empty ?? '—'}
      </Flex>
    )
  return (
    <div style={box} onClick={(e) => e.stopPropagation()}>
      <Image src={src} width={size - 2} height={size - 2} style={{ objectFit: 'contain', borderRadius: box.borderRadius }} />
    </div>
  )
}

function Stat({ title, value, sub, color, active, onClick }: { title: string; value: ReactNode; sub: string; color?: string; active?: boolean; onClick?: () => void }) {
  return (
    <Card
      size="small"
      hoverable={!!onClick}
      onClick={onClick}
      style={{ flex: 1, minWidth: 180, borderRadius: 12, borderColor: active ? C.ink : C.line }}
      styles={{ body: { padding: '14px 16px' } }}
    >
      <Typography.Text style={{ color: C.mute, fontWeight: 600, fontSize: 12 }}>{title}</Typography.Text>
      <div style={{ fontSize: 24, fontWeight: 800, color: color ?? C.ink, lineHeight: '34px' }}>{value}</div>
      <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{sub}</Typography.Text>
    </Card>
  )
}

const n = (v: number | undefined) => (v === undefined ? '—' : v.toLocaleString('ru-RU'))

/** «Как это работает»: 4 шага. */
function HowItWorks() {
  const steps: [ReactNode, string, string][] = [
    [<ScanOutlined />, 'Проверка', 'Gemini смотрит каждое фото каталога: тот ли это товар и лицевая ли сторона'],
    [<SearchOutlined />, 'Поиск', 'Сначала Open Food Facts по штрихкоду (бесплатно), потом картинки Google'],
    [<FileSearchOutlined />, 'Сверка', 'Gemini сверяет название, бренд и штрихкод — чужое фото не ставим'],
    [<CheckCircleFilled />, 'Чистое фото', 'Белый фон, лицевая сторона, квадрат — как в «Настройках»'],
  ]
  return (
    <Card style={{ borderRadius: 12, marginBottom: 16 }} styles={{ body: { padding: '14px 16px' } }}>
      <Flex gap={12} align="center" wrap>
        {steps.map(([icon, title, text], i) => (
          <Flex key={title} gap={10} align="center" style={{ flex: 1, minWidth: 220 }}>
            <Flex align="center" justify="center" style={{ width: 32, height: 32, borderRadius: 8, background: C.redBg, color: C.red, flex: 'none', fontSize: 16 }}>
              {icon}
            </Flex>
            <div style={{ flex: 1 }}>
              <Typography.Text strong>
                {i + 1}. {title}
              </Typography.Text>
              <div style={{ color: C.mute, fontSize: 12 }}>{text}</div>
            </div>
            {i < steps.length - 1 && <ArrowRightOutlined style={{ color: C.faint }} />}
          </Flex>
        ))}
      </Flex>
    </Card>
  )
}

/** Вкладки «ИИ для фото». */
export function PhotoTabs({ active }: { active: 'settings' | 'store' | 'web' }) {
  const tab = (key: typeof active, to: string, label: string) => (
    <Link
      to={to}
      style={{
        padding: '0 0 10px',
        fontWeight: active === key ? 700 : 600,
        color: active === key ? C.red : C.mute,
        borderBottom: `2px solid ${active === key ? C.red : 'transparent'}`,
      }}
    >
      {label}
    </Link>
  )
  return (
    <Flex gap={24} style={{ padding: '4px 16px 0' }}>
      {tab('settings', '/ai-photo', 'Настройки')}
      {tab('store', '/ai-photo/store', 'Фото магазинов')}
      {tab('web', '/ai-photo/web', 'Фото из сети')}
    </Flex>
  )
}

// ─── Порядок проверки (ФС4) ───────────────────────────────────────────────

function StepDot({ n, state, label }: { n: number; state: 'done' | 'active' | 'wait'; label: string }) {
  return (
    <Flex gap={8} align="center">
      <Flex
        align="center"
        justify="center"
        style={{
          minWidth: 22,
          height: 22,
          padding: '0 6px',
          borderRadius: 999,
          fontSize: 12,
          fontWeight: 800,
          background: state === 'done' ? C.green : state === 'active' ? C.red : C.grayBg,
          color: state === 'wait' ? C.mute : '#fff',
        }}
      >
        {state === 'done' ? <CheckOutlined /> : n}
      </Flex>
      <Typography.Text style={{ fontWeight: state === 'wait' ? 600 : 700, color: state === 'wait' ? C.mute : C.ink }}>{label}</Typography.Text>
    </Flex>
  )
}

/** Карточка над таблицей: сначала товары магазинов, остальной каталог — после одобрения (Figma ФС4). */
function QueueOrder({ s, live, busy, onRest }: { s: Summary; live: boolean; busy: boolean; onRest: (v: boolean) => void }) {
  const storesDone = s.stores_queued === 0
  const restCount = s.rest_queued
  const eta = (h: number | null | undefined) => (h == null ? '' : h < 1 ? ' · меньше часа' : ` · ещё ≈ ${Math.ceil(h)} ч`)
  const restHours = s.per_hour > 0 ? restCount / s.per_hour : null
  const steps = (
    <Flex gap={16} align="center" wrap>
      <StepDot n={1} state={storesDone ? 'done' : 'active'} label="Товары, которые есть в магазинах" />
      <ArrowRightOutlined style={{ color: C.faint }} />
      <StepDot n={2} state={s.rest ? (restCount > 0 ? 'active' : 'done') : 'wait'} label="Остальной каталог" />
    </Flex>
  )
  const pct = (done: number, total: number) => (total > 0 ? Math.round((done / total) * 100) : 100)
  const pause = s.paused ? (
    <Typography.Text style={{ color: C.redInk, fontSize: 12 }}>
      Пауза: дошли до лимита {usd(s.limit_usd)} в месяц — проверка продолжится в следующем месяце или после увеличения лимита.
    </Typography.Text>
  ) : null

  let body: ReactNode
  if (!storesDone) {
    // А · идут товары магазинов.
    body = (
      <>
        <Flex gap={8} align="center" wrap>
          <SyncOutlined spin={live} style={{ color: C.red }} />
          <Typography.Text strong style={{ color: C.text, flex: 1 }}>
            Товары магазинов: {n(s.stores_checked)} из {n(s.stores_total)} фото проверено{eta(s.eta_hours)}
          </Typography.Text>
          {!s.rest && <Pill label="остальной каталог — после одобрения" bg="#FFFAEB" fg="#B54708" icon={<LockOutlined />} />}
        </Flex>
        <Progress percent={pct(s.stores_checked, s.stores_total)} showInfo={false} strokeColor={C.red} trailColor={C.grayBg} size="small" style={{ margin: 0 }} />
        <Typography.Text style={{ color: C.mute, fontSize: 12 }}>
          Сначала проверяем фото товаров, которые уже продаются в магазинах, — их видят покупатели. Новый товар магазина встаёт в начало очереди.
          {!s.rest && restCount > 0 ? ` Остальной каталог (${n(restCount)} фото) ждёт вашего одобрения.` : ''}
        </Typography.Text>
      </>
    )
  } else if (!s.rest) {
    // Б · товары магазинов готовы — ждём одобрения.
    const cost = s.avg_cost_usd > 0 ? `≈ ${usd(s.avg_cost_usd * restCount)} по среднему расходу (${usd(s.avg_cost_usd)} за фото) · ` : ''
    body = (
      <>
        <Flex gap={8} align="center">
          <CheckCircleFilled style={{ color: C.green }} />
          <Typography.Text strong style={{ color: C.text }}>
            Товары магазинов готовы: {n(s.stores_checked)} фото проверено
          </Typography.Text>
        </Flex>
        {restCount > 0 ? (
          <Flex gap={16} align="center" wrap style={{ background: C.soft, borderRadius: 10, padding: '14px 16px' }}>
            <div style={{ flex: 1, minWidth: 280 }}>
              <Typography.Text strong>Остальной каталог: {n(restCount)} фото — товары, которых пока нет ни в одном магазине</Typography.Text>
              <div style={{ color: C.mute, fontSize: 12 }}>
                {cost}
                {restHours !== null ? `≈ ${Math.ceil(restHours)} ч · ` : ''}лимит в месяц {usd(s.limit_usd)} — дойдёт до лимита, встанет на паузу до следующего месяца
              </div>
            </div>
            <Popconfirm
              title="Начать остальной каталог?"
              description={`${n(restCount)} фото. Новые товары магазинов всё равно пойдут первыми.`}
              okText="Начать"
              cancelText="Нет"
              onConfirm={() => onRest(true)}
            >
              <Button type="primary" icon={<CaretRightOutlined />} loading={busy}>
                Начать остальной каталог
              </Button>
            </Popconfirm>
          </Flex>
        ) : (
          <Typography.Text style={{ color: C.mute, fontSize: 12 }}>Остального каталога нет — все фото с товарами магазинов.</Typography.Text>
        )}
      </>
    )
  } else {
    // В · остальной каталог одобрен и идёт.
    const checkedRest = Math.max(s.checked - s.stores_checked, 0)
    const totalRest = checkedRest + restCount
    body = (
      <>
        <Flex gap={8} align="center" wrap>
          {restCount > 0 ? <SyncOutlined spin={live} style={{ color: C.red }} /> : <CheckCircleFilled style={{ color: C.green }} />}
          <Typography.Text strong style={{ color: C.text, flex: 1 }}>
            {restCount > 0
              ? `Остальной каталог: ${n(checkedRest)} из ${n(totalRest)} фото${eta(s.eta_hours)}. Новые товары магазинов — всё равно первыми`
              : `Вся база проверена: ${n(s.checked)} фото. Новые товары проверяются сразу — товары магазинов первыми.`}
          </Typography.Text>
          {restCount > 0 && (
            <Button icon={<PauseOutlined />} loading={busy} onClick={() => onRest(false)}>
              Остановить
            </Button>
          )}
        </Flex>
        {restCount > 0 && <Progress percent={pct(checkedRest, totalRest)} showInfo={false} strokeColor={C.red} trailColor={C.grayBg} size="small" style={{ margin: 0 }} />}
      </>
    )
  }
  return (
    <Card style={{ borderRadius: 12, marginBottom: 16 }} styles={{ body: { padding: '16px 20px' } }}>
      <Space direction="vertical" size={12} style={{ width: '100%' }}>
        {steps}
        {body}
        {pause}
      </Space>
    </Card>
  )
}

// ─── Карточка замены (ФС2) ────────────────────────────────────────────────

function Verdict({ j }: { j: WebJob }) {
  const v = j.verdict
  const row = (label: string, ok: boolean | null | undefined, text: string) =>
    ok === undefined || ok === null ? null : (
      <Flex gap={8} align="center" key={label}>
        {ok ? <CheckCircleFilled style={{ color: C.green }} /> : <CloseCircleFilled style={{ color: C.red }} />}
        <Typography.Text strong style={{ color: C.text }}>
          {label}
        </Typography.Text>
        <Typography.Text style={{ color: C.mute }}>{text}</Typography.Text>
      </Flex>
    )
  const rows = [
    row('Название', v.name, v.seen_name || j.name),
    row('Штрихкод', v.barcode ?? (j.found_source === 'off' ? true : null), `${j.barcode} — найдено по нему`),
    row('Бренд', v.brand, v.brand ? 'совпадает' : 'другой'),
    row('Объём', v.volume, v.volume ? 'совпадает' : 'другой'),
  ].filter(Boolean)
  if (!rows.length) return null
  return (
    <Space direction="vertical" size={10} style={{ width: '100%', background: C.soft, borderRadius: 12, padding: '14px 16px' }}>
      <Typography.Text strong>{j.found_source === 'own' ? 'Сверка Gemini — в сети подходящего фото не нашлось' : 'Сверка Gemini — найденное фото того же товара'}</Typography.Text>
      {rows}
    </Space>
  )
}

function JobDrawer({ id, onClose, onChanged }: { id: string | null; onClose: () => void; onChanged: () => void }) {
  const { message } = App.useApp()
  const item = useItem<WebJob>(id ? `/admin/ai-photo/web/jobs/${id}` : null)
  const j = item.data
  const [busy, setBusy] = useState<string | null>(null)
  useInterval(() => void item.refetch(), 3000, !!j && running(j))

  const act = async (what: string, path: string, body?: unknown, ok?: string) => {
    setBusy(what)
    try {
      await api.post(`/admin/ai-photo/web/jobs/${id}/${path}`, body)
      if (ok) message.success(ok)
      await item.refetch()
      onChanged()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }
  const uploadOwn = async (file: File) => {
    setBusy('upload')
    try {
      const url = await api.upload(file, file.name)
      await api.post(`/admin/ai-photo/web/jobs/${id}/pick`, { image: url })
      message.success('Своё фото — делаем чистое')
      await item.refetch()
      onChanged()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }

  const col = (title: string, photo: ReactNode, pill: ReactNode, cap: string) => (
    <Space direction="vertical" size={8} style={{ width: 160 }}>
      <Typography.Text style={{ color: C.mute, fontSize: 12, fontWeight: 700 }}>{title}</Typography.Text>
      {photo}
      {pill}
      <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{cap}</Typography.Text>
    </Space>
  )
  const arrow = <ArrowRightOutlined style={{ color: C.faint, marginTop: 100 }} />
  const others = (j?.candidates ?? []).filter((c) => !c.best || j?.status !== 'replaced')

  return (
    <Drawer open={!!id} onClose={onClose} width={640} title={j?.name ?? ' '} destroyOnClose>
      {item.error && <LoadError error={item.error} retry={() => item.refetch()} />}
      {j && (
        <Space direction="vertical" size={20} style={{ width: '100%' }}>
          <Typography.Text style={{ color: C.mute, marginTop: -12 }}>
            {[j.barcode, j.category, ORIGIN[j.origin]].filter(Boolean).join(' · ')}{' '}
            <Link to={`/products/${j.product_id}`}>
              Товар <ExportOutlined />
            </Link>
          </Typography.Text>

          <Flex gap={10} align="flex-start">
            {col(
              'БЫЛО',
              <Photo src={j.old_image} size={160} empty="нет фото" />,
              j.reason && j.reason !== 'ok' ? <Pill label={j.reason_text} bg={C.redBg} fg={C.redInk} /> : null,
              j.reason === 'ok' ? 'Gemini: фото того товара, лицевая сторона' : j.reason ? `Gemini: ${j.reason_text.toLowerCase()}` : 'ещё не проверено',
            )}
            {arrow}
            {col(
              j.found_source === 'own' ? 'СДЕЛАЛИ ИЗ СВОЕГО' : 'НАШЛИ В СЕТИ',
              <Photo src={j.found_source === 'own' ? j.old_image : j.found_image} size={160} empty={running(j) ? <LoadingOutlined /> : 'не нашли'} />,
              j.found_source ? <Pill label={SOURCE[j.found_source]} bg={C.grayBg} fg={C.text} icon={<SearchOutlined />} /> : null,
              j.found_source ? sourceHint(j) : j.status === 'not_found' ? 'ни по штрихкоду, ни в Google' : '',
            )}
            {arrow}
            {col(
              'СТАЛО',
              <Photo src={j.result_image} size={160} empty={running(j) ? <LoadingOutlined /> : 'старое фото оставлено'} />,
              (() => {
                const s = statusOf(j)
                return <Pill label={s.label} bg={s.bg} fg={s.fg} icon={s.icon} />
              })(),
              j.result_image ? (j.placed ? 'после Gemini · стоит у товара' : 'после Gemini · у товара не стоит') : statusOf(j).sub,
            )}
          </Flex>
          {j.found_page && (
            <Typography.Text style={{ color: C.mute, fontSize: 12, marginTop: -8 }}>
              Источник:{' '}
              <a href={j.found_page} target="_blank" rel="noreferrer noopener">
                {j.found_page.replace(/^https?:\/\//, '').slice(0, 70)}
              </a>
            </Typography.Text>
          )}

          <Verdict j={j} />

          {others.length > 0 && (
            <Space direction="vertical" size={10} style={{ width: '100%' }}>
              <Typography.Text strong>{j.status === 'replaced' ? 'Другие найденные фото' : 'Найденные фото'}</Typography.Text>
              <Flex gap={12} wrap>
                {others.map((c) => {
                  const i = j.candidates.indexOf(c)
                  return (
                    <Space key={i} direction="vertical" size={6} style={{ width: 110 }}>
                      <Popconfirm
                        title="Поставить это фото?"
                        description="Gemini сделает из него чистое фото"
                        okText="Поставить"
                        cancelText="Нет"
                        onConfirm={() => act('pick' + i, 'pick', { candidate: i }, 'Делаем чистое фото')}
                      >
                        <div style={{ cursor: 'pointer', width: 96, height: 96, borderRadius: 8, border: `1px solid ${C.line}`, overflow: 'hidden', background: '#fff' }}>
                          {busy === 'pick' + i ? (
                            <Flex align="center" justify="center" style={{ height: '100%' }}>
                              <LoadingOutlined />
                            </Flex>
                          ) : (
                            <img src={c.url} alt="" referrerPolicy="no-referrer" style={{ width: '100%', height: '100%', objectFit: 'contain' }} />
                          )}
                        </div>
                      </Popconfirm>
                      <Typography.Text style={{ fontSize: 12, color: c.ok ? C.green : C.mute }}>
                        {c.source === 'off' ? 'Open Food Facts' : 'Google'} · {c.note || (c.ok ? 'подошло' : 'не подошло')}
                      </Typography.Text>
                    </Space>
                  )
                })}
              </Flex>
              <Typography.Text style={{ color: C.mute, fontSize: 12 }}>Клик по фото — поставить его вместо найденного.</Typography.Text>
            </Space>
          )}

          {j.error && j.status !== 'not_found' && <Alert type="warning" showIcon message={j.error} />}

          <Flex gap={8} wrap align="center">
            {j.placed && j.old_image && (
              <Button icon={<RollbackOutlined />} loading={busy === 'revert'} onClick={() => act('revert', 'revert', undefined, 'Старое фото вернули')}>
                Вернуть старое
              </Button>
            )}
            {!j.placed && j.result_image && (
              <Button type="primary" loading={busy === 'apply'} onClick={() => act('apply', 'apply', undefined, 'Фото поставили')}>
                Поставить
              </Button>
            )}
            <Button icon={<SearchOutlined />} loading={busy === 'research'} disabled={running(j)} onClick={() => act('research', 'research', undefined, 'Ищем ещё')}>
              Поискать ещё
            </Button>
            <Upload accept="image/jpeg,image/png,image/webp" showUploadList={false} customRequest={({ file }) => void uploadOwn(file as File)} disabled={running(j)}>
              <Button icon={<UploadOutlined />} loading={busy === 'upload'} disabled={running(j)}>
                Загрузить своё
              </Button>
            </Upload>
            <div style={{ flex: 1 }} />
            <Button type="primary" style={{ background: C.ink }} onClick={onClose}>
              Готово
            </Button>
          </Flex>
          <Typography.Text style={{ color: C.mute, fontSize: 12 }}>
            Старое фото не удаляется — остаётся в хранилище, «Вернуть старое» ставит его обратно. Выбрать другое фото — клик по нему в «Найденных».
            {j.cost_usd > 0 ? ` Расход на этот товар: ${usd(j.cost_usd)}.` : ''}
          </Typography.Text>
        </Space>
      )}
    </Drawer>
  )
}

// ─── Страница (ФС1) ───────────────────────────────────────────────────────

export function WebPhotos() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [status, setStatus] = useUrlState('status')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const [page, setPage] = useState(1)
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const pageSize = 20

  const sum = useItem<Summary>('/admin/ai-photo/web/summary')
  const s = sum.data
  const list = useItem<Page>('/admin/ai-photo/web/jobs', { status: status ?? '', q: q ?? '', limit: pageSize, offset: (page - 1) * pageSize })
  const live = !!s && s.enabled && s.configured && !s.paused && s.queued > 0
  useInterval(
    () => {
      void sum.refetch()
      void list.refetch()
    },
    8000,
    live || (list.data?.items ?? []).some(running),
  )

  const refresh = async () => {
    await qc.invalidateQueries({ queryKey: ['/admin/ai-photo/web/summary'] })
    await qc.invalidateQueries({ queryKey: ['/admin/ai-photo/web/jobs'] })
  }
  const filter = (v: string | undefined) => {
    setPage(1)
    setStatus(v)
  }
  const post = async (key: string, path: string, body?: unknown, ok?: (r: any) => string) => {
    setBusy(key)
    try {
      const r = await api.post(path, body)
      if (ok) message.success(ok(r))
      await refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }

  const seg = (v: string, label: string, count?: number) => ({ value: v, label: count === undefined ? label : `${label} · ${n(count)}` })
  const setRest = async (v: boolean) => {
    setBusy('rest')
    try {
      await api.put('/admin/ai-photo/web', { rest: v })
      message.success(v ? 'Остальной каталог — в работе' : 'Остальной каталог остановлен: снова только товары магазинов')
      await refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }

  const columns = [
    {
      title: 'Товар',
      key: 'name',
      width: 260,
      render: (_: unknown, j: WebJob) => (
        <div>
          <Typography.Text strong>{j.name}</Typography.Text>
          <div style={{ color: C.mute, fontSize: 12 }}>{[j.barcode, ORIGIN[j.origin]].filter(Boolean).join(' · ')}</div>
        </div>
      ),
    },
    {
      title: 'Было',
      key: 'old',
      width: 160,
      render: (_: unknown, j: WebJob) => (
        <Space direction="vertical" size={6} style={{ maxWidth: 150 }}>
          <Photo src={j.old_image} size={64} />
          {j.reason && j.reason !== 'ok' && <Pill label={j.reason_text} bg={C.redBg} fg={C.redInk} />}
        </Space>
      ),
    },
    {
      title: 'Нашли в сети',
      key: 'found',
      width: 200,
      render: (_: unknown, j: WebJob) =>
        j.found_source ? (
          <Flex gap={10} align="center">
            <Photo src={j.found_source === 'own' ? j.old_image : j.found_image} size={64} />
            <div>
              <Typography.Text strong style={{ fontSize: 13 }}>
                {SOURCE[j.found_source]}
              </Typography.Text>
              <div style={{ color: C.mute, fontSize: 12 }}>{sourceHint(j)}</div>
            </div>
          </Flex>
        ) : j.status === 'not_found' ? (
          <Flex gap={8} align="center">
            <SearchOutlined style={{ color: C.faint, fontSize: 18 }} />
            <div>
              <Typography.Text strong style={{ fontSize: 13 }}>
                Не нашли
              </Typography.Text>
              <div style={{ color: C.mute, fontSize: 12 }}>ни по штрихкоду, ни в Google</div>
            </div>
          </Flex>
        ) : running(j) ? (
          <Typography.Text style={{ color: C.mute }}>
            <LoadingOutlined /> ищем…
          </Typography.Text>
        ) : (
          <Typography.Text style={{ color: C.faint }}>—</Typography.Text>
        ),
    },
    {
      title: 'Стало',
      key: 'result',
      width: 120,
      render: (_: unknown, j: WebJob) =>
        j.result_image ? (
          <Space direction="vertical" size={4}>
            <Photo src={j.result_image} size={64} />
            <Typography.Text style={{ color: C.mute, fontSize: 11 }}>{j.placed ? 'стоит у товара' : 'не поставлено'}</Typography.Text>
          </Space>
        ) : (
          <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{j.status === 'not_found' || j.status === 'failed' ? 'Старое фото оставлено' : '—'}</Typography.Text>
        ),
    },
    {
      title: 'Статус',
      key: 'status',
      width: 170,
      render: (_: unknown, j: WebJob) => {
        const st = statusOf(j)
        return (
          <Space direction="vertical" size={4}>
            <Pill label={st.label} bg={st.bg} fg={st.fg} icon={st.icon} />
            <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{st.sub}</Typography.Text>
          </Space>
        )
      },
    },
    {
      title: '',
      key: 'act',
      align: 'right' as const,
      render: (_: unknown, j: WebJob) => (
        <div onClick={(e) => e.stopPropagation()}>
          {j.placed && j.old_image ? (
            <Button icon={<RollbackOutlined />} loading={busy === j.id} onClick={() => post(j.id, `/admin/ai-photo/web/jobs/${j.id}/revert`, undefined, () => 'Старое фото вернули')}>
              Вернуть старое
            </Button>
          ) : !j.placed && j.result_image ? (
            <Button type="primary" style={{ background: C.ink }} loading={busy === j.id} onClick={() => post(j.id, `/admin/ai-photo/web/jobs/${j.id}/apply`, undefined, () => 'Фото поставили')}>
              Поставить
            </Button>
          ) : j.status === 'not_found' || j.status === 'failed' ? (
            <Button type="primary" style={{ background: C.ink }} icon={<UploadOutlined />} onClick={() => setOpen(j.id)}>
              Загрузить своё
            </Button>
          ) : null}
        </div>
      ),
    },
  ]

  return (
    <>
      <PageTitle
        title="Фото из сети"
        tabs={
          <>
            <Typography.Text type="secondary" style={{ display: 'block', padding: '0 16px 8px' }}>
              Super Market сам находит в каталоге фото не того товара — чертёж, крышку, оборот со штрихкодом — и ставит настоящее фото из интернета
            </Typography.Text>
            <PhotoTabs active="web" />
          </>
        }
      />
      <LoadError error={sum.error || list.error} retry={refresh} />
      {s && !s.configured && (
        <Alert style={{ marginBottom: 16 }} type="warning" showIcon message={<>Gemini не подключён — проверка не идёт. <Link to="/ai-photo">Подключить →</Link></>} />
      )}
      {s && s.configured && !s.enabled && (
        <Alert style={{ marginBottom: 16 }} type="info" showIcon message={<>Проверка фото каталога выключена. <Link to="/ai-photo#web">Включить в настройках →</Link></>} />
      )}
      {s && s.configured && !s.has_serper && (
        <Alert style={{ marginBottom: 16 }} type="info" showIcon message={<>Нет ключа Serper — ищем только в Open Food Facts. <Link to="/ai-photo#web">Добавить ключ →</Link></>} />
      )}

      <HowItWorks />

      <Flex gap={12} wrap style={{ marginBottom: 16 }}>
        <Stat title="Проверено фото" value={n(s?.checked)} sub={s ? `из ${n(s.total)} в каталоге` : ''} active={status === 'all'} onClick={() => filter(status === 'all' ? undefined : 'all')} />
        <Stat title="Плохих фото" value={n(s?.bad)} color={s?.bad ? C.red : undefined} sub="чертёж, крышка, оборот…" active={!status} onClick={() => filter(undefined)} />
        <Stat
          title="Заменено"
          value={n(s?.replaced)}
          sub={s ? `Open Food Facts ${n(s.replaced_off)} · Google ${n(s.replaced_google)}${s.replaced_own ? ` · своё ${n(s.replaced_own)}` : ''}` : ''}
          active={status === 'replaced'}
          onClick={() => filter(status === 'replaced' ? undefined : 'replaced')}
        />
        <Stat title="Не нашли" value={n(s?.not_found)} sub="оставлено старое — загрузите своё" active={status === 'not_found'} onClick={() => filter(status === 'not_found' ? undefined : 'not_found')} />
        <Stat
          title="Расход за месяц"
          value={s ? usd(s.month_cost_usd) : '—'}
          color={s?.paused ? C.red : undefined}
          sub={s ? `поиск Google ${usd(s.month_search_usd)} · Gemini ${usd(s.month_gemini_usd)}` : ''}
        />
      </Flex>

      {s && s.total > 0 && <QueueOrder s={s} live={live} busy={busy === 'rest'} onRest={setRest} />}

      <Card style={{ borderRadius: 12 }} styles={{ body: { padding: 0 } }}>
        <Flex gap={8} wrap align="center" style={{ padding: '12px 16px' }}>
          <Segmented
            value={status ?? ''}
            onChange={(v) => filter((v as string) || undefined)}
            options={[
              seg('', 'Все плохие', s?.bad),
              seg('replaced', 'Заменено', s?.replaced),
              seg('not_found', 'Не нашли', s?.not_found),
              ...(s?.pending ? [seg('pending', 'Ждут решения', s.pending)] : []),
              seg('queued', 'В очереди', s?.queued),
              ...(s?.reverted ? [seg('reverted', 'Вернули старое', s.reverted)] : []),
            ]}
          />
          <div style={{ flex: 1 }} />
          <Input.Search
            allowClear
            placeholder="Название или штрихкод"
            style={{ width: 240 }}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onSearch={(v) => {
              setPage(1)
              setQ(v.trim() || undefined)
            }}
          />
          <Button
            icon={<ReloadOutlined />}
            loading={busy === 'retry'}
            disabled={!s?.not_found && !s?.failed}
            onClick={() => post('retry', '/admin/ai-photo/web/retry-not-found', undefined, (r) => (r.queued ? `Снова ищем: ${r.queued}` : 'Повторять нечего'))}
          >
            Повторить «Не нашли»
          </Button>
        </Flex>
        <Table<WebJob>
          rowKey="id"
          size="middle"
          columns={columns}
          dataSource={list.data?.items ?? []}
          loading={list.isLoading}
          scroll={{ x: 1000 }}
          locale={{ emptyText: <Empty description={status === 'queued' ? 'Очередь пуста' : 'Здесь пока пусто'} /> }}
          onRow={(j) => ({ onClick: () => setOpen(j.id), style: { cursor: 'pointer' } })}
          pagination={{
            current: page,
            pageSize,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            onChange: setPage,
            showTotal: (t) => `Показано ${Math.min(pageSize, list.data?.items.length ?? 0)} из ${n(t)} · клик по строке открывает карточку «Было → Нашли → Стало»`,
          }}
        />
      </Card>

      <JobDrawer id={open} onClose={() => setOpen(null)} onChanged={refresh} />
    </>
  )
}
