// Курьеры магазина: смена, транспорт, активные заказы и последняя точка.
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, App, Button, Card, Input, Modal, Popconfirm, Space, Table, Tag, Typography } from 'antd'
import { CopyOutlined, EnvironmentOutlined, KeyOutlined, ReloadOutlined, StopOutlined } from '@ant-design/icons'
import dayjs from 'dayjs'
import { LoadError, PageTitle, api, dateTime, errorText, useAction, type List } from '@sm/shared'
import { useStore } from '../ctx'
import { NeedStore } from '../ui'
import type { Courier } from '../types'

export const vehicleTitles: Record<Courier['vehicle'], string> = { foot: 'Пешком', bike: 'Велосипед', scooter: 'Самокат', car: 'Машина' }

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
        title="Курьеры"
        extra={
          <Button icon={<ReloadOutlined spin={isFetching} />} onClick={() => refetch()}>
            {dataUpdatedAt ? dayjs(dataUpdatedAt).format('HH:mm:ss') : 'Обновить'}
          </Button>
        }
      >
        <Typography.Text type="secondary">
          На смене: {onShift} из {data?.length ?? 0}
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
          locale={{ emptyText: 'Курьеров нет: дайте сотруднику право «Курьер: доставка заказов»' }}
          columns={[
            { title: 'Курьер', dataIndex: 'full_name' },
            {
              title: 'Телефон',
              dataIndex: 'phone',
              render: (v: string) => <a href={`tel:${v}`}>{v}</a>,
            },
            { title: 'Транспорт', dataIndex: 'vehicle', render: (v: Courier['vehicle']) => vehicleTitles[v] ?? v },
            {
              title: 'Смена',
              dataIndex: 'on_shift',
              render: (v: boolean) => (v ? <Tag color="green">На смене</Tag> : <Tag>Не на смене</Tag>),
            },
            {
              title: 'Активных заказов',
              dataIndex: 'active_orders',
              align: 'right',
              render: (v: number) => (v > 0 ? <b>{v}</b> : <Typography.Text type="secondary">0</Typography.Text>),
            },
            {
              title: 'Приложение курьера',
              key: 'login',
              render: (_, c) => (
                <Space direction="vertical" size={2}>
                  {c.login ? (
                    <Space size={6}>
                      <Tag color="blue" icon={<KeyOutlined />}>
                        {c.login}
                      </Tag>
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                        {c.last_login_at ? `вход ${dateTime(c.last_login_at)}` : 'ещё не входил'}
                      </Typography.Text>
                    </Space>
                  ) : (
                    <Typography.Text type="secondary">Нет входа</Typography.Text>
                  )}
                  <Button size="small" type="link" style={{ padding: 0 }} onClick={() => setEditing(c)}>
                    {c.login ? 'Сменить логин или пароль' : 'Выдать логин и пароль'}
                  </Button>
                </Space>
              ),
            },
            {
              title: 'Последняя точка',
              key: 'loc',
              render: (_, c) => {
                if (!c.located_at || c.lat === null || c.lng === null) return <Typography.Text type="secondary">Нет данных</Typography.Text>
                const stale = dayjs().diff(dayjs(c.located_at), 'minute') >= FRESH_MIN
                return (
                  <Space size={4} wrap>
                    <Typography.Text type={stale ? 'secondary' : undefined}>{dateTime(c.located_at)}</Typography.Text>
                    {stale && <Tag>устарела</Tag>}
                    <a href={`https://yandex.ru/maps/?pt=${c.lng},${c.lat}&z=16&l=map`} target="_blank" rel="noreferrer">
                      <EnvironmentOutlined /> На карте
                    </a>
                  </Space>
                )
              },
            },
          ]}
        />
      </Card>
      <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
        Курьер входит в приложение «Super Market Курьер» по логину и паролю, которые выдаёт магазин. Курьер — сотрудник с правом
        «Курьер: доставка заказов».
      </Typography.Paragraph>
      <CourierLoginModal courier={editing} onClose={() => setEditing(null)} />
    </NeedStore>
  )
}

/** Пароль из 3 групп: «kx7-Lam4-pz9» — легко продиктовать. */
function generatePassword() {
  const abc = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  const rnd = new Uint32Array(10)
  crypto.getRandomValues(rnd)
  const ch = (i: number) => abc[rnd[i] % abc.length]
  return `${ch(0)}${ch(1)}${ch(2)}-${ch(3)}${ch(4)}${ch(5)}${ch(6)}-${ch(7)}${ch(8)}${ch(9)}`
}

/** Логин из имени: «Азиз Каримов» → «aziz.karimov». */
function suggestLogin(name: string) {
  const map: Record<string, string> = {
    а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'yo', ж: 'j', з: 'z', и: 'i', й: 'y', к: 'k', л: 'l', м: 'm', н: 'n', о: 'o',
    п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'x', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'sh', ъ: '', ы: 'i', ь: '', э: 'e', ю: 'yu',
    я: 'ya', ў: 'o', қ: 'q', ғ: 'g', ҳ: 'h',
  }
  const s = name
    .toLowerCase()
    .split('')
    .map((c) => map[c] ?? c)
    .join('')
    .replace(/[^a-z0-9]+/g, '.')
    .replace(/^\.+|\.+$/g, '')
    .slice(0, 32)
  return s.length >= 3 ? s : ''
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
    success: 'Вход отключён',
    invalidate: [['/store/couriers']],
  })
  const copy = (text: string) => navigator.clipboard?.writeText(text).then(() => message.success('Скопировано'))
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
          Вход в приложение курьера
        </Space>
      }
      footer={
        saved
          ? [
              <Button key="ok" type="primary" onClick={onClose}>
                Готово
              </Button>,
            ]
          : [
              courier?.login ? (
                <Popconfirm
                  key="off"
                  title="Отключить вход? Курьер выйдет из приложения."
                  okText="Отключить"
                  cancelText="Нет"
                  onConfirm={() => disable.mutateAsync(undefined).then(onClose, () => undefined)}
                >
                  <Button danger icon={<StopOutlined />} style={{ float: 'left' }} loading={disable.isPending}>
                    Отключить вход
                  </Button>
                </Popconfirm>
              ) : null,
              <Button key="cancel" onClick={onClose}>
                Отмена
              </Button>,
              <Button key="save" type="primary" loading={save.isPending} onClick={onSave}>
                Сохранить
              </Button>,
            ]
      }
    >
      {courier && (
        <Typography.Paragraph type="secondary">
          {courier.full_name} · {courier.phone}
        </Typography.Paragraph>
      )}
      {saved ? (
        <Space direction="vertical" style={{ width: '100%' }}>
          <Alert type="success" showIcon message="Сохранено. Передайте данные курьеру лично — пароль больше не покажем." />
          <Card size="small">
            <Space direction="vertical" style={{ width: '100%' }}>
              <Space style={{ justifyContent: 'space-between', width: '100%' }}>
                <span>
                  Логин: <b>{saved.login}</b>
                </span>
                <Button size="small" icon={<CopyOutlined />} onClick={() => copy(saved.login)} />
              </Space>
              {saved.password && (
                <Space style={{ justifyContent: 'space-between', width: '100%' }}>
                  <span>
                    Пароль: <b>{saved.password}</b>
                  </span>
                  <Button size="small" icon={<CopyOutlined />} onClick={() => copy(saved.password)} />
                </Space>
              )}
              <Button
                size="small"
                icon={<CopyOutlined />}
                onClick={() => copy(`Super Market Курьер\nЛогин: ${saved.login}${saved.password ? `\nПароль: ${saved.password}` : ''}`)}
              >
                Скопировать для отправки
              </Button>
            </Space>
          </Card>
        </Space>
      ) : (
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              Логин
            </Typography.Text>
            <Input value={login} onChange={(e) => setLogin(e.target.value)} placeholder="aziz.karimov" maxLength={32} />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              Латиница, цифры, точка, дефис — 3–32 символа. Должен быть уникальным.
            </Typography.Text>
          </div>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              {courier?.login ? 'Новый пароль' : 'Пароль'}
            </Typography.Text>
            <Space.Compact style={{ width: '100%' }}>
              <Input
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={courier?.login ? 'Оставьте пустым, чтобы не менять' : 'Не меньше 8 символов'}
                maxLength={72}
              />
              <Button onClick={() => setPassword(generatePassword())}>Сгенерировать</Button>
            </Space.Compact>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              Не меньше 8 символов. После смены пароля курьер выйдет на всех телефонах.
            </Typography.Text>
          </div>
          {error && <Alert type="error" showIcon message={error} />}
          <Alert
            type="warning"
            showIcon
            message="Передайте логин и пароль курьеру лично. Пароль больше нигде не показывается — только сбросить."
          />
        </Space>
      )}
    </Modal>
  )
}
