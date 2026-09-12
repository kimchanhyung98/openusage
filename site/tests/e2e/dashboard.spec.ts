import { test, expect, openHome } from './fixtures';

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
