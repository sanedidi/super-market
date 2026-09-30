// Курьеры магазина: смена, транспорт, активные заказы и последняя точка.
import { useQuery } from '@tanstack/react-query'
import { Button, Card, Space, Table, Tag, Typography } from 'antd'
import { EnvironmentOutlined, ReloadOutlined } from '@ant-design/icons'
import dayjs from 'dayjs'
import { LoadError, PageTitle, api, dateTime, type List } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import type { Courier } from '../types'

export const vehicleTitles: Record<Courier['vehicle'], string> = { foot: 'Пешком', bike: 'Велосипед', scooter: 'Скутер', car: 'Машина' }

/** Точка старше этого считается устаревшей (как у покупателя в отслеживании). */
const FRESH_MIN = 10

export function CouriersPage() {
  const { storeId } = useStore()
  const params = { store_id: storeId }
  const { data, isLoading, isFetching, error, refetch, dataUpdatedAt } = useQuery({
    queryKey: ['/store/couriers', params],
    queryFn: () => api.get<List<Courier>>('/store/couriers', params).then((r) => r.items ?? []),
    enabled: !!storeId,
    refetchInterval: 15_000,
  })
  const onShift = (data ?? []).filter((c) => c.on_shift).length

  return (
    <NeedStore>
      <PageTitle
        title="Курьеры"
        extra={
          <Button icon={<ReloadOutlined spin={isFetching} />} onClick={() => refetch()}>
            {dataUpdatedAt ? dayjs(dataUpdatedAt).format('HH:mm:ss') : 'Обновить'}
          </Button>
        }
      >
        <Typography.Text type="secondary">
          На смене: {onShift} из {data?.length ?? 0}
        </Typography.Text>
      </PageTitle>
      <LoadError error={error} retry={() => refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Courier>
          rowKey="employee_id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          pagination={false}
          locale={{ emptyText: 'Курьеров нет: дайте сотруднику право «Курьер: доставка заказов»' }}
          columns={[
            { title: 'Курьер', dataIndex: 'full_name' },
            {
              title: 'Телефон',
              dataIndex: 'phone',
              render: (v: string) => <a href={`tel:${v}`}>{v}</a>,
            },
            { title: 'Транспорт', dataIndex: 'vehicle', render: (v: Courier['vehicle']) => vehicleTitles[v] ?? v },
            {
              title: 'Смена',
              dataIndex: 'on_shift',
              render: (v: boolean) => (v ? <Tag color="green">На смене</Tag> : <Tag>Не на смене</Tag>),
            },
            {
              title: 'Активных заказов',
              dataIndex: 'active_orders',
              align: 'right',
              render: (v: number) => (v > 0 ? <b>{v}</b> : <Typography.Text type="secondary">0</Typography.Text>),
            },
            {
              title: 'Последняя точка',
              key: 'loc',
              render: (_, c) => {
                if (!c.located_at || c.lat === null || c.lng === null) return <Typography.Text type="secondary">Нет данных</Typography.Text>
                const stale = dayjs().diff(dayjs(c.located_at), 'minute') >= FRESH_MIN
                return (
                  <Space size={4} wrap>
                    <Typography.Text type={stale ? 'secondary' : undefined}>{dateTime(c.located_at)}</Typography.Text>
                    {stale && <Tag>устарела</Tag>}
                    <a href={`https://yandex.ru/maps/?pt=${c.lng},${c.lat}&z=16&l=map`} target="_blank" rel="noreferrer">
                      <EnvironmentOutlined /> На карте
                    </a>
                  </Space>
                )
              },
            },
          ]}
        />
      </Card>
    </NeedStore>
  )
}
