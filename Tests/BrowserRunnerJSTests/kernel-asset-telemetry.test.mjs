// Tests/BrowserRunnerJSTests/kernel-asset-telemetry.test.mjs
//
// Public/kernel-asset-telemetry.js measures how much of a kernel boot came
// over the network and warms the HTTP cache before class; Public/
// kernel-prewarm.js wires the warm onto the dashboard. These pin the
// classification of a resource timing entry, the editor's cache probe, the
// warm's skip rules and its "once per kernel version" marker, the message
// format AssetLoadStats.swift parses, and that the prewarm script fetches
// exactly the server's URLs with the kernel's own credentials.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const K = require('../../Public/kernel-asset-telemetry.js');

const LIST = {
  env: 'chickadee-python',
  version: 'abc123',
  base: '/jupyterlite/xeus/chickadee-python/',
  files: ['bin/xpython.js', 'bin/xpython.wasm', 'kernel_packages/numpy.tar.gz'],
  bytes: 100,
};

function fields(message) {
  return Object.fromEntries(message.split(';').map((p) => p.split('=')));
}

test('a list parses from the data attribute, and anything else is null', () => {
  assert.deepEqual(K.parseList(JSON.stringify(LIST)), LIST);
  assert.equal(K.parseList(''), null);
  assert.equal(K.parseList('not json'), null);
  assert.equal(K.parseList(JSON.stringify({ env: 'x' })), null);
  assert.equal(K.parseList(JSON.stringify({ ...LIST, files: [] })), null);
  assert.deepEqual(K.parseLists(JSON.stringify([LIST, { env: 1 }])), [LIST]);
  assert.deepEqual(K.parseLists('{}'), []);
});

test('the URLs are the base plus each file', () => {
  assert.deepEqual(K.assetURLs(LIST), [
    '/jupyterlite/xeus/chickadee-python/bin/xpython.js',
    '/jupyterlite/xeus/chickadee-python/bin/xpython.wasm',
    '/jupyterlite/xeus/chickadee-python/kernel_packages/numpy.tar.gz',
  ]);
});

test('a timing entry is network, cache, a revalidation (cache), or unknown', () => {
  assert.deepEqual(K.classify({ transferSize: 0, encodedBodySize: 50, decodedBodySize: 80 }), { kind: 'cache', bytes: 50 });
  assert.deepEqual(K.classify({ transferSize: 300, encodedBodySize: 5000, decodedBodySize: 5000 }), { kind: 'cache', bytes: 5000 });
  assert.deepEqual(K.classify({ transferSize: 5300, encodedBodySize: 5000, decodedBodySize: 9000 }), { kind: 'network', bytes: 5300 });
  assert.deepEqual(K.classify({ transferSize: 0, encodedBodySize: 0, decodedBodySize: 0 }), { kind: 'unknown', bytes: 0 });
  assert.deepEqual(K.classify({ name: 'x' }), { kind: 'unknown', bytes: 0 });
});

test('a summary counts only the paths its predicate accepts', () => {
  const entries = [
    { name: 'https://h/jupyterlite/xeus/chickadee-python/bin/xpython.wasm', transferSize: 4000, encodedBodySize: 3900, decodedBodySize: 15000 },
    { name: 'https://h/jupyterlite/xeus/chickadee-python/kernel_packages/a.tar.gz', transferSize: 0, encodedBodySize: 100, decodedBodySize: 100 },
    { name: 'https://h/jupyterlite/build/main.js', transferSize: 900, encodedBodySize: 800, decodedBodySize: 800 },
    { name: 'https://h/jupyterlite/files/users/me/a.ipynb', transferSize: 10, encodedBodySize: 5, decodedBodySize: 5 },
  ];
  assert.deepEqual(K.summarize(entries, K.isKernelPath), {
    netBytes: 4000, cacheBytes: 100, netCount: 1, cacheCount: 1, unknownCount: 0,
  });
  const shell = K.summarize(entries, K.isShellPath);
  assert.equal(shell.netBytes, 900);
  assert.equal(shell.netCount, 1);
});

test('plain entries keep the path and the three sizes only', () => {
  const out = K.plainEntries([
    { name: 'https://h/jupyterlite/xeus/e/bin/x.wasm', transferSize: 1, encodedBodySize: 2, decodedBodySize: 3, serverTiming: [] },
    { name: 'https://h/other.js', transferSize: 1, encodedBodySize: 1, decodedBodySize: 1 },
  ], K.isKernelPath);
  assert.deepEqual(out, [{ name: '/jupyterlite/xeus/e/bin/x.wasm', transferSize: 1, encodedBodySize: 2, decodedBodySize: 3 }]);
});

test('the grading message carries cold, the byte counts and the boot time', () => {
  const message = K.gradingMessage([
    { name: '/jupyterlite/xeus/chickadee-python/bin/xpython.wasm', transferSize: 4000, encodedBodySize: 3900, decodedBodySize: 15000 },
  ], 8123.4);
  assert.deepEqual(fields(message), {
    cold: '1', net_bytes: '4000', cache_bytes: '0', net_n: '1', cache_n: '0', boot_ms: '8123',
  });
  const warm = fields(K.gradingMessage([
    { name: '/jupyterlite/xeus/chickadee-python/bin/xpython.wasm', transferSize: 0, encodedBodySize: 3900, decodedBodySize: 15000 },
  ], 10));
  assert.equal(warm.cold, '0');
  // No kernel entries at all: nothing known, so no `cold`.
  assert.equal(fields(K.gradingMessage([], 10)).cold, undefined);
});

test('a message drops absent fields and is capped', () => {
  assert.equal(K.formatMessage({ a: 1, b: undefined, c: null, d: '', e: 0 }), 'a=1;e=0');
  assert.equal(K.formatMessage({ a: 'x'.repeat(2000) }).length, 1000);
});

test('elapsed_ms is read from a kernel_idle message', () => {
  assert.equal(K.elapsedFrom('elapsed_ms=8100;recovered=1;unhealthy_ms=40'), 8100);
  assert.equal(K.elapsedFrom('recovered=1'), null);
  assert.equal(K.elapsedFrom(undefined), null);
});

// A fake HTTP cache. `only-if-cached` resolves from it or fails, as the
// engines do; any other request "downloads" the file into it.
function fakeCache(cached, sizes) {
  const calls = [];
  const fetch = async (url, init = {}) => {
    calls.push({ url, init });
    if (init.cache === 'only-if-cached') {
      if (!cached.has(url)) throw new TypeError('Failed to fetch');
      return {
        ok: true,
        headers: { get: (h) => (h === 'content-length' ? String(sizes[url] ?? '') : null) },
        body: { cancel() {} },
      };
    }
    cached.add(url);
    return { ok: true, body: null, arrayBuffer: async () => new ArrayBuffer(0) };
  };
  return { fetch, calls };
}

test('the editor probe reports the files the boot fetched as network bytes', async () => {
  const [js, wasm, pkg] = K.assetURLs(LIST);
  const cache = new Set([js]);
  const { fetch, calls } = fakeCache(cache, { [js]: 700, [wasm]: 4000, [pkg]: 300 });
  const probe = K.editorProbe(LIST, fetch);
  await probe.before;
  // The kernel boots and fetches the rest.
  cache.add(wasm);
  cache.add(pkg);
  const message = await probe.finish({
    bootMs: 9000,
    shellEntries: [{ name: '/jupyterlite/build/main.js', transferSize: 0, encodedBodySize: 50, decodedBodySize: 50 }],
  });
  assert.deepEqual(fields(message), {
    cold: '1', net_bytes: '4300', cache_bytes: '700', net_n: '2', cache_n: '1',
    shell_net_bytes: '0', shell_cache_bytes: '50', boot_ms: '9000', env: 'chickadee-python',
  });
  // Every probe asked the cache only, with the kernel's credentials.
  assert.ok(calls.every((c) => c.init.cache === 'only-if-cached' && c.init.credentials === 'same-origin'));
});

test('a fully cached boot is warm and probes nothing twice', async () => {
  const urls = K.assetURLs(LIST);
  const { fetch, calls } = fakeCache(new Set(urls), {});
  const probe = K.editorProbe(LIST, fetch);
  const message = fields(await probe.finish({ bootMs: 3000 }));
  assert.equal(message.cold, '0');
  assert.equal(message.net_n, '0');
  assert.equal(calls.length, urls.length);
});

test('an engine that ignores only-if-cached reports the probe as unsupported, with no cold', async () => {
  const fetch = async () => { throw new TypeError('unsupported'); };
  const probe = K.editorProbe(LIST, fetch);
  const message = fields(await probe.finish({ bootMs: 3000 }));
  assert.equal(message.probe, 'unsupported');
  assert.equal(message.cold, undefined);
  assert.equal(message.boot_ms, '3000');
});

test('the warm skips a data-saving or 2G connection and a recently warmed version', () => {
  const store = new Map();
  const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  const now = 1_000_000_000_000;
  assert.deepEqual(K.warmPlan([LIST], { saveData: true }, storage, now), []);
  assert.deepEqual(K.warmPlan([LIST], { effectiveType: '2g' }, storage, now), []);
  assert.deepEqual(K.warmPlan([LIST], { effectiveType: '4g' }, storage, now), [LIST]);
  assert.deepEqual(K.warmPlan([LIST], null, null, now), [LIST]);
  store.set(K.WARMED_KEY_PREFIX + LIST.env, LIST.version + '|' + now);
  assert.deepEqual(K.warmPlan([LIST], null, storage, now + 1000), []);
  // A new kernel version warms again, and so does an old marker (eviction).
  assert.equal(K.warmPlan([{ ...LIST, version: 'new' }], null, storage, now).length, 1);
  assert.equal(K.warmPlan([LIST], null, storage, now + K.REWARM_AFTER_MS).length, 1);
  // A malformed marker warms.
  store.set(K.WARMED_KEY_PREFIX + LIST.env, LIST.version);
  assert.equal(K.warmPlan([LIST], null, storage, now).length, 1);
  // A storage that throws (blocked site data) warms rather than failing.
  const throwing = { getItem() { throw new Error('blocked'); } };
  assert.deepEqual(K.warmPlan([LIST], null, throwing, now), [LIST]);
});

test('a warm fetches every file in order and marks the version only when all arrive', async () => {
  const store = new Map();
  const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  const { fetch, calls } = fakeCache(new Set(), {});
  assert.equal(await K.warmList(LIST, fetch, storage, 42), true);
  assert.deepEqual(calls.map((c) => c.url), K.assetURLs(LIST));
  assert.ok(calls.every((c) => c.init.credentials === 'same-origin' && c.init.cache === undefined));
  assert.equal(store.get(K.WARMED_KEY_PREFIX + LIST.env), LIST.version + '|42');

  store.clear();
  let n = 0;
  const failing = async () => (++n === 2 ? { ok: false } : { ok: true, body: null, arrayBuffer: async () => null });
  assert.equal(await K.warmList(LIST, failing, storage), false);
  assert.equal(n, 2);
  assert.equal(store.size, 0);
});

test('a warm reads a streamed body to the end', async () => {
  let reads = 0;
  const fetch = async () => ({
    ok: true,
    body: { getReader: () => ({ read: async () => (++reads < 3 ? { done: false, value: new Uint8Array(1) } : { done: true }) }) },
  });
  assert.equal(await K.warmList({ ...LIST, files: ['bin/xpython.wasm'] }, fetch, null), true);
  assert.equal(reads, 3);
});

test('the prewarm message counts only this list’s files', () => {
  const message = fields(K.prewarmMessage(LIST, [
    { name: 'https://h/jupyterlite/xeus/chickadee-python/bin/xpython.wasm', transferSize: 4000, encodedBodySize: 3900, decodedBodySize: 1 },
    { name: 'https://h/jupyterlite/xeus/chickadee-r/bin/xr.wasm', transferSize: 9999, encodedBodySize: 9000, decodedBodySize: 1 },
  ], 1234));
  assert.equal(message.net_bytes, '4000');
  assert.equal(message.warm_ms, '1234');
  assert.equal(message.env, 'chickadee-python');
});

test('report posts one asset_load breadcrumb with the CSRF token, and never throws', () => {
  const posts = [];
  const prior = { fetch: globalThis.fetch, ChickadeeUI: globalThis.ChickadeeUI };
  globalThis.fetch = (url, init) => { posts.push({ url, init }); return Promise.resolve({}); };
  globalThis.ChickadeeUI = { getCsrfToken: () => 'tok' };
  try {
    K.report('editor', 'cold=1', 'setup_1');
    K.report('editor', '', 'setup_1');
    globalThis.fetch = () => { throw new Error('boom'); };
    K.report('editor', 'cold=1');
  } finally {
    globalThis.fetch = prior.fetch;
    globalThis.ChickadeeUI = prior.ChickadeeUI;
  }
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, '/api/v1/client-diagnostics');
  assert.equal(posts[0].init.headers['x-csrf-token'], 'tok');
  assert.deepEqual(JSON.parse(posts[0].init.body), {
    kind: 'asset_load', source: 'editor', message: 'cold=1', testSetupID: 'setup_1',
  });
});

// ---- the dashboard wiring (kernel-prewarm.js) --------------------------------

const prewarmSource = await fs.readFile(path.resolve('Public/kernel-prewarm.js'), 'utf8');

async function runPrewarm({ connection = null, stored = new Map(), fetchOK = true } = {}) {
  const fetched = [];
  const reports = [];
  const timers = [];
  const storage = { getItem: (k) => stored.get(k) ?? null, setItem: (k, v) => stored.set(k, v) };
  const window = {
    ChickadeeKernelAssets: { ...K, report: (source, message) => reports.push({ source, message }) },
    localStorage: storage,
    fetch: async (url, init) => { fetched.push({ url, init }); return { ok: fetchOK, body: null, arrayBuffer: async () => null }; },
    addEventListener() {},
    requestIdleCallback: (fn) => fn(),
  };
  const context = {
    window,
    document: { readyState: 'complete', currentScript: { dataset: { kernelAssets: JSON.stringify([LIST]) } } },
    navigator: { connection },
    performance: { now: () => 0, getEntriesByType: () => [], setResourceTimingBufferSize() {} },
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
  };
  vm.runInNewContext(prewarmSource, context, { filename: 'kernel-prewarm.js' });
  while (timers.length) timers.shift()();
  // Let the warm's promise chain settle.
  for (let i = 0; i < 50; i++) await Promise.resolve();
  return { fetched, reports, stored };
}

test('the dashboard warms the server’s URLs once, then reports a prewarm breadcrumb', async () => {
  const first = await runPrewarm();
  assert.deepEqual(first.fetched.map((f) => f.url), K.assetURLs(LIST));
  assert.equal(first.reports.length, 1);
  assert.equal(first.reports[0].source, 'prewarm');
  // The marker is set, so the next dashboard load warms nothing.
  const second = await runPrewarm({ stored: first.stored });
  assert.equal(second.fetched.length, 0);
});

test('the dashboard warms nothing on a data-saving connection', async () => {
  const run = await runPrewarm({ connection: { saveData: true } });
  assert.equal(run.fetched.length, 0);
  assert.equal(run.reports.length, 0);
});

test('a failed warm reports nothing and leaves the version unmarked', async () => {
  const run = await runPrewarm({ fetchOK: false });
  assert.equal(run.fetched.length, 1);
  assert.equal(run.reports.length, 0);
  assert.equal(run.stored.size, 0);
});
