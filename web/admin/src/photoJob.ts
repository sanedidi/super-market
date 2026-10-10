// Задания «ИИ для фото»: Gemini рисует 10–60 секунд, поэтому сервер сразу
// отвечает заданием, а панель опрашивает GET /admin/ai-photo/jobs/{id}.
import { useEffect, useRef, useState } from 'react'
import { api, errorText } from '@sm/shared'

export interface PhotoItem {
  source: string
  result: string
  error: string
  done: boolean
  ms: number
}

export interface PhotoJob {
  id: string
  test: boolean
  running: boolean
  items: PhotoItem[]
  cost_usd: number
  ok: boolean
  message: string
  model: string
}

const POLL_MS = 1500

/** Запуск задания и опрос, пока оно не закончится. */
export function usePhotoJob(onDone?: (job: PhotoJob) => void) {
  const [job, setJob] = useState<PhotoJob | null>(null)
  const [error, setError] = useState<string | null>(null)
  const timer = useRef<number>()
  const done = useRef(onDone)
  done.current = onDone

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const poll = (id: string) => {
    timer.current = window.setTimeout(async () => {
      try {
        const j = await api.get<PhotoJob>(`/admin/ai-photo/jobs/${id}`)
        setJob(j)
        if (j.running) poll(id)
        else done.current?.(j)
      } catch (e) {
        setError(errorText(e))
      }
    }, POLL_MS)
  }

  const start = async (path: string, body: unknown) => {
    window.clearTimeout(timer.current)
    setError(null)
    setJob(null)
    try {
      const j = await api.post<PhotoJob>(path, body)
      setJob(j)
      if (j.running) poll(j.id)
      else done.current?.(j)
      return j
    } catch (e) {
      setError(errorText(e))
      return null
    }
  }

  const reset = () => {
    window.clearTimeout(timer.current)
    setJob(null)
    setError(null)
  }

  return { job, error, running: !!job?.running, start, reset }
}

/** Примерная цена одного фото по прайсу Google (USD). */
export function usd(v: number): string {
  return `≈ ${v < 1 ? v.toFixed(3) : v.toFixed(2)} $`.replace('.', ',')
}
