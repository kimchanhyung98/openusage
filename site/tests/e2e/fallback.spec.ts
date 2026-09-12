import { test, expect } from './fixtures';

test.use({ javaScriptEnabled: false });

test('the page remains readable and downloadable with JavaScript disabled', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'AI 사용량을 한눈에 확인하세요.' })).toBeVisible();
  await expect(page.locator('.tour-fallback')).toBeVisible();
  await expect(page.locator('[data-tour-description="menu-bar"]')).toBeVisible();
  await expect(page.locator('[data-mock]').getByRole('button', { name: 'Options', exact: true })).toBeHidden();
  await expect(page.locator('[data-mock] .am-section[data-provider]:visible')).toHaveCount(3);
  const downloads = page.locator('[data-download]');
  expect(await downloads.count()).toBeGreaterThan(0);
  for (const link of await downloads.all()) {
    await expect(link).toHaveAttribute('href', 'https://github.com/kimchanhyung98/openusage/releases/latest');
  }
});
