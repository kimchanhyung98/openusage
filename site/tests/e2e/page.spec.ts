import { test, expect, openHome } from './fixtures';

test('home assets load locally with CSP, unique IDs, and no horizontal overflow', async ({ page, request }) => {
  const failed: string[] = [];
  page.on('response', (response) => { if (response.status() >= 400) failed.push(`${response.status()} ${response.url()}`); });
  await openHome(page);
  await expect(page.locator('meta[http-equiv="content-security-policy" i]')).toHaveAttribute('content', /default-src 'self'/);
  const documentState = await page.evaluate(() => {
    const ids = Array.from(document.querySelectorAll('[id]'), (element) => element.id);
    return {
      duplicates: ids.filter((id, index) => ids.indexOf(id) !== index),
      overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      assets: Array.from(document.querySelectorAll<HTMLScriptElement | HTMLLinkElement | HTMLImageElement>('script[src], link[rel="stylesheet"], link[rel="preload"], img[src]'), (element) => 'src' in element ? element.src : element.href),
    };
  });
  expect(documentState.duplicates).toEqual([]);
  expect(documentState.overflow).toBeLessThanOrEqual(1);
  for (const asset of new Set(documentState.assets)) {
    expect(new URL(asset).origin).toBe(new URL(page.url()).origin);
    expect((await request.get(asset)).ok(), asset).toBe(true);
  }
  expect(failed).toEqual([]);
  for (const width of [320, 720, 768]) {
    await page.setViewportSize({ width, height: 640 });
    await page.evaluate(() => document.fonts.ready);
    expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
    const heading = await page.locator('h1').evaluate((element) => {
      const range = document.createRange();
      range.selectNodeContents(element);
      return { text: range.getBoundingClientRect().right, container: element.getBoundingClientRect().right };
    });
    expect(heading.text, `heading at ${width}px`).toBeLessThanOrEqual(heading.container + 1);
    const navigation = await page.locator('.nav .inner').evaluate((element) => ({
      width: element.clientWidth,
      contentWidth: element.scrollWidth,
    }));
    expect(navigation.contentWidth).toBeLessThanOrEqual(navigation.width + 1);
  }
});

test('unknown routes return a noindex 404 with working home recovery', async ({ page }) => {
  const response = await page.goto('/this-page-does-not-exist');
  expect(response?.status()).toBe(404);
  await expect(page.locator('body')).toHaveAttribute('data-page', '404');
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', 'noindex');
  await expect(page.locator('link[rel="canonical"]')).toHaveCount(0);
  await page.locator('main a[href="/"]').click();
  await expect(page.locator('body')).toHaveAttribute('data-page', 'home');
  await expect(page.locator('html')).toHaveAttribute('data-scroll-ready', 'true');
});
