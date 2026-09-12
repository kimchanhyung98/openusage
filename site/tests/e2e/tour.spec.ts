import { test, expect, openHome } from './fixtures';

const stages = ['menu-bar', 'dashboard', 'statistics', 'accounts', 'integrations'];

test('all tour tabs support keyboard navigation without moving the page', async ({ page }) => {
  await openHome(page);
  const tour = page.locator('[data-feature-tour]');
  await tour.scrollIntoViewIfNeeded();
  const first = tour.locator('[data-tour-tab="menu-bar"]');
  await first.click();
  await first.focus();
  const y = await page.evaluate(() => scrollY);
  for (const stage of stages) {
    if (stage !== 'menu-bar') await page.keyboard.press('ArrowRight');
    await expect(tour).toHaveAttribute('data-tour-stage', stage);
    await expect(tour.locator(`[data-tour-tab="${stage}"]`)).toBeFocused();
    await expect(tour.locator(`[data-tour-description="${stage}"]`)).toBeVisible();
    await expect(page.locator('#feature-stage')).toHaveAttribute('aria-labelledby', `tab-${stage}`);
    expect(await page.evaluate(() => scrollY)).toBe(y);
  }
  await page.keyboard.press('Home');
  await expect(first).toBeFocused();
  await page.keyboard.press('End');
  await expect(tour.locator('[data-tour-tab="integrations"]')).toBeFocused();
  await expect(tour.locator('[data-tour-terminal]')).toBeVisible();
});

test('animated account onboarding completes and interrupted tours settle cleanly', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await openHome(page);
  const tour = page.locator('[data-feature-tour]');
  const account = tour.locator('[data-tour-tab="accounts"]');
  await account.click();
  await expect(tour).toHaveAttribute('data-tour-phase', 'account-added', { timeout: 15_000 });
  await expect(tour.locator('[data-tour-account]')).toBeVisible();
  await expect(tour.locator('[data-tour-sheet]')).toBeHidden();
  await account.click();
  await expect(tour).toHaveAttribute('data-tour-phase', 'opening-options');
  await tour.locator('[data-tour-tab="integrations"]').click();
  await expect(tour).toHaveAttribute('data-tour-phase', 'integrations');
  await expect(tour.locator('[data-tour-sheet]')).toBeHidden();
  await account.click();
  await account.focus();
  await page.keyboard.press('Escape');
  await expect(tour).toHaveAttribute('data-tour-phase', 'account-added');
  await expect(tour.locator('[data-tour-account]')).toBeVisible();
  await expect(tour.locator('[data-tour-cursor]')).not.toHaveClass(/is-visible/);
  await expect(tour).not.toHaveAttribute('data-tour-error');
});
