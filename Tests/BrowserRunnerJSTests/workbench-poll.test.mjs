// Unit tests for the validation poll of Public/workbench-rail.js. A save
// queues a validation that a runner grades later, so the fetch right after
// the save sees "pending". The rail asks again until the result lands, then
// redraws the pill, and stops. Before this, the pill said "Validating…"
// until the page was reloaded.

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
const uiSource = fs.readFileSync(path.join(here, '../../Public/chickadee-ui.js'), 'utf8');
const appBarSource = fs.readFileSync(
  path.join(here, '../../Sources/APIServer/Views/WorkbenchAppBar.swift'), 'utf8');

test('the rail asks often at first, then less often, then stops', () => {
  const pending = { status: 'pending', issues: [] };
  assert.equal(Rail.pollDelay(pending, 0, 0), 2000);
  assert.equal(Rail.pollDelay(pending, 28000, 0), 2000);
  assert.equal(Rail.pollDelay(pending, 30000, 0), 5000);
  assert.equal(Rail.pollDelay(pending, 10 * 60 * 1000, 0), null);
  assert.equal(Rail.pollDelay(null, 0, 0), null);
});

test('a settled run stops the poll unless the starter run is behind', () => {
  const settled = {
    status: 'passed', issues: [],
    solutionRunAt: '2026-11-09T12:00:00Z', starterRunAt: '2026-11-09T12:00:05Z',
  };
  assert.equal(Rail.starterBehind(settled), false);
  assert.equal(Rail.pollDelay(settled, 0, 0), null);

  const behind = { ...settled, starterRunAt: '2026-11-09T11:00:00Z' };
  assert.equal(Rail.starterBehind(behind), true);
  assert.equal(Rail.pollDelay(behind, 0, 0), 5000);
  assert.equal(Rail.pollDelay(behind, 0, 12), null);
  assert.equal(Rail.starterBehind({ ...settled, starterRunAt: undefined }), true);

  // No solution run yet, or a state no runner will settle: no wait.
  assert.equal(Rail.starterBehind({ status: 'passed', issues: [] }), false);
  assert.equal(Rail.pollDelay({ status: 'no-runner', issues: [] }, 0, 0), null);
  assert.equal(Rail.pollDelay({ status: null, issues: [] }, 0, 0), null);
});

/// What the rail says for `status` with no issues: `pillState` first, then
/// the server's wording that `chipState` redraws, as `drawPill` does.
function railWording(status) {
  const validation = { status, issues: [] };
  return Rail.pillState(validation) ?? Rail.chipState(validation);
}

test('the rail says what the app bar says for each status', () => {
  // The switch cases of `pillText`, each a status and its wording.
  const body = appBarSource.slice(appBarSource.indexOf('var pillText'), appBarSource.indexOf('var pillClass'));
  const pairs = [...body.matchAll(/case "([a-z-]+)": "([^"]+)"/g)].map((m) => [m[1], m[2]]);
  assert.deepEqual(pairs.map(([status]) => status).sort(), ['failed', 'no-runner', 'passed', 'pending']);
  for (const [status, text] of pairs) assert.equal(railWording(status).text, text, status);
  assert.match(body, /default: "Not validated"/);
  assert.equal(railWording(null).text, 'Not validated');

  const classes = appBarSource.slice(appBarSource.indexOf('var pillClass'));
  assert.match(classes, /case "passed": "chip chip-ok"/);
  assert.match(classes, /case "failed", "no-runner": "chip chip-err"/);
  assert.equal(railWording('passed').tone, 'ok');
  assert.equal(railWording('failed').tone, 'err');
  assert.equal(railWording('no-runner').tone, 'err');
  assert.equal(railWording('pending').tone, '');
  assert.equal(railWording(null).tone, '');
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
  };
}

const outline = (validation) => ({
  version: 1, validation, totals: { checks: 0, points: 0 }, sections: [], unlinked: [],
});

const FAIL = Symbol('503');

/// The rail on a page with a fake clock: `tick()` runs the one timer due.
async function loadPage(responses) {
  const listeners = {};
  const timers = [];
  let fetches = 0;
  const elements = {
    'wb-shell': { getAttribute: (name) => (name === 'data-suite-url' ? '/instructor/abc/suite-outline.json' : null) },
    'wb-rail-suite': element('div'),
    'wb-rail-totals': element('p'),
    'wb-validation': element('span'),
    'wb-issues': element('button'),
    'wb-validation-note': element('span'),
  };
  const context = {
    window: {
      location: { origin: 'https://chickadee.test' },
      addEventListener: (type, fn) => (listeners[type] = fn),
      chickadeeEditorCommand: async () => true,
    },
    document: { getElementById: (id) => elements[id] ?? null, createElement: element, querySelector: () => null },
    // A response is an outline, `FAIL` for a 503, or a function that
    // returns a promise of one (a slow response).
    fetch: async () => {
      fetches += 1;
      let next = responses.length > 1 ? responses.shift() : responses[0];
      if (typeof next === 'function') next = await next();
      if (next === FAIL) return { ok: false, json: async () => null };
      return { ok: true, json: async () => structuredClone(next) };
    },
    setTimeout: (fn, delay) => { timers.push({ fn, delay }); return timers.length; },
    clearTimeout: (id) => { if (timers[id - 1]) timers[id - 1].fn = null; },
  };
  context.self = context;
  vm.createContext(context);
  vm.runInContext(uiSource, context);
  context.ChickadeeUI = context.window.ChickadeeUI;
  vm.runInContext(source, context);
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  await settle();
  const live = () => timers.filter((t) => t.fn);
  return {
    elements,
    fetches: () => fetches,
    live,
    async tick() {
      const due = live()[0];
      assert.ok(due, 'a poll is scheduled');
      const fn = due.fn;
      due.fn = null;
      fn();
      await settle();
      return due.delay;
    },
    async save() {
      listeners['chickadee:workbench']({ detail: { type: 'notebook-saved' } });
      await settle();
    },
  };
}

test('a pending validation is asked for again until it lands, then the pill says so', async () => {
  const pending = outline({ status: 'pending', issues: [] });
  const failed = outline({ status: 'failed', issues: [], solutionRunAt: '2026-11-09T12:00:00Z',
    starterRunAt: '2026-11-09T12:00:05Z' });
  const page = await loadPage([pending, pending, failed]);
  const chip = page.elements['wb-validation'];
  assert.equal(chip.textContent, 'Validating…');
  assert.equal(await page.tick(), 2000);
  assert.equal(chip.textContent, 'Validating…');
  await page.tick();
  assert.equal(chip.textContent, '✗ Validation failed');
  assert.equal(chip.classList.names.has('chip-err'), true);
  assert.equal(page.fetches(), 3);
  assert.equal(page.live().length, 0, 'the poll stops once the run has settled');
});

test('after a save the rail waits for the starter run; a page load does not', async () => {
  const solutionOnly = outline({ status: 'passed', issues: [], solutionRunAt: '2026-11-09T12:00:00Z' });
  const both = outline({ status: 'passed', issues: [], solutionRunAt: '2026-11-09T12:00:00Z',
    starterRunAt: '2026-11-09T12:00:05Z' });
  const page = await loadPage([solutionOnly, solutionOnly, both, outline({ status: 'pending', issues: [] })]);
  const chip = page.elements['wb-validation'];
  assert.equal(chip.textContent, '✓ Validated');
  assert.equal(page.live().length, 0, 'an assignment with no notebook has no starter run to wait for');

  await page.save();
  assert.equal(await page.tick(), 5000);
  assert.equal(page.elements['wb-validation-note'].textContent,
    'Every test passes on the solution; none earns points on the starter');
  assert.equal(page.live().length, 0);

  await page.save();
  assert.equal(chip.textContent, 'Validating…');
  assert.equal(chip.classList.names.has('chip-ok'), false);
  assert.equal(page.live().length, 1, 'one timer, however many fetches');
});

test('a failed poll asks again', async () => {
  const pending = outline({ status: 'pending', issues: [] });
  const passed = outline({ status: 'passed', issues: [] });
  const page = await loadPage([pending, FAIL, passed]);
  await page.tick();
  assert.equal(page.elements['wb-validation'].textContent, 'Validating…');
  assert.equal(page.live().length, 1);
  await page.tick();
  assert.equal(page.elements['wb-validation'].textContent, '✓ Validated');
});

test('a slow poll that answers after a save does not draw over it', async () => {
  let answerSlowPoll;
  const slow = () => new Promise((resolve) => { answerSlowPoll = resolve; });
  const pending = outline({ status: 'pending', issues: [] });
  const failed = outline({ status: 'failed', issues: [] });
  const page = await loadPage([pending, slow, failed]);
  const due = page.live()[0];
  const fn = due.fn;
  due.fn = null;
  fn();
  await page.save();
  assert.equal(page.elements['wb-validation'].textContent, '✗ Validation failed');
  answerSlowPoll(pending);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(page.elements['wb-validation'].textContent, '✗ Validation failed');
});

test('a pending run that never lands stops after ten minutes', async () => {
  const page = await loadPage([outline({ status: 'pending', issues: [] })]);
  let waited = 0;
  while (page.live().length) waited += await page.tick();
  assert.equal(waited, 10 * 60 * 1000);
  assert.equal(page.elements['wb-validation'].textContent, 'Validating…');
});
