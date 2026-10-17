// Public/notebook-boot.js: the loading panel fades when the extension reports
// the notebook's cells drawn (`ck:notebook-open`), with the kernel still
// starting. The chip keeps "starting" until the kernel reports, and a later
// kernel phase does not bring the panel back.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/notebook-boot.js'), 'utf8');
const ORIGIN = 'https://chickadee.test';

function element(attributes) {
  const el = {
    hidden: false,
    attributes: { ...attributes },
    classes: new Set(),
    getAttribute(name) { return this.attributes[name] ?? null; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    querySelector: () => null,
  };
  el.classList = { add: (c) => el.classes.add(c), remove: (c) => el.classes.delete(c) };
  return el;
}

function loadPage() {
  const panel = element({ 'data-phase': 'kernel_starting' });
  const chip = element({ 'data-state': 'starting' });
  const listeners = [];
  const timers = [];
  const context = {
    window: { location: { origin: ORIGIN }, addEventListener: (type, fn) => { if (type === 'message') listeners.push(fn); } },
    document: { getElementById: (id) => (id === 'nb-boot' ? panel : id === 'nb-kernel-chip' ? chip : null) },
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
    clearTimeout: () => {},
  };
  context.self = context;
  vm.runInNewContext(source, context);
  const post = (data, origin = ORIGIN) => listeners.forEach((fn) => fn({ origin, data }));
  return { panel, chip, post, runTimers: () => timers.splice(0).forEach((fn) => fn()) };
}

test('the cells drawn end the panel, and the chip still says starting', () => {
  const page = loadPage();
  page.post({ ck: 'ck:notebook-open' });
  assert.equal(page.panel.classes.has('nb-boot-leaving'), true);
  assert.equal(page.panel.attributes['data-phase'], 'kernel_starting');
  page.runTimers();
  assert.equal(page.panel.hidden, true);
  assert.equal(page.chip.attributes['data-state'], 'starting');
});

test('a kernel phase after the cells are drawn does not bring the panel back', () => {
  const page = loadPage();
  page.post({ ck: 'ck:notebook-open' });
  page.runTimers();
  page.post({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle' });
  page.runTimers();
  assert.equal(page.panel.hidden, true);
  assert.equal(page.chip.attributes['data-state'], 'ready');
});

test('another origin cannot end the panel', () => {
  const page = loadPage();
  page.post({ ck: 'ck:notebook-open' }, 'https://evil.test');
  page.runTimers();
  assert.equal(page.panel.hidden, false);
});

test('a new editor document shows the panel again, and its own cells end it', () => {
  const page = loadPage();
  page.post({ ck: 'ck:notebook-open' });
  page.runTimers();
  page.post({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'boot_start' });
  assert.equal(page.panel.hidden, false);
  page.post({ ck: 'ck:notebook-open' });
  page.runTimers();
  assert.equal(page.panel.hidden, true);
});

test('the extension reporting the kernel idle after the panel faded marks a starting chip ready', () => {
  const page = loadPage();
  page.post({ ck: 'ck:notebook-open' });
  page.runTimers();
  page.post({ ck: 'ck:kernel', status: 'idle' });
  assert.equal(page.chip.attributes['data-state'], 'ready');
});
