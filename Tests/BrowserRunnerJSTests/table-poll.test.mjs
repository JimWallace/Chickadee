// Unit tests for Public/table-poll.js — the one background table refresh.
//
// It had no unit test: the visual harness's repaint probe proves a repaint
// still respects the sort and the filter, but nothing covered when a repaint
// should happen at all. That is where the cost was. Every five seconds, for as
// long as a dashboard was open, this replaced the whole <tbody> whether or not
// anything had changed — throwing away DOM state the server does not know
// about and rebuilding every derived behaviour from identical input.
//
// So what is pinned here is the decisions: when a poll is skipped, when a
// response is applied, and the order the shared behaviours are re-applied in
// (each depends on the last).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/table-poll.js'), 'utf8');

function makeTable({ url = '/rows?fragment=rows', openDetails = false, contains = false } = {}) {
  const tbody = { innerHTML: '', writes: 0 };
  Object.defineProperty(tbody, 'innerHTML', {
    get() { return this._html || ''; },
    set(v) { this.writes += 1; this._html = v; },
  });
  return {
    id: 'the-table',
    attrs: { 'data-poll-url': url, 'data-poll-interval': '5000' },
    events: [],
    getAttribute(n) { return this.attrs[n] ?? null; },
    querySelector(sel) {
      if (sel === 'tbody') return tbody;
      if (sel === 'details[open]') return openDetails ? {} : null;
      return null;
    },
    contains: () => contains,
    dispatchEvent(e) { this.events.push(e.type); return true; },
    tbody,
  };
}

function load({ table, responses = [], activeElement = null, hidden = false }) {
  const calls = [];
  let index = 0;
  const applied = [];

  const sandbox = {
    document: {
      readyState: 'complete',
      hidden,
      activeElement,
      querySelectorAll: () => [],
      querySelector: () => null,
      addEventListener: () => {},
    },
    module: { exports: {} },
    WeakMap,
    Promise,
    setInterval: () => 0,
    CustomEvent: class { constructor(type) { this.type = type; } },
    fetch: (url, opts) => {
      calls.push({ url, opts });
      const res = responses[Math.min(index, responses.length - 1)];
      index += 1;
      return Promise.resolve({
        status: res.status,
        ok: res.status >= 200 && res.status < 300,
        redirected: false,
        headers: { get: (name) => (name === 'ETag' ? res.etag ?? null : null) },
        text: () => Promise.resolve(res.body ?? ''),
      });
    },
    ChickadeeRelativeTime: { applyRelativeTimes: () => applied.push('relative-time') },
    ChickadeeSortableTable: { apply: () => applied.push('sort') },
    ChickadeeListFilter: { apply: () => applied.push('filter') },
  };
  sandbox.self = sandbox;
  sandbox.window = { location: { reload: () => applied.push('reload') } };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { TablePoll: sandbox.module.exports, calls, applied, table };
}

// ── When a poll is skipped ──────────────────────────────────────────────────

test('a hidden tab does not poll', () => {
  const table = makeTable();
  const h = load({ table, hidden: true, responses: [{ status: 200, body: '<tr></tr>' }] });
  assert.equal(h.TablePoll.shouldSkip(table), true);
});

test('focus inside the table defers the repaint', () => {
  const table = makeTable({ contains: true });
  const h = load({ table, responses: [{ status: 200 }] });
  assert.equal(h.TablePoll.shouldSkip(table), true);
});

// The registration panel on a pending-enrolment row is an open <details>. A
// repaint closes it mid-use, and focus does not cover the case: reading the
// panel, or clicking away to copy a value into it, moves focus off the table
// while the panel is still open and wanted.
test('an open <details> in the table defers the repaint', () => {
  const table = makeTable({ openDetails: true });
  const h = load({ table, responses: [{ status: 200 }] });
  assert.equal(h.TablePoll.shouldSkip(table), true);
});

test('an idle visible table with nothing open does poll', () => {
  const table = makeTable();
  const h = load({ table, responses: [{ status: 200 }] });
  assert.equal(h.TablePoll.shouldSkip(table), false);
});

// ── Conditional fetch ───────────────────────────────────────────────────────

test('the first poll sends no If-None-Match and applies the rows', async () => {
  const table = makeTable();
  const h = load({ table, responses: [{ status: 200, body: '<tr>a</tr>', etag: 'W/"abc"' }] });

  const changed = await h.TablePoll.refresh(table);
  assert.equal(changed, true);
  assert.equal(h.calls[0].opts.headers['If-None-Match'], undefined);
  assert.equal(table.tbody.innerHTML, '<tr>a</tr>');
  assert.deepEqual(h.applied, ['relative-time', 'sort', 'filter']);
  assert.deepEqual(table.events, ['chickadee:table-repaint']);
});

test('the next poll sends the ETag back', async () => {
  const table = makeTable();
  const h = load({
    table,
    responses: [
      { status: 200, body: '<tr>a</tr>', etag: 'W/"abc"' },
      { status: 304 },
    ],
  });

  await h.TablePoll.refresh(table);
  await h.TablePoll.refresh(table);
  assert.equal(h.calls[1].opts.headers['If-None-Match'], 'W/"abc"');
});

test('a 304 changes nothing: no write, no re-apply, no repaint event', async () => {
  const table = makeTable();
  const h = load({
    table,
    responses: [
      { status: 200, body: '<tr>a</tr>', etag: 'W/"abc"' },
      { status: 304 },
    ],
  });

  await h.TablePoll.refresh(table);
  const writesAfterFirst = table.tbody.writes;
  const appliedAfterFirst = h.applied.length;

  const changed = await h.TablePoll.refresh(table);
  assert.equal(changed, false);
  assert.equal(table.tbody.writes, writesAfterFirst, 'the tbody is not rewritten');
  assert.equal(h.applied.length, appliedAfterFirst, 'nothing is re-applied');
  assert.deepEqual(table.events, ['chickadee:table-repaint'], 'the page is not told to redecorate');
});

test('a changed table gets a new ETag and repaints', async () => {
  const table = makeTable();
  const h = load({
    table,
    responses: [
      { status: 200, body: '<tr>a</tr>', etag: 'W/"abc"' },
      { status: 200, body: '<tr>b</tr>', etag: 'W/"def"' },
      { status: 304 },
    ],
  });

  await h.TablePoll.refresh(table);
  await h.TablePoll.refresh(table);
  assert.equal(table.tbody.innerHTML, '<tr>b</tr>');

  await h.TablePoll.refresh(table);
  assert.equal(h.calls[2].opts.headers['If-None-Match'], 'W/"def"', 'the newest ETag is sent');
});

test('the request never uses cache: no-store, which would forbid revalidation', async () => {
  const table = makeTable();
  const h = load({ table, responses: [{ status: 200, body: '', etag: 'W/"x"' }] });
  await h.TablePoll.refresh(table);
  assert.equal(h.calls[0].opts.cache, 'no-cache');
});

test('a poll still declares itself a background refresh', async () => {
  const table = makeTable();
  const h = load({ table, responses: [{ status: 200, body: '', etag: 'W/"x"' }] });
  await h.TablePoll.refresh(table);
  assert.equal(h.calls[0].opts.headers['X-Background-Refresh'], '1');
});

// ── Failure ─────────────────────────────────────────────────────────────────

test('a server error leaves the rows already on screen alone', async () => {
  const table = makeTable();
  const h = load({
    table,
    responses: [
      { status: 200, body: '<tr>a</tr>', etag: 'W/"abc"' },
      { status: 500 },
    ],
  });

  await h.TablePoll.refresh(table);
  const changed = await h.TablePoll.refresh(table);
  assert.equal(changed, false);
  assert.equal(table.tbody.innerHTML, '<tr>a</tr>', 'a transient blip must not blank a roster');
});

test('a 500 does not poison the stored ETag', async () => {
  const table = makeTable();
  const h = load({
    table,
    responses: [
      { status: 200, body: '<tr>a</tr>', etag: 'W/"abc"' },
      { status: 500 },
      { status: 304 },
    ],
  });

  await h.TablePoll.refresh(table);
  await h.TablePoll.refresh(table);
  await h.TablePoll.refresh(table);
  assert.equal(h.calls[2].opts.headers['If-None-Match'], 'W/"abc"');
});
