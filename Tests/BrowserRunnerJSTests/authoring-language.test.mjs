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
