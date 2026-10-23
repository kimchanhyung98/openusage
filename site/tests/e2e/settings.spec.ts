import { test, expect, openHome, openSettings, chooseSetting } from './fixtures';

test('language selection persists while the website demo stays in English', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  const languagePicker = app.getByRole('button', { name: 'Language', exact: true });
  const selectedLanguage = languagePicker.locator('[data-picker-value]');
  await expect(selectedLanguage).toHaveAttribute('lang', 'en');
  await expect(app.locator('[data-language-notice]')).toBeHidden();
  await languagePicker.click();
  for (const [name, language] of [['English', 'en'], ['한국어', 'ko'], ['日本語', 'ja']]) {
    await expect(app.getByRole('menuitemradio', { name, exact: true })).toHaveAttribute('lang', language);
  }
  await app.getByRole('menuitemradio', { name: '한국어', exact: true }).click();
  await expect(selectedLanguage).toHaveAttribute('lang', 'ko');
  await chooseSetting(page, 'Language', '日本語');
  await expect(languagePicker).toContainText('日本語');
  await expect(selectedLanguage).toHaveAttribute('lang', 'ja');
  await expect(app.getByRole('status')).toContainText('restart OpenUsage to apply it');
  await expect(app.locator('[data-language-notice]')).toHaveText('Restart OpenUsage to apply the language change.');
  await expect(app.locator('[data-language-notice]')).toBeVisible();
  await expect(app).toHaveAttribute('lang', 'en');
  await page.reload();
  await openSettings(page);
  await expect(languagePicker).toContainText('日本語');
  await expect(selectedLanguage).toHaveAttribute('lang', 'ja');
  await expect(app.getByRole('button', { name: 'Theme', exact: true })).toBeVisible();
  await expect(app).toHaveAttribute('lang', 'en');
  await chooseSetting(page, 'Language', '한국어');
  await expect(app.getByRole('status')).toContainText('restart OpenUsage to apply it');
  await chooseSetting(page, 'Language', 'English');
  await expect(selectedLanguage).toHaveAttribute('lang', 'en');
  await expect(app.getByRole('status')).toHaveText('The demo stays in English.');
  await expect(app.locator('[data-language-notice]')).toBeHidden();
});

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
