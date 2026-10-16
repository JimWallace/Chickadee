// Unit tests for Public/notebook-toolbar.js, the notebook editor's one toolbar
// (notebook views NB2). The pure half maps the extension's events onto the
// chip and the save state, and picks the theme. The wiring half runs in a vm
// against a small fake page: a button runs its commands in order, the first
// ck:kernel of an editor document configures the extension once, and a new
// document configures it again.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const Toolbar = require('../../Public/notebook-toolbar.js');
const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/notebook-toolbar.js'), 'utf8');
const ORIGIN = 'https://chickadee.test';

test('the chip says the kernel state in words', () => {
  assert.equal(Toolbar.kernelWord('idle'), 'idle');
  assert.equal(Toolbar.kernelWord('busy'), 'busy');
  assert.equal(Toolbar.kernelWord('dead'), 'stopped');
  assert.equal(Toolbar.kernelWord('nonsense'), 'starting');
});

test('the save state has text for each save phase and none otherwise', () => {
  assert.equal(Toolbar.saveText('started'), 'Saving…');
  assert.equal(Toolbar.saveText('completed'), 'Saved');
  assert.equal(Toolbar.saveText('failed'), 'Not saved');
  assert.equal(Toolbar.saveText('other'), null);
});

test('an explicit page theme wins over the system preference', () => {
  assert.equal(Toolbar.themeFor('dark', false), 'dark');
  assert.equal(Toolbar.themeFor('light', true), 'light');
  assert.equal(Toolbar.themeFor(null, true), 'dark');
  assert.equal(Toolbar.themeFor(null, false), 'light');
});

test('a command list is split on whitespace', () => {
  assert.deepEqual(
    Toolbar.commandList(' notebook:insert-cell-below  notebook:change-cell-to-code '),
    ['notebook:insert-cell-below', 'notebook:change-cell-to-code']);
  assert.deepEqual(Toolbar.commandList(null), []);
});

function loadPage() {
  const executed = [];
  const listeners = { click: [], message: [] };
  const chipWord = { textContent: 'starting' };
  const chip = {
    hidden: false, attributes: { 'data-state': 'starting' },
    setAttribute(name, value) { this.attributes[name] = value; },
    querySelector: () => chipWord,
  };
  const saveState = { hidden: true, textContent: '' };
  const frame = { getAttribute: (name) => (name === 'data-definition-patterns' ? '["^x$"]' : null) };
  const elements = { 'nb-kernel-chip': chip, 'nb-save-state': saveState, 'jl-frame': frame };
  const window = {
    location: { origin: ORIGIN },
    addEventListener: (type, fn) => listeners[type]?.push(fn),
    matchMedia: () => ({ matches: true, addEventListener() {} }),
    chickadeeEditorCommand: async (command, args) => { executed.push([command, args]); return true; },
  };
  const document = {
    documentElement: { getAttribute: () => null },
    getElementById: (id) => elements[id] ?? null,
    addEventListener: (type, fn) => listeners[type]?.push(fn),
  };
  const context = { window, document };
  context.self = context;
  vm.runInNewContext(source, context);
  const message = (data, origin = ORIGIN) => listeners.message.forEach((fn) => fn({ origin, data }));
  const click = async (commands, inHeader = true) => {
    let opened = true;
    const menu = { removeAttribute: () => { opened = false; } };
    const target = {
      getAttribute: () => commands,
      closest: (selector) => (selector === '[data-nb-commands]' ? target
        : selector === '.notebook-header' ? (inHeader ? {} : null)
        : selector === 'details' ? menu : null),
    };
    listeners.click.forEach((fn) => fn({ target }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    return opened;
  };
  return { executed, chip, chipWord, saveState, message, click };
}

test('a button runs its commands in order, and closes its menu', async () => {
  const page = loadPage();
  const stillOpen = await page.click('notebook:insert-cell-below notebook:change-cell-to-code');
  assert.deepEqual(page.executed.map(([c]) => c), ['notebook:insert-cell-below', 'notebook:change-cell-to-code']);
  assert.equal(stillOpen, false);
});

test('a button outside the notebook header does nothing', async () => {
  const page = loadPage();
  await page.click('notebook:run-all-cells', false);
  assert.deepEqual(page.executed, []);
});

test('the first ck:kernel configures the extension once and sets the chip', () => {
  const page = loadPage();
  page.message({ ck: 'ck:kernel', status: 'busy' });
  page.message({ ck: 'ck:kernel', status: 'idle' });
  const configures = page.executed.filter(([c]) => c === 'chickadee:configure');
  assert.equal(configures.length, 1);
  // Through JSON: the arguments are objects of the vm's realm.
  assert.equal(JSON.stringify(configures[0][1]), JSON.stringify({ patterns: ['^x$'] }));
  assert.equal(JSON.stringify(page.executed.find(([c]) => c === 'chickadee:set-theme')[1]), '{"theme":"dark"}');
  assert.equal(page.chip.attributes['data-state'], 'idle');
  assert.equal(page.chipWord.textContent, 'idle');
});

test('a new editor document configures the extension again', () => {
  const page = loadPage();
  page.message({ ck: 'ck:kernel', status: 'idle' });
  page.message({ ck: 'kernel-diag', kind: 'kernel_phase', source: 'boot_start' });
  page.message({ ck: 'ck:kernel', status: 'starting' });
  assert.equal(page.executed.filter(([c]) => c === 'chickadee:configure').length, 2);
});

test('ck:saved shows the save state, and a message from another origin is ignored', () => {
  const page = loadPage();
  page.message({ ck: 'ck:saved', state: 'completed' });
  assert.equal(page.saveState.textContent, 'Saved');
  assert.equal(page.saveState.hidden, false);
  page.message({ ck: 'ck:saved', state: 'failed' }, 'https://evil.test');
  assert.equal(page.saveState.textContent, 'Saved');
});

test('⋯ → Upload .ipynb opens the hidden file input it names, and runs no command', async () => {
  const executed = [];
  const listeners = { click: [], message: [] };
  let opened = 0;
  const input = { click: () => { opened += 1; } };
  const context = {
    window: {
      location: { origin: ORIGIN },
      addEventListener: (type, fn) => listeners[type]?.push(fn),
      matchMedia: () => ({ matches: false, addEventListener() {} }),
      chickadeeEditorCommand: async (command) => { executed.push(command); return true; },
    },
    document: {
      documentElement: { getAttribute: () => null },
      getElementById: (id) => (id === 'nb-menu-upload-file' ? input : null),
      addEventListener: (type, fn) => listeners[type]?.push(fn),
    },
  };
  context.self = context;
  vm.runInNewContext(source, context);
  let menuOpen = true;
  const target = {
    getAttribute: (name) => (name === 'data-nb-upload' ? 'nb-menu-upload-file' : null),
    closest: (selector) => (selector === '[data-nb-upload]' ? target
      : selector === '.notebook-header' ? {}
      : selector === 'details' ? { removeAttribute: () => { menuOpen = false; } } : null),
  };
  listeners.click.forEach((fn) => fn({ target }));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(opened, 1);
  assert.equal(menuOpen, false);
  assert.deepEqual(executed, []);
});
