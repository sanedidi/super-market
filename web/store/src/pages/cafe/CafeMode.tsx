// «Режим работы кафе» (Figma П10): у прилавка / со столами / столы + с собой
// и правила столов — обслуживание, свои столы, пречек, закрытие без оплаты.
import { useEffect, useState, type ReactNode } from 'react'
import { App, Alert, Divider, Flex, Input, InputNumber, Modal, Radio, Switch, Typography } from 'antd'
import { AppstoreOutlined, ShopOutlined, TableOutlined } from '@ant-design/icons'
import { api, errorText, tr } from '@sm/shared'
import { useQueryClient } from '@tanstack/react-query'
import type { CafeSettings } from './types'

type Mode = CafeSettings['cafe_mode']

const MODES: { value: Mode; icon: ReactNode; title: () => string; text: () => string }[] = [
  {
    value: 'counter',
    icon: <ShopOutlined />,
    title: () => tr('У прилавка', 'Peshtaxtada'),
    text: () => tr('касса открывается на меню; гость сначала платит, потом заказ на кухню', 'kassa menyudan ochiladi; mehmon avval toʻlaydi, keyin buyurtma oshxonaga'),
  },
  {
    value: 'tables',
    icon: <TableOutlined />,
    title: () => tr('Со столами', 'Stollar bilan'),
    text: () => tr('касса открывается на зале; заказ на кухню сразу, оплата в конце', 'kassa zaldan ochiladi; buyurtma darhol oshxonaga, toʻlov oxirida'),
  },
  {
    value: 'both',
    icon: <AppstoreOutlined />,
    title: () => tr('Столы + с собой', 'Stollar + olib ketish'),
    text: () => tr('зал и кнопка «С собой» для быстрых продаж без стола', 'zal va stolsiz tez sotuv uchun «Olib ketish» tugmasi'),
  },
]

export function CafeModeModal({ open, settings, onClose }: { open: boolean; settings?: CafeSettings; onClose: () => void }) {
  const [v, setV] = useState<CafeSettings | null>(null)
  const [saving, setSaving] = useState(false)
  const { message } = App.useApp()
  const qc = useQueryClient()

  useEffect(() => {
    if (open && settings) setV({ ...settings })
  }, [open, settings])

  const set = (p: Partial<CafeSettings>) => setV((x) => (x ? { ...x, ...p } : x))
  const tables = v?.cafe_mode !== 'counter'
  const ikpuBad = !!v && v.service_ikpu !== '' && !/^\d{17}$/.test(v.service_ikpu)
  const percent = Number(v?.service_percent ?? 0)

  const save = async () => {
    if (!v) return
    setSaving(true)
    try {
      const next = await api.patch<CafeSettings>('/store/cafe/settings', {
        cafe_mode: v.cafe_mode,
        service_percent: v.service_percent,
        waiter_own_tables: v.waiter_own_tables,
        precheck_required: v.precheck_required,
        void_senior_only: v.void_senior_only,
        service_ikpu: v.service_ikpu,
      })
      qc.setQueryData(['/store/cafe/settings', undefined], next)
      message.success(tr('Сохранено — касса обновится через несколько секунд', 'Saqlandi — kassa bir necha soniyada yangilanadi'))
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  const row = (title: string, hint: string | null, control: ReactNode) => (
    <Flex justify="space-between" align="center" gap={16}>
      <div>
        <b>{title}</b>
        {hint && (
          <Typography.Text type="secondary" style={{ display: 'block', fontSize: 12 }}>
            {hint}
          </Typography.Text>
        )}
      </div>
      {control}
    </Flex>
  )

  return (
    <Modal
      open={open}
      width={640}
      title={tr('Режим работы кафе', 'Kafe ish rejimi')}
      onCancel={onClose}
      onOk={save}
      okText={tr('Сохранить', 'Saqlash')}
      cancelText={tr('Отмена', 'Bekor qilish')}
      okButtonProps={{ loading: saving, disabled: !v || ikpuBad }}
      destroyOnHidden
    >
      {v && (
        <Flex vertical gap={16}>
          <Typography.Text type="secondary">
            {tr('Как кафе принимает заказы. От этого зависит, что касса показывает первым.', 'Kafe buyurtmalarni qanday qabul qiladi. Kassa birinchi nimani koʻrsatishi shunga bogʻliq.')}
          </Typography.Text>
          <Flex gap={12} wrap="wrap">
            {MODES.map((m) => {
              const on = v.cafe_mode === m.value
              return (
                <div
                  key={m.value}
                  role="radio"
                  aria-checked={on}
                  aria-label={m.title()}
                  tabIndex={0}
                  onClick={() => set({ cafe_mode: m.value })}
                  onKeyDown={(e) => (e.key === ' ' || e.key === 'Enter') && set({ cafe_mode: m.value })}
                  style={{
                    flex: '1 1 0',
                    minWidth: 160,
                    boxSizing: 'border-box',
                    padding: 14,
                    borderRadius: 12,
                    cursor: 'pointer',
                    border: `${on ? 2 : 1}px solid ${on ? '#e11d2a' : '#e5e7eb'}`,
                    background: on ? '#fef2f2' : '#fff',
                  }}
                >
                  <Flex justify="space-between" style={{ fontSize: 20, color: on ? '#e11d2a' : '#374151' }}>
                    {m.icon}
                    <Radio checked={on} />
                  </Flex>
                  <div style={{ fontWeight: 600, margin: '6px 0 2px' }}>{m.title()}</div>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {m.text()}
                  </Typography.Text>
                </div>
              )
            })}
          </Flex>

          {tables && (
            <>
              <Divider style={{ margin: '4px 0' }} />
              <b style={{ fontSize: 15 }}>{tr('Столы', 'Stollar')}</b>
              {row(
                tr('Обслуживание', 'Xizmat haqi'),
                tr('добавляется к счёту стола; «С собой» — без него', 'stol hisobiga qoʻshiladi; «Olib ketish» — usiz'),
                <Flex gap={12} align="center">
                  <InputNumber
                    style={{ width: 90 }}
                    min={0}
                    max={30}
                    step={1}
                    suffix="%"
                    value={percent}
                    onChange={(n) => set({ service_percent: String(n ?? 0) })}
                  />
                  <Switch checked={percent > 0} onChange={(on) => set({ service_percent: on ? '10' : '0' })} />
                </Flex>,
              )}
              {percent > 0 &&
                row(
                  tr('ИКПУ строки «Обслуживание»', '«Xizmat haqi» qatorining MXIK kodi'),
                  tr('для фискального чека; 17 цифр из tasnif.soliq.uz', 'fiskal chek uchun; tasnif.soliq.uz dan 17 raqam'),
                  <Input
                    style={{ width: 210 }}
                    maxLength={17}
                    status={ikpuBad ? 'error' : undefined}
                    placeholder="10000000000000000"
                    value={v.service_ikpu}
                    onChange={(e) => set({ service_ikpu: e.target.value.replace(/\D/g, '') })}
                  />,
                )}
              {row(
                tr('Официант видит только свои столы', 'Ofitsiant faqat oʻz stollarini koʻradi'),
                tr('чужие столы — серые, открыть может только старший кассир', 'boshqa stollar — kulrang, faqat katta kassir ochadi'),
                <Switch checked={v.waiter_own_tables} onChange={(waiter_own_tables) => set({ waiter_own_tables })} />,
              )}
              {row(tr('Пречек перед оплатой обязателен', 'Toʻlovdan oldin prechek majburiy'), null, (
                <Switch checked={v.precheck_required} onChange={(precheck_required) => set({ precheck_required })} />
              ))}
              {row(
                tr('Закрыть стол без оплаты — только старший кассир', 'Stolni toʻlovsiz yopish — faqat katta kassir'),
                tr('например, гость ушёл; попадёт в отчёт «Отмены»', 'masalan, mehmon ketib qoldi; «Bekor qilishlar» hisobotiga tushadi'),
                <Switch checked={v.void_senior_only} onChange={(void_senior_only) => set({ void_senior_only })} />,
              )}
              <Alert
                type="info"
                showIcon
                message={tr(
                  'Залы и столы настраиваются в «Касса → Залы и столы». Официанты входят на кассу по своему ПИН, как кассиры.',
                  'Zallar va stollar «Kassa → Zallar va stollar» da sozlanadi. Ofitsiantlar kassaga kassirlar kabi oʻz PIN-kodi bilan kiradi.',
                )}
              />
            </>
          )}
        </Flex>
      )}
    </Modal>
  )
}
