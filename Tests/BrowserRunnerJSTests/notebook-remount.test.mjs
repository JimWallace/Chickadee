// A workbench notebook switch re-mounts the editor on the same `#jl-frame`
// (Public/notebook.js `chickadeeRemountNotebook`). Before #2382 every switch
// added another frame `load` listener, another 1.5 s poll interval and another
// kernel watchdog, so N switches ran the locked-path and tab hooks N times and
// could send N kernel-ready beacons.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const notebookSource = await fs.readFile(path.resolve('Public/notebook.js'), 'utf8');

function loadPage() {
  const loadListeners = [];
  const intervals = [];
  const frame = {
    dataset: {
      setupId: 'setup_123',
      gradingMode: 'browser',
      notebookUrl: '/api/v1/testsetups/setup_123/assignment',
      editorUrl: '/jupyterlite/notebooks/index.html?path=assignment.ipynb',
    },
    addEventListener(type, fn) { if (type === 'load') loadListeners.push(fn); },
    getAttribute(name) { return name === 'src' ? this.dataset.editorUrl : null; },
    contentWindow: null,
    contentDocument: null,
    src: '',
  };
  const elements = new Map([
    ['jl-frame', frame],
    ['nb-status', { textContent: '', className: '' }],
  ]);
  const window = { location: { origin: 'https://example.test' } };
  const context = {
    console,
    document: {
      getElementById(id) { return elements.get(id) ?? null; },
      createElement() { return { className: '', textContent: '', innerHTML: '', appendChild() {} }; },
      head: { appendChild() {} },
    },
    fetch: async () => ({ ok: true, async json() { return { cells: [] }; } }),
    // No timer callback runs: this test counts what is scheduled, not what
    // it does.
    setTimeout: () => 0,
    clearTimeout: () => {},
    setInterval: (fn, ms) => { intervals.push(ms); return intervals.length; },
    clearInterval: () => {},
    URL, JSON, Error, Promise,
    window,
  };
  context.globalThis = context;
  vm.runInNewContext(notebookSource, context, { filename: 'notebook.js' });
  return { window, loadListeners, intervals };
}

test('re-mounting the notebook adds no second frame listener or poll interval (#2382)', () => {
  const page = loadPage();
  assert.equal(typeof page.window.chickadeeRemountNotebook, 'function');

  page.window.chickadeeRemountNotebook();
  const listenersAfterFirstMount = page.loadListeners.length;
  const pollsAfterFirstMount = page.intervals.filter((ms) => ms === 1500).length;
  assert.equal(listenersAfterFirstMount, 1, 'the first mount binds one load listener');
  assert.equal(pollsAfterFirstMount, 1, 'the first mount starts one 1.5 s poll');

  page.window.chickadeeRemountNotebook();
  page.window.chickadeeRemountNotebook();

  assert.equal(page.loadListeners.length, listenersAfterFirstMount);
  assert.equal(page.intervals.filter((ms) => ms === 1500).length, pollsAfterFirstMount);
});
