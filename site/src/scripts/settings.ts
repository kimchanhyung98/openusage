import { accountFamilies } from '../data/accounts';
import { initialPreviewState, changePreference, selectDashboardAccount, activateAccount, restorePreviewState, previewTime } from '../data/preview-state';

const STORAGE_KEY = 'openusage.site.preview.v1';
let state = initialPreviewState();
let render = (): void => {};
let notify = (_mock: HTMLElement, _message: string): void => {};
const pending = new WeakMap<HTMLElement, { family: string; id: string; button: HTMLButtonElement }>();

const appOnlyPreferences = new Set([
  'launchAtLogin', 'underTenPercent', 'healthyToClose', 'closeToRunningOut',
  'hideFromScreenShare', 'shareAnonymousUsage', 'updateAutomatically', 'betaUpdates', 'logLevel', 'iconStyle',
]);

function report(error: unknown, message: string): void {
  console.warn(message, error);
  const mock = document.querySelector<HTMLElement>('[data-mock]');
  if (mock) notify(mock, message);
}

function save(): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (error) {
    report(error, 'Preview changes could not be saved. They will last until you reload.');
  }
}

export function previewPreference(id: string): string | boolean {
  return state.preferences[id];
}

export function setPreviewPreference(id: string, value: string | boolean): void {
  state = changePreference(state, id, value);
  render();
  save();
}

export function choosePreviewSetting(mock: HTMLElement, id: string, value: string): void {
  if (id.startsWith('acct-')) {
    state = selectDashboardAccount(state, id.slice(5), value);
    render();
    save();
  } else {
    setPreviewPreference(id, value);
    if (appOnlyPreferences.has(id)) notify(mock, 'Preview value changed. Apply this setting in the Mac app.');
  }
}

function closeAccountDialog(mock: HTMLElement): void {
  const previous = pending.get(mock);
  mock.querySelector<HTMLDialogElement>('[data-account-dialog]')?.close();
  pending.delete(mock);
  previous?.button.focus();
}

export function handleSettingsClick(target: Element, mock: HTMLElement): boolean {
  const native = target.closest<HTMLElement>('[data-native-action]');
  if (native) {
    notify(mock, native.dataset.nativeAction ?? 'Open the Mac app to use this feature.');
    return true;
  }
  if (target.closest('[data-account-cancel]')) {
    closeAccountDialog(mock);
    return true;
  }
  if (target.closest('[data-account-confirm]')) {
    const selection = pending.get(mock);
    if (selection) {
      state = activateAccount(state, selection.family, selection.id);
      closeAccountDialog(mock);
      render();
      save();
    }
    return true;
  }
  const accountSwitch = target.closest<HTMLButtonElement>('[data-account-switch]');
  if (accountSwitch) {
    const family = accountSwitch.dataset.accountSwitch ?? '';
    const id = accountSwitch.dataset.accountId ?? '';
    if (state.activeAccounts[family] === id || accountSwitch.disabled) return true;
    const profile = accountFamilies.find((entry) => entry.id === family)?.profiles.find((entry) => entry.id === id);
    const dialog = mock.querySelector<HTMLDialogElement>('[data-account-dialog]');
    const message = dialog?.querySelector<HTMLElement>('[data-account-confirm-text]');
    if (profile && dialog && message) {
      pending.set(mock, { family, id, button: accountSwitch });
      message.textContent = `Use ${profile.name} in this demo? Your Mac’s sign-in will stay unchanged.`;
      dialog.showModal();
    }
    return true;
  }
  const toggle = target.closest<HTMLButtonElement>('button[data-setting]');
  if (toggle) {
    const id = toggle.dataset.setting ?? '';
    setPreviewPreference(id, !state.preferences[id]);
    if (appOnlyPreferences.has(id)) notify(mock, 'Preview value changed. Apply this setting in the Mac app.');
    return true;
  }
  return false;
}

/** 레이아웃 필터 이후 적용해 숨긴 provider·지표를 다시 노출하지 않음. */
export function applySettingsToMock(mock: HTMLElement): void {
  const preferences = state.preferences;
  const dark = preferences.theme === 'Dark' || (preferences.theme === 'System' && matchMedia('(prefers-color-scheme: dark)').matches);
  mock.dataset.theme = dark ? 'dark' : 'light';
  mock.dataset.density = preferences.density === 'Default' ? 'default' : 'compact';
  mock.dataset.mode = preferences.showUsageAs === 'Left' ? 'left' : 'used';
  mock.dataset.reset = preferences.resetTimes === 'Countdown' ? 'relative' : 'absolute';
  mock.dataset.pacing = String(preferences.alwaysShowPacing);
  mock.dataset.transparency = String(preferences.increaseTransparency
    && !matchMedia('(prefers-reduced-transparency: reduce), (prefers-contrast: more)').matches);
  const separate = preferences.usageCards === 'Separate Cards';
  mock.dataset.usageCards = separate ? 'separate' : 'single';

  mock.querySelectorAll<HTMLButtonElement>('[data-setting]').forEach((button) => {
    const on = preferences[button.dataset.setting ?? ''] === true;
    button.classList.toggle('is-on', on);
    button.setAttribute('aria-checked', String(on));
  });
  mock.querySelectorAll<HTMLElement>('[data-picker]').forEach((button) => {
    const id = button.dataset.picker ?? '';
    const family = accountFamilies.find((entry) => id === `acct-${entry.id}`);
    const value = family ? state.viewedAccounts[family.id] : preferences[id];
    const text = family ? family.profiles.find((profile) => profile.id === value)?.name : value;
    const label = button.querySelector('[data-picker-value]');
    if (label && text !== undefined) label.textContent = String(text);
    mock.querySelectorAll<HTMLElement>(`[data-pick="${id}"]`).forEach((option) => {
      option.setAttribute('aria-checked', String(option.dataset.value === value));
    });
  });
  mock.querySelectorAll<HTMLElement>('[data-account-switch]').forEach((button) => {
    const on = state.activeAccounts[button.dataset.accountSwitch ?? ''] === button.dataset.accountId;
    button.classList.toggle('is-on', on);
    button.setAttribute('aria-checked', String(on));
  });
  mock.querySelectorAll<HTMLElement>('.am-section[data-account-id]').forEach((section) => {
    const family = section.dataset.provider ?? '';
    const id = section.dataset.accountId;
    section.hidden ||= !separate && state.viewedAccounts[family] !== id;
    section.dataset.inactiveAccount = String(state.activeAccounts[family] !== id);
    const title = section.querySelector<HTMLElement>('[data-account-title]');
    if (title) title.textContent = (separate ? title.dataset.separateTitle : title.dataset.familyTitle) ?? '';
    const selector = section.querySelector<HTMLElement>('.am-acctwrap');
    if (selector) selector.hidden = separate;
  });
  const hour12 = new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions().hour12 === true;
  mock.querySelectorAll<HTMLElement>('[data-preview-time]').forEach((element) => {
    element.textContent = previewTime(element.dataset.previewTime ?? '', preferences.timeFormat, hour12);
  });
  const iCloud = mock.querySelector<HTMLElement>('[data-icloud-preview]');
  if (iCloud) iCloud.hidden = !preferences.syncAcrossMacs;
  const permission = mock.querySelector<HTMLElement>('[data-notification-permission]');
  if (permission) permission.hidden = !['underTenPercent', 'healthyToClose', 'closeToRunningOut'].some((id) => preferences[id]);
}

export function initPreviewSettings(refresh: () => void, showNotice: typeof notify): void {
  render = refresh;
  notify = showNotice;
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) state = restorePreviewState(JSON.parse(raw));
    else {
      const oldMode = localStorage.getItem('openusage.site.meterStyle');
      const oldReset = localStorage.getItem('openusage.site.resetDisplayMode');
      if (oldMode === 'left') state = changePreference(state, 'showUsageAs', 'Left');
      if (oldReset === 'relative') state = changePreference(state, 'resetTimes', 'Countdown');
    }
  } catch (error) {
    report(error, 'Saved preview settings could not be loaded. This page is using the demo defaults.');
  }
  document.querySelectorAll<HTMLDialogElement>('[data-account-dialog]').forEach((dialog) => {
    dialog.addEventListener('cancel', (event) => {
      event.preventDefault();
      const mock = dialog.closest<HTMLElement>('[data-mock]');
      if (mock) closeAccountDialog(mock);
    });
  });
  for (const query of ['(prefers-color-scheme: dark)', '(prefers-reduced-transparency: reduce)', '(prefers-contrast: more)']) {
    matchMedia(query).addEventListener('change', render);
  }
  render();
}
