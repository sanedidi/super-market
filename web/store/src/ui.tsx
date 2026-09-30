// Общие элементы страниц панели магазина.
import { useEffect, useState, type ReactNode } from 'react'
import { Alert, DatePicker, InputNumber, Select, Typography, type InputNumberProps, type SelectProps } from 'antd'
import dayjs, { type Dayjs } from 'dayjs'
import { useList, money } from '@sm/shared'
import { useStore } from './ctx'
import type { Product } from './types'

export type Range = [Dayjs, Dayjs]

/** Период: сегодня / с начала месяца. */
export const today = (): Range => [dayjs().startOf('day'), dayjs().startOf('day')]
export const thisMonth = (): Range => [dayjs().startOf('month'), dayjs().startOf('day')]

export function RangeFilter({ value, onChange, allowClear = false }: { value: Range | null; onChange: (r: Range | null) => void; allowClear?: boolean }) {
  return (
    <DatePicker.RangePicker
      value={value}
      format="DD.MM.YYYY"
      allowClear={allowClear}
      onChange={(v) => onChange(v && v[0] && v[1] ? [v[0], v[1]] : null)}
      presets={[
        { label: 'Сегодня', value: today() },
        { label: 'Вчера', value: [dayjs().subtract(1, 'day').startOf('day'), dayjs().subtract(1, 'day').startOf('day')] },
        { label: '7 дней', value: [dayjs().subtract(6, 'day').startOf('day'), dayjs().startOf('day')] },
        { label: 'Этот месяц', value: thisMonth() },
        {
          label: 'Прошлый месяц',
          value: [dayjs().subtract(1, 'month').startOf('month'), dayjs().subtract(1, 'month').endOf('month').startOf('day')],
        },
      ]}
    />
  )
}

/** Число для денег/количества: значение — строка, как в API. */
export function Num(props: InputNumberProps<string>) {
  return <InputNumber<string> stringMode min="0" style={{ width: '100%' }} {...props} />
}

/** Поиск товара по названию или штрихкоду (/store/products?q=). */
export function ProductSelect({
  value,
  label,
  onChange,
  priceTypeId,
  ...props
}: {
  value?: string
  label?: string
  onChange?: (id: string, p: Product | undefined) => void
  priceTypeId?: string
} & Omit<SelectProps, 'value' | 'onChange' | 'options'>) {
  const { storeId } = useStore()
  const [q, setQ] = useState('')
  const [debounced, setDebounced] = useState('')
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q.trim()), 300)
    return () => clearTimeout(t)
  }, [q])
  const { data, isFetching } = useList<Product>('/store/products', {
    q: debounced,
    store_id: storeId || undefined,
    price_type_id: priceTypeId,
    limit: 30,
  })
  const options = (data ?? []).map((p) => ({
    value: p.id,
    label: p.name,
    desc: `${p.unit_short}${p.barcodes?.length ? ' · ' + p.barcodes[0] : ''}${p.price ? ' · ' + money(p.price) : ''}`,
  }))
  if (value && !options.some((o) => o.value === value)) options.unshift({ value, label: label ?? value, desc: '' })
  return (
    <Select
      showSearch
      value={value || undefined}
      placeholder="Название или штрихкод"
      filterOption={false}
      onSearch={setQ}
      loading={isFetching}
      notFoundContent={isFetching ? 'Поиск…' : 'Не найдено'}
      style={{ width: '100%', minWidth: 220 }}
      options={options}
      optionRender={(o) => (
        <div>
          {o.data.label}
          {o.data.desc && (
            <Typography.Text type="secondary" style={{ fontSize: 12, marginLeft: 8 }}>
              {o.data.desc}
            </Typography.Text>
          )}
        </div>
      )}
      onChange={(id: string) => onChange?.(id, data?.find((p) => p.id === id))}
      {...props}
    />
  )
}

/** Сообщение, если у сети ещё нет магазинов. */
export function NeedStore({ children }: { children: ReactNode }) {
  const { storeId, storesLoading } = useStore()
  if (storesLoading) return null
  if (!storeId)
    return (
      <Alert
        type="info"
        showIcon
        message="Магазинов пока нет"
        description="Создайте первый магазин в разделе «Настройки → Магазины»."
      />
    )
  return <>{children}</>
}

/** Названия документов в журналах движений. */
export const docTypeTitles: Record<string, string> = {
  stock_document: 'Складской документ',
  sale: 'Продажа',
  customer_return: 'Возврат покупателя',
  order: 'Онлайн-заказ',
  cash_operation: 'Кассовая операция',
  cash_transfer: 'Перемещение денег',
  payout: 'Вывод',
  counterparty: 'Контрагент',
}

export const kindTitles: Record<string, string> = { income: 'Приход', expense: 'Расход' }

/** Сумма со знаком и цветом. */
export function Signed({ v }: { v: string | number }) {
  const n = Number(v)
  return <Typography.Text type={n < 0 ? 'danger' : n > 0 ? 'success' : undefined}>{(n > 0 ? '+' : '') + money(v)}</Typography.Text>
}

/** Сумма чисел-строк. */
export function sum(values: (string | number | null | undefined)[]) {
  return values.reduce<number>((s, v) => s + (Number(v) || 0), 0)
}

const nf4 = new Intl.NumberFormat('ru-RU', { minimumFractionDigits: 0, maximumFractionDigits: 4 })

/** Цена за единицу: до 4 знаков (себестоимость, цены в USD). */
export function unitPrice(v: string | number | null | undefined, suffix = ''): string {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  if (Number.isNaN(n)) return String(v)
  return nf4.format(n) + (suffix ? ' ' + suffix : '')
}

/** "5000.0000" → "5000", "12.50" → "12.5": API отдаёт лишние знаки, а принимает сумму максимум с 2 знаками. */
export function trimNum(v: string | null | undefined, digits = 2): string | null {
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  if (Number.isNaN(n)) return v
  return String(Number(n.toFixed(digits)))
}
