// Unit tests for the Octave auto-compute snippets.
//
// octave-eval-execution.test.mjs runs these under a real interpreter; this file
// asserts the things execution cannot show, because they are about what the
// snippet must NOT contain:
//
//   * `str2func` nowhere — it resolves a BUILT-IN over a command-line function
//     of the same name, so a solution defining `area` would silently be graded
//     against Octave's plotting function;
//   * `printf` nowhere in the payload path — an error message can carry a `%`;
//   * the seeded helpers called, never defined here;
//   * the `1;` guard on the boot cell, which the execution suite cannot prove
//     because a script file accepts function definitions either way.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/eval-protocol-shared.js');
require('../../Public/octave-grading-shared.js');
require('../../Public/octave-eval-shared.js');

const Octave = globalThis.ChickadeeOctaveEvalShared;
const protocol = globalThis.ChickadeeEvalProtocol;

const SNIPPETS = () => ({
  loadCell: Octave.loadCell('function r = f(x)\n r = x;\nend', 'NONCE1'),
  runExpression: Octave.runExpression('f(2)', 'NONCE2'),
  call: Octave.callFunction('f', [1], {}, 'NONCE3'),
  captured: Octave.callFunction('f', [1], { captureStdout: true }, 'NONCE4'),
});

test('the boot cell opens with the 1; script guard', () => {
  const cell = Octave.bootCell('function s = helper()\n s = 1;\nend');
  assert.ok(cell.startsWith('1;\n'),
    'without the guard the cell is a function file and nothing registers');
  assert.ok(cell.includes('function s = helper()'), 'the seeded bytes run verbatim');
});

test('str2func appears nowhere — a builtin would win the lookup', () => {
  for (const [name, snippet] of Object.entries(SNIPPETS())) {
    assert.ok(!snippet.includes('str2func'),
      `${name} must resolve a command-line function by NAME, not through str2func`);
  }
  assert.ok(SNIPPETS().call.includes('feval(ck_callee_'),
    'the call must go through feval on the resolved callee');
});

test('the payload is written with fputs, never printf', () => {
  // An Octave error message can contain a literal `%`; a printf carrying the
  // payload in its format string would consume it.
  for (const [name, snippet] of Object.entries(SNIPPETS())) {
    assert.ok(snippet.includes('fputs(stdout, ['), `${name} must write with fputs`);
    // `sprintf` is fine and used — it is the only way to spell a newline
    // outside a double-quoted literal. It is `printf` writing to stdout that
    // must not appear.
    assert.ok(!/(^|[^s])printf\(/.test(snippet),
      `${name} must not build its payload with printf`);
  }
});

test('the payload marker matches what the shared parser looks for', () => {
  const run = Octave.runExpression('1', 'ABC123');
  assert.ok(run.includes('"\\nABC123:"'),
    `snippet does not write the marker the parser reads:\n${run}`);
  assert.equal(protocol.payloadMarker('ABC123'), '\nABC123:');
});

test('the seeded helpers are called, never defined here', () => {
  for (const [name, snippet] of Object.entries(SNIPPETS())) {
    assert.ok(!/function \w+ = chickadee_/.test(snippet),
      `${name} must use the seeded runtime, not a copy`);
  }
  assert.ok(SNIPPETS().runExpression.includes('chickadee_serialize('),
    'a value must be reported through the seeded serializer');
  assert.ok(SNIPPETS().call.includes('chickadee_escape_string('),
    'the payload must be escaped by the seeded escaper');
});

test('a solution cell is evaluated behind the 1; submission contract', () => {
  const load = Octave.loadCell('function r = f(x)\n r = x;\nend', 'N');
  assert.ok(load.includes('eval(["1;" sprintf("\\n")'),
    'without the prefix a one-function cell binds under the file name, not its own');
  // And the source rides as a string literal, so quotes cannot break out.
  const nasty = Octave.loadCell('r = "he said \\"hi\\"";', 'N');
  assert.ok(nasty.includes('\\\\"'), 'quotes in the source must be escaped');
});

test('a value and an error are distinguished by a flag, not by emptiness', () => {
  // The empty string is a legitimate return value; `isempty` would report it as
  // "returned nothing".
  const call = SNIPPETS().call;
  assert.ok(call.includes('ck_have_val_'), 'a returned value needs its own flag');
  assert.ok(call.includes('ck_have_err_'), 'an error needs its own flag');
});

test('a zero-output function is called without assignment', () => {
  // `ck_res_ = feval(…)` on one raises "value on right hand side of assignment
  // is undefined", which reads as a broken solution rather than as no value.
  const call = SNIPPETS().call;
  assert.ok(call.includes('if nargout(ck_callee_) == 0'),
    'the nargout check is what keeps a printing solution from reporting an error');
});

test('captureStdout uses evalc and drops one trailing newline', () => {
  const captured = SNIPPETS().captured;
  assert.ok(captured.includes('evalc('), 'captureStdout must capture what was printed');
  assert.ok(captured.includes('ck_out_(1:end-1)'), 'one trailing newline is dropped');
  // The trailing semicolon inside the evalc'd code suppresses the `ans = …`
  // echo a value-returning function would otherwise add to the capture.
  assert.ok(/evalc\("feval\([^"]*\);"\)/.test(captured),
    `the evalc'd call must end in a semicolon:\n${captured}`);
  assert.ok(!SNIPPETS().call.includes('evalc('),
    'the default path must report the returned value, not printed output');
});

test('callFunction renders arguments through the pinned Octave renderer', () => {
  const snippet = Octave.callFunction('classify', [18.5, 'lo', [1, 2], [65, 'bc']], {}, 'N');
  assert.ok(snippet.includes('ck_a1_ = 18.5;'), `argument 1 not bound:\n${snippet}`);
  assert.ok(snippet.includes('ck_a2_ = "lo";'), 'a string argument must be quoted');
  assert.ok(snippet.includes('ck_a3_ = [1, 2];'), 'an all-numeric array is a row vector');
  // THE TRAP: brackets here would concatenate into the char array "Abc".
  assert.ok(snippet.includes('ck_a4_ = {65, "bc"};'), 'a mixed array must be a cell');
  assert.ok(snippet.includes('feval(ck_callee_, ck_a1_, ck_a2_, ck_a3_, ck_a4_)'),
    `arguments must be passed positionally:\n${snippet}`);
});

test('a missing function says "not defined", which the editor keys on', () => {
  const snippet = Octave.callFunction('nope', [], {}, 'N');
  assert.ok(snippet.includes('is not defined in the solution notebook'),
    'the missing-function message must carry the phrase the editor matches');
});

test('the parser round-trips a payload the snippet shape would produce', () => {
  const stdout = 'solution output\n\nNONCE:{"value":"42","error":null}\n';
  assert.deepEqual(protocol.parseEvalOutput(stdout, 'NONCE'), { value: '42', error: null });
  const twice = '\nNONCE:{"value":"1","error":null}\n\nNONCE:{"value":"2","error":null}\n';
  assert.equal(protocol.parseEvalOutput(twice, 'NONCE').value, '2');
  assert.equal(protocol.parseEvalOutput('nothing here', 'NONCE'), null);
});
