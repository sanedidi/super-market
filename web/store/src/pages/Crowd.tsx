// Курьеры «по пути»: продавец проверяет личность курьера по документу
// (скан не хранится) и видит бонусы магазина за проверенных курьеров.
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, Button, Card, Checkbox, Col, DatePicker, Descriptions, Form, Input, Modal, Row, Segmented, Space, Statistic, Table, Tag, Typography } from 'antd'
import { QrcodeOutlined, SafetyCertificateOutlined } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { LoadError, PageTitle, api, dateTime, formatPhone, money, tr, useAction } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import { QrCodeModal } from '../qr'
import type { CrowdCourierCard, StoreCrowdBonus, StoreCrowdBonuses } from '../types'

const statusTag: Record<CrowdCourierCard['status'], { color: string; title: string }> = {
  unverified: { color: 'orange', title: tr('Не проверен', 'Tekshirilmagan') },
  active: { color: 'green', title: tr('Личность подтверждена', 'Shaxsi tasdiqlangan') },
  blocked: { color: 'red', title: tr('Заблокирован', 'Bloklangan') },
}

type VerifyForm = {
  doc_type: 'passport' | 'id_card'
  full_name: string
  birth_date: Dayjs
  doc_last4: string
  photo_match: boolean
  doc_valid: boolean
}

export function CrowdPage() {
  return (
    <NeedStore>
      <PageTitle title={tr('Курьеры по пути', 'Yoʻlakay kuryerlar')}>
        <Typography.Text type="secondary">{tr('Проверка личности новых курьеров и бонусы магазина', 'Yangi kuryerlar shaxsini tekshirish va doʻkon bonuslari')}</Typography.Text>
      </PageTitle>
      <Row gutter={[16, 16]}>
        <Col xs={24} xl={12}>
          <VerifyCard />
        </Col>
        <Col xs={24} xl={12}>
          <BonusesCard />
        </Col>
      </Row>
    </NeedStore>
  )
}

function VerifyCard() {
  const { storeId } = useStore()
  const [scan, setScan] = useState(false)
  const [card, setCard] = useState<CrowdCourierCard | null>(null)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [form] = Form.useForm<VerifyForm>()

  const lookup = useAction((code: string) => api.post<CrowdCourierCard>('/store/crowd/lookup', { code }), { invalidate: [] })
  const verify = useAction(
    (body: Record<string, unknown>) => api.post<CrowdCourierCard>('/store/crowd/verify', { ...body, code: card?.code, store_id: storeId }),
    { invalidate: [['/store/crowd/bonuses']] },
  )

  const reset = () => {
    setCard(null)
    form.resetFields()
  }

  const approve = (v: VerifyForm) =>
    verify.mutate(
      {
        decision: 'approve',
        doc_type: v.doc_type,
        full_name: v.full_name.trim(),
        birth_date: v.birth_date.format('YYYY-MM-DD'),
        doc_last4: v.doc_last4,
        photo_match: !!v.photo_match,
        doc_valid: !!v.doc_valid,
      },
      { onSuccess: (c) => setCard(c) },
    )

  const reject = () =>
    verify.mutate(
      { decision: 'reject', reason: reason.trim() },
      {
        onSuccess: (c) => {
          setRejecting(false)
          setReason('')
          setCard(c)
        },
      },
    )

  const st = card ? statusTag[card.status] : null

  return (
    <Card
      title={
        <Space>
          <SafetyCertificateOutlined />
          {tr('Проверка курьера', 'Kuryerni tekshirish')}
        </Space>
      }
      extra={card && <Button onClick={reset}>{tr('Другой курьер', 'Boshqa kuryer')}</Button>}
    >
      {!card ? (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Typography.Paragraph type="secondary" style={{ margin: 0 }}>
            {tr('Курьер показывает QR из приложения и паспорт или ID-карту. Сверьте фото и данные — копию документа не снимайте и не храните.', 'Kuryer ilovadagi QR kodni va pasport yoki ID-kartani koʻrsatadi. Rasm va maʼlumotlarni solishtiring — hujjat nusxasini olmang va saqlamang.')}
          </Typography.Paragraph>
          <Button type="primary" size="large" icon={<QrcodeOutlined />} block onClick={() => setScan(true)}>
            {tr('Сканировать QR или ввести код', 'QR kodni skanerlash yoki kodni kiritish')}
          </Button>
        </Space>
      ) : (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Descriptions size="small" bordered column={1}>
            <Descriptions.Item label={tr('Код', 'Kod')}>
              <Typography.Text strong>{card.code}</Typography.Text> {st && <Tag color={st.color}>{st.title}</Tag>}
            </Descriptions.Item>
            <Descriptions.Item label={tr('Телефон', 'Telefon')}>
              <a href={`tel:${card.phone}`}>{formatPhone(card.phone)}</a>
            </Descriptions.Item>
            {card.full_name && <Descriptions.Item label={tr('Имя', 'Ism')}>{card.full_name}</Descriptions.Item>}
            {card.status !== 'unverified' && (
              <>
                <Descriptions.Item label={tr('Уровень', 'Daraja')}>{card.level}</Descriptions.Item>
                <Descriptions.Item label={tr('Доставок', 'Yetkazishlar')}>{card.delivered}</Descriptions.Item>
                <Descriptions.Item label={tr('Проверен', 'Tekshirilgan')}>
                  {dateTime(card.verified_at)}
                  {card.verified_store && <Typography.Text type="secondary"> · {card.verified_store}</Typography.Text>}
                </Descriptions.Item>
              </>
            )}
          </Descriptions>

          {card.status === 'active' && <Alert type="success" showIcon message={tr('Личность подтверждена — курьер может брать заказы', 'Shaxsi tasdiqlandi — kuryer buyurtma olishi mumkin')} />}
          {card.status === 'blocked' && <Alert type="error" showIcon message={tr('Курьер заблокирован. Проверка невозможна', 'Kuryer bloklangan. Tekshirib boʻlmaydi')} />}

          {card.status === 'unverified' && (
            <Form<VerifyForm> form={form} layout="vertical" requiredMark={false} initialValues={{ doc_type: 'passport' }} onFinish={approve}>
              <Form.Item name="doc_type" label={tr('Документ', 'Hujjat')}>
                <Segmented
                  options={[
                    { value: 'passport', label: tr('Паспорт', 'Pasport') },
                    { value: 'id_card', label: tr('ID-карта', 'ID-karta') },
                  ]}
                />
              </Form.Item>
              <Form.Item name="full_name" label={tr('ФИО как в документе', 'F.I.Sh. hujjatdagidek')} rules={[{ required: true, whitespace: true, message: tr('Введите ФИО', 'F.I.Sh.ni kiriting') }]}>
                <Input placeholder={tr('Иванов Иван Иванович', 'Karimov Aziz Akramovich')} maxLength={120} />
              </Form.Item>
              <Row gutter={12}>
                <Col xs={24} sm={12}>
                  <Form.Item
                    name="birth_date"
                    label={tr('Дата рождения', 'Tugʻilgan sana')}
                    rules={[
                      { required: true, message: tr('Укажите дату', 'Sanani koʻrsating') },
                      {
                        validator: (_, v?: Dayjs) =>
                          !v || dayjs().diff(v, 'year') >= 18 ? Promise.resolve() : Promise.reject(new Error(tr('Курьеру должно быть 18 лет', 'Kuryer 18 yoshga toʻlgan boʻlishi kerak'))),
                      },
                    ]}
                  >
                    <DatePicker format="DD.MM.YYYY" style={{ width: '100%' }} disabledDate={(d) => d.isAfter(dayjs())} />
                  </Form.Item>
                </Col>
                <Col xs={24} sm={12}>
                  <Form.Item
                    name="doc_last4"
                    label={tr('Последние 4 цифры номера', 'Raqamning oxirgi 4 ta raqami')}
                    rules={[{ required: true, pattern: /^[0-9]{4}$/, message: tr('4 цифры', '4 ta raqam') }]}
                  >
                    <Input inputMode="numeric" maxLength={4} placeholder="1234" />
                  </Form.Item>
                </Col>
              </Row>
              <Form.Item
                name="photo_match"
                valuePropName="checked"
                rules={[{ validator: (_, v) => (v ? Promise.resolve() : Promise.reject(new Error(tr('Сверьте фото', 'Rasmni solishtiring')))) }]}
                style={{ marginBottom: 4 }}
              >
                <Checkbox>{tr('Фото в документе совпадает с человеком', 'Hujjatdagi rasm shaxsga mos keladi')}</Checkbox>
              </Form.Item>
              <Form.Item
                name="doc_valid"
                valuePropName="checked"
                rules={[{ validator: (_, v) => (v ? Promise.resolve() : Promise.reject(new Error(tr('Проверьте срок действия', 'Amal qilish muddatini tekshiring')))) }]}
              >
                <Checkbox>{tr('Документ действителен', 'Hujjat amal qiladi')}</Checkbox>
              </Form.Item>
              <Space wrap>
                <Button type="primary" htmlType="submit" loading={verify.isPending && !rejecting}>
                  {tr('Подтвердить личность', 'Shaxsni tasdiqlash')}
                </Button>
                <Button danger onClick={() => setRejecting(true)}>
                  {tr('Отказать', 'Rad etish')}
                </Button>
              </Space>
            </Form>
          )}
        </Space>
      )}

      <QrCodeModal
        open={scan}
        title={tr('Код курьера', 'Kuryer kodi')}
        hint={tr('QR на главном экране приложения курьера, под ним код вида KR-12345', 'QR kod kuryer ilovasining bosh ekranida, uning ostida KR-12345 koʻrinishidagi kod')}
        placeholder="KR-12345"
        okText={tr('Найти', 'Topish')}
        loading={lookup.isPending}
        onClose={() => setScan(false)}
        onSubmit={(code) =>
          lookup.mutate(code, {
            onSuccess: (c) => {
              setScan(false)
              form.resetFields()
              setCard(c)
            },
          })
        }
      />
      <Modal
        open={rejecting}
        title={tr('Отказать в проверке', 'Tekshiruvni rad etish')}
        okText={tr('Отказать', 'Rad etish')}
        okButtonProps={{ danger: true, disabled: !reason.trim(), loading: verify.isPending }}
        onOk={reject}
        onCancel={() => setRejecting(false)}
      >
        <Input.TextArea
          rows={3}
          maxLength={500}
          placeholder={tr('Например: фото не совпадает, документ просрочен', 'Masalan: rasm mos emas, hujjat muddati oʻtgan')}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />
      </Modal>
    </Card>
  )
}

function BonusesCard() {
  const { storeId } = useStore()
  const params = { store_id: storeId }
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['/store/crowd/bonuses', params],
    queryFn: () => api.get<StoreCrowdBonuses>('/store/crowd/bonuses', params),
    enabled: !!storeId,
  })
  return (
    <Card title={tr('Бонусы магазина', 'Doʻkon bonuslari')}>
      <LoadError error={error} retry={() => refetch()} />
      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={8}>
          <Statistic title={tr('Начислено за месяц', 'Oy davomida hisoblangan')} value={money(data?.credited_month)} loading={isLoading} />
        </Col>
        <Col span={8}>
          <Statistic title={tr('Ожидает', 'Kutilmoqda')} value={money(data?.pending)} loading={isLoading} />
        </Col>
        <Col span={8}>
          <Statistic title={tr('Проверено курьеров', 'Tekshirilgan kuryerlar')} value={data?.verified ?? 0} loading={isLoading} />
        </Col>
      </Row>
      {data && (
        <Typography.Paragraph type="secondary">
          {tr(
            `${money(data.per_delivery)} сум за каждую из первых ${data.max_deliveries} доставок проверенного вами курьера. Бонус начисляется после проверочного срока, если у курьера нет нарушений.`,
            `Siz tekshirgan kuryerning dastlabki ${data.max_deliveries} ta yetkazishining har biri uchun ${money(data.per_delivery)} soʻm. Bonus sinov muddatidan keyin, kuryerda qoidabuzarlik boʻlmasa, hisoblanadi.`,
          )}
        </Typography.Paragraph>
      )}
      <Table<StoreCrowdBonus>
        rowKey="courier_id"
        size="small"
        loading={isLoading}
        dataSource={data?.items ?? []}
        pagination={{ pageSize: 10, hideOnSinglePage: true }}
        scroll={{ x: true }}
        locale={{ emptyText: tr('Вы ещё не проверяли курьеров', 'Siz hali kuryerlarni tekshirmagansiz') }}
        columns={[
          {
            title: tr('Курьер', 'Kuryer'),
            dataIndex: 'name',
            render: (v: string, r) => (
              <>
                {v || '—'}
                <div>
                  <Typography.Text type="secondary">{r.code}</Typography.Text>
                </div>
              </>
            ),
          },
          { title: tr('Проверен', 'Tekshirilgan'), dataIndex: 'verified_at', render: (v: string) => dateTime(v) },
          {
            title: tr('Доставок', 'Yetkazishlar'),
            dataIndex: 'deliveries',
            align: 'right',
            render: (v: number) => tr(`${v} из ${data?.max_deliveries ?? 0}`, `${v} / ${data?.max_deliveries ?? 0}`),
          },
          { title: tr('Начислено', 'Hisoblangan'), dataIndex: 'credited', align: 'right', render: (v: string) => money(v) },
          { title: tr('Ожидает', 'Kutilmoqda'), dataIndex: 'pending', align: 'right', render: (v: string) => money(v) },
        ]}
      />
    </Card>
  )
}
