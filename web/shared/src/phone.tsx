import { Input, type InputProps } from 'antd'
import type { Rule } from 'antd/es/form'
import { tr } from './i18n'

// Номер телефона Узбекистана — одна маска во всей системе: +998 99 999 99 99.
// «+998» стоит всегда, вводятся только 9 цифр, пробелы ставятся сами.

/**
 * 9 цифр после +998 из того, что ввели или вставили. Код страны срезается у значения
 * с «+998» (в т. ч. недописанного «+99890» из формы) и у полного номера «998…» из 12 цифр;
 * иначе цифры «99 8…» в начале местного номера приняли бы за код страны.
 */
export function uzLocalDigits(raw: string | null | undefined): string {
  const s = String(raw ?? '').trim()
  let d = s.replace(/\D/g, '')
  if (s.startsWith('+998') || (d.length >= 12 && d.startsWith('998'))) d = d.slice(3)
  return d.slice(0, 9)
}

/** «901234567» → «90 123 45 67» (по мере ввода — «90 12»). */
export function formatUzLocal(raw: string | null | undefined): string {
  const d = uzLocalDigits(raw)
  let out = ''
  for (let i = 0; i < d.length; i++) {
    if (i === 2 || i === 5 || i === 7) out += ' '
    out += d[i]
  }
  return out
}

/** Номер для сервера: +998XXXXXXXXX; null — неполный. */
export function normalizeUzPhone(raw: string | null | undefined): string | null {
  const d = uzLocalDigits(raw)
  return d.length === 9 ? '+998' + d : null
}

/** Для показа: «+998 90 123 45 67». Чужие номера — как есть. */
export function formatPhone(v: string | null | undefined): string {
  const s = String(v ?? '').trim()
  const d = s.replace(/\D/g, '')
  if (d.length === 12 && d.startsWith('998')) return '+998 ' + formatUzLocal(d.slice(3))
  if (d.length === 9 && !s.startsWith('+')) return '+998 ' + formatUzLocal(d)
  return s
}

type PhoneInputProps = Omit<InputProps, 'value' | 'onChange' | 'prefix'> & {
  /** +998XXXXXXXXX (пока номер не дописан — +998 и часть цифр, пусто — ''). */
  value?: string | null
  onChange?: (value: string) => void
}

/** Поле номера с маской для Form.Item: в форму уходит «+998901234567». */
export function PhoneInput({ value, onChange, ...rest }: PhoneInputProps) {
  return (
    <Input
      {...rest}
      inputMode="tel"
      autoComplete="tel-national"
      placeholder="99 999 99 99"
      prefix={<span style={{ fontWeight: 600, paddingRight: 8, marginRight: 4, borderRight: '1px solid rgba(0,0,0,0.12)' }}>+998</span>}
      value={formatUzLocal(value)}
      onChange={(e) => {
        const d = uzLocalDigits(e.target.value)
        onChange?.(d ? '+998' + d : '')
      }}
    />
  )
}

/** Правило формы: номер полностью (9 цифр после +998); пусто — только если не обязателен. */
export function phoneRule(required = false): Rule {
  return {
    validator: (_, v: string | undefined) => {
      if (!v) return required ? Promise.reject(new Error(tr('Введите номер телефона', 'Telefon raqamini kiriting'))) : Promise.resolve()
      return normalizeUzPhone(v) ? Promise.resolve() : Promise.reject(new Error(tr('Введите номер полностью: 9 цифр после +998', 'Raqamni toʻliq kiriting: +998 dan keyin 9 ta raqam')))
    },
  }
}
