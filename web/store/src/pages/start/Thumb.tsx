// Фото товара в списках «Начала работы» (заглушка, если фото нет). badge —
// метка фото от Super Market (Figma «Нормализация фото для магазина», Н1):
// processing — делается (фиолетовая), done — готово (зелёная).
import { CheckOutlined, PictureOutlined, StarFilled } from '@ant-design/icons'
import { tr } from '@sm/shared'

export type ThumbBadge = 'processing' | 'done' | '' | null | undefined

export function Thumb({ src, size = 32, badge }: { src: string | null | undefined; size?: number; badge?: ThumbBadge }) {
  const d = Math.max(14, Math.round(size * 0.36))
  return (
    <div style={{ position: 'relative', flex: 'none', width: size, height: size }}>
      <div
        style={{
          width: size,
          height: size,
          borderRadius: 8,
          background: '#F2F4F7',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          overflow: 'hidden',
        }}
      >
        {src ? <img src={src} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain' }} /> : <PictureOutlined style={{ color: '#98A2B3' }} />}
      </div>
      {(badge === 'processing' || badge === 'done') && (
        <span
          title={badge === 'processing' ? tr('Super Market делает фото… ~1 мин', 'Super Market rasm tayyorlamoqda… ~1 daq') : tr('Фото Super Market', 'Super Market rasmi')}
          style={{
            position: 'absolute',
            right: -3,
            bottom: -3,
            width: d,
            height: d,
            borderRadius: d / 2,
            background: badge === 'processing' ? '#6938EF' : '#079455',
            border: '2px solid #fff',
            color: '#fff',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: Math.round(d * 0.55),
          }}
        >
          {badge === 'processing' ? <StarFilled /> : <CheckOutlined />}
        </span>
      )}
    </div>
  )
}
