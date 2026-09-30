import { useState, type ComponentProps, type ReactNode } from 'react'
import { RemoteSelect } from '@sm/shared'

type Props = Omit<ComponentProps<typeof RemoteSelect>, 'search' | 'selectedLabel'> & {
  /** Значение, сохранённое в записи, и его подпись. */
  known?: { id: string | null | undefined; label: ReactNode }
}

/**
 * Выбор с поиском на сервере. Запоминает подпись выбранного варианта,
 * чтобы после нового поиска вместо названия не показывался id, и берёт
 * подпись сохранённого значения из known, пока выбрано именно оно.
 */
export function SearchSelect({ known, onChange, ...props }: Props) {
  const [picked, setPicked] = useState<{ id: string; label: ReactNode } | null>(null)
  const v = props.value
  const label = picked && v === picked.id ? picked.label : known && known.id && v === known.id ? known.label : undefined
  return (
    <RemoteSelect
      search
      selectedLabel={label}
      onChange={(value, option) => {
        const o = Array.isArray(option) ? undefined : option
        if (typeof value === 'string' && o) setPicked({ id: value, label: o.label as ReactNode })
        onChange?.(value, option)
      }}
      {...props}
    />
  )
}
