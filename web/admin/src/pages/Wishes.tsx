// Спрос на доставку: покупатели нажимают «Хочу доставку» у магазинов, которые
// им не доставляют. Один покупатель — один голос на магазин.
import { useState } from 'react'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Card, Col, Row, Statistic, Table, Tag, Typography } from 'antd'
import { LoadError, PageTitle, api } from '@sm/shared'

interface WishStore {
  store_id: string
  store_name: string
  network_id: string
  network_name: string
  total: number
  week: number
  accepts_online: boolean
  out_of_zone: number
  hidden: boolean
}

interface WishReport {
  totals: { total: number; week: number; stores: number }
  items: WishStore[]
}

const PAGE = 50

function obstacle(r: WishStore) {
  if (r.hidden) return 'Магазин не виден покупателям (отключён, нет склада или подписки)'
  if (!r.accepts_online) return 'Не принимает онлайн-заказы'
  if (r.out_of_zone > 0) return `Вне зоны доставки: ${r.out_of_zone}`
  return 'Уже доставляет этим покупателям'
}

export function Wishes() {
  const [page, setPage] = useState(1)
  const q = useQuery({
    queryKey: ['/admin/delivery-wishes', page],
    queryFn: () => api.get<WishReport>('/admin/delivery-wishes', { limit: PAGE + 1, offset: (page - 1) * PAGE }),
    placeholderData: keepPreviousData,
  })
  const raw = q.data?.items ?? []
  const hasMore = raw.length > PAGE
  const items = hasMore ? raw.slice(0, PAGE) : raw
  const t = q.data?.totals
  return (
    <>
      <PageTitle title="Спрос на доставку" />
      <Typography.Paragraph type="secondary">
        Покупатели нажимают «Хочу доставку» у магазинов, которые им не доставляют. Один покупатель — один голос на магазин.
      </Typography.Paragraph>
      <LoadError error={q.error} retry={() => q.refetch()} />
      <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
        <Col xs={24} md={8}>
          <Card loading={q.isLoading}>
            <Statistic title="Хотят доставку" value={t?.total ?? 0} />
          </Card>
        </Col>
        <Col xs={24} md={8}>
          <Card loading={q.isLoading}>
            <Statistic title="За 7 дней" value={t?.week ?? 0} prefix={t?.week ? '+' : undefined} />
          </Card>
        </Col>
        <Col xs={24} md={8}>
          <Card loading={q.isLoading}>
            <Statistic title="Магазинов с запросами" value={t?.stores ?? 0} />
          </Card>
        </Col>
      </Row>
      <Card styles={{ body: { padding: 0 } }}>
        <Table<WishStore>
          rowKey="store_id"
          loading={q.isFetching}
          dataSource={items}
          scroll={{ x: true }}
          locale={{ emptyText: 'Пока никто не просил доставку' }}
          pagination={
            page > 1 || hasMore
              ? { current: page, pageSize: PAGE, total: (page - 1) * PAGE + items.length + (hasMore ? 1 : 0), onChange: setPage, showSizeChanger: false }
              : false
          }
          columns={[
            { title: 'Магазин', dataIndex: 'store_name' },
            { title: 'Сеть', dataIndex: 'network_name' },
            { title: 'Хотят доставку', dataIndex: 'total', align: 'right', render: (v: number) => <b>{v}</b> },
            { title: 'За 7 дней', dataIndex: 'week', align: 'right', render: (v: number) => (v ? `+${v}` : '—') },
            {
              title: 'Онлайн-заказы',
              dataIndex: 'accepts_online',
              render: (v: boolean) => (v ? <Tag color="green">Включены</Tag> : <Tag color="red">Выключены</Tag>),
            },
            { title: 'Что мешает', key: 'why', render: (_, r) => obstacle(r) },
          ]}
        />
      </Card>
    </>
  )
}
