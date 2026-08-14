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

// ── The sort itself ─────────────────────────────────────────────────────────
//
// The rules above are pure and were always tested; the DOM surgery that uses
// them was not, which is how it kept calling cellValue() from inside the
// comparator — reading every row's cells ~2·log2(n) times over, on every
// 5-second poll repaint of the roster and users tables, not just on a click.

function sortHarness({ names, tiebreaks = null, initial = 'name:asc' }) {
  let cellReads = 0;
  let tbodyMutations = 0;

  const makeCell = (text) => ({
    getAttribute: () => null,
    querySelector: () => null,
    get textContent() { cellReads += 1; return text; },
  });

  const rows = names.map((name, i) => ({
    name,
    children: [makeCell(name), makeCell(tiebreaks ? tiebreaks[i] : 'u' + i)],
  }));

  const order = rows.slice();
  const tbody = {
    querySelectorAll: () => order.slice(),
    appendChild(node) {
      tbodyMutations += 1;
      if (node.isFragment) {
        node.nodes.forEach((n) => { order.splice(order.indexOf(n), 1); order.push(n); });
        return node;
      }
      order.splice(order.indexOf(node), 1);
      order.push(node);
      return node;
    },
  };

  const headers = [
    { key: 'name', type: 'text' },
    { key: 'username', type: 'text' },
  ].map((h) => ({
    attrs: { 'data-sort-key': h.key, 'data-sort-type': h.type },
    classList: { add() {}, remove() {} },
    getAttribute(n) { return this.attrs[n] ?? null; },
    setAttribute(n, v) { this.attrs[n] = v; },
    querySelector: () => ({ addEventListener() {} }),
  }));

  const table = {
    attrs: { 'data-sort-initial': initial, 'data-sort-tiebreak': tiebreaks ? 'username' : null },
    getAttribute(n) { return this.attrs[n] ?? null; },
    querySelector: (sel) => (sel === 'tbody' ? tbody : null),
    querySelectorAll: (sel) => (sel === 'thead th' ? headers : []),
  };

  const sandbox = {
    document: {
      readyState: 'complete',
      querySelectorAll: (sel) => (sel === '.sortable-table' ? [table] : []),
      addEventListener: () => {},
      createDocumentFragment: () => ({
        isFragment: true,
        nodes: [],
        appendChild(n) { this.nodes.push(n); return n; },
      }),
    },
    module: { exports: {} },
    WeakMap, Intl, Number, Date,
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);   // init() applies data-sort-initial

  return {
    Sortable: sandbox.module.exports,
    table,
    order: () => order.map((r) => r.name),
    cellReads: () => cellReads,
    tbodyMutations: () => tbodyMutations,
  };
}

test('data-sort-initial orders the rows on load', () => {
  const h = sortHarness({ names: ['Zhang', 'Assistant', 'Muñoz', 'Byron'] });
  assert.deepEqual(h.order(), ['Assistant', 'Byron', 'Muñoz', 'Zhang']);
});

test('each row is read once per sort, not once per comparison', () => {
  const names = Array.from({ length: 64 }, (_, i) => 'Name ' + ((i * 37) % 64));
  const h = sortHarness({ names });
  // 64 rows, no tiebreak column declared: one key read each. A comparator-side
  // read would cost ~2·64·log2(64) ≈ 768.
  assert.equal(h.cellReads(), 64, `expected 64 cell reads, got ${h.cellReads()}`);
});

test('a declared tiebreak costs exactly one extra read per row', () => {
  const h = sortHarness({
    names: ['Ada', 'Ada', 'Ada', 'Bob'],
    tiebreaks: ['u3', 'u1', 'u2', 'u0'],
  });
  assert.equal(h.cellReads(), 8, 'four rows x (key + tiebreak)');
  assert.deepEqual(h.order(), ['Ada', 'Ada', 'Ada', 'Bob']);
});

test('ties break on the named column so a repaint cannot reshuffle equal rows', () => {
  const h = sortHarness({
    names: ['Ada', 'Ada', 'Ada'],
    tiebreaks: ['u3', 'u1', 'u2'],
  });
  const usernames = () => h.table.querySelector('tbody').querySelectorAll('tr')
    .map((r) => r.children[1].textContent);
  assert.deepEqual(usernames(), ['u1', 'u2', 'u3']);
});

test('the reorder touches the tbody once, not once per row', () => {
  const h = sortHarness({ names: ['Zhang', 'Assistant', 'Muñoz', 'Byron'] });
  assert.equal(h.tbodyMutations(), 1, 'rows move in one DocumentFragment insertion');
});

test('re-applying the sort after a repaint re-reads the new rows', () => {
  const h = sortHarness({ names: ['Zhang', 'Assistant'] });
  const before = h.cellReads();
  h.Sortable.apply(h.table);
  assert.ok(h.cellReads() > before, 'apply() re-reads rather than reusing stale keys');
  assert.deepEqual(h.order(), ['Assistant', 'Zhang']);
});

test('apply() on an unsorted or absent table is a no-op, not a throw', () => {
  Sortable.apply(null);
  Sortable.apply({ querySelector: () => null, getAttribute: () => null });
});
