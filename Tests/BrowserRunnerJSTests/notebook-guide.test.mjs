// Unit tests for Public/notebook-guide.js, the student's task outline on the
// notebook page (notebook views NB4). The pure half builds the attempt card,
// the row labels and the reveal target. The wiring half runs in a vm against a
// small fake page: the guide is fetched, drawn and sent to the extension, the
// extension's ck:tasks updates the rows, and ck:active-cell marks one row.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const Guide = require('../../Public/notebook-guide.js');
const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/notebook-guide.js'), 'utf8');
const ORIGIN = 'https://chickadee.test';

test('each status has a glyph, and an unknown one is the open circle', () => {
  assert.equal(Guide.glyph('pass'), '✓');
  assert.equal(Guide.glyph('fail'), '✗');
  assert.equal(Guide.glyph('starter'), '!');
  assert.equal(Guide.glyph(null), '○');
});

test('each status has words for a screen reader, and none has none', () => {
  assert.equal(Guide.statusWord('pass'), 'Passed');
  assert.equal(Guide.statusWord('fail'), 'Checks failed');
  assert.equal(Guide.statusWord('starter'), 'Still the starter code');
  assert.equal(Guide.statusWord(null), '');
});

test('the attempt card before a submission, while grading, and after', () => {
  assert.equal(Guide.attemptCard(null).title, 'Not submitted yet');
  assert.equal(Guide.attemptCard(null).link, null);

  const pending = Guide.attemptCard({ number: 3, pending: true });
  assert.equal(pending.detail, 'Being graded…');
  assert.equal(pending.short, 'Attempt 3 · grading');

  const graded = Guide.attemptCard({ number: 2, pending: false, percent: 75, points: 7.5, pointsPossible: 10, url: '/r/2' });
  assert.equal(graded.title, 'Attempt 2');
  assert.equal(graded.percent, '75%');
  assert.equal(graded.detail, '7.5 of 10 points');
  assert.equal(graded.link.href, '/r/2');
  assert.equal(graded.short, 'Attempt 2 · 75%');
});

test('a row has a numbered wide label and a short chip label', () => {
  assert.deepEqual(
    JSON.parse(JSON.stringify(Guide.rowLabels({ name: 'Average heart rate', label: null }, 1))),
    { wide: '2. Average heart rate', short: 'Task 2' });
  assert.equal(Guide.rowLabels({ name: 'x', label: 'Part A' }, 0).short, 'Part A');
});

test('a row reveals its heading, else its first anchor, else nothing', () => {
  assert.deepEqual({ ...Guide.revealTarget({ heading: 'Task 1', anchors: [] }) }, { section: 'Task 1' });
  assert.deepEqual({ ...Guide.revealTarget({ anchors: [{ kind: 'function', name: 'mean' }] }) }, { name: 'mean' });
  assert.deepEqual({ ...Guide.revealTarget({ anchors: [{ kind: 'section', name: 'Setup' }] }) }, { section: 'Setup' });
  assert.equal(Guide.revealTarget({ anchors: [] }), null);
});

// A minimal element: enough of the DOM for the outline to draw into.
function element(tag) {
  const node = {
    tagName: tag, className: '', children: [], attributes: {}, listeners: {}, hidden: true,
    _text: '',
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); },
    set textContent(value) { this._text = value; this.children = []; },
    appendChild(child) { this.children.push(child); return child; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return this.attributes[name] ?? null; },
    removeAttribute(name) { delete this.attributes[name]; },
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
    all() { return [this, ...this.children.flatMap((c) => c.all())]; },
    querySelectorAll(selector) {
      const name = selector.replace(/^\./, '');
      const found = this.all().slice(1).filter((n) => n.className.split(' ').includes(name));
      return { forEach: (fn) => found.forEach(fn) };
    },
  };
  return node;
}

const GUIDE = {
  version: 1,
  attempt: { number: 1, pending: false, percent: 50, points: 1, pointsPossible: 2, url: '/r/1' },
  tasks: [
    { sectionID: 's1', heading: 'Load', name: 'Load the data', points: 1, anchors: [], status: 'pass', checks: [], hiddenCount: 0 },
    { sectionID: 's2', heading: 'Mean', name: 'Mean heart rate', points: 1, anchors: [], status: 'fail', checks: [], hiddenCount: 0 },
  ],
  reflections: [],
  starterSources: {},
};

async function loadPage(guide = GUIDE) {
  const executed = [];
  const listeners = { message: [] };
  const nav = element('nav');
  const frame = { getAttribute: (name) => (name === 'data-guide-url' ? '/testsetups/abc/notebook-guide.json' : null) };
  const elements = { 'nb-outline': nav, 'jl-frame': frame };
  const window = {
    location: { origin: ORIGIN },
    addEventListener: (type, fn) => listeners[type]?.push(fn),
    chickadeeEditorCommand: async (command, args) => { executed.push([command, args]); return true; },
  };
  const document = {
    getElementById: (id) => elements[id] ?? null,
    createElement: element,
  };
  const fetched = [];
  const fetch = async (url) => { fetched.push(url); return { ok: true, json: async () => guide }; };
  const context = { window, document, fetch };
  context.self = context;
  vm.runInNewContext(source, context);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const message = (data, origin = ORIGIN) => listeners.message.forEach((fn) => fn({ origin, data }));
  const rows = () => {
    const found = [];
    nav.querySelectorAll('.outline-row').forEach((r) => found.push(r));
    return found;
  };
  return { executed, fetched, nav, message, rows, api: context.ChickadeeNotebookGuide };
}

test('the guide is fetched, drawn as one row per task, and sent to the editor', async () => {
  const page = await loadPage();
  assert.deepEqual(page.fetched, ['/testsetups/abc/notebook-guide.json']);
  assert.equal(page.nav.hidden, false);
  const rows = page.rows();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].getAttribute('data-status'), 'pass');
  assert.equal(rows[1].getAttribute('data-status'), 'fail');
  assert.match(rows[1].textContent, /2\. Mean heart rate/);
  assert.match(page.nav.textContent, /Attempt 1/);
  const sent = page.executed.filter(([c]) => c === 'chickadee:set-guide');
  assert.equal(sent.length, 1);
  assert.equal(sent[0][1].guide.tasks.length, 2);
});

test('ck:tasks from the extension updates a row status', async () => {
  const page = await loadPage();
  page.message({ ck: 'ck:tasks', tasks: [{ sectionID: 's1', status: 'pass' }, { sectionID: 's2', status: 'starter' }] });
  assert.match(page.rows()[1].textContent, /Still the starter code/);
  const rows = page.rows();
  assert.equal(rows[0].getAttribute('data-status'), 'pass');
  assert.equal(rows[1].getAttribute('data-status'), 'starter');
});

test('ck:active-cell marks the task under the cursor, and only that task', async () => {
  const page = await loadPage();
  page.message({ ck: 'ck:active-cell', task: 's1' });
  assert.equal(page.rows()[0].getAttribute('aria-current'), 'step');
  page.message({ ck: 'ck:active-cell', task: 's2' });
  assert.equal(page.rows()[0].getAttribute('aria-current'), null);
  assert.equal(page.rows()[1].getAttribute('aria-current'), 'step');
  page.message({ ck: 'ck:active-cell', task: null });
  assert.equal(page.rows()[1].getAttribute('aria-current'), null);
});

test('a row click reveals its task in the editor', async () => {
  const page = await loadPage();
  page.rows()[1].listeners.click.forEach((fn) => fn());
  const reveal = page.executed.find(([c]) => c === 'chickadee:reveal');
  assert.equal(JSON.stringify(reveal[1]), '{"section":"Mean"}');
});

test('a new editor document gets the guide again on its first ck:kernel', async () => {
  const page = await loadPage();
  page.message({ ck: 'ck:kernel', status: 'idle' });
  assert.equal(page.executed.filter(([c]) => c === 'chickadee:set-guide').length, 1);
  page.message({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'boot_start' });
  page.message({ ck: 'ck:kernel', status: 'starting' });
  page.message({ ck: 'ck:kernel', status: 'idle' });
  assert.equal(page.executed.filter(([c]) => c === 'chickadee:set-guide').length, 2);
});

test('two tasks with no section keep their own status', async () => {
  const guide = { ...GUIDE, tasks: GUIDE.tasks.map((t) => ({ ...t, sectionID: null })) };
  const page = await loadPage(guide);
  page.message({ ck: 'ck:tasks', tasks: [{ sectionID: null, status: 'starter' }, { sectionID: null, status: 'fail' }] });
  assert.equal(page.rows()[0].getAttribute('data-status'), 'starter');
  assert.equal(page.rows()[1].getAttribute('data-status'), 'fail');
});

test('a reflection row follows the extension, and reveals its cell by tag', async () => {
  const page = await loadPage({ ...GUIDE, reflections: [{ label: 'Reflection', tag: 'reflection', readBy: 'course staff' }] });
  const reflection = () => page.rows()[2];
  assert.equal(page.rows().length, 3);
  assert.equal(reflection().getAttribute('data-status'), 'empty');
  assert.match(reflection().textContent, /Reflection, Empty/);
  page.message({ ck: 'ck:tasks', tasks: [], reflections: [{ tag: 'reflection', status: 'written' }] });
  assert.equal(reflection().getAttribute('data-status'), 'written');
  reflection().listeners.click.forEach((fn) => fn());
  const reveal = page.executed.find(([c]) => c === 'chickadee:reveal');
  assert.equal(JSON.stringify(reveal[1]), '{"tag":"reflection"}');
});

test('a message from another origin is ignored', async () => {
  const page = await loadPage();
  page.message({ ck: 'ck:tasks', tasks: [{ sectionID: 's1', status: 'fail' }, { sectionID: 's2', status: 'fail' }] }, 'https://evil.test');
  assert.equal(page.rows()[0].getAttribute('data-status'), 'pass');
});

test('a guide with no task list draws nothing', async () => {
  const page = await loadPage({ version: 1 });
  assert.equal(page.nav.hidden, true);
  assert.equal(page.executed.length, 0);
});
