// Каталог → Исправления от магазинов (Figma «SM Магазин · Изменить товар»,
// логика): магазин правит товар общей базы — название, фото, штрихкоды,
// категорию, единицу; до проверки у всех старое. Здесь «было / стало»,
// «Принять» — изменения уходят в товар для всех магазинов, «Отклонить» —
// с причиной, её увидит магазин.
import { useState, type ReactNode } from 'react'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { App, Button, Card, Empty, Flex, Image, Input, Modal, Space, Spin, Tabs, Tag, Typography } from 'antd'
import { CheckCircleOutlined, StopOutlined } from '@ant-design/icons'
import { Link } from 'react-router-dom'
import { LoadError, PageTitle, api, dateTime, errorText } from '@sm/shared'
import { useUrlState } from '../hooks'

type Status = 'pending' | 'approved' | 'rejected'

interface Changes {
  name?: string
  name_uz?: string
  images?: string[]
  barcodes?: string[]
  category_id?: string
  unit_id?: string
}

interface Suggestion {
  id: string
  product_id: string
  product_name: string
  network_name: string
  store_name: string | null
  author_name: string
  status: Status
  reject_reason: string
  changes: Changes
  category_name: string | null
  unit_name: string | null
  current: Changes
  current_category_name: string
  current_unit_name: string
  created_at: string
  reviewed_at: string | null
}

const statusTag: Record<Status, ReactNode> = {
  pending: <Tag color="gold">Ждёт проверки</Tag>,
  approved: <Tag color="green">Принято</Tag>,
  rejected: <Tag color="red">Отклонено</Tag>,
}

function Photos({ urls }: { urls?: string[] }) {
  if (!urls?.length) return <Typography.Text type="secondary">нет фото</Typography.Text>
  return (
    <Image.PreviewGroup>
      <Space wrap>
        {urls.map((u) => (
          <Image key={u} src={u} width={64} height={64} style={{ objectFit: 'cover', borderRadius: 8 }} />
        ))}
      </Space>
    </Image.PreviewGroup>
  )
}

/** Строка «было → стало». */
function Diff({ label, was, now }: { label: string; was: ReactNode; now: ReactNode }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr 1fr', gap: 12, padding: '8px 0', borderTop: '1px solid #f0f0f0' }}>
      <Typography.Text type="secondary">{label}</Typography.Text>
      <div style={{ color: '#8c8c8c', textDecoration: typeof was === 'string' ? 'line-through' : undefined }}>{was}</div>
      <div style={{ fontWeight: 600 }}>{now}</div>
    </div>
  )
}

function SuggestionCard({ s }: { s: Suggestion }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [busy, setBusy] = useState<'' | 'approve' | 'reject'>('')
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const c = s.changes
  const done = async (kind: 'approve' | 'reject', body: object, ok: string) => {
    setBusy(kind)
    try {
      await api.post(`/admin/product-suggestions/${s.id}/${kind}`, body)
      message.success(ok)
      setRejecting(false)
      await qc.invalidateQueries({ queryKey: ['product-suggestions'] })
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy('')
    }
  }
  return (
    <Card style={{ marginBottom: 12 }}>
      <Flex justify="space-between" align="start" gap={12} wrap>
        <div>
          <Typography.Title level={5} style={{ margin: 0 }}>
            <Link to={`/products/${s.product_id}`}>{s.product_name}</Link>
          </Typography.Title>
          <Typography.Text type="secondary">
            {s.network_name}
            {s.store_name ? ` · ${s.store_name}` : ''} · {s.author_name} · {dateTime(s.created_at)}
          </Typography.Text>
        </div>
        {statusTag[s.status]}
      </Flex>
      <div style={{ marginTop: 12 }}>
        <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr 1fr', gap: 12, paddingBottom: 4 }}>
          <span />
          <Typography.Text type="secondary">Было</Typography.Text>
          <Typography.Text type="secondary">Стало</Typography.Text>
        </div>
        {c.name !== undefined && <Diff label="Название (рус.)" was={s.current.name ?? ''} now={c.name} />}
        {c.name_uz !== undefined && <Diff label="Название (узб.)" was={s.current.name_uz ?? ''} now={c.name_uz} />}
        {c.images !== undefined && <Diff label="Фото" was={<Photos urls={s.current.images} />} now={<Photos urls={c.images} />} />}
        {c.barcodes !== undefined && (
          <Diff label="Штрихкоды" was={(s.current.barcodes ?? []).join(', ') || '—'} now={c.barcodes.join(', ') || '—'} />
        )}
        {c.category_id !== undefined && <Diff label="Категория" was={s.current_category_name} now={s.category_name ?? c.category_id} />}
        {c.unit_id !== undefined && <Diff label="Единица" was={s.current_unit_name} now={s.unit_name ?? c.unit_id} />}
      </div>
      {s.status === 'rejected' && s.reject_reason && (
        <Typography.Paragraph type="danger" style={{ marginTop: 8, marginBottom: 0 }}>
          Причина: {s.reject_reason}
        </Typography.Paragraph>
      )}
      {s.status === 'pending' && (
        <Space style={{ marginTop: 12 }}>
          <Button
            type="primary"
            icon={<CheckCircleOutlined />}
            loading={busy === 'approve'}
            onClick={() => done('approve', {}, 'Принято — товар изменён во всех магазинах')}
          >
            Принять
          </Button>
          <Button danger icon={<StopOutlined />} onClick={() => setRejecting(true)}>
            Отклонить
          </Button>
        </Space>
      )}
      <Modal
        open={rejecting}
        title="Отклонить исправление"
        okText="Отклонить"
        cancelText="Отмена"
        okButtonProps={{ danger: true, disabled: !reason.trim(), loading: busy === 'reject' }}
        onOk={() => done('reject', { reason: reason.trim() }, 'Исправление отклонено')}
        onCancel={() => setRejecting(false)}
      >
        <Typography.Paragraph type="secondary">Причину увидит магазин.</Typography.Paragraph>
        <Input.TextArea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Например: название как на упаковке" />
      </Modal>
    </Card>
  )
}

export function ProductSuggestions() {
  const [statusParam, setStatus] = useUrlState('status', 'pending')
  const status = (statusParam ?? 'pending') as Status
  const q = useQuery({
    queryKey: ['product-suggestions', status],
    queryFn: () => api.get<{ items: Suggestion[] }>('/admin/product-suggestions', { status, limit: 100 }).then((r) => r.items ?? []),
    placeholderData: keepPreviousData,
  })
  return (
    <>
      <PageTitle title="Исправления от магазинов" />
      <Typography.Paragraph type="secondary">
        Магазин изменил товар общей базы. Пока не принято — у всех магазинов и покупателей старое.
      </Typography.Paragraph>
      <Tabs
        activeKey={status}
        onChange={(k) => setStatus(k)}
        items={[
          { key: 'pending', label: 'Ждут проверки' },
          { key: 'approved', label: 'Принятые' },
          { key: 'rejected', label: 'Отклонённые' },
        ]}
      />
      <LoadError error={q.error} retry={() => q.refetch()} />
      {q.isLoading ? (
        <Spin />
      ) : (q.data ?? []).length === 0 ? (
        <Empty description={status === 'pending' ? 'Новых исправлений нет' : 'Пусто'} />
      ) : (
        (q.data ?? []).map((s) => <SuggestionCard key={s.id} s={s} />)
      )}
    </>
  )
}
