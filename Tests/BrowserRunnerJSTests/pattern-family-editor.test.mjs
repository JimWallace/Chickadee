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
