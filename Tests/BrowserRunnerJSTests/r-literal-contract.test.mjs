// The browser half of the R literal contract.
//
// `Public/r-grading-shared.js`'s `rLiteral` is a second implementation of
// `JSONValue.rLiteral`, because in-page auto-compute must call an R solution
// with arguments the instructor typed but has not saved — there is no server
// round-trip in which the server could render them.
//
// Neither implementation owns the expectations. Both read
// Tests/Fixtures/r-literal-contract.json, so a change to either that is not
// mirrored fails on both sides. The Swift half is RLiteralContractTests.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/r-grading-shared.js');

const { rLiteral } = globalThis.ChickadeeRGradingShared;
const contract = JSON.parse(
  fs.readFileSync(path.resolve('Tests/Fixtures/r-literal-contract.json'), 'utf8'));

test('every contract case renders identically in the browser', () => {
  assert.ok(contract.cases.length > 20, 'the contract should cover a real spread of shapes');
  for (const testCase of contract.cases) {
    assert.equal(
      rLiteral(testCase.json), testCase.r,
      `${testCase.name}: browser rLiteral disagrees with the contract`);
  }
});

test('the contract covers the shapes that actually differ between languages', () => {
  const names = new Set(contract.cases.map((c) => c.name));
  // Each of these is a case where a naive renderer gets R wrong: R has no
  // JSON-null so NA stands in; a homogeneous array is an atomic vector while a
  // mixed one is a list; an empty array cannot be typed so it is a list; and a
  // key that is not a syntactic R name has to be quoted.
  for (const required of [
    'null', 'empty array', 'numeric array', 'mixed scalar array',
    'object non-syntactic key', 'string with control char',
  ]) {
    assert.ok(names.has(required), `the contract must pin "${required}"`);
  }
});
