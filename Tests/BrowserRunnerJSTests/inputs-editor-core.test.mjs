// Unit tests for the shared inputs-editor core (#1126) — the value
// classification and literal parsing that both the Global Inputs and
// per-section inputs panels persist through. The two panels used to carry
// byte-identical private copies of these functions.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/inputs-editor-core.js');

test('classifyValue: expressions are signalled by a leading =', () => {
  assert.deepEqual(Core.classifyValue('= seed % 26'), { kind: 'expression', expression: 'seed % 26' });
  assert.deepEqual(Core.classifyValue('   =  len(names) '), { kind: 'expression', expression: 'len(names)' });
  assert.deepEqual(Core.classifyValue('='), { kind: 'expression', expression: '', empty: true });
});

test('classifyValue: literals parse via JSON with Python shortcuts', () => {
  assert.deepEqual(Core.classifyValue('42'), { kind: 'literal', value: 42, strict: true });
  assert.deepEqual(Core.classifyValue('True'), { kind: 'literal', value: true, strict: true });
  assert.deepEqual(Core.classifyValue('None'), { kind: 'literal', value: null, strict: true });
  assert.deepEqual(Core.classifyValue('[1, 2, 3]'), { kind: 'literal', value: [1, 2, 3], strict: true });
  // Python-ish single quotes coerce non-strictly.
  assert.deepEqual(Core.classifyValue("['a', 'b']"), { kind: 'literal', value: ['a', 'b'], strict: false });
  // Bare words degrade to a non-strict string.
  assert.deepEqual(Core.classifyValue('hello'), { kind: 'literal', value: 'hello', strict: false });
  assert.deepEqual(Core.classifyValue('   '), { kind: 'empty' });
});

test('isValidPyIdent and the reserved seed name', () => {
  assert.equal(Core.isValidPyIdent('max_bmi'), true);
  assert.equal(Core.isValidPyIdent('_x1'), true);
  assert.equal(Core.isValidPyIdent('1bad'), false);
  assert.equal(Core.isValidPyIdent('no-dash'), false);
  assert.equal(Core.RESERVED_NAMES.seed, true);
});
