import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { Alert, Button, Form, Input, Typography } from 'antd'
import { LoginLayout } from './loginLayout'
import { PasswordLoginPage } from './passwordLogin'
import { api, ApiError, getTokens, onLogout, setTokens, type AppName, type Tokens } from './api'
import { formatPhone, PhoneInput, phoneRule } from './phone'
import { tr } from './i18n'

interface AuthState {
  loggedIn: boolean
  login: (t: Tokens) => void
  logout: () => Promise<void>
}

const Ctx = createContext<AuthState>({ loggedIn: false, login: () => {}, logout: async () => {} })

export function useAuth() {
  return useContext(Ctx)
}

export function AuthProvider({ app, children }: { app: AppName; children: ReactNode }) {
  const [loggedIn, setLoggedIn] = useState(() => getTokens() !== null)
  useEffect(() => onLogout(() => setLoggedIn(false)), [])
  const state: AuthState = {
    loggedIn,
    login: (t) => {
      setTokens(t)
      setLoggedIn(true)
    },
    logout: async () => {
      try {
        await api.post(`/auth/${app}/logout`)
      } catch {
        // токен мог уже истечь — всё равно выходим
      }
      setTokens(null)
      setLoggedIn(false)
    },
  }
  return <Ctx.Provider value={state}>{children}</Ctx.Provider>
}

/** Экран входа: панель магазина — по логину и паролю, супер-админ — по коду из Telegram. */
export function LoginPage({ app, title }: { app: AppName; title: string }) {
  return app === 'store' ? <PasswordLoginPage title={title} /> : <OtpLoginPage app={app} title={title} />
}

/** Вход по номеру телефона и коду из Telegram-бота (панель супер-админа). */
function OtpLoginPage({ app, title }: { app: AppName; title: string }) {
  const { login } = useAuth()
  const [phone, setPhone] = useState('')
  const [step, setStep] = useState<'phone' | 'code'>('phone')
  const [error, setError] = useState<ReactNode>(null)
  const [busy, setBusy] = useState(false)

  const requestCode = async (values: { phone: string }) => {
    setBusy(true)
    setError(null)
    try {
      await api.post('/auth/otp/request', { phone: values.phone, app: 'admin' })
      setPhone(values.phone)
      setStep('code')
    } catch (e) {
      if (e instanceof ApiError && e.code === 'telegram_not_linked') {
        const url = e.details.bot_url as string | undefined
        setError(
          <>
            {e.message}.{' '}
            {url && (
              <a href={url} target="_blank" rel="noreferrer">
                {tr('Открыть бота', 'Botni ochish')}
              </a>
            )}
          </>,
        )
      } else if (e instanceof ApiError && e.code === 'too_many_requests') {
        setError(
          tr(
            `Код уже отправлен. Повторить можно через ${e.details.retry_after ?? 60} с.`,
            `Kod allaqachon yuborilgan. ${e.details.retry_after ?? 60} soniyadan keyin qayta urinib koʻring.`,
          ),
        )
        setPhone(values.phone)
        setStep('code')
      } else {
        setError(e instanceof Error ? e.message : String(e))
      }
    } finally {
      setBusy(false)
    }
  }

  const verify = async (values: { code: string }) => {
    setBusy(true)
    setError(null)
    try {
      login(await api.post<Tokens>('/auth/otp/verify', { phone, code: values.code.trim(), app }))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <LoginLayout title={title}>
      <h1>{tr('Вход', 'Kirish')}</h1>
      {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
      {step === 'phone' ? (
        <Form layout="vertical" onFinish={requestCode} initialValues={{ phone }} requiredMark={false}>
          <Form.Item name="phone" label={tr('Номер телефона', 'Telefon raqami')} rules={[phoneRule(true)]}>
            <PhoneInput autoFocus />
          </Form.Item>
          <Button type="primary" htmlType="submit" block loading={busy} style={{ marginTop: 8 }}>
            {tr('Получить код в Telegram', 'Telegram orqali kod olish')}
          </Button>
        </Form>
      ) : (
        <Form layout="vertical" onFinish={verify} requiredMark={false}>
          <Typography.Paragraph type="secondary">
            {tr(
              `Код отправлен в Telegram-бот на номер ${formatPhone(phone)}.`,
              `Kod ${formatPhone(phone)} raqami uchun Telegram-botga yuborildi.`,
            )}
          </Typography.Paragraph>
          <Form.Item name="code" label={tr('Код из Telegram', 'Telegramdagi kod')} rules={[{ required: true, message: tr('Введите код', 'Kodni kiriting') }]}>
            <Input autoFocus inputMode="numeric" maxLength={6} />
          </Form.Item>
          <Button type="primary" htmlType="submit" block loading={busy} style={{ marginTop: 8 }}>
            {tr('Войти', 'Kirish')}
          </Button>
          <Button type="link" block onClick={() => setStep('phone')} style={{ marginTop: 8 }}>
            {tr('Другой номер', 'Boshqa raqam')}
          </Button>
        </Form>
      )}
    </LoginLayout>
  )
}
