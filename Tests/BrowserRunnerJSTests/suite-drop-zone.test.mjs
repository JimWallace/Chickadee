// Unit tests for suite-table.js's `dropZoneFor` — which indicator a row shows
// while another row is dragged over it, and therefore where the drop will land.
//
// This is the whole correctness content of the `dragover` handler; everything
// else in it is bookkeeping about when to touch the DOM. It was inline and
// untested, in a 1,700-line file whose six existing tests cover file
// classification and error extraction and nothing about the table itself. The
// render tests prove the template resolves and never run this code; the visual
// harness captures no page that draws it.
//
// What makes it worth pinning rather than reading: the middle band is the
// ADOPT band, and adopting writes a dependency edge. Every refusal below exists
// because the edge it would create is one the server cannot expand or the
// graph cannot hold — and a wrong "yes" here does not look wrong on screen. The
// row lands, the suite saves, and a test's prerequisite is quietly not what the
// author drew.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { dropZoneFor } = require('../../Public/suite-table.js');

/// The permissive case: everything that could refuse an adopt says no.
function adoptable(over = {}) {
  return {
    relY: 0.5,
    sameSection: true,
    targetIsChild: false,
    targetIsCheck: false,
    dragIsCheck: false,
    targetHasChildren: () => false,
    ...over,
  };
}

// ── The bands ───────────────────────────────────────────────────────────────

test('the top and bottom thirds place the row, never adopt', () => {
  for (const relY of [0, 0.1, 0.29]) {
    assert.equal(dropZoneFor(adoptable({ relY })), 'drop-before', `relY=${relY}`);
  }
  for (const relY of [0.71, 0.9, 1]) {
    assert.equal(dropZoneFor(adoptable({ relY })), 'drop-after', `relY=${relY}`);
  }
});

test('the band edges belong to the middle, so adopt has the full third', () => {
  assert.equal(dropZoneFor(adoptable({ relY: 0.3 })), 'drop-adopt');
  assert.equal(dropZoneFor(adoptable({ relY: 0.7 })), 'drop-adopt');
});

test('a refused adopt falls back on the half-way line, not the band edge', () => {
  // Otherwise the middle third would all land one way, and the row's own
  // midpoint would stop being where before becomes after.
  const refused = { sameSection: false };
  assert.equal(dropZoneFor(adoptable({ ...refused, relY: 0.49 })), 'drop-before');
  assert.equal(dropZoneFor(adoptable({ ...refused, relY: 0.5 })), 'drop-after');
});

// ── Why an adopt is refused ─────────────────────────────────────────────────

test('a cross-section hover cannot adopt: the dep token would not resolve', () => {
  assert.equal(dropZoneFor(adoptable({ sameSection: false })), 'drop-after');
});

test('neither end of the edge may be a check — checks are graph leaves', () => {
  assert.equal(dropZoneFor(adoptable({ targetIsCheck: true })), 'drop-after',
    'adopting ONTO a check would produce a check:<id> token the server does not expand');
  assert.equal(dropZoneFor(adoptable({ dragIsCheck: true })), 'drop-after',
    'and a check being dragged cannot acquire a parent either');
});

test('a target that already depends on something cannot take a child', () => {
  assert.equal(dropZoneFor(adoptable({ targetIsChild: true })), 'drop-after');
});

test('a target that already has children in this section cannot take another', () => {
  assert.equal(dropZoneFor(adoptable({ targetHasChildren: () => true })), 'drop-after');
});

test('every refusal is independent — any one of them is enough', () => {
  const refusals = [
    ['cross-section', { sameSection: false }],
    ['target is a check', { targetIsCheck: true }],
    ['dragged row is a check', { dragIsCheck: true }],
    ['target is already a child', { targetIsChild: true }],
    ['target already has children', { targetHasChildren: () => true }],
  ];
  for (const [label, one] of refusals) {
    assert.notEqual(dropZoneFor(adoptable(one)), 'drop-adopt', label);
  }
  // …and with none of them, the same hover does adopt, so the assertions above
  // are not passing because the fixture never adopts in the first place.
  assert.equal(dropZoneFor(adoptable()), 'drop-adopt');
});

// ── The thunk ───────────────────────────────────────────────────────────────
//
// `targetHasChildren` scans every item in the suite. It is a thunk so that the
// cheap refusals above it short-circuit first — most hovers cannot adopt for a
// reason that costs nothing to check, and this runs on a drag's hot path.

test('the expensive check is not run when a cheap refusal already decided', () => {
  for (const [label, one] of [
    ['outside the adopt band', { relY: 0.9 }],
    ['cross-section', { sameSection: false }],
    ['target is a check', { targetIsCheck: true }],
    ['dragged row is a check', { dragIsCheck: true }],
    ['target is already a child', { targetIsChild: true }],
  ]) {
    let called = 0;
    dropZoneFor(adoptable({ ...one, targetHasChildren: () => { called += 1; return false; } }));
    assert.equal(called, 0, `${label}: scanned the suite for an answer it did not need`);
  }
});

test('the expensive check IS run when nothing cheaper has refused', () => {
  let called = 0;
  dropZoneFor(adoptable({ targetHasChildren: () => { called += 1; return false; } }));
  assert.equal(called, 1, 'otherwise a target with children would silently adopt');
});
