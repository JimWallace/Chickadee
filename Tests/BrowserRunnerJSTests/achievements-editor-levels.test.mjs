// Unit tests for the level filter in Public/achievements-editor-core.js
// (docs/achievement-rewards.md, S3). The assignment editor must offer no
// course signal, and the course editor no assignment signal, while one
// condition template carries both.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/achievements-editor-core.js');

function option(value, data) {
  return { value, text: value, getAttribute: (name) => (data && name in data ? data[name] : null) };
}

const OPTIONS = [
  option('grade', { 'data-levels': 'assignment' }),
  option('attempts', { 'data-levels': 'assignment' }),
  option('assignmentsGraded', { 'data-levels': 'course site' }),
  option('legacy', {}),
];
const LEVELS = Core.signalLevelsFromOptions(OPTIONS);
const VALUES = OPTIONS.map((o) => o.value);

test('levels are read off the data-levels attribute', () => {
  assert.deepEqual(LEVELS.grade, ['assignment']);
  assert.deepEqual(LEVELS.assignmentsGraded, ['course', 'site']);
  assert.deepEqual(LEVELS.legacy, []);
});

test('a signal is offered only on a page at one of its levels', () => {
  assert.equal(Core.isSignalAtLevel(LEVELS.grade, 'assignment'), true);
  assert.equal(Core.isSignalAtLevel(LEVELS.grade, 'course'), false);
  assert.equal(Core.isSignalAtLevel(LEVELS.assignmentsGraded, 'assignment'), false);
  assert.equal(Core.isSignalAtLevel(LEVELS.assignmentsGraded, 'course'), true);
});

test('a page with no level, or a signal with no levels, allows it', () => {
  assert.equal(Core.isSignalAtLevel(LEVELS.assignmentsGraded, ''), true);
  assert.equal(Core.isSignalAtLevel(LEVELS.legacy, 'course'), true);
  assert.equal(Core.isSignalAtLevel(undefined, 'course'), true);
});

test('a condition moves to the first signal its page allows', () => {
  assert.equal(Core.signalForLevel('grade', VALUES, LEVELS, 'course'), 'assignmentsGraded');
  assert.equal(Core.signalForLevel('assignmentsGraded', VALUES, LEVELS, 'assignment'), 'grade');
  assert.equal(Core.signalForLevel('attempts', VALUES, LEVELS, 'assignment'), 'attempts');
  assert.equal(Core.signalForLevel('grade', ['grade'], LEVELS, 'course'), 'grade', 'nothing allowed keeps it');
});
