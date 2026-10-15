// Unit tests for Public/celebrate-core.js, the DOM-free half of the
// result-page celebration (docs/result-celebration.md, J1): the beats, the
// frame values, and the particle motion.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/celebrate-core.js');

/// A seeded generator, so a burst is the same on every run.
function seeded(seed) {
  let s = seed;
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296;
    return s / 4294967296;
  };
}

function options(state, from, to) {
  return Object.assign(Core.plan(state), { from, to });
}

test('the beats follow the design: rows 85 ms apart, the count after the last row', () => {
  const b = Core.beats(8, true, true);
  assert.equal(b.row(0), 140);
  assert.equal(b.row(7), 140 + 7 * 85);
  assert.equal(b.cStart, b.row(7) + 140);
  assert.equal(b.cEnd, b.cStart + 650);
  assert.equal(b.pop, b.cEnd);
  assert.equal(b.end, b.cEnd + 3300);
});

test('a long suite still reaches the count-up within about three seconds', () => {
  const b = Core.beats(30, true, true);
  assert.ok(b.cStart <= 140 + 2400 + 140, `count-up starts at ${b.cStart}`);
  assert.ok(b.row(29) - b.row(28) < 85);
});

test('the sparkle-only state has no cascade and no count', () => {
  const p = Core.plan('already');
  assert.equal(p.cascade, false);
  assert.equal(p.counts, false);
  assert.equal(p.burst, 0);
  const b = Core.beats(8, p.cascade, p.counts);
  assert.equal(b.row(5), 0);
  assert.equal(b.cStart, b.cEnd);
});

test('only the first 100% bursts', () => {
  assert.equal(Core.plan('first').burst, 70);
  assert.equal(Core.plan('improved').burst, 0);
  assert.equal(Core.plan('already').burst, 0);
});

test('the grade reads a dash before a count from zero, then counts to the end', () => {
  const o = options('first', 0, 100);
  const b = Core.beats(4, true, true);
  assert.equal(Core.frame(0, b, o).gradeText, '—');
  const mid = parseInt(Core.frame(b.cStart + 325, b, o).gradeText, 10);
  assert.ok(mid > 0 && mid < 100, `mid count ${mid}`);
  assert.equal(Core.frame(b.cEnd, b, o).gradeText, '100%');
});

test('an improvement counts from the previous percent', () => {
  const o = options('improved', 75, 88);
  const b = Core.beats(4, true, true);
  assert.equal(Core.frame(0, b, o).gradeText, '75%');
  assert.equal(Core.frame(b.cEnd, b, o).gradeText, '88%');
});

test('the 100% pop is larger than the improvement pop', () => {
  const b = Core.beats(4, true, true);
  const perfect = Core.frame(b.pop + 170, b, options('first', 0, 100)).gradeScale;
  const improved = Core.frame(b.pop + 170, b, options('improved', 75, 88)).gradeScale;
  assert.ok(Math.abs(perfect - 1.16) < 0.01, `perfect pop ${perfect}`);
  assert.ok(Math.abs(improved - 1.07) < 0.01, `improved pop ${improved}`);
});

test('the bird hops up only, two hops of 8 px at 100% and one of 5 px for a gain', () => {
  const b = Core.beats(4, true, true);
  const perfect = [];
  const improved = [];
  for (let t = b.pop; t <= b.pop + 600; t += 10) {
    perfect.push(Core.frame(t, b, options('first', 0, 100)).birdY);
    improved.push(Core.frame(t, b, options('improved', 75, 88)).birdY);
  }
  assert.ok(perfect.every((y) => y <= 0 && y >= -8));
  assert.ok(Math.min(...perfect) < -7.9);
  assert.ok(improved.every((y) => y <= 0 && y >= -5));
  assert.ok(Math.min(...improved) < -4.9);
  assert.ok(Core.frame(b.pop + 300, b, options('already', 100, 100)).birdY === 0);
});

test('a row reads running before its beat, then its mark pops to rest at 1', () => {
  const b = Core.beats(3, true, true);
  assert.equal(Core.rowPop(b.row(2) - 1, b, 2), null);
  assert.ok(Math.abs(Core.rowPop(b.row(2), b, 2) - 0.7) < 1e-9);
  assert.equal(Core.rowPop(b.row(2) + 240, b, 2), 1);
});

test('a burst bursts upward, with about one seed in five', () => {
  const parts = Core.burst(500, { x: 100, y: 100, w: 40 }, 7, seeded(1));
  assert.equal(parts.length, 500);
  assert.ok(parts.every((p) => p.vy < 0), 'every particle starts upward');
  const seeds = parts.filter((p) => p.type === 'seed');
  assert.ok(seeds.length > 70 && seeds.length < 130, `${seeds.length} seeds`);
  assert.ok(seeds.every((p) => p.colour === -1));
  assert.ok(parts.filter((p) => p.type === 'feather').every((p) => p.colour >= 0 && p.colour < 7));
});

test('every particle is gone after 5.2 seconds', () => {
  let parts = Core.burst(70, { x: 100, y: 100, w: 40 }, 7, seeded(2));
  for (let t = 0; t < 5300; t += 16) {
    parts = Core.step(parts, 16, 10000);
  }
  assert.equal(parts.length, 0);
});

test('a feather falls no faster than its terminal velocity', () => {
  let parts = Core.burst(20, { x: 100, y: 100, w: 40 }, 7, seeded(3)).filter((p) => p.type === 'feather');
  for (let t = 0; t < 2000; t += 16) {
    parts = Core.step(parts, 16, 10000);
  }
  assert.ok(parts.every((p) => p.vy <= 1.5));
});

test('a spark appears after its delay and is gone 650 ms later', () => {
  let parts = Core.sparkle(
    [{ x: 0, y: 0, rx: 10, ry: 10, n: 7, a0: 0, span: Math.PI * 2, delay0: 0, delayStep: 70 }], seeded(4));
  assert.equal(parts.length, 7);
  assert.equal(Core.sparkProgress(parts[1]), null);
  for (let t = 0; t < 70 + 650 * 2; t += 10) {
    parts = Core.step(parts, 10, 1000);
  }
  assert.equal(parts.length, 0);
});

test('a particle fades over its last 1.2 seconds', () => {
  assert.equal(Core.opacity({ life: 3999 }), 1);
  assert.ok(Math.abs(Core.opacity({ life: 4600 }) - 0.5) < 1e-9);
  assert.equal(Core.opacity({ life: 5200 }), 0);
});
