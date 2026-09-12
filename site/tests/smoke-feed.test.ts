import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

test('deployment smoke requires both feeds to match the supplied deployment baseline', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'openusage-smoke-baseline-'));
  const appcast = `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>992</sparkle:version><sparkle:shortVersionString>0.99.2</sparkle:shortVersionString>
    <enclosure url="https://github.com/kimchanhyung98/openusage/releases/download/v0.99.2/OpenUsage.dmg" sparkle:edSignature="original-signature"/>
  </item></channel></rss>`;
  const pricing = '{"pricing":{"sample-model":{"input":1,"output":2}}}';
  writeFileSync(join(directory, 'appcast.xml'), appcast);
  writeFileSync(join(directory, 'pricing_supplement.json'), pricing);
  const routes = new Map([
    ['/', ['text/html', '<title>OpenUsage</title><meta property="og:image" content="https://example.test/og.png">']],
    ['/404.html', ['text/html', '<main data-page="404">Missing</main>']],
    ['/robots.txt', ['text/plain', 'Sitemap: https://example.test/sitemap.xml']],
    ['/sitemap.xml', ['application/xml', '<urlset/>']],
    ['/appcast.xml', ['application/xml', appcast]],
    ['/pricing_supplement.json', ['application/json', pricing]],
    ['/og.png', ['image/png', 'image-fixture']],
  ]);
  const server = createServer((request, response) => {
    const route = routes.get(request.url ?? '');
    response.writeHead(route ? 200 : 404, { 'Content-Type': route?.[0] ?? 'text/html' });
    response.end(route?.[1] ?? '<main data-page="404">Missing</main>');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  const script = fileURLToPath(new URL('../../script/site_smoke.sh', import.meta.url));
  const run = async (baseline?: string) => {
    const args = [script, `http://127.0.0.1:${address.port}`];
    if (baseline) args.push(baseline);
    const child = spawn('bash', args, { timeout: 10000 });
    let output = '';
    child.stdout.on('data', (data) => { output += data; });
    child.stderr.on('data', (data) => { output += data; });
    const [status] = await once(child, 'close');
    return { status, output };
  };
  try {
    await t.test('unchanged feeds pass', async () => {
      const result = await run(directory);
      assert.equal(result.status, 0, result.output);
    });
    await t.test('missing social preview metadata fails validation', async () => {
      const originalIndex = routes.get('/')!;
      routes.set('/', ['text/html', '<title>OpenUsage</title>']);
      try {
        const result = await run(directory);
        assert.equal(result.status, 1, result.output);
        assert.match(result.output, /FAIL og:image meta missing/);
      } finally { routes.set('/', originalIndex); }
    });
    await t.test('asset URLs are passed literally without shell pathname expansion', async () => {
      const assetPath = `${directory}/asset-*.txt`;
      writeFileSync(join(directory, 'asset-found.txt'), 'local file');
      const originalIndex = routes.get('/')!;
      routes.set('/', ['text/html', `${originalIndex[1]}<a href="${assetPath}">Asset</a>`]);
      routes.set(assetPath, ['text/plain', 'remote asset']);
      try {
        const result = await run(directory);
        assert.equal(result.status, 0, result.output);
        assert.ok(result.output.includes(`ok   asset ${assetPath}`), result.output);
      } finally {
        routes.set('/', originalIndex);
      }
    });
    await t.test('changed signatures and emptied pricing fail despite unchanged item count', async () => {
      routes.set('/appcast.xml', ['application/xml', appcast.replace('original-signature', 'invalid-signature')]);
      routes.set('/pricing_supplement.json', ['application/json', '{"pricing":{}}']);
      const result = await run(directory);
      assert.equal(result.status, 1, result.output);
      assert.match(result.output, /FAIL appcast.xml differs from deployment baseline/);
      assert.match(result.output, /FAIL pricing_supplement.json differs from deployment baseline/);
    });
    await t.test('a missing baseline cannot pass deployment validation', async () => {
      const result = await run();
      assert.equal(result.status, 1, result.output);
      assert.match(result.output, /FAIL deployment baseline/);
    });
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    rmSync(directory, { recursive: true, force: true });
  }
});

test('smoke selects stable builds with the same channel, version, and URL boundaries as the page', () => {
  const script = readFileSync(new URL('../../script/site_smoke.sh', import.meta.url), 'utf8');
  const python = script.match(/<<'PY' \|\| fail=1\n([\s\S]*?)\nPY/)?.[1];
  assert.ok(python);
  const directory = mkdtempSync(join(tmpdir(), 'openusage-smoke-feed-'));
  const prefix = 'https://github.com/kimchanhyung98/openusage/releases/download/';
  const item = (build: string, version: string, channel = '', suffix = `v${version}/OpenUsage.dmg`) => `<item>
    <sparkle:channel>${channel}</sparkle:channel><sparkle:version>${build}</sparkle:version>
    <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
    <enclosure url="${prefix}${suffix}"/>
  </item>`;
  const stable = item('992', '0.99.2');
  const invalid = [item('9999', '0.99.9', 'nightly'), item('9999', '0.99.9-rc.1'), item('9999.5', '0.99.9'), item('9999', '0.99.9', '', '../../../../other/repository')];
  try {
    const feed = join(directory, 'appcast.xml');
    writeFileSync(feed, `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${stable}${invalid.join('')}</channel></rss>`);
    const result = spawnSync('python3', ['-', feed, feed], { input: python, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /stable 1/);
    assert.match(result.stdout, /0\.99\.2 \(build 992\)/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
