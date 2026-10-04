// How an auto-compute result lands in a pattern-family Expected cell
// (`applyAutoComputeResult` in Public/pattern-family-editor.js).
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

const editorSource = await fs.readFile(path.resolve('Public/pattern-family-editor.js'), 'utf8');
const languageModuleSource = await fs.readFile(path.resolve('Public/authoring-language.js'), 'utf8');

/// The editor's module scope, loaded under a stub DOM. Only the exported
/// helpers are used, so the stub never has to stand in for a real page.
function loadEditor() {
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
  vm.runInNewContext(editorSource, ctx, { filename: 'pattern-family-editor.js' });
  return ctx.chickadeeApplyAutoComputeResult;
}

const apply = loadEditor();

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

// #1991: a title is one phrase of at most 20 words (docs/ui-design.md, "UI
// copy"). check-ui-vocabulary.sh counts the words of a title in a template;
// a title built in JS has only this test. What to do about a warning is in
// docs/auto-compute.md, which the note under the cases table links.
const TITLE_WORD_CAP = 20;

test('every auto-compute title is one phrase within the hover word budget', () => {
  const unsupported = ['coroutine', 'async-generator', 'generator', 'set', 'tuple', 'bytes', 'complex'];
  const results = [
    { ok: true, value: 42 },
    { ok: true, returnedNone: true },
    { ok: false, timedOut: true, error: 'timed out after 5s' },
    { ok: false, timedOut: true, error: 'solution notebook load timed out after 30s' },
    ...unsupported.map((kind) => ({ ok: false, unsupported: kind })),
    { ok: false, error: "NameError: name 'x' is not defined" },
    { ok: false, loadFailed: true, error: 'no solution notebook', detail: 'no-solution' },
    { ok: false, loadFailed: true, error: 'solution notebook has no code', detail: 'empty-solution' },
    { ok: false, loadFailed: true, error: 'solution notebook did not load', detail: 'Failed to fetch' },
    { ok: false, notJSON: true, error: 'Computed (1 2) — enter it here in JSON.' },
    { ok: false, unavailable: true, error: 'This assignment declares no language, so there is no solution to call.' },
    { ok: false, requestFailed: true, error: 'compute failed' },
  ];
  for (const res of results) {
    const cell = computedCell();
    apply(cell, res, env);
    const label = JSON.stringify(res) + ' -> "' + cell.title + '"';
    const words = cell.title.trim().split(/\s+/).filter(Boolean);
    assert.ok(words.length > 0, label + ' has no title');
    assert.ok(words.length <= TITLE_WORD_CAP, label + ' has ' + words.length + ' words');
    assert.doesNotMatch(cell.title, /[.?!](\s|$)/, label + ' is more than one phrase');
  }
});

test('a timeout title names no language function', () => {
  // The call and the load run in the R, Lua and Octave kernels too, so
  // advice about Python's input() or print() is wrong for those authors.
  for (const error of ['timed out after 5s', 'solution notebook load timed out after 30s']) {
    const cell = computedCell();
    apply(cell, { ok: false, timedOut: true, error }, env);
    assert.doesNotMatch(cell.title, /\w+\(\)/, cell.title);
  }
});

test('a server-route result that is not a solution error has its own title', () => {
  // C++, Racket and Java compute on the server. Its non-JSON value, its
  // refusal and a failed request used to read "Solution raised: ...".
  const cases = [
    [{ ok: false, notJSON: true, error: 'Computed (1 2) — enter it here in JSON.' }, 'Computed value is not JSON'],
    [{ ok: false, unavailable: true, error: 'This assignment declares no language, so there is no solution to call.' }, 'Auto-compute unavailable here'],
    [{ ok: false, requestFailed: true, error: 'compute failed' }, 'Auto-compute request failed'],
  ];
  for (const [res, title] of cases) {
    const cell = computedCell();
    apply(cell, res, env);
    assert.equal(cell.title, title);
    // The reason stays visible in the cell.
    assert.equal(cell.placeholder, '⚠ ' + res.error);
  }
});

test('the note under the cases table links a heading that docs/auto-compute.md has', async () => {
  const template = await fs.readFile(path.resolve('Resources/Views/_family-editor-body.leaf'), 'utf8');
  const doc = await fs.readFile(path.resolve('docs/auto-compute.md'), 'utf8');
  const link = /docs\/auto-compute\.md#([a-z0-9-]+)/.exec(template);
  assert.ok(link, 'the note must link a section of docs/auto-compute.md');
  // GitHub's anchor for a heading: lower case, punctuation dropped, spaces to hyphens.
  const anchors = [...doc.matchAll(/^#+ (.+)$/gm)].map((m) =>
    m[1].toLowerCase().replace(/[^a-z0-9 -]/g, '').replace(/ /g, '-'));
  assert.ok(anchors.includes(link[1]), '#' + link[1] + ' names no heading in docs/auto-compute.md');
});
