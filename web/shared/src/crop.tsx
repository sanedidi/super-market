// Фото баннера 1080 × 450: выбрать файл, подвинуть кадр и приблизить,
// загрузить уже обрезанное и сжатое JPEG (≈ 150–300 КБ вместо мегабайтов).
import { useEffect, useRef, useState } from 'react'
import { App, Button, Modal, Slider, Upload } from 'antd'
import { PictureOutlined, ZoomInOutlined } from '@ant-design/icons'
import { api, ApiError } from './api'

export const BANNER_W = 1080
export const BANNER_H = 450
const BOX_W = 540
const BOX_H = (BOX_W * BANNER_H) / BANNER_W

interface Frame {
  zoom: number
  x: number // смещение картинки в px рамки
  y: number
}

/** Ограничивает сдвиг, чтобы картинка всегда закрывала рамку. */
function clamp(f: Frame, img: { w: number; h: number }): Frame {
  const base = Math.max(BOX_W / img.w, BOX_H / img.h)
  const w = img.w * base * f.zoom
  const h = img.h * base * f.zoom
  return { zoom: f.zoom, x: Math.min(0, Math.max(BOX_W - w, f.x)), y: Math.min(0, Math.max(BOX_H - h, f.y)) }
}

function CropModal({ file, onCancel, onDone }: { file: File; onCancel: () => void; onDone: (url: string) => void }) {
  const { message } = App.useApp()
  const [src, setSrc] = useState('')
  const [img, setImg] = useState<HTMLImageElement | null>(null)
  const [frame, setFrame] = useState<Frame>({ zoom: 1, x: 0, y: 0 })
  const [busy, setBusy] = useState(false)
  const drag = useRef<{ x: number; y: number; f: Frame } | null>(null)

  useEffect(() => {
    const url = URL.createObjectURL(file)
    const i = new Image()
    i.onload = () => {
      setSrc(url)
      setImg(i)
      const base = Math.max(BOX_W / i.naturalWidth, BOX_H / i.naturalHeight)
      // По центру.
      setFrame({ zoom: 1, x: (BOX_W - i.naturalWidth * base) / 2, y: (BOX_H - i.naturalHeight * base) / 2 })
    }
    i.src = url
    return () => URL.revokeObjectURL(url)
  }, [file])

  const size = img ? { w: img.naturalWidth, h: img.naturalHeight } : { w: 1, h: 1 }
  const base = Math.max(BOX_W / size.w, BOX_H / size.h)
  const small = img && (img.naturalWidth < BANNER_W || img.naturalHeight < BANNER_H)

  const setZoom = (z: number) =>
    setFrame((f) => {
      // Приближаем к центру рамки.
      const k = z / f.zoom
      const cx = BOX_W / 2
      const cy = BOX_H / 2
      return clamp({ zoom: z, x: cx - (cx - f.x) * k, y: cy - (cy - f.y) * k }, size)
    })

  const save = async () => {
    if (!img) return
    setBusy(true)
    try {
      const canvas = document.createElement('canvas')
      canvas.width = BANNER_W
      canvas.height = BANNER_H
      const ctx = canvas.getContext('2d')!
      ctx.imageSmoothingQuality = 'high'
      const k = BANNER_W / BOX_W
      const s = base * frame.zoom * k
      ctx.drawImage(img, frame.x * k, frame.y * k, img.naturalWidth * s, img.naturalHeight * s)
      const blob = await new Promise<Blob>((ok, fail) => canvas.toBlob((b) => (b ? ok(b) : fail(new Error('canvas'))), 'image/jpeg', 0.86))
      onDone(await api.upload(blob, 'banner.jpg'))
    } catch (e) {
      message.error(e instanceof ApiError ? e.message : 'Не удалось загрузить фото')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal open title="Кадр баннера" width={BOX_W + 48} onCancel={onCancel} okText="Загрузить" cancelText="Отмена" onOk={save} confirmLoading={busy}>
      <div
        className="sm-crop"
        style={{ width: BOX_W, height: BOX_H }}
        onPointerDown={(e) => {
          ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
          drag.current = { x: e.clientX, y: e.clientY, f: frame }
        }}
        onPointerMove={(e) => {
          const d = drag.current
          if (d) setFrame(clamp({ ...d.f, x: d.f.x + e.clientX - d.x, y: d.f.y + e.clientY - d.y }, size))
        }}
        onPointerUp={() => (drag.current = null)}
        onWheel={(e) => setZoom(Math.min(3, Math.max(1, frame.zoom - e.deltaY / 500)))}
      >
        {img && (
          <img
            src={src}
            alt=""
            draggable={false}
            style={{ width: size.w * base * frame.zoom, height: size.h * base * frame.zoom, transform: `translate(${frame.x}px, ${frame.y}px)` }}
          />
        )}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 12 }}>
        <ZoomInOutlined />
        <Slider style={{ flex: 1 }} min={1} max={3} step={0.01} value={frame.zoom} onChange={setZoom} tooltip={{ open: false }} />
      </div>
      <div style={{ fontSize: 12, color: '#667085' }}>
        Перетащите фото, чтобы выбрать кадр. Сохранится 1080 × 450, JPEG.
        {small && <span style={{ color: '#b54708' }}> Фото меньше 1080 × 450 — в приложении может быть нечётким.</span>}
      </div>
    </Modal>
  )
}

/** Для Form.Item: value — ссылка на уже обрезанное фото баннера. */
export function BannerUpload({ value, onChange, hint = 'Загрузить фото баннера' }: { value?: string | null; onChange?: (url: string) => void; hint?: string }) {
  const [file, setFile] = useState<File | null>(null)
  const pick = (
    <Upload accept="image/jpeg,image/png,image/webp" showUploadList={false} beforeUpload={(f) => (setFile(f), false)}>
      {value ? (
        <Button size="small">Заменить фото</Button>
      ) : (
        <div className="sm-crop-drop">
          <PictureOutlined />
          <b>{hint}</b>
          <span>JPG или PNG · обрежем до 1080 × 450</span>
        </div>
      )}
    </Upload>
  )
  return (
    <div>
      {value && <img className="sm-crop-preview" src={value} alt="" />}
      {pick}
      {value && (
        <Button size="small" type="link" danger onClick={() => onChange?.('')}>
          Убрать
        </Button>
      )}
      {file && (
        <CropModal
          file={file}
          onCancel={() => setFile(null)}
          onDone={(url) => {
            setFile(null)
            onChange?.(url)
          }}
        />
      )}
    </div>
  )
}
