import { useMutation, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query'
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
