// Unit tests for Public/test-renderer-check-core.js, the DOM-free half of the
// notebook-check body renderer. The renderer builds every form from the
// backend-emitted #check-schema seed, so the rules pinned here are the ones a
// wrong form would hide until save: a field the language cannot use must be
// disabled, explained, and never restored from a stored value; each value
// type must round-trip; a number list must refuse non-numbers; and creating a
// check must never overwrite one whose id it happens to share.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/test-renderer-check-core.js');

test('schema parsing tolerates an absent, empty or malformed seed', () => {
  assert.deepEqual(Core.parseSchema(null), { common: [], kinds: {} });
  assert.deepEqual(Core.parseSchema('not json'), { common: [], kinds: {} });
  assert.deepEqual(Core.parseSchema('{"common": "no", "kinds": 5}'), { common: [], kinds: {} });
  assert.deepEqual(Core.parseSchema('{"common": [{"name": "hint"}], "kinds": {"k": []}}'),
    { common: [{ name: 'hint' }], kinds: { k: [] } });
});

test('controlSpec: textarea, select, number and text carry the attributes the stylesheet expects', () => {
  assert.deepEqual(Core.controlSpec({ name: 'csv', control: 'textarea', rows: 6, placeholder: 'a,b' }), {
    tag: 'textarea', attrs: { 'class': 'form-input editor-input input-mono', 'data-field': 'csv', rows: '6' }, placeholder: 'a,b',
  });
  assert.deepEqual(Core.controlSpec({ name: 'match', control: 'select', enumOptions: [{ value: 'exact', label: 'Exact' }] }), {
    tag: 'select', attrs: { 'class': 'form-input editor-input', 'data-field': 'match' }, options: [{ value: 'exact', label: 'Exact' }],
  });
  assert.deepEqual(Core.controlSpec({ name: 'rows', control: 'number', valueType: 'int' }).attrs,
    { type: 'number', 'class': 'form-input editor-input', 'data-field': 'rows', step: '1', min: '0' });
  assert.deepEqual(Core.controlSpec({ name: 'tol', control: 'number', valueType: 'optionalFloat' }).attrs,
    { type: 'number', 'class': 'form-input editor-input', 'data-field': 'tol', step: 'any' });
  assert.equal(Core.controlSpec({ name: 'v', control: 'text' }).attrs.type, 'text');
});

test('a checkbox the language cannot use is disabled and never checked, whatever its default', () => {
  assert.deepEqual(Core.controlSpec({ name: 'regex', control: 'checkbox', defaultChecked: true }),
    { tag: 'input', attrs: { type: 'checkbox', 'data-field': 'regex' }, checked: true, disabled: false });
  assert.deepEqual(Core.controlSpec({ name: 'regex', control: 'checkbox', defaultChecked: true, unsupportedReason: 'Lua patterns are not PCRE' }),
    { tag: 'input', attrs: { type: 'checkbox', 'data-field': 'regex' }, checked: false, disabled: true });
});

test('the help line is the unsupported reason when there is one, else the help, else nothing', () => {
  assert.equal(Core.helpText({ help: 'h', unsupportedReason: 'r' }), 'r');
  assert.equal(Core.helpText({ help: 'h' }), 'h');
  assert.equal(Core.helpText({}), null);
});

test('readField per value type, including the optional ones reporting set:false', () => {
  const read = (valueType, value, checked) => Core.readField({ value, checked }, { valueType });
  assert.deepEqual(read('bool', '', true), { set: true, value: true });
  assert.deepEqual(read('enum', 'exact'), { set: true, value: 'exact' });
  assert.deepEqual(read('string', '  x '), { set: true, value: 'x' });
  assert.deepEqual(read('optionalString', '  '), { set: false });
  assert.deepEqual(read('rawString', ' keep '), { set: true, value: ' keep ' });
  assert.deepEqual(read('optionalRawString', ' \n'), { set: false });
  assert.deepEqual(read('optionalRawString', ' a '), { set: true, value: ' a ' });
  assert.deepEqual(read('int', '7'), { set: true, value: 7 });
  assert.deepEqual(read('optionalInt', ''), { set: false });
  assert.deepEqual(read('optionalFloat', '0.5'), { set: true, value: 0.5 });
  assert.deepEqual(read('stringList', 'a\n\n b \n'), { set: true, value: ['a', 'b'] });
  assert.deepEqual(read('numberList', '1\n2.5\n'), { set: true, value: [1, 2.5] });
  assert.deepEqual(read('numberList', '[1, 2]'), { set: true, value: [1, 2] });
  assert.deepEqual(read('unknownType', 'x'), { set: false });
});

test('a number list refuses a non-number and invalid JSON, naming the problem', () => {
  assert.throws(() => Core.readField({ value: '1\nabc' }, { valueType: 'numberList' }), /non-number: "abc"/);
  assert.throws(() => Core.readField({ value: '[1,' }, { valueType: 'numberList' }), /isn't valid JSON/);
});

test('writeField restores a stored value per type and falls back to the default', () => {
  const c = {};
  Core.writeField(c, { valueType: 'bool', defaultChecked: true }, null); assert.equal(c.checked, true);
  Core.writeField(c, { valueType: 'bool' }, false); assert.equal(c.checked, false);
  Core.writeField(c, { valueType: 'enum', defaultValue: 'exact' }, null); assert.equal(c.value, 'exact');
  Core.writeField(c, { valueType: 'stringList' }, ['a', 'b']); assert.equal(c.value, 'a\nb');
  Core.writeField(c, { valueType: 'numberList' }, 'not-an-array'); assert.equal(c.value, '');
  Core.writeField(c, { valueType: 'int' }, 0); assert.equal(c.value, '0');
  Core.writeField(c, { valueType: 'optionalInt', defaultValue: '3' }, null); assert.equal(c.value, '3');
  Core.writeField(c, { valueType: 'string' }, 'x'); assert.equal(c.value, 'x');
});

test('a stored value for a field the language cannot use is NOT restored into the disabled control', () => {
  const c = { value: 'old', checked: true };
  Core.writeField(c, { control: 'checkbox', valueType: 'bool', defaultChecked: true, unsupportedReason: 'no' }, true);
  assert.equal(c.checked, false);
  Core.writeField(c, { control: 'text', valueType: 'string', defaultValue: 'd', unsupportedReason: 'no' }, 'stored');
  assert.equal(c.value, '');
});

test('generateID slugs the name, caps it, and appends a time suffix', () => {
  assert.equal(Core.generateID('cellContains', 'Has a for loop!', 1_000_000), 'has_a_for_loop_' + (1_000_000).toString(36).slice(-4));
  assert.equal(Core.generateID('cellContains', '', 5).startsWith('cellcontains_'), true);
  assert.equal(Core.generateID('k', '___', 5).startsWith('k_'), true, 'a name that slugs to nothing falls back to the kind');
  assert.equal(Core.generateID('k', 'x'.repeat(50), 5).split('_')[0].length, 32);
});

test('checksFrom keeps only check items with a check body', () => {
  assert.deepEqual(Core.checksFrom([{ kind: 'check', check: { id: 'a' } }, { kind: 'script' }, { kind: 'check' }]), [{ id: 'a' }]);
  assert.deepEqual(Core.checksFrom(undefined), []);
});

test('baseSpec keeps tier, points and dependencies from the row being edited, defaults otherwise', () => {
  assert.deepEqual(
    Core.baseSpec({ kind: 'variableExists', rawName: 'Has x', editingID: 've1', existing: { tier: 'release', points: 3, dependsOn: ['t'] }, sectionID: 's1' }),
    { id: 've1', kind: 'variableExists', tier: 'release', points: 3, dependsOn: ['t'], name: 'Has x', sectionID: 's1' });
  const fresh = Core.baseSpec({ kind: 'variableExists', rawName: '', editingID: null, existing: null, sectionID: null, now: 7 });
  assert.deepEqual(fresh, { id: Core.generateID('variableExists', '', 7), kind: 'variableExists', tier: 'public', points: 1, dependsOn: [] });
  // A points value of 0 on the existing row is a value, not "unset".
  assert.equal(Core.baseSpec({ kind: 'k', editingID: 'x', existing: { points: 0 } }).points, 0);
});

test('mergeChecks upserts when editing and refuses a taken id when creating', () => {
  const checks = [{ id: 'a', v: 1 }, { id: 'b', v: 1 }];
  assert.deepEqual(Core.mergeChecks(checks, { id: 'a', v: 2 }, 'a'), [{ id: 'a', v: 2 }, { id: 'b', v: 1 }]);
  assert.deepEqual(Core.mergeChecks(checks, { id: 'z', v: 2 }, 'z').at(-1), { id: 'z', v: 2 }, 'an edited check that vanished is appended');
  assert.deepEqual(Core.mergeChecks(checks, { id: 'c' }, null).length, 3);
  assert.throws(() => Core.mergeChecks(checks, { id: 'a' }, null), /already exists/);
  assert.deepEqual(checks, [{ id: 'a', v: 1 }, { id: 'b', v: 1 }], 'the input list is not mutated');
});

test('both authoring pages load the core before the renderer', async () => {
  for (const file of ['Resources/Views/_assignment-edit-body.leaf', 'Resources/Views/assignment-new.leaf']) {
    const src = await fs.readFile(path.resolve(file), 'utf8');
    const core = src.indexOf('/test-renderer-check-core.js');
    const wiring = src.indexOf('/test-renderer-check.js');
    assert.ok(core >= 0 && wiring >= 0 && core < wiring, file + ' must load the core before test-renderer-check.js');
  }
});
