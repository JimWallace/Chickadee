// Unit tests for ChickadeeUI.notifyWorkbench — the cross-pane notification the
// assignment workbench's shell listens for.
//
// Three pages call it (the notebook editor, the global-inputs editor, the
// section-inputs editor) and every one of them is also reachable directly as a
// top-level page. Two properties matter and neither is visible by reading a
// single call site: it must be silent when there is no shell above it, and it
// must never broadcast to '*' — these are same-origin notes about what an
// instructor is editing, and a wildcard target would hand them to any document
// that managed to frame the page.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

/// Loads chickadee-ui.js against a stub window whose `parent` we control, and
/// records every postMessage the module makes.
function load({ framed }) {
  const posted = [];
  const window = {
    location: { origin: 'https://chickadee.example' },
    document: { querySelector: () => null },
  };
  window.parent = framed ? { postMessage: (data, origin) => posted.push({ data, origin }) } : window;

  const context = vm.createContext({ window, document: window.document, globalThis: {} });
  vm.runInContext(source, context);
  return { ui: window.ChickadeeUI, posted };
}

test('notifyWorkbench: posts to the shell when the page is a workbench pane', () => {
  const { ui, posted } = load({ framed: true });
  ui.notifyWorkbench('notebook-saved');

  assert.equal(posted.length, 1);
  // Field-by-field rather than deepEqual: the payload is constructed inside the
  // vm realm, so its prototype is not this realm's Object.prototype.
  assert.equal(posted[0].data.source, 'chickadee');
  assert.equal(posted[0].data.type, 'notebook-saved');
});

test('notifyWorkbench: targets this origin explicitly, never a wildcard', () => {
  const { ui, posted } = load({ framed: true });
  ui.notifyWorkbench('inputs-changed');

  assert.equal(posted[0].origin, 'https://chickadee.example');
  assert.notEqual(posted[0].origin, '*');
});

test('notifyWorkbench: is a no-op on a standalone page', () => {
  // window.parent === window is how every one of these pages loads when opened
  // directly. Posting there would be harmless but wasteful; the real point is
  // that the standalone pages behave identically to before the workbench.
  const { ui, posted } = load({ framed: false });
  ui.notifyWorkbench('notebook-saved');
  ui.notifyWorkbench('inputs-changed');

  assert.equal(posted.length, 0);
});

test('notifyWorkbench: a throwing parent does not propagate', () => {
  // A parent that navigated away mid-save throws on postMessage. The pane's own
  // save already succeeded, so losing the cross-pane hint must not surface as
  // an error in the caller's success path.
  const window = {
    location: { origin: 'https://chickadee.example' },
    document: { querySelector: () => null },
  };
  window.parent = { postMessage: () => { throw new Error('parent is gone'); } };
  const context = vm.createContext({ window, document: window.document, globalThis: {} });
  vm.runInContext(source, context);

  assert.doesNotThrow(() => window.ChickadeeUI.notifyWorkbench('notebook-saved'));
});
