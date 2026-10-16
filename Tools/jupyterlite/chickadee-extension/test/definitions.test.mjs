// Unit tests for src/definitions.ts, compiled to lib/ by `jlpm build:lib`.
// The patterns here are the ones the server sends for Python; the extension
// holds none of its own.

import test from 'node:test';
import assert from 'node:assert/strict';
import { compilePatterns, definedNames, sectionHeading } from '../lib/definitions.js';

const python = compilePatterns([
  String.raw`^def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(`,
  String.raw`^([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?=(?!=)`,
]);

test('a cell names each top-level definition once, in order', () => {
  const source = 'GOAL = 8000\ndef count(steps):\n    total = 0\n    return total\ncount = 1';
  assert.deepEqual(definedNames(source, python), ['GOAL', 'count']);
});

test('a comparison, an indented line and a private name are not definitions', () => {
  assert.deepEqual(definedNames('if x == 1:\n    y = 2\n_hidden = 3', python), []);
});

test('with no patterns a cell defines nothing', () => {
  assert.deepEqual(definedNames('x = 1', []), []);
});

test('a pattern this engine cannot compile is dropped', () => {
  assert.equal(compilePatterns(['(unclosed', '^x$']).length, 1);
});

test('a section is the first ## heading of a markdown cell', () => {
  assert.equal(sectionHeading('# Lab\n## Task 2: Average heart rate\n## Later'), 'Task 2: Average heart rate');
  assert.equal(sectionHeading('### Not a section'), null);
});
