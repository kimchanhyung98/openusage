import assert from 'node:assert/strict';
import test from 'node:test';
import { tourCamera, tourGeometry } from '../src/data/tour.ts';

test('the complete laptop and the focused app fit short and narrow viewports', () => {
  for (const [width, height] of [[1168, 757], [940, 380], [350, 620], [804, 215], [280, 300]]) {
    for (const zoomed of [false, true]) {
      const frame = tourCamera(width, height, zoomed);
      const bounds = zoomed ? tourGeometry.focus : { x: 0, y: 0, width: tourGeometry.width, height: tourGeometry.height };
      const left = frame.x + bounds.x * frame.scale;
      const top = frame.y + bounds.y * frame.scale;
      assert.ok(frame.scale > 0);
      assert.ok(left >= -0.001 && top >= -0.001);
      assert.ok(left + bounds.width * frame.scale <= width + 0.001);
      assert.ok(top + bounds.height * frame.scale <= height + 0.001);
    }
  }
});
