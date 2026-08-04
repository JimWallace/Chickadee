// Unit tests for the assignment workbench shell's pure logic: the splitter
// clamp, which notebook a tab click resolves to, and the collapse toggle.
//
// The clamp is the load-bearing piece. The notebook page hides its own editor
// below 640px and shows "open on a larger screen" instead — so a splitter that
// lets the notebook pane get too narrow does not merely look cramped, it
// replaces the editor with a notice. These tests pin the floor from both drag
// directions and at viewports too small to honour both floors at once.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Workbench = require('../../Public/workbench.js');

const NOTEBOOK_MIN = 720;
const EDIT_MIN = 380;
const SPLITTER = 8;

// A roomy desktop: 1920 - 8 - 720 = 1192px of headroom for the edit pane.
const WIDE = 1920;

test('clampLeftWidth: leaves a comfortable width untouched', () => {
  assert.equal(Workbench.clampLeftWidth(600, WIDE), 600);
});

test('clampLeftWidth: dragging left stops at the edit-pane floor', () => {
  assert.equal(Workbench.clampLeftWidth(100, WIDE), EDIT_MIN);
  assert.equal(Workbench.clampLeftWidth(0, WIDE), EDIT_MIN);
  assert.equal(Workbench.clampLeftWidth(-500, WIDE), EDIT_MIN);
});

test('clampLeftWidth: dragging right never starves the notebook pane', () => {
  const maxLeft = WIDE - SPLITTER - NOTEBOOK_MIN;
  assert.equal(Workbench.clampLeftWidth(WIDE, WIDE), maxLeft);
  assert.equal(Workbench.clampLeftWidth(maxLeft + 1, WIDE), maxLeft);
  assert.equal(Workbench.clampLeftWidth(999999, WIDE), maxLeft);
});

test('clampLeftWidth: the notebook pane keeps its floor at every drag position', () => {
  // Sweep the whole range at both a wide and a marginal viewport and assert the
  // invariant directly, rather than trusting the two endpoint cases above.
  for (const total of [WIDE, 1440, 1280, 1140]) {
    for (let desired = -200; desired <= total + 200; desired += 17) {
      const left = Workbench.clampLeftWidth(desired, total);
      const notebook = total - SPLITTER - left;
      assert.ok(
        notebook >= NOTEBOOK_MIN,
        `notebook pane ${notebook}px < ${NOTEBOOK_MIN}px (total=${total}, desired=${desired})`,
      );
    }
  }
});

test('clampLeftWidth: when both floors cannot fit, the edit pane yields', () => {
  // 900px cannot hold 720 + 8 + 380. The notebook is the pane with the hard
  // rendering cliff, so it keeps its width and the edit pane gives up the rest.
  const total = 900;
  const left = Workbench.clampLeftWidth(500, total);
  assert.ok(left < EDIT_MIN, 'edit pane should yield below its own floor');
  assert.equal(left, total - SPLITTER - NOTEBOOK_MIN);
  assert.ok(left >= 0, 'clamp must never return a negative width');
});

test('clampLeftWidth: a viewport narrower than the notebook floor clamps to zero, not negative', () => {
  assert.equal(Workbench.clampLeftWidth(300, 500), 0);
  assert.equal(Workbench.clampLeftWidth(0, 100), 0);
});

// The server publishes a `template` destination only for a notebook that
// actually carries {{placeholders}}. These fixtures model an assignment that
// has one and a solution that does not.
const URLS = {
  'assignment:personalized': '/n?file=assignment&view=personalized',
  'assignment:template': '/n?file=assignment&view=template',
  'solution:personalized': '/n?file=solution&view=personalized',
};

test('resolvePane: returns the exact destination when it exists', () => {
  const p = Workbench.resolvePane(URLS, 'assignment', 'template');
  assert.equal(p.key, 'assignment:template');
  assert.equal(p.view, 'template');
  assert.equal(p.url, URLS['assignment:template']);
});

test('resolvePane: falls back to the rendered view rather than doing nothing', () => {
  // Reachable by a normal click: view the assignment's template, then hit the
  // Solution tab. The solution has no template, and silently ignoring the click
  // would leave the author on the wrong notebook with the wrong tab lit.
  const p = Workbench.resolvePane(URLS, 'solution', 'template');
  assert.equal(p.view, 'personalized');
  assert.equal(p.key, 'solution:personalized');
});

test('resolvePane: reports nothing for a file that has no destinations', () => {
  // An assignment with no reference solution renders no Solution tab, so this
  // is unreachable by clicking — but returning null rather than a broken URL is
  // what keeps it that way if the markup and the table ever disagree.
  assert.equal(Workbench.resolvePane(URLS, 'nosuchfile', 'personalized'), null);
  assert.equal(Workbench.resolvePane({}, 'assignment', 'personalized'), null);
});

test('toggleCollapse: collapsing remembers the width to come back to', () => {
  const collapsed = Workbench.toggleCollapse({ collapsed: false, width: 640, restoreWidth: 0 });
  assert.deepEqual(collapsed, { collapsed: true, width: 0, restoreWidth: 640 });

  const expanded = Workbench.toggleCollapse(collapsed);
  assert.deepEqual(expanded, { collapsed: false, width: 640, restoreWidth: 640 });
});

test('toggleCollapse: collapsing twice does not lose the restore width', () => {
  // The failure this guards: a second collapse capturing the already-collapsed
  // width of 0 would leave the pane unrestorable, with no way back to the
  // editor short of dragging the splitter off the edge.
  let state = { collapsed: false, width: 500, restoreWidth: 0 };
  state = Workbench.toggleCollapse(state);
  state = Workbench.toggleCollapse(state); // expand
  state = Workbench.toggleCollapse(state); // collapse again
  assert.equal(state.collapsed, true);
  assert.equal(state.restoreWidth, 500);

  state = Workbench.toggleCollapse(state);
  assert.equal(state.width, 500, 'restoring must return the original width, not 0');
});

test('toggleCollapse: round-trips back to the starting state', () => {
  const start = { collapsed: false, width: 420, restoreWidth: 420 };
  assert.deepEqual(Workbench.toggleCollapse(Workbench.toggleCollapse(start)), start);
});
