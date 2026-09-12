// 팝오버 안 화면 이동과 Customize 상호작용.
// 화면 위치·Customize 조작은 팝오버별 상태. Settings와 계정 선택은 공통 데모 상태로 반영.
import { maxPins } from '../data/metrics';
import { initPreviewSettings, applySettingsToMock, choosePreviewSetting, handleSettingsClick, previewPreference } from './settings';
import { openMenu, closeMenu } from './menus';

const PILL_MS = 4500;
// 앱은 패널 높이를 min(내용, 화면 85%)로 자르고 넘치면 내부 스크롤(PanelHeightController.swift:139·152).
// 웹에서는 화면 높이를 알 필요가 없으니 그 성격만 가져와 상한을 고정 — 화면을 옮겨도 페이지가 크게 움직이지 않음.
const MAX_H = 560;

function root(el: Element): HTMLElement | null {
  return el.closest<HTMLElement>('[data-mock]');
}

/** 화면 교체. 앱은 밀어 넣지 않고 제자리 교체하므로 hidden만 바꿈. */
function go(mock: HTMLElement, screen: string): void {
  mock.dataset.screen = screen;
  mock.querySelectorAll<HTMLElement>('.am-scr').forEach((s) => {
    s.hidden = s.dataset.scr !== screen;
  });
  closeOptions(mock);
  const shown = mock.querySelector<HTMLElement>('.am-scr:not([hidden])');
  const body = shown?.querySelector<HTMLElement>('.am-body');
  if (body) body.scrollTop = 0;
  fitHeight(mock);
  shown?.querySelector<HTMLElement>('button, [tabindex="0"]')?.focus({ preventScroll: true });
}

// 팝오버 높이를 보이는 화면에 맞춰 px로 고정. CSS의 transition이 그 사이를 이어 줌.
// 높이를 auto로 두면 화면·행이 바뀔 때마다 아래 내용이 통째로 튐. 앱도 패널 높이를 애니메이션함.
function fitHeight(mock: HTMLElement): void {
  const shown = mock.querySelector<HTMLElement>('.am-scr:not([hidden])');
  if (!shown) return;
  let natural = 0;
  for (const part of Array.from(shown.children) as HTMLElement[]) {
    natural += part.classList.contains('am-body')
      ? Array.from(part.children).reduce((height, child) => height + (child as HTMLElement).offsetHeight, 0)
      : part.offsetHeight;
  }
  const height = `${Math.min(natural, MAX_H)}px`;
  if (mock.style.height !== height) mock.style.height = height;
}

// caret 펼침·지표 스위치·기간 전환처럼 화면 안에서 높이가 바뀌는 경우까지 한 번에 받음.
function watchHeights(): void {
  if (!('ResizeObserver' in window)) return;
  document.querySelectorAll<HTMLElement>('[data-mock]').forEach((mock) => {
    const io = new ResizeObserver(() => requestAnimationFrame(() => fitHeight(mock)));
    mock.querySelectorAll<HTMLElement>('.am-content, .am-screen, .am-topbar, .am-foot').forEach((s) => io.observe(s));
  });
}

function closePickers(mock: HTMLElement): void {
  mock.querySelectorAll<HTMLElement>('.am-pickmenu').forEach((m) => {
    closeMenu(m);
  });
  mock.querySelectorAll<HTMLElement>('[data-picker]').forEach((b) => {
    b.setAttribute('aria-expanded', 'false');
  });
}

function closeOptions(mock: HTMLElement): void {
  closePickers(mock);
  mock.querySelectorAll<HTMLElement>('.am-optmenu').forEach((m) => {
    closeMenu(m);
  });
  mock.querySelectorAll<HTMLElement>('[data-options]').forEach((b) => {
    b.setAttribute('aria-expanded', 'false');
  });
}

// 타이머는 팝오버마다 따로 — 하나로 두면 다른 팝오버에서 필을 띄울 때 앞의 필이 안 사라짐.
const pillTimers = new WeakMap<HTMLElement, number>();

function pill(mock: HTMLElement, text: string, notice = false): void {
  const el = mock.querySelector<HTMLElement>('[data-pill]');
  if (!el) return;
  el.textContent = text;
  el.classList.toggle('is-notice', notice);
  el.hidden = false;
  window.clearTimeout(pillTimers.get(mock) ?? 0);
  pillTimers.set(mock, window.setTimeout(() => {
    el.hidden = true;
  }, PILL_MS));
}

/**
 * Customize·Settings의 상태를 대시보드에 반영.
 * - provider를 끄면 그 카드가 사라짐, 켜면 나타남(자료 없는 provider는 값 없는 행으로).
 * - 지표를 끄면 그 행이 사라지고, 다 끄면 카드째 사라짐(displayGroups의 guard !widgets.isEmpty).
 * - Show Total Spend를 끄면 Total Spend 카드가 사라짐(DashboardContentView.swift:47).
 */
function syncCards(mock: HTMLElement): void {
  mock.querySelectorAll<HTMLElement>('.am-section[data-provider]').forEach((section) => {
    const provider = section.dataset.provider ?? '';
    const providerOn = mock.querySelector(`[data-provider-toggle="${provider}"]`)?.getAttribute('aria-checked') !== 'false';
    const rows = Array.from(section.querySelectorAll<HTMLElement>('[data-metric]'));
    for (const row of rows) {
      const id = row.dataset.metric ?? '';
      const sw = mock.querySelector(`[data-metric-toggle="${id}"]`);
      row.hidden = sw ? sw.getAttribute('aria-checked') === 'false' : false;
    }
    section.hidden = !providerOn || (rows.length > 0 && rows.every((r) => r.hidden));
  });

  const spend = mock.querySelector<HTMLElement>('.am-spend-card');
  if (spend) spend.hidden = previewPreference('showTotalSpend') === false;
  applySettingsToMock(mock);
}

function toggleSwitch(el: HTMLElement): boolean {
  const on = el.getAttribute('aria-checked') !== 'true';
  el.setAttribute('aria-checked', String(on));
  el.classList.toggle('is-on', on);
  return on;
}

/** 별은 provider당 2개까지. 넘으면 켜지지 않고 거절 알림만 뜸(LayoutStore.maxPinsPerProvider). */
function toggleStar(mock: HTMLElement, button: HTMLElement): void {
  const provider = button.dataset.provider ?? '';
  const on = button.getAttribute('aria-pressed') === 'true';
  if (!on) {
    const pinned = mock.querySelectorAll(`[data-star][data-provider="${provider}"][aria-pressed="true"]`).length;
    if (pinned >= maxPins) {
      pill(mock, `Up to ${maxPins} stars per provider`, true);
      return;
    }
  }
  button.setAttribute('aria-pressed', String(!on));
  button.classList.toggle('is-on', !on);
  pill(mock, on ? 'Removed from menu bar' : 'Starred for menu bar');
}

export function initPopoverNav(): void {
  document.addEventListener('click', (event) => {
    const target = event.target as Element | null;
    if (!target || !target.closest) return;
    const mock = root(target);
    if (mock && handleSettingsClick(target, mock)) return;

    const options = target.closest<HTMLElement>('[data-options]');
    if (options && mock) {
      const menu = mock.querySelector<HTMLElement>('.am-optmenu');
      const open = options.getAttribute('aria-expanded') === 'true';
      if (menu) {
        if (open) closeMenu(menu);
        else openMenu(menu, options);
      }
      return;
    }

    // 메뉴 항목·뒤로 가기·L1 chevron이 모두 같은 속성으로 목적지를 말함.
    const dest = target.closest<HTMLElement>('[data-go]');
    if (dest && mock) {
      go(mock, dest.dataset.go ?? 'dashboard');
      return;
    }

    const picker = target.closest<HTMLElement>('[data-picker]');
    if (picker && mock) {
      const menu = mock.querySelector<HTMLElement>(`#${CSS.escape(picker.getAttribute('aria-controls') ?? '')}`);
      const open = picker.getAttribute('aria-expanded') === 'true';
      closePickers(mock);
      if (!open && menu) {
        openMenu(menu, picker);
      }
      return;
    }

    const pick = target.closest<HTMLElement>('[data-pick]');
    if (pick && mock) {
      const id = pick.dataset.pick ?? '';
      choosePreviewSetting(mock, id, pick.dataset.value ?? '');
      closePickers(mock);
      Array.from(mock.querySelectorAll<HTMLElement>(`[data-picker="${id}"]`))
        .find((button) => !button.closest<HTMLElement>('.am-section')?.hidden
          && !button.closest<HTMLElement>('.am-scr')?.hidden)?.focus({ preventScroll: true });
      return;
    }

    const star = target.closest<HTMLElement>('[data-star]');
    if (star && mock) {
      toggleStar(mock, star);
      return;
    }

    const metric = target.closest<HTMLElement>('[data-metric-toggle]');
    if (metric && mock) {
      toggleSwitch(metric);
      syncCards(mock);
      return;
    }

    const provider = target.closest<HTMLElement>('[data-provider-toggle]');
    if (provider && mock) {
      const on = toggleSwitch(provider);
      provider.closest('.am-prow')?.classList.toggle('is-off', !on);
      syncCards(mock);
      return;
    }

    // 행 아무 데나 눌러도 열림 — 앱도 grip과 스위치만 빼고 전부 열기 타깃.
    const row = target.closest<HTMLElement>('.am-prow[data-open]');
    if (row && mock && !target.closest('.am-grip')) {
      go(mock, row.dataset.open ?? 'customize');
      return;
    }

    if (mock) closeOptions(mock);
    else document.querySelectorAll<HTMLElement>('[data-mock]').forEach(closeOptions);
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      document.querySelectorAll<HTMLElement>('[data-mock]').forEach((mock) => {
        const trigger = mock.querySelector<HTMLElement>('[aria-expanded="true"][aria-haspopup="menu"]');
        closeOptions(mock);
        trigger?.focus({ preventScroll: true });
      });
      return;
    }
    moveInMenu(event);
  });

  initPreviewSettings(() => document.querySelectorAll<HTMLElement>('[data-mock]').forEach(syncCards), pill);
  watchHeights();
}

// 열린 메뉴 안에서 위아래·Home/End 이동. Options 메뉴와 Total Spend 지표 메뉴가 같은 role="menu"라 함께 처리.
// aria-disabled 항목은 button이 아니라 초점을 받지 않으므로 자연히 건너뜀.
function moveInMenu(event: KeyboardEvent): void {
  const active = document.activeElement as HTMLElement | null;
  const menu = active?.closest<HTMLElement>('[role="menu"]');
  if (!menu || menu.hidden) return;
  const items = Array.from(menu.querySelectorAll<HTMLButtonElement>('button[role^="menuitem"]'));
  const i = items.indexOf(active as HTMLButtonElement);
  if (i < 0) return;
  const next: Record<string, number> = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: items.length - 1 };
  if (!(event.key in next)) return;
  event.preventDefault();
  items[(next[event.key] + items.length) % items.length].focus();
}
