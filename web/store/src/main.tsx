import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { AppRoot } from '@sm/shared'
import { StoreProvider } from './ctx'
import { StoreRoutes } from './routes'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AppRoot app="store" basename="/" title="Панель магазина">
      <StoreProvider>
        <StoreRoutes />
      </StoreProvider>
    </AppRoot>
  </StrictMode>,
)
