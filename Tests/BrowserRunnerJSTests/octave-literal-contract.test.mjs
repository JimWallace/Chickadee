// The browser half of the Octave literal contract. See r-literal-contract.test.mjs
// for why a second implementation exists and how it is kept honest.
//
// The Octave-specific trap: `[...]` concatenates rather than collecting, and a
// number beside a string is coerced to its character — `[65, "bc"]` is the char
// array "Abc". So brackets are used only for an all-numeric/boolean array and
// everything else is a cell.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/octave-grading-shared.js');

const { octaveLiteral, octaveStringLiteral } = globalThis.ChickadeeOctaveGradingShared;
const contract = JSON.parse(
  fs.readFileSync(path.resolve('Tests/Fixtures/octave-literal-contract.json'), 'utf8'));

test('every contract case renders identically in the browser', () => {
  assert.ok(contract.cases.length > 20, 'the contract should cover a real spread of shapes');
  for (const testCase of contract.cases) {
    assert.equal(
      octaveLiteral(testCase.json), testCase.octave,
      `${testCase.name}: browser octaveLiteral disagrees with the contract`);
  }
});

test('a string anywhere in an array forces a cell', () => {
  // The distinction the whole renderer turns on. Brackets here would hand the
  // solution the char array "Abc" where the author wrote a two-element list.
  assert.equal(octaveLiteral([65, 'bc']), '{65, "bc"}');
  assert.equal(octaveLiteral(['a']), '{"a"}');
  assert.equal(octaveLiteral([1, 2]), '[1, 2]');
  // Nesting too: `[[1,2],[3,4]]` would concatenate into one four-element row.
  assert.equal(octaveLiteral([[1, 2], [3, 4]]), '{[1, 2], [3, 4]}');
  // And the empty array, which says nothing about what it would have held.
  assert.equal(octaveLiteral([]), '{}');
});

test('control characters are escaped as three-digit octal, never \\x', () => {
  // Octave's \x consumes every hex digit that follows, so "\x0abc" would
  // swallow four characters of payload. Octal stops at three by rule.
  assert.equal(octaveStringLiteral('a\u0001b'), '"a\\001b"');
  assert.equal(octaveStringLiteral('\u007f'), '"\\177"');
  assert.ok(!octaveStringLiteral('\u0001').includes('\\x'));
  // Exactly three digits even when fewer would read the same alone.
  assert.equal(octaveStringLiteral('\u0000'), '"\\000"');
});

test('a null keeps its slot rather than collapsing the array', () => {
  // NA is a double in Octave, so it occupies a position in a row vector — the
  // opposite of Lua, where a nil would vanish from a table constructor.
  assert.equal(octaveLiteral([60, null, 20]), '[60, NA, 20]');
});
