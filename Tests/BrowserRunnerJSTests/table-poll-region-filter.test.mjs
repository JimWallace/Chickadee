// Unit tests for the region filter rule in Public/table-poll.js. A filter box
// in the page's fixed chrome can point at a table INSIDE a polled region, as
// the leaderboard's does. The swap replaces that table, so the poll must find
// the box by its target, re-apply it after the swap, and wait while it has
// focus, and keep each scroll container's horizontal scroll. Before this, a
// typed filter was undone by the next refresh.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/table-poll.js'), 'utf8');

const table = { id: 'leaderboard-table' };
const filterBox = {
  getAttribute: (name) => (name === 'data-list-filter' ? 'leaderboard-table' : null),
};

function makeRegion() {
  const region = {
    id: 'activity-results',
    attrs: { 'data-poll-url': '/testsetups/s/leaderboard?fragment=body', 'data-poll-swap': 'region' },
    events: [],
    holdsTable: true,
    getAttribute(n) { return this.attrs[n] ?? null; },
    querySelector: () => null,
    contains(node) { return node === table && this.holdsTable; },
    dispatchEvent(e) { this.events.push(e.type); return true; },
    innerHTML: '',
  };
  return region;
}

function load({ activeElement = null } = {}) {
  const applied = [];
  const sandbox = {
    document: {
      readyState: 'complete', hidden: false, activeElement,
      querySelectorAll: (sel) => (sel === 'input[data-list-filter]' ? [filterBox] : []),
      querySelector: () => null,
      getElementById: (id) => (id === 'leaderboard-table' ? table : null),
      addEventListener: () => {},
    },
    module: { exports: {} },
    WeakMap, Promise, Number, Date,
    setInterval: () => 0,
    CustomEvent: class { constructor(type) { this.type = type; } },
    fetch: () => Promise.resolve({
      status: 200, ok: true, redirected: false,
      headers: { get: () => null },
      text: () => Promise.resolve('<table id="leaderboard-table"></table>'),
    }),
    ChickadeeListFilter: { apply: (input) => applied.push(input) },
  };
  sandbox.self = sandbox;
  sandbox.window = { location: { reload: () => {} } };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { TablePoll: sandbox.module.exports, applied };
}

test('a region swap re-applies a filter box that points into the region', async () => {
  const h = load();
  assert.equal(await h.TablePoll.refresh(makeRegion()), true);
  assert.ok(h.applied.includes(filterBox));
});

test('focus in that filter box defers the region poll', () => {
  const h = load({ activeElement: filterBox });
  assert.equal(h.TablePoll.shouldSkip(makeRegion()), true);
});

test('a filter box pointed elsewhere neither defers nor follows the swap', async () => {
  const h = load({ activeElement: filterBox });
  const region = makeRegion();
  region.holdsTable = false;
  assert.equal(h.TablePoll.shouldSkip(region), false);
  await h.TablePoll.refresh(region);
  assert.ok(!h.applied.includes(filterBox));
});

test('a region swap keeps the horizontal scroll of each scroll container', async () => {
  const h = load();
  const region = makeRegion();
  let scrollers = [{ scrollLeft: 240 }, { scrollLeft: 0 }];
  region.querySelectorAll = (sel) => (sel === '.table-scroll' ? scrollers : []);
  Object.defineProperty(region, 'innerHTML', {
    set() { scrollers = [{ scrollLeft: 0 }, { scrollLeft: 0 }]; },
    get() { return ''; },
  });
  assert.equal(await h.TablePoll.refresh(region), true);
  assert.deepEqual(scrollers.map((s) => s.scrollLeft), [240, 0]);
});
