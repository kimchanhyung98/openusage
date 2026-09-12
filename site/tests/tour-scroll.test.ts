import assert from 'node:assert/strict';
import test from 'node:test';
import { TourScrollGesture } from '../src/data/tour-scroll.ts';

test('scroll advances and rewinds every feature before leaving either boundary', () => {
  const gesture = new TourScrollGesture();
  for (let index = 0; index < 4; index++) assert.equal(gesture.move(100, index * 300, index, 5, true), 'next');
  assert.equal(gesture.move(100, 1200, 4, 5, true), 'leave');
  for (let index = 4; index > 0; index--) assert.equal(gesture.move(-100, 1500 + (4 - index) * 300, index, 5, true), 'previous');
  assert.equal(gesture.move(-100, 2700, 0, 5, true), 'leave');
});

test('a trackpad gesture and its momentum advance only one feature', () => {
  const gesture = new TourScrollGesture();
  assert.equal(gesture.move(20, 0, 0, 5, true), 'hold');
  assert.equal(gesture.move(30, 16, 0, 5, true), 'next');
  for (let time = 32; time < 900; time += 16) assert.equal(gesture.move(4, time, 1, 5, true), 'hold');
  assert.equal(gesture.move(100, 1200, 1, 5, true), 'next');
});

test('scrolling in the opposite direction immediately rewinds an interrupted feature', () => {
  const gesture = new TourScrollGesture();
  assert.equal(gesture.move(100, 0, 2, 5, true), 'next');
  assert.equal(gesture.move(-100, 50, 3, 5, true), 'previous');
});

test('momentum cannot leave the section when the last feature has just been selected', () => {
  const gesture = new TourScrollGesture();
  assert.equal(gesture.move(100, 0, 3, 5, true), 'next');
  assert.equal(gesture.move(100, 30, 4, 5, true), 'hold');
  assert.equal(gesture.move(100, 400, 4, 5, true), 'leave');
  assert.equal(gesture.move(100, 430, 4, 5, false), 'hold');
});

test('entering the section or reaching an inner scroll boundary does not skip a feature', () => {
  for (const index of [0, 4]) {
    const gesture = new TourScrollGesture();
    assert.equal(gesture.move(100, 0, index, 5, false), 'native');
    assert.equal(gesture.move(100, 40, index, 5, true), 'hold');
    assert.equal(gesture.move(100, 400, index, 5, true), index === 4 ? 'leave' : 'next');
  }
});

test('a held touch swipe advances once until a new touch starts', () => {
  const gesture = new TourScrollGesture();
  assert.equal(gesture.move(50, 0, 0, 5, true, true), 'next');
  assert.equal(gesture.move(100, 1000, 1, 5, true, true), 'hold');
  gesture.reset();
  assert.equal(gesture.move(-50, 1200, 1, 5, true, true), 'previous');
});

test('continuous deliberate wheel input reaches the next page without requiring a pause', () => {
  for (const delta of [6, 100]) {
    const gesture = new TourScrollGesture();
    let index = 0;
    let left = false;
    for (let time = 0; time <= 2400; time += delta === 6 ? 16 : 100) {
      const decision = gesture.move(delta, time, index, 5, true);
      if (decision === 'next') index++;
      if (decision === 'leave') { left = true; break; }
    }
    assert.equal(left, true, `continuous ${delta}px wheel input must leave the final feature`);
  }
});

test('continuous wheel input after entering a section can advance and reverse without a pause', () => {
  const gesture = new TourScrollGesture();
  assert.equal(gesture.move(100, 0, 0, 5, false), 'native');
  assert.equal(gesture.move(100, 100, 0, 5, true), 'hold');
  assert.equal(gesture.move(100, 200, 0, 5, true), 'hold');
  assert.equal(gesture.move(100, 300, 0, 5, true), 'hold');
  assert.equal(gesture.move(100, 400, 0, 5, true), 'next');
  assert.equal(gesture.move(-100, 450, 1, 5, true), 'previous');
});

test('slower continuous input after a strong initial wheel motion cannot stay locked forever', () => {
  const gesture = new TourScrollGesture();
  assert.equal(gesture.move(100, 0, 0, 5, true), 'next');
  let index = 1;
  let left = false;
  for (let time = 16; time <= 3600; time += 16) {
    const decision = gesture.move(4, time, index, 5, true);
    if (decision === 'next') index++;
    if (decision === 'leave') { left = true; break; }
  }
  assert.equal(left, true, 'weaker continuous input must not require a complete pause');
});
