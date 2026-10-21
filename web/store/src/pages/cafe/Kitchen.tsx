// Кухня → Цеха (Figma П7) и окно «Новый цех» (П7б). Экраны кухни, принтеры
// бегунков и экран выдачи подключаются на этапе 4 — здесь пока заглушки.
import { useEffect, useState } from 'react'
import { App, Alert, Button, Card, Checkbox, Col, Dropdown, Empty, Input, InputNumber, Modal, Row, Segmented, Space, Tag, Typography } from 'antd'
import { EditOutlined, InfoCircleOutlined, MoreOutlined, PlusOutlined, PrinterOutlined, DesktopOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, tr, useList } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { LinkTabs, WORKSHOP_ICONS, WorkshopEmoji } from './common'
import type { MenuGroup, Workshop, WorkshopIcon } from './types'

const printTitle = (p: Workshop['ticket_print']) =>
  p === 'always' ? tr('бегунок печатается всегда', 'cheki doim chop etiladi') : p === 'never' ? tr('без бегунка', 'cheksiz') : tr('бегунок — если экран не в сети', 'chek — ekran tarmoqda boʻlmasa')

export function KitchenPage() {
  const { can } = useStore()
  const manage = can('catalog.manage')
  const list = useList<Workshop>('/store/cafe/workshops')
  const [edit, setEdit] = useState<Workshop | 'new' | null>(null)
  const { modal, message } = App.useApp()
  const qc = useQueryClient()

  const remove = (w: Workshop) =>
    modal.confirm({
      title: tr(`Удалить цех «${w.name}»?`, `«${w.name}» sexini oʻchirasizmi?`),
      content: tr('Его группы меню и блюда перейдут в цех по умолчанию.', 'Uning menyu guruhlari va taomlari asosiy sexga oʻtadi.'),
      okButtonProps: { danger: true },
      onOk: async () => {
        try {
          await api.del(`/store/cafe/workshops/${w.id}`)
          qc.invalidateQueries({ queryKey: ['/store/cafe/workshops'] })
          qc.invalidateQueries({ queryKey: ['/store/cafe/menu-groups'] })
        } catch (e) {
          message.error(errorText(e))
        }
      },
    })

  return (
    <NeedStore>
      <PageTitle
        title={tr('Кухня', 'Oshxona')}
        tabs={<LinkTabs items={[{ path: '/kitchen', label: tr('Цеха и устройства', 'Sexlar va qurilmalar'), count: list.data?.length }]} />}
        extra={
          manage && (
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setEdit('new')}>
              {tr('Цех', 'Sex')}
            </Button>
          )
        }
      />
      <Typography.Paragraph type="secondary">
        {tr(
          'Цех — место на кухне, где готовят свои блюда. Заказ попадает в цех по группе меню блюда (или по цеху, указанному у блюда).',
          'Sex — oshxonada oʻz taomlari tayyorlanadigan joy. Buyurtma sexga taomning menyu guruhi boʻyicha tushadi (yoki taomda koʻrsatilgan sex boʻyicha).',
        )}
      </Typography.Paragraph>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Row gutter={[16, 16]}>
        {(list.data ?? []).map((w) => (
          <Col key={w.id} xs={24} md={12} xl={8}>
            <Card style={{ height: '100%' }} styles={{ body: { display: 'flex', flexDirection: 'column', height: '100%' } }}>
              <div style={{ display: 'flex', gap: 12, alignItems: 'flex-start' }}>
                <WorkshopEmoji icon={w.icon} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 18, fontWeight: 800 }}>
                    {w.name} {w.is_default && <Tag bordered={false}>{tr('по умолчанию', 'asosiy')}</Tag>}
                  </div>
                  <Typography.Text type="secondary" style={{ fontSize: 13 }}>
                    {tr('норма по умолчанию', 'standart meʼyor')} · {w.cook_minutes} {tr('мин', 'daq')} · {printTitle(w.ticket_print)}
                  </Typography.Text>
                </div>
                {manage && !w.is_default && (
                  <Dropdown menu={{ items: [{ key: 'del', danger: true, label: tr('Удалить цех', 'Sexni oʻchirish'), onClick: () => remove(w) }] }}>
                    <Button type="text" icon={<MoreOutlined />} />
                  </Dropdown>
                )}
              </div>
              <Typography.Text type="secondary" style={{ marginTop: 14, fontSize: 12 }}>
                {tr('Группы меню', 'Menyu guruhlari')}
              </Typography.Text>
              <div style={{ marginTop: 6, display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                {w.group_names.length ? (
                  w.group_names.map((g) => (
                    <Tag key={g} bordered={false} style={{ borderRadius: 12, padding: '2px 10px' }}>
                      {g}
                    </Tag>
                  ))
                ) : (
                  <Typography.Text type="secondary">{tr('нет групп', 'guruhlar yoʻq')}</Typography.Text>
                )}
              </div>
              <Typography.Text type="secondary" style={{ marginTop: 14, fontSize: 12 }}>
                {tr('Устройства', 'Qurilmalar')}
              </Typography.Text>
              <Space direction="vertical" style={{ width: '100%', marginTop: 6 }}>
                <Button block icon={<DesktopOutlined />} disabled style={{ borderStyle: 'dashed' }}>
                  {tr('Подключить экран кухни — скоро', 'Oshxona ekranini ulash — tez orada')}
                </Button>
                <Button block icon={<PrinterOutlined />} disabled style={{ borderStyle: 'dashed' }}>
                  {tr('Подключить принтер — скоро', 'Printerni ulash — tez orada')}
                </Button>
              </Space>
              <div style={{ flex: 1 }} />
              {manage && (
                <Button icon={<EditOutlined />} style={{ marginTop: 16 }} onClick={() => setEdit(w)}>
                  {tr('Изменить', 'Oʻzgartirish')}
                </Button>
              )}
            </Card>
          </Col>
        ))}
      </Row>
      {list.data?.length === 0 && <Empty />}
      <Alert
        style={{ marginTop: 16 }}
        type="info"
        showIcon
        icon={<InfoCircleOutlined />}
        message={tr(
          'Экраны кухни, принтеры бегунков и экран выдачи для гостей подключим на следующем этапе — вместе с кассой кафе.',
          'Oshxona ekranlari, chek printerlari va mehmonlar uchun berish ekranini keyingi bosqichda — kafe kassasi bilan birga ulaymiz.',
        )}
      />
      <WorkshopModal open={edit !== null} workshop={edit === 'new' ? undefined : edit ?? undefined} onClose={() => setEdit(null)} />
    </NeedStore>
  )
}

function WorkshopModal({ open, workshop, onClose }: { open: boolean; workshop?: Workshop; onClose: () => void }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const groups = useList<MenuGroup>(open ? '/store/cafe/menu-groups' : null)
  const workshops = useList<Workshop>(open ? '/store/cafe/workshops' : null)
  const [name, setName] = useState('')
  const [nameUz, setNameUz] = useState('')
  const [icon, setIcon] = useState<WorkshopIcon>('fire')
  const [minutes, setMinutes] = useState(15)
  const [print, setPrint] = useState<Workshop['ticket_print']>('offline')
  const [picked, setPicked] = useState<string[]>([])
  const [saving, setSaving] = useState(false)
  useEffect(() => {
    if (!open) return
    setName(workshop?.name_ru ?? '')
    setNameUz(workshop?.name_uz ?? '')
    setIcon(workshop?.icon ?? 'fire')
    setMinutes(workshop?.cook_minutes ?? 15)
    setPrint(workshop?.ticket_print ?? 'offline')
    setPicked(workshop?.group_ids ?? [])
  }, [open, workshop])
  const defaultWs = (workshops.data ?? []).find((w) => w.is_default)
  const whereNow = (g: MenuGroup) => g.workshop_name ?? defaultWs?.name ?? ''

  const save = async () => {
    if (!name.trim() && !nameUz.trim()) {
      message.error(tr('Укажите название цеха', 'Sex nomini kiriting'))
      return
    }
    const body = { name: name.trim() || nameUz.trim(), name_uz: nameUz.trim(), icon, cook_minutes: minutes, ticket_print: print, group_ids: picked }
    setSaving(true)
    try {
      if (workshop) await api.patch(`/store/cafe/workshops/${workshop.id}`, body)
      else await api.post('/store/cafe/workshops', body)
      message.success(workshop ? tr('Цех сохранён', 'Sex saqlandi') : tr('Цех создан', 'Sex yaratildi'))
      qc.invalidateQueries({ queryKey: ['/store/cafe/workshops'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/menu-groups'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/dishes'] })
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
      title={workshop ? workshop.name : tr('Новый цех', 'Yangi sex')}
      okText={workshop ? tr('Сохранить', 'Saqlash') : tr('Создать цех', 'Sex yaratish')}
      cancelText={tr('Отмена', 'Bekor qilish')}
      onOk={save}
      confirmLoading={saving}
      destroyOnHidden
    >
      <Typography.Paragraph type="secondary">
        {tr('Цех — место на кухне, где готовят свои блюда. Заказ делится по цехам: каждый видит только своё.', 'Sex — oshxonada oʻz taomlari tayyorlanadigan joy. Buyurtma sexlarga boʻlinadi: har biri faqat oʻzinikini koʻradi.')}
      </Typography.Paragraph>
      <Row gutter={12}>
        <Col span={12}>
          <Typography.Text type="secondary">Oʻzbekcha</Typography.Text>
          <Input value={nameUz} onChange={(e) => setNameUz(e.target.value)} placeholder="Somsaxona" maxLength={60} />
        </Col>
        <Col span={12}>
          <Typography.Text type="secondary">Русский</Typography.Text>
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Самса" maxLength={60} />
        </Col>
      </Row>
      <Typography.Text type="secondary" style={{ display: 'block', marginTop: 14 }}>
        {tr('Значок', 'Belgi')}
      </Typography.Text>
      <Space wrap style={{ marginTop: 6 }}>
        {WORKSHOP_ICONS.map((i) => (
          <Button
            key={i.key}
            title={i.title}
            onClick={() => setIcon(i.key)}
            style={{ width: 44, height: 44, fontSize: 20, borderColor: icon === i.key ? '#d92d20' : undefined, borderWidth: icon === i.key ? 2 : 1 }}
          >
            {i.emoji}
          </Button>
        ))}
      </Space>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 14 }}>
        <Typography.Text type="secondary">{tr('Группы меню этого цеха', 'Bu sexning menyu guruhlari')}</Typography.Text>
        <Typography.Text type="danger">{tr(`выбрано: ${picked.length}`, `tanlandi: ${picked.length}`)}</Typography.Text>
      </div>
      <div style={{ border: '1px solid var(--sm-line)', borderRadius: 12, marginTop: 6, maxHeight: 260, overflow: 'auto' }}>
        {(groups.data ?? []).map((g) => {
          const on = picked.includes(g.id)
          const moving = on && whereNow(g) && (g.workshop_id ?? defaultWs?.id) !== workshop?.id
          return (
            <div key={g.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 14px', borderBottom: '1px solid var(--sm-line-2)', background: on ? '#fef3f2' : undefined }}>
              <Checkbox checked={on} onChange={(e) => setPicked((p) => (e.target.checked ? [...p, g.id] : p.filter((x) => x !== g.id)))}>
                <b>{g.name}</b>
              </Checkbox>
              <Typography.Text type={moving ? 'warning' : 'secondary'} style={{ fontSize: 12 }}>
                {moving ? tr(`сейчас в «${whereNow(g)}» → перейдёт сюда`, `hozir «${whereNow(g)}»da → bu yerga oʻtadi`) : whereNow(g)}
              </Typography.Text>
            </div>
          )
        })}
        {groups.data?.length === 0 && <Empty style={{ margin: 16 }} description={tr('Групп меню пока нет', 'Hozircha menyu guruhlari yoʻq')} />}
      </div>
      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
        <InfoCircleOutlined /> {tr('Группа может быть только в одном цехе. Отметили — она переезжает сюда со всеми блюдами.', 'Guruh faqat bitta sexda boʻladi. Belgilansa — barcha taomlari bilan bu yerga koʻchadi.')}
      </Typography.Text>
      <Row gutter={12} style={{ marginTop: 14 }}>
        <Col span={8}>
          <Typography.Text type="secondary">{tr('Время по умолчанию', 'Standart vaqt')}</Typography.Text>
          <InputNumber min={1} max={600} value={minutes} onChange={(v) => setMinutes(v ?? 15)} addonAfter={tr('мин', 'daq')} style={{ width: '100%' }} />
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('у блюда можно поставить своё', 'taomda oʻzinikini qoʻyish mumkin')}
          </Typography.Text>
        </Col>
        <Col span={16}>
          <Typography.Text type="secondary">{tr('Бегунок на принтер', 'Printerga chek')}</Typography.Text>
          <Segmented
            block
            value={print}
            onChange={(v) => setPrint(v as Workshop['ticket_print'])}
            options={[
              { value: 'always', label: tr('Всегда', 'Doim') },
              { value: 'offline', label: tr('Если нет экрана', 'Ekran boʻlmasa') },
              { value: 'never', label: tr('Нет', 'Yoʻq') },
            ]}
          />
        </Col>
      </Row>
    </Modal>
  )
}
