// Окна «Начала работы»: новый товар, неизвестный штрихкод.
import { useEffect, useRef, useState } from 'react'
import { Alert, App, Button, Col, Flex, Form, Input, Modal, Row, Segmented, Select, Space, Typography } from 'antd'
import { InfoCircleOutlined, PlusOutlined } from '@ant-design/icons'
import { FormTranslate, ImageUpload, RemoteSelect, api, errorText, getLang, money, tr, useList } from '@sm/shared'
import { useStore } from '../../ctx'
import { Num, ProductSelect } from '../../ui'
import type { DictItem, Product } from '../../types'
import { useStartApi, type Similar } from './api'
import { Thumb } from './Thumb'


// ------------------------------------------------------------ новый товар

export type NewProductInit = {
  name?: string
  barcode?: string
  brand_id?: string | null
  /** Название бренда brand_id — подпись в поле, пока бренда нет в выдаче поиска. */
  brand?: string
  category_id?: string | null
  qty?: string | number
}

/**
 * Свой товар, которого нет в центральной базе: сразу доступен сети и
 * попадает в «Мои товары», в общую базу — после проверки. withLine — сразу
 * в «Мои товары» (иначе только создать и вернуть). Количество и цены — на
 * шаге «Инвентаризация».
 */
export function NewProductModal({
  open,
  init,
  withLine = true,
  onClose,
  onCreated,
}: {
  open: boolean
  init?: NewProductInit
  withLine?: boolean
  onClose: () => void
  onCreated?: (p: Product) => void
}) {
  const { storeId } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [form] = Form.useForm()
  const [saving, setSaving] = useState(false)
  const units = useList<DictItem & { short_name: string }>(open ? '/store/catalog/units' : null)

  // Поля заполняем при открытии окна (init мог пересоздаться при перерисовке).
  const initRef = useRef(init)
  initRef.current = init
  useEffect(() => {
    if (!open) return
    const init = initRef.current
    form.resetFields()
    form.setFieldsValue({
      name: init?.name,
      brand_id: init?.brand_id ?? undefined,
      category_id: init?.category_id ?? undefined,
      barcodes: init?.barcode ? [init.barcode] : [],
    })
  }, [open, form])
  // Единица по умолчанию — штука.
  useEffect(() => {
    // short_name приходит на языке запроса: «шт» или «dona».
    const pcs = units.data?.find((u) => u.short_name === 'шт' || u.short_name === 'dona')
    if (open && pcs && !form.getFieldValue('unit_id')) form.setFieldValue('unit_id', pcs.id)
  }, [open, units.data, form])

  const submit = async (v: Record<string, unknown>) => {
    setSaving(true)
    try {
      const p = await api.post<Product>('/store/products', {
        // Название по-русски и по-узбекски; если заполнено только узбекское — оно же и основное.
        name: String(v.name ?? '').trim() || v.name_uz,
        name_uz: String(v.name_uz ?? '').trim() || undefined,
        category_id: v.category_id,
        unit_id: v.unit_id,
        brand_id: v.brand_id || undefined,
        base_price: v.base_price || undefined,
        barcodes: v.barcodes ?? [],
        images: v.images ?? [],
        description: '',
        // Свой товар из «Начала работы» уходит на модерацию при «Записать и закрыть».
        start_draft: true,
      })
      if (withLine) {
        // Цена продажи из карточки — сразу в строку (на шаге 2 её можно поменять).
        await setLines([{ product_id: p.id, add: true, qty: initRef.current?.qty ?? undefined, price: (v.base_price as string) || undefined, source: 'new' }])
        message.success(tr('Товар создан и добавлен в «Мои товары»', 'Mahsulot yaratildi va «Mahsulotlarim»ga qoʻshildi'))
      }
      onCreated?.(p)
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      open={open}
      title={tr('Новый товар', 'Yangi mahsulot')}
      okText={withLine ? tr('Создать и добавить', 'Yaratish va qoʻshish') : tr('Создать', 'Yaratish')}
      onOk={() => form.submit()}
      confirmLoading={saving}
      onCancel={onClose}
      width={680}
      destroyOnHidden
    >
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message={tr('Товара нет в центральной базе? Создайте его: он сразу встанет в «Мои товары», а после проверки попадёт в общую базу и станет виден покупателям.', 'Mahsulot markaziy bazada yoʻqmi? Uni yarating: u darhol «Mahsulotlarim»ga tushadi, tekshiruvdan soʻng esa umumiy bazaga qoʻshilib, xaridorlarga koʻrinadi.')}
      />
      <Form form={form} layout="vertical" onFinish={submit}>
        <Row gutter={16}>
          {(getLang() === 'uz' ? (['name_uz', 'name'] as const) : (['name', 'name_uz'] as const)).map((f, i) => (
            <Col span={24} key={f}>
              <Form.Item
                name={f}
                label={f === 'name' ? tr('Название', 'Nomi (rus tilida)') : tr('Название на узбекском', 'Nomi')}
                dependencies={[f === 'name' ? 'name_uz' : 'name']}
                rules={
                  i === 0
                    ? [
                        {
                          validator: (_, v) =>
                            String(v ?? '').trim() || String(form.getFieldValue(f === 'name' ? 'name_uz' : 'name') ?? '').trim()
                              ? Promise.resolve()
                              : Promise.reject(new Error(tr('Обязательное поле', 'Majburiy maydon'))),
                        },
                      ]
                    : undefined
                }
              >
                <Input
                  placeholder={
                    i === 0
                      ? tr('Вид товара, бренд, вкус, объём — например «Квас Navruz 1,5 л»', 'Mahsulot turi, brend, taʼm, hajm — masalan, «Navruz kvasi 1,5 l»')
                      : undefined
                  }
                  suffix={<FormTranslate form={form} from={f === 'name' ? 'name_uz' : 'name'} into={f} to={f === 'name' ? 'ru' : 'uz'} />}
                />
              </Form.Item>
            </Col>
          ))}
          <Col xs={24} md={12}>
            <Form.Item name="category_id" label={tr('Категория', 'Kategoriya')} rules={[{ required: true, message: tr('Выберите категорию', 'Kategoriyani tanlang') }]}>
              <RemoteSelect<DictItem> path="/store/catalog/categories" />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="brand_id" label={tr('Бренд', 'Brend')}>
              <RemoteSelect<DictItem> path="/store/catalog/brands" search allowClear selectedLabel={init?.brand_id ? init.brand || undefined : undefined} />
            </Form.Item>
          </Col>
          <Col xs={24} md={8}>
            <Form.Item name="unit_id" label={tr('Единица', 'Oʻlchov birligi')} rules={[{ required: true, message: tr('Выберите единицу', 'Oʻlchov birligini tanlang') }]}>
              <RemoteSelect<DictItem & { short_name: string }> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} />
            </Form.Item>
          </Col>
          <Col xs={24} md={16}>
            <Form.Item name="base_price" label={tr('Цена продажи', 'Sotuv narxi')} extra={tr('Необязательно — цену можно указать на шаге «Инвентаризация»', 'Ixtiyoriy — narxni «Inventarizatsiya» bosqichida kiritish mumkin')}>
              <Num min="1" placeholder={tr('сум', 'soʻm')} />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="barcodes" label={tr('Штрихкод', 'Shtrix-kod')} extra={tr('Отсканируйте или введите и нажмите Enter', 'Skanerlang yoki kiriting va Enter tugmasini bosing')}>
              <Select mode="tags" tokenSeparators={[',', ' ']} open={false} />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="images" label={tr('Фото', 'Rasm')} extra={tr('Первое — главное. JPG, PNG, WEBP до 8 МБ', 'Birinchisi — asosiy. JPG, PNG, WEBP 8 MB gacha')}>
              <ImageUpload multiple max={5} />
            </Form.Item>
          </Col>
        </Row>
      </Form>
    </Modal>
  )
}

// ---------------------------------------------------------- похожий товар

/** Товар для показа: название, фото, штрихкод. */
export type ShortProduct = { name: string; image: string | null; barcode: string | null }

/** V3: похожий товар уже есть — показать оба и спросить. */
export function SimilarModal({ data, onCancel, onConfirm }: { data: { item: ShortProduct; similar: Similar } | null; onCancel: () => void; onConfirm: () => void }) {
  const card = (label: string, p: { name: string; image: string | null; barcode: string | null }, accent?: boolean) => (
    <div style={{ flex: 1, minWidth: 0, background: '#FCFCFD', border: accent ? '1.5px solid #1F2937' : '1px solid #D0D5DD', borderRadius: 12, padding: 14 }}>
      <Typography.Text type="secondary" strong style={{ fontSize: 11, display: 'block', marginBottom: 10 }}>
        {label}
      </Typography.Text>
      <Flex gap={12} align="start">
        <Thumb src={p.image} size={56} />
        <div style={{ minWidth: 0 }}>
          <Typography.Text strong style={{ fontWeight: 600, display: 'block' }}>
            {p.name}
          </Typography.Text>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {p.barcode ?? '—'}
          </Typography.Text>
        </div>
      </Flex>
    </div>
  )
  return (
    <Modal
      open={!!data}
      width={720}
      title={tr('Похожий товар уже есть в списке', 'Oʻxshash mahsulot roʻyxatda allaqachon bor')}
      onCancel={onCancel}
      footer={
        <Space>
          <Button onClick={onCancel}>{tr('Отмена', 'Bekor qilish')}</Button>
          <Button type="primary" icon={<PlusOutlined />} onClick={onConfirm}>
            {tr('Всё равно добавить', 'Baribir qoʻshish')}
          </Button>
        </Space>
      }
      destroyOnHidden
    >
      <Typography.Paragraph type="secondary">
        {tr('Проверьте — может, это тот же товар. Если разные (вкус, упаковка) — добавьте.', 'Tekshiring — balki bu oʻsha mahsulotdir. Agar farqli boʻlsa (taʼm, qadoq) — qoʻshing.')}
      </Typography.Paragraph>
      {data && (
        <Flex gap={12} wrap>
          {card(tr('УЖЕ В «МОИХ ТОВАРАХ»', '«MAHSULOTLARIM»DA BOR'), data.similar)}
          {card(tr('ДОБАВЛЯЕТЕ', 'QOʻSHAYAPSIZ'), data.item, true)}
        </Flex>
      )}
      <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 12 }}>
        <InfoCircleOutlined /> {tr('Спросим один раз — для этой пары предупреждение больше не появится.', 'Bir marta soʻraymiz — bu juftlik uchun ogohlantirish boshqa chiqmaydi.')}
      </Typography.Text>
    </Modal>
  )
}

// ------------------------------------------------------ неизвестный штрихкод

/** Штрихкода нет в каталоге: привязать к найденному товару или создать новый. */
export function BarcodeModal({ code, onClose }: { code: string | null; onClose: () => void }) {
  const { storeId, can } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [mode, setMode] = useState<'bind' | 'new'>('bind')
  const [product, setProduct] = useState<{ id: string; name: string }>()
  const [saving, setSaving] = useState(false)
  const [creating, setCreating] = useState(false)
  useEffect(() => {
    if (code) {
      setMode('bind')
      setProduct(undefined)
    }
  }, [code])
  const manage = can('catalog.manage')

  const bind = async () => {
    if (!product || !code) return
    setSaving(true)
    try {
      await setLines([{ product_id: product.id, add: true, barcode: code, source: 'barcode' }])
      message.success(tr(`Штрихкод привязан · ${product.name} добавлен`, `Shtrix-kod bogʻlandi · ${product.name} qoʻshildi`))
      onClose()
    } catch {
      // ошибка уже показана
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      <Modal
        open={!!code && !creating}
        title={tr(`Штрихкод ${code ?? ''} не найден`, `${code ?? ''} shtrix-kodi topilmadi`)}
        onCancel={onClose}
        footer={
          mode === 'bind' ? (
            <Space>
              <Button onClick={onClose}>{tr('Отмена', 'Bekor qilish')}</Button>
              <Button type="primary" disabled={!product || !manage} loading={saving} onClick={bind}>
                {tr('Привязать и добавить', 'Bogʻlash va qoʻshish')}
              </Button>
            </Space>
          ) : (
            <Space>
              <Button onClick={onClose}>{tr('Отмена', 'Bekor qilish')}</Button>
              <Button type="primary" icon={<PlusOutlined />} disabled={!manage} onClick={() => setCreating(true)}>
                {tr('Создать товар', 'Mahsulot yaratish')}
              </Button>
            </Space>
          )
        }
        destroyOnHidden
      >
        <Typography.Paragraph type="secondary">
          {tr('Такого штрихкода нет в каталоге. Если товар в каталоге есть, но без этого штрихкода — привяжите его, и в следующий раз товар найдётся сканером.', 'Bunday shtrix-kod katalogda yoʻq. Agar mahsulot katalogda boʻlsa-yu, bu shtrix-kodsiz boʻlsa — uni bogʻlang, keyingi safar mahsulot skaner orqali topiladi.')}
        </Typography.Paragraph>
        {!manage && <Alert type="warning" showIcon style={{ marginBottom: 12 }} message={tr('Привязывать штрихкоды и создавать товары может сотрудник с правом на каталог.', 'Shtrix-kodlarni bogʻlash va mahsulot yaratishni katalog huquqiga ega xodim bajarishi mumkin.')} />}
        <Segmented
          block
          value={mode}
          onChange={(v) => setMode(v as 'bind' | 'new')}
          options={[
            { value: 'bind', label: tr('Привязать к товару', 'Mahsulotga bogʻlash') },
            { value: 'new', label: tr('Создать новый товар', 'Yangi mahsulot yaratish') },
          ]}
          style={{ marginBottom: 16 }}
        />
        {mode === 'bind' ? (
          <ProductSelect all value={product?.id} label={product?.name} onChange={(id, p) => setProduct({ id, name: p?.name ?? '' })} autoFocus />
        ) : (
          <Typography.Text>
            {tr(`Создайте свой товар со штрихкодом ${code}. Он сразу встанет в «Мои товары».`, `${code} shtrix-kodli oʻz mahsulotingizni yarating. U darhol «Mahsulotlarim»ga tushadi.`)}
          </Typography.Text>
        )}
      </Modal>
      <NewProductModal
        open={creating}
        init={{ barcode: code ?? undefined }}
        onClose={() => {
          setCreating(false)
          onClose()
        }}
      />
    </>
  )
}

/** Сумма для подписей: «18 450 000 сум». */
export const sum = (v: string | null | undefined) => `${money(v)} ${tr('сум', 'soʻm')}`
