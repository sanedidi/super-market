// «Фото магазинов» (Figma «Супер-админ · Фото магазинов — результаты»): что
// Super Market сделал магазинам за месяц — счётчики, причины «Не вышло»,
// список фото с фильтрами и карточка фото. Временные ошибки Google Super
// Market повторяет сам; «Повторить» — сразу, «Переделать» — новое фото
// (идёт в лимит сети).
import { useState, type CSSProperties, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { App, Button, Card, DatePicker, Drawer, Empty, Flex, Image, Input, Segmented, Select, Space, Table, Tag, Typography } from 'antd'
import { ArrowLeftOutlined, LoadingOutlined, ReloadOutlined } from '@ant-design/icons'
import { Link, useNavigate } from 'react-router-dom'
import dayjs from 'dayjs'
import { LoadError, PageTitle, api, dateTime, errorText, useItem } from '@sm/shared'
import { useInterval, useUrlState } from '../hooks'
import { usd } from '../photoJob'

// ─── Данные ───────────────────────────────────────────────────────────────

type JobStatus = 'queued' | 'processing' | 'done' | 'failed' | 'retry' | 'skipped'
type Kind = 'new' | 'lines' | 'old'

export interface StoreJob {
  id: string
  status: JobStatus
  reason: string
  code: string
  kind: Kind
  network: { id: string; name: string; blocked: boolean }
  store: { id: string; name: string; active: boolean } | null
  employee: string
  product_id: string | null
  new_item_id: string | null
  name: string
  barcode: string
  sources: string[]
  result: string | null
  attempts: number
  max_attempts: number
  retry_at: string | null
  cost_usd: number | null
  model: string
  redo: boolean
  placed: '' | 'product' | 'card' | 'own'
  created_at: string
  finished_at: string | null
  log: { at: string; kind: string; text: string }[]
}

interface Reason {
  code: string
  count: number
  waiting: number
  retryable: boolean
}

export interface StoreSummary {
  month: string
  total: number
  done: number
  failed: number
  retrying: number
  queued: number
  processing: number
  skipped: number
  skipped_by: Record<string, number>
  cost_usd: number
  networks: { id: string; name: string; blocked: boolean; photos: number }[]
  reasons: Reason[]
}

interface Page {
  items: StoreJob[]
  total: number
}

interface StoreTop {
  network_id: string
  used: number
  limit: number | null
}

// ─── Тексты ───────────────────────────────────────────────────────────────

/** Причины «Не вышло»: заголовок и что делать. */
export const REASONS: Record<string, [string, string]> = {
  rate_limit: ['Gemini: превышен лимит запросов (429)', 'Временная ошибка Google. Super Market повторяет сам через 2 мин, до 3 раз; можно повторить сейчас.'],
  unavailable: ['Gemini временно недоступен', 'Сбой на стороне Google. Super Market повторяет сам через 2 мин, до 3 раз; можно повторить сейчас.'],
  timeout: ['Google не ответил вовремя', 'Нет ответа или связи. Super Market повторяет сам через 2 мин, до 3 раз; можно повторить сейчас.'],
  auth: ['Ключ Gemini не подходит', 'Проверьте подключение на «ИИ для фото» и повторите.'],
  model: ['Модель недоступна или не выбрана', 'Выберите модель на «ИИ для фото» и повторите.'],
  refused: ['Gemini не нарисовал фото', 'Обычно помогает «Повторить». Если снова не вышло — фото магазина плохое.'],
  unreadable: ['Фото магазина не читается', 'Файл фото повреждён или пустой. Магазину нужно переснять товар.'],
  not_found: ['Фото нет в хранилище', 'Фото не загрузилось или удалено. Магазину нужно переснять товар.'],
  stale: ['Не успели — сервер перезапускали', 'Можно повторить.'],
  save: ['Не удалось сохранить готовое фото', 'Сбой хранилища — повторите.'],
  other: ['Другая ошибка', 'Текст ошибки — в карточке фото.'],
}
const reasonTitle = (code: string) => (REASONS[code] ?? REASONS.other)[0]
/** Причины, где «Повторить» не поможет — магазину нужно переснять. */
const RESHOOT = new Set(['unreadable', 'not_found'])

const SKIPPED: Record<string, string> = {
  limit: 'Закончился лимит тарифа сети на месяц',
  off: '«Фото для магазинов» были выключены',
  cancelled: 'Магазин выбрал своё фото или товар из базы',
  blocked: 'Сеть заблокирована или магазин выключен — фото не делаются',
}

const KINDS: Record<Kind, [string, string, string]> = {
  new: ['Новый товар', '#EFF8FF', '#175CD3'],
  lines: ['Инвентаризация', '#F0F9FF', '#026AA2'],
  old: ['Старое фото', '#F2F4F7', '#344054'],
}
const KIND_FROM: Record<Kind, string> = {
  new: '«Начало работы» → Новый товар по фото',
  lines: '«Начало работы» → Инвентаризация',
  old: '«Начало работы» → старое фото (снято до нормализации)',
}

const C = {
  ink: '#101828',
  mute: '#667085',
  faint: '#98A2B3',
  line: '#EAECF0',
  purple: '#6941C6',
  purpleBg: '#F4F3FF',
  purpleLine: '#D9D6FE',
  green: '#067647',
  greenBg: '#ECFDF3',
  red: '#D92D20',
  redBg: '#FEF3F2',
  redLine: '#FECDCA',
  grayBg: '#F2F4F7',
  grayInk: '#344054',
}

const time = (v: string) => (dayjs(v).isSame(dayjs(), 'day') ? dayjs(v).format('HH:mm') : dayjs(v).format('DD.MM HH:mm'))

/** Статус фото: метка и пояснение. */
function statusOf(j: StoreJob): { label: string; bg: string; fg: string; text: string } {
  switch (j.status) {
    case 'done':
      return {
        label: 'Сделано',
        bg: C.greenBg,
        fg: C.green,
        text:
          j.placed === 'product'
            ? 'Стоит в товаре первым фото'
            : j.placed === 'card'
              ? 'В карточке «Новых» — ждёт проверки магазином'
              : 'В товаре его нет: магазин оставил своё фото или поменял',
      }
    case 'retry':
      return {
        label: 'Не вышло',
        bg: C.redBg,
        fg: C.red,
        text: `${reasonTitle(j.code)}. Попытка ${j.attempts} из ${j.max_attempts}${j.retry_at ? `, повтор в ${dayjs(j.retry_at).format('HH:mm')}` : ''}`,
      }
    case 'failed':
      return { label: 'Не вышло', bg: C.redBg, fg: C.red, text: reasonTitle(j.code || 'other') }
    case 'processing':
      return { label: 'Делается', bg: C.purpleBg, fg: C.purple, text: 'Gemini рисует фото' }
    case 'queued':
      return { label: 'В очереди', bg: C.grayBg, fg: C.grayInk, text: j.kind === 'old' ? 'Старые фото идут после новых' : 'Ждёт очереди' }
    default:
      return { label: 'Пропущено', bg: C.grayBg, fg: C.grayInk, text: SKIPPED[j.reason] ?? 'Фото не делали' }
  }
}

// ─── Мелкие части ─────────────────────────────────────────────────────────

function Pill({ label, bg, fg, dot }: { label: ReactNode; bg: string; fg: string; dot?: boolean }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '1px 8px', borderRadius: 10, background: bg, color: fg, fontSize: 12, fontWeight: 700, whiteSpace: 'nowrap' }}>
      {dot && <span style={{ width: 6, height: 6, borderRadius: 3, background: fg }} />}
      {label}
    </span>
  )
}

function Dot({ color }: { color: string }) {
  return <span style={{ width: 8, height: 8, borderRadius: 4, background: color, flex: 'none', display: 'inline-block' }} />
}

/** Фото Super Market: готовое, «делается», «не вышло» или пусто. */
function After({ j, size }: { j: StoreJob; size: number }) {
  const box: CSSProperties = { width: size, height: size, borderRadius: size > 60 ? 12 : 8, flex: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center' }
  if (j.result) return <Image src={j.result} width={size} height={size} style={{ objectFit: 'contain', borderRadius: box.borderRadius, border: `1px solid ${C.line}`, background: '#fff' }} />
  if (j.status === 'processing') return <div style={{ ...box, background: C.purpleBg, border: `1px dashed ${C.purpleLine}`, color: C.purple }}><LoadingOutlined /></div>
  if (size > 60 && (j.status === 'failed' || j.status === 'retry'))
    return (
      <div style={{ ...box, background: C.redBg, border: `1px dashed ${C.redLine}`, flexDirection: 'column', textAlign: 'center' }}>
        <Typography.Text strong style={{ color: C.red, fontSize: 15 }}>
          Не вышло
        </Typography.Text>
        <Typography.Text style={{ color: C.red, fontSize: 12 }}>у товара осталось
          <br />
          фото магазина</Typography.Text>
      </div>
    )
  return <div style={{ ...box, background: C.grayBg, color: C.faint }}>—</div>
}

function Thumb({ src, size }: { src?: string; size: number }) {
  if (!src) return <div style={{ width: size, height: size, borderRadius: 8, background: C.grayBg }} />
  return <Image src={src} width={size} height={size} style={{ objectFit: 'cover', borderRadius: size > 60 ? 12 : 8 }} />
}

function Stat({ title, value, sub, dot, color, active, onClick }: { title: string; value: ReactNode; sub: string; dot: string; color?: string; active?: boolean; onClick?: () => void }) {
  return (
    <Card
      size="small"
      hoverable={!!onClick}
      onClick={onClick}
      style={{ flex: 1, minWidth: 170, borderRadius: 16, borderColor: active ? dot : C.line, borderWidth: active ? 2 : 1 }}
      styles={{ body: { padding: '14px 18px' } }}
    >
      <Flex gap={6} align="center">
        <Dot color={dot} />
        <Typography.Text style={{ color: C.mute, fontWeight: 600, fontSize: 13 }}>{title}</Typography.Text>
      </Flex>
      <div style={{ fontSize: 28, fontWeight: 800, color: color ?? C.ink, lineHeight: '40px' }}>{value}</div>
      <Typography.Text style={{ color: C.faint, fontSize: 12 }}>{sub}</Typography.Text>
    </Card>
  )
}

// ─── Страница ─────────────────────────────────────────────────────────────

export function StorePhotos() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const [month, setMonth] = useUrlState('month')
  const [status, setStatus] = useUrlState('status')
  const [network, setNetwork] = useUrlState('network_id')
  const [kind, setKind] = useUrlState('kind')
  const [code, setCode] = useUrlState('code')
  const [q, setQ] = useUrlState('q')
  const [page, setPage] = useState(1)
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const pageSize = 20

  const sum = useItem<StoreSummary>('/admin/ai-photo/store/summary', { month: month ?? '' })
  const s = sum.data
  const live = (s?.queued ?? 0) + (s?.retrying ?? 0) > 0
  const params = { month: month ?? '', status: status ?? '', network_id: network ?? '', kind: kind ?? '', code: code ?? '', q: q ?? '', limit: pageSize, offset: (page - 1) * pageSize }
  const list = useItem<Page>('/admin/ai-photo/store/jobs', params)
  const settings = useItem<{ store_top: StoreTop[] }>('/admin/ai-photo')
  // Пока фото делаются — обновляем сами.
  useInterval(() => {
    void sum.refetch()
    void list.refetch()
  }, 5000, live)

  const filter = (set: (v: string | undefined) => void) => (v: string | undefined) => {
    setPage(1)
    set(v)
  }
  const refresh = async () => {
    await qc.invalidateQueries({ queryKey: ['/admin/ai-photo/store/summary'] })
    await qc.invalidateQueries({ queryKey: ['/admin/ai-photo/store/jobs'] })
    await qc.invalidateQueries({ queryKey: ['/admin/ai-photo'] })
  }
  const retryFailed = async (reason?: string) => {
    setBusy(reason ?? 'all')
    try {
      const r = await api.post<{ queued: number }>('/admin/ai-photo/store/retry-failed', { month: month ?? '', code: reason ?? '', network_id: network ?? '' })
      message.success(r.queued ? `Снова в очереди: ${r.queued}` : 'Повторять нечего')
      await refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }
  const retryOne = async (id: string) => {
    setBusy(id)
    try {
      await api.post(`/admin/ai-photo/store/jobs/${id}/retry`)
      message.success('Снова в очереди')
      await refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }

  const failedNow = s ? s.failed : 0
  const seg = (v: string | undefined, label: string, n?: number) => ({ value: v ?? '', label: n === undefined ? label : `${label} · ${n}` })
  const skippedSub = s
    ? Object.entries(s.skipped_by)
        .map(([k, n]) => `${{ limit: 'лимит', off: 'выключено', cancelled: 'своё фото', blocked: 'сеть заблокирована' }[k] ?? k} — ${n}`)
        .join(' · ') || 'лимит, выключено, своё фото'
    : ''

  return (
    <>
      <Link to="/ai-photo" style={{ color: C.mute, fontSize: 13 }}>
        <ArrowLeftOutlined /> ИИ для фото
      </Link>
      <PageTitle title="Фото магазинов">
        <Space wrap>
          <DatePicker
            picker="month"
            allowClear={false}
            format="MMMM YYYY"
            value={month ? dayjs(month + '-01') : dayjs()}
            onChange={(d) => filter(setMonth)(d && !d.isSame(dayjs(), 'month') ? d.format('YYYY-MM') : undefined)}
            disabledDate={(d) => d.isAfter(dayjs(), 'month')}
          />
          <Button
            type="primary"
            icon={<ReloadOutlined />}
            style={{ background: C.purple }}
            disabled={!failedNow}
            loading={busy === 'all'}
            onClick={() => retryFailed()}
          >
            Повторить неудачные{failedNow ? ` · ${failedNow}` : ''}
          </Button>
        </Space>
      </PageTitle>
      <Typography.Paragraph style={{ color: C.mute, maxWidth: 900, marginTop: -8 }}>
        Чистые фото, которые Super Market сделал магазинам: новые товары по фото, инвентаризация и старые фото «Начала работы». Не вышло — у товара остаётся фото
        магазина.
      </Typography.Paragraph>
      <LoadError error={sum.error || list.error} retry={refresh} />

      <Flex gap={12} wrap style={{ marginBottom: 16 }}>
        <Stat title="Сделано" value={s?.done ?? '—'} sub={s ? `${usd(s.cost_usd)} · расход за месяц` : ''} dot="#17B26A" active={status === 'done'} onClick={() => filter(setStatus)(status === 'done' ? undefined : 'done')} />
        <Stat
          title="Не вышло"
          value={s?.failed ?? '—'}
          color={s?.failed ? C.red : undefined}
          sub={s?.retrying ? `повторяем сами — ${s.retrying}` : 'у товаров осталось фото магазина'}
          dot={C.red}
          active={status === 'failed'}
          onClick={() => filter(setStatus)(status === 'failed' ? undefined : 'failed')}
        />
        <Stat title="В очереди" value={s?.queued ?? '—'} sub={`делается сейчас — ${s?.processing ?? 0}`} dot="#7A5AF8" active={status === 'queued'} onClick={() => filter(setStatus)(status === 'queued' ? undefined : 'queued')} />
        <Stat title="Пропущено" value={s?.skipped ?? '—'} sub={skippedSub} dot={C.faint} active={status === 'skipped'} onClick={() => filter(setStatus)(status === 'skipped' ? undefined : 'skipped')} />
        <Stat title="Сетей" value={s?.networks.length ?? '—'} sub={s?.networks.map((n) => n.name).join(', ') || 'нет фото в этом месяце'} dot="#155EEF" />
      </Flex>

      {!!s?.reasons.length && (
        <Card style={{ borderRadius: 16, marginBottom: 16 }} styles={{ body: { padding: '16px 20px 8px' } }}>
          <Flex gap={8} align="center" style={{ marginBottom: 8 }}>
            <Typography.Text strong style={{ fontSize: 16 }}>
              Почему не вышло
            </Typography.Text>
            <Pill label={s.failed} bg={C.redBg} fg={C.red} />
          </Flex>
          {s.reasons.map((r) => {
            const [title, hint] = REASONS[r.code] ?? REASONS.other
            return (
              <Flex key={r.code} gap={12} align="center" style={{ borderTop: `1px solid ${C.line}`, padding: '10px 0' }}>
                <Dot color={C.red} />
                <div style={{ flex: 1, cursor: 'pointer' }} onClick={() => { setPage(1); setStatus('failed'); setCode(r.code) }}>
                  <Typography.Text strong>{title}</Typography.Text>
                  <div>
                    <Typography.Text style={{ color: C.mute, fontSize: 12 }}>
                      {hint}
                      {r.waiting ? ` Ждут повтора: ${r.waiting}.` : ''}
                    </Typography.Text>
                  </div>
                </div>
                <Typography.Text strong style={{ color: C.red, fontSize: 18 }}>
                  {r.count}
                </Typography.Text>
                {RESHOOT.has(r.code) ? (
                  <Button size="small" onClick={() => { setPage(1); setStatus('failed'); setCode(r.code) }}>
                    Показать {r.count}
                  </Button>
                ) : (
                  <Button size="small" loading={busy === r.code} onClick={() => retryFailed(r.code)} style={{ background: C.purpleBg, borderColor: C.purpleLine, color: C.purple, fontWeight: 700 }}>
                    Повторить {r.count}
                  </Button>
                )}
              </Flex>
            )
          })}
        </Card>
      )}

      <Flex gap={10} wrap align="center" style={{ marginBottom: 12 }}>
        <Segmented
          value={status ?? ''}
          onChange={(v) => filter(setStatus)((v as string) || undefined)}
          options={[
            seg(undefined, 'Все', s?.total),
            seg('done', 'Сделано', s?.done),
            seg('failed', 'Не вышло', s?.failed),
            seg('queued', 'В очереди', s?.queued),
            seg('skipped', 'Пропущено', s?.skipped),
          ]}
        />
        <Select
          style={{ width: 220 }}
          allowClear
          placeholder="Все сети"
          value={network}
          onChange={(v) => filter(setNetwork)(v)}
          options={(s?.networks ?? []).map((n) => ({ value: n.id, label: n.blocked ? `${n.name} · заблокирована` : n.name }))}
        />
        <Select
          style={{ width: 180 }}
          allowClear
          placeholder="Все виды"
          value={kind}
          onChange={(v) => filter(setKind)(v)}
          options={(Object.keys(KINDS) as Kind[]).map((k) => ({ value: k, label: KINDS[k][0] }))}
        />
        {code && (
          <Tag closable onClose={() => filter(setCode)(undefined)} style={{ padding: '4px 8px' }}>
            {reasonTitle(code)}
          </Tag>
        )}
        <Input.Search style={{ flex: 1, minWidth: 220 }} allowClear placeholder="Товар или штрихкод" defaultValue={q} onSearch={(v) => filter(setQ)(v.trim() || undefined)} />
      </Flex>

      <Card style={{ borderRadius: 16 }} styles={{ body: { padding: 0 } }}>
        <Table<StoreJob>
          rowKey="id"
          loading={list.isLoading}
          dataSource={list.data?.items ?? []}
          locale={{ emptyText: <Empty description="Фото за этот месяц нет" /> }}
          onRow={(j) => ({ onClick: () => setOpen(j.id), style: { cursor: 'pointer', background: j.status === 'failed' || j.status === 'retry' ? '#FFFBFA' : undefined } })}
          pagination={{
            current: page,
            pageSize,
            total: list.data?.total ?? 0,
            showSizeChanger: false,
            onChange: setPage,
            showTotal: (t, [a, b]) => `Показаны ${a}–${b} из ${t} · клик по строке открывает карточку фото`,
          }}
          columns={[
            {
              title: 'До → после',
              width: 120,
              render: (_, j) => (
                <Flex gap={4} align="center">
                  <Thumb src={j.sources[0]} size={40} />
                  <span style={{ color: C.faint, fontWeight: 700 }}>→</span>
                  <After j={j} size={40} />
                </Flex>
              ),
            },
            {
              title: 'Товар',
              render: (_, j) => (
                <>
                  <Typography.Text strong>{j.name || 'Без названия'}</Typography.Text>
                  <div>
                    <Typography.Text style={{ color: C.faint, fontSize: 12 }}>{j.barcode || '—'}</Typography.Text>
                  </div>
                </>
              ),
            },
            {
              title: 'Сеть · магазин',
              width: 180,
              render: (_, j) => (
                <>
                  <Typography.Text style={{ fontWeight: 600 }}>{j.network.name}</Typography.Text>
                  <div>
                    <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{j.store?.name ?? '—'}</Typography.Text>
                  </div>
                  {j.network.blocked && <Pill label="Заблокирована" bg={C.redBg} fg={C.red} />}
                  {!j.network.blocked && j.store && !j.store.active && <Pill label="Магазин выключен" bg={C.grayBg} fg={C.grayInk} />}
                </>
              ),
            },
            {
              title: 'Вид',
              width: 140,
              render: (_, j) => (
                <Flex gap={4} wrap>
                  <Pill label={KINDS[j.kind][0]} bg={KINDS[j.kind][1]} fg={KINDS[j.kind][2]} />
                  {j.redo && <Pill label="Переделать" bg={C.purpleBg} fg={C.purple} />}
                </Flex>
              ),
            },
            {
              title: 'Статус',
              width: 260,
              render: (_, j) => {
                const st = statusOf(j)
                return (
                  <>
                    <Pill label={st.label} bg={st.bg} fg={st.fg} dot />
                    <div>
                      <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{st.text}</Typography.Text>
                    </div>
                  </>
                )
              },
            },
            {
              title: 'Когда · цена',
              width: 110,
              render: (_, j) => (
                <>
                  <Typography.Text style={{ color: '#475467' }}>{time(j.created_at)}</Typography.Text>
                  <div>
                    <Typography.Text strong style={{ color: j.cost_usd ? C.ink : C.faint }}>
                      {j.cost_usd ? usd(j.cost_usd) : '—'}
                    </Typography.Text>
                  </div>
                </>
              ),
            },
            {
              title: '',
              width: 120,
              align: 'right',
              render: (_, j) =>
                j.status === 'failed' || j.status === 'retry' ? (
                  <Button
                    size="small"
                    loading={busy === j.id}
                    disabled={j.network.blocked}
                    onClick={(e) => {
                      e.stopPropagation()
                      void retryOne(j.id)
                    }}
                    style={{ background: C.purpleBg, borderColor: C.purpleLine, color: C.purple, fontWeight: 700 }}
                  >
                    Повторить
                  </Button>
                ) : j.status === 'done' && j.product_id ? (
                  <Button
                    type="link"
                    size="small"
                    onClick={(e) => {
                      e.stopPropagation()
                      navigate(`/products/${j.product_id}`)
                    }}
                  >
                    Товар →
                  </Button>
                ) : null,
            },
          ]}
        />
      </Card>

      <JobDrawer
        id={open}
        onClose={() => setOpen(null)}
        top={settings.data?.store_top ?? []}
        onChanged={refresh}
        onOpen={(id) => setOpen(id)}
      />
    </>
  )
}

// ─── Карточка фото ────────────────────────────────────────────────────────

const LOG_COLORS: Record<string, string> = { queued: '#98A2B3', error: C.red, failed: C.red, retry: '#7A5AF8', done: '#17B26A', skipped: '#98A2B3' }
const LOG_TEXT: Record<string, string> = {
  queued: 'Поставлено в очередь',
  error: 'Не вышло',
  failed: 'Не вышло',
  retry: 'Снова в очереди',
  done: 'Готово',
  skipped: 'Пропущено',
}

function JobDrawer({ id, onClose, top, onChanged, onOpen }: { id: string | null; onClose: () => void; top: StoreTop[]; onChanged: () => Promise<void>; onOpen: (id: string) => void }) {
  const { message } = App.useApp()
  const { data: j, isLoading, error, refetch } = useItem<StoreJob>(id ? `/admin/ai-photo/store/jobs/${id}` : null)
  const [busy, setBusy] = useState(false)
  const live = j && (j.status === 'queued' || j.status === 'processing' || j.status === 'retry')
  useInterval(() => void refetch(), 4000, !!live)

  const act = async (path: string, ok: string) => {
    setBusy(true)
    try {
      const r = await api.post<StoreJob>(path)
      message.success(ok)
      await onChanged()
      if (r.id !== id) onOpen(r.id)
      else await refetch()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  const st = j ? statusOf(j) : null
  const lim = j ? top.find((t) => t.network_id === j.network.id) : undefined
  const failed = j && (j.status === 'failed' || j.status === 'retry')
  const row = (k: string, v: ReactNode) => (
    <Flex key={k} gap={12} style={{ borderBottom: `1px solid ${C.line}`, padding: '7px 0' }}>
      <Typography.Text style={{ color: C.mute, width: 150, flex: 'none' }}>{k}</Typography.Text>
      <Typography.Text style={{ fontWeight: 600 }}>{v}</Typography.Text>
    </Flex>
  )

  return (
    <Drawer open={id !== null} onClose={onClose} width={520} title="Фото товара" loading={isLoading}>
      <LoadError error={error} retry={refetch} />
      {j && st && (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <div>
            <Typography.Text strong style={{ fontSize: 16 }}>
              {j.name || 'Без названия'}
            </Typography.Text>
            <div>
              <Typography.Text style={{ color: C.faint }}>{j.barcode || '—'}</Typography.Text>
            </div>
            <Flex gap={6} style={{ marginTop: 6 }} wrap>
              <Pill label={KINDS[j.kind][0]} bg={KINDS[j.kind][1]} fg={KINDS[j.kind][2]} />
              <Pill label={st.label} bg={st.bg} fg={st.fg} dot />
              {j.redo && <Pill label="Переделать" bg={C.purpleBg} fg={C.purple} />}
            </Flex>
          </div>

          <Flex gap={16}>
            <div>
              <Typography.Text style={{ color: C.mute, fontWeight: 700, fontSize: 13 }}>Фото магазина · {j.sources.length}</Typography.Text>
              <Image.PreviewGroup>
                <Flex vertical gap={8} style={{ marginTop: 8 }}>
                  {j.sources.map((u) => (
                    <Thumb key={u} src={u} size={104} />
                  ))}
                </Flex>
              </Image.PreviewGroup>
            </div>
            <div>
              <Typography.Text style={{ color: C.mute, fontWeight: 700, fontSize: 13 }}>Фото Super Market</Typography.Text>
              <div style={{ marginTop: 8 }}>
                <After j={j} size={216} />
              </div>
            </div>
          </Flex>

          {failed && (
            <div style={{ background: C.redBg, border: `1px solid ${C.redLine}`, borderRadius: 12, padding: '12px 14px' }}>
              <Typography.Text strong style={{ color: C.red }}>
                {reasonTitle(j.code || 'other')}
              </Typography.Text>
              <div>
                <Typography.Text style={{ color: '#912018', fontSize: 13 }}>
                  {/[.!?]$/.test(j.reason.trim()) ? j.reason.trim() : `${j.reason.trim()}.`}
                  {j.status === 'retry' && j.retry_at ? ` Super Market повторит сам в ${dayjs(j.retry_at).format('HH:mm')} (попытка ${j.attempts + 1} из ${j.max_attempts}).` : ''}
                  {' '}За ошибку деньги не списываются и в лимит сети она не идёт.
                </Typography.Text>
              </div>
            </div>
          )}
          {j.status === 'done' && (
            <div style={{ background: C.greenBg, borderRadius: 12, padding: '12px 14px' }}>
              <Typography.Text strong style={{ color: C.green }}>
                {j.placed === 'product' ? 'Стоит в товаре первым фото' : j.placed === 'card' ? 'В карточке «Новых»' : 'В товаре его нет'}
              </Typography.Text>
              <div>
                <Typography.Text style={{ color: '#085D3A', fontSize: 13 }}>
                  {j.placed === 'product'
                    ? 'Фото магазина остались в товаре следующими — их видит модератор.'
                    : j.placed === 'card'
                      ? 'Магазин увидит «до / после», когда будет проверять карточку.'
                      : 'Магазин оставил своё фото или поменял фото товара.'}
                </Typography.Text>
              </div>
            </div>
          )}
          {j.status === 'skipped' && (
            <div style={{ background: C.grayBg, borderRadius: 12, padding: '12px 14px' }}>
              <Typography.Text strong>Пропущено</Typography.Text>
              <div>
                <Typography.Text style={{ color: C.mute, fontSize: 13 }}>{SKIPPED[j.reason] ?? 'Фото не делали'}</Typography.Text>
              </div>
            </div>
          )}

          <div>
            {row(
              'Сеть',
              <>
                {j.network.name} {j.network.blocked && <Pill label="Заблокирована" bg={C.redBg} fg={C.red} />}
              </>,
            )}
            {row('Магазин', j.store ? `${j.store.name}${j.store.active ? '' : ' (выключен)'}` : '—')}
            {row('Кто снял', j.employee || '—')}
            {row('Откуда', KIND_FROM[j.kind])}
            {row('Поставлено', dateTime(j.created_at))}
            {j.finished_at && row(j.status === 'done' ? 'Готово' : 'Закончено', dateTime(j.finished_at))}
            {row('Попыток', `${j.attempts} из ${j.max_attempts}`)}
            {row('Модель', j.model || '—')}
            {row('Цена', j.cost_usd ? usd(j.cost_usd) : '—')}
            {lim && row('Лимит сети', lim.limit === null ? `${lim.used} · без лимита` : `${lim.used} из ${lim.limit} в этом месяце`)}
          </div>

          {j.log.length > 0 && (
            <div>
              <Typography.Text style={{ color: C.mute, fontWeight: 700, fontSize: 13 }}>История</Typography.Text>
              {j.log.map((l, i) => (
                <Flex key={i} gap={10} align="baseline" style={{ marginTop: 6 }}>
                  <Dot color={LOG_COLORS[l.kind] ?? C.faint} />
                  <Typography.Text style={{ fontWeight: 600, color: '#475467', flex: 'none' }}>{time(l.at)}</Typography.Text>
                  <Typography.Text>
                    {LOG_TEXT[l.kind] ?? l.kind}
                    {l.text && l.kind !== 'skipped' ? `: ${l.text}` : l.kind === 'skipped' && l.text ? `: ${(SKIPPED[l.text] ?? l.text).toLowerCase()}` : ''}
                  </Typography.Text>
                </Flex>
              ))}
              {j.status === 'retry' && j.retry_at && (
                <Flex gap={10} align="baseline" style={{ marginTop: 6 }}>
                  <Dot color="#7A5AF8" />
                  <Typography.Text style={{ fontWeight: 600, color: '#475467' }}>{dayjs(j.retry_at).format('HH:mm')}</Typography.Text>
                  <Typography.Text>Повтор — ждёт</Typography.Text>
                </Flex>
              )}
            </div>
          )}

          <Flex gap={10} wrap style={{ borderTop: `1px solid ${C.line}`, paddingTop: 12 }}>
            {failed && (
              <Button type="primary" icon={<ReloadOutlined />} loading={busy} disabled={j.network.blocked} style={{ background: C.purple }} onClick={() => act(`/admin/ai-photo/store/jobs/${j.id}/retry`, 'Снова в очереди')}>
                Повторить сейчас
              </Button>
            )}
            {j.product_id && (
              <Link to={`/products/${j.product_id}`}>
                <Button>Открыть товар</Button>
              </Link>
            )}
            {j.status === 'done' && (
              <Button icon={<ReloadOutlined />} loading={busy} disabled={j.network.blocked} onClick={() => act(`/admin/ai-photo/store/jobs/${j.id}/redo`, 'Super Market переделывает фото')}>
                Переделать
              </Button>
            )}
            <Link to={`/networks?open=${j.network.id}`}>
              <Button type="link">Сеть →</Button>
            </Link>
          </Flex>
          {j.status === 'done' && (
            <Typography.Text style={{ color: C.faint, fontSize: 12 }}>«Переделать» — новое фото из тех же фото магазина, встанет на место этого. Идёт в лимит сети.</Typography.Text>
          )}
        </Space>
      )}
    </Drawer>
  )
}
