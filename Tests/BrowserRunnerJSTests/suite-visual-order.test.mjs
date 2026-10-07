// Unit tests for suite-table.js's `visualOrder`: which rows one section of the
// suite table shows, and in which order (#2385).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { visualOrder } = require('../../Public/suite-table.js');

function item(id, dependsOn = []) {
  return { id, dependsOn };
}

function rows(items) {
  return visualOrder(items).map((r) => `${r.item.id}@${r.depth}`);
}

test('a root and its direct children show as one indented group', () => {
  assert.deepEqual(
    rows([item('a'), item('b', ['a']), item('c')]),
    ['a@0', 'b@1', 'c@0']);
});

test('every link of a dependency chain has a row (#2385)', () => {
  // C depends on B, and B depends on A. The server accepts this; before the
  // fix, C had no row and could not be edited or deleted in the UI.
  assert.deepEqual(
    rows([item('a'), item('b', ['a']), item('c', ['b'])]),
    ['a@0', 'b@1', 'c@1']);
});

test('a chain keeps the order of its items, and shows each item once', () => {
  const items = [item('a'), item('b', ['a']), item('c', ['b']), item('d', ['a']), item('e', ['c'])];
  assert.deepEqual(rows(items), ['a@0', 'b@1', 'c@1', 'e@1', 'd@1']);
  assert.equal(visualOrder(items).length, items.length);
});

test('an item whose parent is in another section is a root here', () => {
  assert.deepEqual(rows([item('b', ['elsewhere']), item('c', ['b'])]), ['b@0', 'c@1']);
});

test('items in a dependency cycle are shown as roots rather than hidden', () => {
  // The server refuses cycles; a hand-edited manifest must still not hide rows.
  const items = [item('a', ['b']), item('b', ['a'])];
  assert.deepEqual(rows(items), ['a@0', 'b@1']);
});
