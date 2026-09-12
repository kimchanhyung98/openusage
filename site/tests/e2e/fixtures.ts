import { test as base, expect, type Page } from '@playwright/test';

export const downloadURL = 'https://github.com/kimchanhyung98/openusage/releases/download/v0.99.2/OpenUsage.dmg';
export const stableFeed = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
  <sparkle:version>992</sparkle:version><sparkle:shortVersionString>0.99.2</sparkle:shortVersionString>
  <pubDate>Fri, 11 Sep 2026 00:00:00 GMT</pubDate>
  <enclosure url="${downloadURL}" length="10485760" type="application/octet-stream"/>
</item></channel></rss>`;

export const test = base.extend<{ runtimeErrors: string[]; expectXMLParserCsp: boolean }>({
  expectXMLParserCsp: [false, { option: true }],
  runtimeErrors: [async ({ page, browserName, expectXMLParserCsp }, use) => {
    const errors: string[] = [];
    const cspErrors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', (message) => {
      if (message.type() === 'error' && /content security policy|refused to|violat.*directive/i.test(message.text())) cspErrors.push(message.text());
    });
    await page.route('**/appcast.xml', (route) => route.fulfill({ contentType: 'application/xml', body: stableFeed }));
    await use(errors);
    expect(errors, 'No runtime errors').toEqual([]);
    // Chromium의 XML parsererror 노드가 삽입하는 두 style만 잘못된 XML 검사에서 예상.
    const parserHashes = expectXMLParserCsp && browserName === 'chromium'
      ? ['ICa0DhwZQJsOd/Rn0N8H6FdQ71GfNL+op2zhAQ+Y4mM=', 'ZD0chCyBaNHl+4UwQHJIHGoYhKwMeyCXGgJTKW5/67E='] : [];
    expect(cspErrors, 'Only explicitly expected XML parser diagnostics').toEqual(parserHashes.map((hash) => expect.stringContaining(`sha256-${hash}`)));
  }, { auto: true }],
});

export { expect };

export async function openHome(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.locator('html')).toHaveAttribute('data-ready', '1');
  await expect(page.locator('html')).toHaveAttribute('data-scroll-ready', 'true');
}

export async function openSettings(page: Page): Promise<void> {
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Options', exact: true }).click();
  await app.getByRole('menuitem', { name: 'Settings', exact: true }).click();
  await expect(app).toHaveAttribute('data-screen', 'settings');
}

export async function chooseSetting(page: Page, label: string, value: string): Promise<void> {
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: label, exact: true }).click();
  await app.getByRole('menuitemradio', { name: value, exact: true }).click();
  await expect(app.getByRole('button', { name: label, exact: true })).toBeFocused();
}
