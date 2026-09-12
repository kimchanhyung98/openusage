import assert from 'node:assert/strict';
import test from 'node:test';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

function workflowStep(name: string, file = 'publish-site.yml') {
  const workflow = readFileSync(new URL(`../../.github/workflows/${file}`, import.meta.url), 'utf8');
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
    return result.stdout.trim();
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
    temp, published, checkout, commit, git,
    run(name: string, file = 'publish-site.yml', extraEnv: NodeJS.ProcessEnv = {}) {
      return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', workflowStep(name, file)], {
        cwd: checkout, env: { ...env, ...extraEnv }, encoding: 'utf8', timeout: 5000,
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
    assert.equal(readFileSync(join(fixture.temp, 'revision.txt'), 'utf8').trim(),
      fixture.git(fixture.published, 'rev-parse', 'HEAD'));
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
      assert.match(result.stderr, /missing or is not a regular file/);
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
      assert.equal(existsSync(join(fixture.temp, 'revision.txt')), false);
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

for (const file of ['appcast.xml', 'pricing_supplement.json', 'CNAME']) {
  test(`${file}이 심볼릭 링크면 게시 전 거부`, () => {
    const fixture = publicationFixture();
    try {
      rmSync(join(fixture.published, file));
      symlinkSync('payload.txt', join(fixture.published, file));
      writeFileSync(join(fixture.published, 'payload.txt'), 'invalid feed');
      fixture.commit();
      const result = fixture.run(snapshot);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /not a regular file/);
    } finally { fixture.cleanup(); }
  });
}

for (const file of ['release.yml', 'pricing-supplement.yml']) {
  test(`${file} 게시 결과에 실제 원격 커밋 기록`, () => {
    const fixture = publicationFixture();
    try {
      const result = fixture.run('게시된 Pages 커밋 기록', file);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(readFileSync(join(fixture.temp, 'revision.txt'), 'utf8').trim(),
        fixture.git(fixture.published, 'rev-parse', 'HEAD'));
    } finally { fixture.cleanup(); }
  });
}

function deploymentFixture() {
  const fixture = publicationFixture();
  const bin = join(fixture.temp, 'bin');
  const artifact = join(fixture.temp, 'downloaded-revision.txt');
  const githubEnv = join(fixture.temp, 'github-env');
  const ghArgs = join(fixture.temp, 'gh-args');
  mkdirSync(bin);
  writeFileSync(artifact, fixture.git(fixture.published, 'rev-parse', 'HEAD') + '\n');
  writeFileSync(githubEnv, '');
  // 원격 다운로드만 대체. 커밋 선택·체크아웃은 실제 워크플로우와 Git으로 검증.
  writeFileSync(join(bin, 'gh'), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$GH_ARGS"
if [ "$GH_DOWNLOAD_FAIL" = 1 ]; then exit 1; fi
mkdir -p "$RUNNER_TEMP/pages-publication"
cp "$GH_ARTIFACT" "$RUNNER_TEMP/pages-publication/revision.txt"
`, { mode: 0o755 });
  return {
    ...fixture, artifact, githubEnv, ghArgs,
    select(extraEnv: NodeJS.ProcessEnv = {}) {
      return fixture.run('배포할 게시 커밋 선택', 'deploy-pages.yml', {
        PATH: `${bin}:${process.env.PATH}`,
        EVENT_NAME: 'workflow_run',
        PUBLISH_RUN_ID: '12345',
        PUBLISH_RUN_ATTEMPT: '2',
        GITHUB_REPOSITORY: 'fixture/openusage',
        GITHUB_ENV: githubEnv,
        GH_ARTIFACT: artifact,
        GH_ARGS: ghArgs,
        GH_DOWNLOAD_FAIL: '0',
        ...extraEnv,
      });
    },
  };
}

test('후속 게시가 피드를 변경해도 성공한 실행의 커밋으로 배포 고정', () => {
  const fixture = deploymentFixture();
  try {
    const verifiedRef = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    const verifiedFeed = fixture.git(fixture.published, 'show', 'HEAD:appcast.xml');
    writeFileSync(join(fixture.published, 'appcast.xml'), 'unverified feed\n');
    fixture.commit();
    fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', 'gh-pages');
    assert.equal(fixture.git(fixture.checkout, 'show', 'FETCH_HEAD:appcast.xml'), 'unverified feed');

    const result = fixture.select();
    assert.equal(result.status, 0, result.stderr);
    const selected = readFileSync(fixture.githubEnv, 'utf8').trim().replace(/^PAGES_REF=/, '');
    assert.equal(selected, verifiedRef);
    fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', selected);
    fixture.git(fixture.checkout, 'checkout', '--quiet', '--detach', 'FETCH_HEAD');
    assert.equal(readFileSync(join(fixture.checkout, 'appcast.xml'), 'utf8').trim(), verifiedFeed);
    assert.deepEqual(readFileSync(fixture.ghArgs, 'utf8').trim().split('\n'), [
      'run', 'download', '12345', '--repo', 'fixture/openusage',
      '--name', 'pages-publication-2', '--dir', join(fixture.temp, 'pages-publication'),
    ]);
  } finally { fixture.cleanup(); }
});

test('자동 배포의 커밋 산출물 다운로드 실패 시 최신 브랜치로 대체하지 않고 중단', () => {
  const fixture = deploymentFixture();
  try {
    const result = fixture.select({ GH_DOWNLOAD_FAIL: '1' });
    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
  } finally { fixture.cleanup(); }
});

for (const ref of ['', 'gh-pages', 'a'.repeat(39), 'a'.repeat(40) + '\nPAGES_REF=gh-pages']) {
  test(`잘못된 배포 커밋 값 ${JSON.stringify(ref)} 거부`, () => {
    const fixture = deploymentFixture();
    try {
      writeFileSync(fixture.artifact, ref);
      const result = fixture.select();
      assert.notEqual(result.status, 0);
      assert.match(result.stdout, /Invalid published Pages commit/);
      assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

test('명시적인 수동 복구 배포는 현재 gh-pages 사용', () => {
  const fixture = deploymentFixture();
  try {
    const result = fixture.select({ EVENT_NAME: 'workflow_dispatch', GH_DOWNLOAD_FAIL: '1' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.githubEnv, 'utf8'), 'PAGES_REF=gh-pages\n');
    assert.equal(existsSync(fixture.ghArgs), false);
  } finally { fixture.cleanup(); }
});
