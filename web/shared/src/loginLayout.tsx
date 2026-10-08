import type { ReactNode } from 'react'
import { Brand } from './shell'
import { LangSwitch, tr } from './i18n'

/** Общий каркас экранов входа: карточка слева, картинка справа. */
export function LoginLayout({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="sm-login">
      <div className="sm-login-left">
        <div className="sm-login-top">
          <Brand title="Super Market" subtitle={title} />
          <div style={{ marginLeft: 'auto' }}>
            <LangSwitch size="middle" />
          </div>
        </div>
        <div className="sm-login-body">
          <div className="sm-login-card">{children}</div>
        </div>
        <div className="sm-login-foot">SUPER MARKET © {new Date().getFullYear()}</div>
      </div>
      <div className="sm-login-art">
        <h2>
          {tr('Магазины, заказы', 'Doʻkonlar, buyurtmalar')}
          <br />
          {tr('и деньги — в одном месте', 'va pullar — bir joyda')}
        </h2>
        <p>
          {tr(
            'Онлайн-заказы из приложения, касса, склад, курьеры и выплаты. Всё видно сразу — без таблиц и звонков.',
            'Ilovadan onlayn buyurtmalar, kassa, ombor, kuryerlar va toʻlovlar. Hammasi birdaniga koʻrinadi — jadval va qoʻngʻiroqlarsiz.',
          )}
        </p>
        <div className="sm-login-mock">
          <div className="sm-login-mock-grid">
            <div className="sm-login-mock-card">
              <span>{tr('Продажи сегодня', 'Bugungi sotuvlar')}</span>
              <b>12 540 000</b>
              <i>+12,5%</i>
            </div>
            <div className="sm-login-mock-card">
              <span>{tr('Онлайн-заказы', 'Onlayn buyurtmalar')}</span>
              <b>148</b>
              <i>+8,3%</i>
            </div>
            <div className="sm-login-mock-card">
              <span>{tr('Курьеры на смене', 'Smenadagi kuryerlar')}</span>
              <b>24</b>
              <i>{tr('в пути: 9', 'yoʻlda: 9')}</i>
            </div>
          </div>
          <div className="sm-login-mock-bars">
            {[40, 62, 48, 75, 58, 86, 70, 94].map((h, i) => (
              <div key={i} style={{ height: `${h}%` }} />
            ))}
          </div>
        </div>
        <div className="sm-login-points">
          <span>{tr('Склад', 'Ombor')}</span>
          <span>{tr('Касса', 'Kassa')}</span>
          <span>{tr('Доставка', 'Yetkazib berish')}</span>
          <span>{tr('Финансы', 'Moliya')}</span>
        </div>
      </div>
    </div>
  )
}
