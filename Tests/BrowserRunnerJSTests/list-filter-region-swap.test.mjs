// Unit test for Public/list-filter.js after a polled region swap. The
// leaderboard's filter box sits in the page's fixed chrome, but its table and
// the "no match" message beside it sit inside a region that table-poll.js
// replaces. The cached message then leaves the document, so the filter must
// mint it again beside the new table, or a filter that matches nobody shows
// an empty board with no message.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/list-filter.js'), 'utf8');

function element(tag) {
  const el = {
    tagName: tag.toUpperCase(), className: '', textContent: '', hidden: false, isConnected: true,
    attrs: {}, children: [], parentNode: null,
    classList: { add() {}, remove() {}, contains: () => false },
    setAttribute(n, v) { this.attrs[n] = String(v); },
    getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
    hasAttribute(n) { return n in this.attrs; },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    insertBefore(c) { this.children.push(c); c.parentNode = this; return c; },
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    closest: () => null,
  };
  return el;
}

/// A region holding a one-row table whose only cell reads `text`.
function regionWithTable(text) {
  const region = element('div');
  const table = element('table');
  table.id = 'leaderboard-table';
  const tbody = element('tbody');
  const row = element('tr');
  const cell = element('td');
  cell.textContent = text;
  row.cells = [cell];
  row.querySelectorAll = (sel) => (sel === 'td, th' || sel === 'td' ? [cell] : []);
  tbody.querySelectorAll = (sel) => (sel === 'tr' ? [row] : []);
  table.querySelector = (sel) => (sel === 'tbody' ? tbody : null);
  table.querySelectorAll = () => [];
  region.appendChild(table);
  return { region, table, row };
}

function load(getTable) {
  const sandbox = {
    document: {
      readyState: 'complete',
      createElement: element,
      getElementById: (id) => (id === 'leaderboard-table' ? getTable() : null),
      querySelectorAll: () => [],
      addEventListener: () => {},
    },
    module: { exports: {} },
    WeakMap, Map, Set, String, Array, Object, RegExp,
  };
  sandbox.self = sandbox;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

test('after a region swap, a filter that matches nobody shows the message again', () => {
  let current = regionWithTable('Quiet Cedar');
  const ListFilter = load(() => current.table);
  const group = element('span');
  const input = element('input');
  input.value = 'nobody';
  input.setAttribute('data-list-filter', 'leaderboard-table');
  group.appendChild(input);

  ListFilter.apply(input);
  const first = current.region.children.find((c) => c.className.includes('js-filter-no-match'));
  assert.ok(first, 'the message is minted beside the table');
  assert.equal(first.hidden, false);

  // The region swap replaces the table and removes the message with it.
  first.isConnected = false;
  current = regionWithTable('Quiet Cedar');
  ListFilter.apply(input);
  const second = current.region.children.find((c) => c.className.includes('js-filter-no-match'));
  assert.ok(second, 'a new message is minted beside the new table');
  assert.notEqual(second, first);
  assert.equal(second.hidden, false);
});
