// Графики главной — простые SVG без библиотек. Цвета проверены на различимость
// при дальтонизме; у каждого графика есть подписи значений, не только цвет.
import { useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { money, tr } from '@sm/shared'

export const C = {
  pos: '#2a78d6',
  online: '#93c1ef',
  profit: '#1baf7a',
  prev: '#98a2b3',
  grid: '#f2f4f7',
  axis: '#d0d5dd',
  text: '#101828',
  muted: '#667085',
  faint: '#98a2b3',
  now: '#e11d2a',
  cats: ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#4a3aa7', '#e34948'],
  heat: ['#eef4fc', '#c9dcf5', '#94bbec', '#5f97e0', '#2a78d6', '#1b4f91'],
}

const num = (v: string | number | null | undefined) => Number(v ?? 0) || 0

/** 4 860 000 → «4,86 млн», 820 000 → «820 тыс». */
export function short(v: number): string {
  const a = Math.abs(v)
  if (a >= 1e6) return (v / 1e6).toLocaleString('ru-RU', { maximumFractionDigits: a >= 1e8 ? 0 : 2 }) + tr(' млн', ' mln')
  if (a >= 1e3) return Math.round(v / 1e3).toLocaleString('ru-RU') + tr(' тыс', ' ming')
  return Math.round(v).toLocaleString('ru-RU')
}

/** Удобный верх шкалы: 1, 2, 2.5, 5 × 10^n. */
function niceMax(v: number): number {
  if (v <= 0) return 1
  const p = Math.pow(10, Math.floor(Math.log10(v)))
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p
  return 10 * p
}

/** Ширина контейнера — графики тянутся по карточке. */
function useWidth(initial = 600) {
  const [w, setW] = useState(initial)
  const ro = useRef<ResizeObserver | null>(null)
  const ref = (el: HTMLDivElement | null) => {
    ro.current?.disconnect()
    if (!el) return
    setW(el.clientWidth || initial)
    ro.current = new ResizeObserver(([e]) => setW(Math.max(200, Math.round(e.contentRect.width))))
    ro.current.observe(el)
  }
  return [ref, w] as const
}

const tipBox: CSSProperties = {
  position: 'absolute',
  pointerEvents: 'none',
  background: '#101828',
  color: '#fff',
  borderRadius: 8,
  padding: '8px 10px',
  fontSize: 12,
  lineHeight: 1.5,
  whiteSpace: 'nowrap',
  zIndex: 2,
  boxShadow: '0 4px 12px rgba(16,24,40,.18)',
}

function Tip({ x, y, width, children }: { x: number; y: number; width: number; children: ReactNode }) {
  const left = x > width / 2
  return <div style={{ ...tipBox, top: Math.max(0, y), ...(left ? { right: width - x + 12 } : { left: x + 12 }) }}>{children}</div>
}

export function Legend({ items }: { items: { color: string; label: ReactNode; dashed?: boolean }[] }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px 16px', fontSize: 12, color: '#475467', fontWeight: 600 }}>
      {items.map((i, k) => (
        <span key={k} style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
          <span
            style={
              i.dashed
                ? { width: 14, height: 0, borderTop: `2px dashed ${i.color}` }
                : { width: 10, height: 10, borderRadius: 3, background: i.color }
            }
          />
          {i.label}
        </span>
      ))}
    </div>
  )
}

/** Мини-график в карточке показателя: линия с заливкой или столбики. */
export function Sparkline({ values, color, bars = false, height = 34 }: { values: number[]; color: string; bars?: boolean; height?: number }) {
  const [ref, w] = useWidth(180)
  const n = values.length
  if (n === 0) return <div ref={ref} style={{ height }} />
  const max = Math.max(...values, 0)
  const min = bars ? 0 : Math.min(...values)
  const span = max - min || 1
  const x = (i: number) => (n === 1 ? w / 2 : 2 + (i * (w - 6)) / (n - 1))
  const y = (v: number) => 3 + (height - 6) * (1 - (v - min) / span)
  if (bars) {
    const step = w / n
    return (
      <div ref={ref}>
        <svg width={w} height={height} role="img" aria-label={tr('динамика', 'dinamika')}>
          {values.map((v, i) => {
            const h = Math.max(2, (v / (max || 1)) * height)
            return <rect key={i} x={i * step} y={height - h} width={Math.max(2, step - 3)} height={h} rx={2} fill={i === n - 1 ? C.pos : '#d0d5dd'} />
          })}
        </svg>
      </div>
    )
  }
  const line = values.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  const id = 'sp' + color.slice(1)
  return (
    <div ref={ref}>
      <svg width={w} height={height} role="img" aria-label={tr('динамика', 'dinamika')}>
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor={color} stopOpacity={0.22} />
            <stop offset="1" stopColor={color} stopOpacity={0} />
          </linearGradient>
        </defs>
        <path d={`${line} L${x(n - 1)} ${height} L${x(0)} ${height} Z`} fill={`url(#${id})`} />
        <path d={line} fill="none" stroke={color} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
        <circle cx={x(n - 1)} cy={y(values[n - 1])} r={3.5} fill={color} stroke="#fff" strokeWidth={2} />
      </svg>
    </div>
  )
}

export type Bucket = { at: string; pos: string; online: string; revenue: string; checks: number; orders: number }

/**
 * Столбики касса + онлайн по часам или дням, пунктир — прошлый отрезок,
 * красная линия — «сейчас». Наведение показывает суммы.
 */
export function StackedBars({
  points,
  prev,
  label,
  tipTitle,
  nowIndex,
  prevName,
  height = 210,
}: {
  points: Bucket[]
  prev?: Bucket[]
  label: (p: Bucket, i: number) => string | null
  tipTitle: (p: Bucket, i: number) => string
  nowIndex?: number
  prevName: string
  height?: number
}) {
  const [ref, w] = useWidth(700)
  const [hover, setHover] = useState<number | null>(null)
  const n = Math.max(points.length, prev?.length ?? 0)
  const padL = 46
  const padB = 22
  const padT = 10
  const H = height
  const max = niceMax(Math.max(1, ...points.map((p) => num(p.revenue)), ...(prev ?? []).map((p) => num(p.revenue))))
  const slot = (w - padL) / Math.max(1, n)
  const bw = Math.max(3, Math.min(26, slot * 0.6))
  const cx = (i: number) => padL + slot * i + slot / 2
  const y = (v: number) => padT + (H - padT) * (1 - Math.max(0, v) / max)
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((k) => k * max)
  const prevPath = prev?.length ? prev.map((p, i) => `${i ? 'L' : 'M'}${cx(i).toFixed(1)} ${y(num(p.revenue)).toFixed(1)}`).join(' ') : ''
  const h = hover !== null ? points[hover] : null
  const hp = hover !== null ? prev?.[hover] : undefined
  return (
    <div ref={ref} style={{ position: 'relative' }} onMouseLeave={() => setHover(null)}>
      <svg width={w} height={H + padB} role="img" aria-label={tr('выручка по времени', 'vaqt boʻyicha tushum')}>
        {ticks.map((t, k) => (
          <g key={k}>
            <line x1={padL} x2={w} y1={y(t)} y2={y(t)} stroke={k === 0 ? C.axis : C.grid} />
            <text x={0} y={y(t) + 4} fontSize={10} fill={C.faint}>
              {t === 0 ? '0' : short(t)}
            </text>
          </g>
        ))}
        {points.map((p, i) => {
          const pos = Math.max(0, num(p.pos))
          const on = Math.max(0, num(p.online))
          const op = hover === null || hover === i ? 1 : 0.45
          return (
            <g key={i} opacity={op}>
              {pos > 0 && <rect x={cx(i) - bw / 2} y={y(pos)} width={bw} height={H - y(pos)} fill={C.pos} />}
              {on > 0 && <rect x={cx(i) - bw / 2} y={y(pos + on)} width={bw} height={Math.max(1, H - y(on) - 1)} rx={3} fill={C.online} />}
            </g>
          )
        })}
        {prevPath && <path d={prevPath} fill="none" stroke={C.prev} strokeWidth={2} strokeDasharray="5 4" strokeLinejoin="round" />}
        {nowIndex !== undefined && nowIndex >= 0 && nowIndex < n && (
          <g>
            <line x1={cx(nowIndex) + bw / 2 + 2} x2={cx(nowIndex) + bw / 2 + 2} y1={0} y2={H} stroke={C.now} />
            <text x={cx(nowIndex) + bw / 2 + 6} y={10} fontSize={10} fontWeight={700} fill={C.now}>
              {tr('сейчас', 'hozir')}
            </text>
          </g>
        )}
        {Array.from({ length: n }, (_, i) => {
          const p = points[i] ?? prev?.[i]
          const t = p ? label(p, i) : null
          return t ? (
            <text key={i} x={cx(i)} y={H + 15} fontSize={10} fill={C.faint} textAnchor="middle">
              {t}
            </text>
          ) : null
        })}
        {Array.from({ length: n }, (_, i) => (
          <rect key={'h' + i} x={padL + slot * i} y={0} width={slot} height={H} fill="transparent" onMouseEnter={() => setHover(i)} />
        ))}
      </svg>
      {hover !== null && (h || hp) && (
        <Tip x={cx(hover)} y={8} width={w}>
          <div style={{ fontWeight: 700 }}>{tipTitle((h ?? hp)!, hover)}</div>
          {h ? (
            <>
              <div>
                {tr('Касса', 'Kassa')} {money(h.pos)} · {tr('Онлайн', 'Onlayn')} {money(h.online)}
              </div>
              <div>
                {tr('Чеков', 'Cheklar')} {h.checks}
                {h.orders > 0 && ` · ${tr('заказов', 'buyurtmalar')} ${h.orders}`}
              </div>
            </>
          ) : (
            <div>{tr('Ещё не наступило', 'Hali kelmagan')}</div>
          )}
          {hp && (
            <div style={{ color: '#d0d5dd' }}>
              {prevName}: {money(hp.revenue)}
              {h && num(hp.revenue) > 0 && ` · ${delta(num(h.revenue), num(hp.revenue))}`}
            </div>
          )}
        </Tip>
      )}
    </div>
  )
}

function delta(cur: number, prev: number) {
  const d = ((cur - prev) / prev) * 100
  return (d >= 0 ? '▲ ' : '▼ ') + Math.abs(d).toLocaleString('ru-RU', { maximumFractionDigits: 0 }) + '%'
}

/** Линии с заливкой по дням (выручка, прибыль) и пунктир прошлого отрезка. */
export function DayLines({
  series,
  prev,
  dates,
  prevName,
  height = 190,
}: {
  series: { name: string; color: string; values: number[] }[]
  prev?: number[]
  dates: string[]
  prevName: string
  height?: number
}) {
  const [ref, w] = useWidth(700)
  const [hover, setHover] = useState<number | null>(null)
  const n = dates.length
  const padL = 46
  const padB = 22
  const H = height
  const padT = 10
  const max = niceMax(Math.max(1, ...series.flatMap((s) => s.values), ...(prev ?? [])))
  const x = (i: number) => padL + 4 + (n <= 1 ? 0 : (i * (w - padL - 10)) / (n - 1))
  const y = (v: number) => padT + (H - padT) * (1 - Math.max(0, v) / max)
  const path = (vals: number[]) => vals.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  const ticks = [0, 1 / 3, 2 / 3, 1].map((k) => k * max)
  // Подписываем только рекордный день — не каждое значение.
  const main = series[0]?.values ?? []
  const best = main.length ? main.indexOf(Math.max(...main)) : -1
  const every = Math.max(1, Math.ceil(n / 6))
  return (
    <div ref={ref} style={{ position: 'relative' }} onMouseLeave={() => setHover(null)}>
      <svg width={w} height={H + padB} role="img" aria-label={tr('выручка и прибыль по дням', 'kunlar boʻyicha tushum va foyda')}>
        <defs>
          {series.map((s) => (
            <linearGradient key={s.name} id={'dl' + s.color.slice(1)} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stopColor={s.color} stopOpacity={0.2} />
              <stop offset="1" stopColor={s.color} stopOpacity={0.02} />
            </linearGradient>
          ))}
        </defs>
        {ticks.map((t, k) => (
          <g key={k}>
            <line x1={padL} x2={w} y1={y(t)} y2={y(t)} stroke={k === 0 ? C.axis : C.grid} />
            <text x={0} y={y(t) + 4} fontSize={10} fill={C.faint}>
              {t === 0 ? '0' : short(t)}
            </text>
          </g>
        ))}
        {n > 1 &&
          series.map((s) => (
            <path key={'a' + s.name} d={`${path(s.values)} L${x(n - 1)} ${H} L${x(0)} ${H} Z`} fill={`url(#dl${s.color.slice(1)})`} />
          ))}
        {prev && prev.length === n && n > 1 && <path d={path(prev)} fill="none" stroke={C.prev} strokeWidth={2} strokeDasharray="5 4" />}
        {series.map((s) => (
          <path key={'l' + s.name} d={path(s.values)} fill="none" stroke={s.color} strokeWidth={2} strokeLinejoin="round" />
        ))}
        {best >= 0 && main[best] > 0 && (
          <g>
            <circle cx={x(best)} cy={y(main[best])} r={4.5} fill={series[0].color} stroke="#fff" strokeWidth={2} />
            <text x={Math.min(Math.max(x(best), padL + 60), w - 60)} y={Math.max(10, y(main[best]) - 10)} fontSize={11} fontWeight={700} fill="#344054" textAnchor="middle">
              {tr('рекорд', 'rekord')} · {dates[best]} · {short(main[best])}
            </text>
          </g>
        )}
        {dates.map((d, i) =>
          i % every === 0 || i === n - 1 ? (
            <text key={i} x={x(i)} y={H + 15} fontSize={10} fill={i === n - 1 ? '#344054' : C.faint} fontWeight={i === n - 1 ? 700 : 400} textAnchor={i === n - 1 ? 'end' : 'middle'}>
              {d}
            </text>
          ) : null,
        )}
        {hover !== null && <line x1={x(hover)} x2={x(hover)} y1={0} y2={H} stroke={C.axis} />}
        {hover !== null &&
          series.map((s) => <circle key={'h' + s.name} cx={x(hover)} cy={y(s.values[hover])} r={4} fill={s.color} stroke="#fff" strokeWidth={2} />)}
        {Array.from({ length: n }, (_, i) => (
          <rect
            key={'r' + i}
            x={x(i) - (w - padL) / Math.max(1, n) / 2}
            y={0}
            width={(w - padL) / Math.max(1, n)}
            height={H}
            fill="transparent"
            onMouseEnter={() => setHover(i)}
          />
        ))}
      </svg>
      {hover !== null && (
        <Tip x={x(hover)} y={8} width={w}>
          <div style={{ fontWeight: 700 }}>{dates[hover]}</div>
          {series.map((s) => (
            <div key={s.name}>
              {s.name}: {money(s.values[hover])}
            </div>
          ))}
          {prev?.[hover] !== undefined && (
            <div style={{ color: '#d0d5dd' }}>
              {prevName}: {money(prev[hover])}
            </div>
          )}
        </Tip>
      )}
    </div>
  )
}

/** Кольцо долей с подписью в центре. */
export function Donut({ parts, size = 140, center }: { parts: { value: number; color: string; name: string }[]; size?: number; center: ReactNode }) {
  const [hover, setHover] = useState<number | null>(null)
  const total = parts.reduce((s, p) => s + Math.max(0, p.value), 0)
  const r = size / 2
  const ri = r * 0.68
  const arcs = useMemo(() => {
    let a = -Math.PI / 2
    const gap = parts.length > 1 ? 0.03 : 0
    return parts.map((p) => {
      const sweep = total > 0 ? (Math.max(0, p.value) / total) * Math.PI * 2 : 0
      const a0 = a + gap / 2
      const a1 = a + sweep - gap / 2
      a += sweep
      if (sweep <= gap) return ''
      const pt = (rad: number, ang: number) => `${r + rad * Math.cos(ang)} ${r + rad * Math.sin(ang)}`
      const large = a1 - a0 > Math.PI ? 1 : 0
      if (sweep >= Math.PI * 2 - 0.001) {
        return `M${pt(r, 0)} A${r} ${r} 0 1 1 ${pt(r, Math.PI)} A${r} ${r} 0 1 1 ${pt(r, 0)} M${pt(ri, 0)} A${ri} ${ri} 0 1 0 ${pt(ri, Math.PI)} A${ri} ${ri} 0 1 0 ${pt(ri, 0)}`
      }
      return `M${pt(r, a0)} A${r} ${r} 0 ${large} 1 ${pt(r, a1)} L${pt(ri, a1)} A${ri} ${ri} 0 ${large} 0 ${pt(ri, a0)} Z`
    })
  }, [parts, total, r, ri])
  return (
    <div style={{ position: 'relative', width: size, height: size, flex: 'none' }}>
      <svg width={size} height={size} role="img" aria-label={tr('доли', 'ulushlar')}>
        {total <= 0 && <circle cx={r} cy={r} r={(r + ri) / 2} fill="none" stroke={C.grid} strokeWidth={r - ri} />}
        {arcs.map((d, i) =>
          d ? <path key={i} d={d} fill={parts[i].color} fillRule="evenodd" opacity={hover === null || hover === i ? 1 : 0.45} onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)} /> : null,
        )}
      </svg>
      <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', textAlign: 'center', pointerEvents: 'none' }}>
        {hover !== null ? (
          <div>
            <div style={{ fontWeight: 800, fontSize: 15, color: C.text }}>{total > 0 ? Math.round((parts[hover].value / total) * 100) : 0}%</div>
            <div style={{ fontSize: 11, color: C.muted, maxWidth: ri * 1.6 }}>{parts[hover].name}</div>
          </div>
        ) : (
          center
        )}
      </div>
    </div>
  )
}

/** Тепловая карта «день недели × час». */
export function Heatmap({
  cells,
  hours,
  peak,
}: {
  cells: { weekday: number; hour: number; checks: number; revenue: string }[]
  hours: number[]
  peak?: { weekday: number; hour: number } | null
}) {
  const [hover, setHover] = useState<{ d: number; h: number } | null>(null)
  const map = new Map(cells.map((c) => [c.weekday * 100 + c.hour, c]))
  const max = Math.max(1, ...cells.map((c) => c.checks))
  const days = [
    tr('Пн', 'Du'),
    tr('Вт', 'Se'),
    tr('Ср', 'Ch'),
    tr('Чт', 'Pa'),
    tr('Пт', 'Ju'),
    tr('Сб', 'Sh'),
    tr('Вс', 'Ya'),
  ]
  const cur = hover ? map.get(hover.d * 100 + hover.h) : undefined
  return (
    <div style={{ position: 'relative' }} onMouseLeave={() => setHover(null)}>
      <div style={{ display: 'grid', gridTemplateColumns: `24px repeat(${hours.length}, 1fr)`, gap: 3, alignItems: 'center' }}>
        {days.map((d, di) => (
          <Row key={d} label={d}>
            {hours.map((h) => {
              const c = map.get((di + 1) * 100 + h)
              const k = c ? Math.min(5, Math.floor((c.checks / max) * 5.999)) : 0
              const isPeak = peak && peak.weekday === di + 1 && peak.hour === h
              return (
                <div
                  key={h}
                  onMouseEnter={() => setHover({ d: di + 1, h })}
                  style={{
                    height: 22,
                    borderRadius: 4,
                    background: C.heat[k],
                    boxShadow: isPeak ? 'inset 0 0 0 2px #101828' : undefined,
                    outline: hover && hover.d === di + 1 && hover.h === h ? '2px solid #101828' : undefined,
                  }}
                />
              )
            })}
          </Row>
        ))}
        <span />
        {hours.map((h, i) => (
          <span key={h} style={{ fontSize: 10, color: C.faint, textAlign: 'center' }}>
            {i % 2 === 0 ? h : ''}
          </span>
        ))}
      </div>
      {hover && (
        <div style={{ ...tipBox, top: -6, right: 0 }}>
          {days[hover.d - 1]}, {hover.h}:00–{hover.h + 1}:00 · {cur
            ? tr(
                `${cur.checks.toLocaleString('ru-RU')} чеков, ${money(cur.revenue)} сум`,
                `${cur.checks.toLocaleString('ru-RU')} ta chek, ${money(cur.revenue)} soʻm`,
              )
            : tr('продаж нет', 'sotuv yoʻq')}
        </div>
      )}
    </div>
  )
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <>
      <span style={{ fontSize: 11, color: C.muted, fontWeight: 600 }}>{label}</span>
      {children}
    </>
  )
}

export function HeatLegend() {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, fontSize: 10, color: C.faint }}>
      {tr('меньше', 'kamroq')}
      {C.heat.map((c) => (
        <span key={c} style={{ width: 12, height: 12, borderRadius: 3, background: c }} />
      ))}
      {tr('больше', 'koʻproq')}
    </span>
  )
}

/**
 * Кривая Парето по группам ABC: доля товаров → доля выручки. Точки — границы
 * групп; между ними кривая сглажена (монотонно, без выбросов).
 */
export function Pareto({ groups, height = 120 }: { groups: { count: number; share: number }[]; height?: number }) {
  const [ref, w] = useWidth(330)
  const total = groups.reduce((s, g) => s + g.count, 0)
  const padL = 30
  const pb = 16
  const pt = 8
  const X = (p: number) => padL + (w - padL - 4) * p
  const Y = (p: number) => pt + (height - pt) * (1 - p)
  const pts: [number, number][] = [[0, 0]]
  let c = 0
  let s = 0
  for (const g of groups) {
    c += total ? g.count / total : 0
    s += g.share / 100
    pts.push([Math.min(1, c), Math.min(1, s)])
  }
  // Монотонная кубическая интерполяция (Фритч—Карлсон).
  const n = pts.length
  const dx = pts.slice(1).map((p, i) => p[0] - pts[i][0] || 1e-6)
  const sl = pts.slice(1).map((p, i) => (p[1] - pts[i][1]) / dx[i])
  const m = pts.map((_, i) => (i === 0 ? sl[0] : i === n - 1 ? sl[n - 2] : sl[i - 1] * sl[i] <= 0 ? 0 : (2 * sl[i - 1] * sl[i]) / (sl[i - 1] + sl[i])))
  let d = `M${X(0)} ${Y(0)}`
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = pts[i]
    const [x1, y1] = pts[i + 1]
    const h = dx[i]
    d += ` C${X(x0 + h / 3)} ${Y(y0 + (m[i] * h) / 3)} ${X(x1 - h / 3)} ${Y(y1 - (m[i + 1] * h) / 3)} ${X(x1)} ${Y(y1)}`
  }
  const zones = [
    { from: 0, to: pts[1]?.[0] ?? 0, bg: '#ecfdf3', fg: '#067647', l: 'A' },
    { from: pts[1]?.[0] ?? 0, to: pts[2]?.[0] ?? 0, bg: '#fffaeb', fg: '#b54708', l: 'B' },
    { from: pts[2]?.[0] ?? 0, to: 1, bg: '#f2f4f7', fg: '#475467', l: 'C' },
  ]
  const a = pts[1]
  return (
    <div ref={ref}>
      <svg width={w} height={height + pb} role="img" aria-label={tr('кривая Парето', 'Pareto egri chizigʻi')}>
        {zones.map((z) =>
          z.to > z.from ? (
            <g key={z.l}>
              <rect x={X(z.from)} y={pt} width={Math.max(0, X(z.to) - X(z.from) - 1)} height={height - pt} fill={z.bg} />
              <text x={X(z.from) + 5} y={pt + 13} fontSize={11} fontWeight={800} fill={z.fg}>
                {z.l}
              </text>
            </g>
          ) : null,
        )}
        {[0, 0.5, 1].map((v) => (
          <text key={v} x={0} y={Y(v) + 4} fontSize={9} fill={C.faint}>
            {v * 100}%
          </text>
        ))}
        <line x1={padL} x2={w - 4} y1={height} y2={height} stroke={C.axis} />
        {total > 0 && <path d={d} fill="none" stroke={C.pos} strokeWidth={2} />}
        {total > 0 && a && (
          <g>
            <circle cx={X(a[0])} cy={Y(a[1])} r={4.5} fill={C.pos} stroke="#fff" strokeWidth={2} />
            <text x={Math.min(X(a[0]) + 8, w - 150)} y={Math.min(Y(a[1]) + 18, height - 6)} fontSize={11} fontWeight={700} fill={C.text}>
              {tr(
                `${Math.round(a[0] * 100)}% товаров = ${Math.round(a[1] * 100)}% выручки`,
                `${Math.round(a[0] * 100)}% mahsulot = ${Math.round(a[1] * 100)}% tushum`,
              )}
            </text>
          </g>
        )}
        <text x={padL} y={height + 12} fontSize={9} fill={C.faint}>
          0%
        </text>
        <text x={w - 4} y={height + 12} fontSize={9} fill={C.faint} textAnchor="end">
          {tr('100% товаров', '100% mahsulot')}
        </text>
      </svg>
    </div>
  )
}
