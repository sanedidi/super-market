// Доставка выбранного магазина: приём заказов, часы работы, правила цены, зоны.
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import {
  Alert,
  Button,
  Card,
  Checkbox,
  Col,
  Form,
  InputNumber,
  Row,
  Select,
  Space,
  Switch,
  TimePicker,
  Typography,
} from 'antd'
import { ArrowDownOutlined, ArrowUpOutlined, DeleteOutlined, PlusOutlined } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { LoadError, PageTitle, api, useAction, useItem } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore, Num } from '../ui'
import type { DeliveryRule, DeliverySettings, SlotSettings } from '../types'
import { DeliveryZones } from './DeliveryZones'

// Порядок дней как в жизни: пн … вс (в API 0 — воскресенье).
const DAYS: [number, string][] = [
  [1, 'Понедельник'],
  [2, 'Вторник'],
  [3, 'Среда'],
  [4, 'Четверг'],
  [5, 'Пятница'],
  [6, 'Суббота'],
  [0, 'Воскресенье'],
]

const ruleTitles: Record<DeliveryRule['type'], string> = {
  fixed: 'Фиксированная цена',
  distance: 'По расстоянию',
  zone: 'Цена зоны',
  free_from: 'Бесплатно от суммы',
}

const ruleFields: Record<DeliveryRule['type'], [string, string][]> = {
  fixed: [['price', 'Цена']],
  distance: [
    ['base', 'Базовая цена'],
    ['per_km', 'За каждый км'],
  ],
  zone: [],
  free_from: [['amount', 'Сумма заказа от']],
}

interface DayRow {
  weekday: number
  on: boolean
  opens: Dayjs | null
  closes: Dayjs | null
}

interface RuleRow {
  key: number
  type: DeliveryRule['type']
  params: Record<string, string | null>
}

let seq = 0

export function DeliveryPage() {
  const { storeId } = useStore()
  // key: при смене магазина форма создаётся заново и не несёт настройки прежнего.
  return (
    <NeedStore>
      <DeliveryInner key={storeId} />
    </NeedStore>
  )
}

function DeliveryInner() {
  const { storeId, store } = useStore()
  const { data, isLoading, error, refetch } = useItem<DeliverySettings>(`/store/stores/${storeId}/delivery`)
  const [accepts, setAccepts] = useState(false)
  const [minOrder, setMinOrder] = useState<string | null>('0')
  const [radius, setRadius] = useState<number | null>(0)
  const [etaMin, setEtaMin] = useState<number | null>(null)
  const [etaMax, setEtaMax] = useState<number | null>(null)
  const [days, setDays] = useState<DayRow[]>([])
  const [rules, setRules] = useState<RuleRow[]>([])
  const [zoneCount, setZoneCount] = useState(0)
  const [slots, setSlots] = useState<SlotSettings>({ enabled: false, slot_minutes: 60, days_ahead: 1, lead_minutes: 60, capacity: 5 })

  useEffect(() => {
    if (!data) return
    setAccepts(data.accepts_online)
    setMinOrder(data.min_order_amount)
    setRadius(data.delivery_radius_m)
    setEtaMin(data.eta_min)
    setEtaMax(data.eta_max)
    if (data.slots) setSlots(data.slots)
    setDays(
      DAYS.map(([wd]) => {
        const h = (data.working_hours ?? []).find((x) => x.weekday === wd)
        return {
          weekday: wd,
          on: !!h,
          opens: dayjs(h?.opens ?? '09:00', 'HH:mm'),
          closes: dayjs(h?.closes ?? '22:00', 'HH:mm'),
        }
      }),
    )
    setRules(
      (data.rules ?? []).map((r) => ({
        key: ++seq,
        type: r.type,
        params: Object.fromEntries(Object.entries(r.params ?? {}).map(([k, v]) => [k, String(v)])),
      })),
    )
  }, [data])

  const save = useAction(
    () =>
      api.put(`/store/stores/${storeId}/delivery`, {
        accepts_online: accepts,
        min_order_amount: minOrder || '0',
        delivery_radius_m: radius ?? 0,
        // null очищает обещанное время доставки
        eta_min: etaMin ?? null,
        eta_max: etaMax ?? null,
        slots,
        working_hours: days
          .filter((d) => d.on && d.opens && d.closes)
          .map((d) => ({ weekday: d.weekday, opens: d.opens!.format('HH:mm'), closes: d.closes!.format('HH:mm') })),
        rules: rules.map((r, i) => ({
          type: r.type,
          sort: i + 1,
          params: Object.fromEntries(ruleFields[r.type].map(([k]) => [k, r.params[k] ?? '0'])),
        })),
      }),
    { success: 'Настройки доставки сохранены' },
  )

  const setDay = (wd: number, patch: Partial<DayRow>) => setDays((ds) => ds.map((d) => (d.weekday === wd ? { ...d, ...patch } : d)))
  const move = (i: number, dir: -1 | 1) =>
    setRules((rs) => {
      const next = [...rs]
      const j = i + dir
      if (j < 0 || j >= next.length) return rs
      ;[next[i], next[j]] = [next[j], next[i]]
      return next
    })
  const noGeo = store && (store.lat === null || store.lng === null)

  return (
    <>
      <PageTitle
        title={`Доставка${store ? ' — ' + store.name : ''}`}
        extra={
          <Button type="primary" loading={save.isPending} disabled={isLoading || !data} onClick={() => save.mutate(undefined)}>
            Сохранить
          </Button>
        }
      />
      <LoadError error={error} retry={() => refetch()} />
      {noGeo && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message={
            <>
              Чтобы принимать онлайн-заказы, поставьте точку магазина на карте в разделе <Link to="/settings/stores">Магазины</Link>.
            </>
          }
        />
      )}
      <DeliveryZones
        storeId={storeId}
        storeName={store?.name}
        lat={store?.lat ?? null}
        lng={store?.lng ?? null}
        radiusM={radius}
        onZonesChange={setZoneCount}
      />
      <Row gutter={[16, 16]}>
        <Col xs={24} xl={12}>
          <Card title="Приём заказов" loading={isLoading} style={{ marginBottom: 16 }}>
            <Form layout="vertical">
              <Form.Item label="Принимать онлайн-заказы">
                <Switch checked={accepts} onChange={setAccepts} />
              </Form.Item>
              <Row gutter={16}>
                <Col span={12}>
                  <Form.Item label="Минимальная сумма заказа">
                    <Num value={minOrder} onChange={setMinOrder} />
                  </Form.Item>
                </Col>
                <Col span={12}>
                  <Form.Item label="Радиус доставки, м" extra={zoneCount > 0 ? 'Не действует: есть зоны на карте, доставка только в них' : 'Действует, пока на карте нет зон'}>
                    <InputNumber value={radius} onChange={setRadius} min={0} max={100000} step={500} style={{ width: '100%' }} />
                  </Form.Item>
                </Col>
              </Row>
              <Form.Item label="Время доставки в приложении, минут" extra="Покупатель увидит «25–35 мин». Пустые поля — время не показывается">
                <Space>
                  <InputNumber value={etaMin} onChange={setEtaMin} min={5} max={600} placeholder="от" />
                  —
                  <InputNumber value={etaMax} onChange={setEtaMax} min={5} max={600} placeholder="до" />
                  {(etaMin !== null || etaMax !== null) && (
                    <Button
                      type="link"
                      onClick={() => {
                        setEtaMin(null)
                        setEtaMax(null)
                      }}
                    >
                      Не показывать
                    </Button>
                  )}
                </Space>
              </Form.Item>
            </Form>
          </Card>
          <Card title="Доставка ко времени" loading={isLoading} style={{ marginBottom: 16 }}>
            <Form layout="vertical">
              <Form.Item label="Покупатель может выбрать время" extra="Иначе — только «как можно скорее»">
                <Switch checked={slots.enabled} onChange={(v) => setSlots((s) => ({ ...s, enabled: v }))} />
              </Form.Item>
              {slots.enabled && (
                <Row gutter={16}>
                  <Col xs={12} md={6}>
                    <Form.Item label="Окно, минут">
                      <Select
                        value={slots.slot_minutes}
                        onChange={(v) => setSlots((s) => ({ ...s, slot_minutes: v }))}
                        options={[30, 60, 90, 120, 180, 240].map((v) => ({ value: v, label: v }))}
                      />
                    </Form.Item>
                  </Col>
                  <Col xs={12} md={6}>
                    <Form.Item label="Дней вперёд" extra="0 — только сегодня">
                      <InputNumber value={slots.days_ahead} min={0} max={6} onChange={(v) => setSlots((s) => ({ ...s, days_ahead: v ?? 0 }))} style={{ width: '100%' }} />
                    </Form.Item>
                  </Col>
                  <Col xs={12} md={6}>
                    <Form.Item label="Запас, минут" extra="Не раньше чем через">
                      <InputNumber value={slots.lead_minutes} min={0} max={720} step={15} onChange={(v) => setSlots((s) => ({ ...s, lead_minutes: v ?? 0 }))} style={{ width: '100%' }} />
                    </Form.Item>
                  </Col>
                  <Col xs={12} md={6}>
                    <Form.Item label="Заказов в окно">
                      <InputNumber value={slots.capacity} min={1} max={500} onChange={(v) => setSlots((s) => ({ ...s, capacity: v ?? 1 }))} style={{ width: '100%' }} />
                    </Form.Item>
                  </Col>
                </Row>
              )}
              <Typography.Text type="secondary">Окна строятся по часам работы магазина. Заказ ко времени нужно принять не позже чем за час до окна.</Typography.Text>
            </Form>
          </Card>
          <Card title="Часы работы" loading={isLoading}>
            {days.map((d) => (
              <Row key={d.weekday} gutter={8} align="middle" style={{ marginBottom: 8 }}>
                <Col flex="150px">
                  <Checkbox checked={d.on} onChange={(e) => setDay(d.weekday, { on: e.target.checked })}>
                    {DAYS.find(([w]) => w === d.weekday)?.[1]}
                  </Checkbox>
                </Col>
                <Col flex="auto">
                  {d.on ? (
                    <Space>
                      <TimePicker format="HH:mm" minuteStep={5} value={d.opens} onChange={(v) => setDay(d.weekday, { opens: v })} allowClear={false} />
                      —
                      <TimePicker format="HH:mm" minuteStep={5} value={d.closes} onChange={(v) => setDay(d.weekday, { closes: v })} allowClear={false} />
                    </Space>
                  ) : (
                    <Typography.Text type="secondary">Выходной</Typography.Text>
                  )}
                </Col>
              </Row>
            ))}
            <Typography.Text type="secondary">Закрытие раньше открытия — работа после полуночи.</Typography.Text>
          </Card>
        </Col>
        <Col xs={24} xl={12}>
          <Card
            title="Правила цены доставки"
            loading={isLoading}
            style={{ marginBottom: 16 }}
            extra={
              <Button icon={<PlusOutlined />} onClick={() => setRules((rs) => [...rs, { key: ++seq, type: 'fixed', params: {} }])}>
                Правило
              </Button>
            }
          >
            {zoneCount > 0 ? (
              <Alert
                type="info"
                showIcon
                style={{ marginBottom: 8 }}
                message="Цена доставки берётся из зоны на карте. Здесь действует только «Бесплатно от суммы»."
              />
            ) : (
              <Typography.Paragraph type="secondary">Правила проверяются сверху вниз, первое подходящее задаёт цену.</Typography.Paragraph>
            )}
            {rules.length === 0 && <Alert type="info" message="Правил нет — доставка бесплатная" style={{ marginBottom: 8 }} />}
            {rules.map((r, i) => (
              <Card key={r.key} size="small" style={{ marginBottom: 8 }}>
                <Row gutter={8} align="middle" wrap>
                  <Col flex="200px">
                    <Select
                      value={r.type}
                      style={{ width: '100%' }}
                      onChange={(t: DeliveryRule['type']) => setRules((rs) => rs.map((x) => (x.key === r.key ? { ...x, type: t, params: {} } : x)))}
                      options={(Object.keys(ruleTitles) as DeliveryRule['type'][])
                        .filter((t) => t !== 'zone' || r.type === 'zone')
                        .map((t) => ({ value: t, label: ruleTitles[t] }))}
                    />
                  </Col>
                  {ruleFields[r.type].map(([k, label]) => (
                    <Col flex="150px" key={k}>
                      <Num
                        placeholder={label}
                        
                        value={r.params[k] ?? null}
                       
                        onChange={(v) => setRules((rs) => rs.map((x) => (x.key === r.key ? { ...x, params: { ...x.params, [k]: v } } : x)))}
                      />
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                        {label}
                      </Typography.Text>
                    </Col>
                  ))}
                  {r.type === 'zone' && (
                    <Col flex="auto">
                      <Typography.Text type="secondary">Цена берётся из зоны покупателя</Typography.Text>
                    </Col>
                  )}
                  <Col flex="none" style={{ marginLeft: 'auto' }}>
                    <Space.Compact>
                      <Button icon={<ArrowUpOutlined />} disabled={i === 0} onClick={() => move(i, -1)} />
                      <Button icon={<ArrowDownOutlined />} disabled={i === rules.length - 1} onClick={() => move(i, 1)} />
                      <Button danger icon={<DeleteOutlined />} onClick={() => setRules((rs) => rs.filter((x) => x.key !== r.key))} />
                    </Space.Compact>
                  </Col>
                </Row>
              </Card>
            ))}
          </Card>
        </Col>
      </Row>
    </>
  )
}
