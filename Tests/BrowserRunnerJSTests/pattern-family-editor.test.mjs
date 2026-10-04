// Regression guard: the Python auto-compute call cell runs its snippet through
// `runExpressionPython` (Public/python-eval-shared.js). That wrapper reports a
// value only when `body[-1]` of the parsed Python AST is an `ast.Expr`. Every
// other top-level statement type (If, With, Assign, Import, …) reports no
// value, and auto-compute stops filling cells with no error.
//
// v0.4.124 shipped a `callSolution` whose value-mode snippet ended in an
// `if/else`, hitting exactly that failure mode (under Pyodide's `eval_code`,
// which had the same rule). v0.4.125 fixed it by computing the JSON payload
// into `_payload` and putting a bare `_json.dumps(_payload, default=str)` on
// the last line.
//
// The snippets were built in Public/pattern-family-editor.js and moved to
// `callSnippetPython` in Public/python-eval-shared.js (#1964). This test
// builds each snippet with that function under a fake function name `f` and an
// empty argument list, and shells out to `python3 -m ast` (via a tiny inline
// script) to assert `body[-1]` is an `ast.Expr`.
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

// Auto-compute moved out of the editor into Public/auto-compute-client.js
// (#1966). The auto-compute source-shape tests below read that file. Their
// "must not" assertions read both files, so the editor cannot take a defect
// back either.
const clientSource = await fs.readFile(
  path.resolve('Public/auto-compute-client.js'),
  'utf8',
);
const autoComputeSources = [
  ['pattern-family-editor.js', editorSource],
  ['auto-compute-client.js', clientSource],
];

// The editor reads its language facts through the shared module the page loads
// ahead of it (Public/authoring-language.js). Any context that evaluates the
// editor must evaluate that first, in the same order the template does.
const languageModuleSource = await fs.readFile(
  path.resolve('Public/authoring-language.js'),
  'utf8',
);

// The Python eval module, loaded in the order python-eval-worker.js loads it.
const pythonEvalContext = { console };
pythonEvalContext.globalThis = pythonEvalContext;
vm.createContext(pythonEvalContext);
for (const file of [
  'grading-shared.js', 'eval-protocol-shared.js',
  'python-grading-shared.js', 'python-eval-shared.js',
]) {
  vm.runInContext(await fs.readFile(path.resolve('Public', file), 'utf8'),
    pythonEvalContext, { filename: file });
}
const pythonEval = pythonEvalContext.ChickadeePythonEvalShared;

/// Build the snippet `name` ('value' or 'stdout') with `callSnippetPython`,
/// for a function named `f` called with no arguments. Returns the Python
/// source as a string.
function extractSnippet(name) {
  assert.equal(typeof pythonEval.callSnippetPython, 'function',
    'python-eval-shared.js must export callSnippetPython');
  const source = pythonEval.callSnippetPython('f', [], { captureStdout: name === 'stdout' });
  assert.equal(typeof source, 'string', `snippet '${name}' is not a string`);
  return source;
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
        f"not ast.Expr — runExpressionPython will report no value, "
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
      `Python call snippet '${snippetName}' has the wrong AST shape: ${detail}\n` +
      `--- reconstructed source ---\n${source}\n--- end ---`
    );
  }
}

test("Python value-mode snippet ends in an ast.Expr (so runExpressionPython reports a value)", () => {
  const src = extractSnippet('value');
  assertEndsInAstExpr(src, 'value');
});

test("Python stdout-mode snippet ends in an ast.Expr", () => {
  const src = extractSnippet('stdout');
  assertEndsInAstExpr(src, 'stdout');
});

test("Both snippets reference the substituted JS variables (sanity)", () => {
  // If someone removes the JS interpolation entirely the snippet tests
  // still pass vacuously — guard against that by asserting the built
  // source contains the function name and the arguments.
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
// The AST tests above guarantee runExpressionPython reports a string.
// These tests run the snippets under CPython with `f` defined as various
// edge cases, parse the JSON the snippet emits, and assert it carries
// the right `__chickadee_kind__` sentinel so the JS-side handler routes
// to the right UI feedback (error vs. None vs. unsupported).
//
// xeus-python runs CPython, so `inspect`, `json`, and `isinstance`
// semantics match — the production failure modes we're guarding against
// (coroutine returned without await, set vs. JSON array silent
// miscompare, …) are language-level, not kernel-specific.

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
  assert.ok(clientSource.includes('callSolutionOnServer'),
    'a server-side compute path must exist');
  assert.ok(clientSource.includes('compute-expected') || clientSource.includes('computeExpected'),
    'the server path must call the compute-expected endpoint');
  assert.ok(/ChickadeeLanguage\.autoComputeWorker\(\)/.test(clientSource),
    'the worker must come from the language seed, not from a name check here');

  // No hardcoded worker path. A literal `/x-eval-worker.js` in this file is the
  // shape that made auto-compute Python-only: the editor reached for one
  // kernel by name and no seed could redirect it.
  for (const [name, source] of autoComputeSources) {
    const hardcodedWorker = /['"]\/[a-z-]*eval-worker\.js['"]/.exec(source);
    assert.equal(hardcodedWorker, null,
      `${name} must not name a worker itself (found ${hardcodedWorker && hardcodedWorker[0]})`);
  }
});

test("auto-compute returns describeCallFailure's result as is", () => {
  // describeCallFailure already returns `{ ok: false, error }`. Wrapping it in
  // another object made the Expected cell show "[object Object]" for every R,
  // Lua and Octave solution error (#1994).
  assert.ok(clientSource.includes('return describeCallFailure(err, cellErrors);'),
    'a failed call must return the described failure');
  for (const [name, source] of autoComputeSources) {
    assert.equal(/error:\s*describeCallFailure\(/.exec(source), null,
      `the described failure must not be wrapped in another object (${name})`);
  }
});

test("the editor sends every in-page language the structured call (#1964)", () => {
  // The editor built the Python call snippet itself and sent it as `run`,
  // while every other kernel language got `call`. The snippet now lives in
  // python-eval-shared.js, and the worker builds it. These assertions read
  // the code only, because comments may describe the old shape.
  const codeOf = (source) => source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/gm, '');
  for (const [name, source] of autoComputeSources) {
    const code = codeOf(source);
    assert.equal(/isPython\(\)/.exec(code), null,
      `auto-compute must not branch on the language name (${name})`);
    assert.equal(/type:\s*'run'/.exec(code), null,
      `the editor must not send a snippet of its own to run (${name})`);
    assert.ok(!code.includes('__chickadee_kind__'),
      `the Python payload must be read in python-eval-shared.js, not here (${name})`);
  }
  const code = codeOf(clientSource);
  assert.ok(/type:\s*'call'/.test(code), 'the editor must send the structured call');
  // The reply fields that carry Python's None and unsupported cases.
  assert.ok(code.includes('data.returnedNone'), 'the editor must read returnedNone');
  assert.ok(code.includes('data.unsupported'), 'the editor must read unsupported');
});
