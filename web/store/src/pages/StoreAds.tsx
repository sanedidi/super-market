// «Реклама брендов» в панели магазина (Figma «Витрина · монетизация»,
// раздел 6): доля сети с рекламы, бренды в магазинах сети, скрытые бренды
// и категории, сколько рекламы на главной.
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { App, Card, Spin, Switch, Table, Tag, Typography } from 'antd'
import { BulbFilled, LockFilled } from '@ant-design/icons'
import dayjs from 'dayjs'
import { LoadError, PageTitle, RemoteSelect, api, errorText, money } from '@sm/shared'
import { useStore } from '../ctx'

interface Named {
  id: string
  name: string
}

interface NetworkAds {
  share_pct: string
  share_to_subscription: boolean
  allow_hide_brands: boolean
  allow_exclude_categories: boolean
  plan: { key: string; name: string; ads_max: number; ads_reducible: boolean }
  ads_max: number
  ads_choice: number | null
  hidden_brands: Named[]
  excluded_categories: Named[]
  month_share: string
  month_views: number
  month_orders: number
  month_sales: string
  shares: { period: string; label: string; amount: string; applied: string; credited: string; settled: boolean }[]
  campaigns: {
    id: string
    brand_id: string
    brand_name: string
    format: string
    title: string
    products: string[]
    starts_at: string
    ends_at: string
    hidden: boolean
    views: number
    orders: number
    sales: string
  }[]
}

const TONES = ['#E11D2A', '#3B6FD8', '#E8850C', '#2E9E5B', '#7C5CD6']
const num = (v: number) => v.toLocaleString('ru-RU')
const pct = (v: string) => Number(v).toLocaleString('ru-RU', { maximumFractionDigits: 2 })

function Kpi({ label, value, note, accent }: { label: string; value: string; note: string; accent?: boolean }) {
  return (
    <div className={`ads-kpi${accent ? ' accent' : ''}`}>
      <span>{label}</span>
      <b>{value}</b>
      <small>{note}</small>
    </div>
  )
}

export function StoreAdsPage() {
  const { message } = App.useApp()
  const qc = useQueryClient()
  const { can } = useStore()
  const q = useQuery({ queryKey: ['/store/ads'], queryFn: () => api.get<NetworkAds>('/store/ads') })
  const d = q.data
  const save = async (body: Record<string, unknown>, ok: string) => {
    try {
      qc.setQueryData(['/store/ads'], await api.put<NetworkAds>('/store/ads', body))
      message.success(ok)
    } catch (e) {
      message.error(errorText(e))
    }
  }
  if (q.error) return <LoadError error={q.error} retry={q.refetch} />
  if (!d) return <Spin style={{ margin: 48 }} />
  const hidden = new Set(d.hidden_brands.map((b) => b.id))
  const month = dayjs().format('MMMM')
  const options = [
    { value: 2, title: 'До 2 блоков', text: 'Стандарт: больше рекламы — больше доля' },
    { value: 1, title: '1 блок', text: 'Меньше рекламы, доля меньше' },
    { value: 0, title: 'Без рекламы', text: 'Главная только ваша, доли нет' },
  ]
  return (
    <>
      <PageTitle title="Реклама брендов">
        <Typography.Text type="secondary">Бренды платят Super Market за показ своих товаров. Покупатель видит товар в вашем магазине и покупает у вас.</Typography.Text>
      </PageTitle>
      <div className="ads-grid">
        <div className="ads-col">
          <div className="ads-kpis">
            <Kpi
              accent
              label={`Ваша доля за ${month}`}
              value={`${money(d.month_share)} сум`}
              note={`${pct(d.share_pct)}% от рекламы в ваших магазинах${d.share_to_subscription ? ' — зачтём в счёт за подписку' : ' — на баланс'}`}
            />
            <Kpi label="Продажи товаров из рекламы" value={`${money(d.month_sales)} сум`} note={`${num(d.month_orders)} заказов, деньги — вам, как обычно`} />
            <Kpi label="Показы рекламы" value={num(d.month_views)} note={`за ${month}; один покупатель — один показ в день`} />
          </div>

          <Card className="ads-card">
            <h3>Сейчас в ваших магазинах</h3>
            <Typography.Text type="secondary">
              {d.allow_hide_brands ? 'Выключите бренд — его реклама пропадёт у вас, доля с него не начисляется.' : 'Скрывать бренды сейчас нельзя — правило Super Market.'}
            </Typography.Text>
            <Table
              style={{ marginTop: 12 }}
              rowKey="id"
              pagination={false}
              dataSource={d.campaigns}
              showHeader={false}
              locale={{ emptyText: 'Сейчас рекламы брендов в ваших магазинах нет' }}
              columns={[
                {
                  render: (_, c, i) => (
                    <div className="ads-brand">
                      <span style={{ background: hidden.has(c.brand_id) ? '#D0D5DD' : TONES[i % TONES.length] }}>{c.brand_name.slice(0, 1)}</span>
                      <div>
                        <b className={hidden.has(c.brand_id) ? 'off' : ''}>{c.brand_name}</b>
                        <small>
                          {c.format === 'shelf' ? 'Полка' : 'Фото-баннер'} · {c.products.join(', ')}
                        </small>
                      </div>
                    </div>
                  ),
                },
                { render: (_, c) => <Typography.Text type="secondary" style={{ whiteSpace: 'nowrap' }}>{dayjs(c.ends_at) < dayjs() ? 'завершена' : `до ${dayjs(c.ends_at).subtract(1, 'second').format('D MMM')}`}</Typography.Text> },
                {
                  render: (_, c) => (
                    <div className="ads-sales">
                      <b>{Number(c.sales) ? `${money(c.sales)} сум` : '—'}</b>
                      <small>{hidden.has(c.brand_id) ? 'скрыт · доля не начисляется' : `продажи из рекламы · ${num(c.views)} показов`}</small>
                    </div>
                  ),
                },
                {
                  align: 'right',
                  render: (_, c) => (
                    <span className="ads-toggle">
                      {hidden.has(c.brand_id) ? 'Скрыт' : 'Показывать'}
                      <Switch
                        checked={!hidden.has(c.brand_id)}
                        disabled={!d.allow_hide_brands || !can('showcase.manage')}
                        onChange={(on) => {
                          const next = new Set(hidden)
                          if (on) next.delete(c.brand_id)
                          else next.add(c.brand_id)
                          save({ hidden_brands: [...next] }, on ? `${c.brand_name}: реклама снова показывается` : `${c.brand_name} скрыт в ваших магазинах`)
                        }}
                      />
                    </span>
                  ),
                },
              ]}
            />
          </Card>

          <Card className="ads-card">
            <h3>Не показывать рекламу в категориях</h3>
            <Typography.Text type="secondary">Например, если у сети своя марка воды — реклама чужой воды у вас не появится.</Typography.Text>
            <RemoteSelect
              mode="multiple"
              path="/store/catalog/categories"
              disabled={!d.allow_exclude_categories}
              value={d.excluded_categories.map((c) => c.id)}
              onChange={(v) => save({ excluded_categories: v as string[] }, 'Категории сохранены')}
              placeholder={d.allow_exclude_categories ? '+ Категория' : 'Исключать категории сейчас нельзя — правило Super Market'}
              style={{ width: '100%', marginTop: 12 }}
            />
          </Card>
        </div>

        <div className="ads-col ads-side">
          <Card className="ads-card">
            <h3>Сколько рекламы на главной</h3>
            <Typography.Text type="secondary">Реклама всегда с пометкой «Реклама» и стоит после блоков Super Market.</Typography.Text>
            <div className="ads-options">
              {options
                .filter((o) => o.value <= d.plan.ads_max)
                .map((o) => {
                  const locked = o.value < d.plan.ads_max && !d.plan.ads_reducible
                  const on = d.ads_max === o.value
                  return (
                    <button
                      key={o.value}
                      type="button"
                      className={`ads-option${on ? ' on' : ''}${locked ? ' locked' : ''}`}
                      onClick={() => {
                        if (locked) {
                          message.info('Меньше рекламы или без неё — на тарифе «Про». Сменить тариф: «Витрина приложения» → «Сравнить тарифы».')
                          return
                        }
                        if (!on) save({ ads_max: o.value === d.plan.ads_max ? -1 : o.value }, 'Сохранено')
                      }}
                    >
                      <i />
                      <span>
                        <b>{o.title}</b>
                        <small>{o.text}</small>
                      </span>
                      {locked && (
                        <em>
                          <LockFilled /> «Про»
                        </em>
                      )}
                    </button>
                  )
                })}
            </div>
          </Card>
          <Card className="ads-card ads-how">
            <h3>
              <BulbFilled /> Как считается доля
            </h3>
            <ul>
              <li>Бренд платит Super Market за период или за 1000 показов.</li>
              <li>Ваша доля — {pct(d.share_pct)}% от оплаты за показы в ваших магазинах. Процент задаёт Super Market.</li>
              <li>
                {d.share_to_subscription
                  ? 'Доля идёт в зачёт счёта за подписку; если она больше счёта — остаток на баланс.'
                  : 'Доля зачисляется на баланс платформы после конца месяца.'}
              </li>
              <li>Товары из рекламы покупают у вас — выручка ваша целиком.</li>
            </ul>
          </Card>
          {d.shares.length > 0 && (
            <Card className="ads-card">
              <h3>Начисленная доля</h3>
              {d.shares.map((s) => (
                <div key={s.period} className="ads-share">
                  <span>{s.label}</span>
                  <b>{money(s.amount)} сум</b>
                  <small>
                    {s.settled ? `в счёт подписки ${money(s.applied)} · на баланс ${money(s.credited)}` : <Tag>ждёт счёта</Tag>}
                  </small>
                </div>
              ))}
            </Card>
          )}
        </div>
      </div>
    </>
  )
}

