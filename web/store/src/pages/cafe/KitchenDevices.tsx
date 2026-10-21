// Кухня → устройства (Figma П7, П7а «Подключить экран кухни», П7в «Подключить
// принтер»): экраны кухни и экран выдачи — устройства кассы другого вида
// (подключаются кодом в приложении кассы), принтер бегунков цеха — по сети,
// печатает касса. Состояние принтеров присылает касса.
import { useEffect, useState, type ReactNode } from 'react'
import { App, Alert, Button, Card, Dropdown, Input, InputNumber, Modal, Segmented, Select, Space, Switch, Tag, Typography } from 'antd'
import {
  CheckCircleFilled,
  CheckOutlined,
  ClockCircleOutlined,
  DesktopOutlined,
  EditOutlined,
  ExclamationCircleFilled,
  MoreOutlined,
  PlusOutlined,
  PrinterOutlined,
  ReloadOutlined,
  TabletOutlined,
  WifiOutlined,
  UsbOutlined,
} from '@ant-design/icons'
import { api, errorText, tr } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import { WorkshopEmoji } from './common'
import type { CafeSettings, KitchenDevice, Workshop } from './types'

const devicesKey = '/store/pos/devices'

const fmtCode = (c: string) => (c.length === 8 ? c.slice(0, 4) + '-' + c.slice(4) : c)

const fmtTime = (s: string | null | undefined) => {
  if (!s) return ''
  const d = new Date(s)
  const today = new Date().toDateString() === d.toDateString()
  return today
    ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

function StatusPill({ on, onText, offText, warn }: { on: boolean; onText?: string; offText?: string; warn?: boolean }) {
  return (
    <Tag bordered={false} color={on ? 'success' : warn ? 'warning' : 'error'} style={{ marginInlineEnd: 0, fontWeight: 600 }}>
      {on ? onText ?? tr('в сети', 'tarmoqda') : offText ?? tr('нет связи', 'aloqa yoʻq')}
    </Tag>
  )
}

/** Строка устройства: значок, название, подпись, состояние, меню. */
function DeviceRow({
  icon,
  title,
  sub,
  status,
  danger,
  menu,
  onClick,
}: {
  icon: ReactNode
  title: ReactNode
  sub: ReactNode
  status: ReactNode
  danger?: boolean
  menu?: { key: string; label: string; danger?: boolean; onClick: () => void }[]
  onClick?: () => void
}) {
  return (
    <div
      onClick={onClick}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        padding: '10px 12px',
        borderRadius: 10,
        background: danger ? '#fef3f2' : 'var(--sm-bg-2, #f9fafb)',
        cursor: onClick ? 'pointer' : undefined,
      }}
    >
      <div style={{ width: 36, height: 36, borderRadius: 8, background: '#fff', display: 'grid', placeItems: 'center', fontSize: 18, flex: 'none' }}>
        {icon}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600 }}>{title}</div>
        <Typography.Text type={danger ? 'danger' : 'secondary'} style={{ fontSize: 12 }}>
          {sub}
        </Typography.Text>
      </div>
      {status}
      {menu && menu.length > 0 && (
        <Dropdown menu={{ items: menu.map((m) => ({ key: m.key, label: m.label, danger: m.danger, onClick: (e) => (e.domEvent.stopPropagation(), m.onClick()) })) }}>
          <Button type="text" size="small" icon={<MoreOutlined />} onClick={(e) => e.stopPropagation()} />
        </Dropdown>
      )}
    </div>
  )
}

/** Меню устройства: новый код, отключить, удалить (ещё не подключённое). */
function useDeviceMenu(onCode: (d: KitchenDevice) => void) {
  const { modal, message } = App.useApp()
  const qc = useQueryClient()
  return (d: KitchenDevice) => {
    const items: { key: string; label: string; danger?: boolean; onClick: () => void }[] = [
      { key: 'code', label: tr('Новый код подключения', 'Yangi ulash kodi'), onClick: () => onCode(d) },
    ]
    if (d.status === 'active')
      items.push({
        key: 'revoke',
        label: tr('Отключить', 'Oʻchirish'),
        danger: true,
        onClick: () =>
          modal.confirm({
            title: tr(`Отключить «${d.name}»?`, `«${d.name}» oʻchirilsinmi?`),
            content: tr('Экран перестанет получать заказы. Подключить снова можно новым кодом.', 'Ekran buyurtmalarni olmaydi. Yangi kod bilan qayta ulash mumkin.'),
            okButtonProps: { danger: true },
            onOk: async () => {
              try {
                await api.post(`/store/pos/devices/${d.id}/revoke`)
                qc.invalidateQueries({ queryKey: [devicesKey] })
              } catch (e) {
                message.error(errorText(e))
              }
            },
          }),
      })
    else
      items.push({
        key: 'del',
        label: tr('Удалить', 'Oʻchirish'),
        danger: true,
        onClick: async () => {
          try {
            await api.del(`/store/pos/devices/${d.id}`)
            qc.invalidateQueries({ queryKey: [devicesKey] })
          } catch (e) {
            message.error(errorText(e))
          }
        },
      })
    return items
  }
}

function screenSub(d: KitchenDevice) {
  if (d.status === 'waiting') {
    return d.activation_expires
      ? tr(`ждёт подключения · код до ${fmtTime(d.activation_expires)}`, `ulanishni kutmoqda · kod ${fmtTime(d.activation_expires)} gacha`)
      : tr('ждёт подключения', 'ulanishni kutmoqda')
  }
  if (d.online) return tr(`приложение кассы · подключён ${fmtTime(d.activated_at)}`, `kassa ilovasi · ${fmtTime(d.activated_at)} ulangan`)
  return d.last_seen_at ? tr(`последний раз ${fmtTime(d.last_seen_at)}`, `oxirgi marta ${fmtTime(d.last_seen_at)}`) : tr('ещё не выходил на связь', 'hali aloqaga chiqmagan')
}

function screenStatus(d: KitchenDevice) {
  if (d.status === 'waiting') return <StatusPill on={false} warn offText={tr('ждёт кода', 'kod kutmoqda')} />
  return <StatusPill on={d.online} />
}

// ------------------------------------------------------------- карточка цеха

export function WorkshopCard({
  w,
  screens,
  manage,
  onEdit,
  onRemove,
  onConnect,
  onShowCode,
  onPrinter,
}: {
  w: Workshop
  screens: KitchenDevice[]
  manage: boolean
  onEdit: () => void
  onRemove?: () => void
  onConnect: () => void
  onShowCode: (d: KitchenDevice) => void
  onPrinter: () => void
}) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const menuFor = useDeviceMenu(onShowCode)
  const [testing, setTesting] = useState(false)
  const own = screens.filter((d) => d.workshop_id === w.id)
  const all = screens.filter((d) => d.workshop_id === null)
  const net = w.printer_kind === 'network'
  const printerDown = net && w.printer_ok === false
  const screenDown = [...own, ...all].some((d) => d.status === 'active' && !d.online)
  const hasScreen = [...own, ...all].some((d) => d.status === 'active')
  const health = printerDown
    ? { ok: false, text: tr('нет связи с принтером', 'printer bilan aloqa yoʻq') }
    : screenDown
      ? { ok: false, text: tr('экран кухни не в сети', 'oshxona ekrani tarmoqda emas') }
      : hasScreen || net
        ? { ok: true, text: tr('всё работает', 'hammasi ishlayapti') }
        : null

  const test = async () => {
    setTesting(true)
    try {
      await api.post(`/store/cafe/workshops/${w.id}/test-print`)
      message.info(
        tr('Касса этой точки напечатает тестовый бегунок в течение 10–20 секунд', 'Shu nuqtadagi kassa 10–20 soniya ichida sinov chekini chop etadi'),
      )
      setTimeout(() => qc.invalidateQueries({ queryKey: ['/store/cafe/workshops'] }), 20000)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setTesting(false)
    }
  }

  return (
    <Card
      style={{ height: '100%', borderColor: printerDown ? '#f04438' : undefined }}
      styles={{ body: { display: 'flex', flexDirection: 'column', height: '100%' } }}
    >
      <div style={{ display: 'flex', gap: 12, alignItems: 'flex-start' }}>
        <WorkshopEmoji icon={w.icon} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 18, fontWeight: 800 }}>
            {w.name} {w.is_default && <Tag bordered={false}>{tr('по умолчанию', 'asosiy')}</Tag>}
          </div>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            {tr('норма по умолчанию', 'standart meʼyor')} · {w.cook_minutes} {tr('мин', 'daq')}
          </Typography.Text>
        </div>
        {manage && onRemove && (
          <Dropdown menu={{ items: [{ key: 'del', danger: true, label: tr('Удалить цех', 'Sexni oʻchirish'), onClick: onRemove }] }}>
            <Button type="text" icon={<MoreOutlined />} />
          </Dropdown>
        )}
      </div>
      {health && (
        <div style={{ marginTop: 10 }}>
          <Tag bordered={false} color={health.ok ? 'success' : 'error'} icon={health.ok ? <CheckCircleFilled /> : <ExclamationCircleFilled />} style={{ fontWeight: 600 }}>
            {health.text}
          </Tag>
        </div>
      )}
      <Typography.Text type="secondary" style={{ marginTop: 12, fontSize: 12 }}>
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
      <Space direction="vertical" style={{ width: '100%', marginTop: 6 }} size={8}>
        {own.map((d) => (
          <DeviceRow
            key={d.id}
            icon={<TabletOutlined />}
            title={tr('Экран кухни', 'Oshxona ekrani') + (d.name ? ' · ' + d.name : '')}
            sub={screenSub(d)}
            status={screenStatus(d)}
            menu={manage ? menuFor(d) : undefined}
          />
        ))}
        {all.map((d) => (
          <DeviceRow
            key={d.id}
            icon={<TabletOutlined />}
            title={tr('Экран всех цехов', 'Barcha sexlar ekrani') + (d.name ? ' · ' + d.name : '')}
            sub={screenSub(d)}
            status={screenStatus(d)}
            menu={manage ? menuFor(d) : undefined}
          />
        ))}
        {net ? (
          <DeviceRow
            icon={<PrinterOutlined />}
            title={tr(`Принтер бегунков ${w.printer_paper} мм`, `Buyurtma printeri ${w.printer_paper} mm`)}
            sub={
              printerDown
                ? tr(`${w.printer_host} · последний раз ${fmtTime(w.printer_seen_at)}`, `${w.printer_host} · oxirgi marta ${fmtTime(w.printer_seen_at)}`)
                : `${w.printer_host} · ${
                    w.ticket_print === 'always'
                      ? tr('печатает каждый заказ', 'har bir buyurtmani chop etadi')
                      : w.ticket_print === 'never'
                        ? tr('бегунок выключен', 'chek oʻchirilgan')
                        : tr('печатает, если экран не в сети', 'ekran tarmoqda boʻlmasa chop etadi')
                  }`
            }
            danger={printerDown}
            status={
              w.printer_ok === null ? (
                <Tag bordered={false} style={{ marginInlineEnd: 0 }}>
                  {tr('ещё не печатал', 'hali chop etmagan')}
                </Tag>
              ) : (
                <StatusPill on={w.printer_ok} />
              )
            }
            onClick={manage ? onPrinter : undefined}
          />
        ) : null}
        {manage && own.length === 0 && all.length === 0 && (
          <Button block icon={<PlusOutlined />} style={{ borderStyle: 'dashed' }} onClick={onConnect}>
            {tr('Подключить экран кухни', 'Oshxona ekranini ulash')}
          </Button>
        )}
        {manage && !net && (
          <Button block icon={<PlusOutlined />} style={{ borderStyle: 'dashed' }} onClick={onPrinter}>
            {tr('Подключить принтер', 'Printerni ulash')}
          </Button>
        )}
        {!net && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Без принтера цеха бегунок печатает касса на свой принтер чеков.', 'Sex printeri boʻlmasa, chekni kassa oʻz printerida chop etadi.')}
          </Typography.Text>
        )}
        {w.printer_pending > 0 && (
          <Typography.Text type="danger" style={{ fontSize: 12.5 }}>
            <ExclamationCircleFilled />{' '}
            {tr(
              `${w.printer_pending} бегунк(а) не напечатаны — повторим, когда принтер появится`,
              `${w.printer_pending} ta chek chop etilmadi — printer paydo boʻlganda qaytaramiz`,
            )}
          </Typography.Text>
        )}
      </Space>
      <div style={{ flex: 1 }} />
      {manage && (
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <Button style={{ flex: 1 }} icon={<PrinterOutlined />} loading={testing} onClick={test}>
            {tr('Тест печати', 'Sinov chop')}
          </Button>
          <Button style={{ flex: 1 }} icon={<EditOutlined />} onClick={onEdit}>
            {tr('Изменить', 'Oʻzgartirish')}
          </Button>
        </div>
      )}
    </Card>
  )
}

// ------------------------------------------------- П7а «Подключить экран»

export function ConnectModal({
  open,
  kind,
  storeId,
  workshops,
  workshopId,
  device,
  onClose,
}: {
  open: boolean
  kind: 'kitchen' | 'display'
  storeId: string
  workshops: Workshop[]
  /** Цех для нового экрана кухни ('' — все цеха). */
  workshopId?: string
  /** Уже созданное устройство — показать его новый код. */
  device?: KitchenDevice
  onClose: () => void
}) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [ws, setWs] = useState('')
  const [dev, setDev] = useState<KitchenDevice | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!open) return
    setWs(device?.workshop_id ?? workshopId ?? '')
    setDev(null)
    if (device) void fresh(device.id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, device?.id])

  const fresh = async (id: string) => {
    setBusy(true)
    try {
      setDev(await api.post<KitchenDevice>(`/store/pos/devices/${id}/code`))
      qc.invalidateQueries({ queryKey: [devicesKey] })
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  const create = async () => {
    const wsName = workshops.find((w) => w.id === ws)?.name
    const name = kind === 'display' ? tr('Экран выдачи', 'Berish ekrani') : wsName ? tr(`Экран · ${wsName}`, `Ekran · ${wsName}`) : tr('Экран кухни', 'Oshxona ekrani')
    setBusy(true)
    try {
      setDev(await api.post<KitchenDevice>(devicesKey, { store_id: storeId, name, kind, workshop_id: kind === 'kitchen' && ws ? ws : null }))
      qc.invalidateQueries({ queryKey: [devicesKey] })
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  const code = dev?.activation_code ?? ''
  const wsTitle = workshops.find((w) => w.id === (dev?.workshop_id ?? ws))?.name
  const steps =
    kind === 'display'
      ? [
          tr('На телевизоре (Android TV) или приставке установите приложение кассы Super Market.', 'Televizor (Android TV) yoki pristavkaga Super Market kassa ilovasini oʻrnating.'),
          tr('Откройте его и введите код — там же, где подключают кассу.', 'Uni oching va kodni kiriting — kassa ulanadigan joyda.'),
          tr('Экран сразу покажет номера: «Готовим» и «Готово — заберите».', 'Ekran darhol raqamlarni koʻrsatadi: «Tayyorlanmoqda» va «Tayyor — olib keting».'),
        ]
      : [
          tr('На планшете (Android) установите приложение кассы Super Market.', 'Planshetga (Android) Super Market kassa ilovasini oʻrnating.'),
          tr('Откройте его и введите код — там же, где подключают кассу.', 'Uni oching va kodni kiriting — kassa ulanadigan joyda.'),
          wsTitle
            ? tr(`Планшет сразу покажет заказы цеха «${wsTitle}».`, `Planshet darhol «${wsTitle}» sexi buyurtmalarini koʻrsatadi.`)
            : tr('Планшет сразу покажет заказы всех цехов — с вкладками.', 'Planshet darhol barcha sexlar buyurtmalarini koʻrsatadi — yorliqlar bilan.'),
        ]

  return (
    <Modal
      open={open}
      onCancel={onClose}
      width={520}
      title={kind === 'display' ? tr('Подключить экран выдачи', 'Berish ekranini ulash') : tr('Подключить экран кухни', 'Oshxona ekranini ulash')}
      footer={
        dev ? (
          <div style={{ display: 'flex', gap: 8 }}>
            <Button style={{ flex: 1 }} icon={<ReloadOutlined />} loading={busy} onClick={() => fresh(dev.id)}>
              {tr('Новый код', 'Yangi kod')}
            </Button>
            <Button style={{ flex: 1 }} type="primary" icon={<CheckOutlined />} onClick={onClose}>
              {tr('Готово', 'Tayyor')}
            </Button>
          </div>
        ) : (
          <Button type="primary" block loading={busy} onClick={create}>
            {tr('Получить код', 'Kod olish')}
          </Button>
        )
      }
      destroyOnHidden
    >
      {kind === 'kitchen' && (
        <>
          <Typography.Text type="secondary">{tr('Цех', 'Sex')}</Typography.Text>
          <Select
            style={{ width: '100%', marginTop: 4 }}
            value={dev ? dev.workshop_id ?? '' : ws}
            disabled={!!dev}
            onChange={setWs}
            options={[
              { value: '', label: tr('Все цеха — вкладками на одном экране', 'Barcha sexlar — bitta ekranda yorliqlar bilan') },
              ...workshops.map((w) => ({ value: w.id, label: w.name })),
            ]}
          />
        </>
      )}
      {dev && (
        <div style={{ marginTop: 16, padding: 18, borderRadius: 12, background: '#f9fafb', textAlign: 'center' }}>
          <Typography.Text type="secondary" style={{ fontSize: 12, fontWeight: 700, letterSpacing: 1 }}>
            {kind === 'display' ? tr('КОД ДЛЯ ТЕЛЕВИЗОРА', 'TELEVIZOR UCHUN KOD') : tr('КОД ДЛЯ ПЛАНШЕТА', 'PLANSHET UCHUN KOD')}
          </Typography.Text>
          <div>
            <Typography.Text copyable={{ text: code }} style={{ fontSize: 40, fontWeight: 800, letterSpacing: 6, fontFamily: 'monospace' }}>
              {fmtCode(code)}
            </Typography.Text>
          </div>
          {dev.activation_expires && (
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              <ClockCircleOutlined /> {tr(`действует до ${fmtTime(dev.activation_expires)}`, `${fmtTime(dev.activation_expires)} gacha amal qiladi`)}
            </Typography.Text>
          )}
        </div>
      )}
      <ol style={{ margin: '16px 0 0', paddingLeft: 20, display: 'grid', gap: 6 }}>
        {steps.map((s) => (
          <li key={s}>{s}</li>
        ))}
      </ol>
    </Modal>
  )
}

// --------------------------------------------- П7в «Подключить принтер»

export function PrinterModal({ open, workshop, onClose }: { open: boolean; workshop?: Workshop; onClose: () => void }) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [kind, setKind] = useState<Workshop['printer_kind']>('network')
  const [host, setHost] = useState('')
  const [port, setPort] = useState(9100)
  const [paper, setPaper] = useState<58 | 80>(80)
  const [saving, setSaving] = useState(false)
  useEffect(() => {
    if (!open || !workshop) return
    setKind(workshop.printer_kind === 'none' ? 'network' : workshop.printer_kind)
    setHost(workshop.printer_host)
    setPort(workshop.printer_port || 9100)
    setPaper(workshop.printer_paper || 80)
  }, [open, workshop])
  if (!workshop) return null

  const save = async (andTest: boolean) => {
    if (kind === 'network' && !host.trim()) {
      message.error(tr('Укажите IP-адрес принтера', 'Printer IP manzilini kiriting'))
      return
    }
    setSaving(true)
    try {
      await api.patch(`/store/cafe/workshops/${workshop.id}`, {
        printer_kind: kind,
        printer_host: kind === 'network' ? host.trim() : '',
        printer_port: port,
        printer_paper: paper,
      })
      if (andTest && kind === 'network') {
        await api.post(`/store/cafe/workshops/${workshop.id}/test-print`)
        message.info(tr('Сохранено. Касса напечатает тестовый бегунок в течение 10–20 секунд', 'Saqlandi. Kassa 10–20 soniyada sinov chekini chop etadi'))
        setTimeout(() => qc.invalidateQueries({ queryKey: ['/store/cafe/workshops'] }), 20000)
      } else {
        message.success(tr('Принтер сохранён', 'Printer saqlandi'))
      }
      qc.invalidateQueries({ queryKey: ['/store/cafe/workshops'] })
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  const option = (k: Workshop['printer_kind'], icon: ReactNode, title: string) => (
    <div
      onClick={() => setKind(k)}
      style={{
        flex: 1,
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '12px 14px',
        borderRadius: 10,
        cursor: 'pointer',
        border: kind === k ? '2px solid #d92d20' : '1px solid var(--sm-line, #eaecf0)',
        background: kind === k ? '#fef3f2' : undefined,
        fontWeight: 600,
      }}
    >
      {icon} {title}
    </div>
  )

  return (
    <Modal
      open={open}
      onCancel={onClose}
      width={560}
      title={tr(`Принтер бегунков · цех «${workshop.name}»`, `Buyurtma printeri · «${workshop.name}» sexi`)}
      footer={
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <Button onClick={onClose}>{tr('Отмена', 'Bekor qilish')}</Button>
          {kind === 'network' && (
            <Button icon={<PrinterOutlined />} loading={saving} onClick={() => save(true)}>
              {tr('Сохранить и проверить', 'Saqlash va tekshirish')}
            </Button>
          )}
          <Button type="primary" icon={<CheckOutlined />} loading={saving} onClick={() => save(false)}>
            {tr('Сохранить', 'Saqlash')}
          </Button>
        </div>
      }
      destroyOnHidden
    >
      <Typography.Paragraph type="secondary">
        {tr('Печатает заказы цеха, если экрана нет или он не в сети.', 'Ekran boʻlmasa yoki tarmoqda boʻlmasa, sex buyurtmalarini chop etadi.')}
      </Typography.Paragraph>
      <Typography.Text type="secondary">{tr('Как подключён', 'Qanday ulangan')}</Typography.Text>
      <div style={{ display: 'flex', gap: 10, marginTop: 6 }}>
        {option('network', <WifiOutlined />, tr('По сети (Wi-Fi / кабель)', 'Tarmoq orqali (Wi-Fi / kabel)'))}
        {option('none', <UsbOutlined />, tr('Принтер кассы', 'Kassa printeri'))}
      </div>
      {kind === 'network' ? (
        <>
          <div style={{ display: 'flex', gap: 12, marginTop: 16 }}>
            <div style={{ flex: 2 }}>
              <Typography.Text type="secondary">{tr('IP-адрес принтера', 'Printer IP manzili')}</Typography.Text>
              <Input value={host} onChange={(e) => setHost(e.target.value)} placeholder="192.168.1.42" maxLength={100} />
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {tr('есть на тестовой печати принтера', 'printerning sinov chopida bor')}
              </Typography.Text>
            </div>
            <div style={{ flex: 1 }}>
              <Typography.Text type="secondary">{tr('Порт', 'Port')}</Typography.Text>
              <InputNumber value={port} min={1} max={65535} onChange={(v) => setPort(v ?? 9100)} style={{ width: '100%' }} />
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {tr('обычно 9100', 'odatda 9100')}
              </Typography.Text>
            </div>
          </div>
          <Typography.Text type="secondary" style={{ display: 'block', marginTop: 14 }}>
            {tr('Ширина ленты', 'Lenta kengligi')}
          </Typography.Text>
          <Segmented
            value={paper}
            onChange={(v) => setPaper(v as 58 | 80)}
            options={[
              { value: 58, label: '58 мм' },
              { value: 80, label: '80 мм' },
            ]}
          />
          {workshop.printer_kind === 'network' && workshop.printer_ok !== null && (
            <Alert
              style={{ marginTop: 16 }}
              type={workshop.printer_ok ? 'success' : 'error'}
              showIcon
              message={workshop.printer_ok ? tr('Принтер отвечает', 'Printer javob bermoqda') : tr('Принтер не отвечает', 'Printer javob bermayapti')}
              description={workshop.printer_seen_at ? tr(`касса проверила в ${fmtTime(workshop.printer_seen_at)}`, `kassa ${fmtTime(workshop.printer_seen_at)} da tekshirdi`) : undefined}
            />
          )}
          <Typography.Paragraph type="secondary" style={{ marginTop: 16, fontSize: 12.5 }}>
            {tr(
              'Принтер должен быть в той же сети, что и касса: бегунки отправляет касса этой точки — и без интернета.',
              'Printer kassa bilan bir tarmoqda boʻlishi kerak: cheklarni shu nuqtadagi kassa yuboradi — internetsiz ham.',
            )}
          </Typography.Paragraph>
        </>
      ) : (
        <Typography.Paragraph type="secondary" style={{ marginTop: 16 }}>
          {tr(
            'Бегунок цеха печатает касса на свой принтер чеков — подойдёт, если кухня рядом с кассой.',
            'Sex chekini kassa oʻz chek printerida chop etadi — oshxona kassa yonida boʻlsa mos keladi.',
          )}
        </Typography.Paragraph>
      )}
    </Modal>
  )
}

// ----------------------------------------- экран выдачи и заказы на кухне

export function DisplayCard({
  displays,
  settings,
  manage,
  onConnect,
  onShowCode,
  onSave,
}: {
  displays: KitchenDevice[]
  settings?: CafeSettings
  manage: boolean
  onConnect: () => void
  onShowCode: (d: KitchenDevice) => void
  onSave: (patch: Partial<CafeSettings>) => void
}) {
  const menuFor = useDeviceMenu(onShowCode)
  const anyOnline = displays.some((d) => d.online)
  return (
    <Card
      title={
        <span>
          <DesktopOutlined /> {tr('Экран выдачи для гостей', 'Mehmonlar uchun berish ekrani')}
        </span>
      }
      extra={displays.length > 0 && <StatusPill on={anyOnline} />}
      style={{ height: '100%' }}
    >
      <Space direction="vertical" style={{ width: '100%' }} size={10}>
        {displays.map((d) => (
          <DeviceRow
            key={d.id}
            icon={<DesktopOutlined />}
            title={d.name}
            sub={d.status === 'waiting' ? screenSub(d) : tr('показывает номера заказов', 'buyurtma raqamlarini koʻrsatadi') + ' · ' + screenSub(d)}
            status={screenStatus(d)}
            menu={manage ? menuFor(d) : undefined}
          />
        ))}
        {manage && (
          <Button block icon={<PlusOutlined />} style={{ borderStyle: 'dashed' }} onClick={onConnect}>
            {tr('Подключить экран выдачи', 'Berish ekranini ulash')}
          </Button>
        )}
        {settings && (
          <>
            <SettingRow
              title={tr('Показывать «Готовим»', '«Tayyorlanmoqda»ni koʻrsatish')}
              sub={tr('номера, которые ещё готовятся, серым', 'hali tayyorlanayotgan raqamlar kulrang')}
              control={<Switch checked={settings.display_show_cooking} disabled={!manage} onChange={(v) => onSave({ display_show_cooking: v })} />}
            />
            <SettingRow
              title={tr('Убирать готовый номер через', 'Tayyor raqamni olib tashlash')}
              sub={tr('если «Выдано» не нажали', '«Berildi» bosilmasa')}
              control={
                <InputNumber
                  min={1}
                  max={120}
                  value={settings.display_hide_minutes}
                  disabled={!manage}
                  addonAfter={tr('мин', 'daq')}
                  style={{ width: 120 }}
                  onChange={(v) => v && onSave({ display_hide_minutes: v })}
                />
              }
            />
          </>
        )}
      </Space>
    </Card>
  )
}

function SettingRow({ title, sub, control }: { title: ReactNode; sub?: ReactNode; control: ReactNode }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
      <div style={{ flex: 1 }}>
        <div style={{ fontWeight: 600 }}>{title}</div>
        {sub && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {sub}
          </Typography.Text>
        )}
      </div>
      {control}
    </div>
  )
}

export function OrdersCard({ settings, manage, onSave }: { settings?: CafeSettings; manage: boolean; onSave: (patch: Partial<CafeSettings>) => void }) {
  const soon = (
    <Tag bordered={false} style={{ marginInlineEnd: 0 }}>
      {tr('скоро', 'tez orada')}
    </Tag>
  )
  return (
    <Card title={tr('Заказы на кухне', 'Oshxonadagi buyurtmalar')} style={{ height: '100%' }}>
      <Space direction="vertical" style={{ width: '100%' }} size={14}>
        <SettingRow
          title={tr('Номер заказа с 001 каждый день', 'Buyurtma raqami har kuni 001 dan')}
          sub={tr('номер выдаёт касса — и без интернета', 'raqamni kassa beradi — internetsiz ham')}
          control={<Switch checked disabled />}
        />
        <SettingRow
          title={tr('«С собой» — сам добавлять контейнер', '«Olib ketish» — idishni oʻzi qoʻshish')}
          sub={tr('по 1 контейнеру на горячее блюдо', 'har bir issiq taomga 1 ta idish')}
          control={soon}
        />
        <SettingRow
          title={tr('Звук на экране кухни при новом заказе', 'Yangi buyurtmada oshxona ekranida ovoz')}
          control={<Switch checked={settings?.kitchen_sound ?? true} disabled={!manage || !settings} onChange={(v) => onSave({ kitchen_sound: v })} />}
        />
        <SettingRow
          title={tr('Готовить только после оплаты', 'Faqat toʻlovdan keyin tayyorlash')}
          sub={tr('у прилавка заказ идёт на кухню после оплаты; «На кухню без оплаты» — вместе со столами', 'peshtaxtada buyurtma toʻlovdan keyin oshxonaga tushadi; «Toʻlovsiz oshxonaga» — stollar bilan birga')}
          control={soon}
        />
      </Space>
    </Card>
  )
}
