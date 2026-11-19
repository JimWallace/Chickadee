// Unit tests for src/guide.ts: where a task's header and checks line go, the
// status each task shows, and the pill text (notebook views NB4).

import test from 'node:test';
import assert from 'node:assert/strict';
import { compilePatterns } from '../lib/definitions.js';
import {
  checksPrefix, inlineCodeParts, normalizedSource, pillText, placeTask, placeTasks, reflectionStatus, taskOfCell,
  taskStatus,
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

test('the header sits above its own heading, and the title is that heading', () => {
  const placement = placeTask(task(), cells, python);
  assert.equal(placement.headingCell, 2);
  assert.equal(placement.title, 'Task 2: Average heart rate');
});

test('a suite name the notebook lacks gives way to the heading above the first anchor', () => {
  const placement = placeTask(task({ heading: 'Question 2', label: null, name: 'Question 2' }), cells, python);
  assert.equal(placement.headingCell, 2);
  assert.equal(placement.headerCell, 2);
  assert.equal(placement.title, 'Task 2: Average heart rate');
});

test('the checks in no section take the heading above their first anchor', () => {
  const placement = placeTask(task({ sectionID: null, heading: null, label: null, name: 'Other checks' }), cells, python);
  assert.equal(placement.title, 'Task 2: Average heart rate');
});

test('with no heading above the first anchor, the header sits on it under the suite name', () => {
  const bare = cells.slice(3);
  const placement = placeTask(task({ heading: 'Question 2', label: null, name: 'Question 2' }), bare, python);
  assert.equal(placement.headingCell, null);
  assert.equal(placement.headerCell, 0);
  assert.equal(placement.title, 'Question 2');
});

// A1 in HLTH 230: every task's tests also call bmi(), so each task has an
// ambiguous anchor on it. Each header must still sit with its own functions.
const bmiCells = [
  { type: 'markdown', source: '# Python Functions' },
  { type: 'markdown', source: '## 1. Warm Up I: BMI Calculator' },
  { type: 'code', source: 'def bmi(w, h):\n    pass' },
  { type: 'code', source: 'def bmi_category(b):\n    pass' },
  { type: 'markdown', source: '## 2. Warm Up II: BMI Category' },
  { type: 'code', source: 'def is_underweight(b):\n    pass' },
  { type: 'code', source: 'def is_obese(b):\n    pass' },
];
const shared = { kind: 'function', name: 'bmi', ambiguous: true };
const question = (n, anchors) => task({ sectionID: `q${n}`, heading: `Question ${n}`, label: null, name: `Question ${n}`, anchors });

test('a shared helper does not pull every header up to its cell', () => {
  const tasks = [
    question(1, [{ kind: 'function', name: 'bmi' }, shared, { kind: 'function', name: 'bmi_category' }]),
    question(2, [{ kind: 'function', name: 'is_underweight' }, shared, { kind: 'function', name: 'is_obese' }]),
  ];
  const [one, two] = placeTasks(tasks, bmiCells, python);
  assert.equal(one.headerCell, 1);
  assert.equal(one.checksCell, 3);
  assert.equal(one.title, '1. Warm Up I: BMI Calculator');
  assert.equal(two.headerCell, 4);
  assert.equal(two.checksCell, 6);
  assert.equal(two.title, '2. Warm Up II: BMI Category');
});

test('a task placed only by a shared helper takes no heading', () => {
  const placement = placeTask(question(4, [shared]), bmiCells, python);
  assert.equal(placement.headingCell, null);
  assert.equal(placement.headerCell, 2);
  assert.equal(placement.title, 'Question 4');
});

test('a heading found above the anchors goes to the task that comes first under it', () => {
  // Suite order is the reverse of notebook order: the notebook decides.
  const tasks = [
    question(2, [{ kind: 'function', name: 'bmi_category' }]),
    question(1, [{ kind: 'function', name: 'bmi' }]),
  ];
  const [two, one] = placeTasks(tasks, bmiCells, python);
  assert.equal(one.headerCell, 1);
  assert.equal(one.title, '1. Warm Up I: BMI Calculator');
  assert.equal(two.headerCell, 3);
  assert.equal(two.title, 'Question 2');
});

test('a task\'s own heading is never taken by a task that finds it above its anchors', () => {
  const tasks = [
    question(9, [{ kind: 'function', name: 'bmi' }]),
    task({ sectionID: 'w', heading: '1. Warm Up I: BMI Calculator', label: '1. Warm Up I', name: 'BMI Calculator',
      anchors: [{ kind: 'function', name: 'bmi_category' }] }),
  ];
  const [other, own] = placeTasks(tasks, bmiCells, python);
  assert.equal(own.headerCell, 1);
  assert.equal(other.headerCell, 2);
  assert.equal(other.title, 'Question 9');
});

test('a finished shared helper does not end the starter status of a task', () => {
  const t = question(2, [{ kind: 'function', name: 'is_underweight' }, shared]);
  const edited = bmiCells.map((c, i) => (i === 2 ? { ...c, source: 'def bmi(w, h):\n    return w / (h / 100) ** 2' } : c));
  const placement = placeTask(t, edited, python);
  const starter = { is_underweight: 'def is_underweight(b):\n    pass', bmi: 'def bmi(w, h):\n    pass' };
  assert.equal(taskStatus(t, placement, edited, starter), 'starter');
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

test('a reflection is written when a cell with its tag has text', () => {
  const tagged = [
    { tags: ['reflection'], source: '  \n' },
    { tags: [], source: 'not a reflection' },
  ];
  assert.equal(reflectionStatus('reflection', tagged), 'empty');
  tagged.push({ tags: ['reflection'], source: 'I chose the median.' });
  assert.equal(reflectionStatus('reflection', tagged), 'written');
  assert.equal(reflectionStatus('other', tagged), 'empty');
});
