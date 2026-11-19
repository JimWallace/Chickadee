// Tests/BrowserRunnerJSTests/kernel-asset-editor.test.mjs
//
// The editor half of the cold-load measurement:
//
//   * Public/jl-kernel-diagnostics.js, inside the editor iframe, posts the
//     JupyterLite shell's resource timings (`shell_assets`) just before
//     kernel_idle, so the parent holds them when idle arrives.
//   * Public/notebook.js keeps those timings without forwarding them, and on
//     kernel_idle sends one `asset_load` breadcrumb built by
//     kernel-asset-telemetry.js from its cache probe.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const K = require('../../Public/kernel-asset-telemetry.js');
const collectorSource = await fs.readFile(path.resolve('Public/jl-kernel-diagnostics.js'), 'utf8');
const notebookSource = await fs.readFile(path.resolve('Public/notebook.js'), 'utf8');

test('the collector posts the shell timings, then kernel_idle, once', () => {
  const posted = [];
  const timers = [];
  let bufferSize = null;
  const win = {
    location: { origin: 'https://example.test' },
    parent: { postMessage(payload) { posted.push(payload); } },
    addEventListener() {},
    performance: {
      setResourceTimingBufferSize(n) { bufferSize = n; },
      getEntriesByType: () => [
        { name: 'https://example.test/jupyterlite/build/main.js', transferSize: 0, encodedBodySize: 10, decodedBodySize: 20 },
        { name: 'https://example.test/jupyterlite/xeus/chickadee-python/bin/xpython.wasm', transferSize: 5, encodedBodySize: 5, decodedBodySize: 5 },
        { name: 'https://example.test/jupyterlite/files/users/me/a.ipynb', transferSize: 5, encodedBodySize: 5, decodedBodySize: 5 },
      ],
    },
  };
  const document = {
    body: { textContent: '' },
    addEventListener() {},
    querySelector(sel) {
      return /ExecutionIndicator\[data-status\]/.test(sel) ? { getAttribute: () => 'idle' } : null;
    },
    querySelectorAll() { return { length: 0 }; },
  };
  const context = {
    console, JSON, Error, URL,
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
    clearTimeout() {},
    window: win, document,
  };
  context.globalThis = context;
  vm.runInNewContext(collectorSource, context, { filename: 'jl-kernel-diagnostics.js' });
  assert.equal(bufferSize, 4000);
  timers.shift()();   // the first poll: the kernel is idle
  const kinds = posted.map((p) => p.kind + ':' + (p.source || ''));
  assert.deepEqual(kinds, [
    'kernel_phase:boot_start', 'kernel_phase:kernel_starting', 'shell_assets:', 'kernel_phase:kernel_idle',
  ]);
  const shell = posted.find((p) => p.kind === 'shell_assets');
  assert.deepEqual([...shell.entries.map((e) => e.name)], ['/jupyterlite/build/main.js']);
});

function loadBridge(cachedURLs) {
  const events = [];
  const hooks = {};
  const list = {
    env: 'chickadee-python', version: 'v1', base: '/jupyterlite/xeus/chickadee-python/',
    files: ['bin/xpython.wasm', 'kernel_packages/numpy.tar.gz'], bytes: 10,
  };
  const cache = new Set(cachedURLs);
  const frame = {
    dataset: {
      setupId: 'setup_123', gradingMode: 'browser',
      notebookUrl: '/api/v1/testsetups/setup_123/assignment',
      editorUrl: '/jupyterlite/notebooks/index.html?path=assignment.ipynb',
      kernelAssets: JSON.stringify(list),
    },
    addEventListener() {},
    getAttribute(name) { return name === 'src' ? this.dataset.editorUrl : null; },
    contentWindow: null, contentDocument: null, src: '',
  };
  const elements = new Map([
    ['jl-frame', frame],
    ['nb-status', { textContent: '', className: '' }],
    ['nb-results', { hidden: true, innerHTML: '', appendChild() {}, scrollIntoView() {} }],
  ]);
  const fetch = async (url, init = {}) => {
    if (init.cache === 'only-if-cached') {
      if (!cache.has(url)) throw new TypeError('miss');
      return { ok: true, headers: { get: () => '100' }, body: { cancel() {} } };
    }
    return { ok: true, async json() { return { cells: [] }; } };
  };
  const failures = {
    runPreflight: async () => ({ ok: true, failed: [] }),
    reportEvent: (info) => { events.push(info); },
    reportEditorError() {},
    showFailure() {},
  };
  const context = {
    console, fetch, URL, JSON, Error, Promise,
    document: {
      getElementById(id) { return elements.get(id) ?? null; },
      createElement() { return { className: '', textContent: '', innerHTML: '', appendChild() {} }; },
      addEventListener() {},
      head: { appendChild() {} },
    },
    setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 1, clearInterval: () => {},
    window: {
      location: { origin: 'https://example.test' },
      addEventListener() {},
      matchMedia: null,
      fetch,
      ChickadeeNotebookFailures: failures,
      ChickadeeKernelAssets: K,
    },
    __CHICKADEE_NOTEBOOK_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;
  vm.runInNewContext(notebookSource, context, { filename: 'notebook.js' });
  return { exports: hooks.exports, events, cache };
}

const message = (data) => ({ origin: 'https://example.test', data });

test('the bridge keeps the shell timings and reports one asset_load on kernel_idle', async () => {
  const { exports, events, cache } = loadBridge(['/jupyterlite/xeus/chickadee-python/bin/xpython.wasm']);
  exports.startKernelAssetProbe();
  exports.startKernelAssetProbe();   // once per page load
  const kept = exports.handleKernelDiagMessage(message({
    ck: 'kernel-diag', kind: 'shell_assets',
    entries: [{ name: '/jupyterlite/build/main.js', transferSize: 700, encodedBodySize: 600, decodedBodySize: 600 }],
  }));
  assert.equal(kept, false);
  // The kernel boots and fetches the missing package.
  cache.add('/jupyterlite/xeus/chickadee-python/kernel_packages/numpy.tar.gz');
  exports.handleKernelDiagMessage(message({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle', message: 'elapsed_ms=8000' }));
  exports.handleKernelDiagMessage(message({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle', message: 'elapsed_ms=9000' }));
  for (let i = 0; i < 50; i++) await Promise.resolve();
  const loads = events.filter((e) => e.kind === 'asset_load');
  assert.equal(loads.length, 1);
  assert.equal(loads[0].source, 'editor');
  const fields = Object.fromEntries(loads[0].message.split(';').map((p) => p.split('=')));
  assert.equal(fields.cold, '1');
  assert.equal(fields.net_n, '1');
  assert.equal(fields.cache_n, '1');
  assert.equal(fields.shell_net_bytes, '700');
  assert.equal(fields.boot_ms, '8000');
  assert.equal(events.some((e) => e.kind === 'shell_assets'), false);
});

test('without a kernel list the bridge reports nothing', async () => {
  const { exports, events } = loadBridge([]);
  exports.handleKernelDiagMessage(message({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle', message: 'elapsed_ms=1' }));
  for (let i = 0; i < 20; i++) await Promise.resolve();
  assert.equal(events.filter((e) => e.kind === 'asset_load').length, 0);
});
