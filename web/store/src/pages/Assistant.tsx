// Помощник (тест) — чат владельца с Super Market (Figma «Super Market ·
// Помощник», страница «Веб-панель · тест», П1–П3).
//
// Слева чат: владелец пишет, говорит (удерживая микрофон) или прикрепляет
// фото накладной; помощник отвечает текстом и блоками — кнопки, карточки
// строк накладной, таблицы остатков, ссылки, кнопка «Провести приход».
// Справа — что можно сказать и что помощник сделал сегодня. Ответ приходит
// фоном: пока есть pending, список опрашивается раз в 1,5 с.
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { App, Button, Dropdown, Spin, Tag, Typography } from 'antd'
import {
  AudioOutlined,
  BarChartOutlined,
  CameraOutlined,
  CheckCircleFilled,
  ExportOutlined,
  InboxOutlined,
  PaperClipOutlined,
  SearchOutlined,
  SendOutlined,
  ShoppingCartOutlined,
  WalletOutlined,
} from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, tr } from '@sm/shared'
import { useStore } from '../ctx'

// ------------------------------------------------------------------ типы

type Action = Record<string, unknown> & { type: string; scan_id: string; label?: string }

/** attach: true — фото накладной, 'product' — фото товара, которого нет в базе. */
type AttachKind = 'invoice' | 'product'
type ButtonItem = { label: string; send?: string; action?: Action; attach?: boolean | 'product'; primary?: boolean }

type Block =
  | { type: 'buttons'; items: ButtonItem[] }
  | { type: 'card'; title: string; sum?: string; note?: string; status?: string; status_kind?: 'warn' | 'error' | 'ok'; buttons?: ButtonItem[]; line?: number }
  | { type: 'table'; columns: string[]; rows: string[][] }
  | { type: 'link'; label: string; href: string }
  | { type: 'confirm'; label: string; action: Action; enabled: boolean; hint?: string }

type Message = {
  id: string
  role: 'owner' | 'assistant' | 'system'
  kind: string
  text: string
  transcript: string | null
  lang: string
  images: string[]
  blocks: Block[]
  status: 'pending' | 'done' | 'failed'
  scan_id: string | null
  created_at: string
}

type Messages = { items: Message[]; pending: boolean }

const PATH = '/store/assistant/messages'
const MAX_VOICE_MS = 60_000

const time = (d: string) => new Date(d).toLocaleTimeString(tr('ru-RU', 'uz-UZ'), { hour: '2-digit', minute: '2-digit' })

// ------------------------------------------------------------ страница

export function AssistantPage() {
  const { storeId } = useStore()
  const qc = useQueryClient()
  const { message } = App.useApp()
  const [busy, setBusy] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)
  const attachKind = useRef<AttachKind>('invoice')
  const openAttach = (kind: AttachKind = 'invoice') => {
    attachKind.current = kind
    fileRef.current?.click()
  }

  const chat = useQuery({
    queryKey: [PATH, storeId],
    queryFn: () => api.get<Messages>(PATH, { store_id: storeId }),
    enabled: !!storeId,
    refetchInterval: (q) => (q.state.data?.pending ? 1500 : false),
  })
  const today = useQuery({
    queryKey: ['/store/assistant/today', storeId],
    queryFn: () => api.get<{ items: Message[] }>('/store/assistant/today', { store_id: storeId }),
    enabled: !!storeId,
  })
  const refresh = useCallback(() => {
    void qc.invalidateQueries({ queryKey: [PATH, storeId] })
    void qc.invalidateQueries({ queryKey: ['/store/assistant/today', storeId] })
  }, [qc, storeId])
  // Когда ответ пришёл — обновить журнал.
  const pending = chat.data?.pending
  useEffect(() => {
    if (pending === false) void qc.invalidateQueries({ queryKey: ['/store/assistant/today', storeId] })
  }, [pending, qc, storeId])

  const post = useCallback(
    async (body: unknown) => {
      setBusy(true)
      try {
        await api.post(PATH, body)
        refresh()
      } catch (e) {
        message.error(errorText(e))
      } finally {
        setBusy(false)
      }
    },
    [message, refresh],
  )
  const sendText = (text: string) => post({ store_id: storeId, text })
  const sendAction = (action: Action) => post({ store_id: storeId, action })
  const sendImages = async (files: File[], kind: AttachKind = attachKind.current) => {
    const images = files.filter((f) => f.type.startsWith('image/')).slice(0, kind === 'product' ? 3 : 5)
    if (!images.length) {
      message.warning(tr('Прикрепите фото (jpg или png).', 'Rasm biriktiring (jpg yoki png).'))
      return
    }
    setBusy(true)
    try {
      const urls: string[] = []
      for (const f of images) urls.push(await api.upload(f, f.name))
      await api.post(PATH, { store_id: storeId, images: urls, kind })
      refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  const sendVoice = async (blob: Blob, mime: string) => {
    const fd = new FormData()
    fd.append('store_id', storeId)
    fd.append('audio', blob, mime.includes('mp4') ? 'voice.m4a' : 'voice.webm')
    await post(fd)
  }

  const items = chat.data?.items ?? []
  return (
    <>
      <PageTitle title={tr('Помощник', 'Yordamchi')} />
      <Typography.Paragraph type="secondary" style={{ marginTop: -8 }}>
        {tr(
          'Напишите, скажите или прикрепите накладную — помощник Super Market сделает приход, покажет остатки, подскажет, что заказать.',
          'Yozing, ayting yoki nakladnoyni biriktiring — Super Market yordamchisi kirim qiladi, qoldiqlarni koʻrsatadi, nima buyurtma qilishni aytadi.',
        )}
        <Tag color="green" style={{ marginLeft: 8 }}>{tr('Тестовый режим · только владелец', 'Sinov rejimi · faqat egasi')}</Tag>
      </Typography.Paragraph>
      <input
        ref={fileRef}
        type="file"
        accept="image/*"
        multiple
        hidden
        onChange={(e) => {
          const files = Array.from(e.target.files ?? [])
          e.target.value = ''
          void sendImages(files, attachKind.current)
        }}
      />
      <div className="sm-assist">
        <div
          className="sm-assist-chat"
          onDragOver={(e) => e.preventDefault()}
          onDrop={(e) => {
            e.preventDefault()
            void sendImages(Array.from(e.dataTransfer.files), 'invoice')
          }}
        >
          <div className="sm-assist-messages">
            {chat.isLoading && <Spin style={{ display: 'block', margin: '48px auto' }} />}
            {chat.error && <LoadError error={chat.error} retry={() => chat.refetch()} />}
            {chat.data && items.length === 0 && (
              <Welcome onSend={sendText} onAttach={openAttach} />
            )}
            {items.map((m) => (
              <Bubble key={m.id} m={m} onSend={sendText} onAction={sendAction} onAttach={openAttach} />
            ))}
            <ScrollAnchor dep={items.length + (pending ? 1 : 0)} />
          </div>
          <Composer busy={busy || !!pending} onSend={sendText} onAttach={openAttach} onVoice={sendVoice} />
        </div>
        <div className="sm-assist-side">
          <HowTo onSend={sendText} />
          <div className="sm-assist-card">
            <div className="sm-assist-card-title">{tr('Действия помощника сегодня', 'Yordamchi bugun qilganlari')}</div>
            {(today.data?.items ?? []).length === 0 ? (
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {tr(
                  'Пока ничего. Всё, что помощник запишет, появится здесь.',
                  'Hozircha hech narsa. Yordamchi yozgan hamma narsa shu yerda koʻrinadi.',
                )}
              </Typography.Text>
            ) : (
              (today.data?.items ?? []).map((m) => (
                <div key={m.id} className="sm-assist-journal">
                  <span>{m.text}</span>
                  <span className="sm-assist-muted">{time(m.created_at)}</span>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </>
  )
}

function ScrollAnchor({ dep }: { dep: number }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    ref.current?.scrollIntoView({ block: 'end' })
  }, [dep])
  return <div ref={ref} />
}

// ------------------------------------------------------------ приветствие

const HINTS: { icon: ReactNode; send: string; title: string; desc: string }[] = [
  { icon: <InboxOutlined />, send: tr('Пришли товары', 'Tovarlar keldi'), title: tr('«пришли товары»', '«tovarlar keldi»'), desc: tr('приход по фото накладной', 'nakladnoy rasmidan kirim') },
  { icon: <SearchOutlined />, send: tr('Сколько колы осталось?', 'Kola qancha qoldi?'), title: tr('«сколько колы осталось»', '«kola qancha qoldi»'), desc: tr('остатки и на сколько дней хватит', 'qoldiqlar va necha kunga yetadi') },
  { icon: <ShoppingCartOutlined />, send: tr('Что заказать?', 'Nima buyurtma qilish kerak?'), title: tr('«что заказать»', '«nima buyurtma qilish»'), desc: tr('что заканчивается', 'nima tugayapti') },
  { icon: <BarChartOutlined />, send: tr('Продажи за сегодня', 'Bugungi sotuvlar'), title: tr('«продажи за сегодня»', '«bugungi sotuvlar»'), desc: tr('выручка, чеки, сравнение', 'tushum, cheklar, taqqoslash') },
  { icon: <WalletOutlined />, send: tr('Кто мне должен?', 'Kim menga qarz?'), title: tr('«кто мне должен»', '«kim menga qarz»'), desc: tr('долги покупателей и поставщикам', 'xaridorlar va yetkazib beruvchilar qarzi') },
]

function Welcome({ onSend, onAttach }: { onSend: (t: string) => void; onAttach: (kind?: AttachKind) => void }) {
  return (
    <div className="sm-assist-row">
      <Avatar />
      <div className="sm-assist-bubble sm-assist-bot">
        <div>
          {tr(
            'Салом! Я помощник Super Market. Скажите, что нужно сделать — приход, остатки, что заказать, продажи. Можно написать, сказать голосом или сразу прикрепить накладную.',
            'Salom! Men Super Market yordamchisiman. Nima kerakligini ayting — kirim, qoldiqlar, nima buyurtma qilish, sotuvlar. Yozishingiz, ovoz bilan aytishingiz yoki darrov nakladnoy biriktirishingiz mumkin.',
          )}
        </div>
        <div className="sm-assist-chips">
          <Button type="primary" icon={<PaperClipOutlined />} onClick={() => onAttach('invoice')}>{tr('Прикрепить накладную', 'Nakladnoyni biriktirish')}</Button>
          {HINTS.slice(0, 4).map((h) => (
            <Button key={h.send} icon={h.icon} onClick={() => onSend(h.send)}>{h.send}</Button>
          ))}
        </div>
      </div>
    </div>
  )
}

function HowTo({ onSend }: { onSend: (t: string) => void }) {
  return (
    <div className="sm-assist-card">
      <div className="sm-assist-card-title">{tr('Что можно сказать', 'Nima deyish mumkin')}</div>
      {HINTS.map((h) => (
        <button key={h.send} type="button" className="sm-assist-hint" onClick={() => onSend(h.send)}>
          <span className="sm-assist-hint-icon">{h.icon}</span>
          <span>
            <b>{h.title}</b>
            <br />
            <span className="sm-assist-muted">{h.desc}</span>
          </span>
        </button>
      ))}
      <div className="sm-assist-note">
        <AudioOutlined />{' '}
        {tr(
          'Помощник видит всё, что видите вы в панели, и может делать то же: заводить документы и товары, править карточки, отвечать по накладной. Провести, удалить, деньги и цены — только после вашей кнопки. Голос: удерживайте микрофон и говорите по-узбекски или по-русски.',
          'Yordamchi panelda siz koʻrgan hamma narsani koʻradi va shu ishlarni qila oladi: hujjat va tovar kiritish, kartochkalarni tuzatish, nakladnoy boʻyicha javob berish. Oʻtkazish, oʻchirish, pul va narxlar — faqat siz tugmani bosganingizdan keyin. Ovoz: mikrofonni bosib turing va oʻzbek yoki rus tilida gapiring.',
        )}
      </div>
    </div>
  )
}

// ------------------------------------------------------------ сообщения

function Avatar() {
  return <div className="sm-assist-avatar">SM</div>
}

function Bubble({ m, onSend, onAction, onAttach }: { m: Message; onSend: (t: string) => void; onAction: (a: Action) => void; onAttach: (kind?: AttachKind) => void }) {
  if (m.role === 'system') {
    return (
      <div className="sm-assist-system">
        <CheckCircleFilled /> {m.text} <span className="sm-assist-muted">{time(m.created_at)}</span>
      </div>
    )
  }
  if (m.role === 'owner') {
    return (
      <div className="sm-assist-row sm-assist-row-owner">
        <div className="sm-assist-bubble sm-assist-owner">
          {m.kind === 'image' && m.images.length > 0 && (
            <div className="sm-assist-muted" style={{ color: '#ffd6d9' }}>{tr('Фото', 'Rasm')}</div>
          )}
          {m.kind === 'audio' && (
            <div className="sm-assist-voice">
              <AudioOutlined /> {tr('Голосовое', 'Ovozli xabar')}
              {m.transcript ? <div className="sm-assist-transcript">«{m.transcript}»</div> : <div className="sm-assist-transcript">{tr('расшифровываю…', 'tinglayapman…')}</div>}
            </div>
          )}
          {m.images.length > 0 && (
            <div className="sm-assist-images">
              {m.images.map((u) => (
                <a key={u} href={u} target="_blank" rel="noreferrer"><img src={u} alt="" /></a>
              ))}
            </div>
          )}
          {m.text && <div>{m.text}</div>}
        </div>
      </div>
    )
  }
  return (
    <div className="sm-assist-row">
      <Avatar />
      <div className={'sm-assist-bubble sm-assist-bot' + (m.status === 'failed' ? ' sm-assist-failed' : '')}>
        {m.status === 'pending' ? (
          <div className="sm-assist-typing"><i /><i /><i /></div>
        ) : (
          <>
            {m.text && <div style={{ whiteSpace: 'pre-line' }}>{m.text}</div>}
            {m.blocks.map((b, i) => (
              <BlockView key={i} b={b} onSend={onSend} onAction={onAction} onAttach={onAttach} />
            ))}
          </>
        )}
      </div>
    </div>
  )
}

function Buttons({ items, onSend, onAction, onAttach }: { items: ButtonItem[]; onSend: (t: string) => void; onAction: (a: Action) => void; onAttach: (kind?: AttachKind) => void }) {
  if (!items?.length) return null
  return (
    <div className="sm-assist-chips">
      {items.map((it, i) => (
        <Button
          key={i}
          type={it.primary ? 'primary' : 'default'}
          icon={it.attach === 'product' ? <CameraOutlined /> : it.attach ? <PaperClipOutlined /> : undefined}
          onClick={() => {
            if (it.attach) onAttach(it.attach === 'product' ? 'product' : 'invoice')
            else if (it.action) onAction({ ...it.action, label: it.action.label ?? it.label })
            else onSend(it.send ?? it.label)
          }}
        >
          {it.label}
        </Button>
      ))}
    </div>
  )
}

function BlockView({ b, onSend, onAction, onAttach }: { b: Block; onSend: (t: string) => void; onAction: (a: Action) => void; onAttach: (kind?: AttachKind) => void }) {
  switch (b.type) {
    case 'buttons':
      return <Buttons items={b.items} onSend={onSend} onAction={onAction} onAttach={onAttach} />
    case 'card':
      return (
        <div className="sm-assist-linecard">
          <div className="sm-assist-linecard-head">
            <b>{b.title}</b>
            {b.sum && <b>{b.sum}</b>}
          </div>
          {b.note && <div className="sm-assist-muted">{b.note}</div>}
          {b.status && <div className={'sm-assist-status sm-assist-status-' + (b.status_kind ?? 'warn')}>{b.status}</div>}
          <Buttons items={b.buttons ?? []} onSend={onSend} onAction={onAction} onAttach={onAttach} />
        </div>
      )
    case 'table':
      return (
        <table className="sm-assist-table">
          <thead>
            <tr>{b.columns.map((c, i) => <th key={i}>{c}</th>)}</tr>
          </thead>
          <tbody>
            {b.rows.map((r, i) => (
              <tr key={i}>{r.map((c, j) => <td key={j}>{c}</td>)}</tr>
            ))}
          </tbody>
        </table>
      )
    case 'link':
      return (
        <Link to={b.href} className="sm-assist-link">
          {b.label} <ExportOutlined />
        </Link>
      )
    case 'confirm':
      return (
        <div>
          <Button type="primary" size="large" disabled={!b.enabled} onClick={() => onAction({ ...b.action, label: b.action.label ?? b.label })}>
            {b.label}
          </Button>
          <div className="sm-assist-muted" style={{ marginTop: 6, fontSize: 12 }}>
            {b.hint || tr('Провести можно только кнопкой — чтобы ничего не записалось случайно.', 'Faqat tugma bilan oʻtkazish mumkin — tasodifan yozilib qolmasligi uchun.')}
          </div>
        </div>
      )
    default:
      return null
  }
}

// ------------------------------------------------------------ ввод

function Composer({ busy, onSend, onAttach, onVoice }: { busy: boolean; onSend: (t: string) => void; onAttach: (kind?: AttachKind) => void; onVoice: (b: Blob, mime: string) => Promise<void> }) {
  const [text, setText] = useState('')
  const { message } = App.useApp()
  const rec = useRef<{ r: MediaRecorder; chunks: Blob[]; timer: number; stream: MediaStream } | null>(null)
  const [recording, setRecording] = useState(false)
  const [seconds, setSeconds] = useState(0)

  const submit = () => {
    const t = text.trim()
    if (!t || busy) return
    setText('')
    onSend(t)
  }

  const stop = useCallback(() => {
    const cur = rec.current
    if (!cur) return
    rec.current = null
    window.clearInterval(cur.timer)
    setRecording(false)
    if (cur.r.state !== 'inactive') cur.r.stop()
  }, [])

  const start = async () => {
    if (busy || rec.current) return
    if (typeof MediaRecorder === 'undefined' || !navigator.mediaDevices?.getUserMedia) {
      message.warning(tr('Этот браузер не умеет записывать голос — напишите текстом.', 'Bu brauzer ovoz yoza olmaydi — matn bilan yozing.'))
      return
    }
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      message.warning(tr('Нет доступа к микрофону. Разрешите его в адресной строке браузера.', 'Mikrofonga ruxsat yoʻq. Brauzer manzil qatorida ruxsat bering.'))
      return
    }
    const mime = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg'].find((m) => MediaRecorder.isTypeSupported(m)) ?? ''
    const r = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined)
    const chunks: Blob[] = []
    r.ondataavailable = (e) => {
      if (e.data.size) chunks.push(e.data)
    }
    r.onstop = () => {
      stream.getTracks().forEach((t) => t.stop())
      const type = r.mimeType || mime || 'audio/webm'
      const blob = new Blob(chunks, { type })
      // Короткий тап — не голосовое.
      if (blob.size < 2000) return
      void onVoice(blob, type)
    }
    const started = Date.now()
    setSeconds(0)
    const timer = window.setInterval(() => {
      const s = Math.floor((Date.now() - started) / 1000)
      setSeconds(s)
      if (s * 1000 >= MAX_VOICE_MS) stop()
    }, 250)
    rec.current = { r, chunks, timer, stream }
    setRecording(true)
    r.start()
  }
  useEffect(() => () => stop(), [stop])

  return (
    <div className="sm-assist-composer">
      <Dropdown
        menu={{
          items: [
            { key: 'invoice', icon: <PaperClipOutlined />, label: tr('Фото накладной — сделать приход', 'Nakladnoy rasmi — kirim qilish') },
            { key: 'product', icon: <CameraOutlined />, label: tr('Фото товара — новый товар в базу', 'Tovar rasmi — bazaga yangi tovar') },
          ],
          onClick: ({ key }) => onAttach(key as AttachKind),
        }}
        trigger={['click']}
      >
        <Button icon={<PaperClipOutlined />} title={tr('Прикрепить фото', 'Rasm biriktirish')} />
      </Dropdown>
      <input
        className="sm-assist-input"
        value={recording ? '' : text}
        placeholder={recording ? `${tr('Говорите… ', 'Gapiring… ')}${seconds} ${tr('с', 's')}` : tr('Напишите помощнику… например: «пришли товары»', 'Yordamchiga yozing… masalan: «tovarlar keldi»')}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault()
            submit()
          }
        }}
        disabled={recording}
      />
      <Button
        icon={<AudioOutlined />}
        danger={recording}
        type={recording ? 'primary' : 'default'}
        title={tr('Удерживайте и говорите', 'Bosib turing va gapiring')}
        onPointerDown={(e) => {
          e.preventDefault()
          void start()
        }}
        onPointerUp={stop}
        onPointerLeave={stop}
        onPointerCancel={stop}
      />
      <Button type="primary" icon={<SendOutlined />} loading={busy} disabled={!text.trim()} onClick={submit}>
        {tr('Отправить', 'Yuborish')}
      </Button>
    </div>
  )
}
