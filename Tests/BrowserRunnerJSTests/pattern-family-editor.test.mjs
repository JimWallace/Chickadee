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
import vm from 'node:vm';

const editorSource = await fs.readFile(
  path.resolve('Public/pattern-family-editor.js'),
  'utf8',
);

// The editor reads its language facts through the shared module the page loads
// ahead of it (Public/authoring-language.js). Any context that evaluates the
// editor must evaluate that first, in the same order the template does.
const languageModuleSource = await fs.readFile(
  path.resolve('Public/authoring-language.js'),
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

// ── Load smoke test ──────────────────────────────────────────────────────────
// The snippet tests above only string-extract Python; nothing else executes the
// editor. This loads the whole IIFE under a stubbed DOM so a runtime load error
// (syntax-valid but a ReferenceError in the IIFE body — e.g. a typo'd helper) is
// caught in CI rather than only in the browser.
test("editor IIFE executes without throwing under a stubbed DOM", () => {
  const make = () => new Proxy(function () {}, {
    get(_t, p) {
      if (p === 'value') return '';
      if (p === 'dataset' || p === 'style') return {};
      if (p === 'classList') return { contains: () => false };
      return make();
    },
    apply() { return make(); },
    construct() { return make(); },
  });
  const doc = {
    getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
    addEventListener() {}, createElement: () => make(), currentScript: { dataset: {} },
    body: make(), head: make(),
  };
  const ctx = {
    console, document: doc, setTimeout, clearTimeout, JSON, Array, Object, Math,
    Set, Map, Promise, RegExp, fetch: () => Promise.resolve({}), location: { href: '' },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  assert.doesNotThrow(() => {
    vm.runInNewContext(languageModuleSource, ctx, { filename: 'authoring-language.js' });
    vm.runInNewContext(editorSource, ctx, { filename: 'pattern-family-editor.js' });
  });
});

// Regression guard for the slice-D per-student Expected wiring: the strict
// reader maps a `$name` Expected cell to `expectedVarRef` (not a literal), and
// the helper that lets per-student refs validate against Global Inputs exists.
test("editor carries the per-student expectedVarRef + Global-Inputs wiring", () => {
  assert.ok(editorSource.includes('expectedVarRef'),
    'editor must serialize a $name Expected cell into expectedVarRef');
  assert.ok(editorSource.includes('collectDeclaredInputNames'),
    'editor must union Global Input names so per-student refs are not red-flagged');
  assert.ok(editorSource.includes('js-global-input-name'),
    'editor must read Global Input names from the DOM');
});

// ── The editor knows which language it is editing ────────────────────────────
//
// It used to know nothing: `Public/pattern-family-editor.js` contained the
// string "language" zero times, so an R author typing TRUE got the *string*
// "TRUE" (not JSON, and the repr fallback only rewrote Python's case-sensitive
// `True`), and the placeholder offered a "— Python default —".
//
// These boot the real IIFE under a stubbed DOM that serves an
// `#assignment-language-seed`, then drive the parser the same way a keystroke
// does, so what is asserted is behaviour rather than the presence of a string.

/// Boot the editor with `facts` as the language seed and return the live API
/// plus the parse helper the value boxes use.
function bootEditorWithLanguage(facts) {
  const make = () => new Proxy(function () {}, {
    get(_t, p) {
      if (p === 'value') return '';
      if (p === 'dataset' || p === 'style') return {};
      if (p === 'classList') return { contains: () => false };
      if (p === 'textContent') return '';
      return make();
    },
    apply() { return make(); },
    construct() { return make(); },
  });
  const seedEl = facts === null ? null : { textContent: JSON.stringify(facts) };
  const doc = {
    getElementById: (id) => (id === 'assignment-language-seed' ? seedEl : null),
    querySelector: () => null, querySelectorAll: () => [],
    addEventListener() {}, createElement: () => make(), currentScript: { dataset: {} },
    body: make(), head: make(),
  };
  const ctx = {
    console, document: doc, setTimeout, clearTimeout, JSON, Array, Object, Math,
    Set, Map, Promise, RegExp, String, Boolean, Number,
    fetch: () => Promise.resolve({}), location: { href: '' },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(languageModuleSource, ctx, { filename: 'authoring-language.js' });
  vm.runInNewContext(editorSource, ctx, { filename: 'pattern-family-editor.js' });
  return ctx;
}

test("editor boots against a language seed without throwing", () => {
  assert.doesNotThrow(() => bootEditorWithLanguage({
    name: 'r', displayName: 'R',
    trueLiteral: 'TRUE', falseLiteral: 'FALSE', nullLiteral: 'NA',
    functionScanning: false, expressionEvaluation: false,
  }));
  // …and with no seed at all, which is the language-less assignment and any
  // page that predates the seed. Falling back must not throw either.
  assert.doesNotThrow(() => bootEditorWithLanguage(null));
});

test("the editor reads its language facts from the seed, not from a table", () => {
  // The spellings must reach the parser from the seed. A hardcoded JS table
  // would be a second source of truth for something JSONValue.literal already
  // answers, and the two could disagree — the whole reason the seed exists.
  assert.ok(editorSource.includes('assignment-language-seed'),
    'editor must read #assignment-language-seed');
  assert.ok(editorSource.includes('languageReprToJSON'),
    'the repr fallback must go through the language-aware rewriter');
  // No surviving hardcoded Python-token rewrite.
  assert.ok(!/\\bTrue\\b\/g/.test(editorSource),
    'a hardcoded \\bTrue\\b rewrite is still present — the fallback is Python-only again');
  assert.ok(!editorSource.includes('— Python default —'),
    'the Python-named placeholder is still present');
  assert.ok(!editorSource.includes('Not a valid Python identifier.'),
    'the Python-named identifier error is still present');
});

/// Boot ONLY the shared language module against a seed, so its behaviour can be
/// driven directly rather than inferred from the editor's source shape.
function bootLanguageModule(facts) {
  const seedEl = facts === null ? null : { textContent: JSON.stringify(facts) };
  const ctx = {
    console, JSON, String, RegExp, Array, Object,
    document: { getElementById: (id) => (id === 'assignment-language-seed' ? seedEl : null) },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(languageModuleSource, ctx, { filename: 'authoring-language.js' });
  return ctx.ChickadeeLanguage;
}

test("each language's own true/false/null spelling parses to the right value", () => {
  const cases = [
    ['python', { trueLiteral: 'True', falseLiteral: 'False', nullLiteral: 'None' }],
    ['r', { trueLiteral: 'TRUE', falseLiteral: 'FALSE', nullLiteral: 'NA' }],
    ['lua', { trueLiteral: 'true', falseLiteral: 'false', nullLiteral: 'nil' }],
    ['racket', { trueLiteral: '#t', falseLiteral: '#f', nullLiteral: "'null" }],
  ];
  for (const [name, lits] of cases) {
    const L = bootLanguageModule({ name, displayName: name, ...lits });
    assert.equal(L.matchScalarToken(lits.trueLiteral).value, true, `${name} true`);
    assert.equal(L.matchScalarToken(lits.falseLiteral).value, false, `${name} false`);
    assert.equal(L.matchScalarToken(lits.nullLiteral).value, null, `${name} null`);
    // The defect this fixes: an R author's TRUE used to fall through to the
    // bare-string branch and be stored as the string.
    assert.notEqual(L.matchScalarToken(lits.trueLiteral), null);
  }
});

test("Racket's quoted null survives the repr rewrite", () => {
  // Tokens must be rewritten BEFORE the quote swap. Swapping first turns
  // `'null` into `"null` and loses it — the one ordering bug in this rewriter.
  const L = bootLanguageModule({
    name: 'racket', displayName: 'Racket',
    trueLiteral: '#t', falseLiteral: '#f', nullLiteral: "'null",
  });
  assert.equal(JSON.parse(L.reprToJSON("'null")), null);
  assert.equal(JSON.parse(L.reprToJSON('#t')), true);
  // A token inside a collection is rewritten too, and the surrounding JSON
  // still parses.
  assert.deepEqual(JSON.parse(L.reprToJSON("[1, #t, 'null]")), [1, true, null]);
});

test("a C++ assignment is offered no null token", () => {
  // Its literal(.null) is a poison identifier, not something to type.
  const L = bootLanguageModule({
    name: 'cpp', displayName: 'C++',
    trueLiteral: 'true', falseLiteral: 'false', nullLiteral: null,
  });
  assert.equal(L.scalarTokens().length, 2);
  assert.equal(L.matchScalarToken('nullptr'), null);
});

test("no seed falls back to Python, which is the previous behaviour", () => {
  const L = bootLanguageModule(null);
  assert.equal(L.matchScalarToken('True').value, true);
  assert.equal(L.matchScalarToken('None').value, null);
  assert.equal(L.label(), '');
});

// The shared scan-payload readers. They live in this linted module rather than
// inline in assignment-new.leaf because template JS is neither linted nor
// tested — and the create page's inline copy is exactly the fork that went
// stale three ways in #1269.
test("the scan-payload readers handle both response shapes", () => {
  const ctx = bootEditorWithLanguage(null);
  const read = ctx.chickadeeReadScanPayload;
  assert.equal(typeof read, 'function', 'chickadeeReadScanPayload must be exported');

  // Object shape with a reason: no functions, and the reason survives.
  const unsupported = read({ functions: [], unsupportedReason: 'Racket is upload-only.' });
  assert.equal(unsupported.functions.length, 0);
  assert.equal(unsupported.unsupportedReason, 'Racket is upload-only.');

  // Object shape with functions and no reason.
  const ok = read({ functions: [{ name: 'f' }], unsupportedReason: null });
  assert.equal(ok.functions.length, 1);
  assert.equal(ok.unsupportedReason, null);

  // Bare array — a cached older page. Must not be read as "unsupported".
  const legacy = read([{ name: 'g' }]);
  assert.equal(legacy.functions.length, 1);
  assert.equal(legacy.unsupportedReason, null);

  // Junk must not throw; an empty scan is the safe answer.
  assert.equal(read(null).functions.length, 0);
  assert.equal(read(undefined).functions.length, 0);
});

test("auto-compute picks its substrate from the language seed", () => {
  // The original defect: the in-page evaluator was a Python kernel, so on an R
  // assignment it computed a PYTHON answer for a value compared against R's
  // result. The first fix routed every non-Python language to the server by
  // testing `name !== 'python'` — which fixed the wrong answer and then became
  // the wrong RULE, because the editor exists for in-browser verification and a
  // language with a kernel should evaluate in the browser.
  //
  // So this asserts the seam rather than either rule: which worker runs comes
  // from the descriptor, and the server is the fallback for a language that
  // declares none.
  assert.ok(editorSource.includes('callSolutionOnServer'),
    'a server-side compute path must exist');
  assert.ok(editorSource.includes('compute-expected') || editorSource.includes('computeExpected'),
    'the server path must call the compute-expected endpoint');
  assert.ok(/ChickadeeLanguage\.autoComputeWorker\(\)/.test(editorSource),
    'the worker must come from the language seed, not from a name check here');

  // No hardcoded worker path. A literal `/x-eval-worker.js` in this file is the
  // shape that made auto-compute Python-only: the editor reached for one
  // kernel by name and no seed could redirect it.
  const hardcodedWorker = /['"]\/[a-z-]*eval-worker\.js['"]/.exec(editorSource);
  assert.equal(hardcodedWorker, null,
    `the editor must not name a worker itself (found ${hardcodedWorker && hardcodedWorker[0]})`);
});
