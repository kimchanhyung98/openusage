import { test, expect, openHome, openSettings, chooseSetting } from './fixtures';

test('dashboard account selection stays separate from confirmed active-account switching', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await chooseSetting(page, 'Claude Account', 'Account 2');
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeHidden();
  await openSettings(page);
  await expect(app.getByRole('switch', { name: 'Claude Account 1', exact: true })).toHaveAttribute('aria-checked', 'true');
  const second = app.getByRole('switch', { name: 'Claude Account 2', exact: true });
  await second.click();
  const dialog = page.getByRole('dialog', { name: 'Switch Account?' });
  await expect(dialog).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
  await expect(second).toBeFocused();
  await expect(second).toHaveAttribute('aria-checked', 'false');
  await second.click();
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(second).toHaveAttribute('aria-checked', 'true');
  await expect(app.getByRole('switch', { name: 'Claude Account 1', exact: true })).toHaveAttribute('aria-checked', 'false');
  await page.reload();
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
  await openSettings(page);
  await expect(app.getByRole('switch', { name: 'Claude Account 2', exact: true })).toHaveAttribute('aria-checked', 'true');
});

test('display settings and separate account cards survive a reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Usage Cards', 'Separate Cards');
  await chooseSetting(page, 'Theme', 'Dark');
  await chooseSetting(page, 'Density', 'Default');
  await chooseSetting(page, 'Time Format', '12-hour');
  await chooseSetting(page, 'Show Usage As', 'Left');
  await chooseSetting(page, 'Reset Times', 'Countdown');
  await app.getByRole('switch', { name: 'Show Total Spend', exact: true }).click();
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app).toHaveAttribute('data-density', 'default');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(app).toHaveAttribute('data-reset', 'relative');
  await expect(app).toHaveAttribute('data-usage-cards', 'separate');
  await expect(app.locator('.am-spend-card')).toBeHidden();
  await expect(app.locator('[data-provider="claude"] [data-account-title]')).toHaveText(['Claude: Account 1', 'Claude: Account 2']);
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
});

test('invalid saved settings recover with defaults and a visible explanation', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', '{broken'));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-mode', 'used');
  await expect(app.getByRole('status')).toContainText('Saved preview settings could not be loaded');
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
});

test('blocked storage reports unsaved changes while the current preview still works', async ({ page }) => {
  await page.addInitScript(() => {
    Storage.prototype.setItem = () => { throw new DOMException('Storage is blocked', 'SecurityError'); };
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app.getByRole('status')).toContainText('Preview changes could not be saved');
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'light');
});
