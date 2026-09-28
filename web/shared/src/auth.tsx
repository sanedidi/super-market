import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { Alert, Button, Card, Form, Input, Typography } from 'antd'
import { api, ApiError, getTokens, onLogout, setTokens, type AppName, type Tokens } from './api'

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

/** Вход по номеру телефона и коду из Telegram-бота. */
export function LoginPage({ app, title }: { app: AppName; title: string }) {
  const { login } = useAuth()
  const [phone, setPhone] = useState('')
  const [step, setStep] = useState<'phone' | 'code'>('phone')
  const [error, setError] = useState<ReactNode>(null)
  const [busy, setBusy] = useState(false)

  const requestCode = async (values: { phone: string }) => {
    setBusy(true)
    setError(null)
    try {
      await api.post('/auth/otp/request', { phone: values.phone })
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
                Открыть бота
              </a>
            )}
          </>,
        )
      } else if (e instanceof ApiError && e.code === 'too_many_requests') {
        setError(`Код уже отправлен. Повторить можно через ${e.details.retry_after ?? 60} с.`)
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
    <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', background: '#f5f5f5', padding: 16 }}>
      <Card style={{ width: '100%', maxWidth: 380 }}>
        <Typography.Title level={3} style={{ marginTop: 0 }}>
          {title}
        </Typography.Title>
        {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
        {step === 'phone' ? (
          <Form layout="vertical" onFinish={requestCode} initialValues={{ phone }}>
            <Form.Item name="phone" label="Номер телефона" rules={[{ required: true, message: 'Введите номер' }]}>
              <Input size="large" placeholder="+998 90 123 45 67" autoFocus inputMode="tel" />
            </Form.Item>
            <Button type="primary" htmlType="submit" size="large" block loading={busy}>
              Получить код в Telegram
            </Button>
          </Form>
        ) : (
          <Form layout="vertical" onFinish={verify}>
            <Typography.Paragraph type="secondary">Код отправлен в Telegram-бот на номер {phone}.</Typography.Paragraph>
            <Form.Item name="code" label="Код" rules={[{ required: true, message: 'Введите код' }]}>
              <Input size="large" autoFocus inputMode="numeric" maxLength={6} />
            </Form.Item>
            <Button type="primary" htmlType="submit" size="large" block loading={busy}>
              Войти
            </Button>
            <Button type="link" block onClick={() => setStep('phone')}>
              Другой номер
            </Button>
          </Form>
        )}
      </Card>
    </div>
  )
}
