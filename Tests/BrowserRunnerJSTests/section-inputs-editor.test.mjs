// Unit tests for Public/section-inputs-editor.js — the per-section inputs
// panels on the assignment edit page.
//
// Most of its mechanics live in the shared core (inputs-editor-core.js, which
// has its own suite). What is only here is the wiring, and the wiring is where
// an author's work can be lost:
//
//   * the panel auto-saves on a debounce, so the assignment's main Save must
//     flush it first — and flush EVERY section's form, not just one. A miss
//     means the author's last edit to that section never reaches the server,
//     with a successful-looking save on screen.
//   * the section form must never navigate on submit; it is not the page's
//     form.
//   * a failed save must not announce success to the workbench pane, which
//     would tell a notebook to re-render values the server never took.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/section-inputs-editor.js'), 'utf8');

function makeForm(sectionID, { action = '/instructor/x/suite-sections/' + sectionID + '/variables' } = {}) {
  const tbody = { rows: [], id: 'tbody-' + sectionID };
  const form = {
    action,
    attrs: { 'data-section-id': sectionID },
    handlers: {},
    tbody,
    getAttribute: (n) => form.attrs[n] ?? null,
    querySelector: (sel) => (sel === 'tbody.js-section-vars-body' ? tbody : null),
    addEventListener(type, fn) { (form.handlers[type] ||= []).push(fn); },
    fire(type, event) { (form.handlers[type] || []).slice().forEach((fn) => fn(event)); },
    contains: () => true,
  };
  return form;
}

function load({ forms, payload = { variables: [{ name: 'n', value: '1' }] }, response = { ok: true } } = {}) {
  const fetches = [];
  const notified = [];
  const errors = [];
  const scheduled = [];
  let flushImpl;

  const doc = {
    readyState: 'complete',
    querySelectorAll: (sel) => {
      if (sel === 'form.section-vars-form') return forms;
      if (sel === 'button.js-section-var-add') return [];
      return [];
    },
    querySelector: () => null,
    addEventListener() {},
  };

  const sandbox = {
    document: doc,
    Promise,
    JSON,
    Array,
    Error,
    console: { error: (...a) => errors.push(a.join(' ')) },
    fetch: (url, opts) => {
      fetches.push({ url, opts, body: JSON.parse(opts.body) });
      return Promise.resolve({
        ok: response.ok !== false,
        status: response.status || 200,
        type: response.type || 'basic',
        text: () => Promise.resolve(response.body || ''),
      });
    },
  };
  // The shared core, stubbed: its own behaviour is covered by
  // inputs-editor-core.test.mjs, so this file only needs its seams.
  sandbox.ChickadeeInputsCore = {
    createEditor: () => ({
      buildPayload: () => payload,
      refreshAllRows: () => {},
      addEmptyRow: () => {},
    }),
    // A saver that records scheduling and lets the test drive the flush,
    // so the debounce timer is not what these assertions depend on.
    makeDebouncedSaver: (doPost) => {
      flushImpl = doPost;
      return {
        schedule: () => scheduled.push('scheduled'),
        flush: () => doPost(),
      };
    },
  };
  sandbox.ChickadeeUI = {
    getCsrfToken: () => 'csrf-token-value',
    notifyWorkbench: (what) => notified.push(what),
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  return { fetches, notified, errors, scheduled, sandbox, flushImpl: () => flushImpl };
}

async function settle() {
  for (let i = 0; i < 6; i += 1) await Promise.resolve();
}

// ── The flush contract ──────────────────────────────────────────────────────

test('the page-level flush covers EVERY section form, not just one', async () => {
  const forms = [makeForm('sec-a'), makeForm('sec-b'), makeForm('sec-c')];
  const h = load({ forms });

  await h.sandbox.window.chickadeeFlushSectionVars();
  await settle();

  assert.deepEqual(h.fetches.map((f) => f.url), [
    '/instructor/x/suite-sections/sec-a/variables',
    '/instructor/x/suite-sections/sec-b/variables',
    '/instructor/x/suite-sections/sec-c/variables',
  ], 'a missed form is an edit silently dropped behind a successful-looking save');
});

test('the flush is awaitable, so the assignment save can wait on it', async () => {
  const h = load({ forms: [makeForm('sec-a')] });
  const result = h.sandbox.window.chickadeeFlushSectionVars();
  assert.ok(result && typeof result.then === 'function');
  await result;
});

test('a page with no section panels still exposes a flush that resolves', async () => {
  const h = load({ forms: [] });
  await h.sandbox.window.chickadeeFlushSectionVars();
  assert.deepEqual(h.fetches, []);
});

test('a form with no rows body flushes to a no-op rather than throwing', async () => {
  const form = makeForm('sec-a');
  form.querySelector = () => null;
  const h = load({ forms: [form] });
  await h.sandbox.window.chickadeeFlushSectionVars();
  assert.deepEqual(h.fetches, []);
});

test('nothing is posted when the editor has no payload to send', async () => {
  const h = load({ forms: [makeForm('sec-a')], payload: null });
  await h.sandbox.window.chickadeeFlushSectionVars();
  assert.deepEqual(h.fetches, []);
});

// ── The request ─────────────────────────────────────────────────────────────

test('the save posts JSON to the form action with the CSRF header', async () => {
  const h = load({ forms: [makeForm('sec-a')] });
  await h.sandbox.window.chickadeeFlushSectionVars();

  const sent = h.fetches[0];
  assert.equal(sent.opts.method, 'POST');
  assert.equal(sent.opts.headers['Content-Type'], 'application/json');
  assert.equal(sent.opts.headers['x-csrf-token'], 'csrf-token-value');
  assert.deepEqual(sent.body, { variables: [{ name: 'n', value: '1' }] });
});

test('a successful save tells the workbench its values are stale', async () => {
  const h = load({ forms: [makeForm('sec-a')] });
  await h.sandbox.window.chickadeeFlushSectionVars();
  await settle();
  assert.deepEqual(h.notified, ['inputs-changed']);
});

test('a failed save is reported and does NOT announce success', async () => {
  const h = load({
    forms: [makeForm('sec-a')],
    response: { ok: false, status: 422, body: 'bad name' },
  });
  await h.sandbox.window.chickadeeFlushSectionVars();
  await settle();

  assert.deepEqual(h.notified, [], 'a notebook must not re-render values the server rejected');
  assert.equal(h.errors.length, 1);
  assert.match(h.errors[0], /422/);
});

// A same-origin redirect answer is how the endpoint replies to a normal form
// post; with redirect: 'manual' that surfaces as an opaque response, which is
// success, not failure.
test('an opaque redirect counts as a successful save', async () => {
  const h = load({
    forms: [makeForm('sec-a')],
    response: { ok: false, status: 0, type: 'opaqueredirect' },
  });
  await h.sandbox.window.chickadeeFlushSectionVars();
  await settle();

  assert.deepEqual(h.notified, ['inputs-changed']);
  assert.deepEqual(h.errors, []);
});

// ── Form behaviour ──────────────────────────────────────────────────────────

test('submitting a section form saves in place rather than navigating', async () => {
  const forms = [makeForm('sec-a')];
  const h = load({ forms });
  let prevented = false;

  forms[0].fire('submit', { preventDefault: () => { prevented = true; } });
  await settle();

  assert.equal(prevented, true, 'the section panel is not the page form');
  assert.equal(h.fetches.length, 1, 'and the edit is saved rather than dropped');
});

test('editing a row schedules a save; editing elsewhere does not', () => {
  const forms = [makeForm('sec-a')];
  const h = load({ forms });

  forms[0].fire('input', { target: { closest: (sel) => (sel === 'tr.js-section-var-row' ? {} : null) } });
  assert.equal(h.scheduled.length, 1);

  forms[0].fire('input', { target: { closest: () => null } });
  assert.equal(h.scheduled.length, 1, 'an unrelated input must not schedule a section save');
});

test('removing a row drops it and schedules a save', () => {
  const forms = [makeForm('sec-a')];
  const h = load({ forms });
  let removed = false;
  const tr = { remove: () => { removed = true; } };
  const btn = { closest: (sel) => (sel === 'tr.js-section-var-row' ? tr : null) };

  forms[0].fire('click', { target: { closest: (sel) => (sel === '.js-section-var-remove' ? btn : null) } });

  assert.equal(removed, true);
  assert.equal(h.scheduled.length, 1);
});
