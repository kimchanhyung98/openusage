import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { accountFamilies } from '../src/data/accounts.ts';
import { settingGroups } from '../src/data/settings.ts';
import { initialPreviewState, changePreference, selectDashboardAccount, activateAccount, restorePreviewState, previewTime } from '../src/data/preview-state.ts';

const source = (path: string): string => readFileSync(new URL(`../../Sources/OpenUsage/${path}`, import.meta.url), 'utf8');

test('Settings covers every native section in display order', () => {
  const body = source('Views/SettingsScreen.swift').split('return VStack(alignment: .leading, spacing: density.sectionSpacing)')[1].split('ScreenCrossLinkRow(')[0];
  const sections: Record<string, string> = {
    AccountsSettingsSection: 'Accounts', ICloudSyncSettingsSection: 'iCloud Sync', notificationsSection: 'Notifications',
    TokscaleSettingsSection: 'Tokscale', commandLineSection: 'Command Line', advancedSection: 'Advanced',
  };
  const native = [...body.matchAll(/section\("([^"]+)"\)|\b(AccountsSettingsSection|ICloudSyncSettingsSection|notificationsSection|TokscaleSettingsSection|commandLineSection|advancedSection)\b/g)]
    .map((match) => match[1] ?? sections[match[2]]);
  assert.deepEqual(settingGroups.map((group) => group.title), native);
});

test('Settings includes normal native rows and notification triggers', () => {
  const labels = new Set(settingGroups.flatMap((group) => group.rows.map((row) => row.label)));
  const hiddenEasterEggs = new Set(['Party Mode', 'Drunk Mode']);
  for (const match of source('Views/SettingsScreen.swift').matchAll(/row\("([^"]+)"\)/g)) {
    if (!hiddenEasterEggs.has(match[1])) assert.ok(labels.has(match[1]), match[1]);
  }
  const milestones = source('Support/PaceNotificationLogic.swift').split('var settingLabel: String')[1].split('var notificationTitle')[0];
  for (const match of milestones.matchAll(/return "([^"]+)"/g)) assert.ok(labels.has(match[1]), match[1]);
});

test('Settings includes the native Log Level options and app actions', () => {
  const expected = [...source('Stores/LogLevelSetting.swift').matchAll(/case \.\w+: "([^"]+)"/g)].map((match) => match[1]);
  const logLevel = settingGroups.flatMap((group) => group.rows).find((row) => row.id === 'logLevel')!.control;
  assert.equal(logLevel.kind, 'picker');
  if (logLevel.kind === 'picker') assert.deepEqual(logLevel.options, expected);
  const actions = settingGroups.flatMap((group) => group.rows).flatMap((row) => row.control.kind === 'action' ? [row.control.label] : []);
  for (const action of ['Record Shortcut', 'Sync', 'Install…', 'Copy Log Path', 'Reveal in Finder', 'Check for Updates…']) assert.ok(actions.includes(action), action);
});

test('public account examples are shared, generic, and have one active account', () => {
  for (const family of accountFamilies) {
    assert.ok(family.profiles.every((profile) => /^Account \d+$/.test(profile.name)));
    assert.equal(family.profiles.filter((profile) => profile.id === family.activeAccount).length, 1);
    assert.equal(settingGroups.find((group) => group.id === 'accounts')!.families, accountFamilies);
  }
});

test('dashboard selection does not switch the active account', () => {
  const before = initialPreviewState();
  const after = selectDashboardAccount(before, 'claude', 'account-2');
  assert.equal(after.viewedAccounts.claude, 'account-2');
  assert.equal(after.activeAccounts.claude, 'account-1');
  assert.equal(before.viewedAccounts.claude, 'account-1');
  assert.deepEqual(after.preferences, before.preferences);
});

test('confirmed Settings switching selects exactly one account and moves the dashboard once', () => {
  const switched = activateAccount(initialPreviewState(), 'codex', 'account-2');
  assert.equal(switched.activeAccounts.codex, 'account-2');
  assert.equal(switched.viewedAccounts.codex, 'account-2');
  const viewed = selectDashboardAccount(switched, 'codex', 'account-1');
  assert.equal(viewed.activeAccounts.codex, 'account-2');
  assert.equal(viewed.viewedAccounts.codex, 'account-1');
  assert.equal(viewed.activeAccounts.claude, 'account-1');
});

test('card presentation preserves both account choices across mode changes and reload', () => {
  let state = activateAccount(initialPreviewState(), 'claude', 'account-2');
  state = selectDashboardAccount(state, 'claude', 'account-1');
  state = changePreference(state, 'usageCards', 'Separate Cards');
  state = changePreference(state, 'showUsageAs', 'Left');
  state = changePreference(state, 'resetTimes', 'Countdown');
  const restored = restorePreviewState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(restored, state);
  const single = changePreference(restored, 'usageCards', 'Single Card');
  assert.equal(single.viewedAccounts.claude, 'account-1');
  assert.equal(single.activeAccounts.claude, 'account-2');
  assert.equal(single.preferences.showUsageAs, 'Left');
  assert.equal(single.preferences.resetTimes, 'Countdown');
});

test('invalid stored values cannot inject settings or select unknown accounts', () => {
  const state = initialPreviewState();
  assert.throws(() => changePreference(state, 'theme', 'Rainbow'));
  assert.throws(() => changePreference(state, 'showTotalSpend', 'false'));
  assert.throws(() => changePreference(state, 'usageSync', true));
  assert.throws(() => activateAccount(state, 'codex', 'company'));
  assert.throws(() => restorePreviewState([]));
  assert.throws(() => restorePreviewState({ ...state, preferences: { ...state.preferences, theme: 'invalid' } }));
});

test('time formatting handles noon, midnight, dates, and system preference', () => {
  assert.equal(previewTime('Resets Sep 15 at 00:05', '12-hour', false), 'Resets Sep 15 at 12:05 AM');
  assert.equal(previewTime('Limit today at 12:30', '12-hour', false), 'Limit today at 12:30 PM');
  assert.equal(previewTime('Resets today at 18:20', 'Auto', true), 'Resets today at 6:20 PM');
  assert.equal(previewTime('Resets today at 18:20', 'Auto', false), 'Resets today at 18:20');
  assert.equal(previewTime('Resets in 5h 12m', '12-hour', true), 'Resets in 5h 12m');
});
