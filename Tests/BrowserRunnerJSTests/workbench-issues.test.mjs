// Unit tests for the issues pill of Public/workbench-rail.js (notebook views
// NB8): what the pill and its note say for each validation state, the amber
// state of a test the starter passes for points, and a pill that steps
// through the issues. A starter that did not run is said in the note.

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

const issue = (itemID, kind) => ({ itemID, kind });

test('the pill counts the issues of each kind', () => {
  const both = Rail.pillState({
    status: 'failed',
    issues: [issue('a', 'failsOnSolution'), issue('b', 'passesOnStarter'), issue('c', 'passesOnStarter')],
  });
  assert.equal(both.text, '! 3 issues');
  assert.equal(both.note, '1 fails on the solution · 2 pass on the starter');
  assert.equal(both.tone, 'err');
  assert.deepEqual([...both.issues], ['a', 'b', 'c']);

  const free = Rail.pillState({ status: 'passed', issues: [issue('b', 'passesOnStarter')] });
  assert.equal(free.text, '! 1 issue');
  assert.equal(free.note, '1 passes on the starter');
  assert.equal(free.tone, 'warn');
});

test('with no issues, the pill says validated, and how far', () => {
  const both = Rail.pillState({ status: 'passed', issues: [], starterRunAt: '2026-10-16T12:00:00Z' });
  assert.equal(both.text, '✓ Validated');
  assert.equal(both.note, 'Every test passes on the solution; none earns points on the starter');
  assert.equal(both.tone, 'ok');
  assert.equal(Rail.pillState({ status: 'passed', issues: [] }).note, '');
  const broken = { status: 'passed', issues: [], starterRunAt: '2026-10-16T12:00:00Z', starterError: 'SyntaxError' };
  assert.equal(Rail.pillState(broken).text, '✓ Validated');
  assert.equal(Rail.pillState(broken).note, 'Starter didn’t run: SyntaxError');
  assert.equal(Rail.clip('x'.repeat(80)).length, 60);
  assert.equal(Rail.pillState({ status: 'pending', issues: [issue('a', 'failsOnSolution')] }).text, 'Validating…');
  // The server's wording stays for the states the outline cannot improve.
  assert.equal(Rail.pillState({ status: 'no-runner', issues: [] }), null);
  assert.equal(Rail.pillState({ status: null, issues: [] }), null);
});

test('a test that the starter passes for points is amber', () => {
  const item = { solution: { result: 'pass' }, starter: { result: 'pass' }, points: 2 };
  assert.equal(Rail.itemState(item), 'starter');
  assert.equal(Rail.glyph('starter'), '!');
  assert.equal(Rail.itemState({ ...item, points: 0 }), 'pass');
  assert.equal(Rail.itemState({ ...item, starter: { result: 'fail' } }), 'pass');
  assert.equal(Rail.itemState({ ...item, solution: { result: 'fail' } }), 'fail');
});

function element(tag) {
  return {
    tagName: tag, className: '', children: [], attributes: {}, listeners: {}, hidden: false, type: '',
    _text: '',
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); },
    set textContent(value) { this._text = value; this.children = []; },
    appendChild(child) { this.children.push(child); return child; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return this.attributes[name] ?? null; },
    removeAttribute(name) { delete this.attributes[name]; },
    classList: {
      names: new Set(),
      toggle(name, on) { if (on) this.names.add(name); else this.names.delete(name); },
      remove(name) { this.names.delete(name); },
    },
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
    all() { return [this, ...this.children.flatMap((c) => c.all())]; },
    querySelectorAll(selector) { return this.all().filter((n) => `.${n.className}` === selector); },
  };
}

const OUTLINE = {
  version: 1,
  validation: {
    status: 'failed',
    starterRunAt: '2026-10-16T12:00:00Z',
    issues: [issue('test_a.py', 'failsOnSolution'), issue('test_b.py', 'passesOnStarter')],
  },
  totals: { checks: 2, points: 2 },
  sections: [
    {
      id: 's1', title: 'Task 1', label: 'Task 1', points: 2,
      items: [
        { id: 'test_a.py', name: 'test_a', points: 1, anchor: { kind: 'function', name: 'f' }, solution: { result: 'fail' } },
        {
          id: 'test_b.py', name: 'test_b', points: 1, anchor: { kind: 'function', name: 'g' },
          solution: { result: 'pass' }, starter: { result: 'pass' },
        },
      ],
    },
  ],
  unlinked: [],
};

async function loadPage(outlines) {
  const executed = [];
  const listeners = {};
  const elements = {
    'wb-shell': { getAttribute: (name) => (name === 'data-suite-url' ? '/instructor/abc/suite-outline.json' : null) },
    'wb-rail-suite': element('div'),
    'wb-rail-totals': element('p'),
    'wb-validation': element('span'),
    'wb-issues': element('button'),
    'wb-validation-note': element('span'),
  };
  elements['wb-issues'].hidden = true;
  const context = {
    window: {
      location: { origin: 'https://chickadee.test' },
      addEventListener: (type, fn) => (listeners[type] = fn),
      chickadeeEditorCommand: async (command, args) => { executed.push([command, args]); return true; },
    },
    document: { getElementById: (id) => elements[id] ?? null, createElement: element, querySelector: () => null },
    fetch: async () => ({ ok: true, json: async () => outlines.shift() }),
  };
  context.self = context;
  vm.runInNewContext(source, context);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const redraw = async () => {
    listeners['chickadee:workbench']({ detail: { type: 'notebook-saved' } });
    await new Promise((resolve) => setTimeout(resolve, 0));
  };
  return { elements, executed, redraw };
}

test('with issues, the pill is a button that steps through them', async () => {
  const page = await loadPage([OUTLINE]);
  const button = page.elements['wb-issues'];
  assert.equal(button.hidden, false);
  assert.equal(page.elements['wb-validation'].hidden, true);
  assert.equal(button.textContent, '! 2 issues');
  assert.equal(button.getAttribute('aria-label'), '2 issues: select the next');
  assert.equal(page.elements['wb-validation-note'].textContent, '1 fails on the solution · 1 passes on the starter');
  const rows = page.elements['wb-rail-suite'].all().filter((n) => n.className === 'outline-row');
  assert.deepEqual(rows.map((n) => n.getAttribute('data-status')), ['fail', 'starter']);
  const click = () => button.listeners.click.forEach((fn) => fn());
  click();
  click();
  click();
  const selected = page.executed.filter(([c]) => c === 'chickadee:select-item').map(([, a]) => a.itemID);
  assert.deepEqual(selected, ['test_a.py', 'test_b.py', 'test_a.py']);
  assert.equal(rows[0].getAttribute('aria-current'), 'true');
});

test('a starter that did not run is said in the note, and the pill goes back to the chip', async () => {
  const broken = structuredClone(OUTLINE);
  broken.validation = {
    status: 'passed', issues: [], starterRunAt: '2026-10-16T13:00:00Z', starterError: 'SyntaxError: bad input',
  };
  const page = await loadPage([broken, structuredClone(OUTLINE)]);
  const note = page.elements['wb-validation-note'];
  assert.equal(note.textContent, 'Starter didn’t run: SyntaxError: bad input');
  assert.equal(note.hidden, false);
  assert.equal(page.elements['wb-issues'].hidden, true);
  assert.equal(page.elements['wb-validation'].textContent, '✓ Validated');
  assert.equal(page.elements['wb-validation'].classList.names.has('chip-ok'), true);
  await page.redraw();
  assert.equal(page.elements['wb-issues'].hidden, false);
  assert.equal(page.elements['wb-validation'].hidden, true);
});
