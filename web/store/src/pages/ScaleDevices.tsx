// Весы магазина и отправка товаров в весы (Figma «Панель магазина · Весы:
// отправка товаров в весы (любой бренд)», Н1–Н5).
//
// Весы стоят в сети магазина — сервер их не видит. Панель создаёт задание,
// касса Super Market в той же сети забирает его (раз в 10 секунд), передаёт
// товары на весы и сообщает итог. Rongta и Dahua — «Напрямую»; остальные
// бренды — файл для программы весов и «Загружено в весы».
import { useEffect, useMemo, useState } from 'react'
import { Alert, App, Button, Card, Checkbox, Col, Dropdown, Form, Input, InputNumber, Modal, Radio, Row, Select, Space, Table, Tag, Typography } from 'antd'
import {
  CheckCircleFilled,
  CloseCircleFilled,
  DownloadOutlined,
  ExclamationCircleFilled,
  FileTextOutlined,
  MoreOutlined,
  PlusOutlined,
  ReloadOutlined,
  ThunderboltFilled,
  UploadOutlined,
  WifiOutlined,
} from '@ant-design/icons'
import { useQueryClient } from '@tanstack/react-query'
import { api, dateTime, errorText, money, tr, useAction, useList } from '@sm/shared'
import { useStore } from '../ctx'
import { saveBlob, xlsxBlob } from '../xlsx'

// ------------------------------------------------------------------ типы

export type ScaleFailure = { product_id: string; plu: number; name: string; error: string }

export type ScaleJob = {
  id: string
  scale_id: string
  scale_name: string
  kind: 'send' | 'check'
  mode: 'changed' | 'all'
  status: 'pending' | 'running' | 'done' | 'failed'
  total: number
  sent: number
  error: string | null
  failures: ScaleFailure[]
  created_at: string
  taken_at: string | null
  done_at: string | null
}

export type ScaleDevice = {
  id: string
  name: string
  brand: string
  model: string
  host: string
  port: number
  device_id: string | null
  device_name: string | null
  device_online: boolean
  direct: boolean
  check_at: string | null
  check_ok: boolean | null
  check_error: string | null
  items: number
  last_sent_at: string | null
  to_send: number
  job: ScaleJob | null
}

type FileRow = { product_id: string; plu: number; code: string; name: string; price: number; unit: string }

type PosDevice = { id: string; name: string; status: string; kind: string; online: boolean }

export const DEVICES = '/store/scales/devices'
const SCALES = '/store/scales/products'
const COUNTS = '/store/scales/counts'

export const BRANDS: { value: string; label: () => string; direct: boolean }[] = [
  { value: 'rongta', label: () => 'Rongta', direct: true },
  { value: 'dahua', label: () => 'Dahua', direct: true },
  { value: 'kuanyi', label: () => 'Kuanyi', direct: false },
  { value: 'cas', label: () => 'CAS', direct: false },
  { value: 'massak', label: () => tr('Масса-К', 'Massa-K'), direct: false },
  { value: 'shtrih', label: () => tr('Штрих-Принт', 'Shtrix-Print'), direct: false },
  { value: 'other', label: () => tr('Другие', 'Boshqalar'), direct: false },
]

const brandName = (b: string) => BRANDS.find((x) => x.value === b)?.label() ?? b

export function useScaleDevices(storeId: string | undefined) {
  return useList<ScaleDevice>(storeId ? DEVICES : null, { store_id: storeId })
}

const HowTag = ({ direct }: { direct: boolean }) =>
  direct ? (
    <Tag color="green" icon={<ThunderboltFilled />} style={{ borderRadius: 999 }}>
      {tr('Напрямую', 'Toʻgʻridan-toʻgʻri')}
    </Tag>
  ) : (
    <Tag icon={<FileTextOutlined />} style={{ borderRadius: 999 }}>
      {tr('Через файл', 'Fayl orqali')}
    </Tag>
  )

const Dot = ({ ok }: { ok: boolean }) => <span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 4, background: ok ? '#12B76A' : '#E11D2A', marginRight: 6 }} />

const goods = (n: number) => tr(`${n} ${n % 10 === 1 && n % 100 !== 11 ? 'товар' : n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? 'товара' : 'товаров'}`, `${n} ta mahsulot`)

// ----------------------------------------------------- Н1: весы в магазине

export function ScaleDevicesCard({ readOnly }: { readOnly: boolean }) {
  const { storeId, can } = useStore()
  const { modal } = App.useApp()
  const list = useScaleDevices(storeId)
  const [edit, setEdit] = useState<ScaleDevice | 'new' | null>(null)
  const [send, setSend] = useState<string[] | null>(null)
  const [file, setFile] = useState<ScaleDevice | null>(null)
  const canSend = can('catalog.manage') || can('prices.manage')
  const remove = useAction((id: string) => api.del(`${DEVICES}/${id}`), {
    invalidate: [[DEVICES], [SCALES], [COUNTS]],
    success: tr('Весы удалены', 'Tarozi oʻchirildi'),
  })
  const check = useAction((id: string) => api.post<ScaleJob>(`${DEVICES}/${id}/check`), {
    invalidate: [[DEVICES]],
    success: tr('Касса проверит связь с весами в течение 10 секунд', 'Kassa 10 soniya ichida tarozi bilan aloqani tekshiradi'),
  })
  const items = list.data ?? []
  // Пока касса проверяет связь или отправляет — обновляем список сами.
  const busy = items.some((d) => d.job && (d.job.status === 'pending' || d.job.status === 'running'))
  useEffect(() => {
    if (!busy) return
    const t = setInterval(() => list.refetch(), 3000)
    return () => clearInterval(t)
  }, [busy, list])
  if (!storeId) return <Alert type="info" showIcon message={tr('Выберите магазин вверху — весы у каждого магазина свои.', 'Yuqorida doʻkonni tanlang — har bir doʻkonning tarozilari oʻzi.')} />

  const linkCell = (d: ScaleDevice) => {
    if (!d.direct) {
      return (
        <>
          <div>—</div>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('файл грузится в программе весов', 'fayl tarozi dasturida yuklanadi')}
          </Typography.Text>
        </>
      )
    }
    const checking = d.job?.kind === 'check' && (d.job.status === 'pending' || d.job.status === 'running')
    const ok = d.check_ok !== false && d.device_online
    return (
      <div style={{ maxWidth: 230 }}>
        <div>
          <Dot ok={ok} />
          {d.device_name ?? tr('Любая касса', 'Istalgan kassa')}
        </div>
        <Typography.Text type={ok ? 'secondary' : 'danger'} style={{ fontSize: 12 }}>
          {checking
            ? tr('проверяет связь…', 'aloqani tekshirmoqda…')
            : !d.device_online
              ? tr('касса не в сети — включите её', 'kassa tarmoqda emas — uni yoqing')
              : d.check_ok === false
                ? (d.check_error ?? tr('не видит весы', 'tarozini koʻrmayapti'))
                : d.check_ok
                  ? tr('видит весы', 'tarozini koʻradi')
                  : tr('связь ещё не проверяли', 'aloqa hali tekshirilmagan')}
        </Typography.Text>
      </div>
    )
  }

  return (
    <Card style={{ marginBottom: 16 }}>
      <Space align="start" style={{ width: '100%', justifyContent: 'space-between', marginBottom: 12 }} wrap>
        <div>
          <Typography.Text strong style={{ fontSize: 16 }}>
            {tr('Весы в магазине', 'Doʻkondagi tarozilar')}
          </Typography.Text>
          <div>
            <Typography.Text type="secondary">{tr('Товары уходят в весы через кассу Super Market — она стоит в той же сети, что и весы.', 'Mahsulotlar taroziga Super Market kassasi orqali yuboriladi — u tarozi bilan bitta tarmoqda turadi.')}</Typography.Text>
          </div>
        </div>
        {!readOnly && (
          <Button icon={<PlusOutlined />} onClick={() => setEdit('new')}>
            {tr('Добавить весы', 'Tarozi qoʻshish')}
          </Button>
        )}
      </Space>
      <Table<ScaleDevice>
        rowKey="id"
        size="middle"
        loading={list.isLoading}
        dataSource={items}
        pagination={false}
        scroll={{ x: true }}
        locale={{ emptyText: tr('Весов пока нет. «Добавить весы» — и товары можно будет отправлять в них одной кнопкой.', 'Hozircha tarozi yoʻq. «Tarozi qoʻshish» — va mahsulotlarni ularga bitta tugma bilan yuborish mumkin boʻladi.') }}
        columns={[
          {
            title: tr('Весы', 'Tarozi'),
            key: 'name',
            render: (_, d) => (
              <div style={{ minWidth: 170 }}>
                <Typography.Text strong>{d.name}</Typography.Text>
                <div>
                  <Typography.Text type="secondary" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                    {[brandName(d.brand) + (d.model ? ' ' + d.model : ''), d.host].filter(Boolean).join(' · ')}
                  </Typography.Text>
                </div>
              </div>
            ),
          },
          { title: tr('Как загружаются', 'Qanday yuklanadi'), key: 'how', render: (_, d) => <HowTag direct={d.direct} /> },
          { title: tr('Через кассу', 'Kassa orqali'), key: 'pos', render: (_, d) => linkCell(d) },
          {
            title: tr('Последняя отправка', 'Oxirgi yuborish'),
            key: 'last',
            render: (_, d) => (
              <>
                <div>{d.last_sent_at ? dateTime(d.last_sent_at) : '—'}</div>
                <Typography.Text type={d.to_send > 0 ? 'warning' : 'secondary'} style={{ fontSize: 12 }}>
                  {d.to_send > 0 ? tr(`${goods(d.to_send)} ждут отправки`, `${d.to_send} ta mahsulot yuborilishini kutmoqda`) : tr(`${goods(d.items)} в весах`, `tarozida ${d.items} ta mahsulot`)}
                </Typography.Text>
              </>
            ),
          },
          {
            title: '',
            key: 'act',
            align: 'right',
            render: (_, d) => (
              <Space>
                {d.direct
                  ? canSend && (
                      <Button type="primary" style={{ background: '#0F1729' }} icon={<UploadOutlined />} onClick={() => setSend([d.id])}>
                        {tr('Отправить', 'Yuborish')}
                      </Button>
                    )
                  : (
                      <Button icon={<DownloadOutlined />} onClick={() => setFile(d)}>
                        {tr('Скачать', 'Yuklab olish')}
                      </Button>
                    )}
                {!readOnly && (
                  <Dropdown
                    trigger={['click']}
                    menu={{
                      items: [
                        { key: 'edit', label: tr('Изменить', 'Oʻzgartirish') },
                        ...(d.direct ? [{ key: 'check', label: tr('Проверить связь', 'Aloqani tekshirish') }] : []),
                        { key: 'delete', danger: true, label: tr('Удалить', 'Oʻchirish') },
                      ],
                      onClick: ({ key }) => {
                        if (key === 'edit') setEdit(d)
                        if (key === 'check') check.mutate(d.id)
                        if (key === 'delete')
                          modal.confirm({
                            title: tr(`Удалить «${d.name}»?`, `«${d.name}» oʻchirilsinmi?`),
                            content: tr('Товары в самих весах останутся. Super Market перестанет отправлять в них товары.', 'Tarozining oʻzidagi mahsulotlar qoladi. Super Market ularga mahsulot yubormaydi.'),
                            okText: tr('Удалить', 'Oʻchirish'),
                            okButtonProps: { danger: true },
                            cancelText: tr('Отмена', 'Bekor qilish'),
                            onOk: () => remove.mutateAsync(d.id),
                          })
                      },
                    }}
                  >
                    <Button type="text" icon={<MoreOutlined />} />
                  </Dropdown>
                )}
              </Space>
            ),
          },
        ]}
      />
      <ScaleDeviceModal value={edit} onClose={() => setEdit(null)} />
      <SendToScalesModal open={send !== null} preselect={send ?? undefined} onClose={() => setSend(null)} onFile={(d) => setFile(d)} />
      <ScaleFileModal scale={file} onClose={() => setFile(null)} />
    </Card>
  )
}

// --------------------------------------------------- Н2: добавить весы

type DeviceForm = { name: string; brand: string; model: string; host: string; port: number; device_id: string | null }

function ScaleDeviceModal({ value, onClose }: { value: ScaleDevice | 'new' | null; onClose: () => void }) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [form] = Form.useForm<DeviceForm>()
  const brand = Form.useWatch('brand', form) ?? 'rongta'
  const direct = BRANDS.find((b) => b.value === brand)?.direct ?? false
  const posList = useList<PosDevice>(value !== null && storeId ? '/store/pos/devices' : null, { store_id: storeId })
  const [checkJob, setCheckJob] = useState<ScaleJob | null>(null)
  const editing = value !== null && value !== 'new' ? value : null

  useEffect(() => {
    if (value === null) return
    setCheckJob(null)
    form.resetFields()
    form.setFieldsValue(
      editing
        ? { name: editing.name, brand: editing.brand, model: editing.model, host: editing.host, port: editing.port, device_id: editing.device_id }
        : { name: '', brand: 'rongta', model: '', host: '', port: 4001, device_id: null },
    )
  }, [value]) // eslint-disable-line react-hooks/exhaustive-deps

  // Ждём ответ кассы о проверке связи.
  useEffect(() => {
    if (!checkJob || checkJob.status === 'done' || checkJob.status === 'failed' || !storeId) return
    const t = setTimeout(async () => {
      try {
        const r = await api.get<{ items: ScaleJob[] }>('/store/scales/jobs', { store_id: storeId, ids: checkJob.id })
        if (r.items[0]) setCheckJob(r.items[0])
      } catch {
        // повторим
      }
    }, 2000)
    return () => clearTimeout(t)
  }, [checkJob, storeId])

  const save = useAction(
    async (v: DeviceForm) => {
      const body = { ...v, store_id: storeId, host: v.host ?? '', model: v.model ?? '', port: v.port ?? 4001 }
      return editing ? api.put<ScaleDevice>(`${DEVICES}/${editing.id}`, body) : api.post<ScaleDevice>(DEVICES, body)
    },
    { invalidate: [[DEVICES], [SCALES], [COUNTS]] },
  )

  const submit = async (andCheck: boolean) => {
    const v = await form.validateFields()
    const d = await save.mutateAsync(v)
    if (andCheck && d.direct) {
      try {
        setCheckJob(await api.post<ScaleJob>(`${DEVICES}/${d.id}/check`))
        qc.invalidateQueries({ queryKey: [DEVICES] })
      } catch (e) {
        message.error(errorText(e))
      }
      return
    }
    message.success(tr('Весы сохранены', 'Tarozi saqlandi'))
    onClose()
  }

  const posOptions = [
    { value: '', label: tr('Любая касса магазина', 'Doʻkonning istalgan kassasi') },
    ...(posList.data ?? [])
      .filter((d) => d.kind === 'pos' && d.status === 'active')
      .map((d) => ({ value: d.id, label: `${d.name}${d.online ? '' : tr(' · не в сети', ' · tarmoqda emas')}` })),
  ]

  const waiting = checkJob && (checkJob.status === 'pending' || checkJob.status === 'running')
  const waitedLong = checkJob && waiting && Date.now() - new Date(checkJob.created_at).getTime() > 25000

  return (
    <Modal
      open={value !== null}
      onCancel={onClose}
      width={640}
      title={editing ? tr('Весы', 'Tarozi') : tr('Добавить весы', 'Tarozi qoʻshish')}
      destroyOnHidden
      footer={
        checkJob
          ? [
              <Button key="ok" type="primary" onClick={onClose}>
                {tr('Готово', 'Tayyor')}
              </Button>,
            ]
          : [
              <Button key="c" onClick={onClose}>
                {tr('Отмена', 'Bekor qilish')}
              </Button>,
              <Button key="s" type="primary" loading={save.isPending} onClick={() => submit(direct)}>
                {direct ? tr('Сохранить и проверить связь', 'Saqlash va aloqani tekshirish') : tr('Сохранить', 'Saqlash')}
              </Button>,
            ]
      }
    >
      <Form form={form} layout="vertical" disabled={!!checkJob}>
        <Form.Item name="name" label={tr('Название', 'Nomi')} extra={tr('Как вы их называете в магазине', 'Doʻkonda ularni qanday ataysiz')} rules={[{ required: true, max: 60, message: tr('Название весов', 'Tarozi nomi') }]}>
          <Input placeholder={tr('Весы у фруктов', 'Mevalar yonidagi tarozi')} />
        </Form.Item>
        <Form.Item name="brand" label={tr('Бренд весов', 'Tarozi brendi')} extra={tr('«Напрямую» — Super Market сам отправляет товары в весы. Остальные бренды — через файл для программы весов.', '«Toʻgʻridan-toʻgʻri» — Super Market mahsulotlarni taroziga oʻzi yuboradi. Boshqa brendlar — tarozi dasturi uchun fayl orqali.')}>
          <Radio.Group style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(170px, 1fr))', gap: 8 }}>
            {BRANDS.map((b) => (
              <Radio.Button key={b.value} value={b.value} style={{ height: 'auto', padding: '8px 12px', borderRadius: 10, lineHeight: 1.4 }}>
                <div style={{ fontWeight: 700 }}>{b.label()}</div>
                <div style={{ fontSize: 12, opacity: 0.8 }}>{b.direct ? tr('Напрямую', 'Toʻgʻridan-toʻgʻri') : tr('Через файл', 'Fayl orqali')}</div>
              </Radio.Button>
            ))}
          </Radio.Group>
        </Form.Item>
        <Row gutter={12}>
          <Col xs={24} sm={direct ? 9 : 24}>
            <Form.Item name="model" label={tr('Модель (необязательно)', 'Model (ixtiyoriy)')}>
              <Input placeholder="RLS1000C" maxLength={40} />
            </Form.Item>
          </Col>
          {direct && (
            <Col xs={16} sm={10}>
              <Form.Item
                name="host"
                label={tr('IP-адрес весов', 'Tarozining IP-manzili')}
                extra={tr('Весы показывают его при включении', 'Tarozi yoqilganda uni koʻrsatadi')}
                rules={[{ required: true, pattern: /^(\d{1,3}\.){3}\d{1,3}$/, message: tr('Например 192.168.1.80', 'Masalan 192.168.1.80') }]}
              >
                <Input placeholder="192.168.1.80" />
              </Form.Item>
            </Col>
          )}
          {direct && (
            <Col xs={8} sm={5}>
              <Form.Item name="port" label={tr('Порт', 'Port')}>
                <InputNumber min={1} max={65535} style={{ width: '100%' }} />
              </Form.Item>
            </Col>
          )}
        </Row>
        {direct && (
          <Form.Item
            name="device_id"
            label={tr('Через какую кассу отправлять', 'Qaysi kassa orqali yuborish')}
            extra={tr('Касса Super Market, подключённая к той же сети (роутеру или кабелем), что и весы', 'Tarozi bilan bitta tarmoqqa (router yoki kabel orqali) ulangan Super Market kassasi')}
            getValueProps={(v) => ({ value: v ?? '' })}
            normalize={(v) => (v === '' ? null : v)}
          >
            <Select options={posOptions} loading={posList.isLoading} />
          </Form.Item>
        )}
      </Form>
      {checkJob && (
        <Alert
          showIcon
          type={checkJob.status === 'done' ? 'success' : checkJob.status === 'failed' ? 'error' : waitedLong ? 'warning' : 'info'}
          icon={checkJob.status === 'done' ? <CheckCircleFilled /> : checkJob.status === 'failed' ? <CloseCircleFilled /> : <WifiOutlined />}
          message={
            checkJob.status === 'done'
              ? tr('Касса видит весы — товары можно отправлять', 'Kassa tarozini koʻradi — mahsulotlarni yuborish mumkin')
              : checkJob.status === 'failed'
                ? (checkJob.error ?? tr('Касса не видит весы', 'Kassa tarozini koʻrmayapti'))
                : waitedLong
                  ? tr('Касса пока не ответила. Она должна быть включена, в сети и обновлена до последней версии.', 'Kassa hali javob bermadi. U yoqilgan, tarmoqda va oxirgi versiyaga yangilangan boʻlishi kerak.')
                  : tr('Касса проверяет связь с весами…', 'Kassa tarozi bilan aloqani tekshirmoqda…')
          }
        />
      )}
    </Modal>
  )
}

// ------------------------------------ Н3 + Н4: отправить в весы и итог

export function SendToScalesModal({
  open,
  preselect,
  onClose,
  onFile,
}: {
  open: boolean
  preselect?: string[]
  onClose: () => void
  onFile: (d: ScaleDevice) => void
}) {
  const { storeId } = useStore()
  const qc = useQueryClient()
  const list = useScaleDevices(open ? storeId : undefined)
  const devices = list.data ?? []
  const [picked, setPicked] = useState<string[]>([])
  const [mode, setMode] = useState<'changed' | 'all'>('changed')
  const [jobs, setJobs] = useState<ScaleJob[] | null>(null)
  const [allCount, setAllCount] = useState<number | null>(null)

  useEffect(() => {
    if (!open) return
    setJobs(null)
    setMode('changed')
    setAllCount(null)
  }, [open])
  useEffect(() => {
    if (!open || !list.data) return
    const direct = list.data.filter((d) => d.direct).map((d) => d.id)
    setPicked(preselect?.length ? preselect.filter((id) => direct.includes(id)) : direct)
  }, [open, list.data]) // eslint-disable-line react-hooks/exhaustive-deps
  // «Все весовые» — сколько всего товаров с номером (берём из файла «все» первых весов).
  useEffect(() => {
    if (!open || !devices.length || allCount !== null) return
    api
      .get<{ items: FileRow[] }>(`${DEVICES}/${devices[0].id}/file`, { mode: 'all' })
      .then((r) => setAllCount(r.items.length))
      .catch(() => setAllCount(0))
  }, [open, devices, allCount])

  const changed = Math.max(0, ...devices.filter((d) => picked.includes(d.id)).map((d) => d.to_send))
  const send = useAction((v: { ids: string[]; mode: string }) => api.post<{ items: ScaleJob[] }>('/store/scales/send', { store_id: storeId, scale_ids: v.ids, mode: v.mode }), {
    invalidate: [[DEVICES]],
  })

  // Итог: ждём, пока касса выполнит задания.
  useEffect(() => {
    if (!jobs || !storeId || jobs.every((j) => j.status === 'done' || j.status === 'failed')) {
      if (jobs) {
        qc.invalidateQueries({ queryKey: [SCALES] })
        qc.invalidateQueries({ queryKey: [COUNTS] })
        qc.invalidateQueries({ queryKey: [DEVICES] })
      }
      return
    }
    const t = setTimeout(async () => {
      try {
        const r = await api.get<{ items: ScaleJob[] }>('/store/scales/jobs', { store_id: storeId, ids: jobs.map((j) => j.id).join(',') })
        setJobs(r.items)
      } catch {
        // повторим
      }
    }, 2000)
    return () => clearTimeout(t)
  }, [jobs, storeId, qc])

  const start = async (ids: string[]) => {
    const r = await send.mutateAsync({ ids, mode })
    setJobs((prev) => {
      if (!prev) return r.items
      const byScale = new Map(r.items.map((j) => [j.scale_id, j]))
      return prev.map((j) => byScale.get(j.scale_id) ?? j)
    })
  }

  const fileScales = devices.filter((d) => !d.direct)

  if (jobs) {
    return (
      <Modal
        open={open}
        onCancel={onClose}
        width={640}
        title={tr('Отправка в весы', 'Taroziga yuborish')}
        footer={
          <Button type="primary" style={{ background: '#0F1729' }} onClick={onClose}>
            {tr('Готово', 'Tayyor')}
          </Button>
        }
      >
        <Space direction="vertical" style={{ width: '100%' }} size={10}>
          {jobs.map((j) => (
            <JobRow key={j.id} job={j} onRetry={() => start([j.scale_id])} />
          ))}
          {fileScales.map((d) => (
            <Card key={d.id} size="small" style={{ background: '#F9FAFB' }}>
              <Space style={{ width: '100%', justifyContent: 'space-between' }}>
                <Space>
                  <FileTextOutlined style={{ fontSize: 20, color: '#667085' }} />
                  <div>
                    <Typography.Text strong>{d.name}</Typography.Text>
                    <div>
                      <Typography.Text type="secondary">{tr('Эти весы загружаются файлом в программе весов', 'Bu tarozi tarozi dasturida fayl orqali yuklanadi')}</Typography.Text>
                    </div>
                  </div>
                </Space>
                <Button icon={<DownloadOutlined />} onClick={() => onFile(d)}>
                  {tr('Скачать файл', 'Faylni yuklab olish')}
                </Button>
              </Space>
            </Card>
          ))}
          <Alert
            type="warning"
            showIcon
            message={tr(
              'Если касса выключена, отправка подождёт и уйдёт сама, как только касса включится. Статус каждых весов — в Настройки → Весы.',
              'Kassa oʻchiq boʻlsa, yuborish kutadi va kassa yoqilishi bilan oʻzi ketadi. Har bir tarozi holati — Sozlamalar → Tarozi boʻlimida.',
            )}
          />
        </Space>
      </Modal>
    )
  }

  return (
    <Modal
      open={open}
      onCancel={onClose}
      width={640}
      title={tr('Отправить в весы', 'Taroziga yuborish')}
      footer={[
        <Button key="c" onClick={onClose}>
          {tr('Отмена', 'Bekor qilish')}
        </Button>,
        <Button
          key="s"
          type="primary"
          icon={<UploadOutlined />}
          loading={send.isPending}
          disabled={!picked.length || (mode === 'changed' && changed === 0)}
          onClick={() => start(picked)}
        >
          {tr('Отправить', 'Yuborish')} · {mode === 'all' ? (allCount ?? '…') : changed}
        </Button>,
      ]}
    >
      <Typography.Paragraph type="secondary">
        {tr('Каждые весы получают товары через свою кассу — она стоит в одной сети с весами. Обычно это занимает до минуты.', 'Har bir tarozi mahsulotlarni oʻz kassasi orqali oladi — u tarozi bilan bitta tarmoqda turadi. Odatda bir daqiqagacha vaqt oladi.')}
      </Typography.Paragraph>
      {list.isSuccess && devices.length === 0 && (
        <Alert type="info" showIcon message={tr('Весов пока нет — добавьте их в Настройки → Весы.', 'Hozircha tarozi yoʻq — ularni Sozlamalar → Tarozi boʻlimida qoʻshing.')} />
      )}
      <Typography.Text strong>{tr('Куда', 'Qayerga')}</Typography.Text>
      <Space direction="vertical" style={{ width: '100%', margin: '8px 0 16px' }} size={8}>
        {devices.map((d) => {
          const on = picked.includes(d.id)
          return (
            <div
              key={d.id}
              onClick={() => d.direct && setPicked(on ? picked.filter((x) => x !== d.id) : [...picked, d.id])}
              style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 14px', borderRadius: 12, border: '1px solid #EAECF0', cursor: d.direct ? 'pointer' : 'default' }}
            >
              <Checkbox checked={on} disabled={!d.direct} />
              <div style={{ flex: 1 }}>
                <Typography.Text strong type={d.direct ? undefined : 'secondary'}>
                  {d.name}
                </Typography.Text>
                <div>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {d.direct
                      ? `${brandName(d.brand)}${d.model ? ' ' + d.model : ''} · ${tr('через', 'orqali')} ${d.device_name ?? tr('любую кассу', 'istalgan kassa')}${d.device_online ? '' : tr(' (не в сети)', ' (tarmoqda emas)')}`
                      : `${brandName(d.brand)}${d.model ? ' ' + d.model : ''} · ${tr('эти весы загружаются файлом', 'bu tarozi fayl orqali yuklanadi')}`}
                  </Typography.Text>
                </div>
              </div>
              {d.direct ? (
                <HowTag direct />
              ) : (
                <Button
                  type="link"
                  icon={<DownloadOutlined />}
                  onClick={(e) => {
                    e.stopPropagation()
                    onFile(d)
                  }}
                >
                  {tr('Скачать файл', 'Faylni yuklab olish')}
                </Button>
              )}
            </div>
          )
        })}
      </Space>
      <Typography.Text strong>{tr('Что отправить', 'Nimani yuborish')}</Typography.Text>
      <Radio.Group value={mode} onChange={(e) => setMode(e.target.value)} style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 8 }}>
        <Radio.Button value="changed" style={{ height: 'auto', padding: '10px 14px', borderRadius: 12, lineHeight: 1.4 }}>
          <div style={{ fontWeight: 700 }}>{tr(`Изменённые и новые · ${changed}`, `Oʻzgargan va yangi · ${changed}`)}</div>
          <div style={{ fontSize: 12, opacity: 0.8 }}>{tr('Новая цена, новый товар или номер', 'Yangi narx, yangi mahsulot yoki raqam')}</div>
        </Radio.Button>
        <Radio.Button value="all" style={{ height: 'auto', padding: '10px 14px', borderRadius: 12, lineHeight: 1.4 }}>
          <div style={{ fontWeight: 700 }}>{tr(`Все весовые · ${allCount ?? '…'}`, `Barcha tortiladigan · ${allCount ?? '…'}`)}</div>
          <div style={{ fontSize: 12, opacity: 0.8 }}>{tr('Весы очистятся и заполнятся заново — так же, как в Super Market', 'Tarozi tozalanadi va qaytadan toʻldiriladi — Super Marketdagidek')}</div>
        </Radio.Button>
      </Radio.Group>
    </Modal>
  )
}

function JobRow({ job, onRetry }: { job: ScaleJob; onRetry: () => void }) {
  const waiting = job.status === 'pending' || job.status === 'running'
  const long = waiting && Date.now() - new Date(job.created_at).getTime() > 25000
  const color = job.status === 'done' ? (job.failures.length ? '#FFFAEB' : '#ECFDF3') : job.status === 'failed' ? '#FEF3F2' : '#F9FAFB'
  const icon =
    job.status === 'done' ? (
      job.failures.length ? <ExclamationCircleFilled style={{ fontSize: 22, color: '#B54708' }} /> : <CheckCircleFilled style={{ fontSize: 22, color: '#027A48' }} />
    ) : job.status === 'failed' ? (
      <CloseCircleFilled style={{ fontSize: 22, color: '#E11D2A' }} />
    ) : (
      <ReloadOutlined spin style={{ fontSize: 20, color: '#667085' }} />
    )
  let text: string
  if (job.status === 'done') {
    text =
      job.total === 0 && !job.failures.length
        ? tr('Нечего отправлять — в весах всё как в Super Market', 'Yuboradigan narsa yoʻq — tarozida hammasi Super Marketdagidek')
        : tr(`Отправлено ${goods(job.sent)}${job.done_at ? ' · ' + new Date(job.done_at).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }) : ''}`, `${job.sent} ta mahsulot yuborildi`)
  } else if (job.status === 'failed') {
    text = tr(`Не отправлено: ${job.error ?? ''}`, `Yuborilmadi: ${job.error ?? ''}`)
  } else if (long) {
    text = tr('Ждёт кассу: она должна быть включена, в сети и обновлена до последней версии', 'Kassani kutmoqda: u yoqilgan, tarmoqda va oxirgi versiyaga yangilangan boʻlishi kerak')
  } else {
    text = job.status === 'running' ? tr(`Касса отправляет ${goods(job.total)}…`, `Kassa ${job.total} ta mahsulotni yubormoqda…`) : tr('Ждём кассу…', 'Kassani kutyapmiz…')
  }
  return (
    <div style={{ background: color, borderRadius: 12, padding: '12px 14px' }}>
      <Space align="start" style={{ width: '100%', justifyContent: 'space-between' }}>
        <Space align="start">
          {icon}
          <div>
            <Typography.Text strong>{job.scale_name}</Typography.Text>
            <div>
              <Typography.Text type={job.status === 'failed' ? 'danger' : undefined}>{text}</Typography.Text>
            </div>
          </div>
        </Space>
        {job.status === 'failed' && (
          <Button icon={<ReloadOutlined />} onClick={onRetry}>
            {tr('Повторить', 'Qayta urinish')}
          </Button>
        )}
      </Space>
      {job.failures.length > 0 && (
        <div style={{ marginTop: 8, paddingLeft: 32 }}>
          <Typography.Text type="warning">{tr(`Весы не приняли ${goods(job.failures.length)}:`, `Tarozi ${job.failures.length} ta mahsulotni qabul qilmadi:`)}</Typography.Text>
          {job.failures.slice(0, 8).map((f) => (
            <div key={f.product_id} style={{ fontSize: 13 }}>
              №{f.plu} {f.name} — {f.error}
            </div>
          ))}
          {job.failures.length > 8 && <div style={{ fontSize: 13 }}>{tr(`и ещё ${job.failures.length - 8}`, `va yana ${job.failures.length - 8} ta`)}</div>}
        </div>
      )}
    </div>
  )
}

// ----------------------------------------- Н5: файл для программы весов

export function ScaleFileModal({ scale, onClose }: { scale: ScaleDevice | null; onClose: () => void }) {
  const { storeId } = useStore()
  const list = useScaleDevices(scale ? storeId : undefined)
  const [id, setId] = useState<string>('')
  const [format, setFormat] = useState<'xlsx' | 'csv'>('xlsx')
  const [mode, setMode] = useState<'changed' | 'all'>('changed')
  const [rows, setRows] = useState<FileRow[] | null>(null)
  const [counts, setCounts] = useState<{ changed: number; all: number } | null>(null)
  const loaded = useAction((ids: string[]) => api.post(`${DEVICES}/${id}/loaded`, { product_ids: ids }), {
    invalidate: [[DEVICES], [SCALES], [COUNTS]],
    success: tr('Отмечено: загружено в весы', 'Belgilandi: taroziga yuklandi'),
  })

  useEffect(() => {
    if (scale) {
      setId(scale.id)
      setMode(scale.to_send > 0 ? 'changed' : 'all')
    }
  }, [scale])
  useEffect(() => {
    if (!scale || !id) return
    setRows(null)
    Promise.all([api.get<{ items: FileRow[] }>(`${DEVICES}/${id}/file`, { mode: 'changed' }), api.get<{ items: FileRow[] }>(`${DEVICES}/${id}/file`, { mode: 'all' })])
      .then(([c, a]) => {
        setCounts({ changed: c.items.length, all: a.items.length })
        setRows(mode === 'all' ? a.items : c.items)
      })
      .catch(() => setRows([]))
  }, [scale, id, mode])

  const current = list.data?.find((d) => d.id === id) ?? scale
  const download = () => {
    if (!rows || !current) return
    const head = [tr('PLU', 'PLU'), tr('Код в штрихкоде', 'Shtrix-koddagi kod'), tr('Название', 'Nomi'), tr('Цена за кг', '1 kg narxi'), tr('Ед.', 'Birl.')]
    const body = rows.map((r) => [r.plu, r.code, r.name, r.price, r.unit === 'kg' ? tr('кг', 'kg') : r.unit])
    const name = `${current.name.replace(/[\\/:*?"<>|]+/g, ' ').trim() || 'scale'}_${mode === 'all' ? 'all' : 'changed'}`
    if (format === 'xlsx') {
      saveBlob(xlsxBlob([head, ...body], 'PLU'), `${name}.xlsx`)
    } else {
      const esc = (v: unknown) => `"${String(v).replace(/"/g, '""')}"`
      saveBlob(new Blob(['﻿' + [head, ...body].map((r) => r.map(esc).join(';')).join('\r\n')], { type: 'text/csv;charset=utf-8' }), `${name}.csv`)
    }
  }

  const options = useMemo(
    () => (list.data ?? []).map((d) => ({ value: d.id, label: `${d.name} · ${brandName(d.brand)}${d.model ? ' ' + d.model : ''}` })),
    [list.data],
  )

  return (
    <Modal
      open={scale !== null}
      onCancel={onClose}
      width={760}
      title={tr('Файл для программы весов', 'Tarozi dasturi uchun fayl')}
      footer={[
        <Button key="l" icon={<CheckCircleFilled />} disabled={!rows?.length} loading={loaded.isPending} onClick={() => rows && loaded.mutateAsync(rows.map((r) => r.product_id)).then(onClose)}>
          {tr('Загружено в весы', 'Taroziga yuklandi')}
        </Button>,
        <Button key="d" type="primary" icon={<DownloadOutlined />} disabled={!rows?.length} onClick={download}>
          {tr(`Скачать .${format}`, `.${format} yuklab olish`)}
        </Button>,
      ]}
    >
      <Typography.Paragraph type="secondary">
        {tr(
          'Для весов, которым Super Market пока не отправляет напрямую (CAS, Масса-К, Штрих-Принт и другие). В файле — колонки, которые понимают программы весов: номер, код, название, цена за кг, единица.',
          'Super Market hozircha toʻgʻridan-toʻgʻri yubormaydigan tarozilar uchun (CAS, Massa-K, Shtrix-Print va boshqalar). Faylda tarozi dasturlari tushunadigan ustunlar: raqam, kod, nom, 1 kg narxi, birlik.',
        )}
      </Typography.Paragraph>
      <Space wrap size={12} align="end" style={{ marginBottom: 16 }}>
        <div>
          <div style={{ marginBottom: 6 }}>{tr('Весы', 'Tarozi')}</div>
          <Select value={id} onChange={setId} options={options} style={{ minWidth: 260 }} />
        </div>
        <div>
          <div style={{ marginBottom: 6 }}>{tr('Файл', 'Fayl')}</div>
          <Radio.Group optionType="button" value={format} onChange={(e) => setFormat(e.target.value)} options={[{ value: 'xlsx', label: 'Excel .xlsx' }, { value: 'csv', label: 'CSV' }]} />
        </div>
        <div>
          <div style={{ marginBottom: 6 }}>{tr('Товары', 'Mahsulotlar')}</div>
          <Radio.Group
            optionType="button"
            value={mode}
            onChange={(e) => setMode(e.target.value)}
            options={[
              { value: 'changed', label: tr(`Изменённые · ${counts?.changed ?? '…'}`, `Oʻzgargan · ${counts?.changed ?? '…'}`) },
              { value: 'all', label: tr(`Все · ${counts?.all ?? '…'}`, `Hammasi · ${counts?.all ?? '…'}`) },
            ]}
          />
        </div>
      </Space>
      <Table<FileRow>
        rowKey="product_id"
        size="small"
        loading={rows === null}
        dataSource={rows ?? []}
        pagination={{ pageSize: 6, hideOnSinglePage: true, showSizeChanger: false }}
        locale={{ emptyText: mode === 'changed' ? tr('Изменённых нет — в весах всё как в Super Market', 'Oʻzgarganlar yoʻq — tarozida hammasi Super Marketdagidek') : tr('Весовых товаров с номером нет', 'Raqamli tortiladigan mahsulotlar yoʻq') }}
        columns={[
          { title: 'PLU', dataIndex: 'plu', width: 70 },
          { title: tr('Код в штрихкоде', 'Shtrix-koddagi kod'), dataIndex: 'code', width: 130 },
          { title: tr('Название', 'Nomi'), dataIndex: 'name' },
          { title: tr('Цена за кг', '1 kg narxi'), dataIndex: 'price', align: 'right', render: (v: number) => money(v) },
          { title: tr('Ед.', 'Birl.'), dataIndex: 'unit', width: 60, render: () => tr('кг', 'kg') },
        ]}
      />
      <Alert
        style={{ marginTop: 16 }}
        type="info"
        message={tr('Как загрузить', 'Qanday yuklash')}
        description={
          <ol style={{ margin: 0, paddingLeft: 18 }}>
            <li>{tr('Скачайте файл и откройте программу весов на компьютере.', 'Faylni yuklab oling va kompyuterda tarozi dasturini oching.')}</li>
            <li>{tr('В программе: «Импорт» / «Import PLU» → выберите этот файл.', 'Dasturda: «Import» / «Import PLU» → shu faylni tanlang.')}</li>
            <li>{tr('Нажмите в программе «Загрузить в весы», затем здесь — «Загружено в весы».', 'Dasturda «Taroziga yuklash» ni bosing, keyin bu yerda — «Taroziga yuklandi».')}</li>
          </ol>
        }
      />
    </Modal>
  )
}
