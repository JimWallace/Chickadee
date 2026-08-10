// Unit tests for the R auto-compute snippets.
//
// No kernel here — these assert the SHAPE the kernel constrains, which is the
// part that can be got wrong silently:
//
//   * one top-level expression, because xeus-lite yields ~180ms between them
//     and auto-compute runs on a per-keystroke debounce;
//   * the payload marker spelled exactly as the shared parser reads it;
//   * `sep = ""`, because cat's default space would land inside the JSON;
//   * the instructor's source embedded as an R string literal, so quotes and
//     backslashes in a solution cannot break out of it.
//
// A first draft of this module hand-copied R's JSON escaper; that is why
// `.ck_json_str` being CALLED rather than DEFINED here is asserted.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/eval-protocol-shared.js');
require('../../Public/r-grading-shared.js');
require('../../Public/r-eval-shared.js');

const R = globalThis.ChickadeeREvalShared;
const protocol = globalThis.ChickadeeEvalProtocol;

/// True when `source` is a single `local({ … })` call and nothing follows it.
function isOneTopLevelExpression(source) {
  const trimmed = source.trim();
  if (!trimmed.startsWith('local({') || !trimmed.endsWith('})')) return false;
  // Walk the braces of the whole snippet; the opening one must not close until
  // the very end, or there is a second top-level form after it.
  let depth = 0;
  for (let i = 0; i < trimmed.length; i++) {
    const ch = trimmed[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0 && i < trimmed.length - 2) return false;
    }
  }
  return depth === 0;
}

test('both snippets are a single top-level expression', () => {
  const load = R.loadCell('f <- function(x) x\n', 'NONCE1');
  const run = R.runExpression('f(2)', 'NONCE2');
  assert.ok(isOneTopLevelExpression(load), 'loadCell must be one expression');
  assert.ok(isOneTopLevelExpression(run), 'runExpression must be one expression');
});

test('the payload marker matches what the shared parser looks for', () => {
  const run = R.runExpression('1', 'ABC123');
  // The parser searches for '\n' + nonce + ':'; the snippet must cat exactly
  // that, escaped as an R string literal.
  assert.ok(run.includes('"\\nABC123:"'),
    `snippet does not cat the marker the parser reads:\n${run}`);
  assert.equal(protocol.payloadMarker('ABC123'), '\nABC123:');
});

test('cat uses sep = "" so no space lands inside the payload', () => {
  for (const snippet of [R.loadCell('x', 'N'), R.runExpression('x', 'N')]) {
    assert.ok(/sep = ""/.test(snippet), 'cat must pass sep = ""');
  }
});

test('the escaper is called, never defined here', () => {
  const run = R.runExpression('1', 'N');
  assert.ok(run.includes('.ck_json_str('), 'the seeded escaper must be used');
  assert.ok(!run.includes('.ck_json_str <-'),
    'the escaper must come from the seeded runtime, not a copy in this module');
  assert.ok(!/gsub/.test(run), 'no hand-rolled escaping in the snippet');
});

test('instructor source is embedded as an R string literal', () => {
  // A solution containing quotes and backslashes must not break out.
  const nasty = 'cat("he said \\"hi\\"\\n")';
  const load = R.loadCell(nasty, 'N');
  assert.ok(!load.includes('cat("he said "hi""'), 'raw source must not be spliced in');
  assert.ok(load.includes('\\\\"'), 'quotes in the source must be escaped');
  // And it goes through parse/eval into the GLOBAL env, so later cells see it.
  assert.ok(load.includes('envir = globalenv()'),
    'cells must evaluate into globalenv or later cells cannot see their definitions');
});

test('a value is reported as R\'s own repr, collapsed to one line', () => {
  const run = R.runExpression('1:3', 'N');
  assert.ok(run.includes('deparse('), 'the value must be deparsed, not formatted for display');
  assert.ok(run.includes('collapse = ""'),
    'deparse returns a vector for long values; the payload is one line');
});

test('NULL is reported as JSON null, not the string "NULL"', () => {
  const run = R.runExpression('invisible(NULL)', 'N');
  assert.ok(run.includes('is.null(.ck_val)') && run.includes('"null"'),
    'a NULL result must be distinguishable from the value NULL');
});

test('errors are caught per cell rather than aborting the load', () => {
  const load = R.loadCell('stop("boom")', 'N');
  assert.ok(load.includes('tryCatch('), 'a failing cell must not stop later cells loading');
  assert.ok(load.includes('conditionMessage(e)'), 'the message must be reported');
});

test('the parser round-trips a payload the snippet shape would produce', () => {
  const stdout = 'instructor output\n\nNONCE:{"value":"42","error":null}\n';
  assert.deepEqual(protocol.parseEvalOutput(stdout, 'NONCE'), { value: '42', error: null });
  // Output printed by the solution AFTER a previous payload must not win.
  const twice = '\nNONCE:{"value":"1","error":null}\n\nNONCE:{"value":"2","error":null}\n';
  assert.equal(protocol.parseEvalOutput(twice, 'NONCE').value, '2');
  // No payload at all is a substrate failure, not an empty result.
  assert.equal(protocol.parseEvalOutput('nothing here', 'NONCE'), null);
});

test('callFunction renders arguments through the pinned R literal renderer', () => {
  const snippet = R.callFunction('classify', [18.5, 'lo', [1, 2], null], {}, 'N');
  assert.ok(snippet.includes('.ck_args <- list(18.5, "lo", c(1, 2), NA)'),
    `arguments are not rendered as R literals:\n${snippet}`);
  assert.ok(snippet.includes('get("classify", envir = globalenv())'),
    'the function must be looked up in the environment the cells loaded into');
  assert.ok(snippet.includes('do.call('),
    'arguments are already R values; they must not be re-parsed from source');
  assert.ok(isOneTopLevelExpression(snippet), 'callFunction must be one expression');
});

test('callFunction embeds no raw newline in generated R', () => {
  // A regression on a real bug in this file: the captureStdout branch built
  // `collapse = "<real newline>"`, which parses (R allows multi-line strings)
  // and made the snippet depend on invisible whitespace. Worse, an escaping
  // slip in the other direction emitted a literal backslash-n BETWEEN
  // statements, which is not valid R at all.
  const captured = R.callFunction('f', [], { captureStdout: true }, 'N');
  assert.ok(captured.includes('collapse = "\\n"'),
    'the newline must be the two-character R escape');
  // No stray escape sequence sitting outside a string literal.
  assert.ok(!/\),\\n/.test(captured),
    'statements must be separated by real newlines, not a literal escape');
  assert.ok(captured.includes('capture.output('), 'captureStdout must capture what was printed');
});

test('callFunction without captureStdout reports the return value', () => {
  const plain = R.callFunction('f', [1], {}, 'N');
  assert.ok(!plain.includes('capture.output('),
    'the default path must report the returned value, not printed output');
});
