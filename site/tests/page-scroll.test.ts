import assert from 'node:assert/strict';
import test from 'node:test';
import { initTourScroll } from '../src/scripts/tour-scroll.ts';

function pageHarness(firstHeight = 867) {
  let scrollY = 0;
  let selected = 0;
  const viewport = 941;
  const calls: Array<{ index: number; block: string; behavior: string }> = [];
  class Page {
    parentElement: Page | null = null;
    previousElementSibling: Page | null = null;
    nextElementSibling: Page | null = null;
    children: Page[] = [];
    overflowY = 'visible';
    scrollTop = 0;
    scrollHeight = 0;
    clientHeight = 0;
    isApp = false;
    index: number;
    top: number;
    height: number;
    constructor(index: number, top: number, height: number) {
      this.index = index;
      this.top = top;
      this.height = height;
    }
    getBoundingClientRect() { return { top: this.top - scrollY, bottom: this.top + this.height - scrollY }; }
    contains(target: unknown) {
      let node = target instanceof Page ? target : null;
      while (node) {
        if (node === this) return true;
        node = node.parentElement;
      }
      return false;
    }
    closest(selector: string): Page | null {
      let node: Page | null = this;
      while (node) {
        if (selector === '[data-mock]' && node.isApp) return node;
        node = node.parentElement;
      }
      return null;
    }
    scrollIntoView(options: { block: string; behavior: string }) {
      calls.push({ index: this.index, ...options });
      scrollY = options.block === 'end' ? this.top + this.height - viewport : this.top - 74;
    }
  }
  const pages = [firstHeight, 867, 867, 867].map((height, index, heights) =>
    new Page(index, 74 + heights.slice(0, index).reduce((sum, value) => sum + value, 0), height));
  const main = new Page(-1, 0, 0);
  main.children = pages.slice(0, 3);
  main.nextElementSibling = pages[3];
  pages.forEach((page, index) => {
    page.parentElement = main;
    page.previousElementSibling = pages[index - 1] ?? null;
    page.nextElementSibling = pages[index + 1] ?? null;
  });
  const events = new EventTarget();
  const originals = new Map<string, PropertyDescriptor | undefined>();
  const globals = {
    window: Object.assign(events, { innerHeight: viewport, scrollBy: ({ top }: { top: number }) => { scrollY += top; } }),
    document: { documentElement: { dataset: {} }, querySelectorAll: () => pages },
    Element: Page,
    HTMLElement: Page,
    getComputedStyle: (element: Page) => ({ scrollPaddingTop: '74px', overflowY: element.overflowY ?? 'visible' }),
  };
  for (const [key, value] of Object.entries(globals)) {
    originals.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, value });
  }
  initTourScroll(pages[2] as unknown as HTMLElement, 5, () => selected, (index) => { selected = index; });
  return {
    calls,
    selected: () => selected,
    setStage: (value: number) => { selected = value; },
    position: () => scrollY,
    setScroll: (value: number) => { scrollY = value; },
    wheel(delta: number, time: number, target?: Page) {
      const event = new Event('wheel', { cancelable: true });
      Object.defineProperties(event, {
        deltaY: { value: delta }, deltaX: { value: 0 }, deltaMode: { value: 0 }, timeStamp: { value: time },
      });
      if (target) Object.defineProperty(event, 'target', { value: target });
      events.dispatchEvent(event);
      return event.defaultPrevented;
    },
    key(time: number, repeat: boolean, target?: Page, key = 'ArrowDown') {
      const event = new Event('keydown', { cancelable: true });
      Object.defineProperties(event, { key: { value: key }, repeat: { value: repeat }, timeStamp: { value: time } });
      if (target) Object.defineProperty(event, 'target', { value: target });
      events.dispatchEvent(event);
      return event.defaultPrevented;
    },
    swipe(delta: number, time: number, target: Page) {
      for (const [type, y] of [['touchstart', 100], ['touchmove', 100 - delta]] as const) {
        const event = new Event(type, { cancelable: true });
        Object.defineProperties(event, {
          touches: { value: [{ clientX: 0, clientY: y }] }, timeStamp: { value: time }, target: { value: target },
        });
        events.dispatchEvent(event);
        if (type === 'touchmove') return event.defaultPrevented;
      }
    },
    appSurface() {
      const app = new Page(-1, 0, 0);
      app.parentElement = pages[0];
      app.isApp = true;
      return app;
    },
    innerScroll() {
      const inner = new Page(-1, 0, 0);
      inner.parentElement = this.appSurface();
      inner.overflowY = 'auto';
      inner.scrollHeight = 200;
      inner.clientHeight = 100;
      return inner;
    },
    restore() {
      for (const [key, descriptor] of originals) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor);
        else Reflect.deleteProperty(globalThis, key);
      }
    },
  };
}

test('small wheel input moves to the next page instead of snapping back to the same page', () => {
  const page = pageHarness();
  try {
    assert.equal(page.wheel(100, 0), true);
    assert.equal(page.calls.at(-1)?.index, 1);
    assert.equal(page.selected(), 0);
    page.wheel(-100, 100);
    assert.equal(page.calls.at(-1)?.index, 0);
  } finally { page.restore(); }
});

test('page navigation enters the feature section and keeps its stages before leaving', () => {
  const page = pageHarness();
  try {
    page.setScroll(867);
    page.wheel(100, 0);
    assert.equal(page.calls.at(-1)?.index, 2);
    assert.equal(page.selected(), 0);
    for (let time = 400; time <= 2000; time += 400) page.wheel(100, time);
    assert.equal(page.selected(), 4);
    assert.equal(page.calls.at(-1)?.index, 3);
  } finally { page.restore(); }
});

test('an oversized page scrolls through its content and leaves only at its boundary', () => {
  const page = pageHarness(1100);
  try {
    assert.equal(page.wheel(100, 0), true);
    assert.equal(page.position(), 100);
    assert.equal(page.calls.length, 0);
    page.wheel(500, 100);
    assert.equal(page.position(), 233);
    assert.equal(page.calls.length, 0);
    assert.equal(page.wheel(100, 400), true);
    assert.equal(page.calls.at(-1)?.index, 1);
    page.wheel(-100, 500);
    assert.deepEqual(page.calls.at(-1), { index: 0, block: 'end', behavior: 'instant' });
  } finally { page.restore(); }
});

test('inner app scrolling never turns the page after reaching either boundary', () => {
  const page = pageHarness();
  try {
    const inner = page.innerScroll();
    assert.equal(page.wheel(100, 0, inner), false);
    assert.equal(page.calls.length, 0);
    inner.scrollTop = 100;
    assert.equal(page.wheel(100, 400, inner), true);
    assert.equal(page.calls.length, 0);
    assert.equal(page.position(), 0);
    for (let time = 500; time <= 2500; time += 100) page.wheel(100, time, inner);
    assert.equal(page.calls.length, 0);
    inner.scrollTop = 0;
    assert.equal(page.wheel(-100, 2600, inner), true);
    assert.equal(page.position(), 0);
    assert.equal(page.calls.length, 0);
  } finally { page.restore(); }
});

test('scrolling on app chrome or an app without overflow cannot turn the page', () => {
  const page = pageHarness();
  try {
    const app = page.appSurface();
    assert.equal(page.wheel(100, 0, app), true);
    assert.equal(page.calls.length, 0);
    const inner = page.innerScroll();
    inner.scrollHeight = inner.clientHeight;
    assert.equal(page.wheel(100, 400, inner), true);
    assert.equal(page.calls.length, 0);
  } finally { page.restore(); }
});

test('scrolling outside the app still turns the page after an inner scroll', () => {
  const page = pageHarness();
  try {
    const inner = page.innerScroll();
    inner.scrollTop = 100;
    page.wheel(100, 0, inner);
    assert.equal(page.calls.length, 0);
    page.wheel(100, 400);
    assert.equal(page.calls.at(-1)?.index, 1);
  } finally { page.restore(); }
});

test('touch scrolling inside the app stays isolated at its boundaries', () => {
  const page = pageHarness();
  try {
    const inner = page.innerScroll();
    assert.equal(page.swipe(100, 0, inner), false);
    inner.scrollTop = 100;
    assert.equal(page.swipe(100, 400, inner), true);
    assert.equal(page.calls.length, 0);
    inner.scrollTop = 0;
    assert.equal(page.swipe(-100, 800, inner), true);
    assert.equal(page.calls.length, 0);
  } finally { page.restore(); }
});

test('navigation keys focused inside the app cannot turn the page', () => {
  const page = pageHarness();
  try {
    const inner = page.innerScroll();
    assert.equal(page.key(0, false, inner, 'PageDown'), false);
    inner.scrollTop = 100;
    for (let time = 400; time <= 2400; time += 100) {
      assert.equal(page.key(time, true, inner, 'PageDown'), true);
    }
    assert.equal(page.calls.length, 0);
    inner.scrollTop = 0;
    assert.equal(page.key(2800, false, inner, 'PageUp'), true);
    assert.equal(page.calls.length, 0);
    page.key(3200, false);
    assert.equal(page.calls.at(-1)?.index, 1);
  } finally { page.restore(); }
});

test('holding a navigation key progresses through the pages and every feature', () => {
  const page = pageHarness();
  try {
    for (let time = 0; time <= 2600; time += 50) page.key(time, time > 0);
    assert.equal(page.selected(), 4);
    assert.equal(page.calls.at(-1)?.index, 3);
  } finally { page.restore(); }
});

test('a few pixels of focus or rounding drift do not mistake the visible feature for the previous page', () => {
  const page = pageHarness();
  try {
    page.setScroll(2 * 867 - 3);
    page.setStage(3);
    page.wheel(-100, 0);
    assert.equal(page.selected(), 2);
    assert.equal(page.calls.length, 0);
  } finally { page.restore(); }
});
