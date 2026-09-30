import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { Alert, Button, Form, Input, Typography } from 'antd'
import { Brand } from './shell'
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
    <div className="sm-login">
      <div className="sm-login-left">
        <div className="sm-login-top">
          <Brand title="Super Market" subtitle={title} />
        </div>
        <div className="sm-login-body">
          <div className="sm-login-card">
            <h1>Вход</h1>
            {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
            {step === 'phone' ? (
              <Form layout="vertical" onFinish={requestCode} initialValues={{ phone }} requiredMark={false}>
                <Form.Item name="phone" label="Номер телефона" rules={[{ required: true, message: 'Введите номер' }]}>
                  <Input placeholder="+998 90 123 45 67" autoFocus inputMode="tel" />
                </Form.Item>
                <Button type="primary" htmlType="submit" block loading={busy} style={{ marginTop: 8 }}>
                  Получить код в Telegram
                </Button>
              </Form>
            ) : (
              <Form layout="vertical" onFinish={verify} requiredMark={false}>
                <Typography.Paragraph type="secondary">Код отправлен в Telegram-бот на номер {phone}.</Typography.Paragraph>
                <Form.Item name="code" label="Код из Telegram" rules={[{ required: true, message: 'Введите код' }]}>
                  <Input autoFocus inputMode="numeric" maxLength={6} />
                </Form.Item>
                <Button type="primary" htmlType="submit" block loading={busy} style={{ marginTop: 8 }}>
                  Войти
                </Button>
                <Button type="link" block onClick={() => setStep('phone')} style={{ marginTop: 8 }}>
                  Другой номер
                </Button>
              </Form>
            )}
          </div>
        </div>
        <div className="sm-login-foot">SUPER MARKET © {new Date().getFullYear()}</div>
      </div>
      <div className="sm-login-art">
        <h2>
          Магазины, заказы
          <br />и деньги — в одном месте
        </h2>
        <p>Онлайн-заказы из приложения, касса, склад, курьеры и выплаты. Всё видно сразу — без таблиц и звонков.</p>
        <div className="sm-login-mock">
          <div className="sm-login-mock-grid">
            <div className="sm-login-mock-card">
              <span>Продажи сегодня</span>
              <b>12 540 000</b>
              <i>+12,5%</i>
            </div>
            <div className="sm-login-mock-card">
              <span>Онлайн-заказы</span>
              <b>148</b>
              <i>+8,3%</i>
            </div>
            <div className="sm-login-mock-card">
              <span>Курьеры на смене</span>
              <b>24</b>
              <i>в пути: 9</i>
            </div>
          </div>
          <div className="sm-login-mock-bars">
            {[40, 62, 48, 75, 58, 86, 70, 94].map((h, i) => (
              <div key={i} style={{ height: `${h}%` }} />
            ))}
          </div>
        </div>
        <div className="sm-login-points">
          <span>Склад</span>
          <span>Касса</span>
          <span>Доставка</span>
          <span>Финансы</span>
        </div>
      </div>
    </div>
  )
}
