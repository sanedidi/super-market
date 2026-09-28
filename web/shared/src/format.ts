import dayjs from 'dayjs'

const nf2 = new Intl.NumberFormat('ru-RU', { minimumFractionDigits: 0, maximumFractionDigits: 2 })
const nf3 = new Intl.NumberFormat('ru-RU', { minimumFractionDigits: 0, maximumFractionDigits: 3 })

/** "15000.00" → "15 000" (сум). Деньги приходят строкой — считаем на сервере. */
export function money(v: string | number | null | undefined, suffix = ''): string {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  if (Number.isNaN(n)) return String(v)
  return nf2.format(n) + (suffix ? ' ' + suffix : '')
}

export function qty(v: string | number | null | undefined, unit = ''): string {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  if (Number.isNaN(n)) return String(v)
  return nf3.format(n) + (unit ? ' ' + unit : '')
}

export function dateTime(v: string | null | undefined): string {
  return v ? dayjs(v).format('DD.MM.YYYY HH:mm') : '—'
}

export function date(v: string | null | undefined): string {
  return v ? dayjs(v).format('DD.MM.YYYY') : '—'
}

/** Период для ?from=&to= (to не включается, поэтому +1 день). */
export function periodParams(range: [dayjs.Dayjs, dayjs.Dayjs] | null | undefined) {
  if (!range) return {}
  return { from: range[0].format('YYYY-MM-DD'), to: range[1].add(1, 'day').format('YYYY-MM-DD') }
}
