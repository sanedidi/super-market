// Вход владельца сети: логин и временный пароль выдаёт супер-админ
// (Figma «Вход по логину и паролю» → СА1, СА2, СА3).
import { useEffect, useState } from 'react'
import { Alert, App, Button, Card, Form, Input, Modal, Popconfirm, Space, Typography } from 'antd'
import { CheckCircleFilled, CopyOutlined, LockOutlined, ReloadOutlined, UserOutlined } from '@ant-design/icons'
import { LOGIN_RE, PhoneInput, api, dateTime, errorText, generatePassword, phoneRule, useAction } from '@sm/shared'

export interface OwnerInfo {
  id: string
  name: string
  owner_name: string
  owner_phone: string
  owner_login: string
  owner_temp_password: boolean
  owner_password_changed_at: string | null
  owner_last_login_at: string | null
}

const STORE_PANEL = 'store.super-market.uz'

export const loginRules = [
  { required: true, message: 'Придумайте логин' },
  {
    validator: (_: unknown, v?: string) =>
      !v || LOGIN_RE.test(v.trim().toLowerCase())
        ? Promise.resolve()
        : Promise.reject(new Error('Латиница, цифры, точка, дефис или _ — 3–32 символа')),
  },
]

const passwordRules = [
  { required: true, message: 'Задайте пароль' },
  { min: 8, message: 'Не меньше 8 символов' },
]

/** Поле временного пароля с «Сгенерировать» (внутри Form). */
function PasswordInput({ value, onChange }: { value?: string; onChange?: (v: string) => void }) {
  return (
    <Input
      prefix={<LockOutlined />}
      value={value}
      onChange={(e) => onChange?.(e.target.value)}
      maxLength={72}
      autoComplete="off"
      suffix={
        <Button type="link" size="small" icon={<ReloadOutlined />} onClick={() => onChange?.(generatePassword())} style={{ fontWeight: 700 }}>
          Сгенерировать
        </Button>
      }
    />
  )
}

/** СА1 — логин и временный пароль владельца в форме «Подключить сеть». */
export function OwnerLoginFields() {
  return (
    <>
      <Typography.Text strong style={{ display: 'block', margin: '4px 0 12px' }}>
        <LockOutlined style={{ color: '#155eef' }} /> Вход в панель магазина и «SM Магазин»
      </Typography.Text>
      <Form.Item
        name="owner_login"
        label="Логин"
        rules={loginRules}
        extra="Латиница, цифры, точка, дефис, подчёркивание — 3–32 символа. Уникальный."
        normalize={(v: string) => v.toLowerCase().replace(/\s/g, '')}
      >
        <Input prefix={<UserOutlined />} placeholder="olma" maxLength={32} autoComplete="off" />
      </Form.Item>
      <Form.Item
        name="owner_password"
        label="Временный пароль"
        rules={passwordRules}
        initialValue={generatePassword()}
        extra="При первом входе владелец придумает свой пароль."
      >
        <PasswordInput />
      </Form.Item>
      <Alert
        type="warning"
        showIcon
        message="Временный пароль покажем ещё раз после создания — скопируйте и передайте владельцу. Потом его не увидит никто, только сбросить."
      />
    </>
  )
}

export interface Credentials {
  title: string
  login: string
  password: string
}

/** СА2 — логин и пароль один раз после создания сети или сброса пароля. */
export function CredentialsModal({ value, onClose }: { value: Credentials | null; onClose: () => void }) {
  const { message } = App.useApp()
  const copy = (text: string) => navigator.clipboard?.writeText(text).then(() => message.success('Скопировано'))
  const all = value
    ? `Super Market — вход для магазина\nПанель: https://${STORE_PANEL}\nПриложение: SM Магазин (App Store, Google Play)\nЛогин: ${value.login}\nПароль: ${value.password}\nПри первом входе придумайте свой пароль.`
    : ''
  return (
    <Modal
      open={!!value}
      onCancel={onClose}
      width={520}
      maskClosable={false}
      title={
        <Space>
          <CheckCircleFilled style={{ color: '#17b26a' }} />
          {value?.title}
        </Space>
      }
      footer={[
        <Button key="copy" icon={<CopyOutlined />} onClick={() => copy(all)}>
          Скопировать всё
        </Button>,
        <Button key="ok" type="primary" onClick={onClose}>
          Готово
        </Button>,
      ]}
    >
      {value && (
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <Typography.Text type="secondary">
            Передайте владельцу данные для входа. Пароль временный — при первом входе он придумает свой.
          </Typography.Text>
          <Card size="small" styles={{ body: { padding: 0 } }}>
            {[
              ['Панель', STORE_PANEL, false],
              ['Приложение', 'SM Магазин (App Store, Google Play)', false],
              ['Логин', value.login, true],
              ['Пароль', value.password, true],
            ].map(([k, v, c], i) => (
              <div
                key={String(k)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 12,
                  padding: '10px 14px',
                  borderTop: i ? '1px solid #eaecf0' : undefined,
                }}
              >
                <Typography.Text type="secondary" style={{ width: 96, flex: 'none' }}>
                  {k}
                </Typography.Text>
                <Typography.Text strong style={{ flex: 1, fontSize: c ? 15 : 14 }}>
                  {v}
                </Typography.Text>
                {c && <Button size="small" type="text" icon={<CopyOutlined />} onClick={() => copy(String(v))} />}
              </div>
            ))}
          </Card>
          <Alert
            type="warning"
            showIcon
            message="После закрытия окна пароль больше не показывается. Если владелец его потеряет — «Сбросить пароль» в карточке сети."
          />
        </Space>
      )}
    </Modal>
  )
}

/** Состояние пароля владельца — для карточки сети и окна «Владелец и вход». */
export function OwnerPasswordState({ n }: { n: OwnerInfo }) {
  if (!n.owner_login) return <Typography.Text type="danger">Логина нет — владелец не может войти</Typography.Text>
  const last = n.owner_last_login_at ? `вход ${dateTime(n.owner_last_login_at)}` : 'ещё не входил'
  return n.owner_temp_password ? (
    <Typography.Text type="warning">Временный пароль — владелец ещё не придумал свой · {last}</Typography.Text>
  ) : (
    <Typography.Text type="secondary">
      Свой пароль{n.owner_password_changed_at ? ` с ${dateTime(n.owner_password_changed_at)}` : ''} · {last}
    </Typography.Text>
  )
}

/** СА3 — имя, телефон и логин владельца, сброс пароля. Только у супер-админа. */
export function OwnerModal({ network, onClose }: { network: OwnerInfo | null; onClose: () => void }) {
  const [form] = Form.useForm()
  const [creds, setCreds] = useState<Credentials | null>(null)
  const [error, setError] = useState('')
  const n = network
  useEffect(() => {
    if (!n) return
    setError('')
    form.setFieldsValue({
      owner_name: n.owner_name,
      owner_phone: n.owner_phone,
      owner_login: n.owner_login,
      owner_password: n.owner_login ? undefined : generatePassword(),
    })
  }, [n, form])

  const save = useAction(
    async (v: { owner_name: string; owner_phone: string; owner_login: string; owner_password?: string }) => {
      const id = n!.id
      const ownerChanged = v.owner_name.trim() !== n!.owner_name || v.owner_phone !== n!.owner_phone
      if (ownerChanged) await api.patch(`/admin/networks/${id}/owner`, { full_name: v.owner_name, phone: v.owner_phone })
      const login = v.owner_login.trim().toLowerCase()
      if (login !== n!.owner_login || !n!.owner_login) {
        await api.put(`/admin/networks/${id}/owner/login`, { login, password: n!.owner_login ? undefined : v.owner_password })
      }
      return { login, password: n!.owner_login ? '' : (v.owner_password ?? '') }
    },
    { success: 'Сохранено' },
  )
  const reset = useAction((login: string) => {
    const password = generatePassword()
    return api.put(`/admin/networks/${n!.id}/owner/login`, { login, password }).then(() => ({ login, password }))
  })

  const onFinish = (v: { owner_name: string; owner_phone: string; owner_login: string; owner_password?: string }) => {
    setError('')
    save.mutateAsync(v).then(
      (r) => {
        onClose()
        if (r.password) setCreds({ title: `Логин для «${n!.name}»`, ...r })
      },
      (e) => setError(errorText(e)),
    )
  }

  return (
    <>
      <Modal
        open={!!n}
        onCancel={onClose}
        width={560}
        title={
          <div>
            Владелец и вход
            <Typography.Text type="secondary" style={{ display: 'block', fontSize: 13, fontWeight: 400 }}>
              {n?.name}
            </Typography.Text>
          </div>
        }
        okText="Сохранить"
        cancelText="Отмена"
        onOk={() => form.submit()}
        confirmLoading={save.isPending}
        forceRender
      >
        <Form form={form} layout="vertical" requiredMark={false} onFinish={onFinish}>
          <Space.Compact block style={{ gap: 12 }}>
            <Form.Item name="owner_name" label="Имя владельца" rules={[{ required: true, whitespace: true }]} style={{ flex: 1 }}>
              <Input />
            </Form.Item>
            <Form.Item name="owner_phone" label="Телефон владельца" rules={[phoneRule(true)]} style={{ flex: 1 }}>
              <PhoneInput />
            </Form.Item>
          </Space.Compact>
          <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginTop: -12 }}>
            <LockOutlined /> Номер владельца меняет только супер-админ. В панели магазина он показан без возможности изменить. После смены
            номера владелец выйдет на всех устройствах; логин и пароль остаются.
          </Typography.Paragraph>
          <Form.Item
            name="owner_login"
            label="Логин"
            rules={loginRules}
            normalize={(v: string) => v.toLowerCase().replace(/\s/g, '')}
            extra={n?.owner_login ? 'Если поменять логин — владелец войдёт с новым логином и прежним паролем.' : undefined}
          >
            <Input prefix={<UserOutlined />} maxLength={32} autoComplete="off" />
          </Form.Item>
          {n && !n.owner_login && (
            <Form.Item
              name="owner_password"
              label="Временный пароль"
              rules={passwordRules}
              extra="При первом входе владелец придумает свой пароль."
            >
              <PasswordInput />
            </Form.Item>
          )}
          {n?.owner_login && (
            <Card size="small" style={{ background: '#f8fafc' }}>
              <Space style={{ width: '100%', justifyContent: 'space-between' }} align="center">
                <Space direction="vertical" size={0}>
                  <Typography.Text strong>
                    <LockOutlined /> Пароль
                  </Typography.Text>
                  <OwnerPasswordState n={n} />
                </Space>
                <Popconfirm
                  title="Сбросить пароль владельца?"
                  description="Создадим новый временный пароль. Владелец выйдет на всех устройствах."
                  okText="Сбросить"
                  cancelText="Нет"
                  onConfirm={() =>
                    reset.mutateAsync(n.owner_login).then(
                      (r) => {
                        onClose()
                        setCreds({ title: `Новый пароль для «${n.name}»`, ...r })
                      },
                      () => undefined,
                    )
                  }
                >
                  <Button danger icon={<ReloadOutlined />} loading={reset.isPending}>
                    Сбросить пароль
                  </Button>
                </Popconfirm>
              </Space>
            </Card>
          )}
          {error && <Alert type="error" showIcon message={error} style={{ marginTop: 16 }} />}
          <Alert
            type="info"
            showIcon
            style={{ marginTop: 16 }}
            message="«Сбросить пароль» создаёт новый временный пароль и показывает его один раз. Владелец выйдет на всех устройствах и при входе снова придумает свой пароль."
          />
        </Form>
      </Modal>
      <CredentialsModal value={creds} onClose={() => setCreds(null)} />
    </>
  )
}
