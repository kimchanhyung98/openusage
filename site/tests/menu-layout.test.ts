import assert from 'node:assert/strict';
import test from 'node:test';
import { menuPosition } from '../src/scripts/menus.ts';

test('account menus align to the trigger and stay inside the viewport', () => {
  assert.deepEqual(menuPosition(
    { left: 1158, right: 1230, top: 460, bottom: 480 },
    { width: 92, height: 52 }, { width: 1327, height: 997 }, true, false,
  ), { left: 1138, top: 484 });
  assert.deepEqual(menuPosition(
    { left: 280, right: 386, top: 300, bottom: 320 },
    { width: 130, height: 80 }, { width: 390, height: 844 }, true, false,
  ), { left: 252, top: 324 });
});

test('a picker near the bottom opens upward and Options near the top opens downward', () => {
  assert.deepEqual(menuPosition(
    { left: 220, right: 310, top: 620, bottom: 642 },
    { width: 120, height: 100 }, { width: 390, height: 680 }, true, false,
  ), { left: 190, top: 516 });
  assert.deepEqual(menuPosition(
    { left: 220, right: 310, top: 70, bottom: 92 },
    { width: 180, height: 170 }, { width: 390, height: 680 }, true, true,
  ), { left: 130, top: 96 });
});

test('menus remain within a narrow or short viewport at every edge', () => {
  for (const viewport of [{ width: 320, height: 480 }, { width: 390, height: 844 }, { width: 1280, height: 320 }]) {
    const menu = { width: 200, height: 190 };
    for (const left of [0, viewport.width - 30]) {
      for (const top of [0, viewport.height / 2, viewport.height - 20]) {
        for (const alignEnd of [false, true]) {
          for (const preferAbove of [false, true]) {
            const position = menuPosition({ left, right: left + 30, top, bottom: top + 20 }, menu, viewport, alignEnd, preferAbove);
            assert.ok(position.left >= 8 && position.top >= 8);
            assert.ok(position.left + menu.width <= viewport.width - 8);
            assert.ok(position.top + menu.height <= viewport.height - 8);
          }
        }
      }
    }
  }
});
