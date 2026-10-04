// «Начало работы» (Figma W1/W2): магазин заводит товары, которые у него уже
// есть. Черновик общий с «SM Магазин»: фото полок, штрихкод (USB-сканер),
// каталог с галочками, поиск. «Проверить и провести» — оприходование на
// основной склад по закупочным ценам и установка цен магазина.
import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Alert, App, AutoComplete, Button, Card, Col, Flex, Input, InputNumber, Modal, Result, Row, Segmented, Space, Table, Typography, type InputRef } from 'antd'
import { CameraOutlined, CheckCircleOutlined, DeleteOutlined, PlusOutlined, ScanOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, money, plural, qty as fmtQty, useDebounced, useList, type List } from '@sm/shared'
import { useStore } from '../../ctx'
import { NeedStore } from '../../ui'
import { docPaths } from '../StockDocs'
import type { Product } from '../../types'
import { plainNum, useStartApi, type Draft, type Line, type LineInput, type PostResult } from './api'
import { CatalogTree, Thumb } from './CatalogTree'
import { BarcodeModal, NewProductModal, PhotoModal, sum } from './Modals'

const PAGE = 50
const goods = (n: number) => `${n} ${plural(n, 'товар', 'товара', 'товаров')}`

export function StartPage() {
  return (
    <NeedStore>
      <Start />
    </NeedStore>
  )
}

function Start() {
  const { storeId, can } = useStore()
  const { modal, message } = App.useApp()
  const { refresh } = useStartApi(storeId)
  const [only, setOnly] = useState<'' | 'no_cost' | 'new'>('')
  const [page, setPage] = useState(1)
  const [photoOpen, setPhotoOpen] = useState(false)
  const [newOpen, setNewOpen] = useState(false)
  const [result, setResult] = useState<PostResult | null>(null)
  useEffect(() => setPage(1), [only, storeId])

  const params = { store_id: storeId, only: only || undefined, limit: PAGE + 1, offset: (page - 1) * PAGE }
  const draft = useQuery({
    queryKey: ['/store/start', params],
    queryFn: () => api.get<Draft>('/store/start', params),
    placeholderData: keepPreviousData,
  })
  const d = draft.data
  const t = d?.totals

  const post = () => {
    if (!d || !t) return
    modal.confirm({
      title: `Провести ${goods(t.products)}?`,
      width: 520,
      okText: 'Провести',
      cancelText: 'Отмена',
      content: (
        <div>
          <Typography.Paragraph>
            Будут созданы <b>оприходование</b> на склад «{d.warehouse_name}» по закупочным ценам и <b>установка цен</b> магазина «{d.store_name}» —
            для товаров, где цена продажи изменена.
          </Typography.Paragraph>
          <Typography.Paragraph style={{ marginBottom: 0 }}>
            {fmtQty(t.qty)} шт · по закупке {sum(t.cost_total)} · по цене продажи {sum(t.price_total)}
          </Typography.Paragraph>
          {t.no_cost > 0 && (
            <Alert
              style={{ marginTop: 12 }}
              type="warning"
              showIcon
              message={`Без закупочной цены: ${goods(t.no_cost)}`}
              description="Их себестоимость будет 0 — прибыль по ним в отчётах будет завышена. Можно провести сейчас и поправить позже."
            />
          )}
          {t.pending > 0 && (
            <Alert
              style={{ marginTop: 12 }}
              type="info"
              showIcon
              message={`Новых товаров на проверке: ${t.pending}`}
              description="Они встанут на склад сразу, а покупатели увидят их после проверки."
            />
          )}
        </div>
      ),
      onOk: async () => {
        try {
          const r = await api.post<PostResult>('/store/start/post', { store_id: storeId })
          setResult(r)
          await refresh()
        } catch (e) {
          message.error(errorText(e))
          await refresh()
          throw e
        }
      },
    })
  }

  const subtitle = d
    ? `Товары, которые уже есть в магазине «${d.store_name}» · склад «${d.warehouse_name}» · список общий с приложением «SM Магазин»`
    : ''

  return (
    <>
      <PageTitle
        title="Начало работы"
        extra={
          <Space wrap>
            <Button icon={<CameraOutlined />} onClick={() => setPhotoOpen(true)} disabled={!d}>
              Фото полок
            </Button>
            {can('catalog.manage') && (
              <Button icon={<PlusOutlined />} onClick={() => setNewOpen(true)} disabled={!d}>
                Новый товар
              </Button>
            )}
            <Button type="primary" icon={<CheckCircleOutlined />} disabled={!t || t.products === 0 || d?.status !== 'open'} onClick={post}>
              Проверить и провести
            </Button>
          </Space>
        }
      />
      <LoadError error={draft.error} retry={() => draft.refetch()} />
      {subtitle && (
        <Typography.Paragraph type="secondary" style={{ marginTop: -4 }}>
          {subtitle}
        </Typography.Paragraph>
      )}
      {d && d.stock_products > 0 && !d.id && (
        <Alert
          type="success"
          showIcon
          style={{ marginBottom: 16 }}
          message={`На складе уже ${goods(d.stock_products)}`}
          description="Начальные остатки заведены. Если нашлись ещё товары — добавьте их сюда и проведите снова. Новые поставки оформляйте через «Приход товара»."
        />
      )}
      {d?.status === 'posting' && <Alert type="info" showIcon style={{ marginBottom: 16 }} message="Список проводится — подождите несколько секунд" />}

      {t && (
        <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
          <Stat title="Добавлено" value={`${goods(t.products)} · ${fmtQty(t.qty)} шт`} />
          <Stat title="По закупке" value={sum(t.cost_total)} />
          <Stat title="По цене продажи" value={sum(t.price_total)} />
          <Stat title="Без закупочной цены" value={goods(t.no_cost)} warn={t.no_cost > 0} />
        </Row>
      )}

      {d && <Scanner />}

      <Row gutter={[16, 16]}>
        <Col xs={24} xl={8}>
          {d && <CatalogTree storeId={storeId} />}
        </Col>
        <Col xs={24} xl={16}>
          <Lines draft={d} loading={draft.isLoading || draft.isFetching} only={only} setOnly={setOnly} page={page} setPage={setPage} />
        </Col>
      </Row>

      <PhotoModal open={photoOpen} onClose={() => setPhotoOpen(false)} />
      <NewProductModal open={newOpen} onClose={() => setNewOpen(false)} />
      <Modal open={!!result} footer={null} onCancel={() => setResult(null)} width={560}>
        {result && <Posted r={result} onClose={() => setResult(null)} />}
      </Modal>
    </>
  )
}

function Stat({ title, value, warn }: { title: string; value: string; warn?: boolean }) {
  return (
    <Col xs={12} lg={6}>
      <Card styles={{ body: { padding: '14px 16px' } }}>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {title}
        </Typography.Text>
        <div style={{ fontSize: 18, fontWeight: 700, color: warn ? '#C4320A' : undefined }}>{value}</div>
      </Card>
    </Col>
  )
}

// ----------------------------------------------------------------- сканер

const isBarcode = (s: string) => /^\d{6,14}$/.test(s)

/**
 * Поле сканера: USB-сканер «печатает» штрихкод и Enter — товар сразу в
 * списке, повторный скан — +1 шт. Название — поиск с подсказками.
 */
function Scanner() {
  const { storeId } = useStore()
  const { setLines } = useStartApi(storeId)
  const { message } = App.useApp()
  const [text, setText] = useState('')
  const [missing, setMissing] = useState<string | null>(null)
  const ref = useRef<InputRef>(null)
  const q = useDebounced(text.trim(), 250)
  const found = useList<Product>(q.length >= 2 && !isBarcode(q) ? '/store/products' : null, { q, store_id: storeId, limit: 10 })

  const add = async (p: { id: string; name: string }, source: 'barcode' | 'search') => {
    try {
      await setLines([{ product_id: p.id, add: true, source }])
      message.success(`${p.name} · +1`)
    } catch {
      // ошибка уже показана
    }
  }

  const scan = async (code: string) => {
    try {
      const r = await api.get<List<Product>>('/store/products', { barcode: code, store_id: storeId, limit: 1 })
      const p = r.items?.[0]
      if (p) await add(p, 'barcode')
      else setMissing(code)
    } catch (e) {
      message.error(errorText(e))
    }
  }

  return (
    <Card style={{ borderColor: '#E11D2A', marginBottom: 16 }} styles={{ body: { padding: '10px 16px' } }}>
      <Flex align="center" gap={12}>
        <ScanOutlined style={{ fontSize: 20, color: '#E11D2A' }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <AutoComplete
            value={text}
            onChange={setText}
            style={{ width: '100%' }}
            options={(found.data ?? []).map((p) => ({
              value: p.id,
              label: (
                <Flex justify="space-between" gap={8}>
                  <Typography.Text ellipsis>{p.name}</Typography.Text>
                  <Typography.Text type="secondary" style={{ flex: 'none' }}>
                    {p.price ? money(p.price) : ''}
                  </Typography.Text>
                </Flex>
              ),
            }))}
            onSelect={(id: string) => {
              const p = found.data?.find((x) => x.id === id)
              setText('')
              if (p) add(p, 'search')
              ref.current?.focus()
            }}
          >
            <Input
              ref={ref}
              variant="borderless"
              autoFocus
              placeholder="Сканируйте штрихкод или введите название"
              style={{ paddingLeft: 0, fontWeight: 600 }}
              onKeyDown={(e) => {
                const v = text.trim()
                if (e.key === 'Enter' && isBarcode(v)) {
                  e.preventDefault()
                  setText('')
                  scan(v)
                }
              }}
            />
          </AutoComplete>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            USB-сканер работает как клавиатура: товар сразу встанет в список, повторный скан — +1 шт
          </Typography.Text>
        </div>
      </Flex>
      <BarcodeModal
        code={missing}
        onClose={() => {
          setMissing(null)
          setTimeout(() => ref.current?.focus(), 0)
        }}
      />
    </Card>
  )
}

// ----------------------------------------------------------------- список

/** Число в ячейке: сохраняется по Enter или уходу из поля. */
function NumCell({
  value,
  placeholder,
  warn,
  min = '0',
  onSave,
}: {
  value: string | null
  placeholder?: string
  warn?: boolean
  min?: string
  onSave: (v: string | null) => void
}) {
  const [v, setV] = useState<string | null>(plainNum(value) || null)
  useEffect(() => setV(plainNum(value) || null), [value])
  const commit = () => {
    const next = v === '' || v === null ? null : v
    if ((next === null ? null : Number(next)) !== (value === null ? null : Number(value))) onSave(next)
  }
  return (
    <InputNumber<string>
      stringMode
      min={min}
      value={v ?? undefined}
      placeholder={placeholder}
      status={warn ? 'warning' : undefined}
      style={{ width: '100%', background: warn ? '#FFFAEB' : undefined }}
      formatter={(x) => {
        if (!x) return ''
        const [a, b] = String(x).split('.')
        return a.replace(/\B(?=(\d{3})+(?!\d))/g, ' ') + (b !== undefined ? '.' + b : '')
      }}
      parser={(x) => (x ?? '').replace(/\s/g, '').replace(',', '.')}
      onChange={(x) => setV(x)}
      onBlur={commit}
      onPressEnter={(e) => {
        commit()
        ;(e.target as HTMLInputElement).blur()
      }}
    />
  )
}

function sourceText(l: Line) {
  if (!l.own) return { text: 'общий каталог' }
  if (l.moderation === 'approved') return { text: 'свой товар' }
  if (l.moderation === 'rejected') return { text: 'новый · отклонён', color: '#D92D20' }
  return { text: 'новый · на модерации', color: '#C4320A' }
}

function Lines({
  draft,
  loading,
  only,
  setOnly,
  page,
  setPage,
}: {
  draft: Draft | undefined
  loading: boolean
  only: '' | 'no_cost' | 'new'
  setOnly: (v: '' | 'no_cost' | 'new') => void
  page: number
  setPage: (p: number) => void
}) {
  const { storeId, can } = useStore()
  const { setLines, deleteLine } = useStartApi(storeId)
  const [bind, setBind] = useState<Line | null>(null)
  const t = draft?.totals
  const raw = draft?.lines ?? []
  const hasMore = raw.length > PAGE
  const lines = hasMore ? raw.slice(0, PAGE) : raw
  const save = (l: Line, patch: Omit<LineInput, 'product_id'>) => setLines([{ ...patch, product_id: l.product_id }]).catch(() => {})
  const locked = draft?.status !== 'open'

  return (
    <Card
      title={`Мои товары · ${t?.products ?? 0}`}
      extra={
        <Segmented
          size="small"
          value={only}
          onChange={(v) => setOnly(v as typeof only)}
          options={[
            { value: '', label: 'Все' },
            { value: 'no_cost', label: `Без закупки · ${t?.no_cost ?? 0}` },
            { value: 'new', label: 'Новые' },
          ]}
        />
      }
      styles={{ body: { padding: 0 } }}
    >
      <Table<Line>
        rowKey="product_id"
        size="middle"
        loading={loading}
        dataSource={lines}
        pagination={
          page > 1 || hasMore
            ? {
                current: page,
                pageSize: PAGE,
                total: (page - 1) * PAGE + lines.length + (hasMore ? 1 : 0),
                onChange: setPage,
                showSizeChanger: false,
              }
            : false
        }
        scroll={{ x: 700 }}
        locale={{
          emptyText: only
            ? 'Таких товаров нет'
            : 'Список пуст — отсканируйте штрихкод, загрузите фото полок или отметьте товары в каталоге слева',
        }}
        columns={[
          {
            title: 'Товар',
            key: 'name',
            render: (_, l) => {
              const s = sourceText(l)
              return (
                <Flex align="center" gap={10} style={{ minWidth: 180 }}>
                  <Thumb src={l.image} size={36} />
                  <div style={{ minWidth: 0 }}>
                    <Typography.Text ellipsis={{ tooltip: l.name }} style={{ maxWidth: 230, display: 'block' }}>
                      {l.name}
                    </Typography.Text>
                    <Typography.Text style={{ fontSize: 12, color: s.color }} type={s.color ? undefined : 'secondary'}>
                      {s.text} · {l.unit_short}
                    </Typography.Text>
                  </div>
                </Flex>
              )
            },
          },
          {
            title: 'Кол-во',
            key: 'qty',
            width: 84,
            render: (_, l) => <NumCell value={l.qty} min="0.001" onSave={(v) => v && save(l, { qty: v })} />,
          },
          {
            title: 'Закупка',
            key: 'cost',
            width: 112,
            render: (_, l) => <NumCell value={l.cost} placeholder="—" warn={l.cost === null} onSave={(v) => save(l, { cost: v })} />,
          },
          {
            title: 'Продажа',
            key: 'price',
            width: 112,
            render: (_, l) => (
              <NumCell value={l.price ?? l.current_price} min="1" onSave={(v) => save(l, { price: v })} />
            ),
          },
          {
            title: 'Штрихкод',
            key: 'barcode',
            width: 136,
            render: (_, l) =>
              l.barcode ? (
                <Typography.Text type="secondary" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>
                  {l.barcode}
                </Typography.Text>
              ) : can('catalog.manage') ? (
                <Button type="link" danger size="small" icon={<ScanOutlined />} style={{ padding: 0 }} onClick={() => setBind(l)}>
                  Привязать
                </Button>
              ) : (
                '—'
              ),
          },
          {
            key: 'del',
            width: 40,
            render: (_, l) => (
              <Button type="text" size="small" icon={<DeleteOutlined />} disabled={locked} aria-label="Убрать" onClick={() => deleteLine(l.product_id).catch(() => {})} />
            ),
          },
        ]}
        footer={
          lines.length
            ? () => (
                <Flex justify="space-between" wrap gap={8}>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    Показано {(page - 1) * PAGE + 1}–{(page - 1) * PAGE + lines.length} · последние добавленные сверху
                  </Typography.Text>
                  <Typography.Text strong>Итого по закупке {sum(t?.cost_total)}</Typography.Text>
                </Flex>
              )
            : undefined
        }
      />
      <BindModal line={bind} onClose={() => setBind(null)} />
    </Card>
  )
}

/** Привязать штрихкод к товару списка (сканером или вручную). */
function BindModal({ line, onClose }: { line: Line | null; onClose: () => void }) {
  const { storeId } = useStore()
  const { setLines } = useStartApi(storeId)
  const [code, setCode] = useState('')
  const [saving, setSaving] = useState(false)
  useEffect(() => setCode(''), [line])
  const ok = async () => {
    if (!line || !code.trim()) return
    setSaving(true)
    try {
      await setLines([{ product_id: line.product_id, barcode: code.trim() }])
      onClose()
    } catch {
      // ошибка уже показана
    } finally {
      setSaving(false)
    }
  }
  return (
    <Modal open={!!line} title="Привязать штрихкод" okText="Привязать" onOk={ok} confirmLoading={saving} okButtonProps={{ disabled: !code.trim() }} onCancel={onClose} destroyOnHidden>
      <Typography.Paragraph type="secondary">{line?.name}</Typography.Paragraph>
      <Input autoFocus value={code} onChange={(e) => setCode(e.target.value)} onPressEnter={ok} placeholder="Отсканируйте или введите штрихкод" prefix={<ScanOutlined />} />
    </Modal>
  )
}

// ------------------------------------------------------------ проведено

function Posted({ r, onClose }: { r: PostResult; onClose: () => void }) {
  return (
    <Result
      status="success"
      title="Товары на складе"
      subTitle={`${goods(r.products)} · ${fmtQty(r.qty)} шт · по закупке ${sum(r.cost_total)}`}
      extra={
        <Button type="primary" onClick={onClose}>
          Готово
        </Button>
      }
    >
      <Space direction="vertical" size={6}>
        {r.documents.map((doc) => (
          <Link key={doc.id} to={`${docPaths.posting}/${doc.id}`}>
            Оприходование №{doc.number}
          </Link>
        ))}
        {r.price_document && <Link to={`/sales/prices/${r.price_document.id}`}>Установка цен №{r.price_document.number}</Link>}
        <Typography.Text>
          Покупатели видят {goods(r.visible)}
          {r.pending > 0 && ` · ещё ${r.pending} — после проверки новых товаров`}
        </Typography.Text>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          В приложении товары появятся, если магазин принимает онлайн-заказы и сейчас открыт.
        </Typography.Text>
      </Space>
    </Result>
  )
}
