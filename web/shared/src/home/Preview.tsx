// Предпросмотр главной в рамке телефона. Нарисован по макету приложения и
// берёт настоящие товары выбранного магазина — это приближение, точный вид
// в приложении.
import { useEffect, useRef } from 'react'
import { useQuery } from '@tanstack/react-query'
import { RightOutlined, SearchOutlined, ShopFilled, EnvironmentFilled, BellOutlined, ShoppingOutlined, TagFilled, GiftFilled } from '@ant-design/icons'
import { api } from '../api'
import { money } from '../format'
import { COLORS, iconOf, typeMeta } from './meta'
import type { HomeBlock, PreviewProduct } from './types'
import { tr } from '../i18n'

interface Category {
  id: string
  parent_id: string | null
  name: string
  products_count: number
  image_url?: string | null
}

const TONES = ['#EEF3FB', '#EFF6EC', '#FFF4E6', '#FFF0EB', '#F3F0FA']

function useCategories(storeId: string | undefined) {
  return useQuery({
    queryKey: ['preview-categories', storeId],
    queryFn: () => api.get<{ items: Category[] }>(`/client/stores/${storeId}/categories`).then((r) => r.items ?? []),
    enabled: !!storeId,
    staleTime: 60_000,
  })
}

function Product({ p, width }: { p: PreviewProduct; width?: number }) {
  return (
    <div className="smh-prod" style={width ? { width } : undefined}>
      <div className="smh-prod-img">
        {p.images?.[0] ? <img src={p.images[0]} alt="" /> : <ShoppingOutlined />}
        {p.discount_percent ? <span className="smh-prod-badge">−{p.discount_percent}%</span> : null}
        <span className="smh-prod-add">+</span>
      </div>
      <div className="smh-prod-price">{money(p.price)} {tr('сум', 'soʻm')}</div>
      {p.old_price && <div className="smh-prod-old">{money(p.old_price)}</div>}
      <div className="smh-prod-name">{p.name}</div>
    </div>
  )
}

function Block({ b, cats }: { b: HomeBlock; cats: Category[] }) {
  const roots = cats.filter((c) => !c.parent_id || !cats.some((x) => x.id === c.parent_id))
  switch (b.type) {
    case 'shelf': {
      const items = b.products ?? []
      const cols = b.view === 'grid3' ? 3 : 2
      return (
        <div className="smh-block">
          <div className="smh-head">
            <span>{b.title}</span>
            {b.show_all !== false && b.source !== 'manual' && <a>{tr('Все', 'Hammasi')}</a>}
          </div>
          {items.length === 0 ? (
            <div className="smh-empty">{tr('Нет товаров — в приложении блок скрыт', 'Mahsulot yoʻq — ilovada blok yashirilgan')}</div>
          ) : b.view === 'row' ? (
            <div className="smh-row">{items.map((p) => <Product key={p.id} p={p} width={92} />)}</div>
          ) : (
            <div className="smh-grid" style={{ gridTemplateColumns: `repeat(${cols}, 1fr)` }}>
              {items.map((p) => <Product key={p.id} p={p} />)}
            </div>
          )}
        </div>
      )
    }
    case 'banners': {
      if (b.size === 'strip') {
        const c = COLORS[b.color ?? 'red'] ?? COLORS.red
        return (
          <div className="smh-strip" style={{ background: b.color === 'yellow' ? '#FFC21A' : c.bg, color: b.color === 'yellow' ? '#151515' : '#fff' }}>
            {iconOf(b.icon)}
            <span>{b.title}</span>
            {b.link && b.link.type !== 'none' && <RightOutlined />}
          </div>
        )
      }
      const list = b.banners ?? []
      if (list.length === 0) return <div className="smh-block"><div className="smh-empty">{tr('Нет активных баннеров — в приложении блок скрыт', 'Faol bannerlar yoʻq — ilovada blok yashirilgan')}</div></div>
      const first = list[0]
      return (
        <div className="smh-block">
          <div className="smh-banner" style={{ background: first.color }}>
            {first.image_url && <img src={first.image_url} alt="" />}
            {(first.show_text || !first.image_url) && (
              <div className="smh-banner-text">
                <b>{first.title}</b>
                {first.subtitle && <span>{first.subtitle}</span>}
              </div>
            )}
          </div>
          {list.length > 1 && (
            <div className="smh-dots">
              {list.map((x, i) => <i key={x.id} className={i === 0 ? 'on' : ''} />)}
            </div>
          )}
        </div>
      )
    }
    case 'promo': {
      if (b.kind === 'free_delivery') {
        return (
          <div className="smh-promo" style={{ background: COLORS.yellow.bg }}>
            <GiftFilled style={{ color: COLORS.yellow.icon }} />
            <div>
              <b>{tr('Доставка 0 сум от 150 000 сум', '150 000 soʻmdan yetkazib berish 0 soʻm')}</b>
              <span>{tr('Ещё 150 000 сум до бесплатной', 'Bepul yetkazishgacha yana 150 000 soʻm')}</span>
            </div>
            <RightOutlined />
          </div>
        )
      }
      const c = COLORS[b.color ?? 'yellow'] ?? COLORS.yellow
      return (
        <div className="smh-promo" style={{ background: c.bg, color: c.fg }}>
          <span style={{ color: c.icon }}>{iconOf(b.icon)}</span>
          <div><b>{b.title}</b>{b.subtitle && <span>{b.subtitle}</span>}</div>
          {b.link && b.link.type !== 'none' && <RightOutlined />}
        </div>
      )
    }
    case 'category_icons': {
      const list = b.mode === 'manual' ? (b.category_ids ?? []).map((id) => cats.find((c) => c.id === id)).filter((c): c is Category => !!c) : roots
      const items = [...(b.show_deals !== false ? [{ id: 'deals', name: tr('Скидки', 'Chegirmalar'), image_url: null as string | null | undefined }] : []), ...list]
      const shape = b.shape ?? 'circle'
      return (
        <div className={`smh-icons smh-icons-${shape}`}>
          {items.map((c, i) => (
            <div key={c.id} className="smh-icon">
              <div className="smh-icon-img" style={{ background: c.id === 'deals' ? '#FFE9EA' : TONES[i % TONES.length] }}>
                {c.id === 'deals' ? <TagFilled style={{ color: '#E11D2A' }} /> : c.image_url ? <img src={c.image_url} alt="" /> : c.name.slice(0, 1)}
              </div>
              <span>{c.name}</span>
            </div>
          ))}
        </div>
      )
    }
    case 'catalog_sections': {
      let sections = roots
        .filter((r) => cats.some((c) => c.parent_id === r.id))
        .map((r) => ({ id: r.id, title: r.name, tiles: cats.filter((c) => c.parent_id === r.id) }))
      const leaves = roots.filter((r) => !cats.some((c) => c.parent_id === r.id))
      if (leaves.length) sections.push({ id: 'all', title: tr('Каталог', 'Katalog'), tiles: leaves })
      if (b.mode === 'selected') sections = (b.category_ids ?? []).flatMap((id) => sections.filter((s) => s.id === id))
      const cols = b.view === 'tiles2' ? 2 : 3
      return (
        <div className="smh-block">
          {sections.length === 0 && <div className="smh-empty">{tr('Разделы появятся, когда в магазине будут товары', 'Doʻkonda mahsulotlar paydo boʻlganda boʻlimlar chiqadi')}</div>}
          {sections.map((s) => (
            <div key={s.id} style={{ marginBottom: 10 }}>
              <div className="smh-head"><span>{s.title}</span></div>
              {b.view === 'list' ? (
                s.tiles.map((t) => <div key={t.id} className="smh-list-row">{t.name}<RightOutlined /></div>)
              ) : (
                <div className="smh-grid" style={{ gridTemplateColumns: `repeat(${cols}, 1fr)` }}>
                  {s.tiles.map((t, i) => (
                    <div key={t.id} className="smh-tile" style={{ background: TONES[i % TONES.length], aspectRatio: cols === 2 ? '1.6' : '1' }}>
                      <span>{t.name}</span>
                      {b.show_images !== false && t.image_url && <img src={t.image_url} alt="" />}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      )
    }
  }
}

export function PhonePreview({
  blocks,
  storeId,
  storeName,
  selected,
  onSelect,
  loading,
  platform = 'ios',
}: {
  platform?: 'ios' | 'android'
  blocks: HomeBlock[]
  storeId?: string
  storeName?: string
  selected?: string
  onSelect?: (id: string) => void
  loading?: boolean
}) {
  const cats = useCategories(storeId).data ?? []
  const refs = useRef(new Map<string, HTMLDivElement>())
  useEffect(() => {
    if (selected) refs.current.get(selected)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }, [selected])
  return (
    <div className={`smh-phone ${platform}`}>
      <div className="smh-screen">
        <div className="smh-header">
          <div className="smh-status"><span>{platform === 'ios' ? '9:41' : '12:30'}</span><i /></div>
          <div className="smh-addr"><span><EnvironmentFilled /> {tr('ул. Амира Темура, 12', 'Amir Temur koʻchasi, 12')}</span><BellOutlined /></div>
          <div className="smh-eta">
            <div><small>{tr('Привезём за', 'Yetkazamiz')}</small><b>{tr('25 мин', '25 daqiqada')}</b></div>
            <span className="smh-store"><ShopFilled /> {storeName ?? tr('Магазин', 'Doʻkon')}</span>
          </div>
          <div className="smh-search"><SearchOutlined /> {tr('Найти в Super Market', 'Super Marketda qidirish')}</div>
        </div>
        <div className={`smh-body${loading ? ' smh-loading' : ''}`}>
          {blocks.length === 0 && <div className="smh-empty" style={{ margin: 24 }}>{tr('Добавьте блоки — здесь появится главная', 'Bloklar qoʻshing — bu yerda bosh sahifa paydo boʻladi')}</div>}
          {blocks.map((b) => (
            <div
              key={b.id}
              ref={(el) => {
                if (el) refs.current.set(b.id, el)
                else refs.current.delete(b.id)
              }}
              className={`smh-wrap${selected === b.id ? ' smh-selected' : ''}`}
              onClick={() => onSelect?.(b.id)}
            >
              {selected === b.id && <span className="smh-label">{typeMeta(b.type).title}</span>}
              <Block b={b} cats={cats} />
            </div>
          ))}
        </div>
        {platform === 'android' && <div className="smh-gesture" />}
      </div>
    </div>
  )
}
