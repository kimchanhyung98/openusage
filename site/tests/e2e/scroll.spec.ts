import { type Page } from '@playwright/test';
import { test, expect, openHome, openSettings } from './fixtures';

async function wheel(page: Page, delta: number): Promise<void> {
  await page.evaluate(() => {
    document.documentElement.dataset.wheelSeen = 'false';
    window.addEventListener('wheel', () => { document.documentElement.dataset.wheelSeen = 'true'; }, { once: true, passive: true });
  });
  await page.mouse.wheel(0, delta);
  await expect(page.locator('html')).toHaveAttribute('data-wheel-seen', 'true');
  await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
}

test('app content scrolls internally and keeps top, bottom, and footer wheel input inside the app', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  const body = app.locator('[data-scr="settings"] .am-body');
  await body.hover();
  await body.evaluate((element) => { element.scrollTop = 0; });
  const y = await page.evaluate(() => scrollY);
  await wheel(page, 180);
  await expect.poll(() => body.evaluate((element) => element.scrollTop)).toBeGreaterThan(0);
  expect(await page.evaluate(() => scrollY)).toBe(y);
  await body.evaluate((element) => { element.scrollTop = element.scrollHeight; });
  await wheel(page, 800);
  expect(await page.evaluate(() => scrollY)).toBe(y);
  await body.evaluate((element) => { element.scrollTop = 0; });
  await wheel(page, -800);
  expect(await page.evaluate(() => scrollY)).toBe(y);
  await app.locator('[data-scr="settings"] .am-foot').hover();
  const footerY = await page.evaluate(() => scrollY);
  await wheel(page, 800);
  expect(await page.evaluate(() => scrollY)).toBe(footerY);
});

test('outer wheel input advances through every tour stage and leaves only at the boundary', async ({ page }) => {
  await openHome(page);
  const tour = page.locator('[data-feature-tour]');
  await tour.evaluate((element) => element.scrollIntoView({ block: 'start', behavior: 'instant' }));
  await tour.locator('[data-tour-tab="menu-bar"]').click();
  await page.mouse.move(10, (page.viewportSize()?.height ?? 900) / 2);
  const y = await page.evaluate(() => scrollY);
  for (const stage of ['dashboard', 'statistics', 'accounts', 'integrations']) {
    // 독립 휠 제스처의 220ms 간격을 실제 브라우저 입력으로 검증.
    await page.waitForTimeout(240);
    await wheel(page, 200);
    await expect(tour).toHaveAttribute('data-tour-stage', stage);
    expect(await page.evaluate(() => scrollY)).toBe(y);
  }
  await page.waitForTimeout(240);
  await wheel(page, 200);
  await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(y);
  await expect(page.locator('.footer--download')).toBeInViewport({ ratio: 0.9 });
  await page.waitForTimeout(240);
  await wheel(page, -200);
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(y);
  await expect(tour).toHaveAttribute('data-tour-stage', 'integrations');
  // 브라우저 왕복 시간이 제스처 경계를 넘을 수 있어 재진입 상태와 다음 입력을 분리.
  await page.waitForTimeout(240);
  await wheel(page, -200);
  await expect(tour).toHaveAttribute('data-tour-stage', 'accounts');
});
