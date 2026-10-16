// Unit tests for Public/notebook-boot.js, the loading panel over the notebook
// editor (NB1, design frame 18e). The pure half decides which step is active
// for each kernel phase. The wiring half is run in a vm against a small fake
// page: the kernel-diag messages move the panel through its steps, the idle
// phase fades it out, a stall dismisses it, and a recovery reload shows it
// again.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const Boot = require('../../Public/notebook-boot.js');
const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/notebook-boot.js'), 'utf8');

const ORIGIN = 'https://chickadee.test';

test('each phase makes one step active, and the steps before it done', () => {
  assert.deepEqual(Boot.stepStates('boot_start'), { editor: 'active', kernel: 'pending', notebook: 'pending' });
  assert.deepEqual(Boot.stepStates('app_ready'), { editor: 'done', kernel: 'pending', notebook: 'pending' });
  assert.deepEqual(Boot.stepStates('kernel_starting'), { editor: 'done', kernel: 'active', notebook: 'pending' });
  assert.deepEqual(Boot.stepStates('kernel_idle'), { editor: 'done', kernel: 'done', notebook: 'active' });
  assert.deepEqual(Boot.stepStates(null), Boot.stepStates('boot_start'));
});

test('a phase never moves the panel back, except boot_start', () => {
  assert.equal(Boot.nextPhase('boot_start', 'app_ready'), 'app_ready');
  assert.equal(Boot.nextPhase('kernel_starting', 'app_ready'), 'kernel_starting');
  // kernel_starting can come before app_ready reports.
  assert.equal(Boot.nextPhase('boot_start', 'kernel_starting'), 'kernel_starting');
  assert.equal(Boot.nextPhase('kernel_idle', 'boot_start'), 'boot_start');
  assert.equal(Boot.nextPhase('app_ready', 'exec_hang'), 'app_ready');
});

// A fake element with the few DOM members the script uses.
function element(attrs = {}) {
  const el = {
    hidden: false,
    textContent: '',
    attributes: { ...attrs },
    classes: new Set(),
    children: [],
    getAttribute: (name) => (name in el.attributes ? el.attributes[name] : null),
    setAttribute: (name, value) => { el.attributes[name] = String(value); },
    querySelector: (selector) => {
      const step = /^\[data-boot-step="(\w+)"\]$/.exec(selector);
      if (step) return el.children.find((c) => c.attributes['data-boot-step'] === step[1]) ?? null;
      const cls = /^\.([\w-]+)$/.exec(selector);
      if (cls) return el.children.find((c) => c.classes.has(cls[1])) ?? null;
      return null;
    },
  };
  el.classList = {
    add: (name) => el.classes.add(name),
    remove: (name) => el.classes.delete(name),
    contains: (name) => el.classes.has(name),
  };
  return el;
}

function loadPage() {
  const steps = ['editor', 'kernel', 'notebook'].map((name, i) => {
    const step = element({ 'data-boot-step': name, 'data-state': i === 0 ? 'active' : 'pending' });
    step.textContent = { editor: 'Load the editor', kernel: 'Download and start Python', notebook: 'Open your notebook' }[name];
    return step;
  });
  const live = element();
  live.classes.add('js-nb-boot-live');
  const panel = element({ 'data-phase': 'boot_start' });
  panel.children.push(...steps, live);

  const chipState = element();
  chipState.classes.add('js-nb-kernel-state');
  chipState.textContent = 'starting';
  const chip = element({ 'data-state': 'starting' });
  chip.children.push(chipState);

  const elements = { 'nb-boot': panel, 'nb-kernel-chip': chip };
  const listeners = [];
  const timers = [];
  const window = {
    location: { origin: ORIGIN },
    addEventListener: (type, fn) => { if (type === 'message') listeners.push(fn); },
  };
  const context = {
    window,
    document: { getElementById: (id) => elements[id] ?? null },
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
    clearTimeout: () => {},
  };
  context.self = context;
  vm.runInNewContext(source, context);
  const post = (data, origin = ORIGIN) => listeners.forEach((fn) => fn({ origin, data }));
  const phase = (source) => post({ ck: 'kernel-diag', kind: 'kernel_phase', source });
  const runTimers = () => timers.splice(0).forEach((fn) => fn());
  const stateOf = (name) => steps.find((s) => s.attributes['data-boot-step'] === name).attributes['data-state'];
  return { panel, chip, chipState, live, phase, post, runTimers, stateOf, api: context.ChickadeeNotebookBoot };
}

test('the kernel phases move the panel through its steps and announce each step once', () => {
  const page = loadPage();
  page.phase('boot_start');
  assert.equal(page.stateOf('editor'), 'active');
  page.phase('app_ready');
  assert.equal(page.stateOf('editor'), 'done');
  assert.equal(page.stateOf('kernel'), 'pending');
  assert.equal(page.panel.attributes['data-phase'], 'app_ready');
  page.phase('kernel_starting');
  assert.equal(page.stateOf('kernel'), 'active');
  assert.equal(page.live.textContent, 'Download and start Python');
  page.live.textContent = '';
  page.phase('kernel_starting');
  assert.equal(page.live.textContent, '', 'a step is announced once');
});

test('kernel_idle fades the panel out and marks the kernel ready', () => {
  const page = loadPage();
  page.phase('kernel_starting');
  page.phase('kernel_idle');
  assert.equal(page.stateOf('kernel'), 'done');
  assert.equal(page.stateOf('notebook'), 'active');
  assert.equal(page.live.textContent, 'Open your notebook');
  assert.equal(page.panel.classList.contains('nb-boot-leaving'), true);
  assert.equal(page.panel.hidden, false, 'still fading');
  page.runTimers();
  assert.equal(page.panel.hidden, true);
  assert.equal(page.panel.classList.contains('nb-boot-leaving'), false);
  assert.equal(page.chip.attributes['data-state'], 'ready');
  assert.equal(page.chipState.textContent, 'ready');
});

test('the watchdog probe can finish the panel before the collector reports idle', () => {
  const page = loadPage();
  page.api.finish();
  page.runTimers();
  assert.equal(page.panel.hidden, true);
  assert.equal(page.chip.attributes['data-state'], 'ready');
});

test('a recovery reload shows the panel again from the first step', () => {
  const page = loadPage();
  page.phase('kernel_idle');
  page.runTimers();
  page.phase('boot_start');
  assert.equal(page.panel.hidden, false);
  assert.equal(page.stateOf('editor'), 'active');
  assert.equal(page.stateOf('notebook'), 'pending');
  assert.equal(page.chip.attributes['data-state'], 'starting');
});

test('a stalled boot dismisses the panel and the chip, and a later phase does not bring them back', () => {
  const page = loadPage();
  page.phase('app_ready');
  page.post({ ck: 'kernel-diag', kind: 'kernel_error', source: 'boot_stalled' });
  assert.equal(page.panel.hidden, true);
  assert.equal(page.chip.hidden, true);
  page.phase('kernel_starting');
  assert.equal(page.panel.hidden, true);
});

test('messages from another origin or without the tag change nothing', () => {
  const page = loadPage();
  page.post({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'app_ready' }, 'https://evil.test');
  page.post({ kind: 'kernel_phase', source: 'app_ready' });
  page.post({ ck: 'kernel-diag', kind: 'kernel_error', source: 'csp_violation' });
  assert.equal(page.stateOf('editor'), 'active');
  assert.equal(page.panel.hidden, false);
});

test('the failure panel hides the loading panel and the kernel chip', () => {
  const preflight = fs.readFileSync(path.join(here, '../../Public/notebook-preflight.js'), 'utf8');
  const showFailure = preflight.slice(preflight.indexOf('function showFailure'));
  const body = showFailure.slice(0, showFailure.indexOf('\n    }\n'));
  assert.match(body, /getElementById\('nb-boot'\)/);
  assert.match(body, /getElementById\('nb-kernel-chip'\)/);
});
