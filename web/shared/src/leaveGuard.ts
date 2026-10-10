// «Уйти без сохранения?»: страница с несохранёнными изменениями ставит
// охрану, а меню и вкладки оболочки спрашивают перед переходом. Закрытие
// вкладки браузера — стандартный вопрос браузера (beforeunload).
import { useEffect, useRef } from 'react'
import { App } from 'antd'
import { tr } from './i18n'

let isDirty: (() => boolean) | null = null
let ask: ((proceed: () => void) => void) | null = null

/** Перейти, а если на странице есть несохранённое — сначала спросить. */
export function guardedNavigate(go: () => void) {
  if (isDirty?.() && ask) ask(go)
  else go()
}

/** Охрана страницы, пока dirty; возвращает переход с вопросом. */
export function useLeaveGuard(dirty: boolean, what = tr('Изменения не сохранены.', 'Oʻzgarishlar saqlanmagan.')) {
  const { modal } = App.useApp()
  const ref = useRef(dirty)
  ref.current = dirty

  useEffect(() => {
    const check = () => ref.current
    const confirm = (proceed: () => void) =>
      modal.confirm({
        title: tr('Уйти без сохранения?', 'Saqlamasdan chiqilsinmi?'),
        content: what,
        okText: tr('Уйти', 'Chiqish'),
        cancelText: tr('Остаться', 'Qolish'),
        okButtonProps: { danger: true },
        onOk: proceed,
      })
    isDirty = check
    ask = confirm
    const onUnload = (e: BeforeUnloadEvent) => {
      if (!ref.current) return
      e.preventDefault()
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', onUnload)
    return () => {
      if (isDirty === check) {
        isDirty = null
        ask = null
      }
      window.removeEventListener('beforeunload', onUnload)
    }
  }, [modal, what])

  return guardedNavigate
}
