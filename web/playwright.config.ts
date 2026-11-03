import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests', testMatch: '**/*.spec.ts', fullyParallel: true,
  forbidOnly: !!process.env.CI, retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: { baseURL: 'http://127.0.0.1:5179', trace: 'retain-on-failure' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: {
    command: 'npm run dev', url: 'http://127.0.0.1:5179',
    reuseExistingServer: false, timeout: 30_000,
  },
});
