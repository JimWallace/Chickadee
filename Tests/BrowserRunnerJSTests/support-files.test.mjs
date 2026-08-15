// Unit tests for Public/support-files.js — the support-file upload/delete
// widget shared by the two assignment authoring pages.
//
// It had none, and its history is the reason to care: the two pages carried
// near-identical inline copies, the create page's being the stale fork of the
// pair. This file exists to make that one implementation; nothing was checking
// that it stays correct.
//
// Two things here are easy to get wrong in ways no page would show you. An
// upload posts `tier: "support", isTest: false` — get that wrong and the file
// is stored as a TEST and starts being graded. And a failed upload mid-batch
// must not report success, or the author is told a file landed that did not.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/support-files.js'), 'utf8');

function makeEl(id) {
  return {
    id,
    handlers: {},
    files: null,
    value: 'unset',
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
    fire(type, event) { (this.handlers[type] || []).slice().forEach((fn) => fn(event || {})); },
    click() { this.clicked = (this.clicked || 0) + 1; },
    getAttribute() { return null; },
    closest() { return null; },
  };
}

function load({ responses = [], confirmAnswer = true, readFails = false } = {}) {
  const fetches = [];
  const statuses = [];
  const bodyHandlers = {};
  let index = 0;

  const elements = {
    'add-support-file-btn': makeEl('add-support-file-btn'),
    'support-file-upload-input': makeEl('support-file-upload-input'),
    'support-file-upload-status': makeEl('support-file-upload-status'),
  };

  const doc = {
    readyState: 'complete',
    getElementById: (id) => elements[id] || null,
    body: {
      addEventListener(type, fn) { (bodyHandlers[type] ||= []).push(fn); },
    },
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
  };

  const sandbox = {
    document: doc,
    Promise,
    JSON,
    Error,
    // A FileReader that resolves with the file's own text, or fails on demand.
    FileReader: class {
      readAsText(file) {
        if (readFails) {
          setTimeout(() => this.onerror && this.onerror(), 0);
          return;
        }
        this.result = file.text;
        setTimeout(() => this.onload && this.onload(), 0);
      }
    },
    setTimeout: (fn) => { fn(); return 1; },
    fetch: (url, opts) => {
      fetches.push({ url, opts, body: opts && opts.body ? JSON.parse(opts.body) : null });
      const res = responses[Math.min(index, responses.length - 1)] || { ok: true, status: 200 };
      index += 1;
      return Promise.resolve({
        ok: res.ok !== false,
        status: res.status || 200,
        text: () => Promise.resolve(res.body || ''),
      });
    },
  };
  sandbox.ChickadeeUI = {
    setStatus: (_el, msg, kind) => statuses.push({ msg, kind }),
    confirmAction: () => Promise.resolve(confirmAnswer),
    showActionError: (msg) => statuses.push({ msg, kind: 'error' }),
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const changed = [];
  sandbox.window.initSupportFiles({
    csrfToken: 'csrf-token-value',
    uploadURL: () => '/instructor/abc/support-files',
    deleteURL: (name) => '/instructor/abc/support-files/' + name,
    onChange: () => changed.push('changed'),
  });

  return { fetches, statuses, changed, elements, bodyHandlers, sandbox };
}

function file(name, text) { return { name, text }; }

function deleteClick(h, filename) {
  const btn = {
    getAttribute: (n) => (n === 'data-filename' ? filename : null),
    closest: (sel) => (sel === '.js-support-file-delete-btn' ? btn : null),
  };
  const event = { target: { closest: (sel) => (sel === '.js-support-file-delete-btn' ? btn : null) } };
  return Promise.all((h.bodyHandlers.click || []).map((fn) => fn(event)));
}

// The FileReader stub resolves on a real timer (its `setTimeout` binds to the
// host's, not the sandbox's), so settling needs macrotasks, not just
// microtasks — draining only the microtask queue made every upload test see
// zero fetches and look like a code failure.
async function settle() {
  for (let i = 0; i < 4; i += 1) await new Promise((r) => setTimeout(r, 0));
}

// ── Upload ──────────────────────────────────────────────────────────────────

test('an upload posts the file as a SUPPORT entry, not a test', async () => {
  const h = load();
  h.elements['support-file-upload-input'].files = [file('data.csv', 'a,b\n1,2\n')];
  h.elements['support-file-upload-input'].fire('change');
  await settle();

  assert.equal(h.fetches.length, 1);
  const sent = h.fetches[0];
  assert.equal(sent.url, '/instructor/abc/support-files');
  assert.equal(sent.opts.method, 'POST');
  assert.equal(sent.opts.headers['x-csrf-token'], 'csrf-token-value');
  assert.equal(sent.opts.credentials, 'same-origin');
  assert.deepEqual(sent.body, {
    filename: 'data.csv',
    content: 'a,b\n1,2\n',
    tier: 'support',
    isTest: false,
  });
});

test('the Add button opens the file picker rather than posting anything', () => {
  const h = load();
  h.elements['add-support-file-btn'].fire('click');
  assert.equal(h.elements['support-file-upload-input'].clicked, 1);
  assert.equal(h.fetches.length, 0);
});

test('picking nothing does nothing', async () => {
  const h = load();
  h.elements['support-file-upload-input'].files = [];
  h.elements['support-file-upload-input'].fire('change');
  await settle();
  assert.equal(h.fetches.length, 0);
  assert.deepEqual(h.statuses, []);
});

test('every file in a batch is uploaded, and the surface is refreshed once', async () => {
  const h = load();
  h.elements['support-file-upload-input'].files = [
    file('a.csv', 'a'), file('b.csv', 'b'), file('c.csv', 'c'),
  ];
  h.elements['support-file-upload-input'].fire('change');
  await settle();

  assert.deepEqual(h.fetches.map((f) => f.body.filename), ['a.csv', 'b.csv', 'c.csv']);
  assert.deepEqual(h.changed, ['changed'], 'one refresh for the batch, not one per file');
});

test('a failed upload reports the failure and does NOT refresh', async () => {
  const h = load({ responses: [{ ok: false, status: 413, body: 'File too large' }] });
  h.elements['support-file-upload-input'].files = [file('big.csv', 'x')];
  h.elements['support-file-upload-input'].fire('change');
  await settle();

  const last = h.statuses[h.statuses.length - 1];
  assert.equal(last.kind, 'error');
  assert.match(last.msg, /413/);
  assert.deepEqual(h.changed, [], 'a failed upload must not look like a successful one');
});

test('a batch stops at the first failure rather than reporting success', async () => {
  const h = load({ responses: [{ ok: true }, { ok: false, status: 500, body: 'boom' }, { ok: true }] });
  h.elements['support-file-upload-input'].files = [file('a', '1'), file('b', '2'), file('c', '3')];
  h.elements['support-file-upload-input'].fire('change');
  await settle();

  assert.equal(h.fetches.length, 2, 'the third file is not attempted after the second fails');
  assert.equal(h.statuses[h.statuses.length - 1].kind, 'error');
  assert.deepEqual(h.changed, []);
});

test('an unreadable file is reported, not swallowed', async () => {
  const h = load({ readFails: true });
  h.elements['support-file-upload-input'].files = [file('locked.csv', 'x')];
  h.elements['support-file-upload-input'].fire('change');
  await settle();

  assert.equal(h.fetches.length, 0, 'nothing is posted when the read fails');
  assert.equal(h.statuses[h.statuses.length - 1].kind, 'error');
});

test('the picker is cleared after a batch so the same file can be re-picked', async () => {
  const h = load();
  const input = h.elements['support-file-upload-input'];
  input.files = [file('a.csv', 'a')];
  input.fire('change');
  await settle();
  assert.equal(input.value, '');
});

// ── Delete ──────────────────────────────────────────────────────────────────

test('deleting asks first, then DELETEs the named file', async () => {
  const h = load();
  await deleteClick(h, 'data.csv');
  await settle();

  assert.equal(h.fetches.length, 1);
  assert.equal(h.fetches[0].url, '/instructor/abc/support-files/data.csv');
  assert.equal(h.fetches[0].opts.method, 'DELETE');
  assert.equal(h.fetches[0].opts.headers['x-csrf-token'], 'csrf-token-value');
  assert.deepEqual(h.changed, ['changed']);
});

test('cancelling the question deletes nothing', async () => {
  const h = load({ confirmAnswer: false });
  await deleteClick(h, 'data.csv');
  await settle();

  assert.equal(h.fetches.length, 0);
  assert.deepEqual(h.changed, []);
});

test('a failed delete reports it and does not refresh', async () => {
  const h = load({ responses: [{ ok: false, status: 409, body: 'in use' }] });
  await deleteClick(h, 'data.csv');
  await settle();

  assert.equal(h.statuses[h.statuses.length - 1].kind, 'error');
  assert.deepEqual(h.changed, []);
});
