// Unit tests for the reference render in Public/class-composite-core.js
// (docs/class-composite.md, slice 6): an empty slot that shows the reference
// render gets its own class, so the stylesheet dims it, and its own word in
// the staff tooltip. Its pixels draw like any other slot's.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/class-composite-core.js');

const b64 = (bytes) => Buffer.from(bytes).toString('base64');

test('a reference slot gets the reference class', () => {
  assert.deepEqual(
    Core.slotClasses({ slot: 1, state: 'reference', rendering: false }),
    ['composite-slot', 'composite-slot--reference']);
});

test('the staff tooltip names a reference render', () => {
  assert.equal(Core.slotTitle(1, { slot: 1, state: 'reference', rendering: false }), 'Slot 2: reference render');
  assert.equal(
    Core.slotTitle(0, { slot: 0, state: 'reference', rendering: true, owner: 'Teal Heron' }),
    'Slot 1 · Teal Heron: reference render, grading');
});

test('a reference render merges and draws like a contribution', () => {
  const spec = { compositor: 'tile', columns: 2, rows: 1, count: 2, width: 1, height: 1, frames: 1, format: 'gray8', frameRate: 12 };
  const state = Core.mergeSnapshot(Core.emptyState(2), {
    cursor: '5',
    slots: [{ slot: 1, state: 'reference', rendering: false }],
    pixels: [{ slot: 1, data: b64([90]) }]
  });
  assert.equal(state.slots[1].state, 'reference');
  const rgba = Core.composeRGBA(spec, { 1: Core.decodeBase64(state.pixels[1]) }, 0);
  assert.deepEqual(Array.from(rgba.slice(4, 8)), [90, 90, 90, 255]);
});
