import { test, expect, openHome, openSettings, chooseSetting } from './fixtures';

test('Reset Watch keeps probability and votes when usage flips, and shares time preferences', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const codex = app.locator('[data-card="codex-account-1"]');
  await codex.getByRole('button', { name: 'Show more', exact: true }).click();
  const forecast = codex.locator('[data-metric="codex.resetWatch"]');
  await expect(forecast).toContainText('65% chance');
  await expect(forecast).toContainText('72% expect a reset');
  await codex.locator('[data-toggle-meter]').first().click();
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(forecast).toContainText('65% chance');
  await expect(forecast.locator('.am-meter i')).toHaveClass('am-w65 is-warning');
  await expect(forecast.locator('.am-meter b')).toHaveClass('am-t72');
  await forecast.locator('[data-toggle-reset]').click();
  await expect(forecast.locator('.rel')).toBeVisible();
  await expect(forecast.locator('.rel')).toHaveText('Within 18h 30m');
  await expect(codex.locator('[data-metric="codex.weekly"] .rel')).toBeVisible();
  await openSettings(page);
  await chooseSetting(page, 'Time Format', '12-hour');
  await chooseSetting(page, 'Reset Times', 'Exact Time');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(forecast.locator('.abs')).toHaveText('By Oct 27 at 10:00 AM');
  await expect(forecast.locator('.abs')).toBeVisible();
});

test('Soft Limit validates percentages, mirrors its guide, and keeps forecast meters separate', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const weekly = app.locator('[data-card="claude-account-1"] [data-metric="claude.weekly"]');
  await expect(weekly.locator('.am-soft-marker')).toBeHidden();
  await openSettings(page);
  const threshold = app.getByRole('spinbutton', { name: 'Threshold' });
  await expect(threshold).toBeHidden();
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await threshold.fill('95');
  await threshold.press('Enter');
  await expect(threshold).toBeFocused();
  await expect(app).toHaveAttribute('data-soft-limit', 'Weekly');
  await threshold.fill('101');
  await threshold.press('Tab');
  await expect(threshold).toHaveValue('95');
  await expect(app.getByRole('status')).toContainText('previous threshold is unchanged');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(weekly.locator('.am-soft-marker')).toBeVisible();
  const markerFraction = () => weekly.evaluate((element) => {
    const track = element.querySelector('.am-meter')!.getBoundingClientRect();
    const marker = element.querySelector('.am-soft-marker')!.getBoundingClientRect();
    return (marker.left - track.left) / track.width;
  });
  expect(await markerFraction()).toBeCloseTo(0.95, 2);
  await weekly.locator('[data-toggle-meter]').click();
  expect(await markerFraction()).toBeCloseTo(0.05, 2);
  await openSettings(page);
  await chooseSetting(page, 'Window', '5 Hours');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(weekly.locator('.am-soft-marker')).toBeHidden();
  await expect(app.locator('[data-card="claude-account-1"] [data-metric="claude.session"] .am-soft-marker')).toBeVisible();
  await expect(app.locator('.am-forecast .am-soft-marker')).toHaveCount(0);
  await page.reload();
  await expect(app).toHaveAttribute('data-soft-limit', '5 Hours');
  await openSettings(page);
  await expect(threshold).toHaveValue('95');
});

test('Reset Watch notifications can be enabled without quota notifications', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  const setting = app.getByRole('switch', { name: 'Codex Reset Watch', exact: true });
  await expect(setting).toHaveAttribute('aria-checked', 'false');
  await setting.click();
  await expect(app.getByRole('button', { name: 'Allow Notifications', exact: true })).toBeVisible();
  for (const name of ['Almost Out', 'Cutting It Close', 'Will Run Out']) {
    await expect(app.getByRole('switch', { name, exact: true })).toHaveAttribute('aria-checked', 'false');
  }
  await page.reload();
  await openSettings(page);
  await expect(setting).toHaveAttribute('aria-checked', 'true');
});

test('dashboard context menu confirms the selected account before switching', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Usage Cards', 'Single Card');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await chooseSetting(page, 'Claude Account', 'Account 2');
  const card = app.locator('[data-card="claude-account-2"]');
  await card.locator('.am-head').click({ button: 'right' });
  const action = card.getByRole('menuitem', { name: 'Use Claude: Account 2', exact: true });
  await expect(action).toBeEnabled();
  await action.click();
  const dialog = app.getByRole('dialog', { name: 'Switch Account?' });
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(card).toHaveAttribute('data-inactive-account', 'true');
  await card.getByRole('button', { name: 'Claude Account', exact: true }).press('Shift+F10');
  await expect(action).toBeFocused();
  await action.press('Enter');
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(card).toHaveAttribute('data-inactive-account', 'false');
  await card.getByRole('button', { name: 'Claude Account', exact: true }).press('Shift+F10');
  await expect(action).toBeDisabled();
  await expect(card.getByRole('menuitem', { name: 'Refresh Claude', exact: true })).toBeFocused();
});

test('text-only account cards keep context menus and restore focus to their headers', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Options', exact: true }).click();
  await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
  await app.locator('[data-scr="customize"] [data-go="metrics:codex"]').click();
  for (const toggle of await app.locator('[data-scr="metrics:codex"] [data-metric-toggle]').all()) {
    const enabled = await toggle.getAttribute('aria-checked') === 'true';
    const today = await toggle.getAttribute('data-metric-toggle') === 'codex.today';
    if (enabled !== today) await toggle.click();
  }
  await app.locator('[data-scr="metrics:codex"] .am-back').click();
  await app.locator('[data-scr="customize"] .am-back').click();
  const first = app.locator('[data-card="codex-account-1"]');
  const second = app.locator('[data-card="codex-account-2"]');
  const firstHeader = first.locator('[data-account-actions-trigger]');
  const secondHeader = second.locator('[data-account-actions-trigger]');
  await expect(first.locator('[data-metric="codex.today"]')).toBeVisible();
  for (const card of [first, second]) {
    await expect(card.locator('.am-head button:visible, .am-card button:visible')).toHaveCount(0);
  }
  await firstHeader.click({ button: 'right' });
  await expect(first.getByRole('menuitem', { name: 'Refresh Codex', exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(firstHeader).toBeFocused();
  await firstHeader.press('Shift+Tab');
  await page.keyboard.press('Tab');
  await expect(firstHeader).toBeFocused();
  await firstHeader.press('Shift+F10');
  await expect(first.locator('.am-account-actions')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(firstHeader).toBeFocused();

  const action = second.getByRole('menuitem', { name: 'Use Codex: Account 2', exact: true });
  await secondHeader.click({ button: 'right' });
  await action.click();
  const dialog = app.getByRole('dialog', { name: 'Switch Account?' });
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(secondHeader).toBeFocused();
  await expect(second).toHaveAttribute('data-inactive-account', 'true');
  await secondHeader.press('Shift+F10');
  await action.press('Enter');
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(secondHeader).toBeFocused();
  await expect(second).toHaveAttribute('data-inactive-account', 'false');
  await expect(second.locator('[data-metric="codex.today"]')).toBeVisible();
});

test('both Codex cards share the public Reset Watch forecast across account switching and reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-usage-cards', 'separate');
  const first = app.locator('[data-card="codex-account-1"]');
  const second = app.locator('[data-card="codex-account-2"]');
  for (const [index, card] of [first, second].entries()) {
    await expect(card).toBeVisible();
    await expect(card.locator('[data-account-title]')).toHaveText(`Codex: Account ${index + 1}`);
    await card.getByRole('button', { name: 'Show more', exact: true }).click();
    await expect(card.locator('.am-forecast')).toBeVisible();
    await expect(card.locator('.am-forecast')).toContainText('65% chance');
    await expect(card.locator('.am-forecast')).toContainText('72% expect a reset');
  }
  await expect(first.locator('[data-metric="codex.session"]')).toContainText('28% used');
  await expect(second.locator('[data-metric="codex.session"]')).toContainText('42% used');
  await second.locator('.am-head').click({ button: 'right' });
  await second.getByRole('menuitem', { name: 'Use Codex: Account 2', exact: true }).click();
  await app.getByRole('dialog').getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(first.locator('.am-forecast')).toBeVisible();
  await expect(second.locator('.am-forecast')).toBeVisible();
  await page.reload();
  await expect(first).toBeVisible();
  await expect(second).toBeVisible();
  await expect(second).toHaveAttribute('data-inactive-account', 'false');
});

test('new feature tours show forecasts, credit count, and guides without leaking stage state', async ({ page }) => {
  await openHome(page);
  const tour = page.locator('[data-feature-tour]');
  await tour.evaluate((element) => element.scrollIntoView({ block: 'start', behavior: 'instant' }));
  await tour.locator('[data-tour-tab="reset-watch"]').click();
  const forecast = tour.locator('[data-metric="codex.resetWatch"]');
  await expect(forecast).toBeInViewport();
  await expect(tour.locator('.am-reset-trigger')).toBeInViewport();
  await expect(tour.locator('.am-reset-detail')).toBeHidden();
  await expect(tour.locator('[data-tour-description="reset-watch"]')).toContainText('비공식 공개 예측');
  await tour.locator('[data-tour-tab="soft-limit"]').click();
  await expect(tour.locator('[data-metric="codex.weekly"] .am-soft-marker')).toBeVisible();
  await expect(tour.locator('[data-tour-description="soft-limit"]')).toContainText('현재 자동 작업 취소는 지원하지 않음');
  await tour.locator('[data-tour-tab="dashboard"]').click();
  await expect(tour.locator('[data-metric="codex.weekly"] .am-soft-marker')).toBeHidden();
  await expect(forecast).toBeHidden();
});

test('reset credit details float above the dashboard without changing card height or requesting provider data', async ({ page, isMobile }) => {
  const external: string[] = [];
  page.on('request', (request) => {
    if (!request.url().startsWith('http://127.0.0.1:')) external.push(request.url());
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  const card = app.locator('[data-card="codex-account-1"]');
  await card.getByRole('button', { name: 'Show more', exact: true }).click();
  const trigger = card.locator('.am-reset-trigger');
  await trigger.scrollIntoViewIfNeeded();
  const height = await card.evaluate((element) => element.getBoundingClientRect().height);
  if (isMobile) await trigger.tap();
  else await trigger.click();
  const detail = card.getByRole('dialog', { name: 'Rate Limit Resets', exact: true });
  await expect(detail).toBeVisible();
  await expect(detail).toBeFocused();
  await expect(detail.locator('.am-reset-countdown')).toHaveText(['4d 19h', '11d 19h']);
  await expect(detail.getByRole('button')).toHaveCount(0);
  expect(await card.evaluate((element) => element.getBoundingClientRect().height)).toBeCloseTo(height, 1);
  const bounds = await detail.boundingBox();
  expect(bounds!.x).toBeGreaterThanOrEqual(8);
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(page.viewportSize()!.width - 8);
  await page.keyboard.press('Escape');
  await expect(detail).toBeHidden();
  await expect(trigger).toBeFocused();
  await trigger.press('Enter');
  await expect(detail).toBeVisible();
  await app.getByRole('button', { name: 'Next update in 4m', exact: true }).click();
  await expect(detail).toBeHidden();
  await expect(app.getByRole('status')).toContainText('sample data');
  expect(external).toEqual([]);
});

test('reset credit hover opens only from the count and remains open while moving into the detail', async ({ page, isMobile }) => {
  test.skip(isMobile, 'Touch uses the tested click and keyboard path');
  await openHome(page);
  const card = page.locator('[data-mock] [data-card="codex-account-1"]');
  await card.getByRole('button', { name: 'Show more', exact: true }).click();
  const row = card.locator('.am-resets');
  const detail = row.locator('.am-reset-detail');
  await row.locator('> b').hover();
  await expect(detail).toBeHidden();
  await row.locator('.am-reset-trigger').hover();
  await expect(detail).toBeVisible();
  await detail.hover();
  await expect(detail).toBeVisible();
  await card.locator('[data-account-title]').hover();
  await expect(detail).toBeHidden();
});
