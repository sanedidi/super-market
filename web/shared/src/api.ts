// HTTP-клиент API: токены, автообновление access-токена, ошибки.

export type AppName = 'admin' | 'store'

export interface Tokens {
  access_token: string
  refresh_token: string
}

export class ApiError extends Error {
  status: number
  code: string
  details: Record<string, unknown>

  constructor(status: number, code: string, message: string, details: Record<string, unknown> = {}) {
    super(message)
    this.status = status
    this.code = code
    this.details = details
  }
}

export interface List<T> {
  items: T[]
}

type Params = Record<string, string | number | boolean | undefined | null>

const BASE = '/api/v1'

let app: AppName = 'store'
let refreshing: Promise<boolean> | null = null
const listeners = new Set<() => void>()

function key() {
  return `sm_${app}_tokens`
}

export function configureApi(name: AppName) {
  app = name
}

export function getTokens(): Tokens | null {
  try {
    const raw = localStorage.getItem(key())
    return raw ? (JSON.parse(raw) as Tokens) : null
  } catch {
    return null
  }
}

export function setTokens(t: Tokens | null) {
  try {
    if (t) localStorage.setItem(key(), JSON.stringify({ access_token: t.access_token, refresh_token: t.refresh_token }))
    else localStorage.removeItem(key())
  } catch {
    // приватный режим — токены живут до перезагрузки
  }
  if (!t) listeners.forEach((fn) => fn())
}

/** Подписка на выход (токены сброшены). */
export function onLogout(fn: () => void) {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

export function query(params?: Params): string {
  if (!params) return ''
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') q.set(k, String(v))
  }
  const s = q.toString()
  return s ? `?${s}` : ''
}

async function refresh(): Promise<boolean> {
  const t = getTokens()
  if (!t) return false
  try {
    const res = await fetch(`${BASE}/auth/refresh`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: t.refresh_token }),
    })
    if (!res.ok) return false
    setTokens((await res.json()) as Tokens)
    return true
  } catch {
    return false
  }
}

async function request<T>(method: string, path: string, body?: unknown, retry = true): Promise<T> {
  const headers: Record<string, string> = {}
  const t = getTokens()
  if (t) headers.Authorization = `Bearer ${t.access_token}`
  const form = body instanceof FormData
  if (body !== undefined && !form) headers['Content-Type'] = 'application/json'
  let res: Response
  try {
    res = await fetch(BASE + path, { method, headers, body: body === undefined ? undefined : form ? body : JSON.stringify(body) })
  } catch {
    throw new ApiError(0, 'network', 'Нет связи с сервером')
  }
  if (res.status === 401 && retry && t) {
    refreshing ??= refresh().finally(() => {
      refreshing = null
    })
    if (await refreshing) return request<T>(method, path, body, false)
    setTokens(null)
  }
  if (res.status === 204) return undefined as T
  let data: unknown = null
  try {
    data = await res.json()
  } catch {
    // пустой или не-JSON ответ
  }
  if (!res.ok) {
    const e = (data as { error?: { code?: string; message?: string; details?: Record<string, unknown> } })?.error
    throw new ApiError(res.status, e?.code ?? 'http_' + res.status, e?.message ?? `Ошибка ${res.status}`, e?.details ?? {})
  }
  return data as T
}

export const api = {
  get: <T>(path: string, params?: Params) => request<T>('GET', path + query(params)),
  post: <T>(path: string, body: unknown = {}) => request<T>('POST', path, body),
  put: <T>(path: string, body: unknown) => request<T>('PUT', path, body),
  patch: <T>(path: string, body: unknown) => request<T>('PATCH', path, body),
  del: (path: string) => request<void>('DELETE', path),
  /** Фото в хранилище (MinIO) — возвращает публичную ссылку. */
  upload: (file: Blob, name = 'photo') => {
    const fd = new FormData()
    fd.append('file', file, name)
    return request<{ url: string }>('POST', `/${app}/uploads`, fd).then((r) => r.url)
  },
}
