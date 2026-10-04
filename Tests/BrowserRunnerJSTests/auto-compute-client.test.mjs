// Public/auto-compute-client.js, driven against a fake Web Worker and a fake
// fetch (#1966).
//
// Before the split, auto-compute lived inside the pattern-family editor's
// init closure, and only source-shape tests reached it. These tests run the
// real client:
//   - routing: a language whose seed names an in-page worker computes in that
//     worker; every other language computes on the server.
//   - time limits: a call or a solution load that runs past its limit is
//     reported as a timeout.
//   - kill-on-timeout: the timed-out worker is terminated, and the next call
//     starts a new worker and loads the solution again.
// The time limits are passed in as milliseconds, so no test waits five
// seconds.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const clientSource = await fs.readFile(path.resolve('Public/auto-compute-client.js'), 'utf8');
const editorSource = await fs.readFile(path.resolve('Public/pattern-family-editor.js'), 'utf8');
const languageModuleSource = await fs.readFile(path.resolve('Public/authoring-language.js'), 'utf8');

/// Values made in the vm realm have that realm's prototypes, which strict
/// deepEqual rejects. Compare their JSON shape.
const plain = (value) => JSON.parse(JSON.stringify(value));

/// Code with the comments removed. Comments may describe old shapes.
const codeOf = (source) => source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/.*$/gm, '');

const R_SEED = {
  name: 'r', displayName: 'R',
  trueLiteral: 'TRUE', falseLiteral: 'FALSE', nullLiteral: 'NULL',
  autoComputeWorker: '/r-eval-worker.js',
  autoComputeRuntimeSource: '# the R runtime',
};

const CPP_SEED = {
  name: 'cpp', displayName: 'C++',
  trueLiteral: 'true', falseLiteral: 'false', nullLiteral: null,
  autoComputeWorker: null,
};

const SOLUTION = {
  nbformat: 4,
  metadata: {},
  cells: [
    { cell_type: 'markdown', source: ['# Lab 1\n'] },
    { cell_type: 'code', source: ['%matplotlib inline\n', 'f <- function(x) x + 1\n'] },
    { cell_type: 'code', source: '!pip install nothing\n' },
    { cell_type: 'code', source: ['g <- function() 2\n'] },
  ],
};

const URLS = {
  solutionNotebook: () => '/solution.ipynb',
  computeExpected: () => '/compute-expected',
};

/// The default worker: a load succeeds, and every call returns 42.
function defaultRespond(message) {
  if (message.type === 'loadCells') return { ok: true, cellErrors: [] };
  if (message.type === 'call') return { ok: true, result: 42 };
  return { ok: false, error: `unexpected message ${message.type}` };
}

/// A fake Worker class. Each instance records the messages it gets and
/// answers through `respond(message)`. `undefined` means no reply, which is
/// how a test makes the worker hang. A terminated worker sends nothing, as a
/// real one does.
function makeWorkerClass(respond) {
  const created = [];
  class FakeWorker {
    constructor(url) {
      this.url = url;
      this.messages = [];
      this.terminated = false;
      this.listeners = {};
      created.push(this);
    }
    addEventListener(type, fn) {
      (this.listeners[type] ||= []).push(fn);
    }
    postMessage(message) {
      assert.equal(this.terminated, false, 'a message was posted to a terminated worker');
      const copy = plain(message);
      this.messages.push(copy);
      const reply = respond(copy);
      if (reply === undefined) return;
      setTimeout(() => {
        if (!this.terminated) this.emit('message', { data: { id: copy.id, ...reply } });
      }, 0);
    }
    terminate() {
      this.terminated = true;
    }
    emit(type, event) {
      for (const fn of this.listeners[type] || []) fn(event);
    }
  }
  return { FakeWorker, created };
}

/// Loads the language module and the client the way the page does, against a
/// seed, a fake Worker and a fake fetch.
function loadClient({ seed = R_SEED, respond = defaultRespond, fetchImpl, appVersion = '' } = {}) {
  const seedEl = seed === null ? null : { textContent: JSON.stringify(seed) };
  const { FakeWorker, created } = makeWorkerClass(respond);
  const fetchCalls = [];
  const fetchFn = fetchImpl ?? (async (url) => {
    if (url === '/solution.ipynb') return { ok: true, json: async () => SOLUTION };
    return { ok: false, json: async () => ({}) };
  });
  const ctx = {
    console, JSON, Array, Object, Math, Set, Map, Promise, RegExp, String, Boolean, Number, Error,
    setTimeout, clearTimeout,
    Worker: FakeWorker,
    fetch: (url, init) => {
      fetchCalls.push({ url, init: init ? plain(init) : init });
      return fetchFn(url, init);
    },
    document: {
      getElementById: (id) => (id === 'assignment-language-seed' ? seedEl : null),
      querySelector: (selector) => (selector === 'meta[name="app-version"]' && appVersion
        ? { content: appVersion }
        : null),
    },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(languageModuleSource, ctx, { filename: 'authoring-language.js' });
  vm.runInNewContext(clientSource, ctx, { filename: 'auto-compute-client.js' });
  return { AutoCompute: ctx.ChickadeeAutoCompute, workers: created, fetchCalls };
}

/// Waits until `condition()` is true, for at most a few hundred event-loop
/// turns.
async function waitFor(condition, what) {
  for (let i = 0; i < 500; i++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.fail(`timed out waiting for ${what}`);
}

// ── Routing ─────────────────────────────────────────────────────────────────

test('a language with an in-page worker computes in that worker', async () => {
  const { AutoCompute, workers, fetchCalls } = loadClient({ appVersion: '0.5.1' });
  const client = AutoCompute.createClient({ csrfToken: 'tok', urls: URLS });

  const res = await client.callSolution('f', [1, 'a'], {});

  assert.deepEqual(plain(res), { ok: true, value: 42, returnedNone: false });
  // The worker is the one the seed names, pinned to the page's release.
  assert.equal(workers.length, 1);
  assert.equal(workers[0].url, '/r-eval-worker.js?v=0.5.1');
  // The solution loads first: code cells only, with magic and shell lines
  // removed, and the seed's runtime beside them.
  assert.deepEqual(workers[0].messages.map(({ id: _id, ...rest }) => rest), [
    {
      type: 'loadCells',
      cells: ['f <- function(x) x + 1\n', 'g <- function() 2\n'],
      runtimeSource: '# the R runtime',
    },
    {
      type: 'call', functionName: 'f', args: [1, 'a'],
      captureStdout: false, runtimeSource: '# the R runtime',
    },
  ]);
  // The only request is the solution fetch. The server does not compute.
  assert.deepEqual(fetchCalls.map((c) => c.url), ['/solution.ipynb']);
  assert.equal(fetchCalls[0].init.headers['x-csrf-token'], 'tok');
});

test('the solution loads once, and later calls reuse it', async () => {
  const { AutoCompute, workers } = loadClient();
  const client = AutoCompute.createClient({ urls: URLS });

  // Two rows at once, as the debounce tick sends them, then one more.
  await Promise.all([client.callSolution('f', [1], {}), client.callSolution('f', [2], {})]);
  await client.callSolution('f', [3], { captureStdout: true });

  assert.equal(workers.length, 1);
  const types = workers[0].messages.map((m) => m.type);
  assert.deepEqual(types, ['loadCells', 'call', 'call', 'call']);
  assert.equal(workers[0].messages[3].captureStdout, true);
  // Request ids are unique, so each reply finds its own caller.
  const ids = workers[0].messages.map((m) => m.id);
  assert.equal(new Set(ids).size, ids.length);
});

test("the worker's None and unsupported replies keep their shapes", async () => {
  let reply = { ok: true, returnedNone: true };
  const { AutoCompute } = loadClient({
    respond: (m) => (m.type === 'loadCells' ? { ok: true } : reply),
  });
  const client = AutoCompute.createClient({ urls: URLS });

  assert.deepEqual(plain(await client.callSolution('f', [], {})),
    { ok: true, value: null, returnedNone: true });
  reply = { ok: true, unsupported: 'set' };
  assert.deepEqual(plain(await client.callSolution('f', [], {})),
    { ok: false, unsupported: 'set' });
});

test('a missing function names the solution cell that failed to load', async () => {
  const { AutoCompute } = loadClient({
    respond: (m) => (m.type === 'loadCells'
      ? { ok: true, cellErrors: [{ index: 1, message: 'ZeroDivisionError: division by zero' }] }
      : { ok: false, error: "Traceback (most recent call last):\nNameError: name 'f' is not defined" }),
  });
  const client = AutoCompute.createClient({ urls: URLS });

  const res = await client.callSolution('f', [], {});
  assert.deepEqual(plain(res), {
    ok: false,
    error: "NameError: name 'f' is not defined (cell 2 failed: ZeroDivisionError: division by zero)",
  });
});

test('a language with no in-page worker computes on the server', async () => {
  let rendered = 'true';
  const { AutoCompute, workers, fetchCalls } = loadClient({
    seed: CPP_SEED,
    fetchImpl: async () => ({ ok: true, json: async () => ({ ok: true, rendered }) }),
  });
  const client = AutoCompute.createClient({ csrfToken: 'tok', urls: URLS });

  // A scalar in the language's own spelling round-trips.
  assert.deepEqual(plain(await client.callSolution('f', [2, 'x'], { captureStdout: true })),
    { ok: true, value: true });
  // JSON reads as JSON.
  rendered = '[1, 2]';
  assert.deepEqual(plain(await client.callSolution('f', [], {})), { ok: true, value: [1, 2] });
  // A composite in the language's own syntax is reported, not stored as text.
  rendered = '{1, 2}';
  assert.deepEqual(plain(await client.callSolution('f', [], {})),
    { ok: false, error: 'Computed {1, 2} — enter it here in JSON.' });

  assert.equal(workers.length, 0, 'no worker may start for a language without one');
  assert.equal(fetchCalls[0].url, '/compute-expected');
  assert.equal(fetchCalls[0].init.method, 'POST');
  assert.equal(fetchCalls[0].init.headers['x-csrf-token'], 'tok');
  assert.deepEqual(JSON.parse(fetchCalls[0].init.body),
    { functionName: 'f', args: [2, 'x'], captureStdout: true });
});

test('the server route reports its own failures', async () => {
  let response = { ok: true, json: async () => ({ unsupportedReason: 'No driver for this language.' }) };
  const { AutoCompute, fetchCalls } = loadClient({ seed: CPP_SEED, fetchImpl: async () => response });

  const client = AutoCompute.createClient({ urls: URLS });
  assert.deepEqual(plain(await client.callSolution('f', [], {})),
    { ok: false, error: 'No driver for this language.' });
  response = { ok: true, json: async () => ({ ok: false, error: 'boom' }) };
  assert.deepEqual(plain(await client.callSolution('f', [], {})), { ok: false, error: 'boom' });
  response = { ok: false, json: async () => ({}) };
  assert.deepEqual(plain(await client.callSolution('f', [], {})), { ok: false, error: 'compute failed' });

  // A page that gives no compute-expected URL says so, and fetches nothing.
  const before = fetchCalls.length;
  const noServer = AutoCompute.createClient({ urls: { solutionNotebook: URLS.solutionNotebook } });
  assert.deepEqual(plain(await noServer.callSolution('f', [], {})),
    { ok: false, error: 'Auto-compute is unavailable on this page.' });
  assert.equal(fetchCalls.length, before);
});

test('a page with no language seed computes on the server', async () => {
  const { AutoCompute, workers, fetchCalls } = loadClient({
    seed: null,
    fetchImpl: async () => ({ ok: true, json: async () => ({ ok: true, rendered: '7' }) }),
  });
  const client = AutoCompute.createClient({ urls: URLS });

  assert.deepEqual(plain(await client.callSolution('f', [], {})), { ok: true, value: 7 });
  assert.equal(workers.length, 0);
  assert.deepEqual(fetchCalls.map((c) => c.url), ['/compute-expected']);
});

// ── Time limits and kill-on-timeout ─────────────────────────────────────────

test('the editor gets the five- and thirty-second limits by default', () => {
  const { AutoCompute } = loadClient();
  assert.equal(AutoCompute.TIMEOUT_MS, 5000);
  assert.equal(AutoCompute.LOAD_TIMEOUT_MS, 30000);
  const client = AutoCompute.createClient({ urls: URLS });
  assert.equal(client.timeoutMs, 5000);
  assert.equal(client.loadTimeoutMs, 30000);
});

test('a call that runs past its limit kills the worker, and the next call starts a new one', async () => {
  const { AutoCompute, workers } = loadClient({
    respond: (m) => {
      if (m.type === 'loadCells') return { ok: true, cellErrors: [] };
      if (m.functionName === 'spin') return undefined;
      return { ok: true, result: 'fast' };
    },
  });
  const client = AutoCompute.createClient({ urls: URLS, timeoutMs: 20 });

  const res = await client.callSolution('spin', [], {});
  assert.deepEqual(plain(res), { ok: false, timedOut: true, error: 'timed out after 0.02s' });
  assert.equal(workers.length, 1);
  assert.equal(workers[0].terminated, true, 'the timed-out worker must be terminated');

  const next = await client.callSolution('quick', [], {});
  assert.deepEqual(plain(next), { ok: true, value: 'fast', returnedNone: false });
  assert.equal(workers.length, 2, 'the next call must start a new worker');
  // The killed worker held the loaded solution, so the new one loads it again.
  assert.deepEqual(workers[1].messages.map((m) => m.type), ['loadCells', 'call']);
  // Nothing more went to the killed worker.
  assert.deepEqual(workers[0].messages.map((m) => m.type), ['loadCells', 'call']);
});

test('a solution load that runs past its limit kills the worker and is not cached', async () => {
  let hangLoad = true;
  const { AutoCompute, workers } = loadClient({
    respond: (m) => {
      if (m.type === 'loadCells') return hangLoad ? undefined : { ok: true, cellErrors: [] };
      return { ok: true, result: 1 };
    },
  });
  const client = AutoCompute.createClient({ urls: URLS, loadTimeoutMs: 20 });

  const res = await client.callSolution('f', [], {});
  assert.deepEqual(plain(res),
    { ok: false, timedOut: true, error: 'solution notebook load timed out after 0.02s' });
  assert.equal(workers[0].terminated, true);
  assert.deepEqual(workers[0].messages.map((m) => m.type), ['loadCells'],
    'no call may be sent before the solution has loaded');

  // The failed load is not reused: the next call loads again, in a new worker.
  hangLoad = false;
  const next = await client.callSolution('f', [], {});
  assert.deepEqual(plain(next), { ok: true, value: 1, returnedNone: false });
  assert.equal(workers.length, 2);
  assert.deepEqual(workers[1].messages.map((m) => m.type), ['loadCells', 'call']);
});

test('a worker error fails every pending request and starts over', async () => {
  const { AutoCompute, workers } = loadClient({
    respond: (m) => (m.type === 'loadCells' ? { ok: true, cellErrors: [] } : undefined),
  });
  // No time limit can fire during this test.
  const client = AutoCompute.createClient({ urls: URLS, timeoutMs: 60000 });

  const first = client.callSolution('f', [1], {});
  const second = client.callSolution('f', [2], {});
  await waitFor(() => workers[0] && workers[0].messages.filter((m) => m.type === 'call').length === 2,
    'both calls to reach the worker');
  workers[0].emit('error', { message: 'out of memory' });

  assert.deepEqual(plain(await first), { ok: false, error: 'out of memory' });
  assert.deepEqual(plain(await second), { ok: false, error: 'out of memory' });
  assert.equal(workers[0].terminated, true);

  // The next call starts a new worker, which loads the solution again.
  client.callSolution('f', [3], {});
  await waitFor(() => workers.length === 2 && workers[1].messages.length > 0, 'a new worker');
  assert.equal(workers[1].messages[0].type, 'loadCells');
});

// ── Solution-load failures ──────────────────────────────────────────────────

test('a solution that does not load is reported in readable copy, with no worker', async () => {
  const cases = [
    [async () => ({ ok: false, json: async () => ({}) }),
      { ok: false, loadFailed: true, error: 'no solution notebook', detail: 'no-solution' }],
    [async () => ({ ok: true, json: async () => ({ cells: [{ cell_type: 'markdown', source: 'x' }] }) }),
      { ok: false, loadFailed: true, error: 'solution notebook has no code', detail: 'empty-solution' }],
    [async () => { throw new TypeError('Failed to fetch'); },
      { ok: false, loadFailed: true, error: 'solution notebook did not load', detail: 'Failed to fetch' }],
  ];
  for (const [fetchImpl, expected] of cases) {
    const { AutoCompute, workers } = loadClient({ fetchImpl });
    const client = AutoCompute.createClient({ urls: URLS });
    assert.deepEqual(plain(await client.callSolution('f', [], {})), expected);
    assert.equal(workers.length, 0, `${expected.detail}: no worker may start`);
  }
});

// ── The split itself ────────────────────────────────────────────────────────

test('the editor computes through the client and starts no worker itself', () => {
  const editorCode = codeOf(editorSource);
  assert.ok(editorCode.includes('ChickadeeAutoCompute.createClient('),
    'the editor must create its auto-compute client');
  assert.ok(editorCode.includes('ChickadeeAutoCompute.applyAutoComputeResult('),
    'the editor must write results through the client module');
  assert.equal(/new Worker\(/.exec(editorCode), null,
    'the editor must not start a worker; the client does');
  assert.equal(/fetch\([^)]*computeExpected/.exec(editorCode), null,
    'the editor must not call the server route itself');
});

test('the auto-compute client spells no language literal itself', () => {
  // The same rule as the authoring editors: the scalar spellings come from
  // the seed through ChickadeeLanguage. A quoted True/False/None here is the
  // shape #1958 found in the case cells.
  const literal = /['"](True|False|None|TRUE|FALSE|NULL|nil|#t|#f)['"]/.exec(codeOf(clientSource));
  assert.equal(literal, null, `auto-compute-client.js spells ${literal && literal[0]} itself`);
});
