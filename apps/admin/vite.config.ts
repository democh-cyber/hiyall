import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// The console is served by the admin binary under a strict CSP (script-src 'self', style-src 'self'),
// so the build must emit external files only: no inline assets, no inline module-preload polyfill.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    assetsInlineLimit: 0,
    cssCodeSplit: false,
    sourcemap: false,
    modulePreload: { polyfill: false },
  },
  server: {
    // `npm run dev` talks to a locally running `admin` binary.
    proxy: { '/admin/v1': 'http://127.0.0.1:8081' },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    css: false,
  },
})
