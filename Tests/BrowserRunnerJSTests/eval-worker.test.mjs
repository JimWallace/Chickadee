// Public/eval-worker.js: the one auto-compute worker for every in-page kernel
// language (#2721).
//
// kernel-worker-drivers.test.mjs drives each `<language>-eval-worker.js` entry
// file through the eval protocol. This file covers what the merge added: the
// language comes from `?lang=` or from the entry file, each language gets the
// config its own worker file had, only the version goes on to the imported
// scripts, and an unknown language fails at once. It also covers the
// auto-compute client, which must add the version to a worker URL that
// already has a query.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const PUBLIC = path.resolve('Public');

/// Runs a worker script in a fresh context. The vendored bootstrap is not
/// loaded, and `serveEvalWorker` is replaced, after xeus-kernel-shared.js
/// loads, with a fake that keeps the config it is given.
function loadWorker(workerFile, search, entryLanguage) {
  const imported = [];
  const served = [];
  const context = { console, crypto: globalThis.crypto, location: { search }, postMessage() {} };
  if (entryLanguage) context.ChickadeeEvalLanguage = entryLanguage;
  context.self = context;
  context.globalThis = context;
  const vmContext = vm.createContext(context);
  context.importScripts = (url) => {
    imported.push(url);
    const file = url.split('?')[0];
    if (file.startsWith('/vendor/')) return;
    vm.runInContext(fs.readFileSync(path.join(PUBLIC, file), 'utf8'), vmContext, { filename: file });
    if (file === '/xeus-kernel-shared.js') {
      context.ChickadeeXeusKernel.serveEvalWorker = (config) => { served.push(config); };
    }
  };
  vm.runInContext(fs.readFileSync(path.join(PUBLIC, workerFile), 'utf8'), vmContext, { filename: workerFile });
  return { context, imported, served };
}

const LANGUAGES = [
  { lang: 'python', label: 'Python', kernelName: 'xpython', maxWaitMs: 60000, shared: 'ChickadeePythonEvalShared' },
  { lang: 'r', label: 'R', kernelName: 'xr', maxWaitMs: 60000, shared: 'ChickadeeREvalShared' },
  { lang: 'lua', label: 'Lua', kernelName: 'xlua', maxWaitMs: 60000, shared: 'ChickadeeLuaEvalShared' },
  { lang: 'octave', label: 'Octave', kernelName: 'xoctave', maxWaitMs: 90000, shared: 'ChickadeeOctaveEvalShared' },
];

for (const language of LANGUAGES) {
  test(`eval-worker.js?lang=${language.lang} serves the ${language.label} evaluator`, () => {
    const { context, served } = loadWorker('eval-worker.js', `?lang=${language.lang}&v=1.2.3`);
    assert.equal(served.length, 1);
    const config = served[0];
    const shared = context[language.shared];
    assert.equal(config.label, language.label);
    assert.equal(config.kernel.kernelName, language.kernelName);
    assert.equal(config.maxWaitMs, language.maxWaitMs);
    assert.equal(config.makeNonce, shared.makeNonce);
    assert.equal(typeof config.loadCell, 'function');
    assert.equal(typeof config.runExpression, 'function');
    assert.equal(typeof config.callFunction, 'function');
  });

  test(`${language.lang}-eval-worker.js is the same evaluator as eval-worker.js?lang=${language.lang}`, () => {
    const entry = loadWorker(`${language.lang}-eval-worker.js`, '?v=1.2.3');
    const merged = loadWorker('eval-worker.js', `?lang=${language.lang}&v=1.2.3`);
    assert.deepEqual(Object.keys(entry.served[0]).sort(), Object.keys(merged.served[0]).sort());
    assert.equal(entry.served[0].label, language.label);
    assert.equal(entry.served[0].maxWaitMs, language.maxWaitMs);
    assert.deepEqual(entry.imported.slice(1), merged.imported);
  });
}

test('only Python reads a call result, and only the seeded languages boot a runtime', () => {
  const config = (lang) => loadWorker('eval-worker.js', `?lang=${lang}`).served[0];
  assert.equal(typeof config('python').readCallResult, 'function');
  assert.equal(config('python').bootCell, undefined);
  for (const lang of ['r', 'lua', 'octave']) {
    assert.equal(config(lang).readCallResult, undefined, lang);
    assert.equal(typeof config(lang).bootCell, 'function', lang);
  }
  // R runs the seeded runtime as it is.
  assert.equal(config('r').bootCell('RUNTIME'), 'RUNTIME');
});

test('the imported scripts carry the version and not the language', () => {
  const { imported } = loadWorker('eval-worker.js', '?lang=lua&v=0.5.9');
  assert.deepEqual(imported, [
    '/vendor/xeus-bootstrap.js?v=0.5.9',
    '/xeus-kernel-shared.js?v=0.5.9',
    '/grading-shared.js?v=0.5.9',
    '/eval-protocol-shared.js?v=0.5.9',
    '/lua-grading-shared.js?v=0.5.9',
    '/lua-eval-shared.js?v=0.5.9',
  ]);
});

test('with no version, the imported scripts carry no query', () => {
  const { imported } = loadWorker('eval-worker.js', '?lang=r');
  assert.deepEqual(imported.slice(-2), ['/r-grading-shared.js', '/r-eval-shared.js']);
});

test('?lang= wins over the language an entry file set', () => {
  const { imported, served } = loadWorker('eval-worker.js', '?lang=octave', 'lua');
  assert.equal(served[0].label, 'Octave');
  assert.ok(!imported.includes('/lua-eval-shared.js'));
});

test('an unknown or missing language fails before it loads anything', () => {
  for (const search of ['?lang=cobol', '?lang=constructor', '?v=1', '']) {
    const imported = [];
    const context = { location: { search } };
    context.self = context;
    context.importScripts = (url) => imported.push(url);
    vm.createContext(context);
    assert.throws(
      () => vm.runInContext(fs.readFileSync(path.join(PUBLIC, 'eval-worker.js'), 'utf8'), context),
      /no auto-compute worker for language/, search);
    assert.deepEqual(imported, [], search);
  }
});

// ── The auto-compute client's worker URL ────────────────────────────────────

test('the auto-compute client adds the version with & to a worker URL that has a query', async () => {
  const created = [];
  class FakeWorker {
    constructor(url) { this.url = url; created.push(this); }
    addEventListener() {}
    postMessage() {}
    terminate() {}
  }
  const seed = {
    name: 'r', displayName: 'R',
    trueLiteral: 'TRUE', falseLiteral: 'FALSE', nullLiteral: 'NULL',
    autoComputeWorker: '/eval-worker.js?lang=r',
    autoComputeRuntimeSource: '',
  };
  const ctx = {
    console, JSON, Array, Object, Math, Set, Map, Promise, RegExp, String, Boolean, Number, Error,
    setTimeout, clearTimeout,
    Worker: FakeWorker,
    fetch: async () => ({ ok: true, json: async () => ({ cells: [{ cell_type: 'code', source: 'f <- 1' }] }) }),
    document: {
      getElementById: (id) => (id === 'assignment-language-seed' ? { textContent: JSON.stringify(seed) } : null),
      querySelector: (selector) => (selector === 'meta[name="app-version"]' ? { content: '0.5.9' } : null),
    },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(fs.readFileSync(path.join(PUBLIC, 'authoring-language.js'), 'utf8'), ctx);
  vm.runInNewContext(fs.readFileSync(path.join(PUBLIC, 'auto-compute-client.js'), 'utf8'), ctx);

  const client = ctx.ChickadeeAutoCompute.createClient({
    urls: { solutionNotebook: () => '/solution.ipynb' }, timeoutMs: 5, loadTimeoutMs: 5,
  });
  await client.callSolution('f', [], {});
  assert.equal(created.length, 1);
  assert.equal(created[0].url, '/eval-worker.js?lang=r&v=0.5.9');
});
