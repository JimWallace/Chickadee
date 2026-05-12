// Tests/BrowserRunnerJSTests/watchdog-probe.test.mjs
//
// Regression guards for the iframe-readiness probe used by
// `Public/notebook.js`'s `armEditorWatchdog`.
//
// History:
//   * v0.4.149 introduced the watchdog.  Phase-1 readiness signal was
//     `frame.contentWindow.jupyterapp` truthy from the parent frame.
//     Worked in Chromium.
//   * v0.4.150 deploy: Safari students saw spurious phase-1 timeouts —
//     JupyterLite was clearly running in the iframe, but the parent
//     couldn't see `jupyterapp` due to cross-process iframe isolation.
//   * v0.4.151 fix: `probeIframeReadiness` now layers DOM probes
//     (`.jp-Toolbar` / `.jp-Notebook` / any `.jp-*` class on body,
//     plus kernel status text `| Idle`/`| Busy`) on top of the JS
//     property probe.  DOM access is more permissive across process
//     boundaries.
//
// These tests pin the probe's behaviour under each path so a future
// refactor doesn't regress to the Safari-broken signal.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const notebookSource = await fs.readFile(
  path.resolve('Public/notebook.js'),
  'utf8',
);

// Loads notebook.js inside a sandboxed VM context with mocked DOM
// globals and returns the testHooks export.  Mirrors the setup in
// notebook.test.mjs.
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
    createElement() {
      return { className: '', textContent: '', innerHTML: '', appendChild() {} };
    },
    head: { appendChild() {} },
  };

  const fetch = async () => ({ ok: true, async json() { return { cells: [] }; } });

  const context = {
    console,
    document,
    fetch,
    setTimeout,
    clearTimeout,
    setInterval: () => 1,
    clearInterval: () => {},
    URL,
    JSON,
    Error,
    Promise,
    window: { location: { origin: 'https://example.test' } },
    __CHICKADEE_NOTEBOOK_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;

  vm.runInNewContext(notebookSource, context, { filename: 'notebook.js' });
  return hooks.exports;
}

// Builds a fake iframe whose `contentWindow` and `contentDocument`
// are computed lazily so tests can simulate cross-origin throws by
// passing factories.
function makeFrame({ winFactory, docFactory } = {}) {
  return {
    get contentWindow() { return winFactory ? winFactory() : null; },
    get contentDocument() { return docFactory ? docFactory() : null; },
  };
}

// Minimal DOM-element stub that satisfies the probe's calls.
function makeDoc({ classList = [], bodyText = '' } = {}) {
  const body = { textContent: bodyText };
  return {
    body,
    querySelector(sel) {
      // The probe asks specifically for these selectors; honor them by
      // checking if the corresponding class appears in `classList`.
      if (sel === '.jp-Toolbar' && classList.includes('jp-Toolbar')) return {};
      if (sel === '.jp-Notebook' && classList.includes('jp-Notebook')) return {};
      if ((sel === '[class^="jp-"]' || sel === '[class*=" jp-"]') &&
          classList.some(c => c.startsWith('jp-'))) {
        return {};
      }
      return null;
    },
  };
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

test('probeIframeReadiness: Chromium path — jupyterapp truthy on contentWindow', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: { serviceManager: null } }),
    docFactory: () => null,
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true, 'shellReady should be true when jupyterapp is visible');
});

test('probeIframeReadiness: Safari path — contentWindow inaccessible, DOM has jp-Toolbar', async () => {
  const { probeIframeReadiness } = await loadHarness();
  // Simulate Safari cross-process iframe isolation: contentWindow access
  // returns undefined (or could throw — handled below).  DOM is reachable
  // and shows JupyterLite UI.
  const frame = makeFrame({
    winFactory: () => undefined,
    docFactory: () => makeDoc({ classList: ['jp-Toolbar'], bodyText: '' }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true,
    'shellReady should be true when JupyterLite UI is visible in iframe DOM ' +
    '(v0.4.151 regression guard — Safari spurious-phase-1 fix)');
});

test('probeIframeReadiness: Safari path — DOM has .jp-Notebook', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({ classList: ['jp-Notebook'], bodyText: '' }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
});

test('probeIframeReadiness: Safari path — DOM has generic jp-* class', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({ classList: ['jp-Cell'], bodyText: '' }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
});

test('probeIframeReadiness: contentWindow access throws — does not crash', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => { throw new Error('cross-origin'); },
    docFactory: () => makeDoc({ classList: ['jp-Toolbar'] }),
  });
  // Should fall through to DOM probe rather than throwing.
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true, 'must recover from contentWindow access throw');
});

test('probeIframeReadiness: both probes fail → not ready (clean false)', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => null,
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, false);
  assert.equal(r.kernelHealthy, false);
});

test('probeIframeReadiness: kernel-healthy via DOM text "| Idle"', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Python (Pyodide) | Idle',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
  assert.equal(r.kernelHealthy, true,
    'kernelHealthy should detect "| Idle" in DOM text');
});

test('probeIframeReadiness: kernel-healthy via DOM text "| Busy"', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Python (Pyodide) | Busy',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.kernelHealthy, true);
});

test('probeIframeReadiness: shell up but kernel "Unknown" → kernelHealthy=false', async () => {
  // This is the Hans failure mode (pre-v0.4.150) — JupyterLite is loaded
  // but the kernel never reached idle.  Probe should report shellReady
  // but NOT kernelHealthy, so the watchdog can fire a phase-2
  // (kernel-unhealthy) timeout.
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Python (Pyodide) | Kernel Unknown',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
  assert.equal(r.kernelHealthy, false);
});

test('probeIframeReadiness: Chromium-style sessions API reports idle kernel', async () => {
  const { probeIframeReadiness } = await loadHarness();
  // Simulate JupyterLite's ServiceManager API surface in the iframe's
  // contentWindow.  `running()` returns an iterable of sessions whose
  // `kernel.status` is "idle".
  const fakeApp = {
    serviceManager: {
      sessions: {
        running() {
          return [{ kernel: { status: 'idle' } }];
        },
      },
    },
  };
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: fakeApp, document: makeDoc() }),
    docFactory: () => makeDoc(),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
  assert.equal(r.kernelHealthy, true,
    'kernelHealthy via ServiceManager.sessions.running() with idle status');
});
