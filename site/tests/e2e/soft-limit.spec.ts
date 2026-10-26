import type { Locator } from '@playwright/test';
import { test, expect, openHome, openSettings, chooseSetting } from './fixtures';

async function markerFraction(row: Locator): Promise<number> {
  return row.evaluate((element) => {
    const track = element.querySelector('.am-meter')!.getBoundingClientRect();
    const marker = element.querySelector('.am-soft-marker')!.getBoundingClientRect();
    return (marker.left - track.left) / track.width;
  });
}

test('Soft Limit covers Fable and Antigravity model windows and mirrors them in Left mode', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  const fable = app.locator('[data-card="claude-account-1"] [data-metric="claude.fable"]');
  const antigravity = app.locator('[data-card="antigravity"]');
  await antigravity.getByRole('button', { name: 'Show more', exact: true }).click();
  const session = antigravity.locator('[data-metric="antigravity.claude"]');
  const weekly = antigravity.locator('[data-metric="antigravity.claudeWeekly"]');

  for (const row of [fable, weekly]) {
    await expect(row.locator('.am-soft-marker')).toBeVisible();
    expect(await markerFraction(row)).toBeCloseTo(0.9, 2);
  }
  await expect(session.locator('.am-soft-marker')).toBeHidden();
  await fable.locator('[data-toggle-meter]').click();
  for (const row of [fable, weekly]) expect(await markerFraction(row)).toBeCloseTo(0.1, 2);

  await openSettings(page);
  await chooseSetting(page, 'Window', '5 Hours');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  for (const row of [fable, weekly]) await expect(row.locator('.am-soft-marker')).toBeHidden();
  await expect(session.locator('.am-soft-marker')).toBeVisible();
  expect(await markerFraction(session)).toBeCloseTo(0.1, 2);
  await session.locator('[data-toggle-meter]').click();
  expect(await markerFraction(session)).toBeCloseTo(0.9, 2);
});

test('Soft Limit does not add guides to supported metrics without data or the public forecast', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();

  for (const [provider, metric] of [['Claude', 'claude.sonnet'], ['Codex', 'codex.spark']]) {
    await app.getByRole('button', { name: 'Options', exact: true }).click();
    await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
    await app.getByRole('button', { name: `Open ${provider}`, exact: true }).click();
    await app.locator(`[data-metric-toggle="${metric}"]`).click();
    await app.getByRole('button', { name: 'Back', exact: true }).click();
    await app.getByRole('button', { name: 'Back', exact: true }).click();
    const card = app.locator(`[data-card="${provider.toLowerCase()}-account-1"]`);
    await card.getByRole('button', { name: 'Show more', exact: true }).click();
    const row = card.locator(`[data-metric="${metric}"]`);
    await expect(row).toBeVisible();
    await expect(row).toContainText('No data');
    await expect(row.locator('.am-meter, .am-soft-marker')).toHaveCount(0);
  }
  const forecast = app.locator('[data-card="codex-account-1"] .am-forecast');
  await expect(forecast).toBeVisible();
  await expect(forecast).toContainText('65% chance');
  await expect(forecast.locator('.am-soft-marker')).toHaveCount(0);
  await openSettings(page);
  await chooseSetting(page, 'Window', '5 Hours');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(forecast).toContainText('65% chance');
  await expect(forecast.locator('.am-soft-marker')).toHaveCount(0);
  await expect(app.locator('[data-metric="codex.spark"] .am-soft-marker')).toHaveCount(0);
});
