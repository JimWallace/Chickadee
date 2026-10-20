// Unit tests for the course dataset library controls in Public/support-files.js
// (docs/datasets-course-library.md §4.5, slice 5b).
//
// What is pinned is the request each control sends: the action, its body, the
// confirm before a detach or a remove, the scope box put back after a refusal,
// and the surface re-render after a success. A page with no `libraryURL` (the
// create page) binds nothing.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/support-files.js'), 'utf8');

/// One control element with the given class and data-filename.
function makeControl(className, filename = null) {
  const el = {
    checked: false,
    classList: { contains: (name) => name === className },
    getAttribute: (name) => (name === 'data-filename' ? filename : null),
  };
  el.closest = (selector) => (selector.split(',').some((s) => s.trim() === '.' + className) ? el : null);
  return el;
}

function load({ withLibrary = true, confirm = true, fail = null, selectValue = 'ward-cases' } = {}) {
  const posts = [];
  const bodyHandlers = {};
  let changes = 0;
  const select = { value: selectValue };
  const doc = {
    readyState: 'complete',
    getElementById: () => null,
    body: { addEventListener(type, fn) { (bodyHandlers[type] ||= []).push(fn); } },
    addEventListener() {},
    querySelector: (sel) => (sel === '.js-library-attach-select' ? select : null),
    querySelectorAll: () => [],
  };
  const errors = [];
  const sandbox = { document: doc, Promise, JSON, Error, Object, Array, Math, parseInt, setTimeout };
  sandbox.ChickadeeUI = {
    setStatus: () => {},
    showActionError: (message) => errors.push(message),
    confirmAction: () => Promise.resolve(confirm),
    fetchJSON: (url, opts) => {
      if (opts && opts.method === 'POST') {
        posts.push({ url, body: JSON.parse(JSON.stringify(opts.body)) });
        if (fail) return Promise.reject(new Error(fail));
      }
      return Promise.resolve({ datasets: [], diagnostics: [] });
    },
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const config = {
    uploadURL: () => '/u',
    deleteURL: () => '/d',
    onChange: () => { changes += 1; },
  };
  if (withLibrary) config.libraryURL = (op) => '/instructor/abc/datasets/library/' + op;
  sandbox.window.initSupportFiles(config);

  return { posts, bodyHandlers, errors, changes: () => changes };
}

async function fire(h, type, target) {
  await Promise.all((h.bodyHandlers[type] || []).map((fn) => fn({ target })));
  for (let i = 0; i < 6; i += 1) await new Promise((r) => setTimeout(r, 0));
}

test('attach sends the selected dataset and re-renders the surface', async () => {
  const h = load();
  await fire(h, 'click', makeControl('js-library-attach'));
  assert.deepEqual(h.posts, [{ url: '/instructor/abc/datasets/library/attach', body: { slug: 'ward-cases' } }]);
  assert.equal(h.changes(), 1);
});

test('update, detach and promote each name their file', async () => {
  const h = load();
  await fire(h, 'click', makeControl('js-library-update', 'lib.csv'));
  await fire(h, 'click', makeControl('js-library-detach', 'lib.csv'));
  await fire(h, 'click', makeControl('js-library-promote', 'cases.csv'));
  assert.deepEqual(h.posts.map((p) => [p.url.split('/').pop(), p.body]), [
    ['update', { file: 'lib.csv' }],
    ['detach', { file: 'lib.csv' }],
    ['promote', { file: 'cases.csv' }],
  ]);
});

test('remove on an attached file detaches it and removes the file', async () => {
  const h = load();
  await fire(h, 'click', makeControl('js-library-remove', 'lib.csv'));
  assert.deepEqual(h.posts[0].body, { file: 'lib.csv', removeFile: true });
});

test('a declined confirm stops a remove, and a detach asks no confirm', async () => {
  const h = load({ confirm: false });
  await fire(h, 'click', makeControl('js-library-remove', 'lib.csv'));
  assert.equal(h.posts.length, 0);
  // A detach keeps the file and its sample, so it is easy to undo.
  await fire(h, 'click', makeControl('js-library-detach', 'lib.csv'));
  assert.deepEqual(h.posts.map((p) => p.body), [{ file: 'lib.csv' }]);
});

test('the scope box sends its state, and a refusal puts it back', async () => {
  const h = load({ fail: 'refused' });
  const box = makeControl('js-library-scope', 'lib.csv');
  box.checked = false;
  await fire(h, 'change', box);
  assert.deepEqual(h.posts[0].body, { file: 'lib.csv', courseScoped: false });
  assert.equal(box.checked, true);
  assert.equal(h.errors.length, 1);
  assert.equal(h.changes(), 0);
});

test('a page without libraryURL binds no library control', async () => {
  const h = load({ withLibrary: false });
  await fire(h, 'click', makeControl('js-library-attach'));
  await fire(h, 'click', makeControl('js-library-promote', 'cases.csv'));
  assert.equal(h.posts.length, 0);
});
