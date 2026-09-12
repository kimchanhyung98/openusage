import { TourScrollGesture } from '../data/tour-scroll.ts';
import type { ScrollDecision } from '../data/tour-scroll.ts';

export function initTourScroll(section: HTMLElement, count: number, current: () => number, select: (index: number, focus: boolean) => void): void {
  const wheel = new TourScrollGesture();
  const touch = new TourScrollGesture();
  const keyboard = new TourScrollGesture();
  const pages = Array.from(document.querySelectorAll<HTMLElement>('#main > section, .footer--download'));
  let touchStart: { x: number; y: number; lastY: number } | undefined;

  const scrollInset = (): number => parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop) || 0;
  const pageAtPosition = (): HTMLElement | undefined => {
    const center = (scrollInset() + window.innerHeight) / 2;
    return pages.find((page) => {
      const bounds = page.getBoundingClientRect();
      return bounds.top <= center && bounds.bottom > center;
    });
  };
  const canScrollInside = (target: EventTarget | null, direction: number, page: HTMLElement): boolean => {
    let element = target instanceof Element ? target : null;
    while (element && element !== page && page.contains(element)) {
      if (/(auto|scroll)/.test(getComputedStyle(element).overflowY)) {
        const remaining = element.scrollHeight - element.clientHeight;
        if (remaining > 1 && (direction < 0 ? element.scrollTop > 1 : element.scrollTop < remaining - 1)) return true;
      }
      element = element.parentElement;
    }
    return false;
  };
  const apply = (decision: ScrollDecision, direction: number, event: Event, page: HTMLElement | undefined, focus = false): void => {
    if (decision === 'native') return;
    event.preventDefault();
    if (decision === 'previous' || decision === 'next') {
      select(current() + (decision === 'next' ? 1 : -1), focus);
    } else if (decision === 'leave' && page) {
      const adjacent = pages[pages.indexOf(page) + Math.sign(direction)];
      // 이동 애니메이션과 후속 휠의 취소 경쟁 없이 경계 확정. 긴 이전 화면은 내용 끝으로 진입.
      adjacent?.scrollIntoView({ block: direction < 0 ? 'end' : 'start', behavior: 'instant' });
    }
  };
  const move = (gesture: TourScrollGesture, delta: number, event: Event, heldTouch = false, focus = false): void => {
    const target = event.target instanceof Element ? event.target : null;
    const app = target?.closest<HTMLElement>('[data-mock]') ?? target?.closest<HTMLElement>('[data-tour-terminal]');
    if (app) {
      // 앱의 스크롤 경계·고정 영역에서도 페이지 전환으로 넘기지 않음.
      gesture.reset();
      if (!canScrollInside(target, delta, app)) event.preventDefault();
      return;
    }
    const page = pageAtPosition();
    const inTour = page === section;
    if (!page || canScrollInside(event.target, delta, page)) {
      gesture.move(delta, event.timeStamp, current(), count, false, heldTouch);
      return;
    }
    const bounds = page.getBoundingClientRect();
    const remaining = delta < 0 ? scrollInset() - bounds.top : bounds.bottom - window.innerHeight;
    if (remaining > 2) {
      gesture.move(delta, event.timeStamp, current(), count, false, heldTouch);
      event.preventDefault();
      window.scrollBy({ top: Math.sign(delta) * Math.min(Math.abs(delta), remaining), behavior: 'instant' });
      return;
    }
    apply(gesture.move(delta, event.timeStamp, inTour ? current() : 0, inTour ? count : 1, true, heldTouch), delta, event, page, focus);
  };

  window.addEventListener('wheel', (event) => {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.shiftKey || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1;
    const delta = event.deltaY * unit;
    move(wheel, delta, event);
  }, { passive: false });

  window.addEventListener('touchstart', (event) => {
    touch.reset();
    const point = event.touches[0];
    touchStart = event.touches.length === 1 ? { x: point.clientX, y: point.clientY, lastY: point.clientY } : undefined;
  }, { passive: true });
  window.addEventListener('touchmove', (event) => {
    if (!touchStart || event.touches.length !== 1 || event.defaultPrevented || !event.cancelable) return;
    const point = event.touches[0];
    if (Math.abs(point.clientX - touchStart.x) > Math.abs(point.clientY - touchStart.y)) return;
    const delta = touchStart.lastY - point.clientY;
    touchStart.lastY = point.clientY;
    move(touch, delta, event, true);
  }, { passive: false });
  window.addEventListener('touchend', () => { touchStart = undefined; }, { passive: true });
  window.addEventListener('touchcancel', () => { touchStart = undefined; }, { passive: true });

  window.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) return;
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest('input, textarea, select, [contenteditable="true"]')) return;
    const direction = ['PageDown', 'ArrowDown'].includes(event.key) ? 1 : ['PageUp', 'ArrowUp'].includes(event.key) ? -1 : 0;
    if (!direction) return;
    if (!event.repeat) keyboard.reset();
    const distance = event.key.startsWith('Page') ? window.innerHeight - scrollInset() : 40;
    move(keyboard, direction * distance, event, false, true);
  });
  document.documentElement.dataset.scrollReady = 'true';
}
