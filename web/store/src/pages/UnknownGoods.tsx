// «Товары → Без карточки» (Figma «Панель · Проданы без карточки», ПБ1–ПБ2):
// штрихкоды, которые касса продала «Неизвестным товаром» — их нет ни в
// магазине, ни (часто) в Super Market. «Завести товар» — карточка с ценой,
// дальше касса пробивает товар обычно.
import { useState } from 'react'
import { Alert, Button, Card, Form, Modal, Space, Table, Typography } from 'antd'
import { InfoCircleOutlined } from '@ant-design/icons'
import { LoadError, api, dateTime, money, tr, useAction, useList } from '@sm/shared'
import { useStore } from '../ctx'
import { Num } from '../ui'

export type UnknownGood = {
  barcode: string
  /** Название, которое кассир набрал последним; пусто — не набирали. */
  name: string
  cashier: string
  device: string
  price_min: string
  price_max: string
  qty: string
  total: string
  sales: number
  last_at: string
  /** Штрихкод уже есть в Super Market — завести можно одной ценой. */
  found: { id: string; name: string } | null
}

/** Список «Без карточки» магазина; без выбранного магазина — не запрашивается. */
export function useUnknownGoods(storeId: string | undefined, enabled = true) {
  return useList<UnknownGood>(storeId && enabled ? '/store/pos/unknown-goods' : null, { store_id: storeId })
}

const priceRange = (g: UnknownGood) => (g.price_min === g.price_max ? money(g.price_max) : `${money(g.price_min)} – ${money(g.price_max)}`)

export function UnknownGoodsTab({ onCreate }: { onCreate: (g: UnknownGood) => void }) {
  const { storeId, can } = useStore()
  const list = useUnknownGoods(storeId)
  const [adopt, setAdopt] = useState<UnknownGood | null>(null)
  const manage = can('catalog.manage')
  const prices = can('prices.manage')

  if (!storeId) {
    return <Alert type="info" showIcon message={tr('Выберите магазин вверху — список свой у каждого магазина.', 'Yuqorida doʻkonni tanlang — roʻyxat har bir doʻkonda oʻziniki.')} />
  }
  return (
    <>
      <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
        {tr(
          'Касса продала эти штрихкоды «Неизвестным товаром» — их не было в базе. Остаток не списывался. Заведите карточку — дальше товар пробивается обычно и уходит из этого списка.',
          'Kassa bu shtrix-kodlarni «Nomaʼlum mahsulot» sifatida sotdi — ular bazada yoʻq edi. Qoldiq hisobdan chiqarilmadi. Kartochka oching — keyin mahsulot odatdagidek urib chiqariladi va bu roʻyxatdan chiqadi.',
        )}
      </Typography.Paragraph>
      <LoadError error={list.error} retry={() => list.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<UnknownGood>
          rowKey="barcode"
          loading={list.isLoading || list.isFetching}
          dataSource={list.data ?? []}
          scroll={{ x: true }}
          pagination={{ pageSize: 50, hideOnSinglePage: true, showSizeChanger: false }}
          locale={{ emptyText: tr('Касса не продавала товаров без карточки', 'Kassa kartochkasiz mahsulot sotmagan') }}
          columns={[
            { title: tr('Штрихкод', 'Shtrix-kod'), key: 'barcode', render: (_, g) => <Typography.Text code>{g.barcode}</Typography.Text> },
            {
              title: tr('Название с кассы', 'Kassadagi nomi'),
              key: 'name',
              render: (_, g) => (
                <>
                  {g.name || <Typography.Text type="secondary">{tr('без названия', 'nomsiz')}</Typography.Text>}
                  <div>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {[g.cashier, g.device].filter(Boolean).join(' · ')}
                    </Typography.Text>
                  </div>
                  {g.found && (
                    <div>
                      <Typography.Text type="success" style={{ fontSize: 12 }}>
                        {tr(`Есть в Super Market: ${g.found.name}`, `Super Marketda bor: ${g.found.name}`)}
                      </Typography.Text>
                    </div>
                  )}
                </>
              ),
            },
            { title: tr('Цена', 'Narx'), key: 'price', align: 'right', render: (_, g) => priceRange(g) },
            {
              title: tr('Продано', 'Sotilgan'),
              key: 'qty',
              align: 'right',
              render: (_, g) => (
                <>
                  {tr(`${g.qty} шт · ${money(g.total)}`, `${g.qty} dona · ${money(g.total)}`)}
                  <div>
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {tr(`чеков: ${g.sales}`, `cheklar: ${g.sales}`)}
                    </Typography.Text>
                  </div>
                </>
              ),
            },
            { title: tr('Последняя продажа', 'Oxirgi sotuv'), key: 'last_at', render: (_, g) => dateTime(g.last_at) },
            {
              key: 'act',
              align: 'right',
              render: (_, g) =>
                (g.found ? prices : manage) ? (
                  <Button type="primary" ghost size="small" onClick={() => (g.found ? setAdopt(g) : onCreate(g))}>
                    {tr('Завести товар', 'Mahsulot ochish')}
                  </Button>
                ) : null,
            },
          ]}
        />
      </Card>
      <Typography.Paragraph type="secondary" style={{ marginTop: 12, fontSize: 12 }}>
        <InfoCircleOutlined />{' '}
        {tr(
          'Остаток заводится как обычно — приходом или инвентаризацией.',
          'Qoldiq odatdagidek kiritiladi — kirim yoki inventarizatsiya bilan.',
        )}
      </Typography.Paragraph>
      <AdoptModal good={adopt} onClose={() => setAdopt(null)} />
    </>
  )
}

/** Штрихкод нашёлся в Super Market: товар — в «Мои товары» с ценой магазина. */
function AdoptModal({ good, onClose }: { good: UnknownGood | null; onClose: () => void }) {
  const { storeId } = useStore()
  const [form] = Form.useForm<{ price: string }>()
  const save = useAction((v: { price: string }) => api.post('/store/pos/unknown-goods/adopt', { store_id: storeId, product_id: good!.found!.id, price: v.price }), {
    success: tr('Товар в «Моих товарах» — касса пробивает его с этой ценой', 'Mahsulot «Mening mahsulotlarim»da — kassa uni shu narx bilan urib chiqaradi'),
  })
  return (
    <Modal
      open={good !== null}
      title={tr('Завести товар', 'Mahsulot ochish')}
      okText={tr('Завести', 'Ochish')}
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      destroyOnHidden
      afterOpenChange={(v) => v && good && form.setFieldsValue({ price: good.price_max })}
    >
      {good?.found && (
        <Space direction="vertical" style={{ width: '100%' }}>
          <Alert
            type="success"
            showIcon
            message={tr(`Найден в Super Market: ${good.found.name}`, `Super Marketda topildi: ${good.found.name}`)}
            description={tr(`Штрихкод ${good.barcode}. Карточка уже есть — нужна только цена магазина.`, `Shtrix-kod ${good.barcode}. Kartochka bor — faqat doʻkon narxi kerak.`)}
          />
          <Form form={form} layout="vertical" onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
            <Form.Item name="price" label={tr('Цена продажи', 'Sotish narxi')} rules={[{ required: true, message: tr('Укажите цену', 'Narxni kiriting') }]}>
              <Num />
            </Form.Item>
          </Form>
        </Space>
      )}
    </Modal>
  )
}
