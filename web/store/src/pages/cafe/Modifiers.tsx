// Меню → Модификаторы: группы слева, редактор справа (Figma П3).
import { useEffect, useState } from 'react'
import { App, Button, Card, Col, Empty, Input, InputNumber, Row, Segmented, Select, Space, Switch, Table, Tag, Typography } from 'antd'
import { CheckOutlined, DeleteOutlined, PlusOutlined, RightOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, tr, useList } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { IngredientSelect, MenuTabs } from './common'
import { useMenuCounts } from './Menu'
import type { Dish, ModifierAction, ModifierGroup } from './types'

type Opt = {
  key: string
  id?: string
  name: string
  name_uz: string
  price: string
  action: ModifierAction
  product_id: string | null
  product_name: string | null
  unit?: string
  qty: string
  factor: string
}

let n = 0
const k = () => `o${++n}`

const ACTIONS: { value: ModifierAction; label: string }[] = [
  { value: 'none', label: tr('Только для кухни', 'Faqat oshxona uchun') },
  { value: 'add', label: tr('Добавить продукт или блюдо', 'Mahsulot yoki taom qoʻshish') },
  { value: 'remove', label: tr('Убрать продукт («без лука»)', 'Mahsulotni olib tashlash («piyozsiz»)') },
  { value: 'factor', label: tr('Порция × (0,5 / 1,5)', 'Porsiya × (0,5 / 1,5)') },
]

export function groupBadge(g: Pick<ModifierGroup, 'min_select' | 'max_select' | 'options'>) {
  const paid = g.options.some((o) => Number(o.price) !== 0)
  if (g.min_select > 0)
    return (
      <Tag color="red" bordered={false}>
        {tr('обязательно', 'majburiy')} · {g.min_select} {tr('из', 'dan')} {g.options.length}
      </Tag>
    )
  return (
    <Tag bordered={false}>
      {paid ? tr('платные', 'pullik') : tr('бесплатно', 'bepul')} · {g.min_select}–{g.max_select || g.options.length}
    </Tag>
  )
}

export function ModifiersPage() {
  const { can } = useStore()
  const manage = can('catalog.manage')
  const list = useList<ModifierGroup>('/store/cafe/modifier-groups')
  const counts = useMenuCounts()
  const [selected, setSelected] = useState<string | 'new' | null>(null)
  const groups = list.data ?? []
  useEffect(() => {
    if (selected === null && groups.length) setSelected(groups[0].id)
  }, [groups, selected])
  const current = selected === 'new' ? undefined : groups.find((g) => g.id === selected)

  return (
    <NeedStore>
      <PageTitle
        title={tr('Меню', 'Menyu')}
        tabs={<MenuTabs {...counts} />}
        extra={
          manage && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setSelected('new')}>
              {tr('Группа модификаторов', 'Modifikatorlar guruhi')}
            </Button>
          )
        }
      />
      <Typography.Paragraph type="secondary">
        {tr(
          'Модификаторы — это выбор к блюду: порция, добавки, «без лука». Одна группа подключается к нескольким блюдам.',
          'Modifikatorlar — taomga tanlov: porsiya, qoʻshimchalar, «piyozsiz». Bitta guruh bir nechta taomga ulanadi.',
        )}
      </Typography.Paragraph>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Row gutter={16}>
        <Col xs={24} lg={9}>
          <Card styles={{ body: { padding: 8 } }} loading={list.isLoading}>
            {groups.length === 0 && selected !== 'new' && <Empty description={tr('Групп пока нет', 'Hozircha guruhlar yoʻq')} />}
            {groups.map((g) => (
              <div
                key={g.id}
                onClick={() => setSelected(g.id)}
                style={{
                  padding: '12px 14px',
                  borderRadius: 12,
                  cursor: 'pointer',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: selected === g.id ? '#fef3f2' : undefined,
                  borderLeft: selected === g.id ? '3px solid #d92d20' : '3px solid transparent',
                }}
              >
                <div>
                  <b>{g.name}</b>
                  <div style={{ marginTop: 4 }}>
                    {groupBadge(g)}
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {tr(`блюд: ${g.dish_count}`, `${g.dish_count} ta taom`)}
                    </Typography.Text>
                  </div>
                </div>
                <RightOutlined style={{ color: 'var(--sm-muted)' }} />
              </div>
            ))}
          </Card>
        </Col>
        <Col xs={24} lg={15}>
          {(current || selected === 'new') && (
            <GroupEditor
              key={current?.id ?? 'new'}
              group={current}
              manage={manage}
              onSaved={(id) => setSelected(id)}
              onDeleted={() => setSelected(null)}
            />
          )}
        </Col>
      </Row>
    </NeedStore>
  )
}

function toOpt(o: ModifierGroup['options'][number]): Opt {
  return {
    key: k(),
    id: o.id,
    name: o.name_ru,
    name_uz: o.name_uz,
    price: o.price,
    action: o.action,
    product_id: o.product_id,
    product_name: o.product_name,
    qty: o.qty ?? '',
    factor: o.factor ?? '',
  }
}

function GroupEditor({ group, manage, onSaved, onDeleted }: { group?: ModifierGroup; manage: boolean; onSaved: (id: string) => void; onDeleted: () => void }) {
  const { message, modal } = App.useApp()
  const qc = useQueryClient()
  const [name, setName] = useState(group?.name_ru ?? '')
  const [nameUz, setNameUz] = useState(group?.name_uz ?? '')
  const [many, setMany] = useState(group ? group.max_select !== 1 : false)
  const [min, setMin] = useState(group?.min_select ?? 0)
  const [max, setMax] = useState(group?.max_select ?? 1)
  const [opts, setOpts] = useState<Opt[]>(group?.options.map(toOpt) ?? [{ key: k(), name: '', name_uz: '', price: '0', action: 'none', product_id: null, product_name: null, qty: '', factor: '' }])
  const [saving, setSaving] = useState(false)
  const dishes = useList<Dish>(group ? '/store/cafe/dishes' : null, { kind: 'dish', limit: 200 })
  const linked = (dishes.data ?? []).filter((d) => group && d.modifier_group_ids.includes(group.id))
  const required = min > 0

  const set = (key: string, patch: Partial<Opt>) => setOpts((os) => os.map((o) => (o.key === key ? { ...o, ...patch } : o)))

  const save = async () => {
    if (!name.trim() && !nameUz.trim()) {
      message.error(tr('Укажите название группы', 'Guruh nomini kiriting'))
      return
    }
    const body = {
      name: name.trim() || nameUz.trim(),
      name_uz: nameUz.trim(),
      min_select: min,
      max_select: many ? max : 1,
      options: opts.map((o) => ({
        ...(o.id ? { id: o.id } : {}),
        name: o.name.trim() || o.name_uz.trim(),
        name_uz: o.name_uz.trim(),
        price: o.price || '0',
        action: o.action,
        ...(o.action === 'add' || o.action === 'remove' ? { product_id: o.product_id } : {}),
        ...(o.action === 'add' ? { qty: o.qty } : {}),
        ...(o.action === 'factor' ? { factor: o.factor } : {}),
      })),
    }
    setSaving(true)
    try {
      const out = group ? await api.patch<ModifierGroup>(`/store/cafe/modifier-groups/${group.id}`, body) : await api.post<ModifierGroup>('/store/cafe/modifier-groups', body)
      message.success(tr('Сохранено', 'Saqlandi'))
      await qc.invalidateQueries({ queryKey: ['/store/cafe/modifier-groups'] })
      onSaved(out.id)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  const unlink = async (d: Dish) => {
    try {
      await api.patch(`/store/cafe/dishes/${d.id}`, { modifier_group_ids: d.modifier_group_ids.filter((x) => x !== group?.id) })
      qc.invalidateQueries({ queryKey: ['/store/cafe/dishes'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/modifier-groups'] })
    } catch (e) {
      message.error(errorText(e))
    }
  }
  const link = async (id: string) => {
    const d = dishes.data?.find((x) => x.id === id)
    if (!d || !group) return
    try {
      await api.patch(`/store/cafe/dishes/${d.id}`, { modifier_group_ids: [...d.modifier_group_ids, group.id] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/dishes'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/modifier-groups'] })
    } catch (e) {
      message.error(errorText(e))
    }
  }

  return (
    <Card
      title={group?.name ?? tr('Новая группа', 'Yangi guruh')}
      extra={
        group &&
        manage && (
          <Button
            danger
            icon={<DeleteOutlined />}
            onClick={() =>
              modal.confirm({
                title: tr(`Удалить группу «${group.name}»?`, `«${group.name}» guruhini oʻchirasizmi?`),
                content: tr('Она отвяжется от блюд; в старых чеках варианты останутся.', 'U taomlardan uziladi; eski cheklarda variantlar qoladi.'),
                onOk: async () => {
                  await api.del(`/store/cafe/modifier-groups/${group.id}`)
                  await qc.invalidateQueries({ queryKey: ['/store/cafe/modifier-groups'] })
                  onDeleted()
                },
              })
            }
          >
            {tr('Удалить группу', 'Guruhni oʻchirish')}
          </Button>
        )
      }
    >
      <Row gutter={12}>
        <Col span={12}>
          <Typography.Text type="secondary">Oʻzbekcha</Typography.Text>
          <Input value={nameUz} onChange={(e) => setNameUz(e.target.value)} disabled={!manage} placeholder="Palovga qoʻshimchalar" />
        </Col>
        <Col span={12}>
          <Typography.Text type="secondary">Русский</Typography.Text>
          <Input value={name} onChange={(e) => setName(e.target.value)} disabled={!manage} placeholder="Добавки к плову" />
        </Col>
      </Row>
      <Space wrap size={16} style={{ marginTop: 16, alignItems: 'flex-end' }}>
        <div>
          <Typography.Text type="secondary">{tr('Сколько можно выбрать', 'Nechta tanlash mumkin')}</Typography.Text>
          <br />
          <Segmented
            disabled={!manage}
            value={many ? 'many' : 'one'}
            onChange={(v) => {
              setMany(v === 'many')
              if (v === 'one') setMin((m) => Math.min(m, 1))
            }}
            options={[
              { value: 'one', label: tr('Один вариант', 'Bitta variant') },
              { value: 'many', label: tr('Несколько', 'Bir nechta') },
            ]}
          />
        </div>
        {many && (
          <>
            <div>
              <Typography.Text type="secondary">{tr('Минимум', 'Kamida')}</Typography.Text>
              <br />
              <InputNumber min={0} max={20} value={min} disabled={!manage} onChange={(v) => setMin(v ?? 0)} />
            </div>
            <div>
              <Typography.Text type="secondary">{tr('Максимум', 'Koʻpi bilan')}</Typography.Text>
              <br />
              <InputNumber min={0} max={20} value={max} disabled={!manage} onChange={(v) => setMax(v ?? 0)} />
            </div>
          </>
        )}
        <Space>
          <Switch checked={required} disabled={!manage} onChange={(on) => setMin(on ? Math.max(1, min) : 0)} />
          <div>
            <b>{tr('Обязательная группа', 'Majburiy guruh')}</b>
            <div style={{ fontSize: 12, color: 'var(--sm-muted)' }}>{tr('иначе блюдо не добавить', 'aks holda taomni qoʻshib boʻlmaydi')}</div>
          </div>
        </Space>
      </Space>

      <Table<Opt>
        style={{ marginTop: 16 }}
        rowKey="key"
        size="small"
        pagination={false}
        dataSource={opts}
        columns={[
          {
            title: tr('Вариант', 'Variant'),
            key: 'name',
            render: (_, o) => (
              <Space direction="vertical" size={4} style={{ width: '100%' }}>
                <Input size="small" value={o.name} disabled={!manage} placeholder={tr('по-русски', 'ruscha')} onChange={(e) => set(o.key, { name: e.target.value })} />
                <Input size="small" value={o.name_uz} disabled={!manage} placeholder={tr('по-узбекски', 'oʻzbekcha')} onChange={(e) => set(o.key, { name_uz: e.target.value })} />
              </Space>
            ),
          },
          {
            title: tr('Цена', 'Narx'),
            key: 'price',
            width: 120,
            render: (_, o) => (
              <InputNumber<string>
                stringMode
                size="small"
                step="1000"
                min={o.action === 'factor' ? undefined : '0'}
                value={o.price}
                disabled={!manage}
                onChange={(v) => set(o.key, { price: v ?? '0' })}
                formatter={(v) => (v && Number(v) > 0 ? `+${v}` : `${v ?? ''}`)}
                parser={(v) => (v ?? '').replace('+', '')}
                style={{ width: 110 }}
              />
            ),
          },
          {
            title: tr('Что списывается со склада', 'Ombordan nima chiqadi'),
            key: 'action',
            render: (_, o) => (
              <Space direction="vertical" size={4} style={{ width: '100%' }}>
                <Select size="small" value={o.action} disabled={!manage} options={ACTIONS} onChange={(v: ModifierAction) => set(o.key, { action: v })} style={{ width: '100%' }} />
                {(o.action === 'add' || o.action === 'remove') && (
                  <Space.Compact block>
                    <IngredientSelect
                      size="small"
                      value={o.product_id ?? undefined}
                      label={o.product_name ?? undefined}
                      withDishes={o.action === 'add'}
                      disabled={!manage}
                      onPick={(i) => set(o.key, { product_id: i.id, product_name: i.name, unit: i.unit_short })}
                    />
                    {o.action === 'add' && (
                      <InputNumber<string>
                        stringMode
                        size="small"
                        min="0"
                        step="0.01"
                        value={o.qty}
                        disabled={!manage}
                        onChange={(v) => set(o.key, { qty: v ?? '' })}
                        placeholder={tr('сколько', 'qancha')}
                        style={{ width: 100 }}
                        addonAfter={o.unit}
                      />
                    )}
                  </Space.Compact>
                )}
                {o.action === 'factor' && (
                  <InputNumber<string>
                    stringMode
                    size="small"
                    min="0.1"
                    max="10"
                    step="0.5"
                    value={o.factor}
                    disabled={!manage}
                    onChange={(v) => set(o.key, { factor: v ?? '' })}
                    addonBefore={tr('техкарта ×', 'texkarta ×')}
                    style={{ width: 170 }}
                  />
                )}
              </Space>
            ),
          },
          {
            key: 'x',
            width: 40,
            render: (_, o) =>
              manage && (
                <Button size="small" type="text" icon={<DeleteOutlined />} disabled={opts.length === 1} onClick={() => setOpts((os) => os.filter((x) => x.key !== o.key))} />
              ),
          },
        ]}
      />
      {manage && (
        <Button
          type="link"
          icon={<PlusOutlined />}
          onClick={() => setOpts((os) => [...os, { key: k(), name: '', name_uz: '', price: '0', action: 'none', product_id: null, product_name: null, qty: '', factor: '' }])}
        >
          {tr('Добавить вариант', 'Variant qoʻshish')}
        </Button>
      )}

      {group && (
        <div style={{ marginTop: 16 }}>
          <Typography.Text type="secondary">{tr('Подключено к блюдам', 'Taomlarga ulangan')}</Typography.Text>
          <div style={{ marginTop: 8, display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {linked.map((d) => (
              <Tag key={d.id} closable={manage} onClose={(e) => { e.preventDefault(); unlink(d) }} style={{ padding: '4px 10px', borderRadius: 16 }}>
                {d.name}
              </Tag>
            ))}
            {manage && (
              <Select
                size="small"
                value={null}
                showSearch
                optionFilterProp="label"
                placeholder={<span><PlusOutlined /> {tr('Блюдо', 'Taom')}</span>}
                style={{ width: 200 }}
                options={(dishes.data ?? []).filter((d) => !d.modifier_group_ids.includes(group.id)).map((d) => ({ value: d.id, label: d.name }))}
                onChange={(v: string | null) => v && link(v)}
              />
            )}
          </div>
        </div>
      )}

      {manage && (
        <Space style={{ marginTop: 20, justifyContent: 'flex-end', width: '100%' }}>
          <Button type="primary" icon={<CheckOutlined />} loading={saving} onClick={save}>
            {tr('Сохранить', 'Saqlash')}
          </Button>
        </Space>
      )}
    </Card>
  )
}
