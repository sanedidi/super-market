import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { Alert, App, Button, Checkbox, Input, Modal, Space, Spin, Typography } from 'antd'
import { CheckCircleOutlined, DeleteOutlined, InfoCircleOutlined, WalletOutlined } from '@ant-design/icons'
import { api, errorText, money, useItem } from '@sm/shared'

/**
 * Удаление сети или магазина (Figma «Супер-админ · удаление сетей и
 * магазинов», УС2–УС4): превью «что удалится», подтверждение названием,
 * деньги на балансе; если удалить нельзя — объяснение.
 */

interface DeleteCount {
  key: string
  label: string
  count: number
}

interface DeletePreview {
  kind: 'network' | 'store'
  id: string
  name: string
  network_id: string
  network_name: string
  counts: DeleteCount[]
  total: number
  kept_products: number
  active_orders: number
  balance_available: string
  balance_pending: string
  money_ack_required: boolean
  blocked: { code: 'active_orders' | 'only_store' | 'linked'; message: string } | null
}

interface DeleteResult {
  name: string
  counts: DeleteCount[]
  total: number
}

export interface DeleteTarget {
  kind: 'network' | 'store'
  id: string
  name: string
  /** Для сети: chain | single | distributor — чтобы назвать её правильно. */
  networkKind?: string
}

const norm = (s: string) => s.trim().split(/\s+/).join(' ').toLowerCase()

/** Как назвать удаляемое: «сеть», «магазин» (одиночный магазин) или «агента». */
function words(t: DeleteTarget) {
  if (t.kind === 'store' || t.networkKind === 'single') return { acc: 'магазин', cap: 'Магазин', deleted: 'удалён', pron: 'нему' }
  if (t.networkKind === 'distributor') return { acc: 'агента', cap: 'Агент', deleted: 'удалён', pron: 'нему' }
  return { acc: 'сеть', cap: 'Сеть', deleted: 'удалена', pron: 'ней' }
}

const n = new Intl.NumberFormat('ru-RU')

/** Окно удаления: сначала превью с сервера, потом подтверждение. */
export function DeleteTenantModal({ target, onClose, onDeleted }: { target: DeleteTarget | null; onClose: () => void; onDeleted?: () => void }) {
  const path = target ? `/admin/${target.kind === 'network' ? 'networks' : 'stores'}/${target.id}` : null
  const preview = useItem<DeletePreview>(path ? `${path}/delete-preview` : null)
  const p = preview.data
  const [typed, setTyped] = useState('')
  const [ack, setAck] = useState(false)
  const [busy, setBusy] = useState(false)
  const { message } = App.useApp()
  const qc = useQueryClient()
  const navigate = useNavigate()

  useEffect(() => {
    setTyped('')
    setAck(false)
  }, [target?.id])

  if (!target) return null
  const w = words(target)
  const loading = preview.isLoading || preview.isFetching

  // Удалить нельзя (УС4): незавершённые заказы, единственный магазин, связи.
  if (p && p.blocked) {
    const title =
      p.blocked.code === 'only_store'
        ? `«${p.name}» — единственный магазин сети`
        : p.blocked.code === 'active_orders'
          ? `«${p.name}» пока нельзя удалить`
          : `«${p.name}» нельзя удалить`
    return (
      <Modal
        open
        width={460}
        onCancel={onClose}
        title={
          <Space align="start">
            <InfoCircleOutlined style={{ color: '#155EEF', fontSize: 20, marginTop: 2 }} />
            <span>{title}</span>
          </Space>
        }
        footer={
          <Space>
            <Button onClick={onClose}>{p.blocked.code === 'only_store' ? 'Понятно' : 'Закрыть'}</Button>
            {p.blocked.code === 'active_orders' && (
              <Button
                type="primary"
                onClick={() => {
                  onClose()
                  navigate(`/orders?network_id=${p.network_id}`)
                }}
              >
                Открыть заказы
              </Button>
            )}
          </Space>
        }
      >
        <Typography.Paragraph type="secondary" style={{ marginBottom: 0 }}>
          {p.blocked.message}
        </Typography.Paragraph>
      </Modal>
    )
  }

  const nameOk = p ? norm(typed) === norm(p.name) : false
  const canDelete = !!p && nameOk && (!p.money_ack_required || ack) && !busy

  const submit = async () => {
    if (!p || !path) return
    setBusy(true)
    try {
      const res = await api.del<DeleteResult>(path, { confirm_name: typed, money_ack: ack })
      const parts = res.counts
        .filter((c) => ['stores', 'sales', 'orders'].includes(c.key))
        .map((c) => `${c.label.toLowerCase()}: ${n.format(c.count)}`)
      message.success({
        icon: <CheckCircleOutlined style={{ color: '#12B76A' }} />,
        content: `${w.cap} «${res.name}» ${w.deleted}${parts.length ? ': ' + parts.join(', ') : ''}`,
        duration: 6,
      })
      onClose()
      onDeleted?.()
      qc.invalidateQueries({ queryKey: ['/admin/networks'] })
      qc.invalidateQueries({ queryKey: [`/admin/networks/${p.network_id}`] })
      qc.invalidateQueries({ queryKey: [`/admin/networks/${p.network_id}/stores`] })
      qc.invalidateQueries({ queryKey: [`/admin/billing/networks/${p.network_id}`] })
    } catch (e) {
      message.error(errorText(e))
      preview.refetch()
    } finally {
      setBusy(false)
    }
  }

  const okLabel = target.kind === 'store' ? 'Удалить магазин' : 'Удалить навсегда'
  return (
    <Modal
      open
      width={560}
      onCancel={busy ? undefined : onClose}
      maskClosable={false}
      title={
        <Space align="center">
          <span
            style={{
              display: 'inline-flex',
              width: 36,
              height: 36,
              borderRadius: 18,
              background: '#FEF3F2',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <DeleteOutlined style={{ color: '#D92D20', fontSize: 18 }} />
          </span>
          <span>
            Удалить {w.acc} «{p?.name ?? target.name}»?
          </span>
        </Space>
      }
      footer={
        <Space direction="vertical" style={{ width: '100%' }} size={8}>
          <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', textAlign: 'left' }}>
            Удаление попадёт в журнал: кто, когда, что.
          </Typography.Text>
          <Space style={{ justifyContent: 'flex-end', width: '100%' }}>
            <Button onClick={onClose} disabled={busy}>
              Отмена
            </Button>
            <Button type="primary" danger icon={<DeleteOutlined />} disabled={!canDelete} loading={busy} onClick={submit}>
              {okLabel}
            </Button>
          </Space>
        </Space>
      }
    >
      {preview.error && <Alert type="error" showIcon message="Не удалось посчитать, что удалится" description={errorText(preview.error)} />}
      {loading && !p && <Spin style={{ display: 'block', margin: '32px auto' }} />}
      {p && (
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <Typography.Text type="secondary">
            {target.kind === 'store'
              ? `Магазин удалится вместе со своими данными. Сеть «${p.network_name}» и другие её магазины останутся.`
              : `${w.cap} и всё, что к ${w.pron} относится, удалятся навсегда. Восстановить нельзя.`}
          </Typography.Text>

          <div style={{ background: '#F9FAFB', borderRadius: 10, padding: '4px 14px' }}>
            {p.counts.map((c, i) => (
              <div
                key={c.key}
                style={{ display: 'flex', justifyContent: 'space-between', padding: '7px 0', borderTop: i ? '1px solid #EAECF0' : undefined }}
              >
                <span>{c.label}</span>
                <b>{n.format(c.count)}</b>
              </div>
            ))}
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '7px 0', borderTop: p.counts.length ? '1px solid #EAECF0' : undefined }}>
              <Typography.Text type="secondary">Всего записей</Typography.Text>
              <Typography.Text type="secondary">{n.format(p.total)}</Typography.Text>
            </div>
          </div>

          <Space align="start" size={8}>
            <CheckCircleOutlined style={{ color: '#667085', marginTop: 4 }} />
            <Typography.Text type="secondary">
              {target.kind === 'store'
                ? 'Останутся: сеть, её товары и цены, сотрудники (доступ к этому магазину у них пропадёт), контрагенты, баланс и счета сети. Документы других магазинов не меняются.'
                : `Останутся: ${
                    p.kept_products > 0 ? `одобренные товары сети (${n.format(p.kept_products)}) — в центральной базе, ` : ''
                  }товары общего каталога, покупатели, владелец как пользователь — вход в панель магазина отключится. Данные других сетей не меняются.`}
            </Typography.Text>
          </Space>

          {p.money_ack_required && (
            <Alert
              type="warning"
              icon={<WalletOutlined />}
              showIcon
              message={`На балансе сети ${money(p.balance_available)} сум${
                Number(p.balance_pending) ? ` и ещё ${money(p.balance_pending)} в пути` : ''
              }. После удаления выплатить их через платформу будет нельзя.`}
              description={
                <Checkbox checked={ack} onChange={(e) => setAck(e.target.checked)} style={{ marginTop: 4 }}>
                  <b>Деньги выплачены или магазин от них отказался</b>
                </Checkbox>
              }
            />
          )}

          <div>
            <Typography.Text type="secondary">
              Чтобы подтвердить, введите название: <Typography.Text strong>{p.name}</Typography.Text>
            </Typography.Text>
            <Input
              style={{ marginTop: 6 }}
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              placeholder={p.name}
              autoFocus
              onPressEnter={() => canDelete && submit()}
            />
          </div>
        </Space>
      )}
    </Modal>
  )
}
