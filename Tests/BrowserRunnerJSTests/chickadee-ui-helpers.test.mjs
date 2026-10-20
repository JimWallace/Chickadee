// Unit tests for the Public/chickadee-ui.js helpers that #2721 added: the
// `errorMessage` option of fetchJSON, the `el` DOM builder and the
// `wireOnce` guard.
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
      tagName: tag.toUpperCase(), textContent: null, attrs: {},
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

// ── el ──────────────────────────────────────────────────────────────────────

test('el makes the element and sets each attribute', () => {
  const UI = load();
  const node = UI.el('input', { type: 'number', 'class': 'field-input', min: '0' });
  assert.equal(node.tagName, 'INPUT');
  assert.deepEqual({ ...node.attrs }, { type: 'number', class: 'field-input', min: '0' });
  assert.equal(node.textContent, null, 'no text argument, so the text is not set');
});

test('el sets the text when it is given, and an empty string is text', () => {
  const UI = load();
  assert.equal(UI.el('span', { 'class': 'outline-caption' }, 'Task 1').textContent, 'Task 1');
  assert.equal(UI.el('span', null, 0).textContent, 0);
  assert.equal(UI.el('span', null, '').textContent, '');
});

test('el with no attrs sets no attribute', () => {
  const UI = load();
  assert.deepEqual({ ...UI.el('div').attrs }, {});
});

// ── wireOnce ────────────────────────────────────────────────────────────────

test('wireOnce is true the first time for an element, and false after', () => {
  const UI = load();
  const form = {};
  assert.equal(UI.wireOnce(form, 'section-inputs'), true);
  assert.equal(UI.wireOnce(form, 'section-inputs'), false);
  assert.equal(UI.wireOnce({}, 'section-inputs'), true, 'a new element (after a swap) wires again');
});

test('wireOnce keeps one set per purpose', () => {
  const UI = load();
  const block = {};
  assert.equal(UI.wireOnce(block, 'global-inputs'), true);
  assert.equal(UI.wireOnce(block, 'achievements'), true, 'a second job on the same element still wires');
  assert.equal(UI.wireOnce(block, 'achievements'), false);
});

test('wireOnce refuses a missing element', () => {
  const UI = load();
  assert.equal(UI.wireOnce(null, 'x'), false);
  assert.equal(UI.wireOnce(undefined, 'x'), false);
});
