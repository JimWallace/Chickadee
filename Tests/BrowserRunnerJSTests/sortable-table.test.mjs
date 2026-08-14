// Unit tests for Public/sortable-table.js — the one column-sort
// implementation (UI audit S2).
//
// These pin the union of what the five page-local sorters did before they were
// deleted, because each had learned something the others hadn't:
//
//   * a role <select>'s VALUE is the sort key, not its option-label text
//     (a raw-text sort ordered every role row identically);
//   * `data-iso` doubles as the sort value, so a relative-time cell needs no
//     second attribute repeating the same timestamp;
//   * "12/15" sorts as 12 (the submissions grade column is a fraction);
//   * a blank numeric cell sorts below every real value rather than as 0;
//   * ties break on a named column, so a repaint can't reshuffle equal rows.
//
// `compare` and `cellValue` are exported for exactly this: the sort itself is
// DOM surgery, but the ordering rules are pure and worth testing directly.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/sortable-table.js'), 'utf8');

function load() {
  const sandbox = {
    document: { readyState: 'complete', querySelectorAll: () => [], addEventListener: () => {} },
    module: { exports: {} },
    WeakMap,
    Intl,
    Number,
    Date,
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

function cell({ text = '', sortValue, iso, select }) {
  return {
    textContent: text,
    getAttribute: (name) => {
      if (name === 'data-sort-value') return sortValue ?? null;
      if (name === 'data-iso') return iso ?? null;
      return null;
    },
    querySelector: (sel) => (sel === 'select' && select ? { value: select } : null),
  };
}

const Sortable = load();

test('cellValue prefers data-sort-value over text', () => {
  assert.equal(Sortable.cellValue(cell({ text: '1.4 GB', sortValue: '1503238553' })), '1503238553');
});

test('cellValue falls back to data-iso — one attribute serves rendering and sorting', () => {
  assert.equal(
    Sortable.cellValue(cell({ text: '3 hours ago', iso: '2026-08-13T12:00:00Z' })),
    '2026-08-13T12:00:00Z'
  );
});

test('cellValue reads a select by value, not its option-label text', () => {
  assert.equal(
    Sortable.cellValue(cell({ text: 'Student TA Instructor', select: 'ta' })),
    'ta'
  );
});

test('cellValue uses text when nothing else is present', () => {
  assert.equal(Sortable.cellValue(cell({ text: '  Ada Lovelace  ' })), 'Ada Lovelace');
});

test('number sorting extracts a leading number from mixed text', () => {
  // The grade column renders "12/15"; it must sort as 12, not lexically.
  assert.ok(Sortable.compare('12/15', '9/15', 'number') > 0);
  assert.ok(Sortable.compare('3/15', '12/15', 'number') < 0);
});

test('a blank numeric cell sorts below every real value', () => {
  assert.ok(Sortable.compare('', '0', 'number') < 0);
  assert.ok(Sortable.compare('', '-5', 'number') < 0);
});

test('duration sorting treats the -1 sentinel as smallest', () => {
  // "no average yet" is rendered "—" and carries data-sort-value="-1".
  assert.ok(Sortable.compare('-1', '250', 'duration') < 0);
});

test('date sorting accepts both ISO strings and epoch integers', () => {
  assert.ok(Sortable.compare('2026-08-13T12:00:00Z', '2026-08-12T12:00:00Z', 'date') > 0);
  assert.ok(Sortable.compare('1786665600', '1786579200', 'date') > 0);
  // A missing timestamp sorts below any real one (never as "now" or epoch 0
  // ambiguity against negative values).
  assert.ok(Sortable.compare('', '1786579200', 'date') < 0);
});

test('text sorting is case-insensitive and numeric-aware', () => {
  assert.ok(Sortable.compare('ada', 'Bob', 'text') < 0);
  // "runner-2" before "runner-10": digits compare as numbers, not characters.
  assert.ok(Sortable.compare('runner-2', 'runner-10', 'text') < 0);
});

test('apply() on an unsorted or absent table is a no-op, not a throw', () => {
  Sortable.apply(null);
  Sortable.apply({ querySelector: () => null, getAttribute: () => null });
});
