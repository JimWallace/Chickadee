// Unit tests for Public/achievements-editor-core.js, the DOM-free half of the
// composable Achievements editor. The editor had no tests: every rule here
// used to live inline among element lookups, where the vm-and-fake-document
// harness could not reach it. Pinned first are the rules whose failure is
// silent on the page: a stale section ref serialising as the whole suite, a
// class-wide signal surviving a scope change into a per-student badge, and a
// Save with no name.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/achievements-editor-core.js');

// An <option> as the condition template renders it: value, text, data attrs.
function option(value, text, data) {
  return { value, text, getAttribute: (name) => (data && name in data ? data[name] : null) };
}

const SIGNAL_OPTIONS = [
  option('grade', 'Grade', { 'data-unit': '%', 'data-scope': 'individual classWide' }),
  option('testPasses', 'Test passes', {
    'data-scope': 'individual classWide', 'data-ref-control': 'text', 'data-ref-field': 'testRef',
    'data-ref-label': 'Test', 'data-ref-placeholder': 'test_name', 'data-ref-replaces-value': 'true',
  }),
  option('itemsCovered', 'Items covered', {
    'data-unit': 'items', 'data-scope': 'classWide', 'data-ref-control': 'sections', 'data-ref-field': 'sectionRef',
  }),
];
const META = Core.signalMetaFromOptions(SIGNAL_OPTIONS);
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const ctx = { signalMeta: META, sectionNames: { s1: 'Bug hunt' }, esc, dimLabel: (d) => 'dim:' + d };

test('signal meta is read off the option data attributes, never a JS table', () => {
  assert.deepEqual(META.grade, {
    label: 'Grade', unit: '%', scopes: ['individual', 'classWide'],
    refControl: '', refField: '', refLabel: '', refPlaceholder: '', refReplacesValue: false,
  });
  assert.equal(META.testPasses.refReplacesValue, true);
  assert.deepEqual(META.itemsCovered.scopes, ['classWide']);
});

test('a scope offers only the signals it can evaluate, and an unknown signal everywhere', () => {
  assert.equal(Core.isSignalAllowed(META.itemsCovered, 'individual'), false);
  assert.equal(Core.isSignalAllowed(META.itemsCovered, 'classWide'), true);
  assert.equal(Core.isSignalAllowed({}, 'individual'), true);
  assert.equal(Core.isSignalAllowed(undefined, 'record'), true);
});

test('a condition whose signal the new scope cannot use moves to the first allowed signal', () => {
  const values = SIGNAL_OPTIONS.map((o) => o.value);
  assert.equal(Core.signalForScope('itemsCovered', values, META, 'individual'), 'grade');
  assert.equal(Core.signalForScope('grade', values, META, 'individual'), 'grade');
  // Nothing allowed at all: keep what is there rather than pick blindly.
  assert.equal(Core.signalForScope('itemsCovered', ['itemsCovered'], META, 'individual'), 'itemsCovered');
});

test('condition phrases: comparator glyph, unit spacing, a ref by section NAME, a ref that replaces the value', () => {
  assert.equal(Core.condPhrase({ signal: 'grade', comparator: 'atLeast', value: 80 }, ctx), 'Grade ≥ 80%');
  assert.equal(
    Core.condPhrase({ signal: 'itemsCovered', comparator: 'atLeast', value: 3, sectionRef: 's1' }, ctx),
    'Items covered ≥ 3 items in “Bug hunt”');
  // A deleted section's id is shown as itself, not hidden.
  assert.equal(
    Core.condPhrase({ signal: 'itemsCovered', comparator: 'atMost', value: 1, sectionRef: 'gone' }, ctx),
    'Items covered ≤ 1 items in “gone”');
  assert.equal(Core.condPhrase({ signal: 'testPasses', testRef: 'test_<x>' }, ctx), '“test_&lt;x&gt;” passes');
  // An unknown signal still phrases, with its raw comparator.
  assert.equal(Core.condPhrase({ signal: 'mystery', comparator: 'near', value: 2 }, ctx), 'mystery near 2');
});

test('summaries: always / and / or, class-wide reward, record dimension via the injected label', () => {
  assert.equal(Core.summary({ scope: 'individual', conditions: [] }, ctx), 'always');
  const two = [{ signal: 'grade', comparator: 'atLeast', value: 90 }, { signal: 'testPasses', testRef: 't' }];
  assert.equal(Core.summary({ scope: 'individual', conditions: two, match: 'all' }, ctx), 'Grade ≥ 90% and “t” passes');
  assert.equal(Core.summary({ scope: 'individual', conditions: two, match: 'any' }, ctx), 'Grade ≥ 90% or “t” passes');
  assert.equal(
    Core.summary({ scope: 'classWide', conditions: [], classPercent: 75, points: 1 }, ctx),
    'always · by 75% of class · +1 pt');
  assert.equal(
    Core.summary({ scope: 'classWide', conditions: [], classPercent: 50, points: 2 }, ctx),
    'always · by 50% of class · +2 pts');
  assert.equal(Core.summary({ scope: 'record', recordDimension: 'firstToSolve' }, ctx), 'record · dim:firstToSolve');
});

test('section options: whole suite first, live sections, and a disabled home for a deleted ref', () => {
  assert.deepEqual(Core.sectionOptions({ s1: 'Bug hunt' }, ''), [
    { value: '', label: 'Whole suite', disabled: false },
    { value: 's1', label: 'Bug hunt', disabled: false },
  ]);
  assert.deepEqual(Core.sectionOptions({ s1: 'Bug hunt' }, 'gone').at(-1),
    { value: 'gone', label: 'Deleted section', disabled: true });
  // A stored ref that still exists gets no extra option.
  assert.equal(Core.sectionOptions({ s1: 'Bug hunt' }, 's1').length, 2);
  assert.equal(Core.sectionOptions({}, null).length, 1);
});

test('a condition row serialises by its signal: value+comparator, or a ref that replaces them', () => {
  assert.deepEqual(
    Core.conditionFromRow({ signal: 'grade', comparator: 'atMost', value: '42', refText: '' }, META),
    { signal: 'grade', comparator: 'atMost', value: 42 });
  assert.deepEqual(
    Core.conditionFromRow({ signal: 'testPasses', comparator: 'atMost', value: '42', refText: '  t1 ' }, META),
    { signal: 'testPasses', comparator: 'atLeast', value: 1, testRef: 't1' });
  // A section ref lands in the field the server named, and an empty value is 0.
  assert.deepEqual(
    Core.conditionFromRow({ signal: 'itemsCovered', comparator: 'atLeast', value: '', refText: 's1' }, META),
    { signal: 'itemsCovered', comparator: 'atLeast', value: 0, sectionRef: 's1' });
});

test('buildAchievement refuses a blank name and shapes each scope', () => {
  assert.deepEqual(Core.buildAchievement({ name: '   ', scope: 'individual', match: 'all' }, null),
    { ok: false, error: Core.NAME_REQUIRED });
  const conds = [{ signal: 'grade', comparator: 'atLeast', value: 90 }];
  assert.deepEqual(
    Core.buildAchievement({ name: ' Ace ', detail: '', scope: 'individual', match: 'any', conditions: conds }, null),
    { ok: true, achievement: { name: 'Ace', scope: 'individual', match: 'any', conditions: conds } });
  assert.deepEqual(
    Core.buildAchievement({
      name: 'Team', detail: ' d ', scope: 'classWide', match: 'all', conditions: conds, classPercent: '75', points: '2',
    }, { id: 'ach1' }),
    { ok: true, achievement: { name: 'Team', scope: 'classWide', match: 'all', detail: 'd', id: 'ach1', conditions: conds, classPercent: 75, points: 2 } });
  // A record carries its dimension and NO conditions, whatever the form held.
  assert.deepEqual(
    Core.buildAchievement({ name: 'First', scope: 'record', match: 'all', conditions: conds, recordDimension: 'firstToSolve' }, null),
    { ok: true, achievement: { name: 'First', scope: 'record', match: 'all', recordDimension: 'firstToSolve' } });
});

test('a failed PUT is worded from the server reason, the raw text, or the status, and capped', () => {
  assert.equal(Core.persistErrorMessage('{"reason":"Name taken"}', 400), 'Name taken');
  assert.equal(Core.persistErrorMessage('plain text', 500), 'plain text');
  assert.equal(Core.persistErrorMessage('', 502), 'HTTP 502');
  assert.equal(Core.persistErrorMessage('x'.repeat(300), 400).length, 240);
});

test('the edit page loads the core before the editor', async () => {
  const src = await fs.readFile(path.resolve('Resources/Views/_assignment-edit-body.leaf'), 'utf8');
  const core = src.indexOf('/achievements-editor-core.js');
  const wiring = src.indexOf('/achievements-editor.js');
  assert.ok(core >= 0 && wiring >= 0 && core < wiring, 'core must be loaded before achievements-editor.js');
});
