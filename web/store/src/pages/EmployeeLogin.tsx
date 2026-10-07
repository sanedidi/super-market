// Логин и временный пароль сотрудника для панели и «SM Магазин».
// Логин владельца выдаёт и сбрасывает только Super Market.
import { useEffect, useState } from 'react'
import { Alert, App, Button, Card, Input, Modal, Popconfirm, Space, Typography } from 'antd'
import { CopyOutlined, LockOutlined, ReloadOutlined, StopOutlined } from '@ant-design/icons'
import { LOGIN_RE, api, errorText, formatPhone, generatePassword, suggestLogin, useAction } from '@sm/shared'
import type { Employee } from '../types'

export function EmployeeLoginModal({ employee, onClose }: { employee: Employee | null; onClose: () => void }) {
  const { message } = App.useApp()
  const [login, setLogin] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [saved, setSaved] = useState<{ login: string; password: string } | null>(null)
  const has = !!employee?.login
  useEffect(() => {
    if (!employee) return
    setLogin(employee.login || suggestLogin(employee.full_name))
    setPassword(employee.login ? '' : generatePassword())
    setError('')
    setSaved(null)
  }, [employee])
  const save = useAction((v: { login: string; password: string }) => api.put(`/store/employees/${employee!.id}/login`, v), {
    invalidate: [['/store/employees'], ['/store/couriers']],
  })
  const disable = useAction(() => api.del(`/store/employees/${employee!.id}/login`), {
    success: 'Вход отключён',
    invalidate: [['/store/employees'], ['/store/couriers']],
  })
  const copy = (text: string) => navigator.clipboard?.writeText(text).then(() => message.success('Скопировано'))
  const onSave = () => {
    setError('')
    const v = { login: login.trim().toLowerCase(), password }
    if (!LOGIN_RE.test(v.login)) {
      setError('Логин: латиница, цифры, точка, дефис или _ — 3–32 символа')
      return
    }
    if ((!has || password) && password.length < 8) {
      setError('Пароль — не меньше 8 символов')
      return
    }
    save.mutateAsync(v).then(
      () => setSaved(v),
      (e) => setError(errorText(e)),
    )
  }
  const text = saved
    ? `Super Market — вход для сотрудника\nПанель: https://store.super-market.uz\nПриложение: SM Магазин\nЛогин: ${saved.login}${saved.password ? `\nПароль: ${saved.password}\nПри первом входе придумайте свой пароль.` : ''}`
    : ''
  return (
    <Modal
      open={!!employee}
      onCancel={onClose}
      width={520}
      title={
        <Space>
          <LockOutlined style={{ color: '#155eef' }} />
          Вход в панель и «SM Магазин»
        </Space>
      }
      footer={
        saved
          ? [
              <Button key="copy" icon={<CopyOutlined />} onClick={() => copy(text)}>
                Скопировать всё
              </Button>,
              <Button key="ok" type="primary" onClick={onClose}>
                Готово
              </Button>,
            ]
          : [
              has ? (
                <Popconfirm
                  key="off"
                  title="Отключить вход? Сотрудник выйдет на всех устройствах."
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
      {employee && (
        <Typography.Paragraph type="secondary">
          {employee.full_name} · {formatPhone(employee.phone)} · {employee.role_name}
        </Typography.Paragraph>
      )}
      {saved ? (
        <Space direction="vertical" style={{ width: '100%' }}>
          <Alert
            type="success"
            showIcon
            message={
              saved.password
                ? 'Сохранено. Передайте данные сотруднику лично — пароль больше не покажем. При первом входе он придумает свой.'
                : 'Логин изменён. Пароль прежний.'
            }
          />
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
                    Временный пароль: <b>{saved.password}</b>
                  </span>
                  <Button size="small" icon={<CopyOutlined />} onClick={() => copy(saved.password)} />
                </Space>
              )}
            </Space>
          </Card>
        </Space>
      ) : (
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              Логин
            </Typography.Text>
            <Input value={login} onChange={(e) => setLogin(e.target.value)} placeholder="aziz.karimov" maxLength={32} autoComplete="off" />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              Латиница, цифры, точка, дефис — 3–32 символа. Должен быть уникальным.
            </Typography.Text>
          </div>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              {has ? 'Новый временный пароль' : 'Временный пароль'}
            </Typography.Text>
            <Space.Compact style={{ width: '100%' }}>
              <Input
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={has ? 'Оставьте пустым, чтобы не менять' : 'Не меньше 8 символов'}
                maxLength={72}
                autoComplete="off"
              />
              <Button icon={<ReloadOutlined />} onClick={() => setPassword(generatePassword())}>
                Сгенерировать
              </Button>
            </Space.Compact>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              При первом входе сотрудник придумает свой пароль. После сброса он выйдет на всех устройствах.
            </Typography.Text>
          </div>
          {error && <Alert type="error" showIcon message={error} />}
          <Alert
            type="warning"
            showIcon
            message="Передайте логин и пароль сотруднику лично. Пароль больше нигде не показывается — только сбросить."
          />
        </Space>
      )}
    </Modal>
  )
}
