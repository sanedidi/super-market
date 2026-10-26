// Товары: только «Мои товары» магазина — те, что есть у него (scope=mine).
// Центральная база видна только в поиске при добавлении («Начало работы»,
// приход, установка цен); свои товары сети уходят на модерацию.
import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Alert, Button, Card, Col, Form, Input, Modal, Radio, Row, Select, Space, Table, Tabs, Tag, Tooltip, Typography, type TableColumnType } from 'antd'
import { InfoCircleOutlined, PlusOutlined } from '@ant-design/icons'
import { DeleteButton, FormTranslate, ImageUpload, LoadError, PageTitle, ProductTree, ProductViewSwitch, RemoteSelect, api, getLang, interactive, money, tr, useAction, usePaged, useProductView } from '@sm/shared'
import { useStore } from '../ctx'
import { Num } from '../ui'
import type { DictItem, Product } from '../types'
import { FlavorMenu, childrenOf, useVariantGroups, variantNameCell, variantPriceCell, variantStockCell, type VRow } from './variants'
import { OwnVariantsTab, useOwnGroups } from './OwnVariants'
import { UnknownGoodsTab, useUnknownGoods, type UnknownGood } from './UnknownGoods'
import { NoBarcodeTab, ScalesTab, SellModeModal, useScaleCounts, type SellTarget } from './Scales'

type Tab = 'goods' | 'scales' | 'nobarcode' | 'variants' | 'unknown'
const TABS: Tab[] = ['goods', 'scales', 'nobarcode', 'variants', 'unknown']

/** Новый товар из «Без карточки»: название с кассы, штрихкод и цена. */
type Prefill = { name: string; barcode: string; price: string }

// Для редактирования API отдаёт ещё и сырые названия на обоих языках.
type ProductEdit = Product & { name_ru?: string; name_uz?: string; description_ru?: string; description_uz?: string }

function Moderation({ p }: { p: Product }) {
  if (!p.network_id) return <Tag color="green">{tr('Общий каталог', 'Umumiy katalog')}</Tag>
  if (p.moderation_status === 'pending') return <Tag color="orange">{tr('На модерации', 'Moderatsiyada')}</Tag>
  if (p.moderation_status === 'rejected')
    return (
      <Tooltip title={p.rejection_reason}>
        <Tag color="red">{tr('Отклонён', 'Rad etildi')}</Tag>
      </Tooltip>
    )
  return <Tag color="blue">{tr('Свой', 'Oʻziniki')}</Tag>
}

const priceSource: Record<string, string> = {
  store: tr('магазин', 'doʻkon'),
  network: tr('сеть', 'tarmoq'),
  base: tr('базовая', 'asosiy'),
}

const priceCell = (r: Product) =>
  r.price ? (
    <>
      {money(r.price)}
      {r.price_source && <Typography.Text type="secondary"> ({priceSource[r.price_source] ?? r.price_source})</Typography.Text>}
    </>
  ) : (
    '—'
  )

const barcodes = (v: string[] | null) => (v ?? []).join(', ') || '—'

/** Строка «загрузка группы» — на всю ширину таблицы. */
function spanLoading(cols: TableColumnType<VRow>[]): TableColumnType<VRow>[] {
  return cols.map((c, i) => ({ ...c, onCell: (r: VRow) => (r.kind === 'loading' ? { colSpan: i === 0 ? cols.length : 0 } : {}) }))
}

export function ProductsPage() {
  // Вкладки «Товары» и «Вариации» (Figma «Панель магазина · Вариации своих товаров», В1).
  // «На весах» и «Без штрихкода» (Figma «Панель · Весы и товары без штрихкода», В1, В3).
  const [search, setSearch] = useSearchParams()
  const qTab = search.get('tab') as Tab | null
  const [tab, setTabState] = useState<Tab>(qTab && TABS.includes(qTab) ? qTab : 'goods')
  const setTab = (t: Tab) => {
    setTabState(t)
    const next = new URLSearchParams(search)
    if (t === 'goods') next.delete('tab')
    else next.set('tab', t)
    setSearch(next, { replace: true })
  }
  const [sell, setSell] = useState<SellTarget | null>(null)
  const proposed = useOwnGroups('proposed', 1).data?.counts.proposed ?? 0
  const { storeId, can } = useStore()
  // «Без карточки» (Figma ПБ1): что касса продала неизвестным товаром.
  const seeUnknown = can('catalog.manage') || can('prices.manage') || can('reports.view')
  const unknown = useUnknownGoods(storeId || undefined, seeUnknown).data?.length ?? 0
  const counts = useScaleCounts(storeId || undefined, seeUnknown).data
  const [prefill, setPrefill] = useState<Prefill | null>(null)
  const [q, setQ] = useState('')
  const [categoryId, setCategoryId] = useState<string>()
  const [editing, setEditing] = useState<ProductEdit | null>(null)
  const [open, setOpen] = useState(false)
  const [view, setView] = useProductView()
  const [expanded, setExpanded] = useState<string[]>([])
  const params = {
    q: q || undefined,
    category_id: categoryId,
    store_id: storeId || undefined,
    scope: 'mine',
  }
  const list = usePaged<Product>(view === 'list' ? '/store/products' : null, params)
  const manage = can('catalog.manage')
  const prices = can('prices.manage')
  const variants = useVariantGroups(storeId)
  const rows = variants.build(list.items)
  const hasGroups = rows.some((r) => r.kind === 'group')

  const price: TableColumnType<VRow> = {
    title: tr('Цена в магазине', 'Doʻkondagi narx'),
    key: 'price',
    align: 'right',
    render: (_, r) => (r.kind === 'product' ? priceCell(r.product) : variantPriceCell(r, variants, prices)),
  }
  const unit: TableColumnType<VRow> = {
    title: tr('Ед.', 'Birl.'),
    key: 'unit',
    render: (_, r) => (r.kind === 'product' ? r.product.unit_short : r.kind === 'flavor' ? (r.product?.unit_short ?? tr('шт', 'dona')) : null),
  }
  const barcode: TableColumnType<VRow> = {
    title: tr('Штрихкод', 'Shtrix-kod'),
    key: 'barcodes',
    render: (_, r) => (r.kind === 'product' ? barcodes(r.product.barcodes) : r.kind === 'flavor' ? r.item.barcode || '—' : r.kind === 'weight' ? '—' : null),
  }
  // У строк группы вариаций вместо статуса каталога — остаток по варианту.
  const status = (title: string): TableColumnType<VRow> => ({
    title,
    key: 'mod',
    render: (_, r) => (r.kind === 'product' ? <Moderation p={r.product} /> : variantStockCell(r)),
  })
  const editCol: TableColumnType<VRow> = {
    key: 'edit',
    width: 320,
    align: 'right',
    render: (_, row) => {
      if (row.kind === 'flavor') return prices ? <FlavorMenu r={row} v={variants} /> : null
      if (row.kind !== 'product') return null
      const r = row.product
      const sellBtn = (
        <Tooltip title={tr('Штучно или на развес, номер на весах, штрихкод', 'Donalab yoki tortib, tarozi raqami, shtrix-kod')}>
          <Button size="small" onClick={() => setSell({ id: r.id, name: r.name, price: r.price ?? undefined })}>
            {tr('Как продаётся', 'Qanday sotiladi')}
          </Button>
        </Tooltip>
      )
      if (manage && !r.network_id) return sellBtn
      return manage && r.network_id ? (
        <Space size={8}>
          {sellBtn}
          <Button
            size="small"
            onClick={() => {
              setEditing(r)
              setOpen(true)
            }}
          >
            {tr('Изменить', 'Tahrirlash')}
          </Button>
          <DeleteButton
            path={`/store/products/${r.id}`}
            name={r.name}
            deactivate={() => api.patch(`/store/products/${r.id}`, { is_active: false })}
          />
        </Space>
      ) : null
    },
  }
  // Дерево: бренд и категория — в группах, поэтому в строке товара их нет.
  const treeColumns = spanLoading([
    {
      title: tr('Бренд · категория · товар', 'Brend · kategoriya · mahsulot'),
      key: 'name',
      render: (_, r) =>
        r.kind === 'product' ? (
          <>
            {r.product.name}
            {!r.product.is_active && <Tag style={{ marginLeft: 6 }}>{tr('Отключён', 'Oʻchirilgan')}</Tag>}
          </>
        ) : (
          variantNameCell(r)
        ),
    },
    unit,
    price,
    barcode,
    status(tr('Каталог / остаток', 'Katalog / qoldiq')),
    editCol,
  ])
  const listColumns = spanLoading([
    {
      title: tr('Товар', 'Mahsulot'),
      key: 'name',
      render: (_, row) => {
        if (row.kind !== 'product') return variantNameCell(row)
        const r = row.product
        return (
          <>
            {r.name}
            {r.brand_name && <Typography.Text type="secondary"> · {r.brand_name}</Typography.Text>}
            {!r.is_active && <Tag style={{ marginLeft: 6 }}>{tr('Отключён', 'Oʻchirilgan')}</Tag>}
          </>
        )
      },
    },
    barcode,
    { title: tr('Категория', 'Kategoriya'), key: 'category', render: (_, r) => (r.kind === 'product' ? r.product.category_name : null) },
    unit,
    {
      title: tr('Базовая цена', 'Asosiy narx'),
      key: 'base_price',
      align: 'right',
      render: (_, r) => (r.kind === 'product' ? money(r.product.base_price) : r.kind === 'flavor' && r.product ? money(r.product.base_price) : null),
    },
    price,
    status(hasGroups ? tr('Каталог / остаток', 'Katalog / qoldiq') : tr('Каталог', 'Katalog')),
    editCol,
  ])
  const toggle = (r: VRow) => {
    const willOpen = !expanded.includes(r.id)
    setExpanded((e) => (willOpen ? [...e, r.id] : e.filter((x) => x !== r.id)))
    if (willOpen && r.kind === 'group') variants.load(r.groupId)
  }

  return (
    <>
      <PageTitle
        title={tr('Товары', 'Mahsulotlar')}
        tabs={
          <Tabs
            activeKey={tab}
            onChange={(k) => setTab(k as Tab)}
            items={[
              { key: 'goods', label: tr('Товары', 'Mahsulotlar') },
              ...(seeUnknown
                ? [
                    {
                      key: 'scales',
                      label: (
                        <span>
                          {tr('На весах', 'Tarozida')}
                          {!!counts?.scales && (
                            <Tag color={counts.to_update > 0 ? 'orange' : undefined} bordered={false} style={{ marginLeft: 6, marginInlineEnd: 0 }}>
                              {counts.scales}
                            </Tag>
                          )}
                        </span>
                      ),
                    },
                    {
                      key: 'nobarcode',
                      label: (
                        <span>
                          {tr('Без штрихкода', 'Shtrix-kodsiz')}
                          {!!counts?.no_barcode && <Tag bordered={false} style={{ marginLeft: 6, marginInlineEnd: 0 }}>{counts.no_barcode}</Tag>}
                        </span>
                      ),
                    },
                  ]
                : []),
              {
                key: 'variants',
                label: (
                  <span>
                    {tr('Вариации', 'Variatsiyalar')}
                    {proposed > 0 && <Tag color="purple" bordered={false} style={{ marginLeft: 6, marginInlineEnd: 0 }}>{proposed}</Tag>}
                  </span>
                ),
              },
              ...(seeUnknown
                ? [
                    {
                      key: 'unknown',
                      label: (
                        <span>
                          {tr('Без карточки', 'Kartochkasiz')}
                          {unknown > 0 && <Tag color="orange" bordered={false} style={{ marginLeft: 6, marginInlineEnd: 0 }}>{unknown}</Tag>}
                        </span>
                      ),
                    },
                  ]
                : []),
            ]}
          />
        }
        extra={
          manage &&
          tab === 'goods' && (
            <Button
              type="primary"
              icon={<PlusOutlined />}
              onClick={() => {
                setEditing(null)
                setPrefill(null)
                setOpen(true)
              }}
            >
              {tr('Свой товар', 'Oʻz mahsulotingiz')}
            </Button>
          )
        }
      >
        {tab === 'goods' && (
          <>
            <Input.Search placeholder={tr('Название или штрихкод', 'Nomi yoki shtrix-kod')} allowClear onSearch={setQ} style={{ width: 240 }} />
            <RemoteSelect<DictItem> path="/store/catalog/categories" value={categoryId} onChange={setCategoryId} allowClear placeholder={tr('Все категории', 'Barcha kategoriyalar')} />
            <ProductViewSwitch value={view} onChange={setView} />
          </>
        )}
      </PageTitle>
      {tab === 'scales' ? (
        <ScalesTab onOpen={setSell} />
      ) : tab === 'nobarcode' ? (
        <NoBarcodeTab onOpen={setSell} />
      ) : tab === 'unknown' ? (
        <UnknownGoodsTab
          onCreate={(g: UnknownGood) => {
            setEditing(null)
            setPrefill({ name: g.name, barcode: g.barcode, price: g.price_max })
            setOpen(true)
          }}
        />
      ) : tab === 'variants' ? (
        <OwnVariantsTab />
      ) : (
        <>
          <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
            {tr(
              'Только товары, которые есть в магазине. Новые попадают сюда сами — с приходом, инвентаризацией или установкой цен магазина.',
              'Faqat doʻkonda bor mahsulotlar. Yangilari bu yerga oʻzi tushadi — kirim, inventarizatsiya yoki doʻkon narxini belgilash bilan.',
            )}
          </Typography.Paragraph>
          {view === 'tree' ? (
            <ProductTree<Product, VRow>
              groupsPath="/store/products/groups"
              itemsPath="/store/products"
              params={params}
              columns={treeColumns}
              mapItems={variants.build}
              childrenOf={childrenOf}
              onExpandItem={(r, isOpen) => isOpen && r.kind === 'group' && variants.load(r.groupId)}
              pendingText={(n) => tr(`Свои на модерации: ${n}`, `Moderatsiyadagi oʻz mahsulotlar: ${n}`)}
            />
          ) : (
            <>
              <LoadError error={list.error} retry={() => list.refetch()} />
              <Card styles={{ body: { padding: 0 } }} className="sm-tree">
                <Table<VRow>
                  rowKey="id"
                  loading={list.isLoading || list.isFetching}
                  dataSource={rows}
                  scroll={{ x: true }}
                  pagination={list.pagination}
                  columns={listColumns}
                  rowClassName={(r) => `sm-variant-${r.kind}`}
                  onRow={(r) =>
                    r.kind === 'group' || r.kind === 'weight'
                      ? {
                          onClick: (e) => {
                            if (!interactive(e.target)) toggle(r)
                          },
                          style: { cursor: 'pointer' },
                        }
                      : {}
                  }
                  expandable={{ expandedRowKeys: expanded, onExpand: (_, r) => toggle(r), indentSize: 28 }}
                />
              </Card>
            </>
          )}
          <Typography.Paragraph type="secondary" style={{ marginTop: 12, fontSize: 12 }}>
            <InfoCircleOutlined />{' '}
            {tr(
              'В группе вариаций цена ставится на вес (объём, размер…) или на всю группу — все варианты её наследуют. «Своя цена» — в меню строки варианта. Остаток — по каждому варианту.',
              'Variatsiyalar guruhida narx vaznga (hajm, oʻlcham…) yoki butun guruhga qoʻyiladi — barcha variantlar uni oladi. «Oʻz narxi» — variant qatori menyusida. Qoldiq — har bir variant boʻyicha.',
            )}
          </Typography.Paragraph>
        </>
      )}
      <ProductModal open={open} editing={editing} prefill={prefill} onClose={() => setOpen(false)} />
      <SellModeModal target={sell} onClose={() => setSell(null)} />
    </>
  )
}

function ProductModal({ open, editing, prefill, onClose }: { open: boolean; editing: ProductEdit | null; prefill: Prefill | null; onClose: () => void }) {
  const { storeId } = useStore()
  const [form] = Form.useForm()
  const uzFirst = getLang() === 'uz'
  // Достаточно названия на одном из языков: пустое русское сервер заполнит узбекским.
  const nameRule = (other: string) => ({
    validator: (_: unknown, v?: string) =>
      v?.trim() || String(form.getFieldValue(other) ?? '').trim()
        ? Promise.resolve()
        : Promise.reject(new Error(tr('Обязательное поле', 'Majburiy maydon'))),
  })
  const nameRu = (
    <Col xs={24} md={12} key="name">
      <Form.Item name="name" label={tr('Название (рус.)', 'Nomi (ruscha)')} dependencies={['name_uz']} rules={uzFirst ? [] : [nameRule('name_uz')]}>
        <Input suffix={<FormTranslate form={form} from="name_uz" into="name" to="ru" />} />
      </Form.Item>
    </Col>
  )
  const nameUz = (
    <Col xs={24} md={12} key="name_uz">
      <Form.Item name="name_uz" label={tr('Название (узб.)', 'Nomi (oʻzbekcha)')} dependencies={['name']} rules={uzFirst ? [nameRule('name')] : []}>
        <Input suffix={<FormTranslate form={form} from="name" into="name_uz" to="uz" />} />
      </Form.Item>
    </Col>
  )
  const descRu = (
    <Col span={24} key="description">
      <Form.Item
        name="description"
        label={
          <Space size={4}>
            {tr('Описание (рус.)', 'Tavsif (ruscha)')}
            <FormTranslate form={form} from="description_uz" into="description" to="ru" />
          </Space>
        }
      >
        <Input.TextArea rows={3} />
      </Form.Item>
    </Col>
  )
  const descUz = (
    <Col span={24} key="description_uz">
      <Form.Item
        name="description_uz"
        label={
          <Space size={4}>
            {tr('Описание (узб.)', 'Tavsif (oʻzbekcha)')}
            <FormTranslate form={form} from="description" into="description_uz" to="uz" />
          </Space>
        }
      >
        <Input.TextArea rows={3} />
      </Form.Item>
    </Col>
  )
  const save = useAction(
    (v: Record<string, unknown>) => {
      const body = {
        ...v,
        // Пустое русское название не отправляем: сервер возьмёт узбекское.
        name: String(v.name ?? '').trim() || undefined,
        description: v.description ?? '',
        description_uz: v.description_uz ?? '',
        name_uz: v.name_uz ?? '',
        // Пустая строка убирает бренд или цвет у существующего товара.
        brand_id: v.brand_id ?? (editing ? '' : undefined),
        color_id: v.color_id ?? (editing ? '' : undefined),
        barcodes: v.barcodes ?? [],
        images: v.images ?? [],
      }
      // Новый товар сразу попадает в «Мои товары» текущего магазина.
      return editing ? api.patch(`/store/products/${editing.id}`, body) : api.post('/store/products', { ...body, store_id: storeId || undefined })
    },
    { success: editing ? tr('Сохранено', 'Saqlandi') : tr('Товар отправлен на модерацию', 'Mahsulot moderatsiyaga yuborildi') },
  )
  return (
    <Modal
      open={open}
      title={editing ? tr('Изменить товар', 'Mahsulotni tahrirlash') : tr('Свой товар', 'Oʻz mahsulotingiz')}
      okText={tr('Сохранить', 'Saqlash')}
      onOk={() => form.submit()}
      confirmLoading={save.isPending}
      onCancel={onClose}
      width={720}
      destroyOnHidden
      afterOpenChange={(v) => {
        if (!v) return
        form.resetFields()
        if (editing)
          form.setFieldsValue({
            name: editing.name_ru ?? editing.name,
            name_uz: editing.name_uz ?? '',
            description: editing.description_ru ?? editing.description,
            description_uz: editing.description_uz ?? '',
            brand_id: editing.brand_id ?? undefined,
            category_id: editing.category_id,
            unit_id: editing.unit_id,
            color_id: editing.color_id ?? undefined,
            base_price: editing.base_price,
            barcodes: editing.barcodes ?? [],
            images: editing.images ?? [],
            is_active: editing.is_active,
          })
        else if (prefill)
          form.setFieldsValue({
            [uzFirst ? 'name_uz' : 'name']: prefill.name || undefined,
            barcodes: [prefill.barcode],
            base_price: prefill.price,
          })
      }}
    >
      {!editing && prefill && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message={tr(
            `Штрихкод ${prefill.barcode} продан на кассе без карточки. Название и цена — с кассы, проверьте их.`,
            `${prefill.barcode} shtrix-kodi kassada kartochkasiz sotilgan. Nomi va narxi — kassadan, tekshiring.`,
          )}
        />
      )}
      {!editing && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message={tr(
            'Товар сразу доступен вашей сети, а после проверки администратором попадёт в общий каталог.',
            'Mahsulot tarmogʻingizda darhol mavjud boʻladi, administrator tekshirganidan keyin esa umumiy katalogga qoʻshiladi.',
          )}
        />
      )}
      {editing?.moderation_status === 'rejected' && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message={tr(`Отклонён: ${editing.rejection_reason}`, `Rad etildi: ${editing.rejection_reason}`)}
          description={tr('После сохранения товар снова уйдёт на модерацию.', 'Saqlangandan soʻng mahsulot yana moderatsiyaga yuboriladi.')}
        />
      )}
      <Form form={form} layout="vertical" preserve={false} onFinish={(v) => save.mutate(v, { onSuccess: onClose })}>
        <Row gutter={16}>
          {uzFirst ? [nameUz, nameRu] : [nameRu, nameUz]}
          <Col xs={24} md={8}>
            <Form.Item name="base_price" label={tr('Базовая цена', 'Asosiy narx')} rules={[{ required: true, message: tr('Укажите цену', 'Narxni kiriting') }]}>
              <Num />
            </Form.Item>
          </Col>
          <Col xs={24} md={8}>
            <Form.Item name="category_id" label={tr('Категория', 'Kategoriya')} rules={[{ required: true, message: tr('Выберите категорию', 'Kategoriyani tanlang') }]}>
              <RemoteSelect<DictItem> path="/store/catalog/categories" />
            </Form.Item>
          </Col>
          <Col xs={24} md={8}>
            <Form.Item name="unit_id" label={tr('Единица', 'Oʻlchov birligi')} rules={[{ required: true, message: tr('Выберите единицу', 'Oʻlchov birligini tanlang') }]}>
              <RemoteSelect<DictItem> path="/store/catalog/units" label={(u) => `${u.name} (${u.short_name})`} />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="brand_id" label={tr('Бренд', 'Brend')}>
              <RemoteSelect<DictItem> path="/store/catalog/brands" allowClear />
            </Form.Item>
          </Col>
          <Col xs={24} md={12}>
            <Form.Item name="color_id" label={tr('Цвет', 'Rang')}>
              <RemoteSelect<DictItem> path="/store/catalog/colors" allowClear />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item name="barcodes" label={tr('Штрихкоды', 'Shtrix-kodlar')} extra={tr('Введите и нажмите Enter', 'Kiriting va Enter tugmasini bosing')}>
              <Select mode="tags" tokenSeparators={[',', ' ']} open={false} />
            </Form.Item>
          </Col>
          <Col span={24}>
            <Form.Item
              name="images"
              label={tr('Фото', 'Rasm')}
              extra={tr('До 10 фото, первое — главное. JPG, PNG, WEBP до 8 МБ', '10 tagacha rasm, birinchisi — asosiy. JPG, PNG, WEBP, 8 MB gacha')}
            >
              <ImageUpload multiple max={10} />
            </Form.Item>
          </Col>
          {uzFirst ? [descUz, descRu] : [descRu, descUz]}
          {editing && (
            <Col span={24}>
              <Form.Item name="is_active" label={tr('Статус', 'Holat')}>
                <Radio.Group options={[
                    { value: true, label: tr('Активен', 'Faol') },
                    { value: false, label: tr('Отключён', 'Oʻchirilgan') },
                  ]} />
              </Form.Item>
            </Col>
          )}
        </Row>
      </Form>
    </Modal>
  )
}
