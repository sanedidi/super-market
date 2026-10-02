// Курьеры «по пути»: продавец проверяет личность курьера по документу
// (скан не хранится) и видит бонусы магазина за проверенных курьеров.
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, Button, Card, Checkbox, Col, DatePicker, Descriptions, Form, Input, Modal, Row, Segmented, Space, Statistic, Table, Tag, Typography } from 'antd'
import { QrcodeOutlined, SafetyCertificateOutlined } from '@ant-design/icons'
import dayjs, { type Dayjs } from 'dayjs'
import { LoadError, PageTitle, api, dateTime, formatPhone, money, useAction } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import { QrCodeModal } from '../qr'
import type { CrowdCourierCard, StoreCrowdBonus, StoreCrowdBonuses } from '../types'

const statusTag: Record<CrowdCourierCard['status'], { color: string; title: string }> = {
  unverified: { color: 'orange', title: 'Не проверен' },
  active: { color: 'green', title: 'Личность подтверждена' },
  blocked: { color: 'red', title: 'Заблокирован' },
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
      <PageTitle title="Курьеры по пути">
        <Typography.Text type="secondary">Проверка личности новых курьеров и бонусы магазина</Typography.Text>
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
          Проверка курьера
        </Space>
      }
      extra={card && <Button onClick={reset}>Другой курьер</Button>}
    >
      {!card ? (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Typography.Paragraph type="secondary" style={{ margin: 0 }}>
            Курьер показывает QR из приложения и паспорт или ID-карту. Сверьте фото и данные — копию документа не снимайте и не храните.
          </Typography.Paragraph>
          <Button type="primary" size="large" icon={<QrcodeOutlined />} block onClick={() => setScan(true)}>
            Сканировать QR или ввести код
          </Button>
        </Space>
      ) : (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Descriptions size="small" bordered column={1}>
            <Descriptions.Item label="Код">
              <Typography.Text strong>{card.code}</Typography.Text> {st && <Tag color={st.color}>{st.title}</Tag>}
            </Descriptions.Item>
            <Descriptions.Item label="Телефон">
              <a href={`tel:${card.phone}`}>{formatPhone(card.phone)}</a>
            </Descriptions.Item>
            {card.full_name && <Descriptions.Item label="Имя">{card.full_name}</Descriptions.Item>}
            {card.status !== 'unverified' && (
              <>
                <Descriptions.Item label="Уровень">{card.level}</Descriptions.Item>
                <Descriptions.Item label="Доставок">{card.delivered}</Descriptions.Item>
                <Descriptions.Item label="Проверен">
                  {dateTime(card.verified_at)}
                  {card.verified_store && <Typography.Text type="secondary"> · {card.verified_store}</Typography.Text>}
                </Descriptions.Item>
              </>
            )}
          </Descriptions>

          {card.status === 'active' && <Alert type="success" showIcon message="Личность подтверждена — курьер может брать заказы" />}
          {card.status === 'blocked' && <Alert type="error" showIcon message="Курьер заблокирован. Проверка невозможна" />}

          {card.status === 'unverified' && (
            <Form<VerifyForm> form={form} layout="vertical" requiredMark={false} initialValues={{ doc_type: 'passport' }} onFinish={approve}>
              <Form.Item name="doc_type" label="Документ">
                <Segmented
                  options={[
                    { value: 'passport', label: 'Паспорт' },
                    { value: 'id_card', label: 'ID-карта' },
                  ]}
                />
              </Form.Item>
              <Form.Item name="full_name" label="ФИО как в документе" rules={[{ required: true, whitespace: true, message: 'Введите ФИО' }]}>
                <Input placeholder="Иванов Иван Иванович" maxLength={120} />
              </Form.Item>
              <Row gutter={12}>
                <Col xs={24} sm={12}>
                  <Form.Item
                    name="birth_date"
                    label="Дата рождения"
                    rules={[
                      { required: true, message: 'Укажите дату' },
                      {
                        validator: (_, v?: Dayjs) =>
                          !v || dayjs().diff(v, 'year') >= 18 ? Promise.resolve() : Promise.reject(new Error('Курьеру должно быть 18 лет')),
                      },
                    ]}
                  >
                    <DatePicker format="DD.MM.YYYY" style={{ width: '100%' }} disabledDate={(d) => d.isAfter(dayjs())} />
                  </Form.Item>
                </Col>
                <Col xs={24} sm={12}>
                  <Form.Item
                    name="doc_last4"
                    label="Последние 4 цифры номера"
                    rules={[{ required: true, pattern: /^[0-9]{4}$/, message: '4 цифры' }]}
                  >
                    <Input inputMode="numeric" maxLength={4} placeholder="1234" />
                  </Form.Item>
                </Col>
              </Row>
              <Form.Item
                name="photo_match"
                valuePropName="checked"
                rules={[{ validator: (_, v) => (v ? Promise.resolve() : Promise.reject(new Error('Сверьте фото'))) }]}
                style={{ marginBottom: 4 }}
              >
                <Checkbox>Фото в документе совпадает с человеком</Checkbox>
              </Form.Item>
              <Form.Item
                name="doc_valid"
                valuePropName="checked"
                rules={[{ validator: (_, v) => (v ? Promise.resolve() : Promise.reject(new Error('Проверьте срок действия'))) }]}
              >
                <Checkbox>Документ действителен</Checkbox>
              </Form.Item>
              <Space wrap>
                <Button type="primary" htmlType="submit" loading={verify.isPending && !rejecting}>
                  Подтвердить личность
                </Button>
                <Button danger onClick={() => setRejecting(true)}>
                  Отказать
                </Button>
              </Space>
            </Form>
          )}
        </Space>
      )}

      <QrCodeModal
        open={scan}
        title="Код курьера"
        hint="QR на главном экране приложения курьера, под ним код вида KR-12345"
        placeholder="KR-12345"
        okText="Найти"
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
        title="Отказать в проверке"
        okText="Отказать"
        okButtonProps={{ danger: true, disabled: !reason.trim(), loading: verify.isPending }}
        onOk={reject}
        onCancel={() => setRejecting(false)}
      >
        <Input.TextArea
          rows={3}
          maxLength={500}
          placeholder="Например: фото не совпадает, документ просрочен"
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
    <Card title="Бонусы магазина">
      <LoadError error={error} retry={() => refetch()} />
      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={8}>
          <Statistic title="Начислено за месяц" value={money(data?.credited_month)} loading={isLoading} />
        </Col>
        <Col span={8}>
          <Statistic title="Ожидает" value={money(data?.pending)} loading={isLoading} />
        </Col>
        <Col span={8}>
          <Statistic title="Проверено курьеров" value={data?.verified ?? 0} loading={isLoading} />
        </Col>
      </Row>
      {data && (
        <Typography.Paragraph type="secondary">
          {money(data.per_delivery)} сум за каждую из первых {data.max_deliveries} доставок проверенного вами курьера. Бонус начисляется после
          проверочного срока, если у курьера нет нарушений.
        </Typography.Paragraph>
      )}
      <Table<StoreCrowdBonus>
        rowKey="courier_id"
        size="small"
        loading={isLoading}
        dataSource={data?.items ?? []}
        pagination={{ pageSize: 10, hideOnSinglePage: true }}
        scroll={{ x: true }}
        locale={{ emptyText: 'Вы ещё не проверяли курьеров' }}
        columns={[
          {
            title: 'Курьер',
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
          { title: 'Проверен', dataIndex: 'verified_at', render: (v: string) => dateTime(v) },
          {
            title: 'Доставок',
            dataIndex: 'deliveries',
            align: 'right',
            render: (v: number) => `${v} из ${data?.max_deliveries ?? 0}`,
          },
          { title: 'Начислено', dataIndex: 'credited', align: 'right', render: (v: string) => money(v) },
          { title: 'Ожидает', dataIndex: 'pending', align: 'right', render: (v: string) => money(v) },
        ]}
      />
    </Card>
  )
}
