// Общие элементы страниц панели магазина.
import { useEffect, useState, type ReactNode } from 'react'
import { Alert, App, Button, DatePicker, Divider, InputNumber, Select, Typography, type InputNumberProps, type SelectProps } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import { useQueryClient } from '@tanstack/react-query'
import dayjs, { type Dayjs } from 'dayjs'
import { api, errorText, useList, money, tr } from '@sm/shared'
import { useStore } from './ctx'
import type { Counterparty, Product } from './types'

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
        { label: tr('Сегодня', 'Bugun'), value: today() },
        { label: tr('Вчера', 'Kecha'), value: [dayjs().subtract(1, 'day').startOf('day'), dayjs().subtract(1, 'day').startOf('day')] },
        { label: tr('7 дней', '7 kun'), value: [dayjs().subtract(6, 'day').startOf('day'), dayjs().startOf('day')] },
        { label: tr('Этот месяц', 'Shu oy'), value: thisMonth() },
        {
          label: tr('Прошлый месяц', 'Oʻtgan oy'),
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

/**
 * Поиск товара по названию или штрихкоду (/store/products?q=). Только товары
 * магазина («Мои товары»); всю центральную базу — с [all] (там, где товар
 * как раз добавляют в магазин, например в «Начале работы»).
 */
export function ProductSelect({
  value,
  label,
  onChange,
  priceTypeId,
  all,
  ...props
}: {
  value?: string
  label?: string
  onChange?: (id: string, p: Product | undefined) => void
  priceTypeId?: string
  all?: boolean
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
    scope: all ? undefined : 'mine',
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
      placeholder={tr('Название или штрихкод', 'Nomi yoki shtrix-kod')}
      filterOption={false}
      onSearch={setQ}
      loading={isFetching}
      notFoundContent={isFetching ? tr('Поиск…', 'Qidirilmoqda…') : tr('Не найдено', 'Topilmadi')}
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
        message={tr('Магазинов пока нет', 'Hozircha doʻkonlar yoʻq')}
        description={tr('Создайте первый магазин в разделе «Настройки → Магазины».', 'Birinchi doʻkonni «Sozlamalar → Doʻkonlar» boʻlimida yarating.')}
      />
    )
  return <>{children}</>
}

/** Названия документов в журналах движений. */
export const docTypeTitles: Record<string, string> = {
  stock_document: tr('Складской документ', 'Ombor hujjati'),
  sale: tr('Продажа', 'Sotuv'),
  customer_return: tr('Возврат покупателя', 'Xaridor qaytarishi'),
  order: tr('Онлайн-заказ', 'Onlayn buyurtma'),
  cash_operation: tr('Кассовая операция', 'Kassa operatsiyasi'),
  cash_transfer: tr('Перемещение денег', 'Pul koʻchirish'),
  payout: tr('Вывод', 'Pul yechib olish'),
  counterparty: tr('Контрагент', 'Kontragent'),
}

export const kindTitles: Record<string, string> = { income: tr('Приход', 'Kirim'), expense: tr('Расход', 'Chiqim') }

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

/**
 * Выбор поставщика (контрагента) с поиском на сервере и «Добавить «…»» прямо
 * в списке: набрали название, которого нет, — поставщик заводится и сразу выбран.
 */
export function CounterpartySelect({
  value,
  onChange,
  selectedLabel,
  label,
  filter,
  ...props
}: {
  value?: string
  onChange?: (id: string, c?: Counterparty) => void
  selectedLabel?: ReactNode
  label?: (c: Counterparty) => ReactNode
  filter?: (c: Counterparty) => boolean
} & Omit<SelectProps, 'value' | 'onChange' | 'options'>) {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const [q, setQ] = useState('')
  const [debounced, setDebounced] = useState('')
  const [busy, setBusy] = useState(false)
  const [created, setCreated] = useState<Counterparty | null>(null)
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q.trim()), 300)
    return () => clearTimeout(t)
  }, [q])
  const { data, isFetching } = useList<Counterparty>('/store/finance/counterparties', { q: debounced || undefined, limit: 50 })
  const items = (data ?? []).filter((c) => (filter ? filter(c) : c.is_active || c.id === value))
  const options = items.map((c) => ({ value: c.id, label: label ? label(c) : c.name }))
  if (value && !options.some((o) => o.value === value)) {
    options.unshift({ value, label: created?.id === value ? created.name : (selectedLabel ?? value) })
  }
  const name = q.trim()
  const exact = items.some((c) => c.name.trim().toLowerCase() === name.toLowerCase())
  const add = async () => {
    if (!name) return
    setBusy(true)
    try {
      const c = await api.post<Counterparty>('/store/finance/counterparties', { name })
      setCreated(c)
      setQ('')
      void qc.invalidateQueries({ queryKey: ['/store/finance/counterparties'] })
      onChange?.(c.id, c)
      message.success(tr(`Поставщик «${c.name}» добавлен`, `«${c.name}» yetkazib beruvchisi qoʻshildi`))
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <Select
      showSearch
      value={value || undefined}
      filterOption={false}
      searchValue={q}
      onSearch={setQ}
      loading={isFetching || busy}
      options={options as SelectProps['options']}
      onChange={(id: string) => onChange?.(id, items.find((c) => c.id === id))}
      style={{ minWidth: 200 }}
      popupRender={(menu) => (
        <>
          {menu}
          <Divider style={{ margin: '6px 0' }} />
          {name && !exact ? (
            <Button type="link" icon={<PlusOutlined />} loading={busy} onClick={add} style={{ width: '100%', textAlign: 'left' }}>
              {tr(`Добавить «${name}» — новый поставщик`, `«${name}» — yangi yetkazib beruvchi qoʻshish`)}
            </Button>
          ) : (
            <Typography.Text type="secondary" style={{ display: 'block', padding: '4px 12px' }}>
              {tr('Нет нужного — наберите название и добавьте', 'Kerakli yoʻq — nomini yozing va qoʻshing')}
            </Typography.Text>
          )}
        </>
      )}
      {...props}
    />
  )
}
