// Каталог → Заявки на бренды (Figma «Супер-админ · Заявки на бренды»):
// агент «SM Агент» не нашёл свой бренд в каталоге и прислал заявку.
// Одобрить — бренд появится в каталоге и привяжется к агенту; «Это
// существующий бренд» — привязать к бренду каталога без дубля; отклонить —
// только с причиной (её увидит агент).
import { useEffect, useState, type ReactNode } from 'react'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { App, Avatar, Button, Card, Empty, Flex, Form, Image, Input, Modal, Space, Spin, Tabs, Tag, Typography } from 'antd'
import { CheckCircleOutlined, LinkOutlined, PhoneOutlined, StopOutlined, WarningOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, api, dateTime, errorText, formatPhone } from '@sm/shared'
import { useUrlState } from '../hooks'

type Status = 'pending' | 'approved' | 'rejected'

interface BrandHit {
  id: string
  name: string
  category: string
  products: number
  agents: number
}

interface BrandRequest {
  id: string
  name: string
  category_id: string | null
  category_name: string
  manufacturer: string
  comment: string
  logo_url: string
  status: Status
  brand_id: string | null
  brand_name: string
  linked_existing: boolean
  reason: string
  created_at: string
  decided_at: string | null
  network_id: string
  network_name: string
  agent_name: string
  agent_phone: string
  agent_registered_at: string
  similar?: BrandHit[]
}

interface ListResp {
  items: BrandRequest[]
  pending: number
  approved: number
  rejected: number
}

const palette = [
  ['#dbeafe', '#1d4ed8'],
  ['#dcfce7', '#15803d'],
  ['#fef3c7', '#b45309'],
  ['#ede9fe', '#6d28d9'],
  ['#fce7f3', '#be185d'],
]

function initials(name: string) {
  const w = name.trim().split(/\s+/).filter(Boolean)
  if (w.length === 0) return '?'
  return (w.length === 1 ? w[0].slice(0, 2) : w[0][0] + w[1][0]).toUpperCase()
}

function BrandLogo({ name, url, size = 44 }: { name: string; url?: string; size?: number }) {
  let h = 0
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) | 0
  const [bg, fg] = palette[Math.abs(h) % palette.length]
  if (url) return <Image src={url} width={size} height={size} style={{ borderRadius: 10, objectFit: 'cover' }} preview={{ mask: null }} />
  return (
    <Avatar shape="square" size={size} style={{ background: bg, color: fg, fontWeight: 800, borderRadius: 10, flex: 'none' }}>
      {initials(name)}
    </Avatar>
  )
}

const statusTag: Record<Status, ReactNode> = {
  pending: <Tag color="gold">Новая · ждёт решения</Tag>,
  approved: <Tag color="green">Одобрена</Tag>,
  rejected: <Tag color="red">Отклонена</Tag>,
}

export function BrandRequests() {
  const [status = 'pending', setStatus] = useUrlState('status', 'pending')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const [openId, setOpenId] = useUrlState('open')
  const list = useQuery({
    queryKey: ['brand-requests', status, q],
    queryFn: () => api.get<ListResp>('/admin/brand-requests', { status, q, limit: 100 }),
    placeholderData: keepPreviousData,
  })
  const items = list.data?.items ?? []
  // По умолчанию открыта первая заявка списка.
  useEffect(() => {
    if (!openId && items.length > 0) setOpenId(items[0].id)
  }, [openId, items, setOpenId])

  const tabs = [
    { key: 'pending', label: `Новые · ${list.data?.pending ?? 0}` },
    { key: 'approved', label: `Одобренные · ${list.data?.approved ?? 0}` },
    { key: 'rejected', label: `Отклонённые · ${list.data?.rejected ?? 0}` },
  ]
  return (
    <>
      <PageTitle
        title={
          <Space>
            Заявки на бренды
            {(list.data?.pending ?? 0) > 0 && <Tag color="red">{list.data?.pending} новые</Tag>}
          </Space>
        }
      />
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        Агенты запрашивают бренды, которых нет в каталоге. Одобрите — бренд появится в каталоге и сразу привяжется к агенту. Существующий бренд агент выбирает сам, без заявки.
      </Typography.Paragraph>
      <Flex gap={24} align="flex-start" wrap>
        <Card style={{ flex: '1 1 520px', maxWidth: 640 }}>
          <Tabs
            activeKey={status}
            onChange={(k) => {
              setStatus(k)
              setOpenId(undefined)
            }}
            items={tabs}
          />
          <Input.Search
            placeholder="Поиск по бренду, агенту или телефону"
            allowClear
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onSearch={(v) => setQ(v.trim())}
            style={{ marginBottom: 12 }}
          />
          {list.error ? (
            <LoadError error={list.error} retry={() => list.refetch()} />
          ) : list.isLoading ? (
            <Spin />
          ) : items.length === 0 ? (
            <Empty description={status === 'pending' ? 'Новых заявок нет' : 'Заявок нет'} />
          ) : (
            <Flex vertical gap={8}>
              {items.map((r) => {
                const old = r.status === 'pending' && Date.now() - new Date(r.created_at).getTime() > 3 * 24 * 3600 * 1000
                return (
                  <Card
                    key={r.id}
                    size="small"
                    hoverable
                    onClick={() => setOpenId(r.id)}
                    style={{
                      borderColor: r.id === openId ? '#e11d2a' : undefined,
                      background: r.id === openId ? '#fef3f2' : undefined,
                    }}
                  >
                    <Flex gap={12} align="center">
                      <BrandLogo name={r.name} url={r.logo_url} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <Typography.Text strong>{r.name}</Typography.Text>
                        <div>
                          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                            {[r.category_name, r.manufacturer].filter(Boolean).join(' · ') || '—'}
                          </Typography.Text>
                        </div>
                        <div style={{ fontSize: 12 }}>
                          {r.agent_name} · {r.network_name}
                        </div>
                      </div>
                      <Flex vertical align="flex-end" gap={4}>
                        <Typography.Text type={old ? 'danger' : 'secondary'} style={{ fontSize: 12 }}>
                          {dateTime(r.created_at)}
                        </Typography.Text>
                        {r.status === 'rejected' && <Tag color="red">Отклонена</Tag>}
                        {r.status === 'approved' && <Tag color="green">{r.linked_existing ? 'Привязан' : 'Создан'}</Tag>}
                      </Flex>
                    </Flex>
                  </Card>
                )
              })}
            </Flex>
          )}
          <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginTop: 12, marginBottom: 0 }}>
            Заявки старше 3 дней подсвечиваются. О новой заявке супер-админу приходит уведомление в Telegram-бот.
          </Typography.Paragraph>
        </Card>
        <div style={{ flex: '1 1 480px', maxWidth: 600 }}>
          {openId ? <RequestCard key={openId} id={openId} /> : <Card><Empty description="Выберите заявку" /></Card>}
        </div>
      </Flex>
    </>
  )
}

function RequestCard({ id }: { id: string }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const { data: r, error, isLoading, refetch } = useQuery({
    queryKey: ['brand-request', id],
    queryFn: () => api.get<BrandRequest>(`/admin/brand-requests/${id}`),
  })
  const [form] = Form.useForm<{ name: string; category_id?: string }>()
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const [linkOpen, setLinkOpen] = useState(false)
  const [linkBrand, setLinkBrand] = useState<string | undefined>()

  useEffect(() => {
    if (r) form.setFieldsValue({ name: r.name, category_id: r.category_id ?? undefined })
  }, [r, form])

  if (error) return <LoadError error={error} retry={() => refetch()} />
  if (isLoading || !r) return <Card><Spin /></Card>

  const pending = r.status === 'pending'
  const done = async (what: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(what)
    try {
      await fn()
      message.success(ok)
      await qc.invalidateQueries({ queryKey: ['brand-requests'] })
      await refetch()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(null)
    }
  }
  const approve = () =>
    done(
      'approve',
      () => api.post(`/admin/brand-requests/${id}/approve`, { name: form.getFieldValue('name'), category_id: form.getFieldValue('category_id') ?? null }),
      'Бренд одобрен и привязан к агенту',
    )
  const link = (brandId: string) =>
    done('link', () => api.post(`/admin/brand-requests/${id}/link`, { brand_id: brandId }), 'Агент привязан к бренду каталога')
  const reject = () => {
    if (!reason.trim()) {
      message.warning('Напишите причину — её увидит агент')
      return
    }
    return done('reject', () => api.post(`/admin/brand-requests/${id}/reject`, { reason: reason.trim() }), 'Заявка отклонена')
  }

  return (
    <Card>
      <Flex gap={14} align="center" style={{ marginBottom: 16 }}>
        <BrandLogo name={r.name} url={r.logo_url} size={72} />
        <div>
          <Typography.Title level={4} style={{ margin: 0 }}>
            {r.name}
          </Typography.Title>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {r.logo_url ? 'Логотип — фото упаковки от агента' : 'Агент не приложил логотип'}
          </Typography.Text>
          <div>{statusTag[r.status]}</div>
        </div>
      </Flex>

      <Form form={form} layout="vertical" disabled={!pending}>
        <Form.Item name="name" label="Название бренда (можно поправить)" rules={[{ required: true }]}>
          <Input />
        </Form.Item>
        <Form.Item name="category_id" label="Категория">
          <RemoteSelect path="/admin/catalog/categories" allowClear placeholder="Категория" selectedLabel={r.category_name || undefined} />
        </Form.Item>
        <Form.Item label="Производитель">
          <Input value={r.manufacturer} disabled />
        </Form.Item>
      </Form>

      {r.comment && (
        <Card size="small" style={{ background: '#f8fafc', marginBottom: 12 }}>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            Комментарий агента
          </Typography.Text>
          <div>{r.comment}</div>
        </Card>
      )}

      <Card size="small" style={{ background: '#f8fafc', marginBottom: 12 }}>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          Агент
        </Typography.Text>
        <Flex gap={12} align="center">
          <Avatar style={{ background: '#e11d2a', fontWeight: 800 }}>{initials(r.agent_name || '?')}</Avatar>
          <div style={{ flex: 1 }}>
            <Typography.Text strong>
              {r.agent_name} · {r.network_name}
            </Typography.Text>
            <div style={{ fontSize: 12, color: '#667085' }}>
              {formatPhone(r.agent_phone)} · зарегистрирован {dateTime(r.agent_registered_at)}
            </div>
          </div>
          <Button icon={<PhoneOutlined />} href={`tel:${r.agent_phone}`}>
            Позвонить
          </Button>
        </Flex>
      </Card>

      {pending && (r.similar ?? []).length > 0 && (
        <Card size="small" style={{ background: '#fffaeb', borderColor: '#fedf89', marginBottom: 12 }}>
          <Typography.Text strong style={{ color: '#93370d' }}>
            <WarningOutlined /> Похожий бренд уже есть в каталоге
          </Typography.Text>
          <Flex vertical gap={8} style={{ marginTop: 8 }}>
            {(r.similar ?? []).map((b) => (
              <Flex key={b.id} gap={12} align="center" style={{ background: '#fff', borderRadius: 10, padding: '8px 12px' }}>
                <BrandLogo name={b.name} size={36} />
                <div style={{ flex: 1 }}>
                  <Typography.Text strong>{b.name}</Typography.Text>
                  <div style={{ fontSize: 12, color: '#667085' }}>
                    {[b.category, `${b.products} товаров`, `${b.agents} агентов`].filter(Boolean).join(' · ')}
                  </div>
                </div>
                <Button type="primary" style={{ background: '#101828' }} loading={busy === 'link'} onClick={() => link(b.id)}>
                  Это он — привязать
                </Button>
              </Flex>
            ))}
          </Flex>
          <div style={{ fontSize: 12, color: '#93370d', marginTop: 8 }}>Агент будет привязан к выбранному бренду, заявка закроется, дубль не появится.</div>
        </Card>
      )}

      {pending ? (
        <Flex vertical gap={10}>
          <Button type="primary" size="large" icon={<CheckCircleOutlined />} loading={busy === 'approve'} onClick={approve} block>
            Одобрить — создать бренд и привязать агента
          </Button>
          <Button size="large" icon={<LinkOutlined />} onClick={() => setLinkOpen(true)} block>
            Это существующий бренд — выбрать…
          </Button>
          <Flex gap={10}>
            <Input size="large" placeholder="Причина отказа (увидит агент)" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} />
            <Button size="large" danger icon={<StopOutlined />} loading={busy === 'reject'} onClick={reject}>
              Отклонить
            </Button>
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            Агент получит пуш с решением. После одобрения у него открываются «Магазины» и «Договориться»; отклонённую заявку он может исправить и отправить снова.
          </Typography.Text>
        </Flex>
      ) : (
        <Card size="small">
          {r.status === 'approved' ? (
            <>
              Бренд <b>{r.brand_name}</b> {r.linked_existing ? 'уже был в каталоге — агент привязан к нему' : 'создан в каталоге'} · {dateTime(r.decided_at)}
            </>
          ) : (
            <>
              Отклонена {dateTime(r.decided_at)}. Причина: {r.reason}
            </>
          )}
        </Card>
      )}

      <Modal
        title="Привязать к бренду каталога"
        open={linkOpen}
        onCancel={() => setLinkOpen(false)}
        okText="Привязать"
        okButtonProps={{ disabled: !linkBrand, loading: busy === 'link' }}
        onOk={async () => {
          if (!linkBrand) return
          await link(linkBrand)
          setLinkOpen(false)
        }}
      >
        <Typography.Paragraph type="secondary">Агент ошибся в написании — выберите бренд, который уже есть в каталоге.</Typography.Paragraph>
        <RemoteSelect path="/admin/catalog/brands" search showSearch placeholder="Начните вводить название" value={linkBrand} onChange={(v) => setLinkBrand(v as string)} style={{ width: '100%' }} />
      </Modal>
    </Card>
  )
}
