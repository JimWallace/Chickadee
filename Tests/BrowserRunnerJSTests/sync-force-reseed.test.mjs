// Tests/BrowserRunnerJSTests/sync-force-reseed.test.mjs
//
// Regression guards for the cache-bust decision logic in
// `Public/notebook.js`'s `shouldForceReseed`.
//
// History:
//   * v0.4.153 introduced cache-busting via `data-working-copy-mtime` on
//     the notebook iframe + a per-setup `chickadee_nb_mtime_<setupID>`
//     in localStorage.  The original decision was
//     `serverMtime > 0 && serverMtime > seenMtime`, which
//     false-positived on every student's first post-deploy visit
//     (seenMtime=0, serverMtime>0 → force-reseed wipes IndexedDB).
//   * v0.4.154 added the baseline-required guard: a missing
//     `seenMtime` (=== 0) is treated as "no baseline yet, do NOT
//     force-reseed."  The localStorage stamp is still written so the
//     *next* visit has a baseline to compare against.
//
// These tests pin the decision so a future tweak doesn't regress to
// the "any-positive-mtime-is-newer" form.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const notebookSource = await fs.readFile(
  path.resolve('Public/notebook.js'),
  'utf8',
);

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

// ----------------------------------------------------------------
// Critical safety cases (v0.4.154)
// ----------------------------------------------------------------

test('shouldForceReseed: first visit after deploy (seenMtime=0, serverMtime>0) → FALSE', async () => {
  // This is THE bug that v0.4.154 fixes.  Without the guard, every
  // existing student's IndexedDB work would be wiped on their first
  // post-v0.4.153-deploy visit.
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 1747106462, seenMtime: 0 }), false,
    'No localStorage baseline → must NOT force-reseed, regardless of server mtime');
});

test('shouldForceReseed: first visit ever (both 0) → FALSE', async () => {
  // Edge case: server hasn't created the working copy yet (rare; the
  // template always seeds before render, but defensive).
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 0, seenMtime: 0 }), false);
});

test('shouldForceReseed: server mtime missing/0 (stat failed) → FALSE', async () => {
  // We never force-reseed when we can't read the server file's mtime,
  // even if localStorage has a previous baseline.
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 0, seenMtime: 1747106462 }), false,
    'Missing server mtime is "no signal", not "newer than my baseline"');
});

// ----------------------------------------------------------------
// Working-as-designed cases
// ----------------------------------------------------------------

test('shouldForceReseed: returning visit, server unchanged → FALSE', async () => {
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 1747106462, seenMtime: 1747106462 }), false,
    'Equal mtimes mean nothing has changed — preserve IndexedDB');
});

test('shouldForceReseed: server mtime older than baseline → FALSE', async () => {
  // Defensive: clock skew or file restore could make server mtime
  // appear older.  Never force-reseed in that case.
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 1747106000, seenMtime: 1747106462 }), false);
});

test('shouldForceReseed: after instructor reset (server mtime > baseline by 1s) → TRUE', async () => {
  // The happy path: the student visited recently (baseline saved),
  // then the instructor clicked Reset, then the student returns.
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 1747106463, seenMtime: 1747106462 }), true);
});

test('shouldForceReseed: after instructor reset (server mtime newer by hours) → TRUE', async () => {
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: 1747200000, seenMtime: 1747106462 }), true);
});

test('shouldForceReseed: negative or NaN inputs → FALSE', async () => {
  // Defensive against parseInt('') = NaN, or somehow getting a
  // negative timestamp out of the file system.
  const { shouldForceReseed } = await loadHarness();
  assert.equal(shouldForceReseed({ serverMtime: -1, seenMtime: 0 }), false);
  assert.equal(shouldForceReseed({ serverMtime: NaN, seenMtime: 100 }), false);
  assert.equal(shouldForceReseed({ serverMtime: 100, seenMtime: NaN }), false);
});
