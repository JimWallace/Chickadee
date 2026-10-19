// Unit tests for the Public/chickadee-ui.js helpers that #2721 added: the
// `errorMessage` option of fetchJSON.
//
// The older helpers are covered by chickadee-ui-core.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

function load({ fetchImpl } = {}) {
  const doc = {
    querySelector: () => null,
    createElement: (tag) => ({
      tagName: tag.toUpperCase(), textContent: '', attrs: {},
      setAttribute(name, value) { this.attrs[name] = value; },
    }),
  };
  const sandbox = { document: doc, Promise, JSON, Object, Error, String, WeakSet };
  if (fetchImpl) sandbox.fetch = fetchImpl;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.ChickadeeUI;
}

// ── fetchJSON errorMessage ──────────────────────────────────────────────────

const failing = (status, body) => () => Promise.resolve({ ok: false, status, text: () => Promise.resolve(body) });

test('errorMessage gets the body text and the status, and its result is the message', async () => {
  const seen = [];
  const UI = load({ fetchImpl: failing(404, '{"reason":"gone"}') });
  await assert.rejects(
    () => UI.fetchJSON('/x', {
      errorMessage: (text, status) => { seen.push([text, status]); return 'custom ' + status; },
    }),
    (err) => err instanceof Error && err.message === 'custom 404');
  assert.deepEqual(seen, [['{"reason":"gone"}', 404]]);
});

test('without errorMessage, the server reason is still the message', async () => {
  const UI = load({ fetchImpl: failing(422, '{"reason":"Name is required"}') });
  await assert.rejects(() => UI.fetchJSON('/x'), /^Error: Name is required$/);
});

test('errorMessage is not called on a success', async () => {
  let called = false;
  const UI = load({ fetchImpl: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ a: 1 }) }) });
  const result = await UI.fetchJSON('/x', { errorMessage: () => { called = true; return ''; } });
  assert.deepEqual(result, { a: 1 });
  assert.equal(called, false);
});
