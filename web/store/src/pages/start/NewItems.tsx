// Новый товар по фото (Figma «Панель магазина · новый товар по фото», В1;
// «SM Магазин» Р1–Р5). Товара нет ни в базе, ни в каталоге ИКПУ — магазин
// отправляет фото и работает дальше; Super Market в фоне заполняет карточку.
// Вкладка «Новые от Super Market»: распознаётся / проверить / не удалось.
// Только после «Подтвердить и добавить» товар создаётся (свой, draft) и
// встаёт в «Мои товары»; на модерацию — при «Записать и закрыть».
import { useEffect, useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Col, Flex, Form, Input, Modal, Row, Space, Spin, Tag, Typography } from 'antd'
import { CheckOutlined, DeleteOutlined, FolderAddOutlined, PlusOutlined, ReloadOutlined, StarFilled, TagsOutlined } from '@ant-design/icons'
import { ApiError, FormTranslate, ImageUpload, RemoteSelect, api, errorText, getLang, tr } from '@sm/shared'
import { useStore } from '../../ctx'
import type { DictItem } from '../../types'
import { useStartRefresh, type CategoryRef, type CategorySuggestion, type NewCategory, type NewItem, type NewItemConfirmResult, type NewItemList } from './api'
import { Thumb } from './Thumb'

const PURPLE = '#6938EF'

/** Очередь «Новые» магазина; пока что-то распознаётся — обновляется сама. */
export function useNewItems(storeId: string) {
  return useQuery({
    queryKey: ['/store/start/new-items', storeId],
    queryFn: () => api.get<NewItemList>('/store/start/new-items', { store_id: storeId }),
    refetchInterval: (q) => ((q.state.data?.counts.processing ?? 0) > 0 ? 3000 : false),
  })
}

/** Заголовок-вкладка правой колонки: «Мои товары · N» | «Новые от Super Market · M». */
export function RightTabs({ tab, onTab, mine, fresh, ready }: { tab: 'mine' | 'new'; onTab: (t: 'mine' | 'new') => void; mine: number; fresh: number; ready: boolean }) {
  const item = (key: 'mine' | 'new', label: ReactNode) => (
    <span
      role="button"
      onClick={() => onTab(key)}
      style={{ cursor: 'pointer', fontWeight: tab === key ? 800 : 600, color: tab === key ? '#101828' : '#667085', fontSize: 15, display: 'inline-flex', alignItems: 'center', gap: 6 }}
    >
      {label}
    </span>
  )
  return (
    <Flex gap={18} align="center" wrap>
      {item('mine', `${tr('Мои товары', 'Mahsulotlarim')} · ${mine}`)}
      {(fresh > 0 || tab === 'new') &&
        item(
          'new',
          <>
            {tr('Новые от Super Market', 'Super Market yangilari')} · {fresh}
            {ready && <span style={{ width: 8, height: 8, borderRadius: 4, background: '#E11D2A', display: 'inline-block' }} />}
          </>,
        )}
    </Flex>
  )
}

/** В1: очередь «Новые от Super Market». */
export function NewItemsList({ list, loading }: { list: NewItemList | undefined; loading: boolean }) {
  const [open, setOpen] = useState<NewItem | null>(null)
  const items = list?.items ?? []
  return (
    <>
      <Flex gap={10} style={{ padding: '10px 20px', background: '#F4F3FF' }}>
        <StarFilled style={{ color: PURPLE, marginTop: 3 }} />
        <Typography.Text style={{ fontSize: 13, color: '#3E1C96' }}>
          {tr(
            'Фото новых товаров из «SM Магазин» и кнопки «Новый товар». Super Market заполняет карточку, вы проверяете — только после подтверждения товар встаёт в «Мои товары».',
            '«SM Магазин» va «Yangi mahsulot» tugmasidan yangi mahsulotlar rasmlari. Super Market kartochkani toʻldiradi, siz tekshirasiz — faqat tasdiqlangandan soʻng mahsulot «Mahsulotlarim»ga tushadi.',
          )}
        </Typography.Text>
      </Flex>
      {loading && !list ? (
        <Flex justify="center" style={{ padding: 24 }}>
          <Spin />
        </Flex>
      ) : items.length === 0 ? (
        <Typography.Paragraph type="secondary" style={{ padding: '20px', margin: 0 }}>
          {tr('Пока пусто. Нет товара ни в базе, ни в каталоге ИКПУ — нажмите «Новый товар» и отправьте фото.', 'Hozircha boʻsh. Mahsulot na bazada, na MXIK katalogida boʻlsa — «Yangi mahsulot»ni bosing va rasm yuboring.')}
        </Typography.Paragraph>
      ) : (
        items.map((it) => (
          <Flex key={it.id} align="center" gap={14} style={{ padding: '12px 20px', borderBottom: '1px solid #EAECF0' }}>
            <Thumb src={it.images[0]} size={48} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <Typography.Text strong style={{ display: 'block', fontWeight: 600, color: it.status === 'processing' ? '#667085' : undefined }}>
                {it.status === 'processing' ? tr('Распознаётся…', 'Aniqlanmoqda…') : it.status === 'ready' ? it.result?.name : tr('Не удалось распознать', 'Aniqlab boʻlmadi')}
              </Typography.Text>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {[
                  it.barcode || tr('без штрихкода', 'shtrix-kodsiz'),
                  it.status === 'ready' && it.result?.suggestion?.category ? catText(it.result.suggestion.category) : null,
                  it.status === 'failed' ? it.error : it.status === 'processing' ? tr(`${it.images.length} фото · ~1 мин`, `${it.images.length} ta rasm · ~1 daq`) : null,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </Typography.Text>
            </div>
            {it.status === 'processing' ? (
              <Tag color="purple" bordered={false} style={{ marginInlineEnd: 0 }}>
                <Spin size="small" /> Super Market
              </Tag>
            ) : it.status === 'ready' ? (
              <Button type="primary" size="small" onClick={() => setOpen(it)}>
                {tr('Проверить', 'Tekshirish')}
              </Button>
            ) : (
              <Button size="small" onClick={() => setOpen(it)}>
                {tr('Заполнить', 'Toʻldirish')}
              </Button>
            )}
          </Flex>
        ))
      )}
      <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', padding: '12px 20px 14px' }}>
        {tr('Новые товары уйдут на проверку в общую базу после «Записать и закрыть» на шаге 2.', 'Yangi mahsulotlar 2-qadamdagi «Yozish va yopish»dan soʻng umumiy bazaga tekshiruvga yuboriladi.')}
      </Typography.Text>
      <ReviewModal item={open} onClose={() => setOpen(null)} />
    </>
  )
}

const catText = (c: { section: string; section_uz: string; name: string; name_uz: string }) =>
  getLang() === 'uz' ? `${c.section_uz || c.section} › ${c.name_uz || c.name}` : `${c.section} › ${c.name}`

// ------------------------------------------------------ «Новый товар» по фото

/** «Новый товар»: фото → Super Market (по умолчанию) или ручная форма. */
export function NewByPhotoModal({ open, onClose, onSent, onManual }: { open: boolean; onClose: () => void; onSent: () => void; onManual: () => void }) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [images, setImages] = useState<string[]>([])
  const [barcode, setBarcode] = useState('')
  const [sending, setSending] = useState(false)
  useEffect(() => {
    if (open) {
      setImages([])
      setBarcode('')
    }
  }, [open])
  const send = async () => {
    setSending(true)
    try {
      const it = await api.post<NewItem>('/store/start/new-items', { store_id: storeId, images, barcode: barcode.trim() || undefined })
      message.success(
        it.status === 'failed'
          ? tr('Фото сохранены — заполните карточку во вкладке «Новые»', 'Rasmlar saqlandi — kartochkani «Yangilar» boʻlimida toʻldiring')
          : tr('Отправлено Super Market — карточка будет готова через минуту во вкладке «Новые»', 'Super Market’ga yuborildi — kartochka bir daqiqada «Yangilar» boʻlimida tayyor boʻladi'),
      )
      await refresh()
      onSent()
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSending(false)
    }
  }
  return (
    <Modal
      open={open}
      title={tr('Новый товар', 'Yangi mahsulot')}
      onCancel={onClose}
      destroyOnHidden
      footer={
        <Flex justify="space-between" align="center">
          <Button type="link" style={{ padding: 0 }} onClick={onManual}>
            {tr('Заполнить вручную', 'Qoʻlda toʻldirish')}
          </Button>
          <Space>
            <Button onClick={onClose}>{tr('Отмена', 'Bekor qilish')}</Button>
            <Button type="primary" icon={<StarFilled />} disabled={images.length === 0} loading={sending} onClick={send}>
              {tr('Отправить Super Market', 'Super Market’ga yuborish')}
            </Button>
          </Space>
        </Flex>
      }
    >
      <Typography.Paragraph type="secondary">
        {tr(
          'Сфотографируйте лицевую сторону и этикетку с составом и весом (до 3 фото). Super Market сам заполнит карточку — продолжайте работу, проверите её во вкладке «Новые».',
          'Old tomoni va tarkibi hamda ogʻirligi yozilgan yorligʻini suratga oling (3 tagacha). Super Market kartochkani oʻzi toʻldiradi — ishni davom ettiring, uni «Yangilar» boʻlimida tekshirasiz.',
        )}
      </Typography.Paragraph>
      <ImageUpload multiple max={3} value={images} onChange={setImages} />
      <Typography.Text strong style={{ display: 'block', margin: '12px 0 6px', fontSize: 13 }}>
        {tr('Штрихкод (если есть)', 'Shtrix-kod (boʻlsa)')}
      </Typography.Text>
      <Input value={barcode} onChange={(e) => setBarcode(e.target.value)} placeholder="4780098765432" inputMode="numeric" />
    </Modal>
  )
}

// ------------------------------------------------------------ проверка (Р4)

type Choice = { category_id: string } | { new_category: NewCategory }

/** Р4: карточка, заполненная Super Market (или пустая — «не удалось»). */
function ReviewModal({ item, onClose }: { item: NewItem | null; onClose: () => void }) {
  const { storeId } = useStore()
  const { message, modal } = App.useApp()
  const refresh = useStartRefresh()
  const [form] = Form.useForm()
  const [saving, setSaving] = useState<'' | 'confirm' | 'match' | 'retry' | 'delete'>('')
  const [choice, setChoice] = useState<Choice | null>(null)
  const res = item?.result ?? null

  useEffect(() => {
    if (!item) return
    const r = item.result
    form.resetFields()
    form.setFieldsValue({
      name: r?.name,
      name_uz: r?.name_uz,
      brand_id: r?.brand_id ?? undefined,
      brand_name: r?.brand_id ? '' : (r?.brand ?? ''),
      unit_id: r?.unit_id || undefined,
      barcode: item.barcode,
      images: item.images,
      description: r?.description ?? '',
    })
    setChoice(null)
  }, [item, form])

  const done = async (r: NewItemConfirmResult) => {
    message.success(tr(`${r.line.name} — в «Моих товарах»`, `${r.line.name} — «Mahsulotlarim»da`))
    await refresh()
    onClose()
  }
  const fail = async (e: unknown) => {
    if (e instanceof ApiError && e.code === 'already_added') {
      message.warning(tr('Товар уже добавлен', 'Mahsulot allaqachon qoʻshilgan'))
      await refresh()
      onClose()
    } else message.error(errorText(e))
  }

  const confirm = async (v: Record<string, unknown>) => {
    if (!item || !choice) return
    setSaving('confirm')
    try {
      const r = await api.post<NewItemConfirmResult>(`/store/start/new-items/${item.id}/confirm`, {
        store_id: storeId,
        name: String(v.name ?? '').trim(),
        name_uz: String(v.name_uz ?? '').trim(),
        description: String(v.description ?? '').trim(),
        brand_id: v.brand_id || undefined,
        brand_name: !v.brand_id && String(v.brand_name ?? '').trim() ? String(v.brand_name).trim() : undefined,
        unit_id: v.unit_id,
        barcode: String(v.barcode ?? '').trim(),
        images: (v.images as string[]) ?? [],
        ...choice,
      })
      await done(r)
    } catch (e) {
      await fail(e)
    } finally {
      setSaving('')
    }
  }
  const useMatch = async () => {
    if (!item || !res?.match) return
    setSaving('match')
    try {
      await done(await api.post<NewItemConfirmResult>(`/store/start/new-items/${item.id}/confirm`, { store_id: storeId, product_id: res.match.product_id }))
    } catch (e) {
      await fail(e)
    } finally {
      setSaving('')
    }
  }
  const retry = async () => {
    if (!item) return
    setSaving('retry')
    try {
      await api.post(`/store/start/new-items/${item.id}/retry`)
      message.info(tr('Super Market распознаёт заново', 'Super Market qayta aniqlamoqda'))
      await refresh()
      onClose()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setSaving('')
    }
  }
  const remove = () =>
    modal.confirm({
      title: tr('Убрать карточку?', 'Kartochkani olib tashlaysizmi?'),
      content: tr('Товар не будет создан.', 'Mahsulot yaratilmaydi.'),
      okText: tr('Убрать', 'Olib tashlash'),
      okButtonProps: { danger: true },
      cancelText: tr('Отмена', 'Bekor qilish'),
      onOk: async () => {
        if (!item) return
        try {
          await api.del(`/store/start/new-items/${item.id}`)
          await refresh()
          onClose()
        } catch (e) {
          message.error(errorText(e))
        }
      },
    })

  const failed = item?.status === 'failed'
  return (
    <Modal
      open={!!item}
      width={680}
      title={failed ? tr('Заполните карточку', 'Kartochkani toʻldiring') : tr('Проверьте карточку', 'Kartochkani tekshiring')}
      onCancel={onClose}
      destroyOnHidden
      footer={
        <Flex justify="space-between" align="center">
          <Button type="text" danger icon={<DeleteOutlined />} onClick={remove}>
            {tr('Убрать', 'Olib tashlash')}
          </Button>
          <Space>
            <Button onClick={onClose}>{tr('Отмена', 'Bekor qilish')}</Button>
            <Button type="primary" icon={<PlusOutlined />} loading={saving === 'confirm'} disabled={!choice} onClick={() => form.submit()}>
              {tr('Подтвердить и добавить', 'Tasdiqlash va qoʻshish')}
            </Button>
          </Space>
        </Flex>
      }
    >
      {item && (
        <Flex vertical gap={14}>
          {failed ? (
            <Alert
              type="warning"
              showIcon
              message={item.error || tr('Super Market не смог распознать фото', 'Super Market rasmni aniqlay olmadi')}
              action={
                <Button size="small" icon={<ReloadOutlined />} loading={saving === 'retry'} onClick={retry}>
                  {tr('Распознать заново', 'Qayta aniqlash')}
                </Button>
              }
            />
          ) : (
            <Flex gap={8} align="center" style={{ background: '#EEF4FF', borderRadius: 10, padding: '8px 12px' }}>
              <StarFilled style={{ color: '#3B6FD8' }} />
              <Typography.Text style={{ fontSize: 13, color: '#18497A' }}>
                {tr(`Super Market заполнил по ${item.images.length} фото — проверьте название и категорию`, `Super Market ${item.images.length} ta rasm boʻyicha toʻldirdi — nomi va kategoriyani tekshiring`)}
              </Typography.Text>
            </Flex>
          )}
          {res?.match && (
            <Flex vertical gap={8} style={{ background: '#FFF7D6', borderRadius: 12, padding: 12 }}>
              <Typography.Text strong style={{ color: '#7A2E0E' }}>
                {tr('Похоже, такой товар уже есть в базе', 'Bunday mahsulot bazada allaqachon borga oʻxshaydi')}
              </Typography.Text>
              <Flex align="center" gap={10}>
                <Thumb src={res.match.image} size={40} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <Typography.Text strong style={{ display: 'block', fontWeight: 600 }}>
                    {res.match.name}
                  </Typography.Text>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {[res.match.own ? tr('свой товар', 'oʻz mahsulot') : tr('центральная база', 'markaziy baza'), res.match.barcode].filter(Boolean).join(' · ')}
                  </Typography.Text>
                </div>
                <Button type="primary" icon={<CheckOutlined />} loading={saving === 'match'} onClick={useMatch}>
                  {tr('Это он', 'Shu')}
                </Button>
              </Flex>
            </Flex>
          )}
          <Form form={form} layout="vertical" onFinish={confirm} requiredMark={false}>
            <Form.Item name="images" label={tr('Фото', 'Rasm')} style={{ marginBottom: 12 }}>
              <ImageUpload multiple max={5} />
            </Form.Item>
            <Row gutter={12}>
              <Col span={24}>
                <Form.Item name="name" label={tr('Название', 'Nomi (rus tilida)')} rules={[{ required: true, whitespace: true, message: tr('Обязательное поле', 'Majburiy maydon') }]}>
                  <Input suffix={<FormTranslate form={form} from="name_uz" into="name" to="ru" />} />
                </Form.Item>
              </Col>
              <Col span={24}>
                <Form.Item name="name_uz" label={tr('Название по-узбекски', 'Nomi')}>
                  <Input suffix={<FormTranslate form={form} from="name" into="name_uz" to="uz" />} />
                </Form.Item>
              </Col>
              <Col xs={24} md={12}>
                <Form.Item name="brand_id" label={tr('Бренд', 'Brend')}>
                  <RemoteSelect<DictItem> path="/store/catalog/brands" search allowClear placeholder={tr('Выберите или впишите ниже', 'Tanlang yoki pastda yozing')} />
                </Form.Item>
              </Col>
              <Col xs={24} md={12}>
                <Form.Item noStyle shouldUpdate={(a, b) => a.brand_id !== b.brand_id}>
                  {() =>
                    form.getFieldValue('brand_id') ? null : (
                      <Form.Item name="brand_name" label={tr('Новый бренд', 'Yangi brend')} extra={tr('Если бренда нет в списке — добавится', 'Roʻyxatda boʻlmasa — qoʻshiladi')}>
                        <Input />
                      </Form.Item>
                    )
                  }
                </Form.Item>
              </Col>
              <Col xs={24} md={12}>
                <Form.Item name="unit_id" label={tr('Единица', 'Oʻlchov birligi')} rules={[{ required: true, message: tr('Выберите единицу', 'Oʻlchov birligini tanlang') }]}>
                  <RemoteSelect<DictItem & { short_name: string }> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} />
                </Form.Item>
              </Col>
              <Col xs={24} md={12}>
                <Form.Item name="barcode" label={tr('Штрихкод', 'Shtrix-kod')}>
                  <Input inputMode="numeric" />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name="description" hidden>
              <Input />
            </Form.Item>
          </Form>
          <CategoryChooser suggestion={res?.suggestion ?? null} onChange={setChoice} />
        </Flex>
      )}
    </Modal>
  )
}

// ------------------------------------------------------------ категория

/**
 * Категория для нового товара: предложение Super Market (из базы — можно
 * сменить; новая — можно переименовать) или выбор из списка.
 */
export function CategoryChooser({ suggestion: s, onChange }: { suggestion: CategorySuggestion | null; onChange: (c: Choice | null) => void }) {
  const [mode, setMode] = useState<'suggest' | 'new' | 'pick'>('pick')
  const [chosen, setChosen] = useState<CategoryRef | null>(null)
  const [others, setOthers] = useState<CategoryRef[]>([])
  const [nc, setNc] = useState<NewCategory | null>(null)
  const [picked, setPicked] = useState<string | undefined>()
  const [edit, setEdit] = useState(false)
  useEffect(() => {
    setChosen(s?.category ?? null)
    setOthers(s?.alternatives ?? [])
    setNc(s?.new ?? null)
    setMode(s?.category ? 'suggest' : s?.new ? 'new' : 'pick')
    setPicked(undefined)
    setEdit(false)
  }, [s])
  useEffect(() => {
    if (mode === 'suggest' && chosen) onChange({ category_id: chosen.id })
    else if (mode === 'new' && nc && nc.name.trim()) onChange({ new_category: nc })
    else if (mode === 'pick' && picked) onChange({ category_id: picked })
    else onChange(null)
  }, [mode, chosen, nc, picked, onChange])

  return (
    <div>
      <Flex align="center" gap={8} style={{ marginBottom: 6 }}>
        <Typography.Text strong style={{ fontSize: 13, color: '#344054' }}>
          {tr('Категория', 'Kategoriya')} <span style={{ color: '#E11D2A' }}>*</span>
        </Typography.Text>
        {s && mode !== 'pick' && (
          <Tag color="purple" bordered={false} style={{ fontWeight: 700, marginInlineEnd: 0 }}>
            <StarFilled /> {tr('Предложил Super Market', 'Super Market taklif qildi')}
          </Tag>
        )}
      </Flex>
      {mode === 'suggest' && chosen && (
        <>
          <Flex align="center" gap={12} style={{ border: '1.5px solid #84ADFF', borderRadius: 10, padding: '10px 14px' }}>
            <TagsOutlined style={{ color: '#1570EF', fontSize: 18 }} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <Typography.Text strong style={{ display: 'block' }}>
                {chosen.section} › {chosen.name}
              </Typography.Text>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {chosen.section_uz || chosen.section} › {chosen.name_uz || chosen.name}
              </Typography.Text>
            </div>
            <Button type="link" style={{ padding: 0, fontWeight: 700 }} onClick={() => setMode('pick')}>
              {tr('Изменить', 'Oʻzgartirish')}
            </Button>
          </Flex>
          {others.length > 0 && (
            <Flex align="center" gap={6} wrap style={{ marginTop: 8 }}>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {tr('Ещё подходят:', 'Yana mos keladi:')}
              </Typography.Text>
              {others.map((o) => (
                <Tag
                  key={o.id}
                  bordered={false}
                  style={{ cursor: 'pointer', fontWeight: 600 }}
                  onClick={() => {
                    setOthers((list) => [...list.filter((x) => x.id !== o.id), chosen])
                    setChosen(o)
                  }}
                >
                  {catText(o)}
                </Tag>
              ))}
            </Flex>
          )}
        </>
      )}
      {mode === 'new' && nc && (
        <>
          <Flex align="start" gap={12} style={{ border: '1.5px dashed #9B8AFB', background: '#F9F8FF', borderRadius: 10, padding: '10px 14px' }}>
            <FolderAddOutlined style={{ color: PURPLE, fontSize: 18, marginTop: 2 }} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <Flex align="center" justify="space-between" gap={8}>
                <Typography.Text strong>
                  {nc.parent_name} › {nc.name}
                </Typography.Text>
                <Tag color="success" bordered={false} style={{ marginInlineEnd: 0 }}>
                  {tr('новая', 'yangi')}
                </Tag>
              </Flex>
              <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block' }}>
                {nc.parent_name_uz || nc.parent_name} › {nc.name_uz || nc.name}
              </Typography.Text>
              {edit ? (
                <Flex vertical gap={6} style={{ marginTop: 8 }}>
                  <Input size="small" addonBefore="ru" value={nc.name} maxLength={100} onChange={(e) => setNc({ ...nc, name: e.target.value })} />
                  <Input size="small" addonBefore="uz" value={nc.name_uz} maxLength={100} onChange={(e) => setNc({ ...nc, name_uz: e.target.value })} />
                </Flex>
              ) : (
                <Button type="link" size="small" style={{ padding: 0, fontWeight: 700 }} onClick={() => setEdit(true)}>
                  {tr('Изменить название', 'Nomini oʻzgartirish')}
                </Button>
              )}
            </div>
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 8 }}>
            {tr('Не подходит?', 'Mos emasmi?')}{' '}
            <a onClick={() => setMode('pick')} style={{ fontWeight: 700 }}>
              {tr('Выбрать существующую категорию', 'Mavjud kategoriyani tanlash')}
            </a>
          </Typography.Text>
        </>
      )}
      {mode === 'pick' && (
        <>
          <RemoteSelect<DictItem & { parent_name?: string | null }>
            path="/store/catalog/categories"
            search
            filter={(c) => !!c.parent_id}
            label={(c) => (c.parent_name ? `${c.parent_name} › ${c.name}` : c.name)}
            value={picked}
            onChange={(v) => setPicked(v as string)}
            placeholder={tr('Выберите категорию', 'Kategoriyani tanlang')}
            style={{ width: '100%' }}
          />
          {s && (s.category || s.new) && (
            <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 8 }}>
              <a onClick={() => setMode(s.category ? 'suggest' : 'new')} style={{ fontWeight: 700 }}>
                {tr('Вернуть предложение Super Market', 'Super Market taklifiga qaytish')}
              </a>
            </Typography.Text>
          )}
        </>
      )}
    </div>
  )
}
