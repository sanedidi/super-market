// Курьеры магазина: смена, транспорт, активные заказы и последняя точка.
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Card, Input, Modal, Popconfirm, Space, Table, Tag, Typography } from 'antd'
import { CopyOutlined, EnvironmentOutlined, KeyOutlined, ReloadOutlined, StopOutlined } from '@ant-design/icons'
import dayjs from 'dayjs'
import { LoadError, PageTitle, api, dateTime, errorText, formatPhone, generatePassword, suggestLogin, tr, useAction, type List } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import type { Courier } from '../types'

export const vehicleTitles: Record<Courier['vehicle'], string> = { foot: tr('Пешком', 'Piyoda'), bike: tr('Велосипед', 'Velosiped'), scooter: tr('Самокат', 'Samokat'), car: tr('Машина', 'Mashina') }

/** Точка старше этого считается устаревшей (как у покупателя в отслеживании). */
const FRESH_MIN = 10

export function CouriersPage() {
  const { storeId } = useStore()
  const params = { store_id: storeId }
  const { data, isLoading, isFetching, error, refetch, dataUpdatedAt } = useQuery({
    queryKey: ['/store/couriers', params],
    queryFn: () => api.get<List<Courier>>('/store/couriers', params).then((r) => r.items ?? []),
    enabled: !!storeId,
    refetchInterval: 15_000,
  })
  const onShift = (data ?? []).filter((c) => c.on_shift).length
  const [editing, setEditing] = useState<Courier | null>(null)

  return (
    <NeedStore>
      <PageTitle
        title={tr('Курьеры', 'Kuryerlar')}
        extra={
          <Button icon={<ReloadOutlined spin={isFetching} />} onClick={() => refetch()}>
            {dataUpdatedAt ? dayjs(dataUpdatedAt).format('HH:mm:ss') : tr('Обновить', 'Yangilash')}
          </Button>
        }
      >
        <Typography.Text type="secondary">
          {tr(`На смене: ${onShift} из ${data?.length ?? 0}`, `Smenada: ${onShift} / ${data?.length ?? 0}`)}
        </Typography.Text>
      </PageTitle>
      <LoadError error={error} retry={() => refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<Courier>
          rowKey="employee_id"
          loading={isLoading}
          dataSource={data}
          scroll={{ x: true }}
          pagination={false}
          locale={{ emptyText: tr('Курьеров нет: дайте сотруднику право «Курьер: доставка заказов»', 'Kuryerlar yoʻq: xodimga «Kuryer: buyurtmalarni yetkazish» huquqini bering') }}
          columns={[
            { title: tr('Курьер', 'Kuryer'), dataIndex: 'full_name' },
            {
              title: tr('Телефон', 'Telefon'),
              dataIndex: 'phone',
              render: (v: string) => <a href={`tel:${v}`}>{formatPhone(v)}</a>,
            },
            { title: tr('Транспорт', 'Transport'), dataIndex: 'vehicle', render: (v: Courier['vehicle']) => vehicleTitles[v] ?? v },
            {
              title: tr('Смена', 'Smena'),
              dataIndex: 'on_shift',
              render: (v: boolean) => (v ? <Tag color="green">{tr('На смене', 'Smenada')}</Tag> : <Tag>{tr('Не на смене', 'Smenada emas')}</Tag>),
            },
            {
              title: tr('Активных заказов', 'Faol buyurtmalar'),
              dataIndex: 'active_orders',
              align: 'right',
              render: (v: number) => (v > 0 ? <b>{v}</b> : <Typography.Text type="secondary">0</Typography.Text>),
            },
            {
              title: tr('Приложение курьера', 'Kuryer ilovasi'),
              key: 'login',
              render: (_, c) => (
                <Space direction="vertical" size={2}>
                  {c.login ? (
                    <Space size={6}>
                      <Tag color="blue" icon={<KeyOutlined />}>
                        {c.login}
                      </Tag>
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                        {c.last_login_at ? tr(`вход ${dateTime(c.last_login_at)}`, `kirish ${dateTime(c.last_login_at)}`) : tr('ещё не входил', 'hali kirmagan')}
                      </Typography.Text>
                    </Space>
                  ) : (
                    <Typography.Text type="secondary">{tr('Нет входа', 'Kirish yoʻq')}</Typography.Text>
                  )}
                  <Button size="small" type="link" style={{ padding: 0 }} onClick={() => setEditing(c)}>
                    {c.login ? tr('Сменить логин или пароль', 'Login yoki parolni oʻzgartirish') : tr('Выдать логин и пароль', 'Login va parol berish')}
                  </Button>
                </Space>
              ),
            },
            {
              title: tr('Последняя точка', 'Oxirgi nuqta'),
              key: 'loc',
              render: (_, c) => {
                if (!c.located_at || c.lat === null || c.lng === null) return <Typography.Text type="secondary">{tr('Нет данных', 'Maʼlumot yoʻq')}</Typography.Text>
                const stale = dayjs().diff(dayjs(c.located_at), 'minute') >= FRESH_MIN
                return (
                  <Space size={4} wrap>
                    <Typography.Text type={stale ? 'secondary' : undefined}>{dateTime(c.located_at)}</Typography.Text>
                    {stale && <Tag>{tr('устарела', 'eskirgan')}</Tag>}
                    <a href={`https://yandex.ru/maps/?pt=${c.lng},${c.lat}&z=16&l=map`} target="_blank" rel="noreferrer">
                      <EnvironmentOutlined /> {tr('На карте', 'Xaritada')}
                    </a>
                  </Space>
                )
              },
            },
          ]}
        />
      </Card>
      <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
        {tr(
          'Курьер входит в приложение «Super Market Курьер» по логину и паролю, которые выдаёт магазин. Курьер — сотрудник с правом «Курьер: доставка заказов».',
          'Kuryer «Super Market Курьер» ilovasiga doʻkon bergan login va parol bilan kiradi. Kuryer — «Kuryer: buyurtmalarni yetkazish» huquqiga ega xodim.',
        )}
      </Typography.Paragraph>
      <CourierLoginModal courier={editing} onClose={() => setEditing(null)} />
    </NeedStore>
  )
}

function CourierLoginModal({ courier, onClose }: { courier: Courier | null; onClose: () => void }) {
  const { message } = App.useApp()
  const [login, setLogin] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [saved, setSaved] = useState<{ login: string; password: string } | null>(null)
  useEffect(() => {
    if (!courier) return
    setLogin(courier.login ?? suggestLogin(courier.full_name))
    setPassword(courier.login ? '' : generatePassword())
    setError('')
    setSaved(null)
  }, [courier])
  const save = useAction(
    (v: { login: string; password: string }) => api.put(`/store/couriers/${courier!.employee_id}/login`, v),
    { invalidate: [['/store/couriers']] },
  )
  const disable = useAction(() => api.del(`/store/couriers/${courier!.employee_id}/login`), {
    success: tr('Вход отключён', 'Kirish oʻchirildi'),
    invalidate: [['/store/couriers']],
  })
  const copy = (text: string) => navigator.clipboard?.writeText(text).then(() => message.success(tr('Скопировано', 'Nusxa olindi')))
  const onSave = () => {
    setError('')
    const v = { login: login.trim().toLowerCase(), password }
    save.mutateAsync(v).then(
      () => setSaved(v),
      (e) => setError(errorText(e)),
    )
  }
  return (
    <Modal
      open={!!courier}
      onCancel={onClose}
      width={520}
      title={
        <Space>
          <KeyOutlined style={{ color: '#e11d2a' }} />
          {tr('Вход в приложение курьера', 'Kuryer ilovasiga kirish')}
        </Space>
      }
      footer={
        saved
          ? [
              <Button key="ok" type="primary" onClick={onClose}>
                {tr('Готово', 'Tayyor')}
              </Button>,
            ]
          : [
              courier?.login ? (
                <Popconfirm
                  key="off"
                  title={tr('Отключить вход? Курьер выйдет из приложения.', 'Kirish oʻchirilsinmi? Kuryer ilovadan chiqariladi.')}
                  okText={tr('Отключить', 'Oʻchirish')}
                  cancelText={tr('Нет', 'Yoʻq')}
                  onConfirm={() => disable.mutateAsync(undefined).then(onClose, () => undefined)}
                >
                  <Button danger icon={<StopOutlined />} style={{ float: 'left' }} loading={disable.isPending}>
                    {tr('Отключить вход', 'Kirishni oʻchirish')}
                  </Button>
                </Popconfirm>
              ) : null,
              <Button key="cancel" onClick={onClose}>
                {tr('Отмена', 'Bekor qilish')}
              </Button>,
              <Button key="save" type="primary" loading={save.isPending} onClick={onSave}>
                {tr('Сохранить', 'Saqlash')}
              </Button>,
            ]
      }
    >
      {courier && (
        <Typography.Paragraph type="secondary">
          {courier.full_name} · {formatPhone(courier.phone)}
        </Typography.Paragraph>
      )}
      {saved ? (
        <Space direction="vertical" style={{ width: '100%' }}>
          <Alert type="success" showIcon message={tr('Сохранено. Передайте данные курьеру лично — пароль больше не покажем.', 'Saqlandi. Maʼlumotlarni kuryerga shaxsan bering — parol boshqa koʻrsatilmaydi.')} />
          <Card size="small">
            <Space direction="vertical" style={{ width: '100%' }}>
              <Space style={{ justifyContent: 'space-between', width: '100%' }}>
                <span>
                  {tr('Логин:', 'Login:')} <b>{saved.login}</b>
                </span>
                <Button size="small" icon={<CopyOutlined />} onClick={() => copy(saved.login)} />
              </Space>
              {saved.password && (
                <Space style={{ justifyContent: 'space-between', width: '100%' }}>
                  <span>
                    {tr('Пароль:', 'Parol:')} <b>{saved.password}</b>
                  </span>
                  <Button size="small" icon={<CopyOutlined />} onClick={() => copy(saved.password)} />
                </Space>
              )}
              <Button
                size="small"
                icon={<CopyOutlined />}
                onClick={() =>
                  copy(
                    tr(
                      `Super Market Курьер\nЛогин: ${saved.login}${saved.password ? `\nПароль: ${saved.password}` : ''}`,
                      `Super Market Курьер\nLogin: ${saved.login}${saved.password ? `\nParol: ${saved.password}` : ''}`,
                    ),
                  )
                }
              >
                {tr('Скопировать для отправки', 'Yuborish uchun nusxa olish')}
              </Button>
            </Space>
          </Card>
        </Space>
      ) : (
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              {tr('Логин', 'Login')}
            </Typography.Text>
            <Input value={login} onChange={(e) => setLogin(e.target.value)} placeholder="aziz.karimov" maxLength={32} />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('Латиница, цифры, точка, дефис — 3–32 символа. Должен быть уникальным.', 'Lotin harflari, raqamlar, nuqta, chiziqcha — 3–32 ta belgi. Takrorlanmas boʻlishi kerak.')}
            </Typography.Text>
          </div>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              {courier?.login ? tr('Новый пароль', 'Yangi parol') : tr('Пароль', 'Parol')}
            </Typography.Text>
            <Space.Compact style={{ width: '100%' }}>
              <Input
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={courier?.login ? tr('Оставьте пустым, чтобы не менять', 'Oʻzgartirmaslik uchun boʻsh qoldiring') : tr('Не меньше 8 символов', 'Kamida 8 ta belgi')}
                maxLength={72}
              />
              <Button onClick={() => setPassword(generatePassword())}>{tr('Сгенерировать', 'Yaratish')}</Button>
            </Space.Compact>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('Не меньше 8 символов. После смены пароля курьер выйдет на всех телефонах.', 'Kamida 8 ta belgi. Parol oʻzgartirilgach, kuryer barcha telefonlardan chiqariladi.')}
            </Typography.Text>
          </div>
          {error && <Alert type="error" showIcon message={error} />}
          <Alert
            type="warning"
            showIcon
            message={tr('Передайте логин и пароль курьеру лично. Пароль больше нигде не показывается — только сбросить.', 'Login va parolni kuryerga shaxsan bering. Parol boshqa hech qayerda koʻrsatilmaydi — faqat tiklash mumkin.')}
          />
        </Space>
      )}
    </Modal>
  )
}
