// Новые онлайн-заказы: общий опрос «оплачен, ждёт принятия», звук и
// уведомление браузера, когда появляется новый заказ.
import { useEffect, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { App, Button, Tooltip } from 'antd'
import { BellFilled, BellOutlined } from '@ant-design/icons'
import { api, type List } from '@sm/shared'
import { useStore } from './ctx'
import type { Order } from './types'

const POLL = 15_000

/** Оплаченные, ещё не принятые заказы выбранного магазина (до 200). Один запрос на все экраны. */
export function usePaidOrders() {
  const { storeId, can } = useStore()
  const params = { store_id: storeId, status: 'paid', limit: 200 }
  return useQuery({
    queryKey: ['/store/orders', params],
    queryFn: () => api.get<List<Order>>('/store/orders', params).then((r) => r.items ?? []),
    enabled: !!storeId && can('orders.manage'),
    refetchInterval: POLL,
    refetchIntervalInBackground: true,
  })
}

const KEY = 'sm_store_order_alerts'

function readEnabled(): boolean {
  try {
    return localStorage.getItem(KEY) !== 'off'
  } catch {
    return true
  }
}

function saveEnabled(on: boolean) {
  try {
    localStorage.setItem(KEY, on ? 'on' : 'off')
  } catch {
    // приватный режим — настройка живёт до перезагрузки
  }
}

/** Короткий двойной сигнал без файла со звуком. */
function beep() {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Ctx) return
    const ctx = new Ctx()
    ;[0, 0.25].forEach((at) => {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.type = 'sine'
      osc.frequency.value = 880
      gain.gain.setValueAtTime(0.0001, ctx.currentTime + at)
      gain.gain.exponentialRampToValueAtTime(0.3, ctx.currentTime + at + 0.02)
      gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + at + 0.2)
      osc.connect(gain).connect(ctx.destination)
      osc.start(ctx.currentTime + at)
      osc.stop(ctx.currentTime + at + 0.22)
    })
    setTimeout(() => void ctx.close(), 1000)
  } catch {
    // браузер запретил звук до первого клика — просто молчим
  }
}

function showNotification(orders: Order[]) {
  if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return
  const title = orders.length === 1 ? `Новый заказ № ${orders[0].number}` : `Новых заказов: ${orders.length}`
  const body = orders
    .slice(0, 3)
    .map((o) => `№ ${o.number} — ${o.address}`)
    .join('\n')
  try {
    const n = new Notification(title, { body, tag: 'sm-new-orders' })
    n.onclick = () => {
      window.focus()
      window.location.assign('/orders')
      n.close()
    }
  } catch {
    // мобильный браузер без конструктора Notification
  }
}

/**
 * Кнопка-колокольчик в шапке: включает звук и уведомления о новых заказах.
 * Сигнал — когда среди оплаченных появляется заказ, которого не было при
 * прошлом опросе (первая загрузка и смена магазина не считаются).
 */
export function OrderAlerts() {
  const { can, storeId } = useStore()
  const { message } = App.useApp()
  const [enabled, setEnabled] = useState(readEnabled)
  const paid = usePaidOrders()
  const seen = useRef<{ store: string; ids: Set<string> } | null>(null)

  useEffect(() => {
    if (!paid.data) return
    const ids = new Set(paid.data.map((o) => o.id))
    const prev = seen.current
    seen.current = { store: storeId, ids }
    if (!prev || prev.store !== storeId || !enabled) return
    const fresh = paid.data.filter((o) => !prev.ids.has(o.id))
    if (fresh.length === 0) return
    beep()
    showNotification(fresh)
  }, [paid.data, storeId, enabled])

  if (!can('orders.manage')) return null

  const toggle = async () => {
    const next = !enabled
    setEnabled(next)
    saveEnabled(next)
    if (next && typeof Notification !== 'undefined' && Notification.permission === 'default') {
      const p = await Notification.requestPermission()
      if (p !== 'granted') message.info('Уведомления браузера запрещены — будет только звук')
    }
    if (next) beep()
  }

  return (
    <Tooltip title={enabled ? 'Звук и уведомления о новых заказах включены' : 'Включить звук и уведомления о новых заказах'}>
      <Button
        type="text"
        aria-label="Уведомления о новых заказах"
        icon={enabled ? <BellFilled style={{ color: '#16a34a' }} /> : <BellOutlined />}
        onClick={() => void toggle()}
      />
    </Tooltip>
  )
}
