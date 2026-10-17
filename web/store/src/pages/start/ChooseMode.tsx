// «Как начнём?» (Figma «начало работы v5», Н-W1): после мастера настройки
// магазин выбирает, как внести товары. «Только товары и цены» — количество не
// нужно, у товаров «Остаток не посчитан», посчитать можно потом. «Сразу с
// остатками» — инвентаризация «Начало работы», как раньше. Выбор влияет только
// на старт: режим можно сменить, пока «Начало работы» не записано.
import { useState, type ReactNode } from 'react'
import { App, Button, Card, Flex, Tag, Typography } from 'antd'
import { ArrowRightOutlined, CheckCircleFilled, ClockCircleOutlined, InfoCircleOutlined, ReconciliationOutlined, SyncOutlined, TagOutlined } from '@ant-design/icons'
import { api, errorText, tr } from '@sm/shared'
import { useStore } from '../../ctx'
import { useStartRefresh, type Draft, type StartMode } from './api'

const RED = '#E11D2A'

export function ChooseMode({ d, onChosen }: { d: Draft; onChosen?: () => void }) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [mode, setMode] = useState<StartMode>(d.mode ?? 'prices')
  const [busy, setBusy] = useState(false)

  const go = async () => {
    setBusy(true)
    try {
      await api.post<Draft>('/store/start/mode', { store_id: storeId, mode })
      await refresh()
      onChosen?.()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card style={{ maxWidth: 960, margin: '24px auto' }} styles={{ body: { padding: '32px 36px' } }}>
      <Typography.Text strong style={{ color: '#027A48', fontSize: 13 }}>
        {tr('Магазин настроен · последний шаг — товары', 'Doʻkon sozlandi · oxirgi qadam — mahsulotlar')}
      </Typography.Text>
      <Typography.Title level={3} style={{ margin: '6px 0 4px' }}>
        {tr('Как начнём?', 'Qanday boshlaymiz?')}
      </Typography.Title>
      <Typography.Paragraph type="secondary" style={{ marginBottom: 24 }}>
        {tr(
          'Выберите, как внести товары. Покупатели и касса начнут работать, как только у товаров будет цена.',
          'Mahsulotlarni qanday kiritishni tanlang. Mahsulotlarga narx qoʻyilishi bilan xaridorlar va kassa ishlay boshlaydi.',
        )}
      </Typography.Paragraph>
      <Flex gap={16} wrap align="stretch">
        <Option
          on={mode === 'prices'}
          onClick={() => setMode('prices')}
          icon={<TagOutlined />}
          title={tr('Только товары и цены', 'Faqat mahsulotlar va narxlar')}
          badge={tr('Рекомендуем · начать сегодня', 'Tavsiya · bugun boshlash')}
          desc={tr(
            'Внесите товары и цену продажи — и сразу продавайте. Сколько товара на полках, посчитаете потом, без спешки.',
            'Mahsulotlar va sotish narxini kiriting — va darhol soting. Javonlarda qancha mahsulot borligini keyinroq, shoshilmasdan sanaysiz.',
          )}
          points={[
            [true, tr('Сканер или поиск → только цена продажи', 'Skaner yoki qidiruv → faqat sotish narxi')],
            [true, tr('Количество вводить не нужно', 'Miqdorni kiritish shart emas')],
            [true, tr('Цена закупки — по желанию', 'Xarid narxi — ixtiyoriy')],
            [false, tr('Остатки — потом: при приходе товара или по одной полке', 'Qoldiqlar — keyin: mahsulot kirimida yoki bitta javon boʻyicha')],
          ]}
          note={tr(
            'У товаров будет пометка «Остаток не посчитан». Продавать можно, склад и прибыль станут точными после подсчёта.',
            'Mahsulotlarda «Qoldiq sanalmagan» belgisi boʻladi. Sotish mumkin, ombor va foyda sanalgandan keyin aniq boʻladi.',
          )}
        />
        <Option
          on={mode === 'stock'}
          onClick={() => setMode('stock')}
          icon={<ReconciliationOutlined />}
          title={tr('Сразу с остатками', 'Darhol qoldiqlar bilan')}
          desc={tr(
            'Пройдите все полки и укажите, сколько каждого товара. С первого дня — точный склад, прибыль и подсказки агентам.',
            'Barcha javonlarni aylanib, har bir mahsulotdan qanchaligini kiriting. Birinchi kundanoq — aniq ombor, foyda va agentlarga maslahatlar.',
          )}
          points={[
            [true, tr('Количество и цена продажи по каждому товару', 'Har bir mahsulot boʻyicha miqdor va sotish narxi')],
            [true, tr('Агенты сразу видят, чего вам не хватает', 'Agentlar sizga nima yetishmasligini darhol koʻradi')],
            [false, tr('Дольше: нужно посчитать всё, что есть', 'Uzoqroq: bor narsaning hammasini sanash kerak')],
            [true, tr('Можно остановиться — «Остальное посчитаю потом»', 'Toʻxtash mumkin — «Qolganini keyin sanayman»')],
          ]}
          note={tr(
            'Подходит, если товары вносит команда Super Market или у вас уже есть свой учёт.',
            'Mahsulotlarni Super Market jamoasi kiritsa yoki sizda oʻz hisobingiz boʻlsa mos keladi.',
          )}
        />
      </Flex>
      <Flex gap={16} align="center" justify="space-between" wrap style={{ marginTop: 24 }}>
        <Flex gap={8} align="center" style={{ flex: 1, minWidth: 280 }}>
          <SyncOutlined style={{ color: '#667085' }} />
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            {tr(
              'Выбор не навсегда: досчитать остатки можно в любой момент — в «Начале работы» или при приходе товара.',
              'Tanlov abadiy emas: qoldiqlarni istalgan vaqtda — «Ishni boshlash»da yoki mahsulot kirimida sanash mumkin.',
            )}
          </Typography.Text>
        </Flex>
        <Button type="primary" size="large" loading={busy} onClick={go}>
          {tr('Продолжить', 'Davom etish')} <ArrowRightOutlined />
        </Button>
      </Flex>
    </Card>
  )
}

function Option({
  on,
  onClick,
  icon,
  title,
  badge,
  desc,
  points,
  note,
}: {
  on: boolean
  onClick: () => void
  icon: ReactNode
  title: string
  badge?: string
  desc: string
  points: [boolean, string][]
  note: string
}) {
  return (
    <div
      role="radio"
      aria-checked={on}
      tabIndex={0}
      onClick={onClick}
      onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && onClick()}
      style={{
        flex: '1 1 360px',
        cursor: 'pointer',
        borderRadius: 14,
        padding: 20,
        border: on ? `2px solid ${RED}` : '1px solid #EAECF0',
        background: on ? '#FFFBFA' : '#fff',
      }}
    >
      <Flex gap={12} align="center">
        <Flex
          align="center"
          justify="center"
          style={{ width: 44, height: 44, borderRadius: 10, flex: 'none', fontSize: 20, background: on ? '#FDECED' : '#F2F4F7', color: on ? RED : '#475467' }}
        >
          {icon}
        </Flex>
        <div style={{ flex: 1 }}>
          <Typography.Text strong style={{ fontSize: 17 }}>
            {title}
          </Typography.Text>
          {badge && (
            <div>
              <Tag color="success" bordered={false} style={{ marginTop: 4 }}>
                {badge}
              </Tag>
            </div>
          )}
        </div>
        <span
          style={{
            width: 22,
            height: 22,
            borderRadius: 11,
            flex: 'none',
            boxSizing: 'border-box',
            border: on ? `6px solid ${RED}` : '1.5px solid #D0D5DD',
            background: '#fff',
          }}
        />
      </Flex>
      <Typography.Paragraph style={{ margin: '14px 0 12px', color: '#475467' }}>{desc}</Typography.Paragraph>
      <Flex vertical gap={8}>
        {points.map(([ok, t]) => (
          <Flex key={t} gap={8} align="flex-start">
            {ok ? <CheckCircleFilled style={{ color: '#027A48', marginTop: 3 }} /> : <ClockCircleOutlined style={{ color: '#B54708', marginTop: 3 }} />}
            <Typography.Text style={{ fontSize: 13, fontWeight: 600, color: '#344054' }}>{t}</Typography.Text>
          </Flex>
        ))}
      </Flex>
      <Flex gap={8} align="flex-start" style={{ marginTop: 14, background: '#F9FAFB', borderRadius: 10, padding: '10px 12px' }}>
        <InfoCircleOutlined style={{ color: '#667085', marginTop: 3 }} />
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {note}
        </Typography.Text>
      </Flex>
    </div>
  )
}
