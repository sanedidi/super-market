// Каталог ИКПУ tasnif.soliq.uz: поиск и фото товара. Сервер Super Market до
// tasnif не достаёт, поэтому запросы идут прямо из браузера (CORS открыт), а
// найденные записи отправляются на сервер (/store/start/tasnif…).
import { api } from '@sm/shared'

export const TASNIF_SITE = 'https://tasnif.soliq.uz'
const API = `${TASNIF_SITE}/api/cls-api`

/** Запись каталога ИКПУ — как её отдаёт tasnif. */
export type TasnifRecord = {
  mxikCode: string
  mxikName: string
  groupCode?: string
  classCode?: string
  groupName?: string
  className?: string
  positionName?: string
  subPositionName?: string
  brandName?: string | null
  attributeName?: string | null
  internationalCode?: string | null
  label?: number | string | null
}

export type TasnifPage = { records: TasnifRecord[]; total: number }

export const TASNIF_PAGE = 20
export const isGtin = (s: string) => /^\d{8,14}$/.test(s)

async function get<T>(path: string, signal?: AbortSignal): Promise<T> {
  const r = await fetch(`${API}${path}`, { signal })
  if (!r.ok) throw new Error(`tasnif ${r.status}`)
  return (await r.json()) as T
}

/** Поиск: штрихкод — по штрихкоду, иначе по названию. */
export async function searchTasnif(q: string, page: number, signal?: AbortSignal): Promise<TasnifPage> {
  const p = new URLSearchParams({ lang: 'ru', size: String(TASNIF_PAGE), page: String(page) })
  p.set(isGtin(q) ? 'gtin' : 'text', q)
  const j = await get<{ data?: { content?: TasnifRecord[]; totalElements?: number } }>(`/mxik/search/by-params?${p}`, signal)
  const records = (j.data?.content ?? []).filter((x) => x && /^\d{17}$/.test(x.mxikCode ?? ''))
  return { records, total: j.data?.totalElements ?? records.length }
}

const withTimeout = <T,>(p: Promise<T>, ms: number) =>
  Promise.race([p, new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), ms))])

/** Уменьшить фото до 1000 px по большей стороне (JPEG). */
async function shrink(blob: Blob, max = 1000): Promise<Blob> {
  const bmp = await createImageBitmap(blob)
  const k = Math.min(1, max / Math.max(bmp.width, bmp.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(bmp.width * k)
  canvas.height = Math.round(bmp.height * k)
  const ctx = canvas.getContext('2d')
  if (!ctx) return blob
  ctx.fillStyle = '#fff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.drawImage(bmp, 0, 0, canvas.width, canvas.height)
  bmp.close()
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b ?? blob), 'image/jpeg', 0.85))
}

/**
 * Фото товара из tasnif, загруженное в наше хранилище (ссылка для товара).
 * Фото есть примерно у трети товаров; нет или не получилось — null.
 */
export async function tasnifPhoto(ikpu: string): Promise<string | null> {
  try {
    return await withTimeout(
      (async () => {
        const names = await get<string[] | { data?: string[] }>(`/integration-mxik/references/get/mxik/picture-names?lang=ru&mxik_code=${ikpu}`)
        const list = Array.isArray(names) ? names : (names.data ?? [])
        const first = list.find((n) => typeof n === 'string' && n)
        if (!first) return null
        const r = await fetch(`${API}/integration-mxik/references/get/file/${encodeURIComponent(first)}`)
        if (!r.ok) return null
        const small = await shrink(await r.blob())
        return api.upload(small, `${ikpu}.jpg`)
      })(),
      20000,
    )
  } catch {
    return null
  }
}
