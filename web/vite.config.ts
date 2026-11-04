import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// No proxy or API credentials: this first slice is a strictly local fixture lab.
export default defineConfig({
  plugins: [react()],
  base: './',
  server: { host: '127.0.0.1', port: 5179, strictPort: true },
  preview: { host: '127.0.0.1', port: 5180, strictPort: true },
  build: { target: 'safari16' },
});
