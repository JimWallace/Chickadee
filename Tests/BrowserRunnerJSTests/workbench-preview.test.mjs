// Unit tests for Preview as student in Public/workbench.js (notebook views
// NB6b): which view a pane says it shows, which view-switch control is
// pressed, and that a preview destination resolves like any other pane.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Workbench = require('../../Public/workbench.js');

test('a pane shows the template, the rendering, or one student', () => {
  assert.equal(Workbench.paneView('template'), 'template');
  assert.equal(Workbench.paneView('personalized'), 'personalized');
  assert.equal(Workbench.paneView('student:ab12cd34'), 'student:ab12cd34');
  // Anything else reads as the rendering, never as a preview.
  assert.equal(Workbench.paneView('student:<x>'), 'personalized');
  assert.equal(Workbench.paneView(null), 'personalized');
});

test('Starter is pressed for the starter, a student for their preview', () => {
  assert.equal(Workbench.controlPressed('assignment', null, 'assignment', 'template'), true);
  assert.equal(Workbench.controlPressed('assignment', null, 'assignment', 'student:ab12cd34'), false);
  assert.equal(Workbench.controlPressed('solution', null, 'assignment', 'template'), false);
  assert.equal(Workbench.controlPressed('assignment', 'student:ab12cd34', 'assignment', 'student:ab12cd34'), true);
  assert.equal(Workbench.controlPressed('assignment', 'student:ab12cd34', 'assignment', 'student:zz99'), false);
});

test('a preview destination resolves like any other pane', () => {
  const urls = {
    'assignment:personalized': '/instructor/abc/workbench?file=assignment&view=personalized',
    'assignment:student:ab12cd34': '/instructor/abc/workbench?file=assignment&view=personalized&as=ab12cd34',
  };
  const pane = Workbench.resolvePane(urls, 'assignment', 'student:ab12cd34');
  assert.equal(pane.url, urls['assignment:student:ab12cd34']);
  assert.equal(pane.view, 'student:ab12cd34');
  // A student with no destination falls back to the rendering.
  assert.equal(Workbench.resolvePane(urls, 'assignment', 'student:gone').view, 'personalized');
});
