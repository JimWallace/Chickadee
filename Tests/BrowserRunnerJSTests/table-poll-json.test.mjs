// Unit tests for the JSON mode of Public/table-poll.js
// (`data-poll-swap="json"`): the class composite's canvas polls through the
// one poller, so it keeps the shared rules. The body goes to the element as
// a `chickadee:poll-data` event and nothing is swapped; the request asks for
// JSON and carries the background header and the ETag; the first poll runs at
// once.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/table-poll.js'), 'utf8');

function makeFrame() {
  return {
    attrs: { 'data-poll-url': '/testsetups/s/composite', 'data-poll-swap': 'json', 'data-poll-interval': '5000' },
    events: [],
    getAttribute(n) { return this.attrs[n] ?? null; },
    querySelector: () => null,
    contains: () => false,
    dispatchEvent(e) { this.events.push(e); return true; },
  };
}

function load({ frames = [], responses, hidden = false }) {
  const calls = [];
  let index = 0;
  const sandbox = {
    document: {
      readyState: 'complete', hidden, activeElement: null,
      querySelectorAll: () => frames, querySelector: () => null, addEventListener: () => {},
    },
    module: { exports: {} },
    WeakMap, Promise, Number, Date,
    setInterval: () => 0,
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init && init.detail; } },
    fetch: (url, opts) => {
      calls.push({ url, opts });
      const res = responses[Math.min(index, responses.length - 1)];
      index += 1;
      return Promise.resolve({
        status: res.status, ok: res.status >= 200 && res.status < 300, redirected: false,
        headers: { get: (name) => (name === 'ETag' ? res.etag ?? null : null) },
        json: () => Promise.resolve(res.body),
        text: () => Promise.reject(new Error('a JSON poll must not read text')),
      });
    },
  };
  sandbox.self = sandbox;
  sandbox.window = { location: { reload: () => {} } };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { TablePoll: sandbox.module.exports, calls };
}

test('a JSON poll hands the parsed body to the element and swaps nothing', async () => {
  const frame = makeFrame();
  const h = load({ responses: [{ status: 200, body: { cursor: '5', slots: [] }, etag: 'W/"a"' }] });
  assert.equal(await h.TablePoll.refresh(frame), true);
  assert.equal(h.calls[0].opts.headers.Accept, 'application/json');
  assert.equal(h.calls[0].opts.headers['X-Background-Refresh'], '1');
  assert.equal(frame.events.length, 1);
  assert.equal(frame.events[0].type, 'chickadee:poll-data');
  assert.deepEqual(frame.events[0].detail, { cursor: '5', slots: [] });
});

test('a JSON poll is conditional: the ETag goes back, and a 304 sends no event', async () => {
  const frame = makeFrame();
  const h = load({ responses: [{ status: 200, body: {}, etag: 'W/"a"' }, { status: 304 }] });
  await h.TablePoll.refresh(frame);
  assert.equal(await h.TablePoll.refresh(frame), false);
  assert.equal(h.calls[1].opts.headers['If-None-Match'], 'W/"a"');
  assert.equal(frame.events.length, 1);
});

test('a JSON element polls once at load, because the page holds no initial state', async () => {
  const frame = makeFrame();
  const h = load({ frames: [frame], responses: [{ status: 200, body: {} }] });
  assert.equal(h.calls.length, 1);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(frame.events.length, 1);
});

test('a hidden tab skips the first JSON poll too', () => {
  const frame = makeFrame();
  const h = load({ frames: [frame], hidden: true, responses: [{ status: 200, body: {} }] });
  assert.equal(h.calls.length, 0);
});
