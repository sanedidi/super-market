import { useEffect, useRef } from 'react'
import { useSearchParams } from 'react-router-dom'

/**
 * Фильтр страницы в адресной строке: ссылка с главной (/orders?status=paid)
 * открывает страницу уже с фильтром, а обновление страницы его не теряет.
 * def — значение, когда параметра нет; «пусто» при непустом def хранится
 * как ?key= (например, «все платежи» вместо очереди возвратов).
 */
export function useUrlState(key: string, def?: string): [string | undefined, (v: string | undefined | null) => void] {
  const [sp, setSp] = useSearchParams()
  const value = sp.has(key) ? sp.get(key) || undefined : def
  const set = (v: string | undefined | null) => {
    // Основа — текущий адрес, а не параметры с прошлого рендера: тогда два
    // вызова подряд (сеть и сброс магазина, начало и конец периода) не
    // затирают друг друга. replace меняет адрес сразу.
    const next = new URLSearchParams(window.location.search)
    if (v === undefined || v === null || v === '') {
      if (def) next.set(key, '')
      else next.delete(key)
    } else next.set(key, v)
    setSp(next, { replace: true })
  }
  return [value, set]
}

/** Вызывает fn каждые ms миллисекунд, пока enabled. */
export function useInterval(fn: () => void, ms: number, enabled = true) {
  const ref = useRef(fn)
  ref.current = fn
  useEffect(() => {
    if (!enabled) return
    const t = setInterval(() => ref.current(), ms)
    return () => clearInterval(t)
  }, [ms, enabled])
}
