// Новый товар по фото (Figma «Панель магазина · новый товар по фото», В1;
// «SM Магазин» Р1–Р5). Товара нет ни в базе, ни в каталоге ИКПУ — магазин
// отправляет фото и работает дальше; Super Market в фоне заполняет карточку.
// Распознал уверенно и не дубль — товар сам встаёт в «Мои товары». Во вкладке
// «Требуют внимания» — только дубли, сомнения и то, что не распознано:
// распознаётся / проверить / не удалось. Товар создаётся (свой, draft) после
// «Подтвердить и добавить»; на модерацию — при «Записать и закрыть».
// Без дублей (Figma «без дублей в «Новых»», В1–В3): тот же штрихкод второй
// раз в «Новые» не попадает; похожая карточка помечается «Похоже на дубль»,
// «Это он» объединяет карточки.
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Col, Flex, Form, Input, Modal, Pagination, Progress, Row, Space, Spin, Tag, Typography } from 'antd'
import {
  CameraOutlined,
  CheckCircleFilled,
  CheckOutlined,
  CopyOutlined,
  DeleteOutlined,
  FolderAddOutlined,
  PictureOutlined,
  PlusOutlined,
  ReloadOutlined,
  RollbackOutlined,
  StarFilled,
  TagsOutlined,
} from '@ant-design/icons'
import { ApiError, FormTranslate, ImageUpload, RemoteSelect, api, errorText, getLang, tr } from '@sm/shared'
import { useStore } from '../../ctx'
import type { DictItem } from '../../types'
import { Link } from 'react-router-dom'
import { quotaOut, usePhotoQuota, useStartRefresh, type CategoryRef, type CategorySuggestion, type NewCategory, type NewItem, type NewItemConfirmResult, type NewItemDup, type NewItemList, type NewItemsBulk } from './api'
import { Thumb } from './Thumb'

const PURPLE = '#6938EF'
const AMBER = { bg: '#FFFAEB', border: '#FEDF89', text: '#93370D', icon: '#DC6803' }

/** Чип-причина у карточки в списке «Требуют внимания». */
function ReasonChip({ children, icon }: { children: ReactNode; icon?: ReactNode }) {
  return (
    <span style={{ flex: 'none', display: 'inline-flex', alignItems: 'center', gap: 4, background: AMBER.bg, color: AMBER.text, borderRadius: 6, padding: '1px 8px', fontSize: 12, fontWeight: 600 }}>
      {icon}
      {children}
    </span>
  )
}

/** Почему карточка не встала в «Мои товары» сама. */
function reasons(it: NewItem): ReactNode[] {
  if (it.status !== 'ready') return []
  const out: ReactNode[] = []
  if (it.barcode_invalid) out.push(<ReasonChip key="code">{tr('Проверьте штрихкод', 'Shtrix-kodni tekshiring')}</ReasonChip>)
  if (it.duplicate)
    out.push(
      <ReasonChip key="dup" icon={<CopyOutlined style={{ color: AMBER.icon }} />}>
        {tr('Похоже на дубль', 'Dublga oʻxshaydi')}
      </ReasonChip>,
    )
  if (it.result?.match)
    out.push(
      <ReasonChip key="match">
        {it.result.match.same_barcode ? tr('Уже есть в базе', 'Bazada bor') : tr('Тот же товар, другой штрихкод?', 'Shu mahsulot, boshqa shtrix-kod?')}
      </ReasonChip>,
    )
  if (it.result && !it.result.suggestion?.category) out.push(<ReasonChip key="cat">{tr('Нет категории', 'Kategoriya yoʻq')}</ReasonChip>)
  if (it.result?.note) out.push(<ReasonChip key="note">{tr('Есть сомнения', 'Shubha bor')}</ReasonChip>)
  return out
}

/** Метка фото от Super Market (Figma «Нормализация фото для магазина», Н1). */
function PhotoChip({ it }: { it: NewItem }) {
  const ph = it.photo
  if (!ph) return null
  const chip = (bg: string, color: string, icon: ReactNode, text: string) => (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, background: bg, color, borderRadius: 6, padding: '1px 8px', fontSize: 12, fontWeight: 600 }}>
      {icon}
      {text}
    </span>
  )
  switch (ph.status) {
    case 'processing':
      return chip('#F4F3FF', '#5925DC', <StarFilled />, tr('Super Market делает фото… ~1 мин', 'Super Market rasm tayyorlamoqda… ~1 daq'))
    case 'done':
      return chip('#ECFDF3', '#067647', <CheckOutlined />, tr('Фото Super Market', 'Super Market rasmi'))
    case 'failed':
      return chip('#F2F4F7', '#475467', <PictureOutlined />, tr('Фото не вышло — осталось ваше', 'Rasm chiqmadi — sizniki qoldi'))
    case 'limit':
      return chip('#F2F4F7', '#475467', <PictureOutlined />, tr('Ваше фото · лимит месяца', 'Sizning rasmingiz · oylik limit'))
  }
}

/** Миниатюра карточки: готовое фото Super Market — оно, иначе фото магазина. */
export const newItemThumb = (it: NewItem) => (it.photo?.status === 'done' && it.photo.image ? it.photo.image : it.images[0])
export const newItemBadge = (it: NewItem) => (it.photo?.status === 'processing' || it.photo?.status === 'done' ? it.photo.status : undefined)

/** Н4: фото Super Market на этот месяц закончились — товары остаются с фото магазина. */
export function PhotoLimitBar() {
  const { storeId } = useStore()
  const q = usePhotoQuota(storeId).data
  if (!quotaOut(q)) return null
  const month = new Date(new Date(q!.resets_on).getTime() - 86400000).toLocaleDateString(getLang() === 'uz' ? 'uz-UZ' : 'ru-RU', { month: 'long' })
  const next = new Date(q!.resets_on).toLocaleDateString(getLang() === 'uz' ? 'uz-UZ' : 'ru-RU', { day: 'numeric', month: 'long' })
  return (
    <Flex gap={10} style={{ padding: '12px 20px', background: AMBER.bg, borderBottom: '1px solid #EAECF0' }}>
      <CameraOutlined style={{ color: AMBER.icon, fontSize: 16, marginTop: 2 }} />
      <div>
        <Typography.Text strong style={{ color: AMBER.text, display: 'block' }}>
          {tr(`Фото Super Market на ${month} закончились — ${q!.used} из ${q!.limit}`, `${month} uchun Super Market rasmlari tugadi — ${q!.limit} tadan ${q!.used}`)}
        </Typography.Text>
        <Typography.Text style={{ color: AMBER.text, fontSize: 13 }}>
          {tr(
            `Новые товары сохраняются с вашими фото. С ${next} Super Market снова делает фото сам. Больше фото в месяц — на другом тарифе.`,
            `Yangi mahsulotlar sizning rasmlaringiz bilan saqlanadi. ${next}dan Super Market yana rasmni oʻzi tayyorlaydi. Oyiga koʻproq rasm — boshqa tarifda.`,
          )}
        </Typography.Text>
        <div>
          <Link to="/plan" style={{ color: '#E11D2A', fontWeight: 600, fontSize: 13 }}>
            {tr('Сравнить тарифы →', 'Tariflarni solishtirish →')}
          </Link>
        </div>
      </div>
    </Flex>
  )
}

/** Что сейчас с карточкой в «Новых» — для подсказок «уже в «Новых»». */
export const newItemState = (s: NewItem['status']) =>
  s === 'ready'
    ? tr('готово к проверке', 'tekshirishga tayyor')
    : s === 'processing'
      ? tr('Super Market распознаёт… ~1 мин', 'Super Market aniqlamoqda… ~1 daq')
      : tr('не удалось распознать — заполните', 'aniqlab boʻlmadi — toʻldiring')

export const NEW_PAGE = 50

/** Очередь «Новые» магазина, страница page (с 1); пока что-то распознаётся —
 * обновляется сама. counts и total — по всей очереди с сервера. */
export function useNewItems(storeId: string, page: number) {
  return useQuery({
    queryKey: ['/store/start/new-items', storeId, page],
    queryFn: () => api.get<NewItemList>('/store/start/new-items', { store_id: storeId, limit: NEW_PAGE, offset: (page - 1) * NEW_PAGE }),
    placeholderData: keepPreviousData,
    // Пока что-то распознаётся или Super Market делает фото — обновляется сама.
    refetchInterval: (q) =>
      (q.state.data?.counts.processing ?? 0) > 0 || q.state.data?.items.some((it) => it.photo?.status === 'processing') ? 3000 : false,
  })
}

/** Заголовок-вкладка правой колонки: «Мои товары · N» | «Требуют внимания · M» | «Вариации · K». */
export type RightTab = 'mine' | 'new' | 'variants'
export function RightTabs({
  tab,
  onTab,
  mine,
  fresh,
  ready,
  variants = 0,
}: {
  tab: RightTab
  onTab: (t: RightTab) => void
  mine: number
  fresh: number
  ready: boolean
  /** Сколько групп вариаций ждут проверки (Figma «Вариации своих товаров», В2). */
  variants?: number
}) {
  const item = (key: RightTab, label: ReactNode) => (
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
            {tr('Требуют внимания', 'Eʼtibor talab qiladi')} · {fresh}
            {ready && <span style={{ width: 8, height: 8, borderRadius: 4, background: '#E11D2A', display: 'inline-block' }} />}
          </>,
        )}
      {(variants > 0 || tab === 'variants') &&
        item(
          'variants',
          <>
            {tr('Вариации', 'Variatsiyalar')} · {variants}
            {variants > 0 && <span style={{ width: 8, height: 8, borderRadius: 4, background: PURPLE, display: 'inline-block' }} />}
          </>,
        )}
    </Flex>
  )
}

/** В1: очередь «Требуют внимания». */
export function NewItemsList({
  list,
  loading,
  highlight,
  page,
  onPage,
}: {
  list: NewItemList | undefined
  loading: boolean
  highlight?: string | null
  page: number
  onPage: (p: number) => void
}) {
  const [open, setOpen] = useState<NewItem | null>(null)
  const items = list?.items ?? []
  const top = useRef<HTMLDivElement>(null)
  const total = list?.total ?? 0
  const pager = total > NEW_PAGE && (
    <Flex justify="center" style={{ padding: '12px 20px', borderBottom: '1px solid #EAECF0' }}>
      <Pagination
        size="small"
        current={page}
        pageSize={NEW_PAGE}
        total={total}
        showSizeChanger={false}
        showTotal={(t, [a, b]) => tr(`${a}–${b} из ${t}`, `${t} tadan ${a}–${b}`)}
        onChange={(p) => {
          onPage(p)
          top.current?.scrollIntoView({ block: 'start', behavior: 'smooth' })
        }}
      />
    </Flex>
  )
  return (
    <>
      <div ref={top} />
      <Flex gap={10} style={{ padding: '10px 20px', background: '#F4F3FF' }}>
        <StarFilled style={{ color: PURPLE, marginTop: 3 }} />
        <Typography.Text style={{ fontSize: 13, color: '#3E1C96' }}>
          {tr(
            'Super Market распознаёт фото новых товаров: если всё ясно и это не дубль — товар сам встаёт в «Мои товары». Здесь — то, что нужно проверить: похожие на дубль, с сомнениями и нераспознанные.',
            'Super Market yangi mahsulotlar rasmlarini aniqlaydi: hammasi aniq va dubl boʻlmasa — mahsulot oʻzi «Mahsulotlarim»ga tushadi. Bu yerda — tekshirish kerak boʻlganlar: dublga oʻxshash, shubhali va aniqlanmaganlar.',
          )}
        </Typography.Text>
      </Flex>
      <PhotoLimitBar />
      {(list?.counts.bulk ?? 0) > 0 && <BulkBar ready={list!.counts.bulk!} rest={(list?.total ?? 0) - list!.counts.bulk!} />}
      {(list?.counts.failed ?? 0) > 0 && <RetryBar failed={list!.counts.failed} />}
      {pager}
      {loading && !list ? (
        <Flex justify="center" style={{ padding: 24 }}>
          <Spin />
        </Flex>
      ) : items.length === 0 ? (
        <Typography.Paragraph type="secondary" style={{ padding: '20px', margin: 0 }}>
          {tr('Всё проверено — распознанные товары уже в «Моих товарах».', 'Hammasi tekshirilgan — aniqlangan mahsulotlar «Mahsulotlarim»da.')}
        </Typography.Paragraph>
      ) : (
        items.map((it) => (
          <Flex key={it.id} align="center" gap={14} style={{ padding: '12px 20px', borderBottom: '1px solid #EAECF0', background: highlight === it.id ? AMBER.bg : undefined }}>
            <Thumb src={newItemThumb(it)} size={48} badge={newItemBadge(it)} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <Flex align="center" gap={8} wrap>
                <Typography.Text strong style={{ fontWeight: 600, color: it.status === 'processing' ? '#667085' : undefined }}>
                  {it.status === 'processing' ? tr('Распознаётся…', 'Aniqlanmoqda…') : it.status === 'ready' ? it.result?.name : tr('Не удалось распознать', 'Aniqlab boʻlmadi')}
                </Typography.Text>
                {reasons(it)}
              </Flex>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                {[
                  it.barcode || tr('без штрихкода', 'shtrix-kodsiz'),
                  it.status === 'ready' && it.result?.suggestion?.category ? catText(it.result.suggestion.category) : null,
                  it.status === 'failed' ? it.error : it.status === 'processing' ? tr(`${it.images.length} фото · ~1 мин`, `${it.images.length} ta rasm · ~1 daq`) : null,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </Typography.Text>
              {it.photo && it.status !== 'processing' && (
                <div style={{ marginTop: 4 }}>
                  <PhotoChip it={it} />
                </div>
              )}
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
      {pager}
      <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', padding: '12px 20px 14px' }}>
        {tr('Новые товары уйдут на проверку в общую базу после «Записать и закрыть» на шаге 2.', 'Yangi mahsulotlar 2-qadamdagi «Yozish va yopish»dan soʻng umumiy bazaga tekshiruvga yuboriladi.')}
      </Typography.Text>
      <ReviewModal item={open} onClose={() => setOpen(null)} />
    </>
  )
}

// ------------------------------------------------------- «Провести все»

const plural = (n: number, one: string, few: string, many: string) => {
  const a = n % 10, b = n % 100
  return a === 1 && b !== 11 ? one : a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many
}
const goodsRu = (n: number) => `${n} ${plural(n, 'товар', 'товара', 'товаров')}`
const cardsRu = (n: number) => `${n} ${plural(n, 'карточку', 'карточки', 'карточек')}`

/** В1 (Figma «Требуют внимания — «Провести все»»): полоса над списком. */
function BulkBar({ ready, rest }: { ready: number; rest: number }) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [plan, setPlan] = useState<NewItemsBulk | null>(null)
  const [asking, setAsking] = useState(false)
  const [done, setDone] = useState<number | null>(null)

  const ask = async () => {
    setAsking(true)
    try {
      const p = await api.post<NewItemsBulk>('/store/start/new-items/confirm-all', { store_id: storeId, dry_run: true })
      if (p.ready === 0) {
        message.info(tr('Провести как есть больше нечего — проверьте карточки по одной', 'Boricha oʻtkazadigan narsa qolmadi — kartochkalarni birma-bir tekshiring'))
        await refresh()
      } else setPlan(p)
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setAsking(false)
    }
  }
  // Сервер проводит до 100 карточек за запрос — зовём, пока есть что проводить.
  const run = async () => {
    if (!plan) return
    setDone(0)
    let added = 0
    try {
      for (let i = 0; i < 100; i++) {
        const r = await api.post<NewItemsBulk>('/store/start/new-items/confirm-all', { store_id: storeId })
        added += r.added
        setDone(added)
        if (r.remaining === 0 || r.added === 0) break
      }
    } catch (e) {
      message.error(errorText(e))
    }
    await refresh()
    if (added > 0) {
      message.success(tr(`${goodsRu(added)} — в «Моих товарах»`, `${added} ta mahsulot — «Mahsulotlarim»da`))
    }
    setPlan(null)
    setDone(null)
  }

  const l = plan?.left
  const stay = l ? [
    [l.no_category, tr('Нет категории', 'Kategoriya yoʻq')],
    [l.duplicate, tr('Похоже на дубль', 'Dublga oʻxshaydi')],
    [l.barcode, tr('Проверьте штрихкод', 'Shtrix-kodni tekshiring')],
    [l.processing, tr('распознаются', 'aniqlanmoqda')],
    [l.failed, tr('не удалось распознать', 'aniqlab boʻlmadi')],
    [l.other, tr('другое', 'boshqa')],
  ].filter(([n]) => (n as number) > 0) as [number, string][] : []
  const stayTotal = stay.reduce((n, [x]) => n + x, 0)
  const box = (bg: string, color: string, title: string, lines: string[]) => (
    <div style={{ background: bg, borderRadius: 10, padding: '10px 14px' }}>
      <Typography.Text strong style={{ color, display: 'block', marginBottom: 4 }}>
        {title}
      </Typography.Text>
      {lines.map((t) => (
        <Typography.Text key={t} style={{ display: 'block', fontSize: 13, color: '#344054' }}>
          • {t}
        </Typography.Text>
      ))}
    </div>
  )
  const running = done !== null
  return (
    <>
      <Flex align="center" gap={16} wrap style={{ padding: '12px 20px', borderBottom: '1px solid #EAECF0' }}>
        <div style={{ flex: 1, minWidth: 220 }}>
          <Typography.Text strong style={{ display: 'block' }}>
            {tr(`${cardsRu(ready)} Super Market уже заполнил`, `${ready} ta kartochkani Super Market toʻldirib boʻldi`)}
          </Typography.Text>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {rest > 0
              ? tr(`Можно провести все сразу — название, категория и фото как на карточке. Ещё ${rest} — проверьте по одной.`, `Hammasini birdan oʻtkazish mumkin — nomi, kategoriya va rasm kartochkadagidek. Yana ${rest} tasini birma-bir tekshiring.`)
              : tr('Можно провести все сразу — название, категория и фото как на карточке.', 'Hammasini birdan oʻtkazish mumkin — nomi, kategoriya va rasm kartochkadagidek.')}
          </Typography.Text>
        </div>
        <Button type="primary" icon={<CheckOutlined />} loading={asking} onClick={ask}>
          {tr('Провести все в «Мои товары»', 'Hammasini «Mahsulotlarim»ga oʻtkazish')} · {ready}
        </Button>
      </Flex>
      <Modal
        open={!!plan}
        width={520}
        title={plan ? tr(`Провести ${goodsRu(plan.ready)} в «Мои товары»?`, `${plan.ready} ta mahsulotni «Mahsulotlarim»ga oʻtkazasizmi?`) : null}
        onCancel={() => !running && setPlan(null)}
        closable={!running}
        maskClosable={!running}
        destroyOnHidden
        footer={
          <Space>
            <Button disabled={running} onClick={() => setPlan(null)}>
              {tr('Отмена', 'Bekor qilish')}
            </Button>
            <Button type="primary" icon={<CheckOutlined />} loading={running} onClick={run}>
              {tr('Провести', 'Oʻtkazish')} {plan?.ready}
            </Button>
          </Space>
        }
      >
        {plan && (
          <Flex vertical gap={12}>
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              {tr(
                'Товары добавятся так, как их заполнил Super Market: название (uz / ru), бренд, категория, единица, штрихкод и фото. Количество и цены — на шаге 2.',
                'Mahsulotlar Super Market toʻldirgandek qoʻshiladi: nomi (uz / ru), brend, kategoriya, oʻlchov birligi, shtrix-kod va rasm. Miqdor va narxlar — 2-qadamda.',
              )}
            </Typography.Text>
            {box('#ECFDF3', '#067647', tr(`В «Мои товары» — ${plan.ready}`, `«Mahsulotlarim»ga — ${plan.ready}`), [
              ...(plan.ready - plan.existing > 0
                ? [tr(`${plan.ready - plan.existing} — новые товары (уйдут на модерацию после «Записать и закрыть»)`, `${plan.ready - plan.existing} — yangi mahsulotlar («Yozish va yopish»dan soʻng moderatsiyaga yuboriladi)`)]
                : []),
              ...(plan.existing > 0 ? [tr(`${plan.existing} — этот штрихкод уже есть в базе: добавится товар из базы`, `${plan.existing} — bu shtrix-kod bazada bor: bazadagi mahsulot qoʻshiladi`)] : []),
              tr('«Тот же товар, другой штрихкод?» и «Есть сомнения» — добавятся как новые товары', '«Shu mahsulot, boshqa shtrix-kod?» va «Shubha bor» — yangi mahsulot sifatida qoʻshiladi'),
            ])}
            {stayTotal > 0 &&
              box(
                '#FFFAEB',
                '#93370D',
                tr(`Останутся в «Требуют внимания» — ${stayTotal}`, `«Eʼtibor talab qiladi»da qoladi — ${stayTotal}`),
                stay.map(([n, t]) => `${n} — ${t}`),
              )}
            {running && <Progress percent={Math.min(100, Math.round(((done ?? 0) / plan.ready) * 100))} format={() => `${done} / ${plan.ready}`} />}
          </Flex>
        )}
      </Modal>
    </>
  )
}

/** В4: «Распознать заново» — все нераспознанные карточки разом. */
function RetryBar({ failed }: { failed: number }) {
  const { storeId } = useStore()
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    try {
      const r = await api.post<{ count: number }>('/store/start/new-items/retry-all', { store_id: storeId })
      if (r.count > 0)
        message.info(
          tr(`Super Market распознаёт заново ${cardsRu(r.count)} — ~1–4 мин, можно работать дальше`, `Super Market ${r.count} ta kartochkani qayta aniqlamoqda — ~1–4 daq, ishni davom ettirish mumkin`),
          6,
        )
      await refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <Flex align="center" gap={16} wrap style={{ padding: '12px 20px', borderBottom: '1px solid #EAECF0', background: '#FEF3F2' }}>
      <div style={{ flex: 1, minWidth: 220 }}>
        <Typography.Text strong style={{ display: 'block' }}>
          {tr(`${cardsRu(failed)} не удалось распознать`, `${failed} ta kartochkani aniqlab boʻlmadi`)}
        </Typography.Text>
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {tr(
            'Super Market попробует ещё раз по тем же фото. Если снова не выйдет — заполните вручную или переснимите.',
            'Super Market oʻsha rasmlar boʻyicha yana urinib koʻradi. Yana chiqmasa — qoʻlda toʻldiring yoki qayta suratga oling.',
          )}
        </Typography.Text>
      </div>
      <Button icon={<ReloadOutlined />} loading={busy} onClick={run}>
        {tr('Распознать заново', 'Qayta aniqlash')} · {failed}
      </Button>
    </Flex>
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
          ? tr('Фото сохранены — заполните карточку во вкладке «Требуют внимания»', 'Rasmlar saqlandi — kartochkani «Eʼtibor talab qiladi» boʻlimida toʻldiring')
          : tr('Отправлено Super Market — через минуту товар встанет в «Мои товары» или попадёт в «Требуют внимания»', 'Super Market’ga yuborildi — bir daqiqada mahsulot «Mahsulotlarim»ga tushadi yoki «Eʼtibor talab qiladi»ga oʻtadi'),
      )
      await refresh()
      onSent()
      onClose()
    } catch (e) {
      if (e instanceof ApiError && e.code === 'new_item_exists') {
        // Тот же штрихкод уже в «Новых» — вторую карточку не заводим.
        message.warning(tr('Этот товар уже в «Требуют внимания» — проверьте его карточку', 'Bu mahsulot allaqachon «Eʼtibor talab qiladi»da — kartochkasini tekshiring'))
        await refresh()
        onSent()
        onClose()
      } else message.error(errorText(e))
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
          'Сфотографируйте лицевую сторону и этикетку с составом и весом (до 3 фото). Super Market сам заполнит карточку и добавит товар в «Мои товары» — продолжайте работу. Если что-то неясно, товар попадёт во вкладку «Требуют внимания».',
          'Old tomoni va tarkibi hamda ogʻirligi yozilgan yorligʻini suratga oling (3 tagacha). Super Market kartochkani oʻzi toʻldiradi va mahsulotni «Mahsulotlarim»ga qoʻshadi — ishni davom ettiring. Biror narsa noaniq boʻlsa, mahsulot «Eʼtibor talab qiladi» boʻlimiga tushadi.',
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

/** Н2 (Figma «Нормализация фото для магазина»): до / после. Фото Super Market
 * встаёт первым; «Оставить моё фото» — первым снова снимок магазина;
 * «Переделать» — Super Market делает фото ещё раз. */
function PhotoCompare({ item, images, onImages, onItem }: { item: NewItem; images: string[]; onImages: (v: string[]) => void; onItem: (it: NewItem) => void }) {
  const { message } = App.useApp()
  const refresh = useStartRefresh()
  const [busy, setBusy] = useState(false)
  const ph = item.photo!
  const clean = ph.status === 'done' ? ph.image : null
  const main = !!clean && images[0] === clean
  const own = item.images
  const redo = async () => {
    setBusy(true)
    try {
      onItem(await api.post<NewItem>(`/store/start/new-items/${item.id}/photo`))
      await refresh()
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setBusy(false)
    }
  }
  const keepOwn = () => clean && onImages([...images.filter((u) => u !== clean), clean])
  const useClean = () => clean && onImages([clean, ...images.filter((u) => u !== clean)])
  const box = 168
  return (
    <div>
      <Typography.Text type="secondary" style={{ fontSize: 12, display: 'block', marginBottom: 6 }}>
        {tr('Фото Super Market', 'Super Market rasmi')}
      </Typography.Text>
      <Flex gap={20} wrap style={{ background: '#F9FAFB', borderRadius: 12, padding: 14 }}>
        <Flex vertical gap={8} style={{ width: box }}>
          <div
            style={{
              width: box,
              height: box,
              borderRadius: 12,
              background: '#fff',
              border: '1px solid #EAECF0',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              overflow: 'hidden',
            }}
          >
            {clean ? (
              <img src={clean} alt="" style={{ width: '100%', height: '100%', objectFit: 'contain' }} />
            ) : ph.status === 'processing' ? (
              <Flex vertical align="center" gap={8} style={{ padding: 12, textAlign: 'center' }}>
                <Spin />
                <Typography.Text style={{ fontSize: 12, color: '#5925DC' }}>{tr('Super Market делает фото… ~1 мин', 'Super Market rasm tayyorlamoqda… ~1 daq')}</Typography.Text>
              </Flex>
            ) : (
              <Flex vertical align="center" gap={6} style={{ padding: 12, textAlign: 'center' }}>
                <PictureOutlined style={{ fontSize: 24, color: '#98A2B3' }} />
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {ph.status === 'limit'
                    ? tr('Фото Super Market на этот месяц закончились', 'Bu oy uchun Super Market rasmlari tugadi')
                    : tr('Фото не вышло — осталось ваше', 'Rasm chiqmadi — sizniki qoldi')}
                </Typography.Text>
              </Flex>
            )}
          </div>
          {clean && (
            <Typography.Text style={{ fontSize: 12, fontWeight: 600, color: main ? '#067647' : '#475467' }}>
              {main ? <CheckCircleFilled style={{ marginRight: 4 }} /> : null}
              {main ? tr('Фото Super Market · главное', 'Super Market rasmi · asosiy') : tr('Фото Super Market · не главное', 'Super Market rasmi · asosiy emas')}
            </Typography.Text>
          )}
        </Flex>
        <Flex vertical gap={10} style={{ flex: 1, minWidth: 200 }}>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Ваши фото', 'Sizning rasmlaringiz')} · {own.length}
          </Typography.Text>
          <Flex gap={8} wrap>
            {own.map((u) => (
              <Thumb key={u} src={u} size={72} />
            ))}
          </Flex>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {tr('Остаются в карточке — их видит модератор', 'Kartochkada qoladi — moderator koʻradi')}
          </Typography.Text>
          <Space wrap>
            {clean && main && (
              <Button icon={<RollbackOutlined />} onClick={keepOwn}>
                {tr('Оставить моё фото', 'Oʻz rasmimni qoldirish')}
              </Button>
            )}
            {clean && !main && (
              <Button icon={<StarFilled style={{ color: PURPLE }} />} onClick={useClean}>
                {tr('Главным — фото Super Market', 'Asosiy — Super Market rasmi')}
              </Button>
            )}
            {ph.status !== 'processing' && (
              <Button icon={<ReloadOutlined />} loading={busy} disabled={ph.status === 'limit'} onClick={redo}>
                {tr('Переделать', 'Qayta tayyorlash')}
              </Button>
            )}
          </Space>
        </Flex>
      </Flex>
    </div>
  )
}

type Choice = { category_id: string } | { new_category: NewCategory }

/** Р4: карточка, заполненная Super Market (или пустая — «не удалось»). */
export function ReviewModal({ item, onClose }: { item: NewItem | null; onClose: () => void }) {
  const { storeId } = useStore()
  const { message, modal } = App.useApp()
  const refresh = useStartRefresh()
  const [form] = Form.useForm()
  const [saving, setSaving] = useState<'' | 'confirm' | 'match' | 'merge' | 'retry' | 'delete'>('')
  const [choice, setChoice] = useState<Choice | null>(null)
  const res = item?.result ?? null
  // Карточка со свежим фото Super Market: пока делается — опрашиваем.
  const [cur, setCur] = useState<NewItem | null>(item)
  const clean = cur?.photo?.status === 'done' ? cur.photo.image : null
  const lastClean = useRef<string | null>(null)
  const images: string[] = Form.useWatch('images', form) ?? []

  useEffect(() => {
    setCur(item)
    lastClean.current = item?.photo?.status === 'done' ? item.photo.image : null
  }, [item])
  useEffect(() => {
    if (!cur || cur.photo?.status !== 'processing') return
    const t = setInterval(async () => {
      try {
        setCur(await api.get<NewItem>(`/store/start/new-items/${cur.id}`))
      } catch {
        /* следующая попытка */
      }
    }, 3000)
    return () => clearInterval(t)
  }, [cur])
  // Фото готово (или переделано) — встаёт первым, прежнее фото Super Market заменяется.
  useEffect(() => {
    if (!clean || clean === lastClean.current) return
    const was = lastClean.current
    lastClean.current = clean
    const now: string[] = form.getFieldValue('images') ?? []
    form.setFieldValue('images', [clean, ...now.filter((u) => u !== clean && u !== was)])
  }, [clean, form])

  useEffect(() => {
    if (!item) return
    const r = item.result
    const ready = item.photo?.status === 'done' && item.photo.image ? item.photo.image : null
    form.resetFields()
    form.setFieldsValue({
      name: r?.name,
      name_uz: r?.name_uz,
      brand_id: r?.brand_id ?? undefined,
      brand_name: r?.brand_id ? '' : (r?.brand ?? ''),
      unit_id: r?.unit_id || undefined,
      barcode: item.barcode,
      images: ready ? [ready, ...item.images] : item.images,
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
        // «Оставить моё фото»: первым стоит не фото Super Market.
        keep_own_photo: !!clean && ((v.images as string[]) ?? [])[0] !== clean,
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
  // «Это он» — эта карточка — тот же товар, что в «Новых»: фото переходят туда, эта убирается.
  const merge = async (into: NewItemDup) => {
    if (!item) return
    setSaving('merge')
    try {
      await api.post<NewItem>(`/store/start/new-items/${item.id}/merge`, { store_id: storeId, into: into.id })
      message.success(tr('Карточки объединены — фото добавлены к той карточке', 'Kartochkalar birlashtirildi — rasmlar oʻsha kartochkaga qoʻshildi'))
      await refresh()
      onClose()
    } catch (e) {
      message.error(errorText(e))
      await refresh()
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
          {cur?.photo && (
            <PhotoCompare
              item={cur}
              images={images}
              onImages={(v) => form.setFieldValue('images', v)}
              onItem={setCur}
            />
          )}
          {!failed && res?.note && <Alert type="warning" showIcon message={tr('Проверьте', 'Tekshiring')} description={res.note} />}
          {item.barcode_invalid && (
            <Alert
              type="warning"
              showIcon
              message={tr(`Штрихкод ${item.barcode} не проходит проверку — похоже на опечатку`, `${item.barcode} shtrix-kodi tekshiruvdan oʻtmadi — xatoga oʻxshaydi`)}
              description={tr('Сверьте цифры с упаковкой и исправьте поле «Штрихкод» ниже.', 'Raqamlarni qadoq bilan solishtiring va pastdagi «Shtrix-kod» maydonini tuzating.')}
            />
          )}
          {item.duplicate && <DupBlock dup={item.duplicate} loading={saving === 'merge'} onMerge={merge} />}
          {res?.match && (
            <Flex vertical gap={8} style={{ background: '#FFF7D6', borderRadius: 12, padding: 12 }}>
              <Typography.Text strong style={{ color: '#7A2E0E' }}>
                {res.match.same_barcode
                  ? tr('Этот штрихкод уже есть в базе', 'Bu shtrix-kod bazada allaqachon bor')
                  : tr('Похоже, это тот же товар с другим штрихкодом', 'Bu boshqa shtrix-kodli xuddi shu mahsulotga oʻxshaydi')}
              </Typography.Text>
              {!res.match.same_barcode && (
                <Typography.Text style={{ fontSize: 12, color: '#7A2E0E' }}>
                  {item.barcode
                    ? tr(`Бренд, объём и фасовка совпадают. «Это он» добавит штрихкод ${item.barcode} к этому товару. Если товар другой — подтвердите ниже.`, `Brend, hajm va qadoq mos keladi. «Shu» ${item.barcode} shtrix-kodini shu mahsulotga qoʻshadi. Boshqa mahsulot boʻlsa — pastda tasdiqlang.`)
                    : tr('Бренд, объём и фасовка совпадают. Если товар другой — подтвердите ниже.', 'Brend, hajm va qadoq mos keladi. Boshqa mahsulot boʻlsa — pastda tasdiqlang.')}
                </Typography.Text>
              )}
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
                  <RemoteSelect<DictItem>
                    path="/store/catalog/brands"
                    search
                    allowClear
                    // Бренд, который нашёл Super Market, может не попасть в первые 50 вариантов — без подписи Select показал бы id.
                    selectedLabel={res?.brand_id ? res.brand || undefined : undefined}
                    placeholder={tr('Выберите или впишите ниже', 'Tanlang yoki pastda yozing')}
                  />
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

/** В2: «Похоже, этот товар уже есть в «Новых»» — с кнопкой «Это он». */
function DupBlock({ dup, loading, onMerge }: { dup: NewItemDup; loading: boolean; onMerge: (d: NewItemDup) => void }) {
  const name = dup.name || (dup.status === 'processing' ? tr('Распознаётся…', 'Aniqlanmoqda…') : tr('Не удалось распознать', 'Aniqlab boʻlmadi'))
  return (
    <Flex vertical gap={10} style={{ background: AMBER.bg, border: `1px solid ${AMBER.border}`, borderRadius: 12, padding: '12px 14px' }}>
      <Flex align="center" gap={8}>
        <CopyOutlined style={{ color: AMBER.icon }} />
        <Typography.Text strong style={{ color: AMBER.text }}>
          {tr('Похоже, этот товар уже есть в «Требуют внимания»', 'Bu mahsulot «Eʼtibor talab qiladi»da allaqachon borga oʻxshaydi')}
        </Typography.Text>
      </Flex>
      <Flex align="center" gap={12} wrap style={{ background: '#fff', borderRadius: 10, padding: '10px 12px' }}>
        <Thumb src={dup.image} size={44} />
        <div style={{ flex: 1, minWidth: 160 }}>
          <Typography.Text strong style={{ display: 'block', fontWeight: 600 }}>
            {name}
          </Typography.Text>
          <Typography.Text type="secondary" style={{ fontSize: 12 }}>
            {[dup.barcode, newItemState(dup.status)].filter(Boolean).join(' · ')}
          </Typography.Text>
        </div>
        <Button type="primary" icon={<CheckOutlined />} loading={loading} onClick={() => onMerge(dup)}>
          {tr('Это он — убрать эту карточку', 'Shu — bu kartochkani olib tashlash')}
        </Button>
      </Flex>
      <Typography.Text style={{ fontSize: 12, color: AMBER.text }}>
        {tr(
          '«Это он» — фото этой карточки добавятся к той, а эта уберётся. Если это другой товар — просто подтвердите ниже.',
          '«Shu» — bu kartochkaning rasmlari oʻshanga qoʻshiladi, bu esa olib tashlanadi. Boshqa mahsulot boʻlsa — pastda tasdiqlang.',
        )}
      </Typography.Text>
    </Flex>
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
