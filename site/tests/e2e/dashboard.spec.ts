import { test, expect, openHome, openSettings, chooseSetting } from './fixtures';

test('Customize can enable metrics without sample data in existing and dormant providers', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  for (const [provider, name, metric, card] of [
    ['claude', 'Claude', 'claude.extra', 'claude-account-1'],
    ['cursor', 'Cursor', 'cursor.credits', 'cursor'],
  ]) {
    await app.getByRole('button', { name: 'Options', exact: true }).click();
    await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
    if (provider === 'cursor') await app.getByRole('switch', { name, exact: true }).click();
    await app.getByRole('button', { name: `Open ${name}`, exact: true }).click();
    await app.locator(`[data-metric-toggle="${metric}"]`).click();
    await app.getByRole('button', { name: 'Back', exact: true }).click();
    await app.getByRole('button', { name: 'Back', exact: true }).click();
    const section = app.locator(`[data-card="${card}"]`);
    await section.getByRole('button', { name: 'Show more', exact: true }).click();
    const row = section.locator(`[data-metric="${metric}"]`);
    await expect(row).toBeVisible();
    await expect(row).toContainText('No data');
    await expect(row.locator('.am-meter')).toHaveCount(0);
  }
});

test('On Demand metrics remain visible when every Always Visible metric is disabled', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Options', exact: true }).click();
  await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
  await app.getByRole('button', { name: 'Open Claude', exact: true }).click();
  for (const metric of ['claude.session', 'claude.weekly', 'claude.fable']) await app.locator(`[data-metric-toggle="${metric}"]`).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app.locator('[data-card="claude-account-1"] [data-metric="claude.trend"]')).toBeVisible();
});

test('provider quick links expose their destinations', async ({ page }) => {
  await openHome(page);
  const card = page.locator('[data-mock] [data-card="claude-account-1"]');
  await card.getByRole('button', { name: 'Show more', exact: true }).click();
  await expect(card.getByRole('link', { name: 'Status', exact: true })).toHaveAttribute('href', 'https://status.claude.com/');
  await expect(card.getByRole('link', { name: 'Dashboard', exact: true })).toHaveAttribute('href', 'https://claude.ai/settings/usage');
});

test('selected spend periods remain readable in the Light theme', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Light');
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  const colors = await app.locator('[data-period="today"]').evaluate((element) => ({
    text: getComputedStyle(element).color,
    background: getComputedStyle(element).backgroundColor,
  }));
  const luminance = (color: string) => (color.match(/[\d.]+/g) ?? []).slice(0, 3)
    .map((value) => Number(value) / 255)
    .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
    .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  const values = [luminance(colors.text), luminance(colors.background)].sort((a, b) => a - b);
  expect((values[1] + 0.05) / (values[0] + 0.05)).toBeGreaterThanOrEqual(4.5);
});

test('Customize provider and metric switches update dashboard visibility', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const customize = async (): Promise<void> => {
    await app.getByRole('button', { name: 'Options', exact: true }).click();
    await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
  };
  await customize();
  await app.getByRole('switch', { name: 'Claude', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeHidden();
  await customize();
  await app.getByRole('switch', { name: 'Claude', exact: true }).click();
  await app.getByRole('button', { name: 'Open Claude', exact: true }).click();
  const metric = app.locator('[data-scr="metrics:claude"] [data-metric-toggle][aria-checked="true"]').first();
  const id = await metric.getAttribute('data-metric-toggle');
  await metric.click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator(`[data-card="claude-account-1"] [data-metric="${id}"]`)).toBeHidden();
});

test('a menu closes on a later content scroll and restores its trigger focus', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const button = app.getByRole('button', { name: 'Options', exact: true });
  await button.click();
  await expect(app.getByRole('menu', { name: 'Options', exact: true })).toBeVisible();
  await app.locator('[data-scr="dashboard"] .am-body').evaluate((element) => { element.scrollTop = 50; });
  await expect(app.getByRole('menu', { name: 'Options', exact: true })).toBeHidden();
  await expect(button).toBeFocused();
});

test('selecting a spend metric returns keyboard focus to its button', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Cost', exact: true }).press('Enter');
  await expect(app.getByRole('menu', { name: 'Total Spend Metric' })).toBeVisible();
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(app.getByRole('button', { name: 'Cost/MTok', exact: true })).toBeFocused();
  await expect(app.getByRole('menu', { name: 'Total Spend Metric' })).toBeHidden();
  await expect(app.locator('[data-state="today:costPerMtok"]')).toBeVisible();
});

test('spend period radios support arrow keys without scrolling the page', async ({ page }) => {
  await openHome(page);
  const periods = page.getByRole('radiogroup', { name: 'Total Spend Period' });
  await periods.getByRole('radio', { name: 'Today', exact: true }).focus();
  const initialY = await page.evaluate(() => scrollY);
  await page.keyboard.press('ArrowRight');
  const yesterday = periods.getByRole('radio', { name: 'Yesterday', exact: true });
  await expect(yesterday).toHaveAttribute('aria-checked', 'true');
  await expect(yesterday).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(periods.getByRole('radio', { name: '30 Days', exact: true })).toHaveAttribute('aria-checked', 'true');
  await page.keyboard.press('ArrowRight');
  await expect(periods.getByRole('radio', { name: 'Today', exact: true })).toHaveAttribute('aria-checked', 'true');
  await expect(periods.locator('[tabindex="0"]')).toHaveCount(1);
  expect(await page.evaluate(() => scrollY)).toBe(initialY);
});
