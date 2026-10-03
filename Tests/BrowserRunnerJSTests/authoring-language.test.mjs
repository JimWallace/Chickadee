// Unit tests for `Public/authoring-language.js` — the ONE reader of the
// `#assignment-language-seed` island, and therefore the single place every
// authoring editor learns what language it is editing.
//
// It had no test file of its own, which is how two of the facts it parses
// (`functionScanning`, `expressionEvaluation`) came to be seeded by the server,
// parsed here, and read by nobody: an unread flag looks identical to a read one
// from every angle except a test that asks for its accessor.
//
// Each case re-requires the module so the per-page `_cached` facts object is
// rebuilt against that case's seed.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const MODULE = require.resolve('../../Public/authoring-language.js');

/// Load the module with `seed` as the page's language island. Pass null for a
/// page that has no island at all.
function loadWith(seed) {
  globalThis.document = {
    getElementById(id) {
      if (id !== 'assignment-language-seed' || seed === null) return null;
      return { textContent: JSON.stringify(seed) };
    }
  };
  delete require.cache[MODULE];
  require(MODULE);
  return globalThis.ChickadeeLanguage;
}

const R_SEED = {
  name: 'r',
  displayName: 'R',
  trueLiteral: 'TRUE',
  falseLiteral: 'FALSE',
  nullLiteral: 'NULL',
  scriptExtension: 'R',
  functionScanning: false,
  expressionEvaluation: true,
  unsupportedCheckKinds: { astStructure: 'Not available for R assignments.' }
};

test('a page with no seed falls back to Python, which is the pre-seed behaviour', () => {
  const lang = loadWith(null);
  assert.equal(lang.isPython(), true);
  assert.equal(lang.label(), '');
  assert.equal(lang.scriptExtension(), 'py');
  assert.equal(lang.canScanFunctions(), true);
  assert.equal(lang.canEvaluateExpressions(), true);
});

test('an R seed reports R literals, not Python ones', () => {
  const lang = loadWith(R_SEED);
  assert.equal(lang.isPython(), false);
  assert.equal(lang.label(), 'R');
  // The defect this whole seed exists for: an R author typing the boolean true
  // used to store the STRING "TRUE".
  assert.deepEqual(lang.matchScalarToken('TRUE'), { value: true, kind: 'bool' });
  assert.equal(lang.matchScalarToken('True'), null);
  assert.deepEqual(lang.matchScalarToken('NULL'), { value: null, kind: 'null' });
});

test('scriptExtension is the assignment language extension a new test gets', () => {
  assert.equal(loadWith(R_SEED).scriptExtension(), 'R');
  // C++ generates shell wrappers, so a hand-written C++ test is a `.sh` too.
  // Offering `.cpp` would name a file the runner does not execute.
  assert.equal(
    loadWith({ name: 'cpp', displayName: 'C++', scriptExtension: 'sh' }).scriptExtension(),
    'sh');
  // A seed that omits the field (a page cached from before it existed) must
  // not yield "undefined" as an extension.
  assert.equal(loadWith({ name: 'lua', displayName: 'Lua' }).scriptExtension(), 'py');
});

test('canScanFunctions reports the language, so the UI need not run a scan to find out', () => {
  assert.equal(loadWith(R_SEED).canScanFunctions(), false);
  assert.equal(
    loadWith({ name: 'python', displayName: 'Python', functionScanning: true })
      .canScanFunctions(),
    true);
});

test('canEvaluateExpressions is read, not assumed, so a driver-less language can say no', () => {
  assert.equal(loadWith(R_SEED).canEvaluateExpressions(), true);
  // No language ships false today. The accessor exists for the one that will:
  // an unread flag would leave auto-compute filling Expected cells from a
  // server that refuses.
  assert.equal(
    loadWith({ name: 'zig', displayName: 'Zig', expressionEvaluation: false })
      .canEvaluateExpressions(),
    false);
});

test('checkKindUnsupportedReason carries the save-time refusal into the menu', () => {
  const lang = loadWith(R_SEED);
  assert.match(lang.checkKindUnsupportedReason('astStructure'), /Not available for R/);
  assert.equal(lang.checkKindUnsupportedReason('variableExists'), null);
});

test('autoComputeWorker is the seeded in-page worker, or null for the server route', () => {
  // The pattern-family editor called this accessor from #1322 on, but the
  // module never defined it, so auto-compute threw a TypeError for every
  // language (#1956).
  const lang = loadWith({
    ...R_SEED,
    autoComputeWorker: '/r-eval-worker.js',
    autoComputeRuntimeSource: 'chickadee_runtime <- TRUE'
  });
  assert.equal(lang.autoComputeWorker(), '/r-eval-worker.js');
  assert.equal(lang.facts().autoComputeRuntimeSource, 'chickadee_runtime <- TRUE');

  // A language with no kernel (C++, Racket, Java) seeds no worker, and the
  // editor then computes on the server.
  const cpp = loadWith({ name: 'cpp', displayName: 'C++', autoComputeWorker: null });
  assert.equal(cpp.autoComputeWorker(), null);
  assert.equal(cpp.facts().autoComputeRuntimeSource, null);

  // No seed names no worker: which worker runs is never this module's choice.
  assert.equal(loadWith(null).autoComputeWorker(), null);
});

test('every ChickadeeLanguage member a page script calls is exported', async () => {
  // The defect behind #1956 in general form: a caller can name a member that
  // the module never exports, and nothing fails until a user clicks the
  // control. Read every first-party script and check each named member.
  const { readdirSync, readFileSync } = await import('node:fs');
  const { join } = await import('node:path');
  const publicDir = join(require.resolve('../../Public/authoring-language.js'), '..');
  const lang = loadWith(R_SEED);
  const called = new Set();
  for (const name of readdirSync(publicDir)) {
    if (!name.endsWith('.js') || name === 'authoring-language.js') continue;
    const source = readFileSync(join(publicDir, name), 'utf8');
    for (const match of source.matchAll(/ChickadeeLanguage\.([A-Za-z_]\w*)/g)) {
      called.add(`${match[1]} (${name})`);
    }
  }
  assert.ok(called.size > 0, 'the scan must find the editors that use the module');
  for (const entry of called) {
    const member = entry.split(' ')[0];
    assert.equal(typeof lang[member], 'function', `ChickadeeLanguage.${entry} is not exported`);
  }
});

test("parseValue reads the assignment language's spellings, then JSON, then a bare string", () => {
  // #1958: case cells accepted only Python's True/False/None, so an R author
  // typing TRUE as a case argument stored the STRING "TRUE".
  const r = loadWith(R_SEED);
  assert.deepEqual(r.parseValue('TRUE'), { ok: true, value: true, kind: 'bool', strict: true });
  assert.deepEqual(r.parseValue('NULL'), { ok: true, value: null, kind: 'null', strict: true });
  // Python's spelling is not R's: it stays a string, flagged for a look.
  assert.deepEqual(r.parseValue('True'), { ok: true, value: 'True', kind: 'string', strict: false });
  assert.deepEqual(r.parseValue(' 42 '), { ok: true, value: 42, kind: 'number', strict: true });
  assert.deepEqual(r.parseValue('[1, 2]'), { ok: true, value: [1, 2], kind: 'list', strict: true });
  assert.deepEqual(r.parseValue('   '), { ok: false, value: undefined, kind: 'empty', strict: false });

  const racket = loadWith({ name: 'racket', displayName: 'Racket', trueLiteral: '#t', falseLiteral: '#f', nullLiteral: "'null" });
  assert.equal(racket.parseValue('#t').value, true);
  assert.equal(racket.parseValue('#f').value, false);

  // No seed keeps Python's spellings, the behaviour before the seed existed.
  const py = loadWith(null);
  assert.deepEqual(py.parseValue('None'), { ok: true, value: null, kind: 'null', strict: true });
  assert.deepEqual(py.parseValue('False'), { ok: true, value: false, kind: 'bool', strict: true });
});

test('parseValue rewrites a pasted literal, except where a case cell asks it not to', () => {
  const py = loadWith(null);
  assert.deepEqual(py.parseValue("['a', 'b']"), { ok: true, value: ['a', 'b'], kind: 'list', strict: false });
  // A case cell shows a stored string back without quotes, so a rewrite would
  // turn the string 'hello' into hello on the next save.
  assert.deepEqual(py.parseValue("'hello'", { rewriteRepr: false }),
    { ok: true, value: "'hello'", kind: 'string', strict: false });
  assert.deepEqual(py.parseValue('hello'), { ok: true, value: 'hello', kind: 'string', strict: false });
});

test('the authoring editors spell no language literal themselves', async () => {
  // The scalar spellings come from the seed through this module. A quoted
  // True/False/None in an editor is the shape #1958 found in the case cells.
  const { readFileSync } = await import('node:fs');
  const { join } = await import('node:path');
  const publicDir = join(require.resolve('../../Public/authoring-language.js'), '..');
  for (const name of ['pattern-family-editor.js', 'inputs-editor-core.js']) {
    // Comments may name the spellings; code may not.
    const source = readFileSync(join(publicDir, name), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/.*$/gm, '');
    const literal = /['"](True|False|None|TRUE|FALSE|NULL|nil|#t|#f)['"]/.exec(source);
    assert.equal(literal, null, `${name} spells ${literal && literal[0]} itself`);
  }
});
