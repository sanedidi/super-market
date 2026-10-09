// Окна «Начала работы»: новый товар, неизвестный штрихкод, фото полок.
import { useEffect, useMemo, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Col, Flex, Form, Input, InputNumber, Modal, Row, Segmented, Select, Space, Table, Tag, Typography } from 'antd'
import { CheckCircleFilled, ExclamationCircleFilled, InfoCircleOutlined, PlusOutlined, QuestionCircleFilled } from '@ant-design/icons'
import { FormTranslate, ImageUpload, RemoteSelect, api, errorText, getLang, money, plural, tr, useList } from '@sm/shared'
import { useStore } from '../../ctx'
import { Num, ProductSelect } from '../../ui'
import type { DictItem, Product } from '../../types'
import { useStartApi, type Candidate, type Photo, type PhotoItem, type Similar } from './api'
import { Thumb } from './Thumb'

const goods = (n: number) => tr(`${n} ${plural(n, 'товар', 'товара', 'товаров')}`, `${n} ta mahsulot`)

// ------------------------------------------------------------ новый товар

export type NewProductInit = {
  name?: string
  barcode?: string
  brand_id?: string | null
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
        base_price: v.base_price,
        barcodes: v.barcodes ?? [],
        images: v.images ?? [],
        description: '',
      })
      if (withLine) {
        // Цена продажи из карточки — сразу в строку (на шаге 2 её можно поменять).
        await setLines([{ product_id: p.id, add: true, qty: initRef.current?.qty ?? undefined, price: (v.base_price as string) ?? undefined, source: 'new' }])
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
              <RemoteSelect<DictItem> path="/store/catalog/brands" allowClear />
            </Form.Item>
          </Col>
          <Col xs={24} md={8}>
            <Form.Item name="unit_id" label={tr('Единица', 'Oʻlchov birligi')} rules={[{ required: true, message: tr('Выберите единицу', 'Oʻlchov birligini tanlang') }]}>
              <RemoteSelect<DictItem & { short_name: string }> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} />
            </Form.Item>
          </Col>
          <Col xs={24} md={16}>
            <Form.Item name="base_price" label={tr('Цена продажи', 'Sotuv narxi')} rules={[{ required: true, message: tr('Укажите цену', 'Narxni kiriting') }]}>
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
          <ProductSelect value={product?.id} label={product?.name} onChange={(id, p) => setProduct({ id, name: p?.name ?? '' })} autoFocus />
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

// --------------------------------------------------------------- фото полок

const SKIP = '__skip'
const NEW = '__new'

const stateIcon: Record<PhotoItem['state'], JSX.Element> = {
  found: <CheckCircleFilled style={{ color: '#12B76A' }} />,
  choose: <QuestionCircleFilled style={{ color: '#F79009' }} />,
  missing: <ExclamationCircleFilled style={{ color: '#F04438' }} />,
}

/**
 * Фото полок: Super Market находит на фото товары каталога и считает штуки.
 * Найденное проверяют, выбирают из похожих или создают новый товар — и
 * добавляют в «Мои товары» одним нажатием; посчитанные штуки подставятся
 * на шаге «Инвентаризация». То, что уже в списке, повторно не добавляется.
 */
export function PhotoModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { storeId, can } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [images, setImages] = useState<string[]>([])
  const [photoId, setPhotoId] = useState<string | null>(null)
  const [starting, setStarting] = useState(false)
  const [adding, setAdding] = useState(false)
  // Выбор по строкам фото: id товара, SKIP или пусто.
  const [choice, setChoice] = useState<Record<number, string>>({})
  const [qtys, setQtys] = useState<Record<number, string>>({})
  const [created, setCreated] = useState<Record<number, Candidate>>({})
  const [creating, setCreating] = useState<PhotoItem | null>(null)

  const reset = () => {
    setImages([])
    setPhotoId(null)
    setChoice({})
    setQtys({})
    setCreated({})
  }
  useEffect(() => {
    if (open) reset()
  }, [open])

  const photo = useQuery({
    queryKey: ['/store/start/photos', photoId],
    queryFn: () => api.get<Photo>(`/store/start/photos/${photoId}`),
    enabled: !!photoId,
    refetchInterval: (q) => (q.state.data?.status === 'processing' || !q.state.data ? 1500 : false),
  })
  const ph = photo.data
  const ready = ph?.status === 'ready'

  // Найденное уверенно — выбрано сразу.
  useEffect(() => {
    if (!ready || !ph) return
    setChoice((c) => {
      const next = { ...c }
      for (const it of ph.items) if (next[it.n] === undefined && it.state === 'found' && it.product) next[it.n] = it.product.product_id
      return next
    })
    setQtys((q) => {
      const next = { ...q }
      for (const it of ph.items) if (next[it.n] === undefined) next[it.n] = String(Number(it.qty))
      return next
    })
  }, [ready, ph])

  const start = async () => {
    setStarting(true)
    try {
      const r = await api.post<Photo>('/store/start/photos', { store_id: storeId, images })
      setPhotoId(r.id)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setStarting(false)
    }
  }
  const retry = async () => {
    if (!photoId) return
    try {
      await api.post(`/store/start/photos/${photoId}/retry`)
      photo.refetch()
    } catch (e) {
      message.error(errorText(e))
    }
  }

  const chosen = useMemo(() => {
    if (!ph) return []
    const sum = new Map<string, number>()
    for (const it of ph.items) {
      const id = choice[it.n]
      const q = Number(qtys[it.n] ?? it.qty)
      if (!id || id === SKIP || !(q > 0)) continue
      sum.set(id, (sum.get(id) ?? 0) + q)
    }
    return Array.from(sum, ([product_id, qty]) => ({ product_id, qty: String(qty) }))
  }, [ph, choice, qtys])

  const add = async () => {
    setAdding(true)
    try {
      const r = await setLines(chosen.map((c) => ({ ...c, add: true, source: 'photo' as const })))
      const n = chosen.length - r.skipped.length
      message.success(tr(`В «Мои товары» добавлено: ${goods(n)}`, `«Mahsulotlarim»ga qoʻshildi: ${goods(n)}`))
      if (r.skipped.length) message.info(tr(`Уже были в списке — не добавлены повторно: ${goods(r.skipped.length)}`, `Roʻyxatda allaqachon bor — qayta qoʻshilmadi: ${goods(r.skipped.length)}`))
      onClose()
    } catch {
      // ошибка уже показана
    } finally {
      setAdding(false)
    }
  }

  const options = (it: PhotoItem) => {
    const list: Candidate[] = []
    const seen = new Set<string>()
    for (const c of [created[it.n], it.product, ...it.candidates]) {
      if (c && !seen.has(c.product_id)) {
        seen.add(c.product_id)
        list.push(c)
      }
    }
    return [
      ...list.map((c) => ({
        value: c.product_id,
        label: (
          <Flex align="center" gap={8} style={{ minWidth: 0 }}>
            <Thumb src={c.image} size={22} />
            <Typography.Text ellipsis>
              {c.name}
              {c.score > 0 && c.score < 100 && <Typography.Text type="secondary"> · {c.score}%</Typography.Text>}
            </Typography.Text>
          </Flex>
        ),
        search: c.name,
      })),
      ...(can('catalog.manage') ? [{ value: NEW, label: <Typography.Text type="danger"><PlusOutlined /> {tr('Нет в каталоге — создать товар', 'Katalogda yoʻq — mahsulot yaratish')}</Typography.Text>, search: '' }] : []),
      { value: SKIP, label: <Typography.Text type="secondary">{tr('Не добавлять', 'Qoʻshmaslik')}</Typography.Text>, search: '' },
    ]
  }

  const counts = ph?.counts
  return (
    <>
      <Modal
        open={open && !creating}
        width={880}
        title={
          <div>
            {tr('Фото полок — Super Market найдёт товары', 'Javon rasmlari — Super Market mahsulotlarni topadi')}
            <Typography.Paragraph type="secondary" style={{ fontSize: 13, fontWeight: 400, margin: '4px 0 0' }}>
              {tr('Загрузите фото полок или отдельных товаров. Super Market сопоставит их с общим каталогом и посчитает штуки.', 'Javonlar yoki alohida mahsulotlar rasmlarini yuklang. Super Market ularni umumiy katalog bilan solishtirib, donalarini sanaydi.')}
            </Typography.Paragraph>
          </div>
        }
        onCancel={onClose}
        destroyOnHidden
        footer={
          <Space>
            {ph && (
              <Button onClick={reset} disabled={adding}>
                {tr('Новые фото', 'Yangi rasmlar')}
              </Button>
            )}
            <Button onClick={onClose}>{tr('Отмена', 'Bekor qilish')}</Button>
            {ready ? (
              <Button type="primary" disabled={chosen.length === 0} loading={adding} onClick={add}>
                {tr(`Добавить ${goods(chosen.length)} в список`, `${goods(chosen.length)}ni roʻyxatga qoʻshish`)}
              </Button>
            ) : (
              <Button type="primary" disabled={images.length === 0 || !!photoId} loading={starting || ph?.status === 'processing'} onClick={start}>
                {tr('Найти товары', 'Mahsulotlarni topish')}
              </Button>
            )}
          </Space>
        }
      >
        <ImageUpload multiple max={6} value={images} onChange={setImages} disabled={!!photoId} hint={tr('Фото полки', 'Javon rasmi')} />
        {!photoId && (
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('До 6 фото одной полки или разных полок. Снимайте ближе и при хорошем свете — так Super Market точнее посчитает штуки.', 'Bitta yoki turli javonlarning 6 tagacha rasmi. Yaqinroqdan va yaxshi yorugʻlikda suratga oling — shunda Super Market donalarni aniqroq sanaydi.')}
          </Typography.Text>
        )}
        {ph?.status === 'processing' && (
          <Alert style={{ marginTop: 12 }} type="info" showIcon message={tr('Super Market ищет товары на фото…', 'Super Market rasmdagi mahsulotlarni qidirmoqda…')} description={tr('Обычно это занимает 10–30 секунд.', 'Odatda bu 10–30 soniya davom etadi.')} />
        )}
        {ph?.status === 'failed' && (
          <Alert
            style={{ marginTop: 12 }}
            type="error"
            showIcon
            message={tr('Не удалось найти товары', 'Mahsulotlarni topib boʻlmadi')}
            description={ph.error}
            action={<Button size="small" onClick={retry}>{tr('Повторить', 'Qayta urinish')}</Button>}
          />
        )}
        {ready && ph && counts && (
          <>
            <Space size={8} wrap style={{ margin: '12px 0' }}>
              <Tag bordered={false}>
                {tr(`Распознано ${ph.images.length} фото`, `${ph.images.length} ta rasm aniqlandi`)}
              </Tag>
              <Tag bordered={false} color="green">
                {tr(`${counts.found} найдено`, `${counts.found} ta topildi`)}
              </Tag>
              {counts.choose > 0 && (
                <Tag bordered={false} color="orange">
                  {tr(`${counts.choose} выбрать`, `${counts.choose} ta tanlash kerak`)}
                </Tag>
              )}
              {counts.missing > 0 && (
                <Tag bordered={false} color="red">
                  {tr(`${counts.missing} нет в каталоге`, `${counts.missing} ta katalogda yoʻq`)}
                </Tag>
              )}
            </Space>
            <Table<PhotoItem>
              rowKey="n"
              size="small"
              pagination={false}
              dataSource={ph.items}
              scroll={{ y: 380 }}
              columns={[
                {
                  title: tr('На фото', 'Rasmda'),
                  key: 'name',
                  width: '34%',
                  render: (_, it) => (
                    <Flex align="center" gap={8}>
                      {stateIcon[it.state]}
                      <div style={{ minWidth: 0 }}>
                        <Typography.Text>{it.name}</Typography.Text>
                        {it.in_draft && (
                          <div>
                            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                              {tr('уже в «Моих товарах» — повторно не добавится', '«Mahsulotlarim»da bor — qayta qoʻshilmaydi')}
                            </Typography.Text>
                          </div>
                        )}
                      </div>
                    </Flex>
                  ),
                },
                {
                  title: tr('Товар в каталоге', 'Katalogdagi mahsulot'),
                  key: 'product',
                  render: (_, it) => {
                    const v = choice[it.n]
                    const status = !v ? (it.state === 'missing' ? 'error' : 'warning') : undefined
                    return (
                      <Select
                        value={v || undefined}
                        status={status}
                        style={{ width: '100%' }}
                        placeholder={
                          it.state === 'missing'
                            ? tr('Нет в каталоге — выберите действие', 'Katalogda yoʻq — amalni tanlang')
                            : tr(
                                `Выберите: ${it.candidates.length} ${plural(it.candidates.length, 'вариант', 'варианта', 'вариантов')}`,
                                `Tanlang: ${it.candidates.length} ta variant`,
                              )
                        }
                        options={options(it)}
                        optionFilterProp="search"
                        showSearch
                        onChange={(id: string) => {
                          if (id === NEW) setCreating(it)
                          else setChoice((c) => ({ ...c, [it.n]: id }))
                        }}
                      />
                    )
                  },
                },
                {
                  title: tr('Шт', 'Dona'),
                  key: 'qty',
                  width: 100,
                  render: (_, it) => (
                    <InputNumber<string>
                      stringMode
                      min="0"
                      value={qtys[it.n]}
                      onChange={(v) => setQtys((q) => ({ ...q, [it.n]: v ?? '' }))}
                      style={{ width: '100%' }}
                    />
                  ),
                },
              ]}
            />
          </>
        )}
      </Modal>
      <NewProductModal
        open={!!creating}
        withLine={false}
        init={creating ? { name: creating.name, barcode: creating.barcode || undefined, brand_id: creating.brand_id, category_id: creating.category_id } : undefined}
        onClose={() => setCreating(null)}
        onCreated={(p) => {
          if (!creating) return
          const n = creating.n
          setCreated((c) => ({
            ...c,
            [n]: { product_id: p.id, name: p.name, image: p.images?.[0] ?? null, unit_short: p.unit_short, current_price: p.base_price, barcode: p.barcodes?.[0] ?? null, score: 0 },
          }))
          setChoice((c) => ({ ...c, [n]: p.id }))
          message.success(tr('Товар создан — он на проверке, но в список его добавить можно', 'Mahsulot yaratildi — u tekshiruvda, lekin uni roʻyxatga qoʻshish mumkin'))
        }}
      />
    </>
  )
}

/** Сумма для подписей: «18 450 000 сум». */
export const sum = (v: string | null | undefined) => `${money(v)} ${tr('сум', 'soʻm')}`
