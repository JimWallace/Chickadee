// How an auto-compute result lands in a pattern-family Expected cell
// (`applyAutoComputeResult` in Public/auto-compute-client.js, which was in
// Public/pattern-family-editor.js until #1966).
//
// The defect (#1998): a failed auto-compute set only the cell's placeholder
// and title. If the cell already held a value computed earlier, the
// placeholder was hidden behind it, so the error was only in a hover title,
// which a touch screen never shows. Every failure now clears that value.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const clientSource = await fs.readFile(path.resolve('Public/auto-compute-client.js'), 'utf8');
const languageModuleSource = await fs.readFile(path.resolve('Public/authoring-language.js'), 'utf8');

/// The auto-compute module's scope, loaded under a stub DOM, after the
/// language module as the page loads them. Only the exported helpers are
/// used, so the stub never has to stand in for a real page.
function loadClient() {
  const ctx = {
    console, JSON, Array, Object, Math, Set, Map, Promise, RegExp, String, Boolean, Number,
    setTimeout, clearTimeout, fetch: () => Promise.resolve({}), location: { href: '' },
    document: {
      getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
      addEventListener() {}, currentScript: { dataset: {} },
    },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(languageModuleSource, ctx, { filename: 'authoring-language.js' });
  vm.runInNewContext(clientSource, ctx, { filename: 'auto-compute-client.js' });
  return ctx.ChickadeeAutoCompute.applyAutoComputeResult;
}

const apply = loadClient();

/// A cell that auto-compute filled earlier in the session.
function computedCell() {
  return { value: '"underweight"', placeholder: '', title: '', dataset: { autoComputed: '1' }, cue: null };
}

const env = {
  render: (v) => JSON.stringify(v),
  setCue: (cell, cue) => { cell.cue = cue; },
  timeoutMs: 5000,
  loadTimeoutMs: 30000,
};

test('a solution error clears the computed value, so the warning shows in the cell', () => {
  const cell = computedCell();
  apply(cell, { ok: false, error: "NameError: name 'x' is not defined" }, env);
  assert.equal(cell.value, '');
  assert.equal(cell.placeholder, "⚠ NameError: name 'x' is not defined");
  assert.equal(cell.cue, 'input-invalid');
  assert.equal(cell.dataset.autoComputed, undefined);
});

test('every other failure clears the computed value too', () => {
  const failures = [
    { timedOut: true, ok: false, error: 'timed out' },
    { ok: false, unsupported: 'set' },
    { ok: true, returnedNone: true },
  ];
  for (const res of failures) {
    const cell = computedCell();
    apply(cell, res, env);
    assert.equal(cell.value, '', JSON.stringify(res));
    assert.match(cell.placeholder, /^⚠ /, JSON.stringify(res));
    assert.equal(cell.dataset.autoComputed, undefined, JSON.stringify(res));
  }
});

test('a computed value is written and marked as computed', () => {
  const cell = { value: '', placeholder: 'computing…', title: '', dataset: {}, cue: null };
  apply(cell, { ok: true, value: 42 }, env);
  assert.equal(cell.value, '42');
  assert.equal(cell.dataset.autoComputed, '1');
  assert.equal(cell.cue, 'input-computed');
});

test('a load-phase timeout names the setup cell, a call timeout names the call', () => {
  const load = computedCell();
  apply(load, { ok: false, timedOut: true, error: 'timed out during notebook load' }, env);
  assert.match(load.title, /ran longer than 30 seconds/);
  const call = computedCell();
  apply(call, { ok: false, timedOut: true, error: 'timed out' }, env);
  assert.match(call.title, /did not return within 5 seconds/);
});

test('a solution-load failure shows readable copy, not a sentinel or "Solution raised"', () => {
  const missing = computedCell();
  apply(missing, { ok: false, loadFailed: true, error: 'no solution notebook', detail: 'no-solution' }, env);
  assert.equal(missing.value, '');
  assert.equal(missing.placeholder, '⚠ no solution notebook');
  assert.doesNotMatch(missing.title, /Solution raised|no-solution/);

  const network = computedCell();
  apply(network, { ok: false, loadFailed: true, error: 'solution notebook did not load', detail: 'Failed to fetch' }, env);
  assert.equal(network.placeholder, '⚠ solution notebook did not load');
  assert.equal(network.title, 'Load failed: Failed to fetch');
});
