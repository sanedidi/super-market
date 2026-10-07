import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// API в разработке — локальный backend (make run-api).
export default defineConfig({
  base: '/',
  plugins: [react()],
  // Языки uz/ru в панели магазина (shared/src/i18n.tsx). В панели супер-админа их нет.
  define: { __SM_I18N__: 'true' },
  server: {
    port: 5173,
    proxy: { '/api': 'http://localhost:8080' },
  },
})
