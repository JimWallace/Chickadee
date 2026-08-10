// Tests/BrowserRunnerJSTests/cell-perf-patch.test.mjs
//
// Unit guards for Public/jl-cell-perf-patch.js — the runtime coalescer for
// Notebook 7's per-output forced reflow (upstream CodeCell.updatePromptOverlayIcon
// reads clientHeight per IOPub message; the measured cause of the Aug 2026
// `page_unresponsive` freezes). Driven via its __CK_CELL_PERF_PATCH_TEST_HOOKS__
// seam, same pattern as kernel-diagnostics.test.mjs.
//
// The contract pinned here:
//   * prototype discovery walks a live code cell to the prototype OWNING the
//     method, and gives up (null) when the shape is unfamiliar — fail-safe;
//   * the wrapper coalesces any number of same-frame calls per cell into ONE
//     original call on the next animation frame, per-instance;
//   * a disposed cell's queued update is dropped, and the patch is idempotent
//     (re-running tryPatch never double-wraps);
//   * the auto-collapse replacement for the disabled `:scroll-output` plugin
//     keeps upstream's semantics: user-set `scrolled` metadata wins, the
//     threshold is 1.3 × fontSize × 100, and the class toggles both ways.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const patchSource = await fs.readFile(path.resolve('Public/jl-cell-perf-patch.js'), 'utf8');

function loadPatch() {
  const hooks = {};
  const context = {
    console, JSON, Error, Object,
    setTimeout: () => 0,   // don't run the retry loop; tests drive tryPatch directly
    clearTimeout: () => {},
    __CK_CELL_PERF_PATCH_TEST_HOOKS__: hooks,
  };
  context.globalThis = context;
  vm.runInNewContext(patchSource, context, { filename: 'jl-cell-perf-patch.js' });
  return hooks.exports;
}

// A minimal stand-in for the upstream widget tree: a CodeCell "class" whose
// prototype owns updatePromptOverlayIcon, an app shell exposing the notebook's
// cells, and a manual rAF queue the test flushes like a frame boundary.
function makeEditorWorld({ cellCount = 2 } = {}) {
  const calls = [];
  function CodeCell(name) { this.name = name; this.model = { type: 'code' }; }
  CodeCell.prototype.updatePromptOverlayIcon = function () { calls.push(this.name); };
  const cells = [];
  for (let i = 0; i < cellCount; i++) cells.push(new CodeCell('cell' + i));
  const win = {
    jupyterapp: { shell: { currentWidget: { content: { widgets: cells } } } },
  };
  const rafQueue = [];
  const raf = (fn) => { rafQueue.push(fn); };
  const flushFrame = () => { const q = rafQueue.splice(0); q.forEach((fn) => fn()); };
  return { win, cells, calls, proto: CodeCell.prototype, raf, flushFrame };
}

test('finds the prototype that owns updatePromptOverlayIcon from a live cell', () => {
  const { findCodeCellPrototype } = loadPatch();
  const world = makeEditorWorld();
  assert.equal(findCodeCellPrototype(world.win), world.proto);
});

test('gives up (null) when the editor shape is unfamiliar — fail-safe', () => {
  const { findCodeCellPrototype } = loadPatch();
  // No app at all.
  assert.equal(findCodeCellPrototype({}), null);
  // Cells present but no code cell owns the method (upstream shape changed).
  const world = makeEditorWorld();
  delete world.proto.updatePromptOverlayIcon;
  assert.equal(findCodeCellPrototype(world.win), null);
  // Markdown-only notebook: nothing to patch.
  const mdOnly = { jupyterapp: { shell: { currentWidget: { content: { widgets: [{ model: { type: 'markdown' } }] } } } } };
  assert.equal(findCodeCellPrototype(mdOnly), null);
});

test('coalesces a burst of same-frame calls into one original call per cell', () => {
  const { tryPatch } = loadPatch();
  const world = makeEditorWorld({ cellCount: 2 });
  assert.equal(tryPatch(world.win, world.raf), true);

  // A burst: one cell hit 50 times, the other 3 times — like an output storm.
  for (let i = 0; i < 50; i++) world.cells[0].updatePromptOverlayIcon();
  for (let i = 0; i < 3; i++) world.cells[1].updatePromptOverlayIcon();
  assert.deepEqual(world.calls, []);           // nothing ran synchronously
  world.flushFrame();
  assert.deepEqual(world.calls.sort(), ['cell0', 'cell1']);  // once each

  // The next frame's burst coalesces again (the flag resets per frame).
  world.calls.length = 0;
  world.cells[0].updatePromptOverlayIcon();
  world.cells[0].updatePromptOverlayIcon();
  world.flushFrame();
  assert.deepEqual(world.calls, ['cell0']);
});

test('a disposed cell\'s queued update is dropped', () => {
  const { tryPatch } = loadPatch();
  const world = makeEditorWorld({ cellCount: 1 });
  assert.equal(tryPatch(world.win, world.raf), true);
  world.cells[0].updatePromptOverlayIcon();
  world.cells[0].isDisposed = true;
  world.flushFrame();
  assert.deepEqual(world.calls, []);
});

// A cell mock with enough surface for the auto-collapse check: an output-area
// node with a controllable scrollHeight, class toggling, and cell metadata.
function makeScrollCell({ scrollHeight = 0, fontSize = '', metadata = {} } = {}) {
  const classes = new Set();
  return {
    model: { type: 'code', getMetadata: (k) => metadata[k] },
    outputArea: { node: { scrollHeight, style: { fontSize } } },
    toggleClass(cls, on) { on ? classes.add(cls) : classes.delete(cls); },
    hasScrolled: () => classes.has('jp-mod-outputsScrolled'),
  };
}

test('autoScrollCheck collapses past the upstream threshold and un-collapses below it', () => {
  const { autoScrollCheck } = loadPatch();
  // Default font size 14px → threshold 1.3 * 14 * 100 = 1820.
  const cell = makeScrollCell({ scrollHeight: 1821 });
  autoScrollCheck(cell);
  assert.equal(cell.hasScrolled(), true);
  cell.outputArea.node.scrollHeight = 1820;   // at the threshold: NOT scrolled (strict >)
  autoScrollCheck(cell);
  assert.equal(cell.hasScrolled(), false);
});

test('autoScrollCheck honors an explicit output-area font size', () => {
  const { autoScrollCheck } = loadPatch();
  // 10px font → threshold 1300.
  const cell = makeScrollCell({ scrollHeight: 1400, fontSize: '10px' });
  autoScrollCheck(cell);
  assert.equal(cell.hasScrolled(), true);
});

test('autoScrollCheck never overrides a user-set scrolled choice', () => {
  const { autoScrollCheck } = loadPatch();
  // The student explicitly un-scrolled a giant output: leave it alone.
  const cell = makeScrollCell({ scrollHeight: 99999, metadata: { scrolled: false } });
  autoScrollCheck(cell);
  assert.equal(cell.hasScrolled(), false);
});

test('the coalesced frame callback runs the auto-collapse check too', () => {
  const { tryPatch } = loadPatch();
  const world = makeEditorWorld({ cellCount: 1 });
  const cell = world.cells[0];
  const classes = new Set();
  cell.model.getMetadata = () => undefined;
  cell.outputArea = { node: { scrollHeight: 5000, style: { fontSize: '' } } };
  cell.toggleClass = (cls, on) => { on ? classes.add(cls) : classes.delete(cls); };
  assert.equal(tryPatch(world.win, world.raf), true);
  cell.updatePromptOverlayIcon();
  world.flushFrame();
  assert.deepEqual(world.calls, ['cell0']);          // original still ran
  assert.equal(classes.has('jp-mod-outputsScrolled'), true);  // and the collapse applied
});

test('re-patching is idempotent — the method is never double-wrapped', () => {
  const { tryPatch, findCodeCellPrototype } = loadPatch();
  const world = makeEditorWorld({ cellCount: 1 });
  assert.equal(tryPatch(world.win, world.raf), true);
  const wrappedOnce = world.proto.updatePromptOverlayIcon;
  // A second module instance (fresh page script vs. the same prototype —
  // e.g. after a soft remount) must recognize the wrap marker and leave it.
  const second = loadPatch();
  assert.equal(second.tryPatch(world.win, world.raf), true);
  assert.equal(world.proto.updatePromptOverlayIcon, wrappedOnce);
  // Still coalesces exactly once.
  world.cells[0].updatePromptOverlayIcon();
  world.cells[0].updatePromptOverlayIcon();
  world.flushFrame();
  assert.deepEqual(world.calls, ['cell0']);
});
