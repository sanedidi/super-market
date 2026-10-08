import { useState, type ReactNode } from 'react'
import { App as AntApp, Button, Segmented, Tooltip, type FormInstance } from 'antd'
import { TranslationOutlined } from '@ant-design/icons'
import { api, getTokens } from './api'

/**
 * Языки панели магазина: узбекский (латиница, по умолчанию) и русский.
 *
 * Строки пишутся парой: `tr('Сохранить', 'Saqlash')` — русский первым.
 * Панель супер-админа остаётся только на русском: в её сборке __SM_I18N__
 * не задан (см. store/vite.config.ts), и tr() всегда отдаёт русский.
 *
 * Апострофы в узбекском — типографские: oʻ, gʻ (U+02BB) и ʼ (U+02BC).
 */

export type Lang = 'uz' | 'ru'

declare const __SM_I18N__: boolean | undefined

/** Включены ли языки в этой сборке (панель магазина — да, супер-админ — нет). */
export const i18nEnabled: boolean = typeof __SM_I18N__ !== 'undefined' && !!__SM_I18N__

const KEY = 'sm_lang'

function readLang(): Lang {
  if (!i18nEnabled) return 'ru'
  try {
    const v = localStorage.getItem(KEY)
    if (v === 'uz' || v === 'ru') return v
  } catch {
    // нет доступа к хранилищу — язык по умолчанию
  }
  return 'uz'
}

let current: Lang = readLang()

/** Текущий язык интерфейса (для API — заголовок Accept-Language). */
export function getLang(): Lang {
  return current
}

/** Сменить язык: запоминаем и перезагружаем страницу — так все тексты, даты и antd перейдут на новый язык. */
export function setLang(l: Lang) {
  if (!i18nEnabled || l === current) return
  try {
    localStorage.setItem(KEY, l)
  } catch {
    // без хранилища язык продержится до перезагрузки
  }
  current = l
  // Язык уведомлений сотрудника в Telegram — тот же, что в панели. На экране входа (без токена) — только перезагрузка.
  if (!getTokens()) {
    window.location.reload()
    return
  }
  api.put('/me/language', { language: l }).catch(() => undefined).finally(() => window.location.reload())
}

/** Строка на текущем языке: ru — по-русски, uz — по-узбекски (латиница). */
export function tr(ru: string, uz: string): string {
  return current === 'uz' ? uz : ru
}

/** Поле данных на текущем языке: pickLang(row, 'name') → name_uz, если заполнен, иначе name. */
export function pickLang(row: Record<string, unknown> | null | undefined, field: string): string {
  if (!row) return ''
  if (current === 'uz') {
    const uz = row[field + '_uz']
    if (typeof uz === 'string' && uz.trim()) return uz
  }
  const v = row[field]
  return v === null || v === undefined ? '' : String(v)
}

/** Переключатель «UZ | RU» для шапки и экрана входа. В сборке без языков ничего не рисует. */
export function LangSwitch({ size = 'small' }: { size?: 'small' | 'middle' | 'large' }) {
  if (!i18nEnabled) return null
  return (
    <Segmented
      size={size}
      value={current}
      onChange={(v) => setLang(v as Lang)}
      options={[
        { label: 'UZ', value: 'uz' },
        { label: 'RU', value: 'ru' },
      ]}
    />
  )
}

/** POST /translate — машинный перевод через ИИ сервера. */
export async function translateTexts(texts: string[], to: Lang): Promise<string[]> {
  const r = await api.post<{ texts: string[] }>('/translate', { texts, to })
  return r.texts ?? []
}

type NamePath = string | number | (string | number)[]

/**
 * Кнопка «Перевести автоматически» для двуязычного поля формы antd.
 * Берёт текст из поля [from], переводит на язык [to] и пишет в поле [into].
 * Ставится в suffix/addonAfter поля [into]:
 *
 *   <Form.Item name="name_uz" label="Nomi (oʻzbekcha)">
 *     <Input suffix={<FormTranslate form={form} from="name" into="name_uz" to="uz" />} />
 *   </Form.Item>
 */
export function FormTranslate({ form, from, into, to }: { form: FormInstance; from: NamePath; into: NamePath; to: Lang }) {
  return (
    <TranslateButton
      to={to}
      source={() => form.getFieldValue(from)}
      onResult={(text) => {
        form.setFieldValue(into, text)
        form.validateFields([into]).catch(() => undefined)
      }}
    />
  )
}

/** То же без формы: source() — исходный текст, onResult — перевод. */
export function TranslateButton({
  source,
  onResult,
  to,
  children,
}: {
  source: () => string | undefined | null
  onResult: (text: string) => void
  to: Lang
  /** Текст на кнопке; без него — только значок. */
  children?: ReactNode
}) {
  const { message } = AntApp.useApp()
  const [busy, setBusy] = useState(false)
  const run = async () => {
    const text = (source() ?? '').trim()
    if (!text) {
      message.info(
        to === 'uz'
          ? tr('Сначала заполните поле на русском', 'Avval rus tilidagi maydonni toʻldiring')
          : tr('Сначала заполните поле на узбекском', 'Avval oʻzbek tilidagi maydonni toʻldiring'),
      )
      return
    }
    setBusy(true)
    try {
      const [out] = await translateTexts([text], to)
      if (out?.trim()) onResult(out.trim())
    } catch (e) {
      message.error(e instanceof Error ? e.message : tr('Не удалось перевести', 'Tarjima qilib boʻlmadi'))
    } finally {
      setBusy(false)
    }
  }
  return (
    <Tooltip title={tr('Перевести автоматически', 'Avtomatik tarjima qilish')}>
      <Button
        type="text"
        size="small"
        loading={busy}
        icon={<TranslationOutlined />}
        onClick={run}
        aria-label={tr('Перевести автоматически', 'Avtomatik tarjima qilish')}
      >
        {children}
      </Button>
    </Tooltip>
  )
}
