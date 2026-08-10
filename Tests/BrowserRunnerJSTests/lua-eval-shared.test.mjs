// Unit tests for the Lua auto-compute snippets.
//
// No kernel here — these assert the SHAPE the kernel constrains, which is the
// part that can be got wrong silently:
//
//   * one call expression per cell, because xeus-lua's `return <cell>` probe
//     mis-reads a cell that opens with a `local` declaration;
//   * the payload marker spelled exactly as the shared parser reads it;
//   * the seeded helpers CALLED and never defined here;
//   * arguments bound one per `local`, because a JSON null in a table
//     constructor is not stored at all.
//
// The kernel-side proof is Tools/browser-grading-smoke with `--language lua
// --mode eval`.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/eval-protocol-shared.js');
require('../../Public/lua-grading-shared.js');
require('../../Public/lua-eval-shared.js');

const Lua = globalThis.ChickadeeLuaEvalShared;
const protocol = globalThis.ChickadeeEvalProtocol;

/// True when `source` is a single `(function() … end)()` call and nothing
/// follows it.
function isOneCallExpression(source) {
  const trimmed = source.trim();
  if (!trimmed.startsWith('(function()') || !trimmed.endsWith('end)()')) return false;
  // Walk the parens of the whole snippet; the opening one must not close until
  // the very end, or there is a second top-level form after it. String
  // literals in the snippet can hold parens, so they are skipped.
  let depth = 0;
  let quoted = false;
  for (let i = 0; i < trimmed.length; i++) {
    const ch = trimmed[i];
    if (quoted) {
      if (ch === '\\') i++;
      else if (ch === '"') quoted = false;
      continue;
    }
    if (ch === '"') quoted = true;
    else if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      // The function expression's own paren closes just before the `()` that
      // calls it; anything else after depth reaches zero is a second form.
      if (depth === 0 && trimmed.slice(i + 1) !== '()' && i < trimmed.length - 1) return false;
    }
  }
  return depth === 0;
}

const SNIPPETS = () => ({
  loadCell: Lua.loadCell('function f(x) return x end\n', 'NONCE1'),
  runExpression: Lua.runExpression('f(2)', 'NONCE2'),
  call: Lua.callFunction('f', [1], {}, 'NONCE3'),
  captured: Lua.callFunction('f', [1], { captureStdout: true }, 'NONCE4'),
});

test('every snippet is a single call expression', () => {
  for (const [name, snippet] of Object.entries(SNIPPETS())) {
    assert.ok(isOneCallExpression(snippet), `${name} must be one call expression:\n${snippet}`);
  }
});

test('the payload marker matches what the shared parser looks for', () => {
  const run = Lua.runExpression('1', 'ABC123');
  assert.ok(run.includes('"\\nABC123:"'),
    `snippet does not write the marker the parser reads:\n${run}`);
  assert.equal(protocol.payloadMarker('ABC123'), '\nABC123:');
});

test('the seeded helpers are called, never defined here', () => {
  for (const [name, snippet] of Object.entries(SNIPPETS())) {
    assert.ok(!/local function chickadee_/.test(snippet),
      `${name} must use the seeded runtime, not a copy`);
  }
  assert.ok(SNIPPETS().runExpression.includes('chickadee_serialize('),
    'a value must be reported through the seeded serializer');
  assert.ok(SNIPPETS().runExpression.includes('chickadee_json_str('),
    'the payload must be encoded by the seeded JSON encoder');
});

test('the boot cell wraps the seeded runtime without rewriting it', () => {
  const runtime = 'local function chickadee_json_str(v) return v end\n_G.x = 1';
  const cell = Lua.bootCell(runtime);
  assert.ok(cell.includes(runtime), 'the seeded bytes must be executed verbatim');
  assert.ok(isOneCallExpression(cell), 'the boot cell must be one call expression too');
});

test('instructor source is embedded as a Lua string literal', () => {
  const nasty = 'print("he said \\"hi\\"")';
  const load = Lua.loadCell(nasty, 'N');
  assert.ok(!load.includes('print("he said "hi"")'), 'raw source must not be spliced in');
  assert.ok(load.includes('\\\\"'), 'quotes in the source must be escaped');
  // `load` with no environment compiles against the globals, which is what lets
  // a later cell (and the call snippet) see what this one defined.
  assert.ok(/load\(.*, "solution", "t"\)/s.test(load),
    'cells must compile against the globals or later cells cannot see them');
});

test('a syntax error and a runtime error are both reported per cell', () => {
  const load = Lua.loadCell('error("boom")', 'N');
  assert.ok(load.includes('pcall('), 'a failing cell must not stop later cells loading');
  assert.ok(load.includes('ck_syntax'), 'a cell that will not compile must report its message');
});

test('runExpression compiles as an expression first, then as a block', () => {
  const run = Lua.runExpression('x + 1', 'N');
  assert.ok(run.includes('"return (x + 1)"'),
    'Lua has no eval; the source must be compiled as a return expression');
  assert.ok(run.includes('"x + 1"'),
    'a statement that will not compile as an expression must still run');
});

test('callFunction binds one local per argument, never a table', () => {
  const snippet = Lua.callFunction('classify', [18.5, 'lo', [1, 2], null], {}, 'N');
  assert.ok(snippet.includes('local ck_a1 = 18.5'), `argument 1 not bound:\n${snippet}`);
  assert.ok(snippet.includes('local ck_a2 = "lo"'), 'a string argument must be quoted');
  assert.ok(snippet.includes('local ck_a3 = {1, 2}'), 'an array argument must be a table');
  // THE TRAP: null is `nil` at top level and the sentinel inside a table. A
  // renderer that put the arguments in a table would drop this slot and call
  // the solution with three arguments instead of four.
  assert.ok(snippet.includes('local ck_a4 = nil'), 'a top-level null must stay nil');
  assert.ok(snippet.includes('pcall(ck_fn, ck_a1, ck_a2, ck_a3, ck_a4)'),
    `arguments must be passed positionally:\n${snippet}`);
  assert.ok(!/table.unpack/.test(snippet), 'an argument table would lose the nil slot');
});

test('a null inside an argument becomes the sentinel, which the runtime seeds', () => {
  const snippet = Lua.callFunction('f', [[60, null, 20]], {}, 'N');
  assert.ok(snippet.includes('{60, chickadee.NULL, 20}'),
    `a null inside a table must keep its slot:\n${snippet}`);
});

test('a missing function says "not defined", which the editor keys on', () => {
  // describeCallFailure folds the first failing solution cell into the message
  // only when it recognises the "not defined" / "not found" shape.
  const snippet = Lua.callFunction('nope', [], {}, 'N');
  assert.ok(snippet.includes('is not defined in the solution notebook'),
    'the missing-function message must carry the phrase the editor matches');
  assert.ok(snippet.includes('type(ck_fn) ~= "function"'),
    'a non-function global must be reported the same way as a missing one');
});

test('captureStdout swaps print and io, and puts them back', () => {
  const captured = Lua.callFunction('f', [], { captureStdout: true }, 'N');
  assert.ok(captured.includes('_G.print = function'), 'print must be captured');
  assert.ok(captured.includes('stdout = ck_stdout'),
    'io.stdout:write must be captured too, not just io.write');
  assert.ok(captured.includes('_G.print, _G.io = ck_real_print, ck_real_io'),
    'the swap must be undone before the payload is written');
  assert.ok(captured.indexOf('_G.print, _G.io = ck_real_print, ck_real_io')
    < captured.indexOf('io.write("\\nN:'),
    'the payload must be written through the REAL io, after the restore');
  const plain = Lua.callFunction('f', [], {}, 'N');
  assert.ok(!plain.includes('_G.print = function'),
    'the default path must report the returned value, not printed output');
});

test('the parser round-trips a payload the snippet shape would produce', () => {
  const stdout = 'solution output\n\nNONCE:{"value":"42","error":null}\n';
  assert.deepEqual(protocol.parseEvalOutput(stdout, 'NONCE'), { value: '42', error: null });
  const twice = '\nNONCE:{"value":"1","error":null}\n\nNONCE:{"value":"2","error":null}\n';
  assert.equal(protocol.parseEvalOutput(twice, 'NONCE').value, '2');
  assert.equal(protocol.parseEvalOutput('nothing here', 'NONCE'), null);
});
