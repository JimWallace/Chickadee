// Tests/BrowserRunnerJSTests/ensure-parent-dirs.test.mjs
//
// Regression guard for the JupyterLite 0.8 file-save fix in
// `Public/notebook.js`'s `ensureDriveParentDirectories`.
//
// 0.8's `@jupyterlite/contents` `save()` added a parent-must-exist guard: it
// throws `Directory does not exist: <dir>` unless the notebook's parent
// directory is a materialized `directory` entry in the IndexedDB Drive (0.7.x
// auto-created intermediate dirs). Chickadee working copies are nested under
// `users/<uid>/<setup>/`, which nothing created client-side — so the very first
// save (and the editor's own Ctrl-S) threw and students could lose work.
// `ensureDriveParentDirectories` walks the ancestors root→leaf and creates each
// missing one via newUntitled+rename, satisfying the guard.
//
// These tests pin: ordered ancestor creation (the chicken-and-egg the bug is
// about — never newUntitled into a not-yet-created parent), idempotency,
// partial pre-existence, fail-safety, and the bad-input no-op.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const notebookSource = await fs.readFile(path.resolve('Public/notebook.js'), 'utf8');

async function loadHarness() {
  const hooks = {};
  const elements = new Map();
  const frame = {
    dataset: {
      setupId: 'setup_123',
      gradingMode: 'browser',
      notebookUrl: '/api/v1/testsetups/setup_123/assignment',
      editorUrl: '/jupyterlite/notebooks/index.html?path=assignment.ipynb',
    },
    addEventListener() {},
    getAttribute(name) { return name === 'src' ? this.dataset.editorUrl : null; },
    contentWindow: null,
    contentDocument: null,
    src: '',
  };
  elements.set('jl-frame', frame);
  elements.set('nb-status', { textContent: '', className: '' });
  elements.set('nb-results', { hidden: true, innerHTML: '', appendChild() {}, scrollIntoView() {} });

  const document = {
    getElementById(id) { return elements.get(id) ?? null; },
    createElement() { return { className: '', textContent: '', innerHTML: '', appendChild() {} }; },
    head: { appendChild() {} },
  };

  const context = {
    console,
    document,
    fetch: async () => ({ ok: true, async json() { return { cells: [] }; } }),
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval: () => {},
    URL, JSON, Error, Promise,
    window: { location: { origin: 'https://example.test' } },
    __CHICKADEE_NOTEBOOK_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;
  vm.runInNewContext(notebookSource, context, { filename: 'notebook.js' });
  return hooks.exports;
}

// A fake JupyterLite contents manager backed by a Map that replicates 0.8's
// guard: newUntitled into a non-existent parent throws, exactly as
// @jupyterlite/contents 0.8 does. `created` logs the final dir paths in order.
function fakeContents() {
  const store = new Map();   // path -> { type }
  let untitledN = 0;
  return {
    store,
    created: [],
    async get(p) {
      if (store.has(p)) return { type: store.get(p).type, path: p };
      throw new Error('404');                       // missing -> reject (helper .catch -> null)
    },
    async newUntitled({ path: parent, type }) {
      if (parent && !store.has(parent)) {
        throw new Error(`Directory does not exist: ${parent}`);   // the 0.8 parent guard
      }
      const name = `Untitled Folder${untitledN++ || ''}`;
      const full = parent ? `${parent}/${name}` : name;
      store.set(full, { type });
      return { path: full, type };
    },
    async rename(from, to) {
      store.set(to, store.get(from));
      store.delete(from);
      this.created.push(to);
    },
  };
}

test('ensureDriveParentDirectories: creates every missing ancestor root→leaf, exact names', async () => {
  const { ensureDriveParentDirectories } = await loadHarness();
  const fc = fakeContents();
  await ensureDriveParentDirectories(fc, 'users/abc/setup_9/assignment.ipynb');
  // Proves it never calls newUntitled into a not-yet-created parent (the bug),
  // and stops before the filename.
  assert.deepEqual(fc.created, ['users', 'users/abc', 'users/abc/setup_9']);
});

test('ensureDriveParentDirectories: idempotent when every ancestor already exists', async () => {
  const { ensureDriveParentDirectories } = await loadHarness();
  const fc = fakeContents();
  for (const d of ['users', 'users/abc', 'users/abc/setup_9']) fc.store.set(d, { type: 'directory' });
  await ensureDriveParentDirectories(fc, 'users/abc/setup_9/assignment.ipynb');
  assert.deepEqual(fc.created, []);   // nothing re-created
});

test('ensureDriveParentDirectories: only creates the missing tail when some exist', async () => {
  const { ensureDriveParentDirectories } = await loadHarness();
  const fc = fakeContents();
  fc.store.set('users', { type: 'directory' });
  await ensureDriveParentDirectories(fc, 'users/abc/setup_9/assignment.ipynb');
  assert.deepEqual(fc.created, ['users/abc', 'users/abc/setup_9']);
});

test('ensureDriveParentDirectories: fail-safe — never rejects when the Drive errors', async () => {
  const { ensureDriveParentDirectories } = await loadHarness();
  const fc = fakeContents();
  fc.newUntitled = async () => { throw new Error('Drive exploded'); };
  await assert.doesNotReject(
    ensureDriveParentDirectories(fc, 'users/abc/setup_9/assignment.ipynb'));
});

test('ensureDriveParentDirectories: no-op on bad input', async () => {
  const { ensureDriveParentDirectories } = await loadHarness();
  const fc = fakeContents();
  await assert.doesNotReject(ensureDriveParentDirectories(null, 'a/b.ipynb'));
  await ensureDriveParentDirectories(fc, '');
  assert.deepEqual(fc.created, []);
});
