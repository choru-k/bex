import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.BEX_WEB_PORT ?? 5179);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid BEX_WEB_PORT');
const origin = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: './tests', testMatch: '**/*.spec.ts', fullyParallel: true,
  forbidOnly: !!process.env.CI, retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: { baseURL: origin, trace: 'retain-on-failure' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: {
    command: `npm exec -- vite --host 127.0.0.1 --port ${port} --strictPort`, url: origin,
    reuseExistingServer: false, timeout: 30_000,
  },
});
