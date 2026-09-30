// Баннеры на главной приложения покупателя.
import { DatePicker, Form, Input, InputNumber, Select, Space, Switch, Tag, Typography } from 'antd'
import dayjs, { type Dayjs } from 'dayjs'
import { ActiveTag, CrudPage, ImageUpload, RemoteSelect, dateTime } from '@sm/shared'
import { SearchSelect } from '../components'

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
  created_at: string
}

const LINKS = [
  { value: 'none', label: 'Никуда' },
  { value: 'category', label: 'Категория' },
  { value: 'product', label: 'Товар' },
  { value: 'store', label: 'Магазин' },
  { value: 'promotion', label: 'Акция' },
]

export function Banners() {
  return (
    <CrudPage<Banner>
      title="Баннеры в приложении"
      path="/admin/banners"
      createLabel="Новый баннер"
      columns={[
        {
          title: 'Баннер',
          render: (_, b) => (
            <Space>
              <span style={{ display: 'inline-block', width: 28, height: 28, borderRadius: 6, background: b.color }} />
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
            <ImageUpload hint="Картинка" />
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
