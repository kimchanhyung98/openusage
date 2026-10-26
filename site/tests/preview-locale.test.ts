import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createTranslator, parseStrings, type PreviewLocale } from '../src/data/preview-locale.ts';
import { previewTranslations } from '../src/data/preview-translations.ts';

function translator(locale: PreviewLocale) {
  const table = Object.assign({}, ...['Common', 'Errors', 'Accounts', 'Customize', 'Dashboard', 'Metrics', 'Settings']
    .map((name) => parseStrings(readFileSync(new URL(`../../Sources/OpenUsage/Resources/Localization/${locale}.lproj/${name}.strings`, import.meta.url), 'utf8'))));
  if (locale !== 'en') Object.assign(table, Object.fromEntries(Object.entries(previewTranslations).map(([key, values]) => [key, values[locale]])));
  return createTranslator(table, locale);
}

test('native resources translate nested reset times, usage, and account labels', () => {
  const ko = translator('ko');
  assert.equal(ko('By Oct 27 at 10:00 AM'), '10월 27일 오전 10:00까지');
  assert.equal(ko('Resets today at 3:07 PM'), '오늘 오후 3:07 초기화');
  assert.equal(ko('Resets in 4d 17h'), '4일 17시간 후 초기화');
  assert.equal(ko('Within 18h 30m'), '18시간 30분 이내');
  assert.equal(ko('~29% left at reset'), '초기화 시 약 29% 남음');
  assert.equal(ko('3% used / 97% left'), '3% 사용 / 97% 남음');
  assert.equal(ko('Community vote share: 72%'), '커뮤니티 투표 비율: 72%');
  assert.equal(ko('Claude Account 1'), 'Claude 계정 1');
  assert.equal(ko('Use Account 2 in this demo? Your Mac’s sign-in will stay unchanged.'),
    '이 미리보기의 사용 계정을 계정 2로 바꿀까요? Mac의 로그인 상태는 그대로 유지됩니다.');
});

test('native positional arguments preserve values in Korean and Japanese', () => {
  const ko = translator('ko');
  assert.equal(ko('Total cost $6.39 across 2 providers'), '공급자 2개의 총비용 $6.39');
  assert.equal(translator('ja')('Resets in 4d 17h'), '4日 17時間後にリセット');
  assert.equal(translator('en')('Resets today at 15:07'), 'Resets today at 15:07');
  assert.equal(ko('  Codex  '), '  Codex  ');
  assert.equal(ko('$7.29/MTok'), '$7.29/MTok');
});

test('standalone reset countdowns use native compact durations in Korean and Japanese', () => {
  const ko = translator('ko');
  const ja = translator('ja');
  for (const [source, korean, japanese] of [
    ['4d 19h', '4일 19시간', '4日 19時間'],
    ['11d 19h', '11일 19시간', '11日 19時間'],
    ['18h 30m', '18시간 30분', '18時間 30分'],
    ['4m', '4분', '4分'],
  ]) {
    assert.equal(ko(source), korean);
    assert.equal(ja(source), japanese);
  }
});
