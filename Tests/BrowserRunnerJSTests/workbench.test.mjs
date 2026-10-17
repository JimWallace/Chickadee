// Unit tests for the assignment workbench shell's pure logic: which notebook
// a view-switch or Files-table click resolves to. (The splitter and its clamp
// went with the two-pane layout, notebook views NB6.)

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Workbench = require('../../Public/workbench.js');

// The server publishes a `template` destination only for a notebook that
// actually carries {{placeholders}}. These fixtures model an assignment that
// has one and a solution that does not.
// Real-shaped paths, not placeholders: resolvePane only accepts URLs matching
// the workbench-route shape, so a toy path here would be rejected and the tests
// would be exercising the reject path by accident.
//
// #1266: these address the workbench itself, not the notebook page. Switching
// notebooks is a navigation of this page (the kernel reboots either way), so
// the destinations are workbench URLs and the sink is `location.assign`.
const WB = '/instructor/Ab12Cd/workbench';
const URLS = {
  'assignment:personalized': WB + '?file=assignment&view=personalized',
  'assignment:template': WB + '?file=assignment&view=template',
  'solution:personalized': WB + '?file=solution&view=personalized',
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

test('resolvePane: refuses a destination that is not a workbench path', () => {
  // The destination map arrives as DOM text and the sink is a navigation, so a
  // javascript: URL there would be script execution in this origin. The server
  // never produces one — the point is that this file no longer depends on that.
  const hostile = {
    'assignment:personalized': 'javascript:alert(1)',
    'assignment:template': '//evil.example/steal',
    'solution:personalized': 'https://evil.example/steal',
  };
  assert.equal(Workbench.resolvePane(hostile, 'assignment', 'personalized'), null);
  assert.equal(Workbench.resolvePane(hostile, 'assignment', 'template'), null);
  assert.equal(Workbench.resolvePane(hostile, 'solution', 'personalized'), null);
});

test('resolvePane: a bad entry falls through rather than being served', () => {
  // A malformed template entry must degrade to the rendered view, not hand the
  // caller a destination that will be rejected at the navigation sink and leave
  // the click doing nothing at all.
  const mixed = {
    'assignment:personalized': WB + '?file=assignment&view=personalized',
    'assignment:template': 'javascript:alert(1)',
  };
  const p = Workbench.resolvePane(mixed, 'assignment', 'template');
  assert.equal(p.view, 'personalized');
  assert.equal(p.url, mixed['assignment:personalized']);
});

test('resolvePane: reports nothing for a file that has no destinations', () => {
  // An assignment with no reference solution renders no Solution tab, so this
  // is unreachable by clicking — but returning null rather than a broken URL is
  // what keeps it that way if the markup and the table ever disagree.
  assert.equal(Workbench.resolvePane(URLS, 'nosuchfile', 'personalized'), null);
  assert.equal(Workbench.resolvePane({}, 'assignment', 'personalized'), null);
});
