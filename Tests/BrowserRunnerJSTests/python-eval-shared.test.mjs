import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Unit coverage for Public/python-eval-shared.js — the cells the pattern-family
// editor's auto-compute runs on xeus-python (#1271, plan §A2).
//
// As with the grading modules, this pins the SHAPE of the cell and the parsing
// of what comes back. It cannot prove Python behaves as the cell assumes,
// because no kernel is booted here.
//
// The thing most worth pinning is the last-expression split. `runPythonAsync`
// RETURNED the trailing expression's value and the editor read it directly; an
// execute_request returns nothing, so that semantic has to be rebuilt in the
// cell. Getting it wrong does not throw — it silently yields no value, and
// auto-compute quietly stops filling anything in.

const load = async (file) => fs.readFile(path.resolve(file), 'utf8');

const context = { console };
context.globalThis = context;
const vmContext = vm.createContext(context);
vm.runInContext(await load('Public/grading-shared.js'), vmContext,
  { filename: 'grading-shared.js' });
vm.runInContext(await load('Public/python-grading-shared.js'), vmContext,
  { filename: 'python-grading-shared.js' });
vm.runInContext(await load('Public/python-eval-shared.js'), vmContext,
  { filename: 'python-eval-shared.js' });
const shared = context.ChickadeePythonEvalShared;

// Objects built inside the VM context carry that context's prototypes, so a
// strict deepEqual against a host-realm literal fails on identity alone.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('the eval module reuses the grading module\'s kernel spec', () => {
  // One definition of which kernel "the Python kernel" is. Two would drift, and
  // a drifted spec fails at boot with an opaque emscripten error.
  assert.equal(shared.PYTHON_KERNEL, context.ChickadeePythonGradingShared.PYTHON_KERNEL);
});

test('a nonce is unique per call and long enough not to collide by accident', () => {
  const seen = new Set(Array.from({ length: 200 }, () => shared.makeNonce()));
  assert.equal(seen.size, 200);
  for (const nonce of seen) assert.ok(nonce.length >= 16, `too short: ${nonce}`);
});

test('the run cell splits a trailing expression off so it can be evaluated', () => {
  const cell = shared.runExpressionPython('x = 2\nx * 3', 'NONCE');
  // The split is the whole mechanism: pop the trailing Expr, exec the rest,
  // then eval the popped node for its value.
  assert.match(cell, /_ck_tree\.body\.pop\(\)/);
  assert.match(cell, /_ck_ast\.Expression\(_ck_last\.value\)/);
  assert.match(cell, /"eval"/);
  // The source is embedded as a JSON literal, never interpolated raw.
  assert.match(cell, /_ck_src = "x = 2\\nx \* 3"/);
});

test('the run cell still executes source that ends in a statement', () => {
  const cell = shared.runExpressionPython('x = 1', 'NONCE');
  assert.match(cell, /else:\n\s+exec\(compile\(_ck_tree/);
});

test('the run cell prints its payload behind the nonce', () => {
  const cell = shared.runExpressionPython('1', 'abc123');
  assert.ok(cell.includes('print("\\nabc123:" + _ck_json.dumps('),
    `payload not printed behind the nonce:\n${cell}`);
});

test('a load cell indents the source under try: and keeps blank lines blank', () => {
  const cell = shared.loadCellPython('def f():\n\n    return 1', 'NONCE');
  assert.match(cell, /try:\n {4}def f\(\):\n\n {8}return 1\n/);
});

test('a load cell reports the last traceback line as the message', () => {
  const cell = shared.loadCellPython('boom()', 'NONCE');
  assert.match(cell, /_ck_tb\.format_exc\(\)/);
  assert.match(cell, /_ck_lines\[-1\]/);
});

test('parseEvalOutput reads the payload printed behind the nonce', () => {
  const stdout = 'some solution output\n' + 'N1:' + JSON.stringify({ value: '42', error: null });
  assert.deepEqual(plain(shared.parseEvalOutput(stdout, 'N1')), { value: '42', error: null });
});

test('parseEvalOutput reports an error payload', () => {
  const stdout = '\nN1:' + JSON.stringify({ value: null, error: 'NameError: boom' });
  assert.deepEqual(
    plain(shared.parseEvalOutput(stdout, 'N1')), { value: null, error: 'NameError: boom' });
});

test('the nonce stops solution output from forging a payload', () => {
  // The instructor's own code printing something payload-shaped under a
  // DIFFERENT nonce must not be mistaken for the result.
  const forged = '\nOTHER:' + JSON.stringify({ value: 'forged', error: null });
  assert.equal(shared.parseEvalOutput(forged, 'REAL'), null);
});

test('the LAST payload wins when a cell somehow prints two', () => {
  const stdout =
    '\nN1:' + JSON.stringify({ value: 'first', error: null })
    + '\nN1:' + JSON.stringify({ value: 'second', error: null });
  assert.equal(shared.parseEvalOutput(stdout, 'N1').value, 'second');
});

test('a missing or malformed payload is null, not a fabricated result', () => {
  // null is what makes the worker report a substrate failure instead of
  // silently handing the editor a wrong expected value.
  assert.equal(shared.parseEvalOutput('', 'N1'), null);
  assert.equal(shared.parseEvalOutput('no marker here', 'N1'), null);
  assert.equal(shared.parseEvalOutput('\nN1:not json', 'N1'), null);
  assert.equal(shared.parseEvalOutput('\nN1:"a string"', 'N1'), null);
});

test('a non-string value comes back as null rather than coerced', () => {
  const stdout = '\nN1:' + JSON.stringify({ value: 42, error: null });
  assert.equal(shared.parseEvalOutput(stdout, 'N1').value, null);
});
