// Блюдо или заготовка: основное, техкарта с себестоимостью, модификаторы,
// где продаётся (Figma П2; заготовка — П11 «изменить»).
import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import {
  Alert,
  App,
  Button,
  Card,
  Checkbox,
  Col,
  Form,
  Input,
  InputNumber,
  Row,
  Select,
  Space,
  Spin,
  Statistic,
  Switch,
  Table,
  Tag,
  Tooltip,
  Typography,
} from 'antd'
import { ArrowLeftOutlined, CheckOutlined, CloseOutlined, InfoCircleOutlined, LinkOutlined, StopOutlined } from '@ant-design/icons'
import { ImageUpload, LoadError, RemoteSelect, TranslateButton, api, errorText, money, qty, tr, useItem, useList } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../../ctx'
import { IngredientSelect, markupPct } from './common'
import type { Dish, Ingredient, Kind, MenuGroup, ModifierGroup, Workshop } from './types'

type Line = { key: string; ingredient_id: string; name: string; kind: Kind; unit_short: string; qty: string; unit_cost: string | null; not_tracked: boolean }

type DictItem = { id: string; name: string; short_name: string }

let seq = 0
const key = () => `l${++seq}`

export function DishEditorPage({ kind: forcedKind }: { kind?: Kind }) {
  const { id = 'new' } = useParams()
  const isNew = id === 'new'
  const dish = useItem<Dish>(isNew ? null : `/store/cafe/dishes/${id}`)
  if (!isNew && dish.isLoading) return <Spin style={{ display: 'block', marginTop: 48 }} />
  if (!isNew && dish.error) return <LoadError error={dish.error} retry={() => dish.refetch()} />
  return <DishEditor key={id} dish={dish.data} kind={dish.data?.kind ?? forcedKind ?? 'dish'} />
}

function DishEditor({ dish, kind }: { dish?: Dish; kind: Kind }) {
  const nav = useNavigate()
  const qc = useQueryClient()
  const { message } = App.useApp()
  const { stores, storeId, can } = useStore()
  const manage = can('catalog.manage')
  const isPrep = kind === 'prep'
  const backTo = isPrep ? '/kitchen-stock/preps' : '/menu'
  const [form] = Form.useForm()
  const [lines, setLines] = useState<Line[]>(
    () =>
      dish?.recipe?.map((l) => ({
        key: key(),
        ingredient_id: l.ingredient_id,
        name: l.name,
        kind: l.kind,
        unit_short: l.unit_short,
        qty: l.qty,
        unit_cost: l.has_cost ? l.unit_cost : null,
        not_tracked: l.not_tracked,
      })) ?? [],
  )
  const [modGroups, setModGroups] = useState<string[]>(dish?.modifier_group_ids ?? [])
  const [storeIds, setStoreIds] = useState<string[]>(dish?.store_ids ?? stores.filter((s) => s.status === 'active').map((s) => s.id))
  // Новое блюдо — во всех точках; список точек мог догрузиться позже.
  const [touchedStores, setTouchedStores] = useState(!!dish)
  useEffect(() => {
    if (!touchedStores && stores.length) setStoreIds(stores.filter((s) => s.status === 'active').map((s) => s.id))
  }, [stores, touchedStores])
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const allMods = useList<ModifierGroup>(isPrep ? null : '/store/cafe/modifier-groups')
  const groups = useList<MenuGroup>('/store/cafe/menu-groups')
  const workshops = useList<Workshop>('/store/cafe/workshops')

  useEffect(() => {
    form.setFieldsValue({
      name: dish?.name_ru ?? '',
      name_uz: dish?.name_uz ?? '',
      menu_group_id: dish?.menu_group_id ?? undefined,
      workshop_id: dish?.workshop_id ?? undefined,
      price: dish ? Number(dish.price) : undefined,
      cook_minutes: dish?.cook_minutes ?? undefined,
      shelf_hours: dish?.shelf_hours ?? undefined,
      ikpu: dish?.ikpu ?? '',
      menu_code: dish?.menu_code ?? undefined,
      portion: dish?.portion ?? '',
      yield_qty: dish ? Number(dish.yield_qty) : 1,
      unit_id: dish?.unit_id,
      images: dish?.images ?? [],
      is_active: dish?.is_active ?? true,
    })
  }, [dish, form])

  const yieldQty = Form.useWatch('yield_qty', form) ?? 1
  const price = Form.useWatch('price', form)
  const unitId = Form.useWatch('unit_id', form)
  const units = useList<DictItem>(isPrep ? '/store/catalog/units' : null)
  const unitShort = dish?.unit_short ?? units.data?.find((u) => u.id === unitId)?.short_name ?? (isPrep ? '' : tr('порц', 'porsiya'))

  // Себестоимость считаем сразу, по ценам продуктов (сервер считает так же).
  const { cost, complete } = useMemo(() => {
    let sum = 0
    let ok = lines.length > 0
    for (const l of lines) {
      if (l.not_tracked) continue
      if (l.unit_cost === null) ok = false
      sum += Number(l.qty || 0) * Number(l.unit_cost ?? 0)
    }
    const y = Number(yieldQty) || 1
    return { cost: sum / y, complete: ok }
  }, [lines, yieldQty])
  const priceStr = String(price ?? 0)
  const mPct = markupPct(priceStr, String(cost))
  const foodCost = Number(price) > 0 ? Math.round((cost / Number(price)) * 1000) / 10 : null

  const setLine = (k: string, patch: Partial<Line>) => {
    setDirty(true)
    setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...patch } : l)))
  }
  const addIngredient = (i: Ingredient) => {
    setDirty(true)
    if (lines.some((l) => l.ingredient_id === i.id)) {
      message.info(tr('Этот продукт уже есть в техкарте', 'Bu mahsulot texnologik kartada bor'))
      return
    }
    if (dish && i.id === dish.id) return
    setLines((ls) => [...ls, { key: key(), ingredient_id: i.id, name: i.name, kind: i.kind, unit_short: i.unit_short, qty: '', unit_cost: i.cost, not_tracked: false }])
  }

  const save = async () => {
    let v: Record<string, unknown>
    try {
      v = await form.validateFields()
    } catch {
      return
    }
    const bad = lines.find((l) => !(Number(l.qty) > 0))
    if (bad) {
      message.error(tr(`Укажите количество: «${bad.name}»`, `Miqdorni kiriting: «${bad.name}»`))
      return
    }
    const body: Record<string, unknown> = {
      name: v.name,
      name_uz: v.name_uz,
      menu_group_id: v.menu_group_id ?? null,
      workshop_id: v.workshop_id ?? null,
      price: v.price ?? 0,
      cook_minutes: v.cook_minutes ?? null,
      shelf_hours: v.shelf_hours ?? null,
      ikpu: v.ikpu ?? '',
      menu_code: v.menu_code ?? null,
      portion: v.portion ?? '',
      yield_qty: v.yield_qty ?? 1,
      images: (v.images as string[] | undefined) ?? [],
      is_active: v.is_active,
      store_ids: storeIds,
      recipe: lines.map((l) => ({ ingredient_id: l.ingredient_id, qty: l.qty, not_tracked: l.not_tracked })),
    }
    if (!isPrep) body.modifier_group_ids = modGroups
    if (isPrep || v.unit_id) body.unit_id = v.unit_id
    setSaving(true)
    try {
      const out = dish
        ? await api.patch<Dish>(`/store/cafe/dishes/${dish.id}`, body)
        : await api.post<Dish>('/store/cafe/dishes', { ...body, kind })
      message.success(tr('Сохранено', 'Saqlandi'))
      setDirty(false)
      qc.invalidateQueries({ queryKey: ['/store/cafe/dishes'] })
      qc.invalidateQueries({ queryKey: [`/store/cafe/dishes/${out.id}`] })
      if (!dish) nav(isPrep ? `/kitchen-stock/preps?id=${out.id}` : `/menu/dishes/${out.id}`, { replace: true })
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  const stopped = !!(dish && storeId && dish.stop_store_ids.includes(storeId))
  const toggleStop = async (on: boolean) => {
    if (!dish) return
    try {
      await api.put('/store/cafe/stop-list', { store_id: storeId, product_id: dish.id, stopped: on })
      qc.invalidateQueries({ queryKey: [`/store/cafe/dishes/${dish.id}`] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/stop-list'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/dishes'] })
      message.success(on ? tr('Блюдо на стопе', 'Taom stopda') : tr('Снято со стопа', 'Stopdan olindi'))
    } catch (e) {
      message.error(errorText(e))
    }
  }

  const linked = (allMods.data ?? []).filter((g) => modGroups.includes(g.id)).sort((a, b) => modGroups.indexOf(a.id) - modGroups.indexOf(b.id))
  const title = dish?.name ?? (isPrep ? tr('Новая заготовка', 'Yangi yarim tayyor') : tr('Новое блюдо', 'Yangi taom'))

  return (
    <div>
      <div className="sm-page-head" style={{ marginBottom: 16 }}>
        <div className="sm-head" style={{ alignItems: 'center' }}>
          <Space align="center" size={12} style={{ minWidth: 0 }}>
            <Button type="text" icon={<ArrowLeftOutlined />} onClick={() => nav(backTo)} />
            <div style={{ minWidth: 0 }}>
              <h1 className="sm-head-title" style={{ margin: 0 }}>
                {title} {stopped && <Tag color="orange">{tr('стоп-лист', 'stop-roʻyxat')}</Tag>}
              </h1>
              <Typography.Text type="secondary" style={{ fontSize: 13 }}>
                {isPrep ? tr('Склад продуктов → Заготовки', 'Mahsulotlar ombori → Yarim tayyorlar') : tr('Меню', 'Menyu') + (dish?.menu_group_name ? ' → ' + dish.menu_group_name : '')}
                {' · '}
                {isPrep ? tr('заготовка вашего кафе', 'kafengiz yarim tayyori') : tr('блюдо вашего кафе', 'kafengiz taomi')}
              </Typography.Text>
            </div>
          </Space>
          <Space>
            {dish && !isPrep && manage && (
              <Button icon={<StopOutlined />} onClick={() => toggleStop(!stopped)}>
                {stopped ? tr('Снять со стопа', 'Stopdan olish') : tr('На стоп', 'Stopga')}
              </Button>
            )}
            {manage && (
              <Button type="primary" icon={<CheckOutlined />} loading={saving} onClick={save}>
                {tr('Сохранить', 'Saqlash')}
              </Button>
            )}
          </Space>
        </div>
      </div>

      <Form form={form} layout="vertical" disabled={!manage} onValuesChange={() => setDirty(true)} requiredMark={false}>
        <Row gutter={16}>
          <Col xs={24} xl={16}>
            <Card title={tr('Основное', 'Asosiy')} style={{ marginBottom: 16 }}>
              <Row gutter={16}>
                <Col flex="120px">
                  <Form.Item name="images" label={tr('Фото', 'Rasm')}>
                    <ImageUpload multiple max={1} />
                  </Form.Item>
                </Col>
                <Col flex="auto">
                  <Row gutter={12}>
                    <Col xs={24} md={8}>
                      <Form.Item name="name_uz" label="Oʻzbekcha">
                        <Input placeholder={isPrep ? 'Somsa xamiri' : 'Choyxona palovi'} />
                      </Form.Item>
                    </Col>
                    <Col xs={24} md={8}>
                      <Form.Item
                        name="name"
                        label={
                          <Space size={4}>
                            Русский
                            <TranslateButton to="ru" source={() => form.getFieldValue('name_uz')} onResult={(t) => form.setFieldValue('name', t)} />
                          </Space>
                        }
                        rules={[{ required: true, message: tr('Укажите название', 'Nomini kiriting') }]}
                      >
                        <Input placeholder={isPrep ? 'Тесто для самсы' : 'Плов чайханский'} />
                      </Form.Item>
                    </Col>
                    {!isPrep ? (
                      <Col xs={24} md={8}>
                        <Form.Item name="menu_group_id" label={tr('Группа меню', 'Menyu guruhi')}>
                          <Select allowClear placeholder={tr('Без группы', 'Guruhsiz')} options={(groups.data ?? []).map((g) => ({ value: g.id, label: g.name }))} />
                        </Form.Item>
                      </Col>
                    ) : (
                      <Col xs={24} md={8}>
                        <Form.Item name="unit_id" label={tr('Единица', 'Birlik')} rules={[{ required: true, message: tr('Выберите единицу', 'Birlikni tanlang') }]}>
                          <RemoteSelect<DictItem> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} disabled={!!dish} />
                        </Form.Item>
                      </Col>
                    )}
                  </Row>
                  <Row gutter={12}>
                    <Col xs={24} md={6}>
                      <Form.Item name="workshop_id" label={tr('Цех', 'Sex')}>
                        <Select
                          allowClear
                          placeholder={isPrep ? tr('Любой', 'Istalgan') : tr('Как у группы', 'Guruhdagidek')}
                          options={(workshops.data ?? []).map((w) => ({ value: w.id, label: w.name }))}
                        />
                      </Form.Item>
                    </Col>
                    {!isPrep && (
                      <Col xs={12} md={6}>
                        <Form.Item name="price" label={tr('Цена продажи', 'Sotuv narxi')} rules={[{ required: true, message: tr('Укажите цену', 'Narxni kiriting') }]}>
                          <InputNumber min={0} step={1000} style={{ width: '100%' }} addonAfter={tr('сум', 'soʻm')} />
                        </Form.Item>
                      </Col>
                    )}
                    {!isPrep ? (
                      <Col xs={12} md={6}>
                        <Form.Item name="cook_minutes" label={tr('Норма приготовления', 'Tayyorlash meʼyori')}>
                          <InputNumber min={1} max={600} style={{ width: '100%' }} addonAfter={tr('мин', 'daq')} />
                        </Form.Item>
                      </Col>
                    ) : (
                      <Col xs={12} md={6}>
                        <Form.Item name="shelf_hours" label={tr('Срок хранения', 'Saqlash muddati')}>
                          <InputNumber min={1} max={8760} style={{ width: '100%' }} addonAfter={tr('ч', 'soat')} />
                        </Form.Item>
                      </Col>
                    )}
                    {!isPrep && (
                      <Col xs={24} md={6}>
                        <Form.Item
                          name="ikpu"
                          label={tr('ИКПУ (для чека)', 'MXIK (chek uchun)')}
                          rules={[{ pattern: /^(\d{17})?$/, message: tr('17 цифр', '17 ta raqam') }]}
                        >
                          <Input maxLength={17} placeholder="10202001001000000" />
                        </Form.Item>
                      </Col>
                    )}
                  </Row>
                  {!isPrep && (
                    <Row gutter={12}>
                      <Col xs={12} md={6}>
                        <Form.Item name="menu_code" label={tr('Код на кассе', 'Kassadagi kod')} tooltip={tr('Короткий номер: «12» + Enter на кассе', 'Qisqa raqam: kassada «12» + Enter')}>
                          <InputNumber min={1} max={99999} style={{ width: '100%' }} />
                        </Form.Item>
                      </Col>
                      <Col xs={12} md={6}>
                        <Form.Item name="portion" label={tr('Выход порции', 'Porsiya chiqishi')}>
                          <Input maxLength={30} placeholder="350 г" />
                        </Form.Item>
                      </Col>
                      <Col xs={12} md={6}>
                        <Form.Item name="is_active" label={tr('В продаже', 'Sotuvda')} valuePropName="checked">
                          <Switch />
                        </Form.Item>
                      </Col>
                    </Row>
                  )}
                </Col>
              </Row>
            </Card>

            <Card
              title={
                <Space>
                  {tr('Техкарта', 'Texnologik karta')}
                  <Typography.Text type="secondary" style={{ fontWeight: 400 }}>
                    · {tr('на', 'uchun')} {isPrep ? `${qty(yieldQty)} ${unitShort}` : tr('1 порцию', '1 porsiya')}
                  </Typography.Text>
                </Space>
              }
              extra={
                isPrep && (
                  <Space>
                    <Typography.Text type="secondary">{tr('Выход', 'Chiqish')}</Typography.Text>
                    <Form.Item name="yield_qty" noStyle>
                      <InputNumber min={0.001} step={1} style={{ width: 110 }} addonAfter={unitShort || undefined} />
                    </Form.Item>
                  </Space>
                )
              }
              style={{ marginBottom: 16 }}
            >
              <Table<Line>
                rowKey="key"
                size="middle"
                pagination={false}
                dataSource={lines}
                locale={{ emptyText: tr('Добавьте продукты — из них считается себестоимость и списание', 'Mahsulotlarni qoʻshing — ulardan tannarx va hisobdan chiqarish hisoblanadi') }}
                columns={[
                  {
                    title: tr('Продукт со склада', 'Ombordagi mahsulot'),
                    dataIndex: 'name',
                    render: (v, l) => (
                      <span style={{ color: l.not_tracked ? 'var(--sm-muted)' : undefined }}>
                        {v} {l.kind === 'prep' && <Tag bordered={false} color="purple">{tr('заготовка', 'yarim tayyor')}</Tag>}
                      </span>
                    ),
                  },
                  {
                    title: tr('Кол-во', 'Miqdor'),
                    dataIndex: 'qty',
                    width: 130,
                    render: (v, l) => (
                      <InputNumber<string>
                        stringMode
                        min="0"
                        step="0.01"
                        value={v}
                        disabled={!manage}
                        status={!(Number(v) > 0) ? 'error' : undefined}
                        onChange={(x) => setLine(l.key, { qty: x ?? '' })}
                        style={{ width: 110 }}
                      />
                    ),
                  },
                  { title: tr('Ед.', 'Birl.'), dataIndex: 'unit_short', width: 60 },
                  {
                    title: tr('Цена закупки', 'Xarid narxi'),
                    dataIndex: 'unit_cost',
                    align: 'right',
                    render: (v, l) =>
                      l.not_tracked ? '—' : v === null ? <Typography.Text type="warning">{tr('не приходовали', 'kirim yoʻq')}</Typography.Text> : `${money(v)} / ${l.unit_short}`,
                  },
                  {
                    title: tr('Сумма', 'Summa'),
                    key: 'sum',
                    align: 'right',
                    render: (_, l) => (l.not_tracked || l.unit_cost === null ? '—' : <b>{money(Number(l.qty || 0) * Number(l.unit_cost))}</b>),
                  },
                  {
                    title: (
                      <Tooltip title={tr('Не учитываем на складе (вода): не списывается и не в себестоимости', 'Omborda hisobga olinmaydi (suv): hisobdan chiqmaydi va tannarxga kirmaydi')}>
                        {tr('Не учит.', 'Hisobsiz')} <InfoCircleOutlined />
                      </Tooltip>
                    ),
                    dataIndex: 'not_tracked',
                    align: 'center',
                    width: 90,
                    render: (v, l) => <Checkbox checked={v} disabled={!manage} onChange={(e) => setLine(l.key, { not_tracked: e.target.checked })} />,
                  },
                  {
                    key: 'x',
                    width: 40,
                    render: (_, l) =>
                      manage && (
                        <Button
                          type="text"
                          size="small"
                          icon={<CloseOutlined />}
                          onClick={() => {
                            setDirty(true)
                            setLines((ls) => ls.filter((x) => x.key !== l.key))
                          }}
                        />
                      ),
                  },
                ]}
              />
              {manage && (
                <div style={{ marginTop: 12 }}>
                  <IngredientSelect onPick={addIngredient} value={undefined} style={{ width: '100%', maxWidth: 520 }} placeholder={tr('+ Добавить продукт — поиск по складу и центральной базе, штрихкод', '+ Mahsulot qoʻshish — ombor va markaziy baza boʻyicha qidiruv, shtrix-kod')} />
                </div>
              )}
              <Row gutter={12} style={{ marginTop: 16 }}>
                <Col xs={12} md={6}>
                  <Card size="small" style={{ background: 'var(--sm-bg)' }}>
                    <Statistic
                      title={isPrep ? tr(`Себестоимость 1 ${unitShort}`, `1 ${unitShort} tannarxi`) : tr('Себестоимость', 'Tannarx')}
                      value={money(cost)}
                      suffix={!complete && lines.length > 0 ? <Tooltip title={tr('Не у всех продуктов есть цена прихода', 'Hamma mahsulotlarda kirim narxi yoʻq')}>*</Tooltip> : undefined}
                    />
                  </Card>
                </Col>
                {!isPrep && (
                  <>
                    <Col xs={12} md={6}>
                      <Card size="small" style={{ background: 'var(--sm-bg)' }}>
                        <Statistic title={tr('Цена', 'Narx')} value={money(price ?? 0)} />
                      </Card>
                    </Col>
                    <Col xs={12} md={6}>
                      <Card size="small" style={{ background: 'var(--sm-bg)' }}>
                        <Statistic title={tr('Наценка', 'Ustama')} value={mPct === null ? '—' : `${mPct}%`} valueStyle={{ color: mPct !== null && mPct >= 60 ? '#067647' : '#b54708' }} />
                      </Card>
                    </Col>
                    <Col xs={12} md={6}>
                      <Card size="small" style={{ background: 'var(--sm-bg)' }}>
                        <Statistic title={tr('Фудкост', 'Fudkost')} value={foodCost === null ? '—' : `${foodCost}%`} valueStyle={{ color: foodCost !== null && foodCost <= 35 ? '#067647' : '#b54708' }} />
                      </Card>
                    </Col>
                  </>
                )}
              </Row>
            </Card>
          </Col>

          <Col xs={24} xl={8}>
            {!isPrep && (
              <Card
                title={tr('Модификаторы', 'Modifikatorlar')}
                extra={<Typography.Text type="secondary">{tr(`групп: ${linked.length}`, `${linked.length} ta guruh`)}</Typography.Text>}
                style={{ marginBottom: 16 }}
              >
                <Space direction="vertical" style={{ width: '100%' }} size={10}>
                  {linked.map((g) => (
                    <Card key={g.id} size="small">
                      <Space style={{ width: '100%', justifyContent: 'space-between' }}>
                        <Space>
                          <b>{g.name}</b>
                          {g.required ? (
                            <Tag color="red" bordered={false}>
                              {tr('обязательно', 'majburiy')} · {g.min_select} {tr('из', 'dan')} {g.options.length}
                            </Tag>
                          ) : (
                            <Tag bordered={false}>
                              {g.min_select}–{g.max_select || '∞'}
                            </Tag>
                          )}
                        </Space>
                        {manage && (
                          <Button
                            size="small"
                            type="text"
                            icon={<CloseOutlined />}
                            onClick={() => {
                              setDirty(true)
                              setModGroups((m) => m.filter((x) => x !== g.id))
                            }}
                          />
                        )}
                      </Space>
                      {g.options.map((o) => (
                        <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginTop: 4 }}>
                          <span>
                            {o.name}{' '}
                            {o.action === 'factor' ? (
                              <b>{money(Number(price ?? 0) + Number(o.price))}</b>
                            ) : Number(o.price) ? (
                              <b>+{money(o.price)}</b>
                            ) : null}
                          </span>
                          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                            {o.action === 'factor' && `${tr('техкарта', 'texkarta')} × ${qty(o.factor)}`}
                            {o.action === 'add' && `${o.product_name} ${qty(o.qty)}`}
                            {o.action === 'remove' && `${o.product_name} ${tr('не спишется', 'hisobdan chiqmaydi')}`}
                          </Typography.Text>
                        </div>
                      ))}
                    </Card>
                  ))}
                  {manage && (
                    <Select
                      value={null}
                      placeholder={
                        <span>
                          <LinkOutlined /> {tr('Привязать группу', 'Guruhni bogʻlash')}
                        </span>
                      }
                      style={{ width: '100%' }}
                      options={(allMods.data ?? []).filter((g) => !modGroups.includes(g.id)).map((g) => ({ value: g.id, label: g.name }))}
                      onChange={(v: string | null) => {
                        if (!v) return
                        setDirty(true)
                        setModGroups((m) => [...m, v])
                      }}
                      notFoundContent={tr('Групп нет — создайте в «Меню → Модификаторы»', 'Guruhlar yoʻq — «Menyu → Modifikatorlar»da yarating')}
                    />
                  )}
                </Space>
              </Card>
            )}

            {!isPrep && (
              <Card title={tr('Где продаётся', 'Qayerda sotiladi')} style={{ marginBottom: 16 }}>
                <Space direction="vertical" style={{ width: '100%' }} size={12}>
                  {stores.map((s) => (
                    <div key={s.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <div>
                        <b>{tr('Касса', 'Kassa')} · {s.name}</b>
                        <div style={{ fontSize: 12, color: 'var(--sm-muted)' }}>
                          {tr('плитка в группе', 'guruhdagi plitka')} «{groups.data?.find((g) => g.id === form.getFieldValue('menu_group_id'))?.name ?? tr('без группы', 'guruhsiz')}»
                        </div>
                      </div>
                      <Switch
                        checked={storeIds.includes(s.id)}
                        disabled={!manage}
                        onChange={(on) => {
                          setDirty(true)
                          setTouchedStores(true)
                          setStoreIds((ids) => (on ? [...ids, s.id] : ids.filter((x) => x !== s.id)))
                        }}
                      />
                    </div>
                  ))}
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', opacity: 0.6 }}>
                    <div>
                      <b>{tr('Приложение покупателя', 'Xaridor ilovasi')}</b>
                      <div style={{ fontSize: 12, color: 'var(--sm-muted)' }}>{tr('доставка и самовывоз — скоро', 'yetkazib berish va olib ketish — tez orada')}</div>
                    </div>
                    <Switch disabled checked={false} />
                  </div>
                  {dish && (
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <div>
                        <b>{tr('Стоп-лист', 'Stop-roʻyxat')}</b>
                        <div style={{ fontSize: 12, color: 'var(--sm-muted)' }}>{tr('блюдо закончилось — скрыть в этой точке', 'taom tugadi — bu nuqtada yashirish')}</div>
                      </div>
                      <Switch checked={stopped} disabled={!manage} onChange={toggleStop} />
                    </div>
                  )}
                </Space>
              </Card>
            )}

            {isPrep && dish?.used_in && (
              <Card title={tr('Где используется', 'Qayerda ishlatiladi')} style={{ marginBottom: 16 }}>
                {dish.used_in.length === 0 ? (
                  <Typography.Text type="secondary">{tr('Пока ни в одной техкарте', 'Hali hech qaysi texkartada yoʻq')}</Typography.Text>
                ) : (
                  dish.used_in.map((u) => (
                    <div key={u.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0' }}>
                      <Typography.Link onClick={() => nav(u.kind === 'prep' ? `/kitchen-stock/preps/${u.id}/edit` : `/menu/dishes/${u.id}`)}>{u.name}</Typography.Link>
                      <span>
                        {qty(u.qty, unitShort)} / {u.unit_short}
                      </span>
                    </div>
                  ))
                )}
              </Card>
            )}

            <Alert
              type="info"
              showIcon
              message={tr('Как списываются продукты', 'Mahsulotlar qanday hisobdan chiqadi')}
              description={
                isPrep
                  ? tr(
                      'Продукты списываются, когда заготовку производят («Произвести»). Блюдо с заготовкой списывает саму заготовку со склада.',
                      'Mahsulotlar yarim tayyor ishlab chiqarilganda («Ishlab chiqarish») hisobdan chiqadi. Yarim tayyorli taom ombordan yarim tayyorni oʻzini hisobdan chiqaradi.',
                    )
                  : tr(
                      'Продали порцию — со склада спишутся продукты по техкарте. Не хватает продукта — остаток уйдёт в минус, приход его закроет.',
                      'Porsiya sotildi — ombordan mahsulotlar texkarta boʻyicha hisobdan chiqadi. Mahsulot yetmasa — qoldiq minusga ketadi, kirim uni yopadi.',
                    )
              }
            />
            {dirty && (
              <Typography.Paragraph type="warning" style={{ marginTop: 12 }}>
                {tr('Есть несохранённые изменения', 'Saqlanmagan oʻzgarishlar bor')}
              </Typography.Paragraph>
            )}
          </Col>
        </Row>
      </Form>
    </div>
  )
}
