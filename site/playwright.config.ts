import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.SITE_E2E_PORT ?? 4391);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid SITE_E2E_PORT');
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: 2,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL,
    reducedMotion: 'reduce',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'], viewport: { width: 1440, height: 900 } } },
    { name: 'webkit', use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 900 } } },
    { name: 'mobile-chromium', use: { ...devices['Pixel 7'], viewport: { width: 390, height: 844 } } },
    { name: 'mobile-webkit', testIgnore: '**/scroll.spec.ts', use: { ...devices['iPhone 13'], viewport: { width: 390, height: 844 } } },
    // 모바일 WebKit은 자동화 휠 API 미지원. 같은 폭의 데스크톱 모드로 휠 경계 검증.
    { name: 'narrow-webkit-wheel', testMatch: '**/scroll.spec.ts', use: { ...devices['Desktop Safari'], viewport: { width: 390, height: 844 } } },
  ],
  webServer: {
    command: `node tests/e2e/server.mjs ${port}`,
    url: baseURL,
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
