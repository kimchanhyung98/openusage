// 랜딩 페이지 런타임. 외부 요청은 같은 출처 /appcast.xml 하나뿐.
// 실패·차단 시 정적 링크(releases/latest)와 표시 상태를 그대로 유지.
import { initPopoverNav } from './nav';
import { setPreviewPreference } from './settings';
import { initFeatureTour } from './tour';
import { initMenus, openMenu, closeMenu } from './menus';

const SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
const DOWNLOAD_PREFIX = 'https://github.com/kimchanhyung98/openusage/releases/download/';

// hero 단어 리빌. 인라인 style 속성은 CSP가 막으므로 CSSOM으로 delay 변수 부여.
function initHero(): void {
  document.querySelectorAll<HTMLElement>('.hero .device').forEach((device) => {
    const mock = device.querySelector<HTMLElement>('[data-mock]');
    if (!mock) return;
    // 원본 배치를 유지하며 가시 폭에 맞춰 축소. 화면 전환 중 높이도 같은 배율로 반영.
    const fit = () => {
      const scale = Math.min(1, device.clientWidth / mock.offsetWidth);
      mock.style.setProperty('--hero-scale', String(scale));
      const height = scale < 1 ? `${mock.getBoundingClientRect().height}px` : '';
      if (device.style.height !== height) device.style.height = height;
    };
    const observer = new ResizeObserver(() => requestAnimationFrame(fit));
    observer.observe(device);
    observer.observe(mock);
    fit();
  });
  document.querySelectorAll<HTMLElement>('[data-words] .w').forEach((w) => {
    w.style.setProperty('--i', w.dataset.i ?? '0');
  });
  requestAnimationFrame(() => {
    document.querySelectorAll('[data-words]').forEach((el) => el.classList.add('is-in'));
  });
}

function initReveal(): void {
  const els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window)) {
    els.forEach((el) => el.classList.add('is-in'));
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add('is-in');
          io.unobserve(e.target);
        }
      }
    },
    { threshold: 0.15, rootMargin: '0px 0px -10% 0px' },
  );
  els.forEach((el) => io.observe(el));
}

function initNav(): void {
  const nav = document.querySelector('[data-nav]');
  const sentinel = document.querySelector('[data-nav-sentinel]');
  if (!nav || !sentinel) return;
  new IntersectionObserver(([entry]) => {
    nav.classList.toggle('is-scrolled', !entry.isIntersecting);
  }).observe(sentinel);
}

// 앱 재현 그래픽의 상호작용. 앱의 실제 동작만 옮김.
// - 헤드라인 클릭 → meterStyle(used/left) 전역 전환. 막대가 반전되고 pace 눈금이 미러링됨. 색은 그대로.
// - 리셋 라벨 클릭 → resetDisplayMode(Exact Time/Countdown) 전역 전환.
// - caret 클릭 → 그 카드만 On Demand 행과 quick links를 펼침.
// - Total Spend 기간·지표 → 미리 그려 둔 상태 중 하나를 보임.
// - Customize 토글 → 그 행만 흐려짐.
// 두 전역 상태는 앱이 UserDefaults에 남기므로 여기서도 localStorage에 남김.
function initAppMock(): void {
  const roots = document.querySelectorAll<HTMLElement>('[data-mock]');
  if (!roots.length) return;

  document.addEventListener('click', (event) => {
    const target = event.target as Element | null;
    if (!target || !target.closest) return;

    const headline = target.closest<HTMLElement>('[data-toggle-meter]');
    if (headline) {
      const root = headline.closest<HTMLElement>('[data-mock]');
      const next = root?.dataset.mode === 'left' ? 'used' : 'left';
      setPreviewPreference('showUsageAs', next === 'left' ? 'Left' : 'Used');
      return;
    }

    const reset = target.closest<HTMLElement>('[data-toggle-reset]');
    if (reset) {
      const root = reset.closest<HTMLElement>('[data-mock]');
      const next = root?.dataset.reset === 'relative' ? 'absolute' : 'relative';
      setPreviewPreference('resetTimes', next === 'relative' ? 'Countdown' : 'Exact Time');
      return;
    }

    const caret = target.closest<HTMLButtonElement>('[data-expand]');
    if (caret) {
      const open = caret.getAttribute('aria-expanded') === 'true';
      caret.setAttribute('aria-expanded', String(!open));
      const panel = document.getElementById(caret.getAttribute('aria-controls') ?? '');
      if (panel) panel.hidden = open;
      return;
    }

    const period = target.closest<HTMLButtonElement>('[data-period]');
    if (period) {
      selectSpend(period, 'period');
      return;
    }

    const metric = target.closest<HTMLButtonElement>('[data-spend-metric]');
    if (metric) {
      const trigger = metric.closest('.am-spend-card')?.querySelector<HTMLButtonElement>('[data-metric-btn]');
      selectSpend(metric, 'metric');
      closeMetricMenus();
      trigger?.focus({ preventScroll: true });
      return;
    }

    const menuButton = target.closest<HTMLButtonElement>('[data-metric-btn]');
    if (menuButton) {
      const open = menuButton.getAttribute('aria-expanded') === 'true';
      closeMetricMenus();
      if (!open) openMetricMenu(menuButton);
      return;
    }

    closeMetricMenus();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeMetricMenus();
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    const period = event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-period]') : null;
    if (!period) return;
    const direction = ['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : ['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 0;
    if (!direction) return;
    event.preventDefault();
    const options = Array.from(period.closest('[role="radiogroup"]')!.querySelectorAll<HTMLButtonElement>('[data-period]'));
    const next = options[(options.indexOf(period) + direction + options.length) % options.length];
    selectSpend(next, 'period');
    next.focus({ preventScroll: true });
  });
}

// 카드가 여럿이라 document 전역에서 하나만 집으면 다른 카드의 메뉴가 열림.
function openMetricMenu(button: HTMLButtonElement): void {
  const list = button.closest('.am-spend-card')?.querySelector<HTMLElement>('.am-menu');
  if (!list) return;
  openMenu(list, button);
}

function closeMetricMenus(): void {
  document.querySelectorAll<HTMLElement>('.am-spend-card .am-menu').forEach((list) => {
    closeMenu(list);
  });
  document.querySelectorAll<HTMLElement>('[data-metric-btn]').forEach((button) => {
    button.setAttribute('aria-expanded', 'false');
  });
}

// 기간·지표 선택을 반영. 상태 조합은 빌드 시 전부 그려 두었으므로 보이기만 바꿈.
function selectSpend(clicked: HTMLButtonElement, kind: 'period' | 'metric'): void {
  const card = clicked.closest<HTMLElement>('.am-spend-card');
  if (!card) return;

  if (kind === 'period') {
    card.querySelectorAll<HTMLElement>('[data-period]').forEach((b) => {
      b.setAttribute('aria-checked', String(b === clicked));
      b.tabIndex = b === clicked ? 0 : -1;
    });
  } else {
    const id = clicked.dataset.spendMetric ?? '';
    card.querySelectorAll<HTMLElement>('.am-menu [role="menuitemradio"]').forEach((option) => {
      option.setAttribute('aria-checked', String(option === clicked));
    });
    card.querySelectorAll<HTMLElement>('[data-metric-label]').forEach((label) => {
      label.hidden = label.dataset.metricLabel !== id;
    });
  }

  const period = card.querySelector<HTMLElement>('[data-period][aria-checked="true"]')?.dataset.period;
  const metric = card.querySelector<HTMLElement>('.am-menu [aria-checked="true"][data-spend-metric]')?.dataset.spendMetric;
  if (!period || !metric) return;
  card.querySelectorAll<HTMLElement>('[data-state]').forEach((state) => {
    state.hidden = state.dataset.state !== `${period}:${metric}`;
  });
}

interface FeedItem {
  channel: string;
  build: number;
  short: string;
  url: string;
  pub: number;
}

// 같은 출처 appcast에서 stable 최신 item을 골라 다운로드 링크·버전을 승격.
// 규칙: channel 없는 정식 버전 + sparkle:version 최대, 동률이면 pubDate 늦은 것.
async function initDownload(): Promise<void> {
  const links = document.querySelectorAll<HTMLAnchorElement>('[data-download]');
  const meta = document.querySelector<HTMLElement>('[data-download-meta]');
  if (!links.length) return;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 5000);
  try {
    const res = await fetch('/appcast.xml', { signal: ctrl.signal });
    if (!res.ok) throw new Error(`Appcast returned HTTP ${res.status}`);
    const doc = new DOMParser().parseFromString(await res.text(), 'application/xml');
    if (doc.querySelector('parsererror')) throw new Error('Appcast contains invalid XML');
    const items: FeedItem[] = Array.from(doc.getElementsByTagName('item'))
      .map((it) => {
        const ns = (name: string): string => it.getElementsByTagNameNS(SPARKLE_NS, name)[0]?.textContent?.trim() ?? '';
        const enclosure = it.querySelector('enclosure');
        return {
          channel: ns('channel'),
          build: Number(ns('version')),
          short: ns('shortVersionString'),
          url: enclosure?.getAttribute('url') ?? '',
          pub: Date.parse(it.querySelector('pubDate')?.textContent ?? '') || 0,
        };
      })
      .filter((i) => i.channel === '' && /^\d+\.\d+\.\d+$/.test(i.short)
        && Number.isSafeInteger(i.build) && i.build > 0
        && i.url.startsWith(DOWNLOAD_PREFIX) && new URL(i.url).href.startsWith(DOWNLOAD_PREFIX));
    if (!items.length) throw new Error('Appcast contains no valid stable release');
    const latest = items.reduce((a, b) => (b.build > a.build || (b.build === a.build && b.pub > a.pub) ? b : a));
    links.forEach((a) => {
      a.href = latest.url;
    });
    if (meta && latest.short) {
      meta.textContent = `v${latest.short}`;
      meta.hidden = false;
    }
  } catch (error) {
    console.warn('OpenUsage release metadata unavailable; keeping the release-page link', error);
  } finally {
    clearTimeout(timer);
  }
}

// 초기화 중 오류가 나면 .js를 떼어 JS 없는 렌더링(전부 표시)으로 되돌림.
try {
  document.documentElement.classList.add('js');
  // js-flag.js의 안전장치에 "런타임이 실제로 떴다"고 알림.
  document.documentElement.dataset.ready = '1';
  initHero();
  initReveal();
  initNav();
  initFeatureTour();
  initMenus();
  initAppMock();
  initPopoverNav();
} catch (error) {
  document.documentElement.classList.remove('js');
  delete document.documentElement.dataset.ready;
  throw error;
}
// 버전 fetch는 홈에서만(404 페이지는 정적 링크 유지).
if (document.body.dataset.page === 'home') void initDownload();
