// Tests/BrowserRunnerJSTests/watchdog-probe.test.mjs
//
// Regression guards for the iframe-readiness probe used by
// `Public/notebook.js`'s `armEditorWatchdog`.
//
// History:
//   * v0.4.149 introduced the watchdog.  Phase-1 signal was
//     `frame.contentWindow.jupyterapp` truthy.  Worked in Chromium.
//   * v0.4.150 deploy: Safari students saw spurious phase-1 timeouts
//     because of cross-process iframe isolation.
//   * v0.4.151: layered shell probe (DOM `.jp-Toolbar` / `.jp-Notebook`
//     / `.jp-*` selectors).  Latched `shellLoadedAt`.
//   * v0.4.152: phase-2 (kernel) probe inverted.  Previously fired on
//     ABSENCE of positive health evidence ("| Idle" / "| Busy" text);
//     this false-positived on healthy kernels in valid states like
//     "Starting" / "Connecting" or when the DOM text didn't render the
//     way our probe expected.  Now phase 2 fires ONLY on POSITIVE
//     EVIDENCE of failure ("Kernel Unknown" text, or session status
//     `dead`/`unknown` via ServiceManager API).
//
// These tests pin the probe's behaviour under each path so a future
// refactor doesn't regress.

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

function makeFrame({ winFactory, docFactory } = {}) {
  return {
    get contentWindow() { return winFactory ? winFactory() : null; },
    get contentDocument() { return docFactory ? docFactory() : null; },
  };
}

function makeDoc({ classList = [], bodyText = '' } = {}) {
  const body = { textContent: bodyText };
  return {
    body,
    querySelector(sel) {
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
// Shell readiness — unchanged semantics from v0.4.151
// ----------------------------------------------------------------

test('probeIframeReadiness: Chromium path — jupyterapp truthy on contentWindow', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: { serviceManager: null } }),
    docFactory: () => null,
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
});

test('probeIframeReadiness: Safari path — contentWindow inaccessible, DOM has jp-Toolbar', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => undefined,
    docFactory: () => makeDoc({ classList: ['jp-Toolbar'] }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true,
    'v0.4.151 regression guard — Safari spurious-phase-1 fix');
});

test('probeIframeReadiness: Safari path — DOM has .jp-Notebook', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({ classList: ['jp-Notebook'] }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
});

test('probeIframeReadiness: Safari path — DOM has generic jp-* class', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({ classList: ['jp-Cell'] }),
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
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true, 'must recover from contentWindow access throw');
});

test('probeIframeReadiness: nothing detectable → not ready', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => null,
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, false);
  assert.equal(r.kernelInFailureState, false);
});

// ----------------------------------------------------------------
// Kernel state — v0.4.152 semantics: failure-evidence only
// ----------------------------------------------------------------

test('probeIframeReadiness: shell up, kernel idle → NOT in failure state', async () => {
  // v0.4.152 regression guard — pre-v0.4.152 this required "| Idle" text
  // to confirm health and would false-positive when text wasn't visible.
  // Now we only flag failure on POSITIVE evidence of failure.
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
  assert.equal(r.kernelInFailureState, false);
});

test('probeIframeReadiness: shell up, kernel busy → NOT in failure state', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Python (Pyodide) | Busy',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.kernelInFailureState, false);
});

test('probeIframeReadiness: kernel starting (no idle text visible) → NOT in failure state', async () => {
  // v0.4.152 regression guard — the watchdog must NOT fire kernel-unhealthy
  // just because the kernel is still bootstrapping and the status text
  // hasn't rendered as "| Idle" yet.  Pyodide WASM load can take minutes
  // on slow networks.
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Python (Pyodide) | Starting',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
  assert.equal(r.kernelInFailureState, false,
    'starting kernels must not be flagged as failed');
});

test('probeIframeReadiness: shell up, no kernel status text at all → NOT in failure state', async () => {
  // The most defensive case: we can\'t see kernel status text in the DOM
  // (maybe rendered in shadow DOM, maybe different markup version).
  // Absence of evidence must NOT be treated as evidence of failure.
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Some notebook content but no status indicator visible to the parent frame',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
  assert.equal(r.kernelInFailureState, false,
    'v0.4.152 regression guard — no failure evidence means do not fire');
});

test('probeIframeReadiness: "Kernel Unknown" text in DOM → IN failure state', async () => {
  // The Hans symptom from PR #467.  This IS positive evidence of failure;
  // the watchdog should fire phase-2 kernel-unhealthy.
  const { probeIframeReadiness } = await loadHarness();
  const frame = makeFrame({
    winFactory: () => null,
    docFactory: () => makeDoc({
      classList: ['jp-Toolbar'],
      bodyText: 'Python (Pyodide) Kernel Unknown',
    }),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.shellReady, true);
  assert.equal(r.kernelInFailureState, true,
    'Kernel Unknown text is positive evidence of failure (Hans symptom)');
});

test('probeIframeReadiness: ServiceManager reports kernel status "unknown" → IN failure state', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const fakeApp = {
    serviceManager: {
      sessions: {
        running() { return [{ kernel: { status: 'unknown' } }]; },
      },
    },
  };
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: fakeApp, document: makeDoc() }),
    docFactory: () => makeDoc(),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.kernelInFailureState, true);
});

test('probeIframeReadiness: ServiceManager reports kernel status "dead" → IN failure state', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const fakeApp = {
    serviceManager: {
      sessions: {
        running() { return [{ kernel: { status: 'dead' } }]; },
      },
    },
  };
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: fakeApp, document: makeDoc() }),
    docFactory: () => makeDoc(),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.kernelInFailureState, true);
});

test('probeIframeReadiness: ServiceManager reports kernel status "idle" → NOT in failure state', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const fakeApp = {
    serviceManager: {
      sessions: {
        running() { return [{ kernel: { status: 'idle' } }]; },
      },
    },
  };
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: fakeApp, document: makeDoc() }),
    docFactory: () => makeDoc(),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.kernelInFailureState, false);
});

test('probeIframeReadiness: ServiceManager reports kernel status "starting" → NOT in failure state', async () => {
  const { probeIframeReadiness } = await loadHarness();
  const fakeApp = {
    serviceManager: {
      sessions: {
        running() { return [{ kernel: { status: 'starting' } }]; },
      },
    },
  };
  const frame = makeFrame({
    winFactory: () => ({ jupyterapp: fakeApp, document: makeDoc() }),
    docFactory: () => makeDoc(),
  });
  const r = probeIframeReadiness(frame);
  assert.equal(r.kernelInFailureState, false,
    'starting kernels must not be flagged as failed (v0.4.152 regression guard)');
});

test('isKernelInFailureState: empty running sessions → not in failure', async () => {
  const { isKernelInFailureState } = await loadHarness();
  const fakeWin = {
    jupyterapp: {
      serviceManager: { sessions: { running() { return []; } } },
    },
    document: { body: { textContent: '' } },
  };
  assert.equal(isKernelInFailureState(fakeWin), false);
});

test('isKernelInFailureState: API access throws → not in failure (no evidence)', async () => {
  const { isKernelInFailureState } = await loadHarness();
  const fakeWin = {
    get jupyterapp() { throw new Error('cross-origin'); },
    document: { body: { textContent: '' } },
  };
  assert.equal(isKernelInFailureState(fakeWin), false);
});
