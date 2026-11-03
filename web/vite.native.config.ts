import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

// Explicit alternate build only. No app packaging or runtime activation.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    target: 'safari16',
    outDir: 'dist-native',
    rolldownOptions: { input: fileURLToPath(new URL('./native.html', import.meta.url)) },
  },
});
