// «Реклама брендов» в панели магазина (Figma «Витрина · монетизация»,
// раздел 6): доля сети с рекламы, бренды в магазинах сети, скрытые бренды
// и категории, сколько рекламы на главной.
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { App, Card, Spin, Switch, Table, Tag, Typography } from 'antd'
import { BulbFilled, LockFilled } from '@ant-design/icons'
import dayjs from 'dayjs'
import { LoadError, PageTitle, RemoteSelect, api, errorText, money, tr } from '@sm/shared'
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
    { value: 2, title: tr('До 2 блоков', '2 tagacha blok'), text: tr('Стандарт: больше рекламы — больше доля', 'Standart: reklama koʻp — ulush koʻp') },
    { value: 1, title: tr('1 блок', '1 blok'), text: tr('Меньше рекламы, доля меньше', 'Reklama kamroq, ulush ham kamroq') },
    { value: 0, title: tr('Без рекламы', 'Reklamasiz'), text: tr('Главная только ваша, доли нет', 'Bosh sahifa faqat sizniki, ulush yoʻq') },
  ]
  return (
    <>
      <PageTitle title={tr('Реклама брендов', 'Brendlar reklamasi')}>
        <Typography.Text type="secondary">
          {tr(
            'Бренды платят Super Market за показ своих товаров. Покупатель видит товар в вашем магазине и покупает у вас.',
            'Brendlar oʻz mahsulotlarini koʻrsatish uchun Super Marketga toʻlaydi. Xaridor mahsulotni doʻkoningizda koʻradi va sizdan sotib oladi.',
          )}
        </Typography.Text>
      </PageTitle>
      <div className="ads-grid">
        <div className="ads-col">
          <div className="ads-kpis">
            <Kpi
              accent
              label={tr(`Ваша доля за ${month}`, `${month} uchun ulushingiz`)}
              value={`${money(d.month_share)} ${tr('сум', 'soʻm')}`}
              note={
                tr(`${pct(d.share_pct)}% от рекламы в ваших магазинах`, `Doʻkonlaringizdagi reklamadan ${pct(d.share_pct)}%`) +
                (d.share_to_subscription
                  ? tr(' — зачтём в счёт за подписку', ' — obuna hisobiga hisoblanadi')
                  : tr(' — на баланс', ' — balansga'))
              }
            />
            <Kpi
              label={tr('Продажи товаров из рекламы', 'Reklamadagi mahsulotlar sotuvi')}
              value={`${money(d.month_sales)} ${tr('сум', 'soʻm')}`}
              note={tr(`${num(d.month_orders)} заказов, деньги — вам, как обычно`, `${num(d.month_orders)} ta buyurtma, pul odatdagidek sizga`)}
            />
            <Kpi
              label={tr('Показы рекламы', 'Reklama koʻrsatishlari')}
              value={num(d.month_views)}
              note={tr(`за ${month}; один покупатель — один показ в день`, `${month} uchun; bitta xaridor — kuniga bitta koʻrsatish`)}
            />
          </div>

          <Card className="ads-card">
            <h3>{tr('Сейчас в ваших магазинах', 'Hozir doʻkonlaringizda')}</h3>
            <Typography.Text type="secondary">
              {d.allow_hide_brands
                ? tr('Выключите бренд — его реклама пропадёт у вас, доля с него не начисляется.', 'Brendni oʻchirsangiz, uning reklamasi sizda koʻrinmaydi va undan ulush hisoblanmaydi.')
                : tr('Скрывать бренды сейчас нельзя — правило Super Market.', 'Hozir brendlarni yashirib boʻlmaydi — Super Market qoidasi.')}
            </Typography.Text>
            <Table
              style={{ marginTop: 12 }}
              rowKey="id"
              pagination={false}
              dataSource={d.campaigns}
              showHeader={false}
              locale={{ emptyText: tr('Сейчас рекламы брендов в ваших магазинах нет', 'Hozir doʻkonlaringizda brendlar reklamasi yoʻq') }}
              columns={[
                {
                  render: (_, c, i) => (
                    <div className="ads-brand">
                      <span style={{ background: hidden.has(c.brand_id) ? '#D0D5DD' : TONES[i % TONES.length] }}>{c.brand_name.slice(0, 1)}</span>
                      <div>
                        <b className={hidden.has(c.brand_id) ? 'off' : ''}>{c.brand_name}</b>
                        <small>
                          {c.format === 'shelf' ? tr('Полка', 'Javon') : tr('Фото-баннер', 'Foto-banner')} · {c.products.join(', ')}
                        </small>
                      </div>
                    </div>
                  ),
                },
                { render: (_, c) => <Typography.Text type="secondary" style={{ whiteSpace: 'nowrap' }}>{dayjs(c.ends_at) < dayjs()
                        ? tr('завершена', 'yakunlangan')
                        : tr(`до ${dayjs(c.ends_at).subtract(1, 'second').format('D MMM')}`, `${dayjs(c.ends_at).subtract(1, 'second').format('D MMM')} gacha`)}</Typography.Text> },
                {
                  render: (_, c) => (
                    <div className="ads-sales">
                      <b>{Number(c.sales) ? `${money(c.sales)} ${tr('сум', 'soʻm')}` : '—'}</b>
                      <small>{hidden.has(c.brand_id)
                          ? tr('скрыт · доля не начисляется', 'yashirilgan · ulush hisoblanmaydi')
                          : tr(`продажи из рекламы · ${num(c.views)} показов`, `reklamadan sotuvlar · ${num(c.views)} ta koʻrsatish`)}</small>
                    </div>
                  ),
                },
                {
                  align: 'right',
                  render: (_, c) => (
                    <span className="ads-toggle">
                      {hidden.has(c.brand_id) ? tr('Скрыт', 'Yashirilgan') : tr('Показывать', 'Koʻrsatish')}
                      <Switch
                        checked={!hidden.has(c.brand_id)}
                        disabled={!d.allow_hide_brands || !can('showcase.manage')}
                        onChange={(on) => {
                          const next = new Set(hidden)
                          if (on) next.delete(c.brand_id)
                          else next.add(c.brand_id)
                          save({ hidden_brands: [...next] }, on
                              ? tr(`${c.brand_name}: реклама снова показывается`, `${c.brand_name}: reklama yana koʻrsatilmoqda`)
                              : tr(`${c.brand_name} скрыт в ваших магазинах`, `${c.brand_name} doʻkonlaringizda yashirildi`))
                        }}
                      />
                    </span>
                  ),
                },
              ]}
            />
          </Card>

          <Card className="ads-card">
            <h3>{tr('Не показывать рекламу в категориях', 'Reklamani koʻrsatmaslik kerak boʻlgan kategoriyalar')}</h3>
            <Typography.Text type="secondary">
              {tr(
                'Например, если у сети своя марка воды — реклама чужой воды у вас не появится.',
                'Masalan, tarmogʻingizda oʻz suv brendi boʻlsa — boshqa suv reklamasi sizda chiqmaydi.',
              )}
            </Typography.Text>
            <RemoteSelect
              mode="multiple"
              path="/store/catalog/categories"
              disabled={!d.allow_exclude_categories}
              value={d.excluded_categories.map((c) => c.id)}
              onChange={(v) => save({ excluded_categories: v as string[] }, tr('Категории сохранены', 'Kategoriyalar saqlandi'))}
              placeholder={
                d.allow_exclude_categories
                  ? tr('+ Категория', '+ Kategoriya')
                  : tr('Исключать категории сейчас нельзя — правило Super Market', 'Hozir kategoriyalarni chiqarib boʻlmaydi — Super Market qoidasi')
              }
              style={{ width: '100%', marginTop: 12 }}
            />
          </Card>
        </div>

        <div className="ads-col ads-side">
          <Card className="ads-card">
            <h3>{tr('Сколько рекламы на главной', 'Bosh sahifada qancha reklama')}</h3>
            <Typography.Text type="secondary">
              {tr(
                'Реклама всегда с пометкой «Реклама» и стоит после блоков Super Market.',
                'Reklama doim «Reklama» belgisi bilan va Super Market bloklaridan keyin turadi.',
              )}
            </Typography.Text>
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
                          message.info(
                            tr(
                              'Меньше рекламы или без неё — на тарифе выше. Сменить тариф — в разделе «Тариф».',
                              'Kamroq reklama yoki reklamasiz — yuqoriroq tarifda. Tarifni «Tarif» boʻlimida almashtirish mumkin.',
                            ),
                          )
                          return
                        }
                        if (!on) save({ ads_max: o.value === d.plan.ads_max ? -1 : o.value }, tr('Сохранено', 'Saqlandi'))
                      }}
                    >
                      <i />
                      <span>
                        <b>{o.title}</b>
                        <small>{o.text}</small>
                      </span>
                      {locked && (
                        <em>
                          <LockFilled /> {tr('тариф выше', 'yuqoriroq tarif')}
                        </em>
                      )}
                    </button>
                  )
                })}
            </div>
          </Card>
          <Card className="ads-card ads-how">
            <h3>
              <BulbFilled /> {tr('Как считается доля', 'Ulush qanday hisoblanadi')}
            </h3>
            <ul>
              <li>{tr('Бренд платит Super Market за период или за 1000 показов.', 'Brend Super Marketga davr uchun yoki har 1000 ta koʻrsatish uchun toʻlaydi.')}</li>
              <li>
                {tr(
                  `Ваша доля — ${pct(d.share_pct)}% от оплаты за показы в ваших магазинах. Процент задаёт Super Market.`,
                  `Sizning ulushingiz — doʻkonlaringizdagi koʻrsatishlar uchun toʻlovning ${pct(d.share_pct)}%. Foizni Super Market belgilaydi.`,
                )}
              </li>
              <li>
                {d.share_to_subscription
                  ? tr('Доля идёт в зачёт счёта за подписку; если она больше счёта — остаток на баланс.', 'Ulush obuna hisobiga hisoblanadi; agar u hisobdan koʻp boʻlsa — qoldigʻi balansga.')
                  : tr('Доля зачисляется на баланс платформы после конца месяца.', 'Ulush oy tugagach platformadagi balansga oʻtkaziladi.')}
              </li>
              <li>{tr('Товары из рекламы покупают у вас — выручка ваша целиком.', 'Reklamadagi mahsulotlar sizdan sotib olinadi — tushum toʻliq sizniki.')}</li>
            </ul>
          </Card>
          {d.shares.length > 0 && (
            <Card className="ads-card">
              <h3>{tr('Начисленная доля', 'Hisoblangan ulush')}</h3>
              {d.shares.map((s) => (
                <div key={s.period} className="ads-share">
                  <span>{s.label}</span>
                  <b>
                    {money(s.amount)} {tr('сум', 'soʻm')}
                  </b>
                  <small>
                    {s.settled ? (
                      tr(`в счёт подписки ${money(s.applied)} · на баланс ${money(s.credited)}`, `obuna hisobiga ${money(s.applied)} · balansga ${money(s.credited)}`)
                    ) : (
                      <Tag>{tr('ждёт счёта', 'hisobni kutmoqda')}</Tag>
                    )}
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

