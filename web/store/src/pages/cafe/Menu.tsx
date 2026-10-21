// Меню кафе: блюда (Figma П1), группы меню, стоп-лист точки.
import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Alert, App, Avatar, Button, Card, Form, Input, Modal, Select, Space, Table, Tag, Tooltip, Typography } from 'antd'
import { FolderOutlined, PlusOutlined, StopOutlined, WarningOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, RemoteSelect, api, dateTime, money, tr, useAction, useDebounced, useList, usePaged } from '@sm/shared'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { MarkupText, MenuTabs } from './common'
import type { Dish, MenuGroup, ModifierGroup, StopItem, Workshop } from './types'

/** Счётчики во вкладках «Меню». */
export function useMenuCounts() {
  const { storeId } = useStore()
  const groups = useList<ModifierGroup>('/store/cafe/modifier-groups')
  const workshops = useList<Workshop>('/store/cafe/workshops')
  const stop = useList<StopItem>(storeId ? '/store/cafe/stop-list' : null, { store_id: storeId })
  const dishes = useList<Dish>('/store/cafe/dishes', { kind: 'dish', limit: 200 })
  return { dishes: dishes.data?.length, modifiers: groups.data?.length, workshops: workshops.data?.length, stopped: stop.data?.length }
}

export function MenuPage() {
  const nav = useNavigate()
  const { can, storeId } = useStore()
  const manage = can('catalog.manage')
  const [q, setQ] = useState('')
  const debounced = useDebounced(q.trim())
  const [groupId, setGroupId] = useState<string>()
  const [workshopId, setWorkshopId] = useState<string>()
  const [noRecipe, setNoRecipe] = useState(false)
  const [groupsOpen, setGroupsOpen] = useState(false)
  const params = { kind: 'dish', q: debounced || undefined, group_id: groupId, workshop_id: workshopId, no_recipe: noRecipe ? 1 : undefined }
  const list = usePaged<Dish>('/store/cafe/dishes', params, 50)
  const withoutRecipe = useList<Dish>('/store/cafe/dishes', { kind: 'dish', no_recipe: 1, limit: 200 })
  const counts = useMenuCounts()
  const missing = withoutRecipe.data?.length ?? 0

  return (
    <NeedStore>
      <PageTitle
        title={tr('Меню', 'Menyu')}
        tabs={<MenuTabs {...counts} />}
        extra={
          manage && (
            <Space>
              <Button type="primary" icon={<PlusOutlined />} onClick={() => nav('/menu/dishes/new')}>
                {tr('Блюдо', 'Taom')}
              </Button>
              <Button icon={<FolderOutlined />} onClick={() => setGroupsOpen(true)}>
                {tr('Группы меню', 'Menyu guruhlari')}
              </Button>
            </Space>
          )
        }
      >
        <Input.Search
          allowClear
          placeholder={tr('Название блюда или код', 'Taom nomi yoki kodi')}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          style={{ width: 240 }}
        />
        <RemoteSelect<MenuGroup>
          path="/store/cafe/menu-groups"
          value={groupId}
          onChange={setGroupId}
          allowClear
          placeholder={tr('Все группы', 'Barcha guruhlar')}
          style={{ width: 180 }}
        />
        <RemoteSelect<Workshop>
          path="/store/cafe/workshops"
          value={workshopId}
          onChange={setWorkshopId}
          allowClear
          placeholder={tr('Все цеха', 'Barcha sexlar')}
          style={{ width: 160 }}
        />
      </PageTitle>

      {missing > 0 && (
        <Alert
          type="warning"
          showIcon
          icon={<WarningOutlined />}
          style={{ marginBottom: 12 }}
          message={tr(
            `${missing} ${plural(missing, 'блюдо', 'блюда', 'блюд')} без техкарты — себестоимость не считается, продукты не списываются`,
            `${missing} ta taom texnologik kartasiz — tannarx hisoblanmaydi, mahsulotlar hisobdan chiqmaydi`,
          )}
          action={
            <Button size="small" type={noRecipe ? 'primary' : 'default'} onClick={() => setNoRecipe((v) => !v)}>
              {noRecipe ? tr('Показать все', 'Hammasini koʻrsatish') : tr('Показать', 'Koʻrsatish')}
            </Button>
          }
        />
      )}

      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Dish>
          rowKey="id"
          loading={list.isLoading || list.isFetching}
          dataSource={list.items}
          pagination={list.pagination}
          scroll={{ x: true }}
          onRow={(r) => ({ onClick: () => nav(`/menu/dishes/${r.id}`), style: { cursor: 'pointer' } })}
          rowClassName={(r) => (storeId && r.stop_store_ids.includes(storeId) ? 'sm-row-muted' : '')}
          columns={[
            {
              title: tr('Блюдо', 'Taom'),
              key: 'name',
              render: (_, r) => (
                <Space>
                  <Avatar shape="square" size={40} src={r.images[0]} style={{ background: '#fdf0e3', color: '#9a5b13' }}>
                    🍽
                  </Avatar>
                  <div>
                    <div style={{ fontWeight: 700 }}>
                      {r.menu_code ? <Typography.Text type="secondary">{r.menu_code} · </Typography.Text> : null}
                      {r.name}
                    </div>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {r.menu_group_name ?? tr('без группы', 'guruhsiz')}
                    </Typography.Text>
                    {storeId && r.stop_store_ids.includes(storeId) && (
                      <Tag color="orange" bordered={false} style={{ marginLeft: 6 }}>
                        {tr('стоп-лист', 'stop-roʻyxat')}
                      </Tag>
                    )}
                    {!r.is_active && <Tag style={{ marginLeft: 6 }}>{tr('выключено', 'oʻchirilgan')}</Tag>}
                  </div>
                </Space>
              ),
            },
            { title: tr('Цех', 'Sex'), dataIndex: 'kitchen_workshop_name' },
            { title: tr('Цена', 'Narx'), dataIndex: 'price', align: 'right', render: (v) => money(v) },
            {
              title: tr('Себестоимость', 'Tannarx'),
              dataIndex: 'cost',
              align: 'right',
              render: (v, r) =>
                !r.has_recipe ? (
                  <Typography.Text type="danger">{tr('нет техкарты', 'texkarta yoʻq')}</Typography.Text>
                ) : (
                  <Tooltip title={!r.cost_complete ? tr('Часть продуктов ещё не приходовали — их цена неизвестна', 'Ayrim mahsulotlar hali kirim qilinmagan — narxi nomaʼlum') : undefined}>
                    <span>
                      {money(v)}
                      {!r.cost_complete && ' *'}
                    </span>
                  </Tooltip>
                ),
            },
            { title: tr('Наценка', 'Ustama'), key: 'markup', align: 'right', render: (_, r) => (r.has_recipe ? <MarkupText price={r.price} cost={r.cost} /> : '—') },
            { title: tr('Выход', 'Chiqish'), dataIndex: 'portion', align: 'right', render: (v) => v || '—' },
            {
              title: tr('Модификаторы', 'Modifikatorlar'),
              dataIndex: 'modifier_group_ids',
              render: (v: string[]) =>
                v.length ? (
                  <Typography.Link>
                    {v.length} {tr(plural(v.length, 'группа', 'группы', 'групп'), 'ta guruh')}
                  </Typography.Link>
                ) : (
                  '—'
                ),
            },
            {
              title: tr('Где продаётся', 'Qayerda sotiladi'),
              dataIndex: 'store_ids',
              render: (v: string[]) => (v.length ? <Tag bordered={false} color="green">{tr(`точек: ${v.length}`, `${v.length} ta nuqta`)}</Tag> : <Tag bordered={false}>{tr('нигде', 'hech qayerda')}</Tag>),
            },
          ]}
        />
      </Card>
      <MenuGroupsModal open={groupsOpen} onClose={() => setGroupsOpen(false)} />
    </NeedStore>
  )
}

export function plural(n: number, one: string, few: string, many: string) {
  const m10 = n % 10
  const m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}

// ------------------------------------------------------------ группы меню

function MenuGroupsModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const groups = useList<MenuGroup>(open ? '/store/cafe/menu-groups' : null)
  const workshops = useList<Workshop>(open ? '/store/cafe/workshops' : null)
  const [editing, setEditing] = useState<MenuGroup | 'new' | null>(null)
  const [form] = Form.useForm()
  const { modal } = App.useApp()
  const save = useAction(
    (v: Record<string, unknown>) =>
      editing && editing !== 'new' ? api.patch(`/store/cafe/menu-groups/${editing.id}`, v) : api.post('/store/cafe/menu-groups', v),
    { success: tr('Сохранено', 'Saqlandi') },
  )
  const remove = useAction((id: string) => api.del(`/store/cafe/menu-groups/${id}`), { success: tr('Группа удалена', 'Guruh oʻchirildi') })
  const startEdit = (g: MenuGroup | 'new') => {
    setEditing(g)
    form.setFieldsValue(
      g === 'new'
        ? { name: '', name_uz: '', workshop_id: null, color: '' }
        : { name: g.name_ru, name_uz: g.name_uz, workshop_id: g.workshop_id, color: g.color },
    )
  }
  return (
    <Modal open={open} onCancel={onClose} footer={null} title={tr('Группы меню', 'Menyu guruhlari')} width={680} destroyOnHidden>
      <Typography.Paragraph type="secondary">
        {tr(
          'Группа — раздел меню на кассе («Плов и вторые», «Супы»). Цех группы — куда по умолчанию уходят её блюда.',
          'Guruh — kassadagi menyu boʻlimi («Palov», «Shoʻrvalar»). Guruh sexi — uning taomlari sukut boʻyicha yuboriladigan joy.',
        )}
      </Typography.Paragraph>
      <Table<MenuGroup>
        rowKey="id"
        size="small"
        pagination={false}
        loading={groups.isLoading}
        dataSource={groups.data ?? []}
        columns={[
          {
            title: tr('Группа', 'Guruh'),
            dataIndex: 'name',
            render: (v, r) => (
              <Space>
                {r.color && <span style={{ display: 'inline-block', width: 10, height: 10, borderRadius: 3, background: r.color }} />}
                {v}
              </Space>
            ),
          },
          { title: tr('Цех', 'Sex'), dataIndex: 'workshop_name', render: (v) => v ?? <Typography.Text type="secondary">{tr('по умолчанию', 'sukut boʻyicha')}</Typography.Text> },
          { title: tr('Блюд', 'Taomlar'), dataIndex: 'dish_count', align: 'right' },
          {
            key: 'a',
            align: 'right',
            render: (_, r) => (
              <Space>
                <Button size="small" onClick={() => startEdit(r)}>
                  {tr('Изменить', 'Oʻzgartirish')}
                </Button>
                <Button
                  size="small"
                  danger
                  onClick={() =>
                    modal.confirm({
                      title: tr(`Удалить группу «${r.name}»?`, `«${r.name}» guruhini oʻchirasizmi?`),
                      content: r.dish_count ? tr('В группе есть блюда — сначала перенесите их.', 'Guruhda taomlar bor — avval ularni koʻchiring.') : undefined,
                      onOk: () => remove.mutateAsync(r.id),
                    })
                  }
                >
                  {tr('Удалить', 'Oʻchirish')}
                </Button>
              </Space>
            ),
          },
        ]}
      />
      {editing ? (
        <Card size="small" style={{ marginTop: 12 }} title={editing === 'new' ? tr('Новая группа', 'Yangi guruh') : tr('Группа', 'Guruh')}>
          <Form
            form={form}
            layout="vertical"
            onFinish={(v) =>
              save.mutate({ ...v, color: v.color || '' }, { onSuccess: () => setEditing(null) })
            }
          >
            <Space.Compact block>
              <Form.Item name="name_uz" label="Oʻzbekcha" style={{ flex: 1, marginRight: 8 }}>
                <Input placeholder="Palov" />
              </Form.Item>
              <Form.Item name="name" label="Русский" style={{ flex: 1 }} rules={[{ required: true, message: tr('Укажите название', 'Nomini kiriting') }]}>
                <Input placeholder="Плов и вторые" />
              </Form.Item>
            </Space.Compact>
            <Space.Compact block>
              <Form.Item name="workshop_id" label={tr('Цех', 'Sex')} style={{ flex: 1, marginRight: 8 }}>
                <Select
                  allowClear
                  placeholder={tr('Цех по умолчанию', 'Asosiy sex')}
                  options={(workshops.data ?? []).map((w) => ({ value: w.id, label: w.name }))}
                />
              </Form.Item>
              <Form.Item name="color" label={tr('Цвет плитки на кассе', 'Kassadagi plitka rangi')} style={{ width: 200 }}>
                <Select
                  allowClear
                  options={['#E8A33D', '#D92D20', '#12B76A', '#2E90FA', '#7A5AF8', '#EE46BC', '#667085'].map((c) => ({
                    value: c,
                    label: <span style={{ display: 'inline-block', width: 40, height: 14, borderRadius: 4, background: c }} />,
                  }))}
                />
              </Form.Item>
            </Space.Compact>
            <Space>
              <Button type="primary" htmlType="submit" loading={save.isPending}>
                {tr('Сохранить', 'Saqlash')}
              </Button>
              <Button onClick={() => setEditing(null)}>{tr('Отмена', 'Bekor qilish')}</Button>
            </Space>
          </Form>
        </Card>
      ) : (
        <Button icon={<PlusOutlined />} style={{ marginTop: 12 }} onClick={() => startEdit('new')}>
          {tr('Группа', 'Guruh')}
        </Button>
      )}
    </Modal>
  )
}

// ---------------------------------------------------------------- стоп-лист

export function StopListPage() {
  const { storeId, store, can } = useStore()
  const list = useList<StopItem>(storeId ? '/store/cafe/stop-list' : null, { store_id: storeId })
  const counts = useMenuCounts()
  const [pick, setPick] = useState<string>()
  const allowed = can('catalog.manage') || can('sales.pos')
  const set = useAction((v: { product_id: string; stopped: boolean }) => api.put('/store/cafe/stop-list', { store_id: storeId, ...v }), {
    invalidate: [['/store/cafe/stop-list'], ['/store/cafe/dishes']],
  })
  const stoppedIds = useMemo(() => new Set((list.data ?? []).map((s) => s.product_id)), [list.data])
  return (
    <NeedStore>
      <PageTitle
        title={tr('Меню', 'Menyu')}
        tabs={<MenuTabs {...counts} />}
        extra={
          allowed && (
            <Space.Compact>
              <RemoteSelect<Dish>
                path="/store/cafe/dishes"
                params={{ kind: 'dish' }}
                search
                filter={(d) => !stoppedIds.has(d.id)}
                value={pick}
                onChange={setPick}
                placeholder={tr('Блюдо закончилось…', 'Taom tugadi…')}
                style={{ width: 260 }}
              />
              <Button
                type="primary"
                icon={<StopOutlined />}
                disabled={!pick}
                loading={set.isPending}
                onClick={() => pick && set.mutate({ product_id: pick, stopped: true }, { onSuccess: () => setPick(undefined) })}
              >
                {tr('На стоп', 'Stopga')}
              </Button>
            </Space.Compact>
          )
        }
      />
      <Typography.Paragraph type="secondary">
        {tr(
          `Стоп-лист точки «${store?.name ?? ''}»: эти блюда закончились — касса их не продаёт. Снимите со стопа, когда блюдо снова есть.`,
          `«${store?.name ?? ''}» nuqtasining stop-roʻyxati: bu taomlar tugagan — kassa ularni sotmaydi. Taom yana boʻlganda stopdan oling.`,
        )}
      </Typography.Paragraph>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<StopItem>
          rowKey="product_id"
          loading={list.isLoading}
          dataSource={list.data ?? []}
          pagination={false}
          locale={{ emptyText: tr('На стопе ничего нет', 'Stopda hech narsa yoʻq') }}
          columns={[
            { title: tr('Блюдо', 'Taom'), dataIndex: 'name', render: (v, r) => <span><b>{v}</b> <Typography.Text type="secondary">{r.menu_group_name ?? ''}</Typography.Text></span> },
            { title: tr('На стопе с', 'Stopda'), dataIndex: 'since', render: (v) => dateTime(v) },
            { title: tr('Кто поставил', 'Kim qoʻydi'), dataIndex: 'by', render: (v) => v ?? '—' },
            {
              key: 'a',
              align: 'right',
              render: (_, r) =>
                allowed && (
                  <Button size="small" onClick={() => set.mutate({ product_id: r.product_id, stopped: false })}>
                    {tr('Снять со стопа', 'Stopdan olish')}
                  </Button>
                ),
            },
          ]}
        />
      </Card>
    </NeedStore>
  )
}
