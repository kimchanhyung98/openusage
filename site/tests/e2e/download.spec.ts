import { test, expect, openHome, stableFeed, downloadURL } from './fixtures';

test('download links select the latest stable release and exclude other channels', async ({ page }) => {
  const feed = stableFeed.replace('</channel>', `<item>
    <sparkle:channel>nightly</sparkle:channel><sparkle:version>9999</sparkle:version>
    <sparkle:shortVersionString>0.99.9</sparkle:shortVersionString>
    <enclosure url="https://github.com/kimchanhyung98/openusage/releases/download/nightly/OpenUsage.dmg" length="1048576"/>
  </item></channel>`);
  await page.route('**/appcast.xml', (route) => route.fulfill({ contentType: 'application/xml', body: feed }));
  await openHome(page);
  await expect(page.locator('[data-download-meta]')).toBeVisible();
  await expect(page.locator('#install [data-download] [data-download-meta]')).toHaveCount(1);
  await expect(page.locator('#install [data-download] .download-label')).toHaveText('Download');
  for (const link of await page.locator('[data-download]').all()) await expect(link).toHaveAttribute('href', downloadURL);
  await expect(page.locator('[data-download-meta]')).toHaveText('v0.99.2');
});

for (const invalid of [
  { label: 'a fractional build', build: '9999.5', version: '0.99.9', url: downloadURL.replace('0.99.2', '0.99.9') },
  { label: 'a prerelease without a channel', build: '9999', version: '0.99.9-rc.1', url: downloadURL.replace('0.99.2', '0.99.9-rc.1') },
  { label: 'a URL escaping the release directory', build: '9999', version: '0.99.9', url: downloadURL.replace('v0.99.2/OpenUsage.dmg', '../../../../other/repository') },
]) {
  test(`download links ignore ${invalid.label}`, async ({ page }) => {
    const feed = stableFeed.replace('</channel>', `<item>
      <sparkle:version>${invalid.build}</sparkle:version><sparkle:shortVersionString>${invalid.version}</sparkle:shortVersionString>
      <enclosure url="${invalid.url}" length="1048576"/>
    </item></channel>`);
    await page.route('**/appcast.xml', (route) => route.fulfill({ contentType: 'application/xml', body: feed }));
    await openHome(page);
    await expect(page.locator('[data-download-meta]')).toBeVisible();
    await expect(page.locator('[data-download]').first()).toHaveAttribute('href', downloadURL);
  });
}

for (const failure of ['http', 'xml', 'body-timeout'] as const) {
  test.describe(`unavailable feed: ${failure}`, () => {
    test.use({ expectXMLParserCsp: failure === 'xml' });
    test(`download keeps the release-page fallback after ${failure}`, async ({ page }) => {
      if (failure === 'body-timeout') {
        await page.clock.install();
        await page.addInitScript(() => {
          const original = window.fetch;
          window.fetch = (input, options) => {
            if (input !== '/appcast.xml') return original(input, options);
            return Promise.resolve(new Response(new ReadableStream({
              start(controller) {
                options?.signal?.addEventListener('abort', () => controller.error(options.signal?.reason), { once: true });
              },
            }), { headers: { 'Content-Type': 'application/xml' } }));
          };
        });
      } else {
        await page.route('**/appcast.xml', (route) => route.fulfill({ status: failure === 'http' ? 503 : 200, contentType: 'application/xml', body: '<broken' }));
      }
      const notice = page.waitForEvent('console', (message) => message.text().includes('OpenUsage release metadata unavailable'));
      await openHome(page);
      if (failure === 'body-timeout') await page.clock.fastForward(5001);
      await notice;
      for (const link of await page.locator('[data-download]').all()) {
        await expect(link).toHaveAttribute('href', 'https://github.com/kimchanhyung98/openusage/releases/latest');
      }
      await expect(page.locator('[data-download-meta]')).toBeHidden();
    });
  });
}
