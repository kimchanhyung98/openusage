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

function guardedDeploymentFixture() {
  const fixture = publicationFixture();
  const output = join(fixture.temp, 'github-output');
  const checkpoint = 'refs/heads/pages-deployment';
  return {
    ...fixture, output, checkpoint,
    deploy(ref: string) {
      fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', 'gh-pages');
      fixture.git(fixture.checkout, 'checkout', '--quiet', '--detach', ref);
      writeFileSync(output, '');
      return fixture.run('과거 Pages 배포 차단', 'deploy-pages.yml', { GITHUB_OUTPUT: output });
    },
  };
}

test('Pages 최초 배포와 새 커밋 전진 후 과거 실행은 배포 생략', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const first = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    let result = fixture.deploy(first);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.output, 'utf8').trim(), 'deploy=true');
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), first);
    writeFileSync(join(fixture.published, 'appcast.xml'), 'new release\n');
    fixture.commit();
    const second = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    result = fixture.deploy(second);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), second);
    result = fixture.deploy(first);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.output, 'utf8').trim(), 'deploy=false');
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), second);
  } finally { fixture.cleanup(); }
});

test('Pages 기준 전진 후 게시 head가 바뀌어도 동일 SHA 재시도 허용', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const verified = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    assert.equal(fixture.deploy(verified).status, 0);
    writeFileSync(join(fixture.published, 'appcast.xml'), 'unverified feed\n');
    fixture.commit();
    const result = fixture.deploy(verified);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.output, 'utf8').trim(), 'deploy=true');
    assert.equal(fixture.git(fixture.checkout, 'rev-parse', 'HEAD'), verified);
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), verified);
  } finally { fixture.cleanup(); }
});

test('과거 Pages 실행으로 최초 보호 기준 생성 금지', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const old = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    writeFileSync(join(fixture.published, 'index.html'), 'newer publication\n');
    fixture.commit();
    const result = fixture.deploy(old);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /latest successful publication/);
    assert.equal(readFileSync(fixture.output, 'utf8'), '');
    assert.equal(fixture.git(fixture.published, 'for-each-ref', '--format=%(refname)', fixture.checkpoint), '');
  } finally { fixture.cleanup(); }
});

test('갈라진 Pages 게시 이력은 강제 전진 없이 실패', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const first = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    writeFileSync(join(fixture.published, 'index.html'), 'deployed branch\n');
    fixture.commit();
    const deployed = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    assert.equal(fixture.deploy(deployed).status, 0);
    fixture.git(fixture.published, 'checkout', '--quiet', '--detach', first);
    writeFileSync(join(fixture.published, 'index.html'), 'diverged branch\n');
    fixture.commit();
    const diverged = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    fixture.git(fixture.published, 'update-ref', 'refs/heads/gh-pages', diverged);
    const result = fixture.deploy(diverged);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /not a descendant/);
    assert.equal(readFileSync(fixture.output, 'utf8'), '');
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), deployed);
  } finally { fixture.cleanup(); }
});

for (const failure of ['read', 'write']) {
  test(`Pages 보호 기준 ${failure} 실패 시 배포 금지`, () => {
    const fixture = guardedDeploymentFixture();
    try {
      const ref = fixture.git(fixture.published, 'rev-parse', 'HEAD');
      fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', 'gh-pages');
      fixture.git(fixture.checkout, 'checkout', '--quiet', '--detach', ref);
      if (failure === 'read') {
        fixture.git(fixture.checkout, 'remote', 'set-url', 'origin', join(fixture.temp, 'missing'));
      } else {
        writeFileSync(join(fixture.published, '.git/hooks/pre-receive'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
      }
      writeFileSync(fixture.output, '');
      const result = fixture.run('과거 Pages 배포 차단', 'deploy-pages.yml', { GITHUB_OUTPUT: fixture.output });
      assert.notEqual(result.status, 0);
      assert.equal(readFileSync(fixture.output, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

test('Pages 보호 통과 조건이 산출물 업로드와 실제 배포 모두에 적용', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/deploy-pages.yml', import.meta.url), 'utf8');
  for (const name of ['사이트 배포 산출물 업로드', 'GitHub Pages 배포']) {
    assert.ok(workflow.includes(`      - name: ${name}\n        if: steps.revision.outputs.deploy == 'true'`));
  }
  assert.match(workflow, /ref: \$\{\{ env.PAGES_REF \}\}\n          fetch-depth: 0/);
  assert.match(workflow, /group: pages-deploy\n  queue: max\n  cancel-in-progress: false/);
});

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

test('가격표 게시 작업은 main ref에서만 실행', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/pricing-supplement.yml', import.meta.url), 'utf8');
  assert.match(workflow, /jobs:\n  publish:\n    if: github\.ref == 'refs\/heads\/main'\n/);
  assert.match(workflow, /\n  workflow_dispatch:/);
});

const supplement = JSON.parse(readFileSync(new URL('../../Sources/OpenUsage/Resources/pricing_supplement.json', import.meta.url), 'utf8'));
for (const [updatedAt, valid] of [
  [supplement.updated_at, true], ['2024-02-29T23:59:59Z', true],
  ['2026-09-13', false], ['2026-09-13T00:00:00+00:00', false],
  ['2026-09-13T00:00:00.000Z', false], ['2026-09-13T00:00:00Z\n', false],
  ['2026-02-29T00:00:00Z', false], ['2026-13-01T00:00:00Z', false],
  ['2026-09-13T24:00:00Z', false], ['2026-09-13T00:00:60Z', false],
  ['2026-9-13T00:00:00Z', false], ['２０２６-09-13T00:00:00Z', false],
  [undefined, false], [true, false], [12345, false],
] as const) {
  test(`가격표 발행 시 updated_at ${JSON.stringify(updatedAt)} ${valid ? '허용' : '거부'}`, () => {
    const temp = mkdtempSync(join(tmpdir(), 'openusage-pricing-validation-test-'));
    try {
      const resources = join(temp, 'Sources/OpenUsage/Resources');
      mkdirSync(resources, { recursive: true });
      writeFileSync(join(resources, 'pricing_supplement.json'), JSON.stringify({ ...supplement, updated_at: updatedAt }));
      const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', workflowStep('가격표 JSON 검증', 'pricing-supplement.yml')], {
        cwd: temp, encoding: 'utf8', timeout: 5000,
      });
      assert.equal(result.status, valid ? 0 : 1, result.stderr || result.stdout);
      if (!valid) assert.match(result.stderr, /updated_at/);
    } finally { rmSync(temp, { recursive: true, force: true }); }
  });
}

test('사이트 게시 대상만 변경된 push는 게시 내부 검증으로 처리', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/site.yml', import.meta.url), 'utf8');
  const push = workflow.split('  push:\n')[1].split('  pull_request:\n')[0];
  for (const path of ['site/**', 'script/site_*.sh', '.github/workflows/publish-site.yml']) {
    assert.equal(push.includes(`      - '${path}'`), false, path);
  }
  assert.ok(push.includes("      - 'Sources/OpenUsage/**'"));
  assert.ok(push.includes("      - '!Sources/OpenUsage/Resources/ProviderIcons/**'"));
  assert.match(workflow, /\n  workflow_call:/);
  const pullRequest = workflow.split('  pull_request:\n')[1].split('\npermissions:')[0];
  for (const path of ['site/**', 'script/site_*.sh', 'Sources/OpenUsage/**', '.github/workflows/publish-site.yml']) {
    assert.ok(pullRequest.includes(`      - '${path}'`), path);
  }
});
