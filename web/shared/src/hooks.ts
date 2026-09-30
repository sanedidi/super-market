import { useEffect, useState } from 'react'
import { keepPreviousData, useMutation, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query'
import { App } from 'antd'
import { api, ApiError, type List } from './api'

type Params = Record<string, string | number | boolean | undefined | null>

/** GET списка { items: [...] }. */
export function useList<T>(path: string | null, params?: Params) {
  return useQuery({
    queryKey: [path, params],
    queryFn: () => api.get<List<T>>(path!, params).then((r) => r.items ?? []),
    enabled: path !== null,
  })
}

/**
 * Постраничный список: запрашивает pageSize+1 записей со смещением, чтобы
 * узнать, есть ли следующая страница (сервер не отдаёт общее число).
 * При смене параметров возвращается на первую страницу.
 */
export function usePaged<T>(path: string | null, params?: Params, pageSize = 50) {
  const [page, setPage] = useState(1)
  const key = JSON.stringify(params ?? {})
  useEffect(() => setPage(1), [key, path])
  const q = useQuery({
    queryKey: [path, params, 'page', page, pageSize],
    queryFn: () =>
      api.get<List<T>>(path!, { ...params, limit: pageSize + 1, offset: (page - 1) * pageSize }).then((r) => r.items ?? []),
    enabled: path !== null,
    placeholderData: keepPreviousData,
  })
  const raw = q.data ?? []
  const hasMore = raw.length > pageSize
  const items = hasMore ? raw.slice(0, pageSize) : raw
  return {
    ...q,
    items,
    page,
    setPage,
    hasMore,
    /** Свойство pagination для antd Table. */
    pagination: {
      current: page,
      pageSize,
      total: (page - 1) * pageSize + items.length + (hasMore ? 1 : 0),
      onChange: (p: number) => setPage(p),
      showSizeChanger: false,
      hideOnSinglePage: true,
      showTotal: undefined,
    },
  }
}

/** Значение с задержкой — для поиска по мере ввода. */
export function useDebounced<T>(value: T, ms = 300): T {
  const [v, setV] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms)
    return () => clearTimeout(t)
  }, [value, ms])
  return v
}

/** GET одного объекта. */
export function useItem<T>(path: string | null, params?: Params) {
  return useQuery({
    queryKey: [path, params],
    queryFn: () => api.get<T>(path!, params),
    enabled: path !== null,
  })
}

export function errorText(e: unknown): string {
  if (e instanceof ApiError) {
    const d = e.details
    if (e.code === 'insufficient_stock' && d.available !== undefined) {
      return `${e.message}: доступно ${d.available}, нужно ${d.required}`
    }
    return e.message
  }
  return e instanceof Error ? e.message : String(e)
}

/** Мутация с сообщением об успехе/ошибке и сбросом кэша списков. */
export function useAction<In, Out = unknown>(fn: (input: In) => Promise<Out>, opts: { success?: string; invalidate?: QueryKey[] } = {}) {
  const qc = useQueryClient()
  const { message } = App.useApp()
  return useMutation({
    mutationFn: fn,
    onSuccess: () => {
      if (opts.success) message.success(opts.success)
      if (opts.invalidate) opts.invalidate.forEach((k) => qc.invalidateQueries({ queryKey: k }))
      else qc.invalidateQueries()
    },
    onError: (e) => message.error(errorText(e)),
  })
}
