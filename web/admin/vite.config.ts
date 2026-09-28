import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// API в разработке — локальный backend (make run-api).
export default defineConfig({
  base: '/admin/',
  plugins: [react()],
  server: {
    port: 5174,
    proxy: { '/api': 'http://localhost:8080' },
  },
})
