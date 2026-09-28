import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { AppRoot } from '@sm/shared'
import { AdminRoutes } from './routes'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AppRoot app="admin" basename="/admin" title="Супер-админ">
      <AdminRoutes />
    </AppRoot>
  </StrictMode>,
)
