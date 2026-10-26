import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import { accountFamilies } from '../src/data/accounts.ts';
import { settingGroups } from '../src/data/settings.ts';
import { softLimitWindows } from '../src/data/metrics.ts';
import { initialPreviewState, changePreference, selectDashboardAccount, activateAccount, restorePreviewState, previewTime } from '../src/data/preview-state.ts';

const source = (path: string): string => readFileSync(new URL(`../../Sources/OpenUsage/${path}`, import.meta.url), 'utf8');
const englishSource = (path: string): string => source(path)
  .replace(/\bL10n\.\w+\(\s*("(?:\\.|[^"\\])*")\s*\)/g, '$1');

test('Settings covers every native section in display order', () => {
  const body = englishSource('Views/SettingsScreen.swift').split('return VStack(alignment: .leading, spacing: density.sectionSpacing)')[1].split('ScreenCrossLinkRow(')[0];
  const sections: Record<string, string> = {
    AccountsSettingsSection: 'Accounts', ICloudSyncSettingsSection: 'iCloud Sync', notificationsSection: 'Notifications',
    TokscaleSettingsSection: 'Tokscale', commandLineSection: 'Command Line', advancedSection: 'Advanced',
    SoftLimitSettingsSection: 'Soft Limit',
  };
  const native = [...body.matchAll(/section\("([^"]+)"\)|\b(AccountsSettingsSection|ICloudSyncSettingsSection|SoftLimitSettingsSection|notificationsSection|TokscaleSettingsSection|commandLineSection|advancedSection)\b/g)]
    .map((match) => match[1] ?? sections[match[2]]);
  assert.ok(native.includes('General'), 'The native section extractor must find the General section');
  assert.deepEqual(settingGroups.map((group) => group.title), native);
});

test('Settings includes normal native rows and notification triggers', () => {
  const labels = new Set(settingGroups.flatMap((group) => group.rows.map((row) => row.label)));
  const hiddenEasterEggs = new Set(['Party Mode', 'Drunk Mode']);
  const settingsSource = englishSource('Views/SettingsScreen.swift');
  assert.match(settingsSource, /\bLanguageSettingsRow\(selection:/);
  const nativeRows = [...settingsSource.matchAll(/row\("([^"]+)"\)/g)].map((match) => match[1]);
  const languageRows = [...englishSource('Views/LanguageSettingsRow.swift').matchAll(/Text\("([^"]+)"\)\s+Spacer\([^)]*\)\s+Picker\(/g)]
    .map((match) => match[1]);
  nativeRows.push(...languageRows);
  assert.ok(nativeRows.includes('Language'), 'The native row extractor must find the Language picker');
  assert.ok(nativeRows.includes('Show Total Spend'), 'The native row extractor must keep existing rows');
  for (const label of nativeRows) {
    if (!hiddenEasterEggs.has(label)) assert.ok(labels.has(label), label);
  }
  const milestones = englishSource('Support/PaceNotificationLogic.swift').split('var settingLabel: String')[1].split('var notificationTitle')[0];
  const milestoneLabels = [...milestones.matchAll(/(?:return|case \.\w+:)\s*"([^"]+)"/g)].map((match) => match[1]);
  assert.equal(milestoneLabels.length, 3, 'Every native notification trigger must be checked');
  for (const label of milestoneLabels) assert.ok(labels.has(label), label);
  const resetWatch = englishSource('Stores/CodexResetWatchNotificationEvaluator.swift');
  const resetWatchLabel = resetWatch.match(/static var settingLabel: String \{ "([^"]+)" \}/)?.[1];
  assert.ok(resetWatchLabel, 'The native Reset Watch notification label must be checked');
  assert.ok(labels.has(resetWatchLabel));
});

test('Soft Limit preserves its threshold, rejects invalid percentages, and defaults to off', () => {
  const initial = initialPreviewState();
  assert.equal(initial.preferences.softLimitEnabled, false);
  assert.equal(initial.preferences.softLimitWindow, 'Weekly');
  assert.equal(initial.preferences.softLimitThreshold, '90');
  const changed = changePreference(initial, 'softLimitThreshold', '95');
  assert.equal(restorePreviewState(changed).preferences.softLimitThreshold, '95');
  for (const invalid of ['0', '101', '-1', '90.5', '', 'abc']) {
    assert.throws(() => changePreference(changed, 'softLimitThreshold', invalid));
  }
  assert.equal(initial.preferences.codexResetWatch, false);
});

test('Soft Limit windows match every native provider declaration', () => {
  const constants = Object.fromEntries([...source('Providers/Antigravity/AntigravityMetric.swift')
    .matchAll(/static let (\w+) = "([^"]+)"/g)].map((match) => [`AntigravityMetric.${match[1]}`, match[2]]));
  const native: Record<string, string> = {};
  const files = readdirSync(new URL('../../Sources/OpenUsage/Providers/', import.meta.url), { recursive: true, encoding: 'utf8' })
    .filter((path) => path.endsWith('Provider.swift'));
  for (const file of files) {
    const family = file.split('/')[0].toLowerCase();
    let metric: string | undefined;
    for (const match of source(`Providers/${file}`).matchAll(/\bid:\s*("[^"]+"|AntigravityMetric\.\w+)|\.supportingSoftLimit\(\.(fiveHours|weekly)\)/g)) {
      if (match[1]) {
        metric = match[1].startsWith('"') ? match[1].slice(1, -1).replace('\\(provider.id)', family) : constants[match[1]];
      } else {
        assert.ok(metric, `The native metric ID must be resolved in ${file}`);
        native[metric] = match[2] === 'fiveHours' ? '5 Hours' : 'Weekly';
      }
    }
  }
  assert.equal(Object.keys(native).length, 19, 'Every native Soft Limit declaration must be checked');
  assert.deepEqual(softLimitWindows, native);
});

test('Settings includes the native Log Level options and app actions', () => {
  const expected = [...englishSource('Stores/LogLevelSetting.swift').matchAll(/case \.\w+: "([^"]+)"/g)].map((match) => match[1]);
  assert.equal(expected.length, 4, 'Every native log level must be checked');
  const logLevel = settingGroups.flatMap((group) => group.rows).find((row) => row.id === 'logLevel')!.control;
  assert.equal(logLevel.kind, 'picker');
  if (logLevel.kind === 'picker') assert.deepEqual(logLevel.options, expected);
  const actions = settingGroups.flatMap((group) => group.rows).flatMap((row) => row.control.kind === 'action' ? [row.control.label] : []);
  for (const action of ['Record Shortcut', 'Sync', 'Install…', 'Copy Log Path', 'Reveal in Finder', 'Check for Updates…']) assert.ok(actions.includes(action), action);
});

test('Language offers the three app languages and starts in English', () => {
  const control = settingGroups.flatMap((group) => group.rows).find((row) => row.id === 'language')!.control;
  assert.equal(control.kind, 'picker');
  if (control.kind !== 'picker') return;
  assert.deepEqual(control.options, ['English', '한국어', '日本語']);
  assert.equal(initialPreviewState().preferences.language, 'English');
  for (const language of control.options) {
    const changed = changePreference(initialPreviewState(), 'language', language);
    assert.equal(restorePreviewState(JSON.parse(JSON.stringify(changed))).preferences.language, language);
  }
  assert.equal(settingGroups[0].title, 'General');
  assert.throws(() => changePreference(initialPreviewState(), 'language', 'System'));
  const oldState = initialPreviewState();
  delete oldState.preferences.language;
  assert.equal(restorePreviewState(oldState).preferences.language, 'English');
});

test('public account examples are shared, generic, and have one active account', () => {
  for (const family of accountFamilies) {
    assert.ok(family.profiles.every((profile) => /^Account \d+$/.test(profile.name)));
    assert.equal(family.profiles.filter((profile) => profile.id === family.activeAccount).length, 1);
    assert.equal(settingGroups.find((group) => group.id === 'accounts')!.families, accountFamilies);
  }
});

test('the web preview starts with both Codex accounts and preserves an explicit single-card choice', () => {
  const initial = initialPreviewState();
  assert.equal(initial.preferences.usageCards, 'Separate Cards');
  assert.equal(accountFamilies.find((family) => family.id === 'codex')?.profiles.length, 2);
  const single = changePreference(initial, 'usageCards', 'Single Card');
  assert.equal(restorePreviewState(JSON.parse(JSON.stringify(single))).preferences.usageCards, 'Single Card');
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
