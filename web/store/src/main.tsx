import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { AppRoot, getLang, tr } from '@sm/shared'
import { StoreProvider } from './ctx'
import { StoreRoutes } from './routes'

document.title = tr('Панель магазина', 'Doʻkon paneli')
document.documentElement.lang = getLang()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AppRoot app="store" basename="/" title={tr('Панель магазина', 'Doʻkon paneli')}>
      <StoreProvider>
        <StoreRoutes />
      </StoreProvider>
    </AppRoot>
  </StrictMode>,
)
