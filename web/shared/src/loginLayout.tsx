import type { ReactNode } from 'react'
import { Brand } from './shell'

/** Общий каркас экранов входа: карточка слева, картинка справа. */
export function LoginLayout({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="sm-login">
      <div className="sm-login-left">
        <div className="sm-login-top">
          <Brand title="Super Market" subtitle={title} />
        </div>
        <div className="sm-login-body">
          <div className="sm-login-card">{children}</div>
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
