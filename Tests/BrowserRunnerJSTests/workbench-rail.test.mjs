// Unit tests for Public/workbench-rail.js, the test suite in the workbench rail
// (notebook views NB6). The pure half builds the totals, the captions, the
// glyphs and the reveal target. The wiring half runs in a vm against a small
// fake page: the outline is fetched and drawn, an item reveals its cell, and a
// workbench event draws it again.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const Rail = require('../../Public/workbench-rail.js');
const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/workbench-rail.js'), 'utf8');
// The page loads chickadee-ui.js first, and this script builds its rows with
// ChickadeeUI.el (#2721), so each context runs the real one too.
const uiSource = fs.readFileSync(path.join(here, '../../Public/chickadee-ui.js'), 'utf8');

/// Runs chickadee-ui.js and then `source` in one context, as the page does.
function runWithUI(context) {
  vm.createContext(context);
  vm.runInContext(uiSource, context);
  context.ChickadeeUI = context.window.ChickadeeUI;
  vm.runInContext(source, context);
}

test('an item is passing, failing or not validated on the solution', () => {
  assert.equal(Rail.itemState({ solution: { result: 'pass' } }), 'pass');
  assert.equal(Rail.itemState({ solution: { result: 'timeout' } }), 'fail');
  assert.equal(Rail.itemState({ solution: null }), 'none');
  assert.equal(Rail.glyph('pass'), '✓');
  assert.equal(Rail.glyph('fail'), '✗');
  assert.equal(Rail.glyph('none'), '○');
});

test('the totals and the captions', () => {
  assert.equal(Rail.totalsText({ checks: 10, points: 9 }), '10 checks · 9 pts');
  assert.equal(Rail.totalsText({ checks: 1, points: 1 }), '1 check · 1 pt');
  assert.equal(Rail.sectionCaption({ label: 'Task 2', title: 'Task 2: Mean' }), 'Task 2');
  assert.equal(Rail.sectionCaption({ label: null, title: 'Setup' }), 'Setup');
  assert.equal(Rail.sectionCaption({ label: null, title: null }), 'Other checks');
});

test('an item reveals its name, or its section, or nothing', () => {
  assert.deepEqual({ ...Rail.revealTarget({ anchor: { kind: 'function', name: 'mean' } }) }, { name: 'mean' });
  assert.deepEqual({ ...Rail.revealTarget({ anchor: { kind: 'section', name: 'Task 1' } }) }, { section: 'Task 1' });
  assert.equal(Rail.revealTarget({ anchor: null }), null);
});

function element(tag) {
  return {
    tagName: tag, className: '', children: [], attributes: {}, listeners: {}, disabled: false, type: '',
    _text: '',
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); },
    set textContent(value) { this._text = value; this.children = []; },
    appendChild(child) { this.children.push(child); return child; },
    setAttribute(name, value) {
      this.attributes[name] = String(value);
      if (name === 'class') this.className = String(value);
    },
    getAttribute(name) { return this.attributes[name] ?? null; },
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
    all() { return [this, ...this.children.flatMap((c) => c.all())]; },
    querySelectorAll(selector) { return this.all().filter((n) => `.${n.className}` === selector); },
    removeAttribute(name) { delete this.attributes[name]; },
    click() { this.clicked = (this.clicked || 0) + 1; },
  };
}

const OUTLINE = {
  version: 1,
  validation: { status: 'failed', issues: [{ itemID: 'test_b.py', kind: 'failsOnSolution' }] },
  totals: { checks: 3, points: 4 },
  sections: [
    {
      id: 's1', title: 'Task 1: Count', label: 'Task 1', points: 3,
      items: [
        { id: 'test_a.py', name: 'test_a', anchor: { kind: 'function', name: 'count' }, solution: { result: 'pass' } },
        { id: 'test_b.py', name: 'test_b', anchor: { kind: 'section', name: 'Task 1: Count' }, solution: { result: 'fail' } },
      ],
    },
  ],
  unlinked: [{ id: 'test_c.py', name: 'test_c', anchor: null, solution: null }],
};

const ORIGIN = 'https://chickadee.test';

async function loadPage(outlines) {
  const executed = [];
  const listeners = {};
  const suite = element('div');
  const totals = element('p');
  const save = element('button');
  const saveStatus = element('span');
  const shell = {
    getAttribute: (name) => ({ 'data-suite-url': '/instructor/abc/suite-outline.json', 'data-assignment-id': 'abc' })[name] ?? null,
  };
  const elements = { 'wb-shell': shell, 'wb-rail-suite': suite, 'wb-rail-totals': totals, 'wb-save': save, 'wb-save-status': saveStatus };
  const fetched = [];
  const context = {
    window: {
      location: { origin: ORIGIN },
      addEventListener: (type, fn) => (listeners[type] = fn),
      chickadeeEditorCommand: async (command, args) => { executed.push([command, args]); return true; },
    },
    document: {
      getElementById: (id) => elements[id] ?? null,
      createElement: element,
      querySelector: (selector) => (selector === 'meta[name="csrf-token"]' ? { content: 'tok' } : null),
    },
    fetch: async (url, init) => {
      fetched.push(init && init.method ? [init.method, url, init.headers['x-csrf-token'], init.body] : url);
      return { ok: true, json: async () => outlines.shift() };
    },
  };
  context.self = context;
  runWithUI(context);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const items = () => suite.all().filter((n) => n.className === 'outline-row');
  const message = (data, origin = ORIGIN) => listeners.message({ origin, data });
  return { suite, totals, save, saveStatus, items, executed, fetched, listeners, message, api: context.ChickadeeWorkbenchRail };
}

test('the rail draws each section, then the unlinked items', async () => {
  const page = await loadPage([OUTLINE]);
  assert.deepEqual(page.fetched, ['/instructor/abc/suite-outline.json']);
  assert.equal(page.totals.textContent, '3 checks · 4 pts');
  const captions = page.suite.all().filter((n) => n.className === 'outline-caption').map((n) => n.textContent);
  assert.deepEqual(captions, ['Task 1', 'Not linked to a cell']);
  const items = page.items();
  assert.deepEqual(items.map((n) => n.getAttribute('data-item-id')), ['test_a.py', 'test_b.py', 'test_c.py']);
  assert.deepEqual(items.map((n) => n.getAttribute('data-status')), ['pass', 'fail', 'none']);
  assert.match(items[1].textContent, /test_b, Fails on the solution/);
  assert.equal(items[2].disabled, true);
});

test('the outline goes to the editor, and an item selects its card', async () => {
  const page = await loadPage([OUTLINE]);
  assert.equal(page.executed[0][0], 'chickadee:set-suite');
  assert.equal(page.executed[0][1].suite.totals.checks, 3);
  page.items()[1].listeners.click.forEach((fn) => fn());
  assert.equal(JSON.stringify(page.executed.at(-1)), JSON.stringify(['chickadee:select-item', { itemID: 'test_b.py' }]));
  assert.equal(page.items()[1].getAttribute('aria-current'), 'true');
  assert.equal(page.items()[0].getAttribute('aria-current'), null);
});

test('a new editor document gets the outline again on its first ck:kernel', async () => {
  const page = await loadPage([OUTLINE]);
  page.message({ ck: 'ck:kernel', status: 'idle' });
  assert.equal(page.executed.filter(([c]) => c === 'chickadee:set-suite').length, 1);
  page.message({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'boot_start' });
  page.message({ ck: 'ck:kernel', status: 'idle' });
  assert.equal(page.executed.filter(([c]) => c === 'chickadee:set-suite').length, 2);
});

test('a card asks the page: Run again saves, and Pin saves the pin', async () => {
  const page = await loadPage([OUTLINE, OUTLINE]);
  page.message({ ck: 'ck:run-again', itemID: 'test_b.py' });
  assert.equal(page.save.clicked, 1);
  page.message({ ck: 'ck:pin', itemID: 'test_b.py', anchor: 'total' });
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(page.fetched[1], ['PUT', '/instructor/abc/suite-anchor', 'tok', '{"script":"test_b.py","anchor":"total"}']);
  assert.equal(page.saveStatus.textContent, 'Pinned to total');
  assert.equal(page.fetched.length, 3);
  page.message({ ck: 'ck:pin-refused', itemID: 'test_b.py' });
  assert.equal(page.saveStatus.textContent, 'That cell defines no name to pin to');
  page.message({ ck: 'ck:run-again' }, 'https://evil.test');
  assert.equal(page.save.clicked, 1);
});

test('findItem and cssEscape', () => {
  assert.equal(Rail.findItem(OUTLINE, 'test_c.py').name, 'test_c');
  assert.equal(Rail.findItem(OUTLINE, 'nope'), null);
  assert.equal(Rail.cssEscape('a"b'), 'a\\"b');
});

test('a workbench event draws the rail again', async () => {
  const fixed = structuredClone(OUTLINE);
  fixed.sections[0].items[1].solution = { result: 'pass' };
  const page = await loadPage([OUTLINE, fixed]);
  page.listeners['chickadee:workbench']({ detail: { type: 'notebook-saved' } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(page.fetched.length, 2);
  assert.deepEqual(page.items().map((n) => n.getAttribute('data-status')), ['pass', 'pass', 'none']);
});
