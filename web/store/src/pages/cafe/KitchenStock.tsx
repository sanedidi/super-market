// Склад продуктов → Остатки (Figma П5): сколько осталось, на сколько дней
// хватит, что ушло в минус. Приход, списание, инвентаризация — те же
// документы, что у магазина.
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button, Card, Col, Input, Row, Segmented, Space, Statistic, Table, Tag, Typography } from 'antd'
import { DeleteOutlined, FieldTimeOutlined, InboxOutlined, MinusCircleOutlined, PlusOutlined, SnippetsOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, money, qty, tr, useDebounced, useItem } from '@sm/shared'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import type { Warehouse } from '../../types'
import { docPaths } from '../StockDocs'
import { StockTabs } from './common'
import type { StockItem, StockSummary } from './types'

const daysWord = (d: number) => (d === 1 ? tr('день', 'kun') : d >= 2 && d <= 4 ? tr('дня', 'kun') : tr('дней', 'kun'))

export function KitchenStockPage() {
  const nav = useNavigate()
  const { storeId, can } = useStore()
  const [warehouseId, setWarehouseId] = useState<string>()
  const [q, setQ] = useState('')
  const debounced = useDebounced(q.trim())
  const [status, setStatus] = useState<'' | 'low' | 'minus'>('')
  const data = useItem<StockSummary>(storeId ? '/store/cafe/stock' : null, { store_id: storeId, warehouse_id: warehouseId, q: debounced || undefined, status: status || undefined })
  const manage = can('inventory.manage')
  const d = data.data
  const seesCost = !!d?.value

  return (
    <NeedStore>
      <PageTitle
        title={tr('Склад продуктов', 'Mahsulotlar ombori')}
        tabs={<StockTabs />}
        extra={
          manage && (
            <Space wrap>
              <Button type="primary" icon={<PlusOutlined />} onClick={() => nav(`${docPaths.income}/new`)}>
                {tr('Приход', 'Kirim')}
              </Button>
              <Button icon={<SnippetsOutlined />} onClick={() => nav(`${docPaths.inventory}/new`)}>
                {tr('Инвентаризация', 'Inventarizatsiya')}
              </Button>
              <Button icon={<DeleteOutlined />} onClick={() => nav(`${docPaths.write_off}/new`)}>
                {tr('Списать порчу', 'Buzilganini hisobdan chiqarish')}
              </Button>
            </Space>
          )
        }
      >
        <Input.Search allowClear placeholder={tr('Продукт или штрихкод', 'Mahsulot yoki shtrix-kod')} value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 220 }} />
        <RemoteSelect<Warehouse>
          path="/store/warehouses"
          params={{ store_id: storeId }}
          value={warehouseId}
          onChange={setWarehouseId}
          allowClear
          placeholder={tr('Склад кухни', 'Oshxona ombori')}
          style={{ width: 180 }}
        />
      </PageTitle>
      <Typography.Paragraph type="secondary">
        {tr(
          'Продукты для кухни: приход, остатки, порча. Расход идёт сам — по техкартам при каждой продаже блюда.',
          'Oshxona uchun mahsulotlar: kirim, qoldiq, buzilish. Sarf oʻzi ketadi — har bir taom sotilganda texkarta boʻyicha.',
        )}
      </Typography.Paragraph>
      <LoadError error={data.error} retry={() => data.refetch()} />
      <Row gutter={[12, 12]} style={{ marginBottom: 16 }}>
        <Col xs={12} lg={6}>
          <Card loading={data.isLoading}>
            <Statistic
              title={<span><InboxOutlined /> {tr('Продукты на складе', 'Ombordagi mahsulotlar')}</span>}
              value={seesCost ? money(d?.value) : '—'}
            />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>{tr('по цене закупки', 'xarid narxida')}</Typography.Text>
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card loading={data.isLoading} hoverable onClick={() => setStatus(status === 'low' ? '' : 'low')}>
            <Statistic title={<span><FieldTimeOutlined /> {tr('Заканчиваются', 'Tugayapti')}</span>} value={d?.low ?? 0} valueStyle={{ color: '#b54708' }} />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>{tr('хватит меньше чем на 2 дня', '2 kundan kamga yetadi')}</Typography.Text>
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card loading={data.isLoading} hoverable onClick={() => setStatus(status === 'minus' ? '' : 'minus')}>
            <Statistic title={<span><MinusCircleOutlined /> {tr('В минусе', 'Minusda')}</span>} value={d?.minus ?? 0} valueStyle={{ color: '#b42318' }} />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>{tr('продали больше, чем пришло', 'kelganidan koʻp sotildi')}</Typography.Text>
          </Card>
        </Col>
        <Col xs={12} lg={6}>
          <Card loading={data.isLoading}>
            <Statistic title={<span><DeleteOutlined /> {tr('Порча за неделю', 'Haftalik buzilish')}</span>} value={money(d?.spoil_week ?? 0)} />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {d?.spoil_share ? tr(`${d.spoil_share}% от расхода`, `sarfning ${d.spoil_share}%`) : tr('списания за 7 дней', '7 kunlik hisobdan chiqarish')}
            </Typography.Text>
          </Card>
        </Col>
      </Row>
      <Segmented
        style={{ marginBottom: 12 }}
        value={status}
        onChange={(v) => setStatus(v as '' | 'low' | 'minus')}
        options={[
          { value: '', label: tr('Все', 'Hammasi') },
          { value: 'low', label: tr(`Заканчиваются · ${d?.low ?? 0}`, `Tugayapti · ${d?.low ?? 0}`) },
          { value: 'minus', label: tr(`В минусе · ${d?.minus ?? 0}`, `Minusda · ${d?.minus ?? 0}`) },
        ]}
      />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<StockItem>
          rowKey="product_id"
          loading={data.isLoading || data.isFetching}
          dataSource={d?.items ?? []}
          pagination={{ pageSize: 50, hideOnSinglePage: true, showSizeChanger: false }}
          scroll={{ x: true }}
          rowClassName={(r) => (r.status === 'minus' ? 'sm-row-danger' : '')}
          columns={[
            {
              title: tr('Продукт', 'Mahsulot'),
              dataIndex: 'name',
              render: (v, r) => (
                <span>
                  <b>{v}</b> {r.kind === 'prep' && <Tag bordered={false} color="purple">{tr('заготовка', 'yarim tayyor')}</Tag>}
                </span>
              ),
            },
            {
              title: tr('Остаток', 'Qoldiq'),
              dataIndex: 'qty',
              align: 'right',
              render: (v, r) => <b style={{ color: Number(v) < 0 ? '#b42318' : undefined }}>{qty(v, r.unit_short)}</b>,
            },
            ...(seesCost
              ? [
                  { title: tr('Цена закупки', 'Xarid narxi'), dataIndex: 'cost', align: 'right' as const, render: (v: string | null) => money(v) },
                  { title: tr('Сумма', 'Summa'), dataIndex: 'value', align: 'right' as const, render: (v: string) => (Number(v) > 0 ? money(v) : '—') },
                ]
              : []),
            { title: tr('Расход в день', 'Kunlik sarf'), dataIndex: 'per_day', align: 'right', render: (v, r) => (Number(v) > 0 ? qty(v, r.unit_short) : '—') },
            {
              title: tr('Хватит на', 'Yetadi'),
              key: 'days',
              render: (_, r) => {
                if (r.status === 'minus') return <Tag color="red" bordered={false}>{tr('в минусе', 'minusda')}</Tag>
                if (!r.days_left) return <Typography.Text type="secondary">—</Typography.Text>
                const n = Math.floor(Number(r.days_left))
                return (
                  <Tag color={r.status === 'low' ? 'orange' : 'green'} bordered={false}>
                    {n} {daysWord(n)}
                  </Tag>
                )
              },
            },
            { title: tr('В техкартах', 'Texkartalarda'), dataIndex: 'dish_count', render: (v) => (v ? tr(`${v} блюд`, `${v} ta taom`) : '—') },
            {
              key: 'a',
              align: 'right',
              render: (_, r) =>
                manage && (r.status === 'minus' || r.status === 'low') && r.kind === 'goods' ? (
                  <Button size="small" type="link" icon={<PlusOutlined />} onClick={() => nav(`${docPaths.income}/new`)}>
                    {tr('Приход', 'Kirim')}
                  </Button>
                ) : null,
            },
          ]}
        />
      </Card>
      <Typography.Paragraph type="secondary" style={{ marginTop: 8, fontSize: 12 }}>
        {tr(
          '«Хватит на» — по среднему расходу за 14 дней. «В минусе» — продано по техкартам больше, чем оприходовано: ближайший приход досписывает недостачу, инвентаризация закрывает её по факту.',
          '«Yetadi» — 14 kunlik oʻrtacha sarf boʻyicha. «Minusda» — texkartalar boʻyicha kirimdan koʻp sotilgan: navbatdagi kirim kamomadni hisobdan chiqaradi, inventarizatsiya uni fakt boʻyicha yopadi.',
        )}
      </Typography.Paragraph>
    </NeedStore>
  )
}
