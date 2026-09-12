import assert from 'node:assert/strict';
import test from 'node:test';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const workflow = readFileSync(new URL('../../.github/workflows/publish-site.yml', import.meta.url), 'utf8');

function workflowStep(name: string) {
  const lines = workflow.split('\n');
  const start = lines.indexOf(`      - name: ${name}`);
  assert.notEqual(start, -1, `Missing workflow step: ${name}`);
  assert.equal(lines[start + 1], '        run: |');
  const body: string[] = [];
  for (const line of lines.slice(start + 2)) {
    if (line && !line.startsWith('          ')) break;
    body.push(line.slice(10));
  }
  return body.join('\n');
}

function publicationFixture() {
  const temp = mkdtempSync(join(tmpdir(), 'openusage-publication-test-'));
  const published = join(temp, 'published');
  const checkout = join(temp, 'checkout');
  mkdirSync(published);
  mkdirSync(join(checkout, 'script'), { recursive: true });
  copyFileSync(new URL('../../script/site_feed_snapshot.sh', import.meta.url), join(checkout, 'script/site_feed_snapshot.sh'));
  const env = { ...process.env, RUNNER_TEMP: temp, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
  function git(cwd: string, ...args: string[]) {
    const result = spawnSync('git', args, { cwd, env, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  }
  function commit() {
    git(published, 'add', '--all');
    git(published, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
      'commit', '--quiet', '-m', 'test: update publication fixture');
  }
  git(published, 'init', '--quiet', '--initial-branch=gh-pages');
  git(checkout, 'init', '--quiet', '--initial-branch=main');
  git(checkout, 'remote', 'add', 'origin', published);
  writeFileSync(join(published, 'appcast.xml'), '<rss><channel/></rss>\n');
  writeFileSync(join(published, 'pricing_supplement.json'), '{"pricing":{}}\n');
  writeFileSync(join(published, 'CNAME'), 'openusage.chanhyung.kim\n');
  commit();
  return {
    published, commit,
    run(name: string) {
      return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', workflowStep(name)], {
        cwd: checkout, env, encoding: 'utf8', timeout: 5000,
      });
    },
    cleanup() { rmSync(temp, { recursive: true, force: true }); },
  };
}

const snapshot = '게시된 피드 기준값 기록';
const verify = '게시 전후 피드 불변 확인';

test('피드 두 개와 도메인을 보존하는 사이트 갱신 허용', () => {
  const fixture = publicationFixture();
  try {
    const before = fixture.run(snapshot);
    assert.equal(before.status, 0, before.stderr);
    writeFileSync(join(fixture.published, 'index.html'), '<title>Landing page</title>');
    fixture.commit();
    const after = fixture.run(verify);
    assert.equal(after.status, 0, after.stderr);
  } finally { fixture.cleanup(); }
});

for (const file of ['appcast.xml', 'pricing_supplement.json', 'CNAME']) {
  test(`${file} 누락 시 게시 전 실패`, () => {
    const fixture = publicationFixture();
    try {
      rmSync(join(fixture.published, file));
      fixture.commit();
      const result = fixture.run(snapshot);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /missing or is not a file/);
    } finally { fixture.cleanup(); }
  });

  test(`게시된 ${file} 변경 시 실패`, () => {
    const fixture = publicationFixture();
    try {
      assert.equal(fixture.run(snapshot).status, 0);
      writeFileSync(join(fixture.published, file), file === 'CNAME' ? 'example.invalid\n' : 'changed\n');
      fixture.commit();
      const result = fixture.run(verify);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /Published feeds changed|CNAME does not match/);
    } finally { fixture.cleanup(); }
  });
}

test('도메인 불일치 시 게시 전 거부', () => {
  const fixture = publicationFixture();
  try {
    writeFileSync(join(fixture.published, 'CNAME'), 'example.invalid\n');
    fixture.commit();
    const result = fixture.run(snapshot);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CNAME does not match/);
  } finally { fixture.cleanup(); }
});

test('게시 액션이 제거하는 .github 경로가 있으면 게시 거부', () => {
  const fixture = publicationFixture();
  try {
    mkdirSync(join(fixture.published, '.github'));
    writeFileSync(join(fixture.published, '.github/keep.txt'), 'existing file');
    fixture.commit();
    const result = fixture.run(snapshot);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not contain .github/);
  } finally { fixture.cleanup(); }
});
