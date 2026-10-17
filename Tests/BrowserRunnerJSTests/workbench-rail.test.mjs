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
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return this.attributes[name] ?? null; },
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
    all() { return [this, ...this.children.flatMap((c) => c.all())]; },
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

async function loadPage(outlines) {
  const executed = [];
  const listeners = {};
  const suite = element('div');
  const totals = element('p');
  const shell = { getAttribute: (name) => (name === 'data-suite-url' ? '/instructor/abc/suite-outline.json' : null) };
  const elements = { 'wb-shell': shell, 'wb-rail-suite': suite, 'wb-rail-totals': totals };
  const fetched = [];
  const context = {
    window: {
      addEventListener: (type, fn) => (listeners[type] = fn),
      chickadeeEditorCommand: async (command, args) => { executed.push([command, args]); return true; },
    },
    document: { getElementById: (id) => elements[id] ?? null, createElement: element },
    fetch: async (url) => { fetched.push(url); return { ok: true, json: async () => outlines.shift() }; },
  };
  context.self = context;
  vm.runInNewContext(source, context);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const items = () => suite.all().filter((n) => n.className === 'outline-row');
  return { suite, totals, items, executed, fetched, listeners, api: context.ChickadeeWorkbenchRail };
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

test('an item reveals its cell', async () => {
  const page = await loadPage([OUTLINE]);
  page.items()[0].listeners.click.forEach((fn) => fn());
  page.items()[1].listeners.click.forEach((fn) => fn());
  assert.equal(JSON.stringify(page.executed), JSON.stringify([
    ['chickadee:reveal', { name: 'count' }],
    ['chickadee:reveal', { section: 'Task 1: Count' }],
  ]));
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
