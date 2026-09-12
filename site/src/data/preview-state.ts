import { accountFamilies } from './accounts.ts';
import { settingGroups } from './settings.ts';

export interface PreviewState {
  preferences: Record<string, string | boolean>;
  activeAccounts: Record<string, string>;
  viewedAccounts: Record<string, string>;
}

const rows = settingGroups.flatMap((group) => group.rows);

export function initialPreviewState(): PreviewState {
  const preferences: PreviewState['preferences'] = {};
  for (const { id, control } of rows) {
    if (control.kind === 'toggle') preferences[id] = control.on;
    if (control.kind === 'picker') preferences[id] = control.value;
  }
  return {
    preferences,
    activeAccounts: Object.fromEntries(accountFamilies.map((family) => [family.id, family.activeAccount])),
    viewedAccounts: Object.fromEntries(accountFamilies.map((family) => [family.id, family.activeAccount])),
  };
}

export function changePreference(state: PreviewState, id: string, value: unknown): PreviewState {
  const control = rows.find((row) => row.id === id)?.control;
  if (!control || control.kind === 'action'
    || (control.kind === 'toggle' && typeof value !== 'boolean')
    || (control.kind === 'picker' && (typeof value !== 'string' || !control.options.includes(value)))) {
    throw new Error(`Invalid preview setting: ${id}`);
  }
  return { ...state, preferences: { ...state.preferences, [id]: value as string | boolean } };
}

function account(family: string, id: string) {
  const profile = accountFamilies.find((entry) => entry.id === family)?.profiles.find((entry) => entry.id === id);
  if (!profile) throw new Error(`Unknown preview account: ${family}/${id}`);
  return profile;
}

/** 대시보드 선택은 표시만 변경. 터미널용 활성 계정은 유지. */
export function selectDashboardAccount(state: PreviewState, family: string, id: string): PreviewState {
  account(family, id);
  return { ...state, viewedAccounts: { ...state.viewedAccounts, [family]: id } };
}

/** Settings에서 확정한 전환은 활성 계정과 대시보드 선택을 함께 이동. */
export function activateAccount(state: PreviewState, family: string, id: string): PreviewState {
  if (account(family, id).status !== 'Ready') throw new Error('This account needs sign-in.');
  return { ...selectDashboardAccount(state, family, id), activeAccounts: { ...state.activeAccounts, [family]: id } };
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid preview preferences.');
  return value as Record<string, unknown>;
}

export function restorePreviewState(value: unknown): PreviewState {
  const stored = record(value);
  let state = initialPreviewState();
  for (const [id, preference] of Object.entries(record(stored.preferences))) {
    state = changePreference(state, id, preference);
  }
  for (const [family, id] of Object.entries(record(stored.activeAccounts))) {
    if (typeof id !== 'string') throw new Error('Invalid active preview account.');
    state = activateAccount(state, family, id);
  }
  for (const [family, id] of Object.entries(record(stored.viewedAccounts))) {
    if (typeof id !== 'string') throw new Error('Invalid selected preview account.');
    state = selectDashboardAccount(state, family, id);
  }
  return state;
}

export function previewTime(text: string, format: string | boolean, systemHour12: boolean): string {
  if (format !== '12-hour' && !(format === 'Auto' && systemHour12)) return text;
  return text.replace(/\b(\d{1,2}):(\d{2})\b/g, (_, hour: string, minute: string) => {
    const value = Number(hour);
    return `${value % 12 || 12}:${minute} ${value < 12 ? 'AM' : 'PM'}`;
  });
}
