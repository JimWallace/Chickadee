// Unit tests for src/guide.ts: where a task's header and checks line go, the
// status each task shows, and the pill text (notebook views NB4).

import test from 'node:test';
import assert from 'node:assert/strict';
import { compilePatterns } from '../lib/definitions.js';
import {
  checksPrefix, inlineCodeParts, normalizedSource, pillText, placeTask, taskOfCell, taskStatus,
} from '../lib/guide.js';

const python = compilePatterns([
  String.raw`^def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(`,
  String.raw`^([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?=(?!=)`,
]);

const cells = [
  { type: 'markdown', source: '## Task 1: Count active days' },
  { type: 'code', source: 'def count_active_days(steps, goal):\n    ...' },
  { type: 'markdown', source: '## Task 2: Average heart rate' },
  { type: 'code', source: 'def average_heart_rate(readings):\n    return 0' },
  { type: 'code', source: 'summary = average_heart_rate([])' },
];

const task = (overrides = {}) => ({
  sectionID: 's2', heading: 'Task 2: Average heart rate', label: 'Task 2', name: 'Average heart rate',
  points: 3, anchors: [{ kind: 'function', name: 'average_heart_rate' }, { kind: 'variable', name: 'summary' }],
  status: 'fail', hiddenCount: 1,
  checks: [{ name: 'test_a', kind: 'script', result: 'pass' }, { name: 'test_b', kind: 'script', result: 'fail' }],
  ...overrides,
});

test('the header sits above the heading and the checks line under the last anchor', () => {
  const placement = placeTask(task(), cells, python);
  assert.deepEqual([...placement.anchorCells], [3, 4]);
  assert.equal(placement.headerCell, 2);
  assert.equal(placement.checksCell, 4);
  assert.deepEqual([...placement.missing], []);
});

test('with no heading in the notebook, the header sits above the first anchor', () => {
  const placement = placeTask(task({ heading: 'Not in this notebook' }), cells, python);
  assert.equal(placement.headerCell, 3);
});

test('a renamed function is missing, and the checks line falls back to the heading', () => {
  const placement = placeTask(task({ anchors: [{ kind: 'function', name: 'avg_hr' }] }), cells, python);
  assert.deepEqual([...placement.missing], ['avg_hr']);
  assert.equal(placement.checksCell, 2);
});

test('a section anchor is the first code cell after its heading', () => {
  const placement = placeTask(task({ anchors: [{ kind: 'section', name: 'Task 1: Count active days' }] }), cells, python);
  assert.deepEqual([...placement.anchorCells], [1]);
});

test('every anchor cell back at the starter makes the task starter, whatever the attempt said', () => {
  const t = task({ anchors: [{ kind: 'function', name: 'count_active_days' }], heading: 'Task 1: Count active days' });
  const placement = placeTask(t, cells, python);
  const starter = { count_active_days: 'def count_active_days(steps, goal):\n    ...' };
  assert.equal(taskStatus(t, placement, cells, starter), 'starter');
  assert.equal(taskStatus(t, placement, cells, { count_active_days: 'something else' }), 'fail');
  // An anchor with no starter source cannot be compared: the attempt stands.
  assert.equal(taskStatus(t, placement, cells, {}), 'fail');
});

test('the pill says what happened in which attempt', () => {
  const attempt = { number: 2, pending: false, url: '/submissions/s' };
  assert.equal(pillText('pass', task(), attempt, false), 'Passed in attempt 2');
  assert.equal(pillText('fail', task(), attempt, false), '1 check failed in attempt 2');
  const two = task({ checks: [{ name: 'a', kind: 'script', result: 'fail' }, { name: 'b', kind: 'script', result: 'error' }] });
  assert.equal(pillText('fail', two, attempt, true), '2 checks failed in attempt 2 · edited since');
  assert.equal(pillText('starter', task(), attempt, false), 'Still the starter code');
  assert.equal(pillText('fresh', task(), null, false), 'Not submitted yet');
  assert.equal(pillText(null, task(), { number: 3, pending: true, url: '' }, false), 'Attempt 3 is being graded');
  assert.equal(pillText(null, task(), attempt, false), null);
});

test('the checks line says when the checks run', () => {
  const attempt = { number: 2, pending: false, url: '' };
  assert.equal(checksPrefix('fail', attempt), 'Checked in attempt 2');
  assert.equal(checksPrefix('starter', attempt), 'Checked when you submit');
  assert.equal(checksPrefix('fresh', null), 'Checked when you submit');
});

test('normalization matches the server: CRLF and trailing whitespace go', () => {
  assert.equal(normalizedSource('def f():   \r\n    ...\n\n'), 'def f():\n    ...');
});

test('inline code splits on backticks', () => {
  assert.deepEqual(inlineCodeParts('Check with `is None` first'), ['Check with ', 'is None', ' first']);
});

test('a cell belongs to the task whose header comes last before it', () => {
  const headers = [{ sectionID: 's1', cell: 0 }, { sectionID: 's2', cell: 2 }];
  assert.equal(taskOfCell(1, headers), 's1');
  assert.equal(taskOfCell(4, headers), 's2');
  assert.equal(taskOfCell(0, []), null);
});
