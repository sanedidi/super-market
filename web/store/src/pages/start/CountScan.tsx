// Шаг 2 «Начала работы» — инвентаризация сканером (Figma «Панель магазина ·
// начало работы v4»). Тот же сканер и поиск, что на шаге 1, но найденный товар
// открывает не «Добавить», а шторку снизу: количество и цена продажи
// (обязательны, можно 0), цена закупки — по желанию. Товара нет в документе —
// «Добавить и заполнить»; нет и в центральной базе — как на шаге 1, через
// каталог ИКПУ или «Новый товар по фото». У товара без фото шторка требует
// снимок: без фото покупатель не увидит товар, и документ не записывается.
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Alert, App, Button, Card, Drawer, Flex, Input, InputNumber, Space, Typography, type InputRef } from 'antd'
import { PlusOutlined, QrcodeOutlined, SearchOutlined, StarFilled } from '@ant-design/icons'
import { ImageUpload, api, errorText, money, tr, useDebounced } from '@sm/shared'
import { useStore } from '../../ctx'
import { Thumb } from './Thumb'
import { plainNum, quotaOut, usePhotoQuota, type Draft, type Line, type LinesResult, type ScanResult } from './api'

const isBarcode = (s: string) => /^[0-9]{6,14}$/.test(s)

/**
 * Поиск и сканер документа: штрихкод — сразу шторка, название — список строк.
 * USB-сканер «печатает» штрихкод и Enter, поле остаётся в фокусе.
 */
export function ScanCard({ onFound }: { onFound: (l: Line) => void }) {
  const { storeId } = useStore()
  const { message, modal } = App.useApp()
  const nav = useNavigate()
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const ref = useRef<InputRef>(null)
  const q = useDebounced(text.trim(), 250)

  // Поиск по названию — среди товаров документа.
  const [found, setFound] = useState<Line[]>([])
  useEffect(() => {
    let live = true
    if (q.length < 2 || isBarcode(q)) {
      setFound([])
      return
    }
    api
      .get<Draft>('/store/start', { store_id: storeId, q, limit: 8 })
      .then((d) => live && setFound(d.lines ?? []))
      .catch(() => live && setFound([]))
    return () => {
      live = false
    }
  }, [q, storeId])

  const open = (l: Line) => {
    setText('')
    setFound([])
    onFound(l)
  }

  /** Штрихкод: строка документа → шторка; товар базы → «Добавить и заполнить»; нет нигде → шаг 1. */
  const scan = async (code: string) => {
    setBusy(true)
    try {
      const r = await api.get<ScanResult>('/store/start/scan', { store_id: storeId, code })
      if (r.status === 'line' && r.line) {
        open(r.line)
        return
      }
      if (r.status === 'product' && r.product) {
        const p = r.product
        modal.confirm({
          title: tr('Товара нет в документе', 'Hujjatda bunday mahsulot yoʻq'),
          width: 520,
          okText: tr('Добавить и заполнить', 'Qoʻshish va toʻldirish'),
          cancelText: tr('Пропустить', 'Oʻtkazib yuborish'),
          content: (
            <div>
              <Typography.Paragraph style={{ marginBottom: 6 }}>{p.name}</Typography.Paragraph>
              <Typography.Text type="secondary">
                {tr(
                  `Штрихкод ${code} нашли в центральной базе, но вы не добавляли этот товар на шаге 1. Добавим в «Мои товары» и сразу откроем количество и цены.`,
                  `${code} shtrix-kodi markaziy bazada bor, lekin siz bu mahsulotni 1-qadamda qoʻshmagansiz. «Mahsulotlarim»ga qoʻshamiz va darhol miqdor va narxlarni ochamiz.`,
                )}
              </Typography.Text>
            </div>
          ),
          onOk: async () => {
            const res = await api.post<LinesResult>('/store/start/lines', {
              store_id: storeId,
              items: [{ product_id: p.product_id, add: true, source: 'barcode' }],
            })
            if (res.lines[0]) open(res.lines[0])
          },
        })
        return
      }
      modal.confirm({
        title: tr('Штрихкода нет', 'Shtrix-kod topilmadi'),
        width: 520,
        okText: tr('Перейти к добавлению товара', 'Mahsulot qoʻshishga oʻtish'),
        cancelText: tr('Отмена', 'Bekor qilish'),
        content: tr(
          `${code} — нет ни в товарах документа, ни в центральной базе. На шаге «Выбор товаров» можно поискать его в каталоге ИКПУ или завести новый товар по фото.`,
          `${code} — na hujjat mahsulotlarida, na markaziy bazada bor. «Mahsulotlarni tanlash» qadamida uni IKPU katalogidan qidirish yoki rasm orqali yangi mahsulot yaratish mumkin.`,
        ),
        onOk: () => nav('/start?step=1'),
      })
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
      setText('')
      ref.current?.focus()
    }
  }

  return (
    <Card styles={{ body: { padding: '14px 16px' } }}>
      <Flex gap={12} wrap align="center">
        <Input
          ref={ref}
          allowClear
          autoFocus
          size="large"
          style={{ maxWidth: 520 }}
          disabled={busy}
          value={text}
          prefix={<QrcodeOutlined />}
          placeholder={tr('Наведите USB-сканер или введите штрихкод / название', 'USB-skanerni yoʻnaltiring yoki shtrix-kod / nomni kiriting')}
          onChange={(e) => setText(e.target.value)}
          onPressEnter={() => {
            const v = text.trim()
            if (v) void scan(v)
          }}
        />
        <Alert
          type="success"
          showIcon
          style={{ flex: 1, minWidth: 280 }}
          message={tr('Сканируйте — снизу откроется ввод количества и цен', 'Skanerlang — pastdan miqdor va narx kiritish ochiladi')}
        />
      </Flex>
      {found.length > 0 && (
        <div style={{ marginTop: 12, borderTop: '1px solid #EFEFF1', paddingTop: 10 }}>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Нашли в товарах документа', 'Hujjat mahsulotlari orasidan topildi')}
          </Typography.Text>
          <Space direction="vertical" size={6} style={{ width: '100%', marginTop: 8 }}>
            {found.map((l) => (
              <Flex key={l.product_id} gap={10} align="center">
                <Thumb src={l.image} badge={l.photo} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div>{l.name}</div>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {l.barcode ?? tr('без штрихкода', 'shtrix-kodsiz')}
                    {l.qty !== null && ` · ${plainNum(l.qty)} ${l.unit_short}`}
                  </Typography.Text>
                </div>
                <Button size="small" icon={<SearchOutlined />} onClick={() => open(l)}>
                  {tr('Заполнить', 'Toʻldirish')}
                </Button>
              </Flex>
            ))}
          </Space>
        </div>
      )}
    </Card>
  )
}

/** Шторка снизу: количество, цена продажи, цена закупки и фото, если его нет. */
export function CountDrawer({ line, onClose, onSaved }: { line: Line | null; onClose: () => void; onSaved: () => Promise<void> | void }) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const [qty, setQty] = useState<string | null>(null)
  const [cost, setCost] = useState<string | null>(null)
  const [price, setPrice] = useState<string | null>(null)
  const [photos, setPhotos] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const quota = usePhotoQuota(storeId).data
  const filled = !!line && line.qty !== null
  const needPhoto = !!line && !line.image && photos.length === 0

  useEffect(() => {
    if (!line) return
    // Товар уже заполняли — в поле то количество, что вводили; его можно исправить.
    setQty(line.qty !== null ? plainNum(line.qty) : null)
    setCost(line.cost)
    setPrice(line.price ?? (Number(line.current_price) > 0 ? line.current_price : null))
    setPhotos([])
  }, [line])

  if (!line) return null

  const save = async () => {
    if (qty === null || qty === '') {
      message.error(tr('Количество обязательно — можно 0', 'Miqdor majburiy — 0 boʻlishi mumkin'))
      return
    }
    if (price === null || price === '') {
      message.error(tr('Цена продажи обязательна — можно 0', 'Sotish narxi majburiy — 0 boʻlishi mumkin'))
      return
    }
    if (needPhoto) {
      message.error(tr('Сначала добавьте фото товара', 'Avval mahsulot rasmini qoʻshing'))
      return
    }
    setBusy(true)
    try {
      if (photos.length > 0 && !line.image) {
        await api.post<LinesResult>(`/store/start/lines/${line.product_id}/photo`, { store_id: storeId, images: photos })
      }
      await api.post<LinesResult>('/store/start/lines', {
        store_id: storeId,
        items: [{ product_id: line.product_id, qty, price, cost: cost === '' ? null : cost }],
      })
      message.success(tr(`${line.name} — записано`, `${line.name} — yozildi`))
      await onSaved()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Drawer
      open
      placement="bottom"
      height="auto"
      onClose={onClose}
      destroyOnClose
      title={tr('Количество и цены', 'Miqdor va narxlar')}
      extra={
        <Button type="primary" size="large" icon={<PlusOutlined />} loading={busy} disabled={needPhoto} onClick={save}>
          {tr('Сохранить и сканировать дальше', 'Saqlash va skanerlashni davom ettirish')}
        </Button>
      }
    >
      <Flex gap={16} wrap align="flex-start">
        <Flex gap={12} align="center" style={{ minWidth: 280, flex: 1 }}>
          <Thumb src={line.image} badge={line.photo} />
          <div>
            <div style={{ fontWeight: 600 }}>{line.name}</div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {line.barcode ?? tr('без штрихкода', 'shtrix-kodsiz')}
              {filled && ` · ${tr('было', 'bor edi')} ${plainNum(line.qty)} ${line.unit_short}`}
            </Typography.Text>
          </div>
        </Flex>
        {filled && (
          <div>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('Этот товар уже заполняли', 'Bu mahsulot allaqachon toʻldirilgan')}
            </Typography.Text>
          </div>
        )}
        <div>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Количество', 'Miqdor')} *
          </Typography.Text>
          <div>
            <InputNumber
              autoFocus
              size="large"
              style={{ width: 180 }}
              min="0"
              step="1"
              value={qty}
              stringMode
              addonAfter={line.unit_short}
              placeholder={tr('обязательно', 'majburiy')}
              onChange={(v) => setQty(v === null ? null : String(v))}
            />
          </div>
        </div>
        <div>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Цена продажи', 'Sotish narxi')} *
          </Typography.Text>
          <div>
            <InputNumber
              size="large"
              style={{ width: 200 }}
              min="0"
              value={price}
              stringMode
              placeholder={tr('обязательно', 'majburiy')}
              onChange={(v) => setPrice(v === null ? null : String(v))}
            />
          </div>
          {Number(line.current_price) > 0 && (
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr(`в базе: ${money(line.current_price)}`, `bazada: ${money(line.current_price)}`)}
            </Typography.Text>
          )}
        </div>
        <div>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Цена закупки', 'Xarid narxi')}
          </Typography.Text>
          <div>
            <InputNumber
              size="large"
              style={{ width: 200 }}
              min="0"
              value={cost}
              stringMode
              placeholder={tr('необязательно', 'ixtiyoriy')}
              onChange={(v) => setCost(v === null ? null : String(v))}
            />
          </div>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('нужна только для прибыли', 'faqat foyda uchun kerak')}
          </Typography.Text>
        </div>
      </Flex>
      {!line.image && (
        <Alert
          type="error"
          showIcon
          style={{ marginTop: 14 }}
          message={tr('У товара нет фото', 'Mahsulotning rasmi yoʻq')}
          description={
            <div>
              <Typography.Paragraph type="secondary" style={{ marginBottom: 8 }}>
                {tr(
                  'Без фото покупатель не увидит товар в каталоге, и «Записать и закрыть» не пройдёт. Загрузите снимок — можно несколько: лицевая сторона, этикетка, состав (до 6).',
                  'Rasmsiz xaridor mahsulotni katalogda koʻrmaydi va «Yozish va yopish» oʻtmaydi. Rasm yuklang — bir nechta boʻlishi mumkin: old tomoni, yorligʻi, tarkibi (6 tagacha).',
                )}
              </Typography.Paragraph>
              <ImageUpload multiple max={6} value={photos} onChange={setPhotos} />
              {photos.length > 0 && quota?.enabled && !quotaOut(quota) && (
                <Flex gap={8} align="center" style={{ marginTop: 10, background: '#F4F3FF', borderRadius: 10, padding: '8px 12px' }}>
                  <StarFilled style={{ color: '#6938EF' }} />
                  <Typography.Text style={{ fontSize: 13, color: '#3E1C96', fontWeight: 500 }}>
                    {tr('Super Market сделает из снимка чистое фото — сохраняйте, ждать не нужно', 'Super Market suratdan toza rasm tayyorlaydi — saqlang, kutish shart emas')}
                  </Typography.Text>
                </Flex>
              )}
            </div>
          }
        />
      )}
    </Drawer>
  )
}
