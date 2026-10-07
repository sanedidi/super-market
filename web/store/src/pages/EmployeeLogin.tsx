// Логин и временный пароль сотрудника для панели и «SM Магазин».
// Логин владельца выдаёт и сбрасывает только Super Market.
import { useEffect, useState } from 'react'
import { Alert, App, Button, Card, Input, Modal, Popconfirm, Space, Typography } from 'antd'
import { CopyOutlined, LockOutlined, ReloadOutlined, StopOutlined } from '@ant-design/icons'
import { LOGIN_RE, api, errorText, formatPhone, generatePassword, suggestLogin, tr, useAction } from '@sm/shared'
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
    success: tr('Вход отключён', 'Kirish oʻchirildi'),
    invalidate: [['/store/employees'], ['/store/couriers']],
  })
  const copy = (text: string) => navigator.clipboard?.writeText(text).then(() => message.success(tr('Скопировано', 'Nusxa olindi')))
  const onSave = () => {
    setError('')
    const v = { login: login.trim().toLowerCase(), password }
    if (!LOGIN_RE.test(v.login)) {
      setError(tr('Логин: латиница, цифры, точка, дефис или _ — 3–32 символа', 'Login: lotin harflari, raqamlar, nuqta, chiziqcha yoki _ — 3–32 ta belgi'))
      return
    }
    if ((!has || password) && password.length < 8) {
      setError(tr('Пароль — не меньше 8 символов', 'Parol — kamida 8 ta belgi'))
      return
    }
    save.mutateAsync(v).then(
      () => setSaved(v),
      (e) => setError(errorText(e)),
    )
  }
  const text = saved
    ? tr(
        `Super Market — вход для сотрудника\nПанель: https://store.super-market.uz\nПриложение: SM Магазин\nЛогин: ${saved.login}${saved.password ? `\nПароль: ${saved.password}\nПри первом входе придумайте свой пароль.` : ''}`,
        `Super Market — xodim uchun kirish\nPanel: https://store.super-market.uz\nIlova: SM Магазин\nLogin: ${saved.login}${saved.password ? `\nParol: ${saved.password}\nBirinchi kirishda oʻz parolingizni oʻylab toping.` : ''}`,
      )
    : ''
  return (
    <Modal
      open={!!employee}
      onCancel={onClose}
      width={520}
      title={
        <Space>
          <LockOutlined style={{ color: '#155eef' }} />
          {tr('Вход в панель и «SM Магазин»', 'Panelga va «SM Магазин»ga kirish')}
        </Space>
      }
      footer={
        saved
          ? [
              <Button key="copy" icon={<CopyOutlined />} onClick={() => copy(text)}>
                {tr('Скопировать всё', 'Hammasidan nusxa olish')}
              </Button>,
              <Button key="ok" type="primary" onClick={onClose}>
                {tr('Готово', 'Tayyor')}
              </Button>,
            ]
          : [
              has ? (
                <Popconfirm
                  key="off"
                  title={tr('Отключить вход? Сотрудник выйдет на всех устройствах.', 'Kirish oʻchirilsinmi? Xodim barcha qurilmalardan chiqariladi.')}
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
                ? tr(
                    'Сохранено. Передайте данные сотруднику лично — пароль больше не покажем. При первом входе он придумает свой.',
                    'Saqlandi. Maʼlumotlarni xodimga shaxsan bering — parol boshqa koʻrsatilmaydi. Birinchi kirishda u oʻz parolini oʻylab topadi.',
                  )
                : tr('Логин изменён. Пароль прежний.', 'Login oʻzgartirildi. Parol avvalgidek.')
            }
          />
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
                    {tr('Временный пароль:', 'Vaqtinchalik parol:')} <b>{saved.password}</b>
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
              {tr('Логин', 'Login')}
            </Typography.Text>
            <Input value={login} onChange={(e) => setLogin(e.target.value)} placeholder="aziz.karimov" maxLength={32} autoComplete="off" />
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('Латиница, цифры, точка, дефис — 3–32 символа. Должен быть уникальным.', 'Lotin harflari, raqamlar, nuqta, chiziqcha — 3–32 ta belgi. Takrorlanmas boʻlishi kerak.')}
            </Typography.Text>
          </div>
          <div>
            <Typography.Text strong style={{ fontSize: 12 }}>
              {has ? tr('Новый временный пароль', 'Yangi vaqtinchalik parol') : tr('Временный пароль', 'Vaqtinchalik parol')}
            </Typography.Text>
            <Space.Compact style={{ width: '100%' }}>
              <Input
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={has ? tr('Оставьте пустым, чтобы не менять', 'Oʻzgartirmaslik uchun boʻsh qoldiring') : tr('Не меньше 8 символов', 'Kamida 8 ta belgi')}
                maxLength={72}
                autoComplete="off"
              />
              <Button icon={<ReloadOutlined />} onClick={() => setPassword(generatePassword())}>
                {tr('Сгенерировать', 'Yaratish')}
              </Button>
            </Space.Compact>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {tr('При первом входе сотрудник придумает свой пароль. После сброса он выйдет на всех устройствах.', 'Birinchi kirishda xodim oʻz parolini oʻylab topadi. Parol tiklangandan soʻng u barcha qurilmalardan chiqariladi.')}
            </Typography.Text>
          </div>
          {error && <Alert type="error" showIcon message={error} />}
          <Alert
            type="warning"
            showIcon
            message={tr('Передайте логин и пароль сотруднику лично. Пароль больше нигде не показывается — только сбросить.', 'Login va parolni xodimga shaxsan bering. Parol boshqa hech qayerda koʻrsatilmaydi — faqat tiklash mumkin.')}
          />
        </Space>
      )}
    </Modal>
  )
}
