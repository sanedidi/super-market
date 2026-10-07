// Сканер QR камерой (BarcodeDetector в Chrome/Edge/Android) с ручным вводом,
// если камеры или детектора нет.
import { useEffect, useRef, useState } from 'react'
import { Alert, Button, Input, Modal, Space, Typography } from 'antd'
import { CameraOutlined } from '@ant-design/icons'
import { tr } from '@sm/shared'

type Detector = { detect: (src: HTMLVideoElement) => Promise<{ rawValue: string }[]> }
type DetectorCtor = new (opts: { formats: string[] }) => Detector

function detectorCtor(): DetectorCtor | null {
  const w = window as unknown as { BarcodeDetector?: DetectorCtor }
  return w.BarcodeDetector ?? null
}

export const canScanQr = () => !!detectorCtor() && !!navigator.mediaDevices?.getUserMedia

/** Видео с камеры; вызывает onCode один раз, когда распознан QR. */
function Scanner({ onCode }: { onCode: (code: string) => void }) {
  const video = useRef<HTMLVideoElement>(null)
  const [error, setError] = useState('')
  const done = useRef(false)

  useEffect(() => {
    const Ctor = detectorCtor()
    if (!Ctor) return
    let stream: MediaStream | null = null
    let timer = 0
    let stopped = false
    const detector = new Ctor({ formats: ['qr_code'] })
    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: 'environment' } })
      .then((s) => {
        if (stopped) {
          s.getTracks().forEach((t) => t.stop())
          return
        }
        stream = s
        const v = video.current
        if (!v) return
        v.srcObject = s
        void v.play()
        const tick = async () => {
          if (stopped || done.current) return
          try {
            if (v.readyState >= 2) {
              const found = await detector.detect(v)
              const raw = found[0]?.rawValue?.trim()
              if (raw && !done.current) {
                done.current = true
                onCode(raw)
                return
              }
            }
          } catch {
            // кадр не готов — пробуем дальше
          }
          timer = window.setTimeout(tick, 250)
        }
        void tick()
      })
      .catch(() => setError(tr('Нет доступа к камере — введите код вручную', 'Kameraga ruxsat yoʻq — kodni qoʻlda kiriting')))
    return () => {
      stopped = true
      window.clearTimeout(timer)
      stream?.getTracks().forEach((t) => t.stop())
    }
  }, [onCode])

  if (error) return <Alert type="warning" showIcon message={error} />
  return (
    <video
      ref={video}
      muted
      playsInline
      style={{ width: '100%', maxHeight: 320, borderRadius: 12, background: '#101828', objectFit: 'cover' }}
    />
  )
}

/**
 * Окно «сканируйте или введите код». onSubmit получает строку как есть
 * (QR целиком или ручной ввод) — разбор на сервере.
 */
export function QrCodeModal({
  open,
  title,
  hint,
  placeholder,
  okText,
  loading,
  onSubmit,
  onClose,
}: {
  open: boolean
  title: string
  hint?: string
  placeholder: string
  okText: string
  loading?: boolean
  onSubmit: (code: string) => void
  onClose: () => void
}) {
  const [code, setCode] = useState('')
  const [scan, setScan] = useState(false)
  useEffect(() => {
    if (!open) {
      setCode('')
      setScan(false)
    }
  }, [open])

  const submit = (v: string) => {
    const t = v.trim()
    if (t) onSubmit(t)
  }

  return (
    <Modal
      open={open}
      title={title}
      onCancel={onClose}
      okText={okText}
      okButtonProps={{ disabled: !code.trim(), loading }}
      onOk={() => submit(code)}
      destroyOnHidden
    >
      <Space direction="vertical" style={{ width: '100%' }} size={12}>
        {hint && <Typography.Text type="secondary">{hint}</Typography.Text>}
        {scan ? (
          <Scanner
            onCode={(v) => {
              setScan(false)
              setCode(v)
              submit(v)
            }}
          />
        ) : (
          canScanQr() && (
            <Button icon={<CameraOutlined />} block onClick={() => setScan(true)}>
              {tr('Сканировать QR камерой', 'QR kodni kamera bilan skanerlash')}
            </Button>
          )
        )}
        <Input
          size="large"
          autoFocus
          placeholder={placeholder}
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onPressEnter={() => submit(code)}
          style={{ textTransform: 'uppercase', letterSpacing: 1 }}
        />
      </Space>
    </Modal>
  )
}
