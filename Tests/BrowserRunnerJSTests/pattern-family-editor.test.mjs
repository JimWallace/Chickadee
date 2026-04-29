// Regression guard: Pyodide's `eval_code` in `last_expr` mode only returns a
// value to JS when `body[-1]` of the parsed Python AST is an `ast.Expr`.
// Every other top-level statement type (If, With, Assign, Import, …)
// causes `runPythonAsync` to resolve with `undefined`, downstream
// `JSON.parse(undefined)` to throw, and auto-compute to silently break.
//
// v0.4.124 shipped a `callSolution` whose value-mode snippet ended in an
// `if/else`, hitting exactly that failure mode.  v0.4.125 fixes it by
// computing the JSON payload into `_payload` and putting a bare
// `_json.dumps(_payload, default=str)` on the last line.
//
// This test extracts each snippet from the live JS file (between
// `// PYODIDE_SNIPPET_BEGIN: <name>` and `// PYODIDE_SNIPPET_END: <name>`
// markers in `Public/pattern-family-editor.js`), `eval`s the array
// literal under fake `fnLit` / `argsLit` substitutions to get the
// reconstructed Python source, and shells out to `python3 -m ast` (via a
// tiny inline script) to assert `body[-1]` is an `ast.Expr`.
//
// If you change the snippet shape and CI starts failing here, the right
// fix is to make sure the LAST top-level Python statement is a bare
// expression — not an assignment, not an `if`, not a `with`.  Move the
// computation into a variable assignment if needed and put a final
// `_json.dumps(<that variable>)` expression on the last line.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const editorSource = await fs.readFile(
  path.resolve('Public/pattern-family-editor.js'),
  'utf8',
);

/// Extract the array literal that follows `pyCode = ` between the
/// snippet's BEGIN/END marker comments and `eval` it under fake values
/// for the JS-side substitutions (`fnLit`, `argsLit`).  Returns the
/// reconstructed Python source as a string.
function extractSnippet(name) {
  const begin = `// PYODIDE_SNIPPET_BEGIN: ${name}`;
  const end = `// PYODIDE_SNIPPET_END: ${name}`;
  const beginIx = editorSource.indexOf(begin);
  const endIx = editorSource.indexOf(end, beginIx);
  assert.ok(beginIx >= 0 && endIx > beginIx,
    `markers '${begin}' / '${end}' not found in pattern-family-editor.js`);
  const block = editorSource.slice(beginIx, endIx);

  // Pull the array literal: `pyCode = [ ... ].join('\n')`.
  const arrMatch = block.match(/pyCode\s*=\s*(\[[\s\S]*?\])\s*\.join\(/);
  assert.ok(arrMatch, `did not find 'pyCode = [...].join(' inside snippet '${name}'`);

  // The array references `fnLit` and `argsLit` — both are JS strings
  // produced by `JSON.stringify(<thing>)` (so they're already-quoted
  // JSON literals).  Substitute realistic placeholders.
  const fnLit = JSON.stringify('f');
  const argsLit = JSON.stringify('[]');
  // eslint-disable-next-line no-new-func
  const lines = new Function('fnLit', 'argsLit', `return ${arrMatch[1]};`)(fnLit, argsLit);
  assert.ok(Array.isArray(lines), `evaluated array literal for '${name}' is not an array`);
  return lines.join('\n');
}

/// Run python3 to AST-parse the source and assert the last top-level
/// statement is an `ast.Expr`.  Returns nothing on success; throws on
/// shape mismatch or python failure.
function assertEndsInAstExpr(source, snippetName) {
  const py = `
import ast, sys
mod = ast.parse(sys.stdin.read())
if not mod.body:
    sys.stderr.write("snippet body is empty\\n")
    sys.exit(2)
last = mod.body[-1]
if not isinstance(last, ast.Expr):
    sys.stderr.write(
        f"snippet last top-level statement is {type(last).__name__}, "
        f"not ast.Expr — Pyodide eval_code(last_expr) will return None to JS, "
        f"breaking JSON.parse downstream.\\n"
    )
    sys.exit(1)
`;
  const result = spawnSync('python3', ['-c', py], {
    input: source,
    encoding: 'utf8',
  });
  if (result.status !== 0) {
    const detail = (result.stderr || '').trim() || `exit ${result.status}`;
    assert.fail(
      `Pyodide snippet '${snippetName}' has the wrong AST shape: ${detail}\n` +
      `--- reconstructed source ---\n${source}\n--- end ---`
    );
  }
}

test("Pyodide value-mode snippet ends in an ast.Expr (so runPythonAsync returns a value)", () => {
  const src = extractSnippet('value');
  assertEndsInAstExpr(src, 'value');
});

test("Pyodide stdout-mode snippet ends in an ast.Expr", () => {
  const src = extractSnippet('stdout');
  assertEndsInAstExpr(src, 'stdout');
});

test("Both snippets reference the substituted JS variables (sanity)", () => {
  // If someone removes the JS interpolation entirely the substitution
  // logic still passes vacuously — guard against that by asserting the
  // reconstructed source contains the substituted function name.
  for (const name of ['value', 'stdout']) {
    const src = extractSnippet(name);
    assert.ok(src.includes('globals().get("f")'),
      `snippet '${name}' did not pick up the fnLit substitution`);
    assert.ok(src.includes('_json.loads("[]")'),
      `snippet '${name}' did not pick up the argsLit substitution`);
  }
});

// ── Runtime semantic tests for v0.4.130 ──────────────────────────────────
//
// The AST tests above guarantee Pyodide will return a string to JS.
// These tests run the snippets under CPython with `f` defined as various
// edge cases, parse the JSON the snippet emits, and assert it carries
// the right `__chickadee_kind__` sentinel so the JS-side handler routes
// to the right UI feedback (error vs. None vs. unsupported).
//
// CPython is close enough to Pyodide's interpreter for `inspect`,
// `json`, and `isinstance` semantics to match — the production failure
// modes we're guarding against (coroutine returned without await, set
// vs. JSON array silent miscompare, …) are language-level, not
// Pyodide-specific.

/// Runs `fSetup; <snippet>` under python3 and returns the parsed JSON
/// payload the snippet would have handed to JS, or `{ exitError: msg }`
/// if the python process exited non-zero.
///
/// The snippet's final top-level statement is a bare `_json.dumps(...)`
/// expression (per the AST tests above).  CPython doesn't echo bare
/// expressions at script-level (unlike REPL), so we wrap the last line
/// with `print(<that>, end="")` to capture it on stdout.
function runSnippet(snippetName, fSetup) {
  const src = extractSnippet(snippetName);
  const lines = src.split('\n');
  let lastIdx = lines.length - 1;
  while (lastIdx >= 0 && lines[lastIdx].trim() === '') lastIdx--;
  lines[lastIdx] = `print(${lines[lastIdx]}, end="")`;
  const program = `${fSetup}\n${lines.join('\n')}\n`;
  const result = spawnSync('python3', ['-c', program], { encoding: 'utf8' });
  if (result.status !== 0) {
    return { exitError: (result.stderr || '').trim() || `exit ${result.status}` };
  }
  return JSON.parse(result.stdout);
}

test("value snippet flags coroutine returns as unsupported", () => {
  const out = runSnippet('value', 'async def f():\n    return 5');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'coroutine' });
});

test("value snippet flags generator returns as unsupported", () => {
  const out = runSnippet('value', 'def f():\n    yield 1\n    yield 2');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'generator' });
});

test("value snippet flags async-generator returns as unsupported", () => {
  const out = runSnippet('value', 'async def f():\n    yield 1');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'async-generator' });
});

test("value snippet flags set returns as unsupported", () => {
  const out = runSnippet('value', 'def f():\n    return {1, 2, 3}');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'set' });
});

test("value snippet flags tuple returns as unsupported (avoids list/tuple miscompare)", () => {
  // `(1,2) == [1,2]` is False in Python — silent miscompare if we
  // round-tripped via JSON.  Must surface as unsupported instead.
  const out = runSnippet('value', 'def f():\n    return (1, 2, 3)');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'tuple' });
});

test("value snippet flags bytes returns as unsupported", () => {
  const out = runSnippet('value', 'def f():\n    return b"hello"');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'bytes' });
});

test("value snippet flags complex returns as unsupported", () => {
  const out = runSnippet('value', 'def f():\n    return 1 + 2j');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'complex' });
});

test("value snippet still passes through a None return as 'none'", () => {
  const out = runSnippet('value', 'def f():\n    return None');
  assert.deepEqual(out, { __chickadee_kind__: 'none' });
});

test("value snippet still passes through a JSON-friendly value", () => {
  const out = runSnippet('value', 'def f():\n    return "underweight"');
  assert.deepEqual(out, { __chickadee_kind__: 'value', value: 'underweight' });
});

test("value snippet passes through dicts and lists unchanged", () => {
  const out = runSnippet('value', 'def f():\n    return {"a": [1, 2], "b": True}');
  assert.deepEqual(out, { __chickadee_kind__: 'value', value: { a: [1, 2], b: true } });
});

test("stdout snippet flags coroutine returns as unsupported", () => {
  // An async function used by mistake in stdout mode never enters its
  // body, so the captured buffer is empty.  Pre-v0.4.130 the instructor
  // saw a silently-empty Expected.  Now: explicit reason.
  const out = runSnippet('stdout', 'async def f():\n    print("hello")');
  assert.deepEqual(out, { __chickadee_kind__: 'unsupported', reason: 'coroutine' });
});

test("stdout snippet captures normal print output and strips trailing newline", () => {
  const out = runSnippet('stdout', 'def f():\n    print("hello")');
  assert.deepEqual(out, { __chickadee_kind__: 'value', value: 'hello' });
});

test("stdout snippet preserves multi-line print output (only strips final newline)", () => {
  const out = runSnippet('stdout', 'def f():\n    print("a")\n    print("b")');
  assert.deepEqual(out, { __chickadee_kind__: 'value', value: 'a\nb' });
});
