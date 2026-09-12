interface Rect { left: number; right: number; top: number; bottom: number }
interface Size { width: number; height: number }

export function menuPosition(anchor: Rect, menu: Size, viewport: Size, alignEnd: boolean, preferAbove: boolean): { left: number; top: number } {
  const margin = 8;
  const below = anchor.bottom + 4;
  const above = anchor.top - menu.height - 4;
  const fitsAbove = above >= margin;
  const fitsBelow = below + menu.height <= viewport.height - margin;
  const top = preferAbove ? (fitsAbove || !fitsBelow ? above : below) : (fitsBelow || !fitsAbove ? below : above);
  return {
    left: Math.max(margin, Math.min(alignEnd ? anchor.right - menu.width : anchor.left, viewport.width - menu.width - margin)),
    top: Math.max(margin, Math.min(top, viewport.height - menu.height - margin)),
  };
}

let active: { menu: HTMLElement; trigger: HTMLElement; openedAt: number } | undefined;

export function closeMenu(menu: HTMLElement): void {
  if (menu.matches(':popover-open')) menu.hidePopover();
  menu.hidden = true;
  if (active?.menu === menu) {
    active.trigger.setAttribute('aria-expanded', 'false');
    active = undefined;
  }
}

function closeActive(restoreFocus = false): void {
  if (!active) return;
  const { menu, trigger } = active;
  closeMenu(menu);
  if (restoreFocus) trigger.focus({ preventScroll: true });
}

/// DOM 소속은 유지하고 최상위 표시 레이어로 띄워 본문 스크롤과 모서리 경계에서 분리.
export function openMenu(menu: HTMLElement, trigger: HTMLElement): void {
  closeActive();
  menu.popover = 'manual';
  menu.hidden = false;
  menu.showPopover();
  const position = menuPosition(
    trigger.getBoundingClientRect(),
    menu.getBoundingClientRect(),
    { width: document.documentElement.clientWidth, height: window.innerHeight },
    !trigger.hasAttribute('data-metric-btn'),
    trigger.hasAttribute('data-options'),
  );
  menu.style.left = `${position.left}px`;
  menu.style.top = `${position.top}px`;
  trigger.setAttribute('aria-expanded', 'true');
  active = { menu, trigger, openedAt: performance.now() };
  (menu.querySelector<HTMLElement>('[aria-checked="true"]')
    ?? menu.querySelector<HTMLElement>('button[role^="menuitem"]'))?.focus({ preventScroll: true });
}

export function initMenus(): void {
  document.addEventListener('pointerdown', (event) => {
    const target = event.target as Node;
    if (active && !active.menu.contains(target) && !active.trigger.contains(target)) closeActive();
  });
  document.addEventListener('focusin', (event) => {
    const target = event.target as Node;
    if (active && !active.menu.contains(target) && !active.trigger.contains(target)) closeActive();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && active) {
      event.preventDefault();
      closeActive(true);
    }
  });
  document.addEventListener('scroll', (event) => {
    // 열기 전에 발생했지만 나중에 전달된 스크롤은 새 메뉴를 닫지 않음.
    if (active && event.timeStamp > active.openedAt && !active.menu.contains(event.target as Node)) closeActive(true);
  }, true);
  window.addEventListener('resize', () => closeActive(true));
}
