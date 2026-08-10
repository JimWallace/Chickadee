// The browser half of the Lua literal contract. See r-literal-contract.test.mjs
// for why a second implementation exists and how it is kept honest.
//
// The Lua-specific trap: null is `nil` at top level and `chickadee.NULL` inside
// any table, because a `nil` in a table constructor is not stored and the table
// silently loses a slot.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/lua-grading-shared.js');

const { luaLiteral } = globalThis.ChickadeeLuaGradingShared;
const contract = JSON.parse(
  fs.readFileSync(path.resolve('Tests/Fixtures/lua-literal-contract.json'), 'utf8'));

test('every contract case renders identically in the browser', () => {
  assert.ok(contract.cases.length > 20, 'the contract should cover a real spread of shapes');
  for (const testCase of contract.cases) {
    assert.equal(
      luaLiteral(testCase.json, false), testCase.lua,
      `${testCase.name}: browser luaLiteral disagrees with the contract`);
  }
});

test('null renders differently inside a table than at top level', () => {
  // The distinction the whole renderer turns on. Getting it wrong produces a
  // table of the wrong length that a generated test then grades against.
  assert.equal(luaLiteral(null, false), 'nil');
  assert.equal(luaLiteral(null, true), 'chickadee.NULL');
  assert.equal(luaLiteral([1, null, 3], false), '{1, chickadee.NULL, 3}');
});
