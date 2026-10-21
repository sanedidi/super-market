// Кухня → Цеха и устройства (Figma П7): цеха с группами меню, экраны кухни,
// принтеры бегунков (П7а, П7в), экран выдачи для гостей и настройки заказов;
// окно «Новый цех» (П7б).
import { useEffect, useState } from 'react'
import { App, Button, Checkbox, Col, Empty, Input, InputNumber, Modal, Row, Segmented, Space, Typography } from 'antd'
import { DesktopOutlined, InfoCircleOutlined, PlusOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, tr, useItem, useList } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { LinkTabs, WORKSHOP_ICONS } from './common'
import { ConnectModal, DisplayCard, OrdersCard, PrinterModal, WorkshopCard } from './KitchenDevices'
import type { CafeSettings, KitchenDevice, MenuGroup, Workshop, WorkshopIcon } from './types'

type Connect = { kind: 'kitchen' | 'display'; workshopId?: string; device?: KitchenDevice }

export function KitchenPage() {
  const { can, storeId } = useStore()
  const manage = can('catalog.manage')
  const list = useList<Workshop>('/store/cafe/workshops')
  const devices = useList<KitchenDevice>(storeId ? '/store/pos/devices' : null, { kind: 'kitchen,display', store_id: storeId })
  const settings = useItem<CafeSettings>('/store/cafe/settings')
  const [edit, setEdit] = useState<Workshop | 'new' | null>(null)
  const [connect, setConnect] = useState<Connect | null>(null)
  const [printer, setPrinter] = useState<Workshop | null>(null)
  const { modal, message } = App.useApp()
  const qc = useQueryClient()

  // «В сети» и состояние принтеров меняются сами — обновлять раз в 15 секунд.
  useEffect(() => {
    const t = setInterval(() => {
      qc.invalidateQueries({ queryKey: ['/store/pos/devices'] })
      qc.invalidateQueries({ queryKey: ['/store/cafe/workshops'] })
    }, 15000)
    return () => clearInterval(t)
  }, [qc])

  const live = (devices.data ?? []).filter((d) => d.status !== 'revoked')
  const screens = live.filter((d) => d.kind === 'kitchen')
  const displays = live.filter((d) => d.kind === 'display')

  const saveSettings = async (patch: Partial<CafeSettings>) => {
    try {
      const next = await api.patch<CafeSettings>('/store/cafe/settings', patch)
      qc.setQueryData(['/store/cafe/settings', undefined], next)
    } catch (e) {
      message.error(errorText(e))
    }
  }

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
          qc.invalidateQueries({ queryKey: ['/store/pos/devices'] })
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
            <Space>
              <Button icon={<DesktopOutlined />} onClick={() => setConnect({ kind: 'display' })}>
                {tr('Экран выдачи', 'Berish ekrani')}
              </Button>
              <Button type="primary" icon={<PlusOutlined />} onClick={() => setEdit('new')}>
                {tr('Цех', 'Sex')}
              </Button>
            </Space>
          )
        }
      />
      <Typography.Paragraph type="secondary">
        {tr(
          'Цеха, экраны кухни, принтеры бегунков и экран выдачи для гостей. Заказ попадает в цех по группе меню блюда (или по цеху, указанному у блюда).',
          'Sexlar, oshxona ekranlari, chek printerlari va mehmonlar uchun berish ekrani. Buyurtma sexga taomning menyu guruhi boʻyicha tushadi (yoki taomda koʻrsatilgan sex boʻyicha).',
        )}
      </Typography.Paragraph>
      <LoadError error={list.error ?? devices.error} retry={() => (list.refetch(), devices.refetch())} />
      <Row gutter={[16, 16]}>
        {(list.data ?? []).map((w) => (
          <Col key={w.id} xs={24} md={12} xl={8}>
            <WorkshopCard
              w={w}
              screens={screens}
              manage={manage}
              onEdit={() => setEdit(w)}
              onRemove={w.is_default ? undefined : () => remove(w)}
              onConnect={() => setConnect({ kind: 'kitchen', workshopId: w.id })}
              onShowCode={(d) => setConnect({ kind: d.kind === 'display' ? 'display' : 'kitchen', device: d })}
              onPrinter={() => setPrinter(w)}
            />
          </Col>
        ))}
      </Row>
      {list.data?.length === 0 && <Empty />}
      <Row gutter={[16, 16]} style={{ marginTop: 16 }}>
        <Col xs={24} lg={12}>
          <DisplayCard
            displays={displays}
            settings={settings.data}
            manage={manage}
            onConnect={() => setConnect({ kind: 'display' })}
            onShowCode={(d) => setConnect({ kind: 'display', device: d })}
            onSave={saveSettings}
          />
        </Col>
        <Col xs={24} lg={12}>
          <OrdersCard settings={settings.data} manage={manage} onSave={saveSettings} />
        </Col>
      </Row>
      <WorkshopModal open={edit !== null} workshop={edit === 'new' ? undefined : edit ?? undefined} onClose={() => setEdit(null)} />
      <ConnectModal
        open={connect !== null}
        kind={connect?.kind ?? 'kitchen'}
        storeId={storeId}
        workshops={list.data ?? []}
        workshopId={connect?.workshopId}
        device={connect?.device}
        onClose={() => setConnect(null)}
      />
      <PrinterModal open={printer !== null} workshop={printer ?? undefined} onClose={() => setPrinter(null)} />
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
