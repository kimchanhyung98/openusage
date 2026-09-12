import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

function assemblyFixture() {
  const temp = mkdtempSync(join(tmpdir(), 'openusage-assembly-test-'));
  const root = join(temp, 'checkout');
  const output = join(temp, 'output');
  const bin = join(temp, 'bin');
  const fixture = join(temp, 'fixture');
  for (const path of [join(root, 'script'), join(root, 'site/public'), bin, fixture]) mkdirSync(path, { recursive: true });
  copyFileSync(new URL('../../script/site_assemble.sh', import.meta.url), join(root, 'script/site_assemble.sh'));
  for (const file of ['index.html', '404.html', 'robots.txt', 'sitemap.xml', 'js-flag.js']) {
    writeFileSync(join(fixture, file), file.endsWith('.html') ? '<!doctype html><title>Site</title>__BUILD__' : '__DATE__');
  }
  const builder = '#!/bin/sh\nif [ "${SITE_ASSEMBLY_FAIL:-0}" = 1 ]; then exit 42; fi\nif [ "$1" = ci ]; then exit 0; fi\nmkdir -p dist\ncp -R "$SITE_ASSEMBLY_FIXTURE/." dist/\n';
  for (const name of ['npm', 'npx']) writeFileSync(join(bin, name), builder, { mode: 0o755 });
  return {
    root, output, fixture,
    run(out = output, fail = false) {
      return spawnSync('bash', [join(root, 'script/site_assemble.sh'), out, 'test-build'], {
        cwd: root,
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, SITE_ASSEMBLY_FIXTURE: fixture, SITE_ASSEMBLY_FAIL: fail ? '1' : '0', WITH_FEED: '0' },
        encoding: 'utf8', timeout: 5000,
      });
    },
    cleanup() { rmSync(temp, { recursive: true, force: true }); },
  };
}

test('assembly preserves the last successful preview when the next build fails', () => {
  const fixture = assemblyFixture();
  try {
    const first = fixture.run();
    assert.equal(first.status, 0, first.stderr || first.stdout);
    const previous = readFileSync(join(fixture.output, 'index.html'), 'utf8');
    const failed = fixture.run(fixture.output, true);
    assert.notEqual(failed.status, 0);
    assert.equal(readFileSync(join(fixture.output, 'index.html'), 'utf8'), previous);
  } finally { fixture.cleanup(); }
});

test('assembly preserves the previous preview when output validation fails', () => {
  const fixture = assemblyFixture();
  try {
    assert.equal(fixture.run().status, 0);
    const previous = readFileSync(join(fixture.output, 'index.html'), 'utf8');
    writeFileSync(join(fixture.fixture, 'index.html'), '<title>Homebrew</title>');
    assert.notEqual(fixture.run().status, 0);
    assert.equal(readFileSync(join(fixture.output, 'index.html'), 'utf8'), previous);
  } finally { fixture.cleanup(); }
});

test('assembly refuses to replace an unrelated nonempty directory', () => {
  const fixture = assemblyFixture();
  try {
    mkdirSync(fixture.output);
    writeFileSync(join(fixture.output, 'keep.txt'), 'existing work');
    const result = fixture.run();
    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(join(fixture.output, 'keep.txt'), 'utf8'), 'existing work');
  } finally { fixture.cleanup(); }
});

test('assembly refuses source directories inside the checkout', () => {
  const fixture = assemblyFixture();
  try {
    const source = join(fixture.root, 'site');
    writeFileSync(join(source, 'public/keep.txt'), 'source');
    assert.notEqual(fixture.run(source).status, 0);
    assert.equal(readFileSync(join(source, 'public/keep.txt'), 'utf8'), 'source');
  } finally { fixture.cleanup(); }
});

test('assembly replaces only marked output and resolves build placeholders', () => {
  const fixture = assemblyFixture();
  try {
    assert.equal(fixture.run().status, 0);
    assert.equal(readFileSync(join(fixture.output, '.openusage-site-output'), 'utf8'), '1\n');
    assert.match(readFileSync(join(fixture.output, 'index.html'), 'utf8'), /test-build/);
    writeFileSync(join(fixture.fixture, 'index.html'), '<title>Updated</title>__BUILD__');
    assert.equal(fixture.run().status, 0);
    assert.equal(readFileSync(join(fixture.output, 'index.html'), 'utf8'), '<title>Updated</title>test-build');
  } finally { fixture.cleanup(); }
});

test('assembly rejects feed collisions while preserving the previous output', () => {
  const fixture = assemblyFixture();
  try {
    assert.equal(fixture.run().status, 0);
    const previous = readFileSync(join(fixture.output, 'index.html'), 'utf8');
    writeFileSync(join(fixture.root, 'site/public/appcast.xml'), '<rss/>');
    assert.notEqual(fixture.run().status, 0);
    assert.equal(readFileSync(join(fixture.output, 'index.html'), 'utf8'), previous);
  } finally { fixture.cleanup(); }
});

for (const name of ['appcast.xml', 'copy.bak']) {
  test(`assembly rejects many ${name} output paths without losing the previous preview`, () => {
    const fixture = assemblyFixture();
    try {
      assert.equal(fixture.run().status, 0);
      const previous = readFileSync(join(fixture.output, 'index.html'), 'utf8');
      for (let index = 0; index < 1000; index++) {
        const directory = join(fixture.fixture, `${'nested-'.repeat(20)}${index}`);
        mkdirSync(directory);
        writeFileSync(join(directory, name), 'invalid build output');
      }
      const result = fixture.run();
      assert.notEqual(result.status, 0, result.stdout);
      assert.match(result.stderr, /must not be produced|backup files/);
      assert.equal(readFileSync(join(fixture.output, 'index.html'), 'utf8'), previous);
    } finally { fixture.cleanup(); }
  });
}

test('assembly allows native provider sign-in copy while still rejecting site endorsement claims', () => {
  const fixture = assemblyFixture();
  try {
    const copy = '<title>Site</title><p>Otherwise the official Claude sign-in opens in your browser.</p>';
    writeFileSync(join(fixture.fixture, 'index.html'), copy);
    const first = fixture.run();
    assert.equal(first.status, 0, first.stderr || first.stdout);
    writeFileSync(join(fixture.fixture, 'index.html'), '<title>The official OpenUsage site</title>');
    assert.notEqual(fixture.run().status, 0);
    assert.equal(readFileSync(join(fixture.output, 'index.html'), 'utf8'), copy);
  } finally { fixture.cleanup(); }
});
