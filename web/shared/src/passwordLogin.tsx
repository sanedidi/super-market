// Вход в панель магазина по логину и паролю и смена временного пароля
// (Figma «Вход по логину и паролю» → ЛП1, ЛП2, ЛП3).
import { useState, type ReactNode } from 'react'
import { Alert, Button, Form, Input, Spin } from 'antd'
import { CheckCircleFilled, LockOutlined, QuestionCircleFilled, UserOutlined } from '@ant-design/icons'
import { useQueryClient } from '@tanstack/react-query'
import { api, ApiError, type Tokens } from './api'
import { useAuth } from './auth'
import { useItem } from './hooks'
import { LoginLayout } from './loginLayout'

/** Контакты поддержки Super Market — для «Забыли пароль?». */
export const SUPPORT_TELEGRAM = '@super_market_support'
export const SUPPORT_PHONE = '+998 50 576 47 23'

/** Пароль из 3 групп: «kx7-Lam4-pz9» — легко продиктовать. */
export function generatePassword() {
  const abc = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  const rnd = new Uint32Array(10)
  crypto.getRandomValues(rnd)
  const ch = (i: number) => abc[rnd[i] % abc.length]
  const p = `${ch(0)}${ch(1)}${ch(2)}-${ch(3)}${ch(4)}${ch(5)}${ch(6)}-${ch(7)}${ch(8)}${ch(9)}`
  // Хотя бы одна цифра — такой пароль годится и как постоянный.
  return /\d/.test(p) ? p : p.slice(0, -1) + String(2 + (rnd[9] % 8))
}

/** Логин из имени: «Азиз Каримов» → «aziz.karimov». */
export function suggestLogin(name: string) {
  const map: Record<string, string> = {
    а: 'a',
    б: 'b',
    в: 'v',
    г: 'g',
    д: 'd',
    е: 'e',
    ё: 'yo',
    ж: 'j',
    з: 'z',
    и: 'i',
    й: 'y',
    к: 'k',
    л: 'l',
    м: 'm',
    н: 'n',
    о: 'o',
    п: 'p',
    р: 'r',
    с: 's',
    т: 't',
    у: 'u',
    ф: 'f',
    х: 'x',
    ц: 'ts',
    ч: 'ch',
    ш: 'sh',
    щ: 'sh',
    ъ: '',
    ы: 'i',
    ь: '',
    э: 'e',
    ю: 'yu',
    я: 'ya',
    ў: 'o',
    қ: 'q',
    ғ: 'g',
    ҳ: 'h',
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

/** Логин: латиница, цифры, точка, дефис, подчёркивание — 3–32 символа. */
export const LOGIN_RE = /^[a-z0-9][a-z0-9._-]{2,31}$/

function SupportNote() {
  return (
    <div className="sm-login-help">
      <QuestionCircleFilled />
      <span>
        Забыли пароль? Напишите в поддержку Super Market — сбросим и пришлём новый.
        <br />
        Telegram {SUPPORT_TELEGRAM} · {SUPPORT_PHONE}
      </span>
    </div>
  )
}

/** ЛП1/ЛП2 — вход в панель магазина по логину и паролю. */
export function PasswordLoginPage({ title }: { title: string }) {
  const { login } = useAuth()
  const [error, setError] = useState<ReactNode>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (v: { login: string; password: string }) => {
    setBusy(true)
    setError(null)
    try {
      login(await api.post<Tokens>('/auth/store/login', { login: v.login.trim().toLowerCase(), password: v.password }))
    } catch (e) {
      if (e instanceof ApiError && e.code === 'invalid_credentials' && typeof e.details.attempts_left === 'number') {
        setError(
          <>
            Неверный логин или пароль. Осталось попыток: {e.details.attempts_left}.
            <br />
            После 5 неверных паролей вход закроется на 15 минут.
          </>,
        )
      } else {
        setError(e instanceof Error ? e.message : String(e))
      }
    } finally {
      setBusy(false)
    }
  }

  return (
    <LoginLayout title={title}>
      <h1 style={{ marginBottom: 8 }}>Вход</h1>
      <p className="sm-login-sub">Логин и пароль выдаёт Super Market при подключении магазина</p>
      {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
      <Form layout="vertical" onFinish={submit} requiredMark={false}>
        <Form.Item name="login" label="Логин" rules={[{ required: true, whitespace: true, message: 'Введите логин' }]}>
          <Input prefix={<UserOutlined />} autoFocus autoComplete="username" autoCapitalize="none" spellCheck={false} maxLength={32} />
        </Form.Item>
        <Form.Item name="password" label="Пароль" rules={[{ required: true, message: 'Введите пароль' }]}>
          <Input.Password prefix={<LockOutlined />} autoComplete="current-password" maxLength={72} />
        </Form.Item>
        <Button type="primary" htmlType="submit" block loading={busy} style={{ marginTop: 8 }}>
          Войти
        </Button>
      </Form>
      <SupportNote />
    </LoginLayout>
  )
}

/** Правила нового пароля — те же, что на сервере. */
export function passwordChecks(pw: string, repeat: string) {
  return [
    { ok: pw.length >= 8 && pw.length <= 72, text: 'Не меньше 8 символов' },
    { ok: /\p{L}/u.test(pw) && /\d/.test(pw), text: 'Есть буквы и цифры' },
    { ok: pw.length > 0 && pw === repeat, text: 'Пароли совпадают' },
  ]
}

/** ЛП3 — первый вход по временному паролю: придумать свой. */
export function ChangePasswordPage({ title }: { title: string }) {
  const { logout } = useAuth()
  const qc = useQueryClient()
  const [pw, setPw] = useState('')
  const [repeat, setRepeat] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const checks = passwordChecks(pw, repeat)
  const ready = checks.every((c) => c.ok)

  const submit = async () => {
    if (!ready) return
    setBusy(true)
    setError(null)
    try {
      await api.post('/auth/store/password', { new_password: pw })
      // Пароль уже сменён — даже если перезагрузка профиля не удастся, второй раз этот экран не нужен.
      qc.setQueryData<{ must_change_password?: boolean }>(['/store/me', undefined], (me) =>
        me ? { ...me, must_change_password: false } : me,
      )
      await qc.invalidateQueries()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setBusy(false)
    }
  }

  return (
    <LoginLayout title={title}>
      <div className="sm-login-icon">
        <LockOutlined />
      </div>
      <h1 style={{ marginBottom: 8 }}>Придумайте свой пароль</h1>
      <p className="sm-login-sub">Вы вошли по временному паролю от Super Market. Придумайте новый — его будете знать только вы.</p>
      {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
      <Form layout="vertical" onFinish={submit} requiredMark={false}>
        <Form.Item label="Новый пароль" htmlFor="sm-new-password">
          <Input.Password
            id="sm-new-password"
            prefix={<LockOutlined />}
            autoFocus
            autoComplete="new-password"
            maxLength={72}
            value={pw}
            onChange={(e) => setPw(e.target.value)}
          />
        </Form.Item>
        <Form.Item label="Повторите пароль" htmlFor="sm-repeat-password">
          <Input.Password
            id="sm-repeat-password"
            prefix={<LockOutlined />}
            autoComplete="new-password"
            maxLength={72}
            value={repeat}
            onChange={(e) => setRepeat(e.target.value)}
          />
        </Form.Item>
        <ul className="sm-login-checks">
          {checks.map((c) => (
            <li key={c.text} className={c.ok ? 'ok' : undefined}>
              <CheckCircleFilled /> {c.text}
            </li>
          ))}
        </ul>
        <Button type="primary" htmlType="submit" block loading={busy} disabled={!ready} style={{ marginTop: 8 }}>
          Сохранить и войти
        </Button>
        <Button type="link" block onClick={() => void logout()} style={{ marginTop: 8 }}>
          Выйти
        </Button>
      </Form>
    </LoginLayout>
  )
}

/**
 * Пока пароль временный, панель магазина показывает только экран смены
 * пароля: сервер на остальные запросы отвечает password_change_required.
 */
export function StorePasswordGate({ title, children }: { title: string; children: ReactNode }) {
  const me = useItem<{ must_change_password?: boolean }>('/store/me')
  if (me.isLoading) {
    return (
      <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center' }}>
        <Spin />
      </div>
    )
  }
  if (me.data?.must_change_password) return <ChangePasswordPage title={title} />
  return <>{children}</>
}
