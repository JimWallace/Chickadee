// Unit tests for Public/class-composite-core.js, the DOM-free half of the
// class-composite view (docs/class-composite.md, slice 5): the canvas size,
// the shared clock, where a slot's pixels land, the four compositors, and how
// a snapshot merges into what the page holds.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/class-composite-core.js');

function spec(overrides) {
  return Object.assign(
    { compositor: 'tile', columns: 2, rows: 2, count: 4, width: 2, height: 1, frames: 1, format: 'gray8', frameRate: 12 },
    overrides);
}

const b64 = (bytes) => Buffer.from(bytes).toString('base64');

test('the spec reads from data attributes, with the count from the grid', () => {
  const s = Core.specFromDataset({
    compositeCompositor: 'tile', compositeCols: '8', compositeRows: '6', compositeW: '8', compositeH: '8',
    compositeFrames: '30', compositeFormat: 'rgb8', compositeFrameRate: '24',
  });
  assert.deepEqual(s, {
    compositor: 'tile', columns: 8, rows: 6, count: 48, width: 8, height: 8, frames: 30, format: 'rgb8', frameRate: 24,
  });
  assert.equal(Core.specFromDataset({ compositeFormat: 'cmyk' }).format, 'gray8', 'an unknown format reads as gray');
});

test('a grid canvas holds every tile; a sequence or a sum holds one contribution', () => {
  assert.deepEqual(Core.canvasSize(spec()), { width: 4, height: 2 });
  assert.deepEqual(Core.canvasSize(spec({ compositor: 'gallery' })), { width: 4, height: 2 });
  assert.deepEqual(Core.canvasSize(spec({ compositor: 'sequence' })), { width: 2, height: 1 });
  assert.deepEqual(Core.canvasSize(spec({ compositor: 'sum' })), { width: 2, height: 1 });
});

test('a sequence plays every slot in order; a tile plays its frames on one clock', () => {
  const sequence = spec({ compositor: 'sequence', frames: 3 });
  assert.equal(Core.loopLength(sequence), 12);
  assert.deepEqual(Core.frameAt(sequence, 4), { slot: 1, frame: 1 });
  assert.deepEqual(Core.frameAt(sequence, 12), { slot: 0, frame: 0 }, 'the loop wraps');
  assert.deepEqual(Core.frameAt(spec({ frames: 3 }), 5), { slot: null, frame: 2 });
  assert.equal(Core.isAnimated(spec()), false, 'a still tile does not move');
  assert.equal(Core.isAnimated(spec({ compositor: 'sequence' })), true);
});

test('a slot lands at its column and row', () => {
  assert.deepEqual(Core.slotOrigin(spec(), 3), { x: 2, y: 1 });
});

test('gray and RGB frames become opaque RGBA', () => {
  assert.deepEqual([...Core.frameRGBA(spec(), Uint8Array.from([10, 200]), 0)], [10, 10, 10, 255, 200, 200, 200, 255]);
  const rgb = spec({ format: 'rgb8', frames: 2 });
  const bytes = Uint8Array.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  assert.deepEqual([...Core.frameRGBA(rgb, bytes, 1)], [7, 8, 9, 255, 10, 11, 12, 255]);
});

test('a tile canvas places each slot and leaves an empty slot transparent', () => {
  const out = Core.composeRGBA(spec(), { 3: Uint8Array.from([50, 60]) }, 0);
  // Row 1 holds slot 2 (empty) then slot 3.
  assert.deepEqual([...out.subarray(16, 32)], [0, 0, 0, 0, 0, 0, 0, 0, 50, 50, 50, 255, 60, 60, 60, 255]);
  assert.equal(out[3], 0, 'slot 0 is empty');
});

test('a sequence shows the slot the clock is on', () => {
  const s = spec({ compositor: 'sequence' });
  const pixels = { 0: Uint8Array.from([1, 1]), 1: Uint8Array.from([9, 9]) };
  assert.equal(Core.composeRGBA(s, pixels, 1)[0], 9);
  assert.equal(Core.composeRGBA(s, pixels, 2)[3], 0, 'slot 2 has no contribution');
});

test('a sum adds the contributions and scales the brightest sample to 255', () => {
  const s = spec({ compositor: 'sum' });
  const out = Core.composeRGBA(s, { 0: Uint8Array.from([10, 0]), 1: Uint8Array.from([10, 10]) }, 0);
  assert.deepEqual([...out], [255, 255, 255, 255, 128, 128, 128, 255]);
});

test('a snapshot replaces the slot states and keeps pixels it does not resend', () => {
  let state = Core.emptyState(4);
  state = Core.mergeSnapshot(state, {
    cursor: '10', complete: 1, total: 4,
    slots: [{ slot: 0, state: 'passed', rendering: false, owner: 'Calm Finch' }, { slot: 2, state: 'empty', rendering: true }],
    pixels: [{ slot: 0, data: b64([1, 2]) }],
  });
  assert.equal(state.cursor, '10');
  assert.equal(state.pixels[0], b64([1, 2]));
  assert.deepEqual(state.slots[2], { state: 'empty', rendering: true, owner: '' });

  state = Core.mergeSnapshot(state, {
    cursor: '20', complete: 1, total: 4,
    slots: [{ slot: 0, state: 'passed', rendering: true }],
    pixels: [],
  });
  assert.equal(state.pixels[0], b64([1, 2]), 'unchanged pixels stay');
  assert.equal(state.slots[2], undefined, 'a slot left out is empty again');

  state = Core.mergeSnapshot(state, { cursor: '30', complete: 0, total: 4, slots: [], pixels: [] });
  assert.deepEqual(state.pixels, {}, 'an emptied slot drops its pixels');
});

test('a cell carries its state and rendering classes', () => {
  assert.deepEqual(Core.slotClasses(null), ['composite-slot', 'composite-slot--empty']);
  assert.deepEqual(Core.slotClasses({ state: 'failed', rendering: true }), [
    'composite-slot', 'composite-slot--failed', 'composite-slot--rendering',
  ]);
});

test('the staff tooltip names the holder and the state', () => {
  assert.equal(Core.slotTitle(3, null), 'Slot 4: empty', 'slots count from 1');
  assert.equal(Core.slotTitle(3, { state: 'failed', rendering: true, owner: 'Calm Finch' }),
    'Slot 4 · Calm Finch: did not pass, grading');
});

test('base64 decodes to bytes', () => {
  assert.deepEqual([...Core.decodeBase64(b64([0, 255, 7]))], [0, 255, 7]);
});
