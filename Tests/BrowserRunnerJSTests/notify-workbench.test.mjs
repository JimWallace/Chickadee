// Unit tests for ChickadeeUI.notifyWorkbench — the note the assignment
// workbench listens for when something it is displaying goes stale.
//
// Re-specified in #1266. It used to `postMessage` to `window.parent`, because
// the workbench composed the editor and the notebook as two iframes and the
// listener was in a different document. One document means one event bus: it
// now dispatches a `chickadee:workbench` CustomEvent on this window, and
// workbench.js listens for it directly.
//
// The origin checks that used to matter here are moot for the same reason —
// nothing crosses a document boundary any more, so there is no boundary a
// framing third party could forge across, and no target origin to get wrong.
//
// What still matters: three pages call this (the notebook editor, the
// global-inputs editor, the section-inputs editor) and every one of them is
// also reachable directly as a top-level page with nothing listening. Firing
// there must be harmless rather than an error in a caller's success path.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

/// Loads chickadee-ui.js against a stub window, recording dispatched events.
///
/// `opts.customEventThrows` models a browser with no usable CustomEvent
/// constructor — the one failure mode the implementation still guards.
function load(opts = {}) {
  const dispatched = [];
  const window = {
    location: { origin: 'https://chickadee.example' },
    document: { querySelector: () => null },
    dispatchEvent: (e) => { dispatched.push(e); return true; },
    addEventListener: () => {},
  };
  window.parent = window;

  class StubCustomEvent {
    constructor(type, init) {
      if (opts.customEventThrows) throw new Error('CustomEvent unavailable');
      this.type = type;
      this.detail = init && init.detail;
    }
  }

  const context = vm.createContext({
    window,
    document: window.document,
    globalThis: {},
    CustomEvent: StubCustomEvent,
  });
  vm.runInContext(source, context);
  return { ui: window.ChickadeeUI, dispatched };
}

test('notifyWorkbench: dispatches a same-document event carrying the type', () => {
  const { ui, dispatched } = load();
  ui.notifyWorkbench('notebook-saved');

  assert.equal(dispatched.length, 1);
  assert.equal(dispatched[0].type, 'chickadee:workbench');
  assert.equal(dispatched[0].detail.type, 'notebook-saved');
});

test('notifyWorkbench: each notification kind rides through unchanged', () => {
  // workbench.js switches on this value, so a mangled or dropped type is a
  // silently missing staleness chip rather than a visible failure.
  const { ui, dispatched } = load();
  ui.notifyWorkbench('inputs-changed');
  ui.notifyWorkbench('notebook-saved');

  assert.deepEqual(dispatched.map((e) => e.detail.type), ['inputs-changed', 'notebook-saved']);
});

test('notifyWorkbench: fires unconditionally, with no parent-frame check', () => {
  // Deliberate: on a page with nothing listening, dispatching an event nobody
  // handles costs nothing, and that is simpler than each caller knowing which
  // surface it is on. The old implementation returned early when
  // `window.parent === window`, which — now that it is always true — would have
  // made this a permanent no-op.
  const { ui, dispatched } = load();
  ui.notifyWorkbench('notebook-saved');

  assert.equal(dispatched.length, 1, 'notifyWorkbench went silent on a top-level page');
});

test('notifyWorkbench: a failure to construct the event does not propagate', () => {
  // The caller has just saved successfully. Losing the staleness hint must not
  // surface as an error in that success path.
  const { ui, dispatched } = load({ customEventThrows: true });

  assert.doesNotThrow(() => ui.notifyWorkbench('notebook-saved'));
  assert.equal(dispatched.length, 0);
});
