// Очередь уведомлений покупателям (push и Telegram): что ушло, что ждёт,
// что не доставлено — с повтором.
import { useState } from 'react'
import { Button, Input, Popconfirm, Select, Tag, Typography } from 'antd'
import { PageTitle, PagedTable, api, dateTime, useAction } from '@sm/shared'
import { useUrlState } from '../hooks'

interface Notification {
  id: number
  user_id: string
  phone: string
  kind: string
  title: string
  body: string
  status: 'pending' | 'sent' | 'skipped' | 'failed'
  channel: string
  attempts: number
  last_error: string
  send_after: string
  created_at: string
  sent_at: string | null
}

const STATUSES: Record<string, { label: string; color: string }> = {
  pending: { label: 'В очереди', color: 'orange' },
  sent: { label: 'Отправлено', color: 'green' },
  skipped: { label: 'Пропущено', color: 'default' },
  failed: { label: 'Не доставлено', color: 'red' },
}

function kindTitle(kind: string) {
  if (kind === 'order_status') return 'Статус заказа'
  if (kind.startsWith('family')) return 'Моя семья'
  return kind
}

const CHANNELS: Record<string, string> = {
  push: 'Push',
  telegram: 'Telegram',
}

export function Notifications() {
  const [status, setStatus] = useUrlState('status')
  const [q, setQ] = useUrlState('q')
  const [search, setSearch] = useState(q ?? '')
  const retry = useAction((id: number) => api.post(`/admin/notifications/${id}/retry`), { success: 'Уведомление снова в очереди' })
  return (
    <>
      <PageTitle title="Уведомления покупателям">
        <Input.Search
          placeholder="Телефон или заголовок"
          allowClear
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onSearch={(v) => setQ(v.trim())}
          style={{ width: 240 }}
        />
        <Select
          placeholder="Все"
          allowClear
          value={status}
          onChange={setStatus}
          style={{ width: 170 }}
          options={Object.entries(STATUSES).map(([value, s]) => ({ value, label: s.label }))}
        />
      </PageTitle>
      <Typography.Paragraph type="secondary">
        Воркер отправляет push на устройства покупателя, если их нет — сообщение в Telegram. «Пропущено» — доставить было некуда (нет
        устройств и Telegram) или ошибка не временная; «Не доставлено» — кончились попытки. «Повторить» возвращает уведомление в очередь.
      </Typography.Paragraph>
      <PagedTable<Notification>
        path="/admin/notifications"
        params={{ status, q }}
        columns={[
          { title: 'Создано', dataIndex: 'created_at', render: dateTime },
          { title: 'Покупатель', dataIndex: 'phone' },
          {
            title: 'Уведомление',
            render: (_, n) => (
              <>
                <b>{n.title}</b>
                <div>
                  <Typography.Text type="secondary">
                    {kindTitle(n.kind)} · {n.body}
                  </Typography.Text>
                </div>
              </>
            ),
          },
          {
            title: 'Статус',
            render: (_, n) => (
              <>
                <Tag color={STATUSES[n.status]?.color}>{STATUSES[n.status]?.label ?? n.status}</Tag>
                {n.channel && <Typography.Text type="secondary">{CHANNELS[n.channel] ?? n.channel}</Typography.Text>}
                {n.status === 'sent' && n.sent_at && <div>{dateTime(n.sent_at)}</div>}
                {n.status === 'pending' && <div>не раньше {dateTime(n.send_after)}</div>}
                {n.last_error && (
                  <div>
                    <Typography.Text type="danger">{n.last_error}</Typography.Text>
                  </div>
                )}
              </>
            ),
          },
          { title: 'Попыток', dataIndex: 'attempts', align: 'right' },
          {
            key: 'act',
            render: (_, n) =>
              (n.status === 'failed' || n.status === 'skipped') && (
                <Popconfirm title="Отправить уведомление ещё раз?" onConfirm={() => retry.mutateAsync(n.id).catch(() => undefined)}>
                  <Button size="small" loading={retry.isPending && retry.variables === n.id}>
                    Повторить
                  </Button>
                </Popconfirm>
              ),
          },
        ]}
      />
    </>
  )
}
