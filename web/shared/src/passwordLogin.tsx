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
import { tr } from './i18n'

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
        {tr(
          'Забыли пароль? Напишите в поддержку Super Market — сбросим и пришлём новый.',
          'Parolni unutdingizmi? Super Market qoʻllab-quvvatlash xizmatiga yozing — parolni tiklab, yangisini yuboramiz.',
        )}
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
            {tr(
              `Неверный логин или пароль. Осталось попыток: ${e.details.attempts_left}.`,
              `Login yoki parol notoʻgʻri. Qolgan urinishlar: ${e.details.attempts_left}.`,
            )}
            <br />
            {tr('После 5 неверных паролей вход закроется на 15 минут.', '5 marta notoʻgʻri parol kiritilsa, kirish 15 daqiqaga yopiladi.')}
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
      <h1 style={{ marginBottom: 8 }}>{tr('Вход', 'Kirish')}</h1>
      <p className="sm-login-sub">
        {tr('Логин и пароль выдаёт Super Market при подключении магазина', 'Login va parolni doʻkon ulanganda Super Market beradi')}
      </p>
      {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
      <Form layout="vertical" onFinish={submit} requiredMark={false}>
        <Form.Item name="login" label={tr('Логин', 'Login')} rules={[{ required: true, whitespace: true, message: tr('Введите логин', 'Loginni kiriting') }]}>
          <Input prefix={<UserOutlined />} autoFocus autoComplete="username" autoCapitalize="none" spellCheck={false} maxLength={32} />
        </Form.Item>
        <Form.Item name="password" label={tr('Пароль', 'Parol')} rules={[{ required: true, message: tr('Введите пароль', 'Parolni kiriting') }]}>
          <Input.Password prefix={<LockOutlined />} autoComplete="current-password" maxLength={72} />
        </Form.Item>
        <Button type="primary" htmlType="submit" block loading={busy} style={{ marginTop: 8 }}>
          {tr('Войти', 'Kirish')}
        </Button>
      </Form>
      <SupportNote />
    </LoginLayout>
  )
}

/** Правила нового пароля — те же, что на сервере. */
export function passwordChecks(pw: string, repeat: string) {
  return [
    { ok: pw.length >= 8 && pw.length <= 72, text: tr('Не меньше 8 символов', 'Kamida 8 ta belgi') },
    { ok: /\p{L}/u.test(pw) && /\d/.test(pw), text: tr('Есть буквы и цифры', 'Harf va raqamlar bor') },
    { ok: pw.length > 0 && pw === repeat, text: tr('Пароли совпадают', 'Parollar mos keladi') },
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
      <h1 style={{ marginBottom: 8 }}>{tr('Придумайте свой пароль', 'Oʻz parolingizni oʻylab toping')}</h1>
      <p className="sm-login-sub">
        {tr(
          'Вы вошли по временному паролю от Super Market. Придумайте новый — его будете знать только вы.',
          'Siz Super Market bergan vaqtinchalik parol bilan kirdingiz. Yangisini oʻylab toping — uni faqat siz bilasiz.',
        )}
      </p>
      {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
      <Form layout="vertical" onFinish={submit} requiredMark={false}>
        <Form.Item label={tr('Новый пароль', 'Yangi parol')} htmlFor="sm-new-password">
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
        <Form.Item label={tr('Повторите пароль', 'Parolni takrorlang')} htmlFor="sm-repeat-password">
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
          {tr('Сохранить и войти', 'Saqlash va kirish')}
        </Button>
        <Button type="link" block onClick={() => void logout()} style={{ marginTop: 8 }}>
          {tr('Выйти', 'Chiqish')}
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
