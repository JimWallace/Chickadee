// Unit tests for the Present-mode podium bounce (Public/present-podium.js,
// #2591). A refresh that keeps the same top three marks the podium settled,
// which stills the CSS bounce; a new top three, or the first podium, bounces.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Podium = require('../../Public/present-podium.js');

/** A region whose podium carries `key`, or no podium when `key` is null. */
function region(key) {
  const classes = new Set();
  const podium = key === null ? null : {
    getAttribute: name => (name === 'data-podium-key' ? key : null),
    classList: { add: c => classes.add(c) },
  };
  return { region: { querySelector: () => podium }, classes };
}

test('settle: the same three after a refresh are settled', () => {
  const { region: r, classes } = region('Ada|Bo|Cy');
  assert.equal(Podium.settle(r, 'Ada|Bo|Cy'), 'Ada|Bo|Cy');
  assert.ok(classes.has(Podium.SETTLED));
});

test('settle: a new top three bounces', () => {
  const { region: r, classes } = region('Bo|Ada|Cy');
  assert.equal(Podium.settle(r, 'Ada|Bo|Cy'), 'Bo|Ada|Cy');
  assert.equal(classes.size, 0);
});

test('settle: the first podium bounces, and a board with no podium has no key', () => {
  const first = region('Ada');
  assert.equal(Podium.settle(first.region, null), 'Ada');
  assert.equal(first.classes.size, 0);
  assert.equal(Podium.settle(region(null).region, 'Ada'), null);
});

test('attach: each repaint compares with the podium before it', () => {
  let current = region('Ada|Bo|Cy');
  let onRepaint = null;
  const target = {
    querySelector: sel => current.region.querySelector(sel),
    addEventListener: (type, fn) => { if (type === 'chickadee:table-repaint') onRepaint = fn; },
  };
  Podium.attach(target);

  // A value below the podium changed: the same three stay still.
  current = region('Ada|Bo|Cy');
  onRepaint();
  assert.ok(current.classes.has(Podium.SETTLED));

  // The top three changed: they bounce.
  current = region('Bo|Ada|Cy');
  onRepaint();
  assert.equal(current.classes.size, 0);

  // The new three stay: still again.
  current = region('Bo|Ada|Cy');
  onRepaint();
  assert.ok(current.classes.has(Podium.SETTLED));
});
