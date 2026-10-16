// Public/notebook-boot.js and the Chickadee extension (notebook views NB2):
// the extension's `ck:kernel` idle or busy ends the loading panel, so the panel
// never outlives a kernel the extension has seen come up.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/notebook-boot.js'), 'utf8');
const ORIGIN = 'https://chickadee.test';

function loadPage(chipState = null) {
  const panel = {
    hidden: false,
    attributes: { 'data-phase': 'app_ready' },
    classes: new Set(),
    getAttribute(name) { return this.attributes[name] ?? null; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    querySelector: () => null,
  };
  panel.classList = { add: (c) => panel.classes.add(c), remove: (c) => panel.classes.delete(c) };
  const chip = chipState === null ? null : {
    attributes: { 'data-state': chipState },
    getAttribute(name) { return this.attributes[name] ?? null; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    querySelector: () => null,
  };
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

test('the extension reporting the kernel idle ends the panel', () => {
  const page = loadPage();
  page.post({ ck: 'ck:kernel', status: 'idle' });
  page.runTimers();
  assert.equal(page.panel.hidden, true);
});

test('a starting kernel keeps the panel, and another origin is ignored', () => {
  const page = loadPage();
  page.post({ ck: 'ck:kernel', status: 'starting' });
  page.post({ ck: 'ck:kernel', status: 'idle' }, 'https://evil.test');
  page.runTimers();
  assert.equal(page.panel.hidden, false);
});

test('the panel marks a starting chip ready, but never overwrites the state the extension set', () => {
  const starting = loadPage('starting');
  starting.post({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle' });
  assert.equal(starting.chip.attributes['data-state'], 'ready');
  const reported = loadPage('busy');
  reported.post({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'kernel_idle' });
  assert.equal(reported.chip.attributes['data-state'], 'busy');
});
