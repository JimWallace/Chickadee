// Tests/BrowserRunnerJSTests/kernel-diagnostics.test.mjs
//
// Unit guards for the in-iframe kernel-boot diagnostics:
//
//   * Public/jl-kernel-diagnostics.js — the passive collector that runs INSIDE
//     the JupyterLite editor iframe, detects the kernel boot phase, and
//     postMessages kernel_phase / kernel_error breadcrumbs to the parent. Driven
//     here via its __CK_KERNEL_DIAG_TEST_HOOKS__ seam.
//   * Public/notebook.js handleKernelDiagMessage — the parent-side bridge that
//     validates those messages (same-origin, our `ck` tag, allowed kind, cap)
//     before forwarding them through the client-diagnostics pipeline.
//
// Together these pin the contract that closes the cross-process-iframe blind
// spot: the parent can't read the kernel's state, but the collector can, and the
// bridge only trusts a same-origin sender.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const collectorSource = await fs.readFile(
  path.resolve('Public/jl-kernel-diagnostics.js'), 'utf8');
const notebookSource = await fs.readFile(
  path.resolve('Public/notebook.js'), 'utf8');

// ----------------------------------------------------------------
// Collector (jl-kernel-diagnostics.js)
// ----------------------------------------------------------------

function loadCollector({ executionStatus, jpCount = 0, kernelError = false, bodyText = '' } = {}) {
  const posted = [];
  const hooks = {};
  const win = {
    location: { origin: 'https://example.test' },
    parent: { postMessage(payload, origin) { posted.push({ payload, origin }); } },
    addEventListener() {},
  };
  // Mock the JupyterLite shell DOM the collector reads (this build exposes no
  // window.jupyterapp): the execution indicator's data-status, the kernel-status
  // error class, and the jp-* shell-element count.
  const document = {
    body: { textContent: bodyText },
    addEventListener() {},
    querySelector(sel) {
      if (/jp-Notebook-ExecutionIndicator\[data-status\]/.test(sel)) {
        return executionStatus != null
          ? { getAttribute: (a) => (a === 'data-status' ? executionStatus : null) }
          : null;
      }
      if (/jp-KernelStatus-error/.test(sel)) return kernelError ? {} : null;
      if (/jp-Notebook-ExecutionIndicator|jp-NotebookPanel|jp-Notebook/.test(sel)) {
        return jpCount > 0 ? {} : null;
      }
      return null;
    },
    querySelectorAll(sel) {
      return { length: /class\^=/.test(sel) ? jpCount : 0 };
    },
  };
  const context = {
    console, JSON, Error,
    setTimeout: () => 0,   // don't auto-run the poll loop; we drive via hooks
    clearTimeout: () => {},
    window: win,
    document,
    __CK_KERNEL_DIAG_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;
  vm.runInNewContext(collectorSource, context, { filename: 'jl-kernel-diagnostics.js' });
  return { posted, exports: hooks.exports };
}

test('collector posts boot_start to the parent on load, same-origin', () => {
  const { posted } = loadCollector();
  assert.equal(posted.length, 1);
  // Spread into a test-realm object: the payload is built inside the vm context,
  // so its prototype differs and deepStrictEqual would reject it cross-realm.
  assert.deepEqual({ ...posted[0].payload }, {
    ck: 'kernel-diag', kind: 'kernel_phase', source: 'boot_start',
  });
  assert.equal(posted[0].origin, 'https://example.test');
});

test('collector kernelStatus reads data-status from the execution indicator', () => {
  assert.equal(loadCollector({ executionStatus: 'idle' }).exports.kernelStatus(), 'idle');
  assert.equal(loadCollector({ executionStatus: 'busy' }).exports.kernelStatus(), 'busy');
  assert.equal(loadCollector({ executionStatus: 'starting' }).exports.kernelStatus(), 'starting');
  assert.equal(loadCollector({ kernelError: true }).exports.kernelStatus(), 'unknown');
});

test('collector kernelStatus falls back to the kernel-status text', () => {
  assert.equal(loadCollector({ bodyText: 'Python (Pyodide) Kernel status: Idle' }).exports.kernelStatus(), 'idle');
  assert.equal(loadCollector({ bodyText: 'Kernel status: Unknown' }).exports.kernelStatus(), 'unknown');
  assert.equal(loadCollector({ bodyText: '' }).exports.kernelStatus(), null);
});

test('collector reportPhase de-duplicates a phase', () => {
  const { posted, exports } = loadCollector();   // posted already has boot_start
  exports.reportPhase('app_ready');
  exports.reportPhase('app_ready');
  const appReady = posted.filter(p => p.payload.source === 'app_ready');
  assert.equal(appReady.length, 1);
});

test('collector reportPhase forwards an optional elapsed_ms message', () => {
  const { posted, exports } = loadCollector();
  exports.reportPhase('kernel_idle', 'elapsed_ms=1234');
  const idle = posted.filter(p => p.payload.source === 'kernel_idle');
  assert.equal(idle.length, 1);
  assert.deepEqual({ ...idle[0].payload }, {
    ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle', message: 'elapsed_ms=1234',
  });
  // boot_start (posted on load) carries no message — the boot clock is reported
  // from app_ready onward, so the boot_start payload stays message-free.
  const bootStart = posted.find(p => p.payload.source === 'boot_start');
  assert.equal('message' in bootStart.payload, false);
});

test('collector reportError forwards source + message and de-dupes', () => {
  const { posted, exports } = loadCollector();
  exports.reportError('csp_violation', "worker-src blocked data:");
  exports.reportError('csp_violation', "worker-src blocked data:");   // dup
  const errs = posted.filter(p => p.payload.kind === 'kernel_error');
  assert.equal(errs.length, 1);
  assert.deepEqual({ ...errs[0].payload }, {
    ck: 'kernel-diag', kind: 'kernel_error',
    source: 'csp_violation', message: 'worker-src blocked data:',
  });
});

test('collector reportError caps at MAX_ERRORS distinct errors', () => {
  const { posted, exports } = loadCollector();
  for (let i = 0; i < 12; i++) exports.reportError('src' + i, 'msg' + i);
  const errs = posted.filter(p => p.payload.kind === 'kernel_error');
  assert.equal(errs.length, 8);   // MAX_ERRORS
});

test('collector trackUnhealthy ignores a transient unknown but flags a sustained one', () => {
  const { exports } = loadCollector();
  const t = exports.trackUnhealthy;
  // First unhealthy poll starts the clock; nothing reported yet.
  const first = t('unknown', 0, 1000);
  assert.equal(first.unhealthySince, 1000);
  assert.equal(first.report, false);
  // Still unhealthy but under the threshold (passing the streak start back in):
  // the start is preserved and no report fires.
  const held = t('unknown', 1000, 5000);
  assert.equal(held.unhealthySince, 1000);
  assert.equal(held.report, false);
  // Held continuously past SUSTAINED_UNHEALTHY_MS (30s): now report. 'dead'
  // behaves identically.
  assert.equal(t('unknown', 1000, 31000).report, true);
  assert.equal(t('dead', 1000, 31000).report, true);
  // A 10s unhealthy streak no longer reports — the threshold was raised from
  // 10s to 30s so slow-but-recovering Chromium/Safari boots aren't flagged as
  // CASE-2 failures (they reach idle on their own, just past the old 10s mark).
  assert.equal(t('unknown', 1000, 11000).report, false);
  // Any healthy/indeterminate poll resets the clock — no report, streak cleared —
  // so a momentary unknown that flips back to idle/null never reports.
  for (const status of ['idle', 'busy', 'starting', null]) {
    assert.deepEqual({ ...t(status, 1000, 31000) }, { unhealthySince: 0, report: false });
  }
});

test('collector executionStatusRaw reads only the data-status indicator', () => {
  assert.equal(loadCollector({ executionStatus: 'busy' }).exports.executionStatusRaw(), 'busy');
  assert.equal(loadCollector({ executionStatus: 'idle' }).exports.executionStatusRaw(), 'idle');
  // No data-status indicator → null (watcher reports nothing; never scans body text).
  assert.equal(loadCollector({ bodyText: 'Kernel status: Busy' }).exports.executionStatusRaw(), null);
});

test('collector trackExecHang flags a sustained-busy cell but not a quick one', () => {
  const { exports } = loadCollector();
  const t = exports.trackExecHang;
  // First busy poll starts the clock; nothing flagged yet.
  const first = t('busy', 0, 1000);
  assert.equal(first.execBusySince, 1000);
  assert.equal(first.hang, false);
  // Still busy but under EXEC_HANG_MS (45s): clock preserved, no hang.
  const held = t('busy', 1000, 20000);
  assert.equal(held.execBusySince, 1000);
  assert.equal(held.hang, false);
  // Busy held continuously past EXEC_HANG_MS: now a hang.
  assert.equal(t('busy', 1000, 46000).hang, true);
  // Any non-busy status (finished cell or none running) resets the clock — a
  // quick cell, or an idle kernel, is never a hang.
  for (const status of ['idle', 'starting', null]) {
    assert.deepEqual({ ...t(status, 1000, 46000) }, { execBusySince: 0, hang: false });
  }
});

test('collector idleMessage tags a recovered boot, plain otherwise', () => {
  const { exports } = loadCollector();
  // A clean boot (never reported unhealthy) → just the elapsed clock.
  assert.equal(exports.idleMessage(1500, false, 0), 'elapsed_ms=1500');
  // A boot that emitted a sustained kernel_unknown then reached idle → tagged
  // recovered so it can be subtracted from the terminal CASE-2 failures.
  assert.equal(exports.idleMessage(1500, true, 12000),
    'elapsed_ms=1500;recovered=1;unhealthy_ms=12000');
});

test('collector bootContext returns a PII-safe env snapshot without throwing', () => {
  const { exports } = loadCollector();
  const ctx = exports.bootContext();
  assert.equal(typeof ctx, 'string');
  // Capability + device-class + error-trail keys only — never code/output/identity.
  for (const key of ['coi=', 'sab=', 'mem=', 'cpu=', 'swctl=', 'shell=', 'errs=', 'lasterr=', 'phase=']) {
    assert.ok(ctx.includes(key), `expected ${key} in "${ctx}"`);
  }
  // The bare harness has no navigator / SharedArrayBuffer / crossOriginIsolated:
  // each must degrade to a safe fallback token, never a throw.
  assert.ok(ctx.includes('coi=false'));
  assert.ok(ctx.includes('sab=false'));
  assert.ok(ctx.includes('mem=na'));
  assert.ok(ctx.includes('lasterr=none'));
  assert.ok(ctx.includes('phase=boot_start'));
});

test('collector bootContext surfaces the boot error trail (count + last source)', () => {
  const { exports } = loadCollector();
  assert.ok(exports.bootContext().includes('errs=0'));
  exports.reportError('resource_error', 'failed to load /jupyterlite/kernel.js');
  const ctx = exports.bootContext();
  assert.ok(ctx.includes('errs=1'), ctx);
  assert.ok(ctx.includes('lasterr=resource_error'), ctx);
});

// ----------------------------------------------------------------
// Parent bridge (notebook.js handleKernelDiagMessage)
// ----------------------------------------------------------------

function loadBridge() {
  const events = [];
  const hooks = {};
  const elements = new Map();
  const frame = {
    dataset: {
      setupId: 'setup_123', gradingMode: 'browser',
      notebookUrl: '/api/v1/testsetups/setup_123/assignment',
      editorUrl: '/jupyterlite/notebooks/index.html?path=assignment.ipynb',
    },
    addEventListener() {},
    getAttribute(name) { return name === 'src' ? this.dataset.editorUrl : null; },
    contentWindow: null, contentDocument: null, src: '',
  };
  elements.set('jl-frame', frame);
  elements.set('nb-status', { textContent: '', className: '' });
  elements.set('nb-results', { hidden: true, innerHTML: '', appendChild() {}, scrollIntoView() {} });
  const document = {
    getElementById(id) { return elements.get(id) ?? null; },
    createElement() { return { className: '', textContent: '', innerHTML: '', appendChild() {} }; },
    addEventListener() {},
    head: { appendChild() {} },
  };
  const fetch = async () => ({ ok: true, async json() { return { cells: [] }; } });
  const failures = {
    runPreflight: async () => ({ ok: true, failed: [] }),
    reportEvent: (info) => { events.push(info); },
    reportEditorError() {},
    showFailure() {},
  };
  const context = {
    console, document, fetch,
    // No-op timers: the bridge installs synchronously at load, so we never need
    // a real tick — and a real one would fire mountEditor's deferred sw_state
    // beacon (which touches an undefined `navigator`) after the test ended.
    setTimeout: () => 0, clearTimeout: () => {},
    setInterval: () => 1, clearInterval: () => {},
    URL, JSON, Error, Promise,
    window: {
      location: { origin: 'https://example.test' },
      addEventListener() {},
      matchMedia: null,
      ChickadeeNotebookFailures: failures,
    },
    __CHICKADEE_NOTEBOOK_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;
  vm.runInNewContext(notebookSource, context, { filename: 'notebook.js' });
  // Drop any non-kernel telemetry emitted during load (e.g. sw_state).
  const kernelEvents = () => events.filter(
    e => e.kind === 'kernel_phase' || e.kind === 'kernel_error');
  return { handleKernelDiagMessage: hooks.exports.handleKernelDiagMessage, kernelEvents, frame };
}

function msg(data, origin = 'https://example.test') {
  return { origin, data };
}

test('bridge self-heals an exec_hang: one reload + a recover_attempt event', async () => {
  const { handleKernelDiagMessage, frame, kernelEvents } = loadBridge();
  const editorUrl = frame.dataset.editorUrl;
  // First exec_hang → reload the editor iframe once. whenServiceWorkerActive
  // resolves false synchronously (no navigator in the harness), so the reload
  // .then() runs on a microtask we flush with two awaits.
  frame.src = 'SENTINEL-A';
  handleKernelDiagMessage(msg({
    ck: 'kernel-diag', kind: 'kernel_error', source: 'exec_hang', message: 'busy_ms=45000',
  }));
  await Promise.resolve(); await Promise.resolve();
  assert.equal(frame.src, editorUrl);
  assert.equal(kernelEvents().filter(e => e.source === 'recover_attempt').length, 1);
  // A second exec_hang must NOT reload again — guarded so a persistently
  // deadlocking kernel can't reload-loop.
  frame.src = 'SENTINEL-B';
  handleKernelDiagMessage(msg({
    ck: 'kernel-diag', kind: 'kernel_error', source: 'exec_hang', message: 'busy_ms=45000',
  }));
  await Promise.resolve(); await Promise.resolve();
  assert.equal(frame.src, 'SENTINEL-B');
});

test('bridge reports recover_failed when the rebooted kernel hangs again', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  // Two exec_hangs without yielding: the reload .then() hasn't run, so the
  // reset-window guard is still open and the second hang reaches the
  // persistent-hang branch — exactly the "self-heal didn't take" case.
  const hang = () => handleKernelDiagMessage(msg({
    ck: 'kernel-diag', kind: 'kernel_error', source: 'exec_hang', message: 'busy_ms=45000',
  }));
  hang();   // recover_attempt + schedules the reload
  hang();   // already-recovered, guard still open → recover_failed
  assert.equal(kernelEvents().filter(e => e.source === 'recover_attempt').length, 1);
  assert.equal(kernelEvents().filter(e => e.source === 'recover_failed').length, 1);
});

test('bridge forwards a same-origin kernel_phase', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  const ok = handleKernelDiagMessage(msg({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle' }));
  assert.equal(ok, true);
  assert.deepEqual(kernelEvents().map(e => ({ ...e })),
    [{ kind: 'kernel_phase', source: 'kernel_idle', message: undefined }]);
});

test('bridge forwards a kernel_phase elapsed_ms message to the server', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  handleKernelDiagMessage(msg({
    ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle', message: 'elapsed_ms=1500',
  }));
  assert.deepEqual(kernelEvents().map(e => ({ ...e })),
    [{ kind: 'kernel_phase', source: 'kernel_idle', message: 'elapsed_ms=1500' }]);
});

test('bridge forwards a kernel_error with source + message', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  handleKernelDiagMessage(msg({
    ck: 'kernel-diag', kind: 'kernel_error', source: 'boot_stalled', message: 'last_phase=app_ready',
  }));
  assert.deepEqual(kernelEvents().map(e => ({ ...e })),
    [{ kind: 'kernel_error', source: 'boot_stalled', message: 'last_phase=app_ready' }]);
});

test('bridge rejects a cross-origin message', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  const ok = handleKernelDiagMessage(
    msg({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle' }, 'https://evil.example.com'));
  assert.equal(ok, false);
  assert.equal(kernelEvents().length, 0);
});

test('bridge rejects a message without the ck tag', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  assert.equal(handleKernelDiagMessage(msg({ kind: 'kernel_phase', source: 'x' })), false);
  assert.equal(handleKernelDiagMessage(msg({ ck: 'something-else', kind: 'kernel_phase', source: 'x' })), false);
  assert.equal(kernelEvents().length, 0);
});

test('bridge rejects a disallowed kind', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  assert.equal(handleKernelDiagMessage(msg({ ck: 'kernel-diag', kind: 'editor_ready' })), false);
  assert.equal(handleKernelDiagMessage(msg({ ck: 'kernel-diag', kind: 'evil' })), false);
  assert.equal(kernelEvents().length, 0);
});

test('bridge caps forwarded messages', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  let forwarded = 0;
  for (let i = 0; i < 30; i++) {
    if (handleKernelDiagMessage(msg({ ck: 'kernel-diag', kind: 'kernel_error', source: 's' + i, message: 'm' }))) {
      forwarded += 1;
    }
  }
  assert.equal(forwarded, 24);            // KERNEL_DIAG_MAX
  assert.equal(kernelEvents().length, 24);
});

test('bridge clamps oversized source and message', () => {
  const { handleKernelDiagMessage, kernelEvents } = loadBridge();
  handleKernelDiagMessage(msg({
    ck: 'kernel-diag', kind: 'kernel_error',
    source: 'x'.repeat(200), message: 'y'.repeat(5000),
  }));
  const [e] = kernelEvents();
  assert.equal(e.source.length, 64);
  assert.equal(e.message.length, 1000);
});
