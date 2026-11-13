// Tests for the identical-markup rule of a region swap in Public/table-poll.js.
//
// The result page's pending band is a `role="status"` region. The first poll
// has no ETag, so the server answers 200 even when the state has not changed.
// Rewriting the region with the same text makes a screen reader announce it
// again, so a region that already shows the markup is left alone.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/table-poll.js'), 'utf8');

function makeRegion(initialHTML) {
  const region = {
    attrs: {
      'data-poll-url': '/submissions/s1?fragment=state',
      'data-poll-interval': '2000',
      'data-poll-swap': 'region',
    },
    writes: 0,
    events: [],
    _html: initialHTML,
    getAttribute(n) { return this.attrs[n] ?? null; },
    querySelector() { return null; },
    contains: () => false,
    dispatchEvent(e) { this.events.push(e.type); return true; },
  };
  Object.defineProperty(region, 'innerHTML', {
    get() { return this._html || ''; },
    set(v) { this.writes += 1; this._html = v; },
  });
  return region;
}

function load(responses) {
  let index = 0;
  const sandbox = {
    document: {
      readyState: 'complete',
      hidden: false,
      activeElement: null,
      querySelectorAll: () => [],
      querySelector: () => null,
      addEventListener: () => {},
    },
    module: { exports: {} },
    WeakMap,
    Promise,
    setInterval: () => 0,
    CustomEvent: class { constructor(type) { this.type = type; } },
    fetch: () => {
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
  };
  sandbox.self = sandbox;
  sandbox.window = { location: { reload: () => {} } };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

const queued = '<div class="spinner"></div><p>Queued</p>';
const grading = '<div class="spinner"></div><p>Grading</p>';

test('a region that already shows the markup is not rewritten', async () => {
  const region = makeRegion(queued);
  const poll = load([{ status: 200, body: queued, etag: 'W/"q"' }]);

  const changed = await poll.refresh(region);
  assert.equal(changed, false);
  assert.equal(region.writes, 0, 'no write, so no second announcement');
  assert.deepEqual(region.events, [], 'no repaint event');
});

test('a region whose markup changed is still swapped', async () => {
  const region = makeRegion(queued);
  const poll = load([{ status: 200, body: grading, etag: 'W/"g"' }]);

  const changed = await poll.refresh(region);
  assert.equal(changed, true);
  assert.equal(region.writes, 1);
  assert.equal(region.innerHTML, grading);
  assert.deepEqual(region.events, ['chickadee:table-repaint']);
});
