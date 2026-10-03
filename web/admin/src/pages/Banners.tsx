// Баннеры на главной приложения покупателя.
import { App, Button, DatePicker, Form, Input, InputNumber, Modal, Segmented, Select, Space, Switch, Tag, Typography } from 'antd'
import dayjs, { type Dayjs } from 'dayjs'
import { useState } from 'react'
import { ActiveTag, BannerUpload, CrudPage, RemoteSelect, api, dateTime, useAction } from '@sm/shared'
import { SearchSelect } from '../components'
import { useUrlState } from '../hooks'

interface Banner {
  id: string
  title: string
  subtitle: string
  image_url: string
  color: string
  link_type: 'none' | 'promotion' | 'category' | 'product' | 'store'
  link_id: string | null
  network_id: string | null
  network_name: string | null
  starts_at: string | null
  ends_at: string | null
  sort: number
  is_active: boolean
  show_text: boolean
  owner: 'platform' | 'network'
  moderation: 'pending' | 'approved' | 'rejected'
  reject_reason: string
  created_at: string
}

/** Баннер сети: принять или отклонить с причиной (сеть её увидит). */
function Moderate({ b }: { b: Banner }) {
  const { modal } = App.useApp()
  const [reason, setReason] = useState('')
  const [open, setOpen] = useState(false)
  const approve = useAction(() => api.post(`/admin/banners/${b.id}/approve`), { success: 'Баннер принят' })
  const reject = useAction(() => api.post(`/admin/banners/${b.id}/reject`, { reason }), { success: 'Баннер отклонён' })
  return (
    <Space>
      <Button
        size="small"
        type="primary"
        disabled={b.moderation === 'approved'}
        loading={approve.isPending}
        onClick={() => modal.confirm({ title: 'Принять баннер?', content: 'Он появится в приложении у магазинов сети.', okText: 'Принять', cancelText: 'Отмена', onOk: () => approve.mutateAsync(undefined) })}
      >
        Принять
      </Button>
      <Button size="small" danger disabled={b.moderation === 'rejected'} onClick={() => setOpen(true)}>
        Отклонить
      </Button>
      <Modal
        open={open}
        title="Отклонить баннер"
        okText="Отклонить"
        okButtonProps={{ danger: true, disabled: !reason.trim() }}
        confirmLoading={reject.isPending}
        onCancel={() => setOpen(false)}
        onOk={() => reject.mutate(undefined, { onSuccess: () => setOpen(false) })}
      >
        <Input.TextArea value={reason} onChange={(e) => setReason(e.target.value)} rows={3} placeholder="Причина — сеть увидит её в панели, например: текст нечитаем на фото" />
      </Modal>
    </Space>
  )
}

const MODERATION: Record<Banner['moderation'], { color: string; label: string }> = {
  pending: { color: 'gold', label: 'На модерации' },
  approved: { color: 'green', label: 'Принят' },
  rejected: { color: 'red', label: 'Отклонён' },
}

const LINKS = [
  { value: 'none', label: 'Никуда' },
  { value: 'category', label: 'Категория' },
  { value: 'product', label: 'Товар' },
  { value: 'store', label: 'Магазин' },
  { value: 'promotion', label: 'Акция' },
]

export function Banners() {
  const [moderation, setModeration] = useUrlState('moderation')
  return (
    <CrudPage<Banner>
      key={moderation ?? 'all'}
      title="Баннеры в приложении"
      path="/admin/banners"
      canDelete
      rowName={(r) => r.title}
      params={{ moderation }}
      toolbar={
        <Segmented
          value={moderation ?? ''}
          onChange={(v) => setModeration(v as string)}
          options={[
            { value: '', label: 'Все' },
            { value: 'pending', label: 'На модерации' },
            { value: 'rejected', label: 'Отклонённые' },
          ]}
        />
      }
      createLabel="Новый баннер"
      columns={[
        {
          title: 'Баннер',
          render: (_, b) => (
            <Space>
              {b.image_url ? (
                <img src={b.image_url} alt="" style={{ width: 72, height: 30, objectFit: 'cover', borderRadius: 6 }} />
              ) : (
                <span style={{ display: 'inline-block', width: 28, height: 28, borderRadius: 6, background: b.color }} />
              )}
              <span>
                {b.title}
                <br />
                <Typography.Text type="secondary">{b.subtitle}</Typography.Text>
              </span>
            </Space>
          ),
        },
        { title: 'Ведёт', dataIndex: 'link_type', render: (v: string) => LINKS.find((l) => l.value === v)?.label },
        { title: 'Для кого', dataIndex: 'network_id', render: (v: string | null, b) => (v ? <Tag>{b.network_name ?? 'Сеть'}</Tag> : <Tag color="blue">Все</Tag>) },
        {
          title: 'Показ',
          render: (_, b) =>
            b.starts_at || b.ends_at ? `${b.starts_at ? dateTime(b.starts_at) : '…'} — ${b.ends_at ? dateTime(b.ends_at) : '…'}` : 'Всегда',
        },
        { title: 'Порядок', dataIndex: 'sort', align: 'right' },
        { title: 'Статус', dataIndex: 'is_active', render: (v: boolean) => <ActiveTag active={v} /> },
        {
          title: 'Модерация',
          render: (_, b) =>
            b.owner === 'network' ? (
              <Space direction="vertical" size={4}>
                <Tag color={MODERATION[b.moderation].color}>{MODERATION[b.moderation].label}</Tag>
                {b.reject_reason && <Typography.Text type="secondary">{b.reject_reason}</Typography.Text>}
                <Moderate b={b} />
              </Space>
            ) : (
              <Typography.Text type="secondary">Super Market</Typography.Text>
            ),
        },
      ]}
      toForm={(b) => ({
        ...b,
        period: b.starts_at || b.ends_at ? [b.starts_at ? dayjs(b.starts_at) : null, b.ends_at ? dayjs(b.ends_at) : null] : undefined,
        network_id: b.network_id ?? undefined,
        link_id: b.link_id ?? undefined,
      })}
      toBody={(v) => {
        const period = v.period as [Dayjs | null, Dayjs | null] | undefined
        return {
          title: v.title,
          subtitle: v.subtitle ?? '',
          image_url: v.image_url ?? '',
          color: v.color || '#155EEF',
          link_type: v.link_type ?? 'none',
          link_id: v.link_type && v.link_type !== 'none' ? v.link_id : '',
          network_id: v.network_id ?? '',
          // null — снять ограничение (очищенное поле периода).
          starts_at: period?.[0] ? period[0].toISOString() : null,
          ends_at: period?.[1] ? period[1].toISOString() : null,
          sort: v.sort ?? 0,
          is_active: v.is_active ?? true,
          show_text: v.show_text ?? true,
        }
      }}
      form={(editing) => (
        <>
          <Form.Item name="title" label="Заголовок" rules={[{ required: true, message: 'Введите заголовок' }]}>
            <Input placeholder="−20% на молочные продукты" />
          </Form.Item>
          <Form.Item name="subtitle" label="Подзаголовок">
            <Input placeholder="Только до воскресенья" />
          </Form.Item>
          <Form.Item name="image_url" label="Картинка" extra="Необязательно; без картинки баннер — цветная плашка">
            <BannerUpload hint="Картинка баннера" />
          </Form.Item>
          <Form.Item name="show_text" label="Подпись на фото" valuePropName="checked" initialValue={true} extra="Выключите, если текст уже нарисован на картинке">
            <Switch />
          </Form.Item>
          <Form.Item name="color" label="Цвет фона" initialValue="#155EEF" rules={[{ pattern: /^#[0-9A-Fa-f]{6}$/, message: 'Формат #RRGGBB' }]}>
            <Input style={{ width: 140 }} />
          </Form.Item>
          <Space wrap align="start">
            <Form.Item name="link_type" label="Куда ведёт" initialValue="none">
              <Select options={LINKS} style={{ width: 160 }} />
            </Form.Item>
            <Form.Item noStyle shouldUpdate={(a, b) => a.link_type !== b.link_type}>
              {({ getFieldValue }) => {
                const t = getFieldValue('link_type')
                if (!t || t === 'none') return null
                return (
                  <Form.Item name="link_id" label="Что открыть" rules={[{ required: true, message: 'Выберите' }]}>
                    {t === 'category' ? (
                      <RemoteSelect path="/admin/catalog/categories" style={{ width: 260 }} />
                    ) : (
                      <Input placeholder="ID (uuid)" style={{ width: 300 }} />
                    )}
                  </Form.Item>
                )
              }}
            </Form.Item>
          </Space>
          <Form.Item name="network_id" label="Показывать" extra="Пусто — всем покупателям; сеть — только рядом с её магазинами">
            <SearchSelect path="/admin/networks" known={{ id: editing?.network_id, label: editing?.network_name }} allowClear placeholder="Всем" />
          </Form.Item>
          <Form.Item name="period" label="Период показа" extra="Пусто — всегда">
            <DatePicker.RangePicker showTime={{ format: 'HH:mm' }} format="DD.MM.YYYY HH:mm" allowEmpty={[true, true]} />
          </Form.Item>
          <Space wrap>
            <Form.Item name="sort" label="Порядок" initialValue={0}>
              <InputNumber precision={0} style={{ width: 100 }} />
            </Form.Item>
            <Form.Item name="is_active" label="Показывать" valuePropName="checked" initialValue={true}>
              <Switch />
            </Form.Item>
          </Space>
        </>
      )}
    />
  )
}
