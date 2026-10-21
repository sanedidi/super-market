// Склад продуктов → Заготовки (Figma П11) и окно «Произвести» (П12).
import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Alert, App, Button, Card, Col, DatePicker, Empty, InputNumber, Modal, Row, Select, Space, Spin, Table, Tag, Typography } from 'antd'
import { CheckCircleFilled, ExperimentOutlined, InfoCircleOutlined, PlusOutlined, WarningOutlined } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { LoadError, PageTitle, api, dateTime, errorText, money, qty, tr, useDebounced, useItem, useList } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import type { Employee } from '../../types'
import { StockTabs } from './common'
import type { Dish, Production, ProductionPreview } from './types'

const when = (v: string | null | undefined) => {
  if (!v) return '—'
  const d = dayjs(v)
  if (d.isSame(dayjs(), 'day')) return tr('сегодня', 'bugun') + ' ' + d.format('HH:mm')
  if (d.isSame(dayjs().add(1, 'day'), 'day')) return tr('завтра', 'ertaga') + ' ' + d.format('HH:mm')
  if (d.isSame(dayjs().subtract(1, 'day'), 'day')) return tr('вчера', 'kecha') + ' ' + d.format('HH:mm')
  return dateTime(v)
}

export function PrepsPage() {
  const nav = useNavigate()
  const { can } = useStore()
  const [sp, setSp] = useSearchParams()
  const manage = can('catalog.manage')
  const produce = can('inventory.manage')
  const list = useList<Dish>('/store/cafe/dishes', { kind: 'prep', limit: 200 })
  const preps = list.data ?? []
  const selectedId = sp.get('id') ?? preps[0]?.id
  const [producing, setProducing] = useState(false)

  return (
    <NeedStore>
      <PageTitle
        title={tr('Склад продуктов', 'Mahsulotlar ombori')}
        tabs={<StockTabs />}
        extra={
          manage && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => nav('/kitchen-stock/preps/new')}>
              {tr('Заготовка', 'Yarim tayyor')}
            </Button>
          )
        }
      />
      <Typography.Paragraph type="secondary">
        {tr(
          'Заготовки — то, что кухня готовит заранее партиями: тесто, фарш, бульон, лапша. Техкарта блюда списывает заготовку, а заготовка — продукты.',
          'Yarim tayyorlar — oshxona oldindan partiyalab tayyorlaydigan narsalar: xamir, qiyma, shoʻrva, lagʻmon. Taom texkartasi yarim tayyorni, yarim tayyor esa mahsulotlarni hisobdan chiqaradi.',
        )}
      </Typography.Paragraph>
      <LoadError error={list.error} retry={() => list.refetch()} />
      {list.isLoading ? (
        <Spin />
      ) : preps.length === 0 ? (
        <Card>
          <Empty description={tr('Заготовок пока нет. Тесто, фарш, бульон — заведите их, чтобы самса и манты списывали заготовку.', 'Hozircha yarim tayyorlar yoʻq.')} />
        </Card>
      ) : (
        <Row gutter={16}>
          <Col xs={24} lg={8}>
            <Card styles={{ body: { padding: 8 } }}>
              {preps.map((p) => (
                <div
                  key={p.id}
                  onClick={() => setSp({ id: p.id })}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    padding: '12px 14px',
                    borderRadius: 12,
                    cursor: 'pointer',
                    background: p.id === selectedId ? '#fef3f2' : undefined,
                    borderLeft: p.id === selectedId ? '3px solid #d92d20' : '3px solid transparent',
                  }}
                >
                  <Space>
                    <ExperimentOutlined style={{ fontSize: 18, color: 'var(--sm-muted)' }} />
                    <div>
                      <b>{p.name}</b>
                      <div style={{ fontSize: 12, color: 'var(--sm-muted)' }}>
                        {!p.has_recipe ? tr('нет техкарты', 'texkarta yoʻq') : p.shelf_hours ? tr(`хранится ${p.shelf_hours} ч`, `${p.shelf_hours} soat saqlanadi`) : tr('без срока', 'muddatsiz')}
                      </div>
                    </div>
                  </Space>
                  {!p.is_active && <Tag>{tr('выкл.', 'oʻch.')}</Tag>}
                </div>
              ))}
            </Card>
          </Col>
          <Col xs={24} lg={16}>{selectedId && <PrepDetails key={selectedId} id={selectedId} canProduce={produce} manage={manage} onProduce={() => setProducing(true)} />}</Col>
        </Row>
      )}
      {selectedId && <ProduceModal open={producing} prepId={selectedId} onClose={() => setProducing(false)} />}
    </NeedStore>
  )
}

function PrepDetails({ id, canProduce, manage, onProduce }: { id: string; canProduce: boolean; manage: boolean; onProduce: () => void }) {
  const nav = useNavigate()
  const { storeId } = useStore()
  const d = useItem<Dish>(`/store/cafe/dishes/${id}`)
  const history = useList<Production>(storeId ? '/store/cafe/production' : null, { store_id: storeId, product_id: id, limit: 10 })
  if (d.isLoading) return <Spin />
  if (!d.data) return <LoadError error={d.error} retry={() => d.refetch()} />
  const p = d.data
  const lastExpiry = history.data?.find((h) => h.expires_at)?.expires_at
  return (
    <Space direction="vertical" style={{ width: '100%' }} size={16}>
      <Card>
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
          <div>
            <div style={{ fontSize: 20, fontWeight: 800 }}>{p.name}</div>
            <Typography.Text type="secondary">
              {tr('выход в', 'chiqish')} {p.unit_short}
              {p.shelf_hours ? ' · ' + tr(`хранится ${p.shelf_hours} ч`, `${p.shelf_hours} soat saqlanadi`) : ''} · {money(p.cost)} {tr('сум за 1', 'soʻm 1')} {p.unit_short}
            </Typography.Text>
          </div>
          <Space>
            <Card size="small" style={{ background: 'var(--sm-bg)' }}>
              <div style={{ fontSize: 11, color: 'var(--sm-muted)' }}>{tr('ОСТАТОК', 'QOLDIQ')}</div>
              <b>{qty(p.stock, p.unit_short)}</b>
            </Card>
            <Card size="small" style={{ background: 'var(--sm-bg)' }}>
              <div style={{ fontSize: 11, color: 'var(--sm-muted)' }}>{tr('ГОДНО ДО', 'YAROQLI')}</div>
              <b>{when(lastExpiry)}</b>
            </Card>
            {canProduce && (
              <Button type="primary" icon={<ExperimentOutlined />} disabled={!p.has_recipe} onClick={onProduce}>
                {tr('Произвести', 'Ishlab chiqarish')}
              </Button>
            )}
          </Space>
        </div>
      </Card>
      <Row gutter={16}>
        <Col xs={24} xl={13}>
          <Card
            title={tr(`Техкарта · на ${qty(p.yield_qty)} ${p.unit_short}`, `Texkarta · ${qty(p.yield_qty)} ${p.unit_short} uchun`)}
            extra={manage && <Typography.Link onClick={() => nav(`/kitchen-stock/preps/${p.id}/edit`)}>{tr('изменить', 'oʻzgartirish')}</Typography.Link>}
          >
            <Table
              rowKey="line"
              size="small"
              pagination={false}
              dataSource={p.recipe ?? []}
              locale={{ emptyText: tr('Техкарта не заполнена', 'Texkarta toʻldirilmagan') }}
              columns={[
                {
                  title: tr('Продукт', 'Mahsulot'),
                  dataIndex: 'name',
                  render: (v, l) => (
                    <span style={{ color: l.not_tracked ? 'var(--sm-muted)' : undefined }}>
                      {v} {l.not_tracked && <Tag bordered={false}>{tr('не учитываем', 'hisobga olinmaydi')}</Tag>}
                    </span>
                  ),
                },
                { title: tr('Кол-во', 'Miqdor'), dataIndex: 'qty', align: 'right', render: (v, l) => <b>{qty(v, l.unit_short)}</b> },
                { title: tr('Сумма', 'Summa'), dataIndex: 'cost', align: 'right', render: (v, l) => (l.not_tracked ? '—' : money(v)) },
              ]}
            />
            <div style={{ display: 'flex', justifyContent: 'space-between', background: 'var(--sm-bg)', borderRadius: 12, padding: '12px 14px', marginTop: 12 }}>
              <b>{tr(`Себестоимость 1 ${p.unit_short}`, `1 ${p.unit_short} tannarxi`)}</b>
              <b style={{ fontSize: 18 }}>{money(p.cost)}</b>
            </div>
          </Card>
        </Col>
        <Col xs={24} xl={11}>
          <Card title={tr('Где используется', 'Qayerda ishlatiladi')} extra={<Typography.Text type="secondary">{tr(`блюд: ${p.used_in?.length ?? 0}`, `${p.used_in?.length ?? 0} ta taom`)}</Typography.Text>}>
            {(p.used_in ?? []).length === 0 && <Typography.Text type="secondary">{tr('Пока ни в одной техкарте', 'Hali hech qaysi texkartada yoʻq')}</Typography.Text>}
            {(p.used_in ?? []).map((u) => (
              <Card key={u.id} size="small" style={{ marginBottom: 8 }} hoverable onClick={() => nav(u.kind === 'prep' ? `/kitchen-stock/preps?id=${u.id}` : `/menu/dishes/${u.id}`)}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <b>{u.name}</b>
                  <Typography.Link>
                    {qty(u.qty, p.unit_short)} / {u.unit_short}
                  </Typography.Link>
                </div>
              </Card>
            ))}
            <Alert
              type="info"
              showIcon
              icon={<InfoCircleOutlined />}
              style={{ marginTop: 8 }}
              message={tr('Продали блюдо — списалась заготовка. Продукты списались раньше, когда заготовку произвели.', 'Taom sotildi — yarim tayyor hisobdan chiqdi. Mahsulotlar avvalroq, yarim tayyor ishlab chiqarilganda chiqqan.')}
            />
          </Card>
        </Col>
      </Row>
      <Card title={tr('Производство', 'Ishlab chiqarish')}>
        <Table<Production>
          rowKey="id"
          size="small"
          pagination={false}
          loading={history.isLoading}
          dataSource={history.data ?? []}
          locale={{ emptyText: tr('Ещё не производили', 'Hali ishlab chiqarilmagan') }}
          columns={[
            { title: tr('Когда', 'Qachon'), dataIndex: 'produced_at', render: (v) => <b>{when(v)}</b> },
            { title: tr('Кто', 'Kim'), dataIndex: 'cook', render: (v, r) => v ?? r.created_by },
            { title: tr('Выход', 'Chiqish'), dataIndex: 'qty', align: 'right', render: (v, r) => <b>{qty(v, r.unit_short)}</b> },
            { title: tr('Себестоимость', 'Tannarx'), dataIndex: 'cost', align: 'right', render: (v) => money(v) },
            { title: tr('Годно до', 'Yaroqli'), dataIndex: 'expires_at', render: (v) => when(v) },
          ]}
        />
      </Card>
    </Space>
  )
}

function ProduceModal({ open, prepId, onClose }: { open: boolean; prepId: string; onClose: () => void }) {
  const { storeId, me } = useStore()
  const { message } = App.useApp()
  const qc = useQueryClient()
  const prep = useItem<Dish>(open ? `/store/cafe/dishes/${prepId}` : null)
  const employees = useList<Employee>(open ? '/store/employees' : null)
  const [amount, setAmount] = useState<string | null>(null)
  const [cook, setCook] = useState<string>()
  const [at, setAt] = useState<Dayjs>(dayjs())
  const [saving, setSaving] = useState(false)
  const debounced = useDebounced(amount ?? '', 400)
  useEffect(() => {
    if (open) {
      setAmount(prep.data ? String(Number(prep.data.yield_qty)) : null)
      setAt(dayjs())
      setCook(me?.employee_id)
    }
  }, [open, prep.data, me])
  const preview = useItem<ProductionPreview>(open && Number(debounced) > 0 ? '/store/cafe/production-preview' : null, { store_id: storeId, product_id: prepId, qty: debounced })
  const p = prep.data
  const pv = preview.data
  const short = (pv?.lines ?? []).filter((l) => !l.enough)

  const submit = async () => {
    if (!(Number(amount) > 0)) {
      message.error(tr('Укажите, сколько получилось', 'Qancha chiqqanini kiriting'))
      return
    }
    setSaving(true)
    try {
      await api.post('/store/cafe/production', {
        client_uid: crypto.randomUUID(),
        store_id: storeId,
        product_id: prepId,
        qty: amount,
        cook_id: cook ?? null,
        produced_at: at.toISOString(),
      })
      message.success(tr('Заготовка пришла на склад', 'Yarim tayyor omborga keldi'))
      qc.invalidateQueries({ queryKey: [`/store/cafe/dishes/${prepId}`] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/production'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/stock'] })
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      open={open}
      onCancel={onClose}
      width={640}
      title={
        <div>
          {tr('Произвести', 'Ishlab chiqarish')}: {p?.name}
          <div style={{ fontSize: 13, fontWeight: 400, color: 'var(--sm-muted)' }}>
            {tr('продукты спишутся по техкарте, заготовка придёт на склад', 'mahsulotlar texkarta boʻyicha chiqadi, yarim tayyor omborga keladi')}
            {pv ? ` «${pv.warehouse_name}»` : ''}
          </div>
        </div>
      }
      okText={tr('Провести', 'Oʻtkazish')}
      cancelText={tr('Отмена', 'Bekor qilish')}
      onOk={submit}
      confirmLoading={saving}
      destroyOnHidden
    >
      <Row gutter={12}>
        <Col span={8}>
          <Typography.Text type="secondary">{tr('Сколько получилось', 'Qancha chiqdi')}</Typography.Text>
          <InputNumber<string> stringMode min="0" value={amount} onChange={setAmount} addonAfter={p?.unit_short} style={{ width: '100%' }} size="large" autoFocus />
        </Col>
        <Col span={8}>
          <Typography.Text type="secondary">{tr('Кто готовил', 'Kim tayyorladi')}</Typography.Text>
          <Select
            size="large"
            style={{ width: '100%' }}
            value={cook}
            onChange={setCook}
            showSearch
            optionFilterProp="label"
            options={(employees.data ?? []).map((e) => ({ value: e.id, label: e.full_name }))}
          />
        </Col>
        <Col span={8}>
          <Typography.Text type="secondary">{tr('Когда', 'Qachon')}</Typography.Text>
          <DatePicker
            size="large"
            showTime={{ format: 'HH:mm' }}
            format="DD.MM HH:mm"
            value={at}
            onChange={(v) => v && setAt(v)}
            disabledDate={(d) => d.isAfter(dayjs().endOf('day')) || d.isBefore(dayjs().subtract(7, 'day').startOf('day'))}
            allowClear={false}
            style={{ width: '100%' }}
          />
        </Col>
      </Row>
      <Typography.Text type="secondary" style={{ display: 'block', margin: '16px 0 6px' }}>
        {tr('Спишется со склада', 'Ombordan chiqadi')}
      </Typography.Text>
      <Table
        rowKey="ingredient_id"
        size="small"
        pagination={false}
        loading={preview.isFetching}
        dataSource={pv?.lines ?? []}
        rowClassName={(l) => (!l.enough ? 'sm-row-warning' : '')}
        columns={[
          { title: tr('Продукт', 'Mahsulot'), dataIndex: 'name' },
          { title: tr('Спишется', 'Chiqadi'), dataIndex: 'qty', align: 'right', render: (v, l) => <b>{qty(v, l.unit_short)}</b> },
          { title: tr('На складе', 'Omborda'), dataIndex: 'stock', align: 'right', render: (v, l) => <span style={{ color: !l.enough ? '#b54708' : undefined }}>{qty(v, l.unit_short)}</span> },
          {
            key: 's',
            render: (_, l) =>
              l.enough ? (
                <Typography.Text type="success">
                  <CheckCircleFilled /> {tr('хватает', 'yetadi')}
                </Typography.Text>
              ) : (
                <Typography.Text type="warning">
                  <WarningOutlined /> {tr('не хватает', 'yetmaydi')} {qty(l.short)}
                </Typography.Text>
              ),
          },
        ]}
      />
      {pv?.not_tracked.length ? (
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {tr('Не учитываем', 'Hisobga olinmaydi')}: {pv.not_tracked.join(', ')}
        </Typography.Text>
      ) : null}
      {pv && (
        <Alert
          style={{ marginTop: 12 }}
          type="success"
          showIcon
          message={tr(`На склад придёт: ${p?.name} · ${qty(pv.qty, p?.unit_short)}`, `Omborga keladi: ${p?.name} · ${qty(pv.qty, p?.unit_short)}`)}
          description={
            tr('себестоимость', 'tannarx') +
            ' ' +
            money(pv.cost) +
            (pv.expires_at ? ' · ' + tr('годно до', 'yaroqli') + ' ' + when(dayjs(at).add(p?.shelf_hours ?? 0, 'hour').toISOString()) : '')
          }
        />
      )}
      {short.length > 0 && (
        <Alert
          style={{ marginTop: 12 }}
          type="info"
          showIcon
          message={tr(
            `${short.map((s) => s.name).join(', ')} не хватает — остаток уйдёт в минус, как при продаже. Ближайший приход его закроет.`,
            `${short.map((s) => s.name).join(', ')} yetmaydi — qoldiq sotuvdagidek minusga ketadi. Navbatdagi kirim uni yopadi.`,
          )}
        />
      )}
    </Modal>
  )
}
