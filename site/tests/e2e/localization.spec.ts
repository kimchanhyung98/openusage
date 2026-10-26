import type { Locator } from '@playwright/test';
import { test, expect, openHome, openSettings } from './fixtures';

async function choose(app: Locator, id: string, value: string): Promise<void> {
  const picker = app.locator(`[data-picker="${id}"]`);
  await picker.click();
  await app.locator(`[data-pick="${id}"][data-value="${value}"]`).click();
  await expect(picker).toBeFocused();
}

async function settings(app: Locator): Promise<void> {
  await app.locator('[data-options]').click();
  await app.locator('.am-optmenu [data-go="settings"]').click();
  await expect(app).toHaveAttribute('data-screen', 'settings');
}

test('Korean applies immediately to settings, accounts, dashboard details, and customization', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const documentStart = await page.evaluate(() => performance.timeOrigin);
  await openSettings(page);
  await choose(app, 'language', '한국어');
  await expect(app).toHaveAttribute('lang', 'ko');
  await expect(app).toHaveAttribute('data-screen', 'settings');
  expect(await page.evaluate(() => performance.timeOrigin)).toBe(documentStart);
  for (const download of await page.locator('[data-download]').all()) await expect(download).toContainText('다운로드');

  const screen = app.locator('[data-scr="settings"]');
  await expect(screen.locator('.am-topbar > b')).toHaveText('설정');
  await expect(screen.locator('[data-settings-group="general"] > b')).toHaveText('일반');
  await expect(screen.locator('[data-settings-group="privacy"] > b')).toHaveText('개인정보 보호');
  await expect(screen.locator('[data-settings-group="advanced"] > b')).toHaveText('고급');
  await expect(screen.locator('[data-language-notice]')).toHaveText('이 미리보기에서는 언어 변경이 즉시 적용됩니다.');
  await expect(screen.getByRole('button', { name: '언어', exact: true })).toContainText('한국어');
  await screen.getByRole('button', { name: '단축키 지정', exact: true }).click();
  await expect(app.getByRole('status')).toHaveText('Mac 앱에서 전역 단축키를 지정하세요.');

  await screen.locator('[data-account-switch="codex"][data-account-id="account-2"]').click();
  const dialog = app.getByRole('dialog', { name: '계정을 전환할까요?' });
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('[data-account-confirm-text]')).toHaveText('이 미리보기의 사용 계정을 계정 2로 바꿀까요? Mac의 로그인 상태는 그대로 유지됩니다.');
  await dialog.getByRole('button', { name: '취소', exact: true }).click();
  await screen.getByRole('button', { name: '뒤로', exact: true }).click();

  const spend = app.locator('.am-spend-card');
  await expect(spend.locator('[data-metric-label="cost"]')).toHaveText('비용');
  await expect(spend.getByRole('radio', { name: '오늘', exact: true })).toBeVisible();
  await spend.locator('[data-metric-btn]').click();
  await spend.getByRole('menuitemradio', { name: '토큰', exact: true }).click();
  await expect(spend.locator('[data-state="today:tokens"] .am-ring-center')).toContainText('백만');

  const codex = app.locator('[data-card="codex-account-1"]');
  await expect(codex.locator('[data-account-title]')).toHaveText('Codex: 계정 1');
  await expect(codex.locator('[data-metric="codex.session"] .am-row-label > b')).toHaveText('세션');
  await codex.getByRole('button', { name: '더 보기', exact: true }).click();
  const forecast = codex.locator('[data-metric="codex.resetWatch"]');
  await expect(forecast).toBeVisible();
  await expect(forecast.locator('.am-row-label > b')).toHaveText('초기화 예측');
  await expect(forecast.locator('.am-headline')).toHaveText('가능성 65%');
  await expect(forecast.getByRole('img', { name: '초기화 가능성 높음', exact: true })).toBeVisible();
  await expect(forecast.locator('.am-votes')).toHaveText('72%가 초기화 예상');
  await expect(forecast.locator('.am-votes')).toHaveAttribute('aria-label', '커뮤니티 투표 비율: 72%');
  await codex.locator('.am-reset-trigger').click();
  await expect(codex.locator('.am-reset-trigger')).toContainText('2개 사용 가능');
  const resetDetails = codex.getByRole('dialog', { name: '한도 초기화권', exact: true });
  await expect(resetDetails).toBeVisible();
  await expect(resetDetails.locator('.am-reset-date')).toHaveText(['10월 31일 10:00', '11월 7일 10:00']);
  await expect(resetDetails.locator('.am-reset-countdown')).toHaveText(['4일 19시간', '11일 19시간']);
  await page.keyboard.press('Escape');
  await expect(resetDetails).toBeHidden();

  await app.locator('[data-options]').click();
  await app.getByRole('menuitem', { name: '커스터마이즈', exact: true }).click();
  await app.locator('[data-scr="customize"] [data-go="metrics:codex"]').click();
  const metrics = app.locator('[data-scr="metrics:codex"]');
  await expect(metrics.locator('.am-group > b')).toHaveText(['항상 표시', '필요 시 표시']);
  await expect(metrics.getByRole('switch', { name: '초기화 예측', exact: true })).toBeVisible();
  await expect(metrics.locator('[data-star="codex.session"] .am-sr')).toHaveText('세션 메뉴 막대에 고정');
});

test('Korean remains applied after display changes and restores on reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await choose(app, 'language', '한국어');
  await choose(app, 'timeFormat', '12-hour');
  await choose(app, 'showUsageAs', 'Left');
  await choose(app, 'density', 'Default');
  await expect(app.locator('[data-picker="timeFormat"]')).toContainText('12시간제');
  await expect(app.locator('[data-picker="showUsageAs"]')).toContainText('남음');
  await expect(app.locator('[data-picker="density"]')).toContainText('기본');
  await app.locator('[data-scr="settings"] .am-back').click();

  const codex = app.locator('[data-card="codex-account-1"]');
  const session = codex.locator('[data-metric="codex.session"]');
  await expect(session.locator('.am-headline .l')).toHaveText('72% 남음');
  await expect(session.locator('.abs')).toHaveText('오늘 오후 9:00 초기화');
  await codex.locator('[data-expand]').click();
  const forecast = codex.locator('[data-metric="codex.resetWatch"]');
  await expect(forecast.locator('.abs')).toHaveText('10월 27일 오전 10:00까지');
  await forecast.locator('[data-toggle-reset]').click();
  await expect(forecast.locator('.rel')).toBeVisible();
  await expect(forecast.locator('.rel')).toHaveText('18시간 30분 이내');
  await expect(session.locator('.rel')).toHaveText('6시간 0분 후 초기화');

  await page.reload();
  await expect(app).toHaveAttribute('lang', 'ko');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(app).toHaveAttribute('data-reset', 'relative');
  await expect(session.locator('.am-headline .l')).toHaveText('72% 남음');
  await settings(app);
  await expect(app.locator('[data-picker="language"] [data-picker-value]')).toHaveText('한국어');
  await expect(app.locator('[data-picker="language"] [data-picker-value]')).toHaveAttribute('lang', 'ko');
  await expect(app.locator('[data-picker="timeFormat"]')).toContainText('12시간제');
  await expect(app.locator('[data-picker="resetTimes"]')).toContainText('남은 시간');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('openusage.site.preview.v1')!).preferences))
    .toMatchObject({ language: '한국어', timeFormat: '12-hour', showUsageAs: 'Left', resetTimes: 'Countdown' });
});

test('language cycles through Korean, Japanese, and English across interactive and tour screens', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const tour = page.locator('[data-tour-mock]');
  const sheet = page.locator('[data-tour-sheet]');
  const downloads = page.locator('[data-download]');
  await expect(downloads).toContainText(['Download', 'Download', 'Download']);
  await openSettings(page);
  for (const [language, locale, title, label, sheetTitle, downloadLabel] of [
    ['한국어', 'ko', '설정', '언어', 'Claude 계정 추가', '다운로드'],
    ['日本語', 'ja', '設定', '言語', 'Claude アカウントを追加', 'ダウンロード'],
    ['English', 'en', 'Settings', 'Language', 'Add Claude Account', 'Download'],
  ]) {
    await choose(app, 'language', language);
    for (const root of [app, tour, sheet]) await expect(root).toHaveAttribute('lang', locale);
    await expect(app.locator('[data-scr="settings"] .am-topbar > b')).toHaveText(title);
    await expect(app.locator('[data-picker="language"]')).toHaveAttribute('aria-label', label);
    await expect(app.locator('[data-picker="language"] [data-picker-value]')).toHaveText(language);
    await expect(app.locator('[data-picker="language"] [data-picker-value]')).toHaveAttribute('lang', locale);
    await expect(sheet.locator('.tour-sheet-head > b')).toHaveText(sheetTitle);
    await expect(downloads).toContainText([downloadLabel, downloadLabel, downloadLabel]);
    await expect(page.locator('.hero [data-download]')).toHaveText(downloadLabel);
  }
  await expect(app.locator('[data-language-notice]')).toHaveText('Language changes apply immediately in this preview.');
  await app.locator('[data-scr="settings"] .am-back').click();
  const codex = app.locator('[data-card="codex-account-1"]');
  await expect(codex.locator('[data-account-title]')).toHaveText('Codex: Account 1');
  await codex.getByRole('button', { name: 'Show more', exact: true }).click();
  await expect(codex.getByRole('img', { name: 'Reset chance is high', exact: true })).toBeVisible();
  await expect(codex.locator('.am-forecast .am-headline')).toHaveText('65% chance');
  await expect(codex.locator('.am-forecast .abs')).toHaveText('By Oct 27 at 10:00');
  await expect(app.locator('.am-spend-card [data-period="today"]')).toHaveText('Today');
});
