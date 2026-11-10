// «Автонормализация каталога» (Figma «Супер-админ · Автонормализация
// каталога»: АН1 главная, АН2 прогон, АН3 запуск вручную). Super Market сам
// чистит названия, исправляет категории, собирает вариации и решает по
// товарам и исправлениям от магазинов. Очереди на ручную проверку нет:
// страница показывает, что сделано, и даёт откатить прогон.
import { useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Alert, App, Button, Card, Checkbox, Empty, Flex, Input, Modal, Popconfirm, Progress, Segmented, Space, Switch, Table, Typography } from 'antd'
import {
  AuditOutlined,
  BlockOutlined,
  CheckCircleFilled,
  CheckOutlined,
  CloseOutlined,
  CopyOutlined,
  EditOutlined,
  EyeOutlined,
  FileTextOutlined,
  FolderOpenOutlined,
  InfoCircleOutlined,
  PlayCircleOutlined,
  PlusOutlined,
  RollbackOutlined,
  StopOutlined,
  SyncOutlined,
  WarningFilled,
} from '@ant-design/icons'
import { Link, useNavigate, useParams } from 'react-router-dom'
import dayjs from 'dayjs'
import { LoadError, PageTitle, api, errorText, useItem } from '@sm/shared'
import { useInterval, useUrlState } from '../hooks'

// ─── Данные ───────────────────────────────────────────────────────────────

interface Totals {
  names: number
  categories: number
  moves: number
  moves_kept: number
  groups: number
  in_groups: number
  approved: number
  rejected: number
  duplicates: number
  suggestions_approved: number
  suggestions_rejected: number
  ai_requests: number
  ai_cost_usd: number
  ai_cost_uzs: number
}

interface Settings {
  auto: boolean
  concurrency: number
  batch_size: number
  pending: number
  suggestions: number
  products: number
  totals: Totals
}

interface Stats {
  total: number
  processed: number
  names: number
  names_uz: number
  categories: number
  moves: number
  moves_kept: number
  groups: number
  in_groups: number
  joined: number
  approved: number
  rejected: number
  duplicates: number
  suggestions_approved: number
  suggestions_rejected: number
  failed: number
  input_tokens: number
  output_tokens: number
}

type RunStatus = 'running' | 'done' | 'failed' | 'interrupted' | 'applying' | 'rolled_back'

interface Run {
  id: string
  trigger: 'manual' | 'auto'
  section_ids: string[]
  sections: string[]
  only_new: boolean
  dry_run: boolean
  status: RunStatus
  applied: boolean
  stats: Partial<Stats>
  error: string
  started_at: string
  finished_at: string | null
  applied_at: string | null
  rolled_back_at: string | null
}

type Kind = 'name' | 'name_uz' | 'category' | 'variant_group' | 'moderation' | 'suggestion'

interface GroupItem {
  product_id: string
  weight: string
  flavor: string
}

interface Change {
  id: number
  product_id: string | null
  product_name: string
  image: string | null
  kind: Kind
  old: string
  new: string
  detail: {
    action?: 'create' | 'join'
    name?: string
    items?: GroupItem[]
    skipped?: boolean
    reason?: string
    duplicate_name?: string
  }
  applied: boolean
  reverted: boolean
}

interface Section {
  id: string
  name: string
  products: number
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
  amber: '#B54708',
  amberBg: '#FFFAEB',
  blue: '#175CD3',
  blueBg: '#EFF8FF',
  grayBg: '#F2F4F7',
  soft: '#F9FAFB',
}

const n = (v: number | undefined | null) => (v === undefined || v === null ? '—' : v.toLocaleString('ru-RU'))
const s = (st: Partial<Stats>, k: keyof Stats) => st[k] ?? 0

function when(v: string): string {
  const d = dayjs(v)
  if (d.isSame(dayjs(), 'day')) return `сегодня, ${d.format('HH:mm')}`
  if (d.isSame(dayjs().subtract(1, 'day'), 'day')) return `вчера, ${d.format('HH:mm')}`
  return d.format('DD.MM.YYYY, HH:mm')
}

function cost(t: Totals): string {
  if (t.ai_cost_usd > 0) return `≈ ${t.ai_cost_usd.toLocaleString('ru-RU', { maximumFractionDigits: t.ai_cost_usd < 10 ? 2 : 0 })} $`
  if (t.ai_cost_uzs > 0) return `≈ ${Math.round(t.ai_cost_uzs).toLocaleString('ru-RU')} сум`
  return '0'
}

/** Что в прогоне: разделы или весь каталог, новые товары. */
function scope(r: Run): ReactNode {
  if (r.trigger === 'auto') return `Новые товары · ${n(r.stats.total)}`
  const what = r.sections.length ? r.sections.join(', ') : 'Весь каталог'
  return r.only_new ? `${what} · только новые` : what
}

const live = (r: Run) => r.status === 'running' || r.status === 'applying'

function Pill({ label, bg, fg, icon }: { label: ReactNode; bg: string; fg: string; icon?: ReactNode }) {
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        padding: '2px 10px',
        borderRadius: 999,
        background: bg,
        color: fg,
        fontSize: 12,
        fontWeight: 700,
        whiteSpace: 'nowrap',
      }}
    >
      {icon}
      {label}
    </span>
  )
}

function RunStatusPill({ r }: { r: Run }) {
  switch (r.status) {
    case 'running': {
      const left = r.stats.total ? Math.max(0, r.stats.total - (r.stats.processed ?? 0)) : 0
      return <Pill label={left ? `Идёт · осталось ${n(left)}` : 'Идёт'} bg={C.blueBg} fg={C.blue} icon={<SyncOutlined spin />} />
    }
    case 'applying':
      return <Pill label="Применяется" bg={C.blueBg} fg={C.blue} icon={<SyncOutlined spin />} />
    case 'failed':
      return <Pill label="Ошибка" bg={C.redBg} fg={C.redInk} icon={<WarningFilled />} />
    case 'interrupted':
      return <Pill label="Прерван" bg={C.grayBg} fg={C.text} icon={<StopOutlined />} />
    case 'rolled_back':
      return <Pill label="Откачен" bg={C.grayBg} fg={C.mute} icon={<RollbackOutlined />} />
    default:
      if (r.dry_run && !r.applied) return <Pill label="Ждёт «Применить»" bg={C.amberBg} fg={C.amber} icon={<EyeOutlined />} />
      return <Pill label="Готово" bg={C.greenBg} fg={C.green} icon={<CheckOutlined />} />
  }
}

function Stat({ title, value, sub }: { title: string; value: ReactNode; sub: ReactNode }) {
  return (
    <Card size="small" style={{ flex: 1, minWidth: 180, borderRadius: 12 }} styles={{ body: { padding: '14px 16px' } }}>
      <Typography.Text style={{ color: C.mute, fontWeight: 600, fontSize: 12 }}>{title}</Typography.Text>
      <div style={{ fontSize: 24, fontWeight: 800, color: C.ink, lineHeight: '34px' }}>{value}</div>
      <Typography.Text style={{ color: C.mute, fontSize: 12 }}>{sub}</Typography.Text>
    </Card>
  )
}

const Sub = ({ children }: { children: ReactNode }) => <div style={{ color: C.mute, fontSize: 12 }}>{children}</div>

// ─── Действия с прогоном ──────────────────────────────────────────────────

function useRunActions(onDone: () => void) {
  const { message } = App.useApp()
  const [busy, setBusy] = useState<string | null>(null)
  const act = async (id: string, what: 'apply' | 'rollback') => {
    setBusy(id + what)
    try {
      await api.post(`/admin/catalog-norm/runs/${id}/${what}`)
      message.success(what === 'apply' ? 'Применяем изменения' : 'Прогон откачен')
      onDone()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }
  return { busy, act }
}

function RollbackButton({ busy, onClick, size }: { busy: boolean; onClick: () => void; size?: 'small' }) {
  return (
    <Popconfirm
      title="Откатить прогон?"
      description={
        <div style={{ maxWidth: 300 }}>
          Названия, категории, решения по товарам магазинов и группы вариаций вернутся как были. Что с тех пор поправили руками — не трогаем.
          Принятые исправления от магазинов не откатываются.
        </div>
      }
      okText="Откатить"
      okButtonProps={{ danger: true }}
      cancelText="Нет"
      onConfirm={onClick}
    >
      <Button size={size} icon={<RollbackOutlined />} loading={busy} onClick={(e) => e.stopPropagation()}>
        Откатить
      </Button>
    </Popconfirm>
  )
}

// ─── АН3 · Запустить вручную ──────────────────────────────────────────────

function StartModal({ open, onClose, settings }: { open: boolean; onClose: () => void; settings?: Settings }) {
  const { message } = App.useApp()
  const nav = useNavigate()
  const secs = useItem<{ items: Section[] }>(open ? '/admin/catalog-norm/sections' : null)
  const [picked, setPicked] = useState<string[]>([])
  const [dry, setDry] = useState(true)
  const [busy, setBusy] = useState(false)
  const items = secs.data?.items ?? []
  const all = picked.length === 0
  const count = all ? (settings?.products ?? items.reduce((a, x) => a + x.products, 0)) : items.filter((x) => picked.includes(x.id)).reduce((a, x) => a + x.products, 0)
  // ≈ 30 секунд на пачку; пачки идут параллельно.
  const minutes = settings ? Math.max(1, Math.ceil(((count / settings.batch_size) * 0.5) / settings.concurrency)) : 0
  const time = minutes >= 90 ? `≈ ${Math.round(minutes / 60)} ч` : `≈ ${minutes} мин`
  const perProduct = settings && settings.totals.ai_cost_usd > 0 && settings.totals.names > 0 ? settings.totals.ai_cost_usd / Math.max(settings.totals.names, 1) : 0

  const start = async () => {
    setBusy(true)
    try {
      const r = await api.post<Run>('/admin/catalog-norm/runs', { section_ids: picked, dry_run: dry })
      message.success(dry ? 'Запустили — изменения будут в журнале' : 'Запустили')
      onClose()
      nav(`/catalog/norm/${r.id}`)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  const toggle = (id: string, on: boolean) => setPicked((p) => (on ? [...p, id] : p.filter((x) => x !== id)))

  const row = (key: string, label: ReactNode, count: number, checked: boolean, onChange: (v: boolean) => void, bold?: boolean) => (
    <Flex key={key} align="center" gap={10} style={{ padding: '10px 14px', borderTop: `1px solid ${C.line}`, cursor: 'pointer' }} onClick={() => onChange(!checked)}>
      <Checkbox checked={checked} onClick={(e) => e.stopPropagation()} onChange={(e) => onChange(e.target.checked)} />
      <Typography.Text strong={bold} style={{ flex: 1, fontWeight: bold ? 700 : 600 }}>
        {label}
      </Typography.Text>
      <Typography.Text style={{ color: C.mute }}>{n(count)}</Typography.Text>
    </Flex>
  )

  return (
    <Modal
      open={open}
      onCancel={onClose}
      width={560}
      title="Запустить автонормализацию"
      okText="Запустить"
      okButtonProps={{ icon: <PlayCircleOutlined />, loading: busy, disabled: count === 0 }}
      cancelText="Отмена"
      onOk={start}
      destroyOnClose
    >
      <Typography.Text style={{ color: C.mute, fontWeight: 700, fontSize: 13 }}>Разделы</Typography.Text>
      <LoadError error={secs.error} retry={() => secs.refetch()} />
      <div style={{ border: `1px solid ${C.line}`, borderRadius: 12, overflow: 'hidden', margin: '8px 0 16px', maxHeight: 320, overflowY: 'auto' }}>
        <div style={{ marginTop: -1 }}>
          {row('all', 'Весь каталог', settings?.products ?? 0, all, (v) => v && setPicked([]), true)}
          {items.map((x) => row(x.id, x.name, x.products, picked.includes(x.id), (v) => toggle(x.id, v)))}
        </div>
      </div>
      <Flex gap={10} align="flex-start" style={{ background: C.soft, borderRadius: 12, padding: '12px 14px', marginBottom: 12, cursor: 'pointer' }} onClick={() => setDry(!dry)}>
        <Checkbox checked={dry} onClick={(e) => e.stopPropagation()} onChange={(e) => setDry(e.target.checked)} />
        <div>
          <Typography.Text strong>Только посмотреть</Typography.Text>
          <Sub>Изменения попадут в журнал «было → стало», в товары — после «Применить». Удобно для первого раза.</Sub>
        </div>
      </Flex>
      <Flex gap={8} align="flex-start">
        <InfoCircleOutlined style={{ color: C.mute, marginTop: 3 }} />
        <Typography.Text style={{ color: C.mute, fontSize: 12 }}>
          {n(count)} товаров · {time}
          {perProduct > 0 ? ` и ~${(perProduct * count).toLocaleString('ru-RU', { maximumFractionDigits: 0 })} $ ИИ` : ''}. Товары, которые правил человек, не
          трогаются. Один прогон за раз.
        </Typography.Text>
      </Flex>
    </Modal>
  )
}

// ─── АН1 · Главная ────────────────────────────────────────────────────────

function WhatItDoes() {
  const steps: [ReactNode, string, string][] = [
    [<EditOutlined />, 'Названия', 'У еды и напитков без типа ИКПУ: «Coca-Cola, 0,15 л». У непищевых — короткий тип: «Телевизор Samsung …»'],
    [<FolderOpenOutlined />, 'Категории', 'Внутри раздела — сразу. В другой раздел — только если второе мнение ИИ согласно'],
    [<BlockOutlined />, 'Вариации', 'Lay’s 90 г / 150 г × вкусы — группа собирается и подтверждается сама'],
    [<AuditOutlined />, 'Модерация', 'Товары от магазинов: одобрить, дубль общей базы или отклонить с причиной'],
    [<FileTextOutlined />, 'Исправления', '«Предложить исправление» от магазина — принять или отклонить, магазину пуш'],
  ]
  return (
    <Flex gap={12} wrap style={{ marginBottom: 16 }}>
      {steps.map(([icon, title, text]) => (
        <Card key={title} size="small" style={{ flex: 1, minWidth: 200, borderRadius: 12 }} styles={{ body: { padding: '14px 16px' } }}>
          <Flex gap={8} align="center" style={{ marginBottom: 6 }}>
            <Flex align="center" justify="center" style={{ width: 28, height: 28, borderRadius: 8, background: C.redBg, color: C.red, flex: 'none' }}>
              {icon}
            </Flex>
            <Typography.Text strong style={{ fontSize: 14 }}>
              {title}
            </Typography.Text>
          </Flex>
          <Sub>{text}</Sub>
        </Card>
      ))}
    </Flex>
  )
}

export function CatalogNorm() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const nav = useNavigate()
  const [trigger, setTrigger] = useUrlState('trigger')
  const [page, setPage] = useState(1)
  const [startOpen, setStartOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const pageSize = 20

  const set = useItem<Settings>('/admin/catalog-norm/settings')
  const runs = useItem<{ items: Run[]; total: number }>('/admin/catalog-norm/runs', { trigger: trigger ?? '', limit: pageSize, offset: (page - 1) * pageSize })
  const st = set.data
  const t = st?.totals
  const anyLive = (runs.data?.items ?? []).some(live)
  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['/admin/catalog-norm/settings'] })
    void qc.invalidateQueries({ queryKey: ['/admin/catalog-norm/runs'] })
  }
  useInterval(refresh, 4000, anyLive)
  const { busy, act } = useRunActions(refresh)

  const setAuto = async (auto: boolean) => {
    setSaving(true)
    try {
      await api.put('/admin/catalog-norm/settings', { auto })
      message.success(auto ? 'Автоматический режим включён' : 'Автоматический режим выключен')
      await set.refetch()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  const columns = [
    {
      title: 'Когда',
      key: 'when',
      width: 140,
      render: (_: unknown, r: Run) => (
        <div>
          <Typography.Text strong>{when(r.started_at)}</Typography.Text>
          <Sub>{r.trigger === 'auto' ? 'автоматически' : 'вручную'}</Sub>
        </div>
      ),
    },
    {
      title: 'Что',
      key: 'what',
      render: (_: unknown, r: Run) => (
        <div style={{ maxWidth: 300 }}>
          <Typography.Text strong>{scope(r)}</Typography.Text>
          {r.status === 'running' && r.stats.total ? (
            <Progress
              percent={Math.round(((r.stats.processed ?? 0) / r.stats.total) * 100)}
              showInfo={false}
              strokeColor={C.red}
              trailColor={C.grayBg}
              size="small"
              style={{ margin: '4px 0 0' }}
            />
          ) : r.dry_run ? (
            <Sub>только посмотреть · {n(r.stats.total)} товаров</Sub>
          ) : s(r.stats, 'suggestions_approved') + s(r.stats, 'suggestions_rejected') > 0 ? (
            <Sub>исправления от магазинов: {n(s(r.stats, 'suggestions_approved') + s(r.stats, 'suggestions_rejected'))}</Sub>
          ) : r.error ? (
            <Sub>{r.error}</Sub>
          ) : null}
        </div>
      ),
    },
    { title: 'Статус', key: 'status', width: 190, render: (_: unknown, r: Run) => <RunStatusPill r={r} /> },
    { title: 'Названия', key: 'names', width: 100, render: (_: unknown, r: Run) => n(s(r.stats, 'names')) },
    { title: 'Категории', key: 'cats', width: 100, render: (_: unknown, r: Run) => n(s(r.stats, 'categories')) },
    {
      title: 'Вариации',
      key: 'groups',
      width: 120,
      render: (_: unknown, r: Run) => {
        const g = s(r.stats, 'groups')
        const j = s(r.stats, 'joined')
        if (!g && !j) return '—'
        return [g ? `${n(g)} групп` : '', j ? `+${n(j)} в группы` : ''].filter(Boolean).join(' · ')
      },
    },
    {
      title: 'Магазины',
      key: 'stores',
      width: 170,
      render: (_: unknown, r: Run) => {
        const a = s(r.stats, 'approved')
        const d = s(r.stats, 'duplicates')
        const rj = s(r.stats, 'rejected')
        const sg = s(r.stats, 'suggestions_approved') + s(r.stats, 'suggestions_rejected')
        if (!a && !d && !rj && !sg) return '—'
        return (
          <div>
            {a + d + rj > 0 && <Typography.Text strong>{n(a + d + rj)} решено</Typography.Text>}
            <Sub>{[a ? `${n(a)} одобрено` : '', d ? `${n(d)} дубль` : '', rj ? `${n(rj)} отклонено` : '', sg ? `исправлений ${n(sg)}` : ''].filter(Boolean).join(' · ')}</Sub>
          </div>
        )
      },
    },
    {
      title: '',
      key: 'act',
      width: 130,
      align: 'right' as const,
      render: (_: unknown, r: Run) =>
        r.dry_run && !r.applied && r.status === 'done' ? (
          <Button type="primary" style={{ background: C.ink }} onClick={() => nav(`/catalog/norm/${r.id}`)}>
            Открыть
          </Button>
        ) : r.applied && r.status === 'done' ? (
          <RollbackButton busy={busy === r.id + 'rollback'} onClick={() => act(r.id, 'rollback')} />
        ) : null,
    },
  ]

  const pending = (st?.pending ?? 0) + (st?.suggestions ?? 0)
  return (
    <>
      <PageTitle
        title="Автонормализация каталога"
        extra={
          <Button icon={<PlayCircleOutlined />} onClick={() => setStartOpen(true)}>
            Запустить вручную
          </Button>
        }
        tabs={
          <Typography.Text type="secondary" style={{ display: 'block', padding: '0 16px 8px' }}>
            Super Market сам чистит названия, исправляет категории, собирает вариации и решает по товарам от магазинов. Каждое изменение — в журнале
            «было → стало», любой прогон можно откатить.
          </Typography.Text>
        }
      />
      <LoadError error={set.error || runs.error} retry={refresh} />

      <Card style={{ borderRadius: 12, marginBottom: 16 }} styles={{ body: { padding: '18px 20px' } }}>
        <Flex gap={16} align="center" wrap>
          <Switch checked={!!st?.auto} loading={saving || set.isLoading} onChange={setAuto} style={st?.auto ? { background: C.red } : undefined} />
          <div style={{ flex: 1, minWidth: 280 }}>
            <Typography.Text strong style={{ fontSize: 16 }}>
              Автоматически
            </Typography.Text>
            <Sub>
              Новые товары, товары магазинов на модерации и исправления карточек обрабатываются сами каждые 10 минут. Супер-админу ничего проверять не
              нужно.
            </Sub>
          </div>
          {st &&
            (pending === 0 ? (
              <Pill label="Всё обработано · новых товаров 0 · исправлений 0" bg={C.greenBg} fg={C.green} icon={<CheckCircleFilled />} />
            ) : (
              <Pill
                label={`Ждут: товаров ${n(st.pending)} · исправлений ${n(st.suggestions)}${st.auto ? '' : ' — включите авто-режим'}`}
                bg={st.auto ? C.blueBg : C.amberBg}
                fg={st.auto ? C.blue : C.amber}
                icon={st.auto ? <SyncOutlined /> : <WarningFilled />}
              />
            ))}
        </Flex>
      </Card>

      <WhatItDoes />

      <Flex gap={12} wrap style={{ marginBottom: 16 }}>
        <Stat title="названий исправлено" value={n(t?.names)} sub={st ? `у ${n(st.products)} товаров каталога` : ''} />
        <Stat title="категорий исправлено" value={n(t?.categories)} sub={t ? `в другой раздел: ${n(t.moves)} · второе мнение «нет»: ${n(t.moves_kept)}` : ''} />
        <Stat title="групп вариаций" value={n(t?.groups)} sub={t ? `${n(t.in_groups)} товаров, подтверждены сами` : ''} />
        <Stat
          title="товаров магазинов решено"
          value={n(t ? t.approved + t.duplicates + t.rejected : undefined)}
          sub={t ? `${n(t.approved)} одобрено · ${n(t.duplicates)} дублей · ${n(t.rejected)} отклонено` : ''}
        />
        <Stat title="расход ИИ" value={t ? cost(t) : '—'} sub={t ? `${n(t.ai_requests)} запросов` : ''} />
      </Flex>

      <Card style={{ borderRadius: 12 }} styles={{ body: { padding: 0 } }}>
        <Flex gap={8} wrap align="center" style={{ padding: '14px 20px' }}>
          <Typography.Text strong style={{ fontSize: 16, flex: 1 }}>
            Прогоны
          </Typography.Text>
          <Segmented
            value={trigger ?? ''}
            onChange={(v) => {
              setPage(1)
              setTrigger((v as string) || undefined)
            }}
            options={[
              { value: '', label: 'Все' },
              { value: 'manual', label: 'Ручные' },
              { value: 'auto', label: 'Автоматические' },
            ]}
          />
        </Flex>
        <Table<Run>
          rowKey="id"
          size="middle"
          columns={columns}
          dataSource={runs.data?.items ?? []}
          loading={runs.isLoading}
          scroll={{ x: 1000 }}
          locale={{ emptyText: <Empty description="Прогонов ещё не было — нажмите «Запустить вручную»" /> }}
          onRow={(r) => ({ onClick: () => nav(`/catalog/norm/${r.id}`), style: { cursor: 'pointer' } })}
          pagination={{
            current: page,
            pageSize,
            total: runs.data?.total ?? 0,
            showSizeChanger: false,
            hideOnSinglePage: true,
            onChange: setPage,
          }}
        />
        <div style={{ padding: '12px 20px 14px', color: C.mute, fontSize: 12 }}>
          Строка открывает журнал прогона. Пустые автоматические прогоны (ничего не изменили) не показываются. Один прогон за раз.
        </div>
      </Card>

      <StartModal open={startOpen} onClose={() => setStartOpen(false)} settings={st} />
    </>
  )
}

// ─── АН2 · Прогон ─────────────────────────────────────────────────────────

const KINDS: { key: Kind; label: string }[] = [
  { key: 'name', label: 'Названия' },
  { key: 'name_uz', label: 'Узбекские' },
  { key: 'category', label: 'Категории' },
  { key: 'variant_group', label: 'Вариации' },
  { key: 'moderation', label: 'Магазины' },
  { key: 'suggestion', label: 'Исправления' },
]

const section = (path: string) => path.split(' / ')[0]

function Thumb({ src }: { src: string | null }) {
  return (
    <Flex
      align="center"
      justify="center"
      style={{ width: 40, height: 40, borderRadius: 8, background: C.grayBg, flex: 'none', overflow: 'hidden', border: `1px solid ${C.line}` }}
    >
      {src ? <img src={src} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain', background: '#fff' }} /> : <FileTextOutlined style={{ color: C.faint }} />}
    </Flex>
  )
}

function ProductCell({ c }: { c: Change }) {
  return (
    <Flex gap={10} align="center">
      <Thumb src={c.image} />
      {c.product_id ? (
        <Link to={`/products/${c.product_id}`} onClick={(e) => e.stopPropagation()} style={{ color: C.ink, fontWeight: 700 }}>
          {c.product_name}
        </Link>
      ) : (
        <Typography.Text strong>{c.product_name}</Typography.Text>
      )}
    </Flex>
  )
}

function rowNote(c: Change): ReactNode {
  if (c.reverted && c.applied) return <Pill label="откачено" bg={C.grayBg} fg={C.mute} icon={<RollbackOutlined />} />
  if (c.reverted || c.detail.skipped) return <Pill label="пропущено — товар успели изменить" bg={C.grayBg} fg={C.mute} />
  return null
}

function columnsFor(kind: Kind) {
  const note = { title: '', key: 'note', width: 150, render: (_: unknown, c: Change) => rowNote(c) }
  switch (kind) {
    case 'name':
    case 'name_uz':
      return [
        {
          title: 'Было',
          key: 'old',
          render: (_: unknown, c: Change) => (
            <Flex gap={10} align="center">
              <Thumb src={c.image} />
              <Typography.Text delete style={{ color: C.mute }}>
                {c.old || '—'}
              </Typography.Text>
            </Flex>
          ),
        },
        {
          title: 'Стало',
          key: 'new',
          render: (_: unknown, c: Change) =>
            c.product_id ? (
              <Link to={`/products/${c.product_id}`} onClick={(e) => e.stopPropagation()} style={{ color: C.ink, fontWeight: 700 }}>
                {c.new}
              </Link>
            ) : (
              <Typography.Text strong>{c.new}</Typography.Text>
            ),
        },
        note,
      ]
    case 'category':
      return [
        { title: 'Товар', key: 'p', width: 340, render: (_: unknown, c: Change) => <ProductCell c={c} /> },
        { title: 'Было', key: 'old', render: (_: unknown, c: Change) => <Typography.Text style={{ color: C.mute }}>{c.old}</Typography.Text> },
        { title: 'Стало', key: 'new', render: (_: unknown, c: Change) => <Typography.Text strong>{c.new}</Typography.Text> },
        {
          title: 'Второе мнение',
          key: 'why',
          width: 170,
          render: (_: unknown, c: Change) =>
            section(c.old) === section(c.new) ? (
              <Pill label="тот же раздел" bg={C.blueBg} fg={C.blue} />
            ) : (
              <Pill label="Да · перенесён" bg={C.greenBg} fg={C.green} icon={<CheckOutlined />} />
            ),
        },
        note,
      ]
    case 'variant_group':
      return [
        {
          title: 'Группа',
          key: 'g',
          width: 280,
          render: (_: unknown, c: Change) => (
            <div>
              <Typography.Text strong>«{c.detail.name}»</Typography.Text>
              <div style={{ marginTop: 4 }}>
                {c.detail.action === 'join' ? (
                  <Pill label="добавлены в группу" bg={C.blueBg} fg={C.blue} icon={<PlusOutlined />} />
                ) : (
                  <Pill label="новая группа · подтверждена сама" bg={C.greenBg} fg={C.green} icon={<PlusOutlined />} />
                )}
              </div>
            </div>
          ),
        },
        {
          title: 'Товары: вес и вкус',
          key: 'items',
          render: (_: unknown, c: Change) => (
            <Flex gap={6} wrap>
              {(c.detail.items ?? []).map((it) => (
                <span key={it.product_id} style={{ border: `1px solid ${C.line}`, borderRadius: 8, padding: '3px 8px', fontSize: 12, fontWeight: 600 }}>
                  {[it.weight, it.flavor].filter(Boolean).join(' · ')}
                </span>
              ))}
            </Flex>
          ),
        },
        {
          title: '',
          key: 'note',
          width: 220,
          render: (_: unknown, c: Change) =>
            c.detail.skipped ? <Pill label="не собрана — товары уже в других группах" bg={C.grayBg} fg={C.mute} /> : rowNote(c),
        },
      ]
    case 'moderation':
      return [
        { title: 'Товар магазина', key: 'p', width: 360, render: (_: unknown, c: Change) => <ProductCell c={c} /> },
        {
          title: 'Решение',
          key: 'd',
          width: 210,
          render: (_: unknown, c: Change) =>
            c.new === 'approved' ? (
              <Pill label="Одобрен → в общей базе" bg={C.greenBg} fg={C.green} icon={<CheckOutlined />} />
            ) : c.detail.duplicate_name ? (
              <Pill label="Дубль" bg={C.amberBg} fg={C.amber} icon={<CopyOutlined />} />
            ) : (
              <Pill label="Отклонён" bg={C.redBg} fg={C.redInk} icon={<CloseOutlined />} />
            ),
        },
        { title: 'Причина для магазина', key: 'r', render: (_: unknown, c: Change) => <Sub>{c.detail.reason || '—'}</Sub> },
        note,
      ]
    case 'suggestion':
      return [
        { title: 'Товар', key: 'p', width: 360, render: (_: unknown, c: Change) => <ProductCell c={c} /> },
        {
          title: 'Исправление',
          key: 'd',
          width: 160,
          render: (_: unknown, c: Change) =>
            c.new === 'approved' ? (
              <Pill label="Принято" bg={C.greenBg} fg={C.green} icon={<CheckOutlined />} />
            ) : (
              <Pill label="Отклонено" bg={C.redBg} fg={C.redInk} icon={<CloseOutlined />} />
            ),
        },
        { title: 'Причина', key: 'r', render: (_: unknown, c: Change) => <Sub>{c.new === 'approved' ? 'изменено во всех магазинах' : c.detail.reason || '—'}</Sub> },
      ]
  }
}

export function CatalogNormRun() {
  const { id } = useParams()
  const qc = useQueryClient()
  const [kind, setKind] = useUrlState('kind', 'name')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const [page, setPage] = useState(1)
  const pageSize = 30

  const run = useItem<Run>(id ? `/admin/catalog-norm/runs/${id}` : null)
  const r = run.data
  const k = (kind as Kind) || 'name'
  const ch = useItem<{ items: Change[]; total: number; counts: Partial<Record<Kind, number>> }>(id ? `/admin/catalog-norm/runs/${id}/changes` : null, {
    kind: k,
    q: q ?? '',
    limit: pageSize,
    offset: (page - 1) * pageSize,
  })
  const refresh = () => {
    void qc.invalidateQueries({ queryKey: [`/admin/catalog-norm/runs/${id}`] })
    void qc.invalidateQueries({ queryKey: [`/admin/catalog-norm/runs/${id}/changes`] })
    void qc.invalidateQueries({ queryKey: ['/admin/catalog-norm/runs'] })
    void qc.invalidateQueries({ queryKey: ['/admin/catalog-norm/settings'] })
  }
  useInterval(refresh, 4000, !!r && live(r))
  const { busy, act } = useRunActions(refresh)
  const counts = ch.data?.counts ?? {}
  const st = r?.stats ?? {}

  const minutes = r?.finished_at ? Math.max(1, Math.round(dayjs(r.finished_at).diff(dayjs(r.started_at), 'minute', true))) : 0
  const head = !r
    ? ''
    : r.status === 'running'
      ? `Идёт: разобрано ${n(st.processed)} из ${n(st.total)} товаров. Журнал пополняется на ходу.`
      : r.status === 'applying'
        ? 'Применяем изменения к товарам…'
        : r.status === 'rolled_back'
          ? `Откачен ${r.rolled_back_at ? when(r.rolled_back_at) : ''} — названия, категории, решения и группы вернулись как были.`
          : r.status === 'failed' || r.status === 'interrupted'
            ? r.error
            : r.dry_run && !r.applied
              ? `Готово за ${minutes} мин · ${n(st.processed)} товаров разобрано · в товары ещё ничего не записано. Посмотрите журнал и нажмите «Применить» — или просто закройте.`
              : `Готово за ${minutes} мин · ${n(st.processed)} товаров разобрано${r.applied_at ? ` · применено ${when(r.applied_at)}` : ''}.`

  return (
    <>
      <PageTitle
        title={
          r ? (
            <Flex gap={10} align="center" wrap>
              <span>{scope(r)}</span>
              {r.dry_run && <Pill label="Только посмотреть" bg={C.amberBg} fg={C.amber} icon={<EyeOutlined />} />}
              <RunStatusPill r={r} />
            </Flex>
          ) : (
            'Прогон'
          )
        }
        extra={
          r && (
            <Space>
              {r.dry_run && !r.applied && r.status === 'done' && (
                <Popconfirm
                  title="Применить изменения?"
                  description={<div style={{ maxWidth: 300 }}>Названия, категории, решения по товарам магазинов и группы вариаций запишутся в товары. Потом можно откатить.</div>}
                  okText="Применить"
                  cancelText="Нет"
                  onConfirm={() => act(r.id, 'apply')}
                >
                  <Button type="primary" icon={<CheckOutlined />} loading={busy === r.id + 'apply'}>
                    Применить изменения
                  </Button>
                </Popconfirm>
              )}
              {r.applied && r.status === 'done' && <RollbackButton busy={busy === r.id + 'rollback'} onClick={() => act(r.id, 'rollback')} />}
            </Space>
          )
        }
        tabs={
          <Typography.Text type="secondary" style={{ display: 'block', padding: '0 16px 8px' }}>
            <Link to="/catalog/norm">Автонормализация</Link>
            {r ? ` › Прогон ${dayjs(r.started_at).format('DD.MM, HH:mm')} · ${r.trigger === 'auto' ? 'автоматически' : 'вручную'}` : ''}
          </Typography.Text>
        }
      />
      <LoadError error={run.error || ch.error} retry={refresh} />
      {r && (
        <>
          {(r.status === 'failed' || r.status === 'interrupted') && (
            <Alert
              type={r.status === 'failed' ? 'error' : 'warning'}
              showIcon
              style={{ marginBottom: 16 }}
              message={r.status === 'failed' ? 'Прогон остановился с ошибкой' : 'Прогон прерван перезапуском сервера'}
              description={`${r.error ? r.error + '. ' : ''}Уже разобранное сохранено. Продолжить — «Запустить вручную» с теми же разделами: товары, которые ещё не проходили, пройдут.`}
            />
          )}
          <Typography.Text style={{ color: C.mute, display: 'block', marginBottom: 12 }}>{head}</Typography.Text>
          {r.status === 'running' && st.total ? (
            <Progress percent={Math.round(((st.processed ?? 0) / st.total) * 100)} strokeColor={C.red} trailColor={C.grayBg} style={{ marginBottom: 12 }} />
          ) : null}
          <Flex gap={12} wrap style={{ marginBottom: 16 }}>
            <Stat title="названия" value={n(st.names)} sub={`узбекские: ${n(st.names_uz)}`} />
            <Stat title="категории" value={n(st.categories)} sub={`в другой раздел: ${n(st.moves)} · «нет»: ${n(st.moves_kept)}`} />
            <Stat title="вариации" value={`${n(st.groups)} групп`} sub={`${n(st.in_groups)} товаров · +${n(st.joined)} в группы`} />
            <Stat
              title="товары магазинов"
              value={n(s(st, 'approved') + s(st, 'duplicates') + s(st, 'rejected'))}
              sub={`${n(st.approved)} одобрено · ${n(st.duplicates)} дубль · ${n(st.rejected)} отклонено`}
            />
            <Stat title="не разобрано" value={`${n(st.failed)} пачек`} sub={st.failed ? 'ИИ ответил ошибкой — войдут в следующий прогон' : 'ИИ ответил на все'} />
          </Flex>
        </>
      )}

      <Card style={{ borderRadius: 12 }} styles={{ body: { padding: 0 } }}>
        <Flex gap={8} wrap align="center" style={{ padding: '12px 16px' }}>
          <Segmented
            value={k}
            onChange={(v) => {
              setPage(1)
              setKind(v as string)
            }}
            options={KINDS.map((x) => ({ value: x.key, label: `${x.label} · ${n(counts[x.key] ?? 0)}` }))}
          />
          <div style={{ flex: 1 }} />
          <Input.Search
            allowClear
            placeholder="Название товара"
            style={{ width: 240 }}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onSearch={(v) => {
              setPage(1)
              setQ(v.trim() || undefined)
            }}
          />
        </Flex>
        {k === 'name' && (
          <div style={{ padding: '0 16px 10px', color: C.mute, fontSize: 12 }}>
            Название от ИИ берётся, только если бренд и все цифры на месте; иначе — очищенное без ИИ.
          </div>
        )}
        {k === 'category' && (
          <div style={{ padding: '0 16px 10px', color: C.mute, fontSize: 12 }}>
            Перенос в другой раздел — только если второе мнение ИИ согласно; иначе категория остаётся и сюда не попадает.
          </div>
        )}
        <Table<Change>
          rowKey="id"
          size="middle"
          columns={columnsFor(k)}
          dataSource={ch.data?.items ?? []}
          loading={ch.isLoading}
          scroll={{ x: 900 }}
          locale={{ emptyText: <Empty description="Здесь изменений нет" /> }}
          pagination={{
            current: page,
            pageSize,
            total: ch.data?.total ?? 0,
            showSizeChanger: false,
            hideOnSinglePage: true,
            onChange: setPage,
            showTotal: (t) => `Всего ${n(t)}`,
          }}
        />
      </Card>
    </>
  )
}
