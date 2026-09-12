import { tourCamera, tourGeometry } from '../data/tour';
import type { Tab } from '../data/copy';
import { initTourScroll } from './tour-scroll';

type Stage = Tab['id'];

function pause(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const cancel = (): void => {
      window.clearTimeout(timer);
      reject(new DOMException('Tour interrupted', 'AbortError'));
    };
    const timer = window.setTimeout(() => {
      signal.removeEventListener('abort', cancel);
      resolve();
    }, milliseconds);
    if (signal.aborted) cancel();
    else signal.addEventListener('abort', cancel, { once: true });
  });
}

export function initFeatureTour(): void {
  const section = document.querySelector<HTMLElement>('[data-feature-tour]');
  if (!section) return;
  const get = <T extends HTMLElement = HTMLElement>(selector: string): T => section.querySelector<T>(selector)!;
  const viewport = get('[data-tour-viewport]');
  const panel = get('#feature-stage');
  const camera = get('[data-tour-camera]');
  const mock = get('[data-tour-mock]');
  const cursor = get('[data-tour-cursor]');
  const sheet = get('[data-tour-sheet]');
  const terminal = get('[data-tour-terminal]');
  const announcement = get('[data-tour-announcement]');
  const tabs = Array.from(section.querySelectorAll<HTMLButtonElement>('[data-tour-tab]'));
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let zoomed = false;
  let selected: Stage = 'menu-bar';
  let running: AbortController | undefined;
  let durationMultiplier = 1;
  let hasStarted = false;
  const waitForStep = (milliseconds: number, signal: AbortSignal): Promise<void> => pause(milliseconds * durationMultiplier, signal);

  const setPhase = (phase: string): void => { section.dataset.tourPhase = phase; };
  const showCaption = (): void => { section.setAttribute('data-tour-caption-visible', ''); };
  const updateCamera = (): void => {
    if (!viewport.clientWidth || !viewport.clientHeight) return;
    const frame = tourCamera(viewport.clientWidth, viewport.clientHeight, zoomed);
    camera.style.setProperty('--camera-x', `${frame.x}px`);
    camera.style.setProperty('--camera-y', `${frame.y}px`);
    camera.style.setProperty('--camera-scale', String(frame.scale));
    section.dataset.tourReady = 'true';
  };
  const setZoom = (value: boolean): void => {
    zoomed = value;
    section.dataset.tourZoom = value ? 'focused' : 'overview';
    updateCamera();
  };
  const showScreen = (screen: 'dashboard' | 'settings'): void => {
    mock.dataset.screen = screen;
    mock.querySelectorAll<HTMLElement>('[data-scr]').forEach((el) => {
      el.hidden = el.dataset.scr !== screen;
      if (!el.hidden) el.querySelector<HTMLElement>('.am-body')!.scrollTop = 0;
    });
  };
  const showAccount = (added: boolean): void => {
    get('[data-tour-accounts-empty]').hidden = added;
    get('[data-tour-account]').hidden = !added;
  };
  const closeTransientViews = (): void => {
    sheet.hidden = true;
    get('.am-optmenu').hidden = true;
    get('[data-options]').setAttribute('aria-expanded', 'false');
    cursor.classList.remove('is-visible', 'is-clicking');
    delete section.dataset.tourHighlight;
    terminal.hidden = true;
  };
  const finish = (): void => {
    announcement.textContent = tabs.find((tab) => tab.dataset.tourTab === selected)?.dataset.tourLabel ?? '';
  };
  const settle = (): void => {
    closeTransientViews();
    setZoom(true);
    showScreen(selected === 'accounts' ? 'settings' : 'dashboard');
    section.dataset.tourPopup = selected === 'menu-bar' || selected === 'integrations' ? 'closed' : 'open';
    showAccount(selected === 'accounts');
    terminal.hidden = selected !== 'integrations';
    setPhase(selected === 'accounts' ? 'account-added' : selected);
    showCaption();
    finish();
  };
  const clickAt = async (selector: string, signal: AbortSignal): Promise<void> => {
    const target = get(selector).getBoundingClientRect();
    const bounds = camera.getBoundingClientRect();
    const scale = bounds.width / tourGeometry.width;
    cursor.style.setProperty('--cursor-x', `${(target.left + target.width / 2 - bounds.left) / scale - 3}px`);
    cursor.style.setProperty('--cursor-y', `${(target.top + target.height / 2 - bounds.top) / scale - 2}px`);
    cursor.classList.add('is-visible');
    await waitForStep(450, signal);
    cursor.classList.add('is-clicking');
    await waitForStep(160, signal);
    cursor.classList.remove('is-clicking');
  };
  const focusCamera = async (signal: AbortSignal): Promise<void> => {
    if (zoomed) return;
    setZoom(true);
    await waitForStep(850, signal);
  };
  const openDashboard = async (signal: AbortSignal): Promise<void> => {
    await focusCamera(signal);
    showCaption();
    const alreadyOpen = section.dataset.tourPopup === 'open' && mock.dataset.screen === 'dashboard';
    showScreen('dashboard');
    if (alreadyOpen) return;
    section.dataset.tourPopup = 'closed';
    setPhase('opening-dashboard');
    await clickAt('[data-tour-status]', signal);
    section.dataset.tourPopup = 'open';
    await waitForStep(260, signal);
    cursor.classList.remove('is-visible');
  };

  const animate = async (stage: Stage, signal: AbortSignal): Promise<void> => {
    closeTransientViews();
    if (stage === 'menu-bar') {
      section.dataset.tourPopup = 'closed';
      setZoom(false);
      setPhase('overview');
      await waitForStep(350, signal);
      setPhase('zooming');
      setZoom(true);
      await waitForStep(850, signal);
      setPhase('menu-bar');
      showCaption();
    } else if (stage === 'integrations') {
      await focusCamera(signal);
      showCaption();
      section.dataset.tourPopup = 'closed';
      terminal.hidden = false;
      setPhase('integrations');
    } else {
      await openDashboard(signal);
      if (stage === 'statistics') {
        setPhase('highlighting-statistics');
        // 같은 탭을 다시 눌러도 이전 하이라이트를 끝내고 처음부터 재생.
        void get('.am-spend-card').offsetWidth;
        section.dataset.tourHighlight = 'true';
        await waitForStep(1600, signal);
        delete section.dataset.tourHighlight;
        setPhase('statistics');
      } else if (stage === 'accounts') {
        showAccount(false);
        setPhase('opening-options');
        await clickAt('[data-options]', signal);
        get('.am-optmenu').hidden = false;
        get('[data-options]').setAttribute('aria-expanded', 'true');
        await waitForStep(220, signal);
        await clickAt('.am-optmenu [data-go="settings"]', signal);
        get('.am-optmenu').hidden = true;
        get('[data-options]').setAttribute('aria-expanded', 'false');
        showScreen('settings');
        setPhase('accounts-empty');
        await waitForStep(750, signal);
        await clickAt('[data-settings-group="accounts"] [aria-label="Add Account"]', signal);
        sheet.hidden = false;
        setPhase('add-account');
        await waitForStep(750, signal);
        await clickAt('[data-tour-add-confirm]', signal);
        await waitForStep(300, signal);
        sheet.hidden = true;
        showAccount(true);
        setPhase('account-added');
        cursor.classList.remove('is-visible');
      } else {
        setPhase('dashboard');
      }
    }
    finish();
  };

  const select = (button: HTMLButtonElement, focus = false): void => {
    running?.abort();
    hasStarted = true;
    section.removeAttribute('data-tour-caption-visible');
    selected = button.dataset.tourTab as Stage;
    section.querySelectorAll<HTMLElement>('[data-tour-description]').forEach((description) => {
      description.hidden = description.dataset.tourDescription !== selected;
    });
    durationMultiplier = selected === 'accounts' ? 2 : 1;
    section.style.setProperty('--tour-duration-multiplier', String(durationMultiplier));
    section.dataset.tourStage = selected;
    camera.setAttribute('aria-hidden', String(selected !== 'integrations'));
    panel.setAttribute('aria-labelledby', button.id);
    tabs.forEach((tab) => {
      tab.setAttribute('aria-selected', String(tab === button));
      tab.tabIndex = tab === button ? 0 : -1;
    });
    const tablist = get('[data-tour-tabs]');
    const tabBounds = button.getBoundingClientRect();
    const listBounds = tablist.getBoundingClientRect();
    if (tabBounds.left < listBounds.left + 4) tablist.scrollLeft += tabBounds.left - listBounds.left - 4;
    else if (tabBounds.right > listBounds.right - 4) tablist.scrollLeft += tabBounds.right - listBounds.right + 4;
    if (focus) button.focus({ preventScroll: true });
    if (reducedMotion.matches) { settle(); return; }
    const controller = new AbortController();
    running = controller;
    void animate(selected, controller.signal).catch((error: unknown) => {
      if (error instanceof DOMException && error.name === 'AbortError') return;
      console.error('OpenUsage feature preview failed', error);
      section.dataset.tourError = 'true';
      announcement.textContent = '미리보기를 불러오지 못했습니다. 새로고침해 주세요.';
    }).finally(() => { if (running === controller) running = undefined; });
  };

  tabs.forEach((tab) => tab.addEventListener('click', () => select(tab)));
  initTourScroll(section, tabs.length, () => tabs.findIndex((tab) => tab.dataset.tourTab === selected), (index, focus) => select(tabs[index], focus));
  get('[data-tour-tabs]').addEventListener('keydown', (event) => {
    const index = tabs.indexOf(document.activeElement as HTMLButtonElement);
    if (index < 0) return;
    const next: Record<string, number> = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: tabs.length - 1 };
    if (!(event.key in next)) return;
    event.preventDefault();
    select(tabs[(next[event.key] + tabs.length) % tabs.length], true);
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && running) { running.abort(); settle(); }
  });
  reducedMotion.addEventListener('change', () => {
    if (reducedMotion.matches && running) { running.abort(); settle(); }
  });
  new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting && entry.intersectionRatio >= 0.55 && !hasStarted) {
      select(tabs[0]);
      return;
    }
    if (!entry.isIntersecting && running) { running.abort(); settle(); }
  }, { threshold: [0, 0.55] }).observe(section);
  new ResizeObserver(() => {
    camera.classList.add('is-resizing');
    updateCamera();
    requestAnimationFrame(() => camera.classList.remove('is-resizing'));
  }).observe(viewport);
  updateCamera();
}
