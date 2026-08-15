// Unit tests for ChickadeeSurfaceSwap.refreshEditSurface — how the assignment
// editor re-renders itself after a write.
//
// Renamed and re-specified in #1266. It used to read `data-ck-panel-url` off
// <body> and hand it to `location.replace`, because the editor lived in a
// workbench iframe and a reload would have pinned the pane to whatever chromed
// page a handler's redirect had left it on. That whole mechanism is gone: the
// workbench is one document, so there is no second URL to keep in sync and no
// DOM-sourced navigation target to validate (the old CodeQL finding went with
// it — `fetch(window.location.href)` is not DOM text).
//
// What replaced it is worth its own tests, because getting it wrong is silent
// and expensive:
//
//   * On the merged workbench it must SWAP the edit half's DOM and never
//     navigate. The form shares a document with a live Pyodide kernel, so a
//     reload costs a 10-30s boot and the author's unsaved cells — and it would
//     still *look* correct, because the re-rendered section does appear.
//   * On the standalone /edit page, where there is no kernel and no shell, a
//     plain reload is still right.
//   * A failed refresh must fall back to a reload rather than leaving a
//     half-swapped page. The write already succeeded, so showing stale state is
//     worse than paying for the reload.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/surface-swap.js'), 'utf8');

/// A minimal element stub: enough surface for the swap path to run.
///
/// The swap builds real nodes (importNode into a fragment) rather than
/// assigning innerHTML — that is what preserves the identity of the carried-over
/// element — so the stub has to model appendChild/textContent, not just a
/// string. `appended` records what the swap put in.
function makeEl(marker = '') {
  return {
    marker,
    scrollTop: 0,
    textContent: marker,
    appended: [],
    childNodes: marker ? [{ marker }] : [],
    appendChild(n) {
      this.appended.push(n);
      // A real element loses its scroll offset when its content is replaced —
      // the container briefly stops overflowing and the browser clamps
      // scrollTop to 0. Modelled here because without it the scroll-preservation
      // test below passes whether or not the restore exists (verified: deleting
      // `half.scrollTop = scrollTop` from swapHalf left it green).
      this.scrollTop = 0;
      return n;
    },
    // The swap re-executes inline scripts; no fixture here carries one, so an
    // empty list is honest rather than convenient. The re-execution path itself
    // is exercised by the browser check, which has a real DOM.
    querySelectorAll: () => [],
    querySelector: () => null,
  };
}

function makeFragment() {
  return {
    nodes: [],
    appendChild(n) { this.nodes.push(n); return n; },
    querySelector: () => null,
  };
}

/// Load chickadee-ui.js against a stub DOM.
///
/// `opts.merged` decides whether `#wb-shell` exists — i.e. whether this is the
/// merged workbench or the standalone editor. `opts.responseHTML` is what the
/// refresh fetch resolves with; `opts.fetchFails` makes it reject.
function load(opts = {}) {
  const calls = [];
  const half = makeEl('<p>old</p>');
  const freshHalf = makeEl('<p>fresh</p>');

  const document = {
    body: { getAttribute: () => null },
    querySelector: (sel) => (sel === '.wb-pane-edit' ? half : null),
    getElementById: (id) => (id === 'wb-shell' && opts.merged ? {} : null),
    createElement: () => ({}),
    createDocumentFragment: makeFragment,
    importNode: (n) => n,
  };
  const window = {
    location: {
      href: 'https://chickadee.example/instructor/DEJr2f/workbench',
      origin: 'https://chickadee.example',
      reload: () => calls.push({ kind: 'reload' }),
      replace: (url) => calls.push({ kind: 'replace', url }),
      assign: (url) => calls.push({ kind: 'assign', url }),
    },
    document,
    scrollY: 0,
    addEventListener: () => {},
    sessionStorage: { setItem: () => {}, getItem: () => null, removeItem: () => {} },
    fetch: (url, init) => {
      calls.push({ kind: 'fetch', url, init });
      if (opts.fetchFails) return Promise.reject(new Error('network'));
      return Promise.resolve({
        ok: opts.notOk ? false : true,
        status: opts.notOk ? 500 : 200,
        text: () => Promise.resolve(opts.responseHTML ?? '<html></html>'),
      });
    },
    DOMParser: class {
      parseFromString() {
        return { querySelector: () => (opts.responseMissingHalf ? null : freshHalf) };
      }
    },
  };
  window.parent = window;

  // `self`, because surface-swap.js resolves its global as
  // `typeof self !== 'undefined' ? self : this`.
  const context = vm.createContext({
    window,
    document,
    globalThis: {},
    self: window,
    fetch: window.fetch,
    DOMParser: window.DOMParser,
  });
  vm.runInContext(source, context);
  return { ui: window.ChickadeeSurfaceSwap, calls, half, freshHalf };
}

test('refreshEditSurface: swaps the edit half in place, never navigating', async () => {
  // The assertion the merge rests on. A navigation here — reload or otherwise —
  // is a dead Pyodide kernel.
  const { ui, calls, half } = load({ merged: true });
  const ok = await ui.refreshEditSurface();

  assert.equal(ok, true);
  assert.equal(half.appended.length, 1, 'the edit half was not swapped');
  assert.equal(half.appended[0].nodes[0].marker, '<p>fresh</p>');
  assert.equal(
    calls.filter((c) => c.kind !== 'fetch').length, 0,
    `refreshEditSurface navigated: ${JSON.stringify(calls)}`);
});

test('refreshEditSurface: refreshes from the page it is already on', async () => {
  // Not a stored panel URL. The merged page's own URL already names exactly
  // what to re-render, including which notebook is open, so there is no second
  // URL that can drift out of sync with it.
  const { ui, calls } = load({ merged: true });
  await ui.refreshEditSurface();

  const fetches = calls.filter((c) => c.kind === 'fetch');
  assert.equal(fetches.length, 1);
  assert.equal(fetches[0].url, 'https://chickadee.example/instructor/DEJr2f/workbench');
  assert.equal(fetches[0].init.credentials, 'same-origin');
});

test('refreshEditSurface: preserves scroll position across the swap', async () => {
  // Every caller is re-rendering after a small edit — one support file, one
  // section rename — and landing back at the top of a long assignment each time
  // is its own kind of lost work.
  const { ui, half } = load({ merged: true });
  half.scrollTop = 420;
  await ui.refreshEditSurface();

  assert.equal(half.scrollTop, 420);
});

test('refreshEditSurface: plainly reloads on the standalone editor', async () => {
  // No #wb-shell, so no kernel to protect and no half to swap. Reloading is
  // what this page has always done.
  const { ui, calls, half } = load({ merged: false });
  await ui.refreshEditSurface();

  assert.deepEqual(calls, [{ kind: 'reload' }]);
  assert.equal(half.appended.length, 0, 'the standalone page must not swap');
});

test('refreshEditSurface: falls back to a reload when the refresh fails', async () => {
  // The write already succeeded. Leaving the author on stale state with no
  // error is worse than paying for the reload.
  for (const opts of [
    { merged: true, fetchFails: true },
    { merged: true, notOk: true },
    { merged: true, responseMissingHalf: true },
  ]) {
    const { ui, calls } = load(opts);
    const ok = await ui.refreshEditSurface();

    assert.equal(ok, false, `expected failure for ${JSON.stringify(opts)}`);
    assert.equal(
      calls.filter((c) => c.kind === 'reload').length, 1,
      `expected a fallback reload for ${JSON.stringify(opts)}`);
  }
});
