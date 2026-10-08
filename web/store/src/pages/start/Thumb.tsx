// Фото товара в списках «Начала работы» (заглушка, если фото нет).
import { PictureOutlined } from '@ant-design/icons'

export function Thumb({ src, size = 32 }: { src: string | null | undefined; size?: number }) {
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: 8,
        background: '#F2F4F7',
        flex: 'none',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
      }}
    >
      {src ? <img src={src} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain' }} /> : <PictureOutlined style={{ color: '#98A2B3' }} />}
    </div>
  )
}
