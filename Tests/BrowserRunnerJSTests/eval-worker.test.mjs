// Public/eval-worker.js: the one auto-compute worker for every in-page kernel
// language (#2721).
//
// kernel-worker-drivers.test.mjs drives each language through the eval
// protocol. This file covers what the merge added: the language comes from
// `?lang=`, each language gets the config its own worker file had, only the
// version goes on to the imported scripts, and an unknown language fails at
// once. auto-compute-client.test.mjs pins the worker URL the client builds.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const PUBLIC = path.resolve('Public');

/// Runs a worker script in a fresh context. The vendored bootstrap is not
/// loaded, and `serveEvalWorker` is replaced, after xeus-kernel-shared.js
/// loads, with a fake that keeps the config it is given.
function loadWorker(workerFile, search) {
  const imported = [];
  const served = [];
  const context = { console, crypto: globalThis.crypto, location: { search }, postMessage() {} };
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
