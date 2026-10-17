// Tests for src/margin.ts: where the instructor's test cards sit beside the
// notebook (notebook views NB7), and what their summaries say.

import test from 'node:test';
import assert from 'node:assert/strict';
import { compilePatterns } from '../lib/definitions.js';
import {
  findItem, issueText, itemIssue, itemState, marginKey, pinName, placeSuite, sectionMeta, sectionOf, stripSummary,
} from '../lib/margin.js';

const python = compilePatterns([
  String.raw`^def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(`,
  String.raw`^([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?=(?!=)`,
]);

const cells = [
  { type: 'markdown', source: '## Task 1: Count' },
  { type: 'code', source: 'def count_to(n):\n    return list(range(n))' },
  { type: 'markdown', source: '## Task 2: Total' },
  { type: 'code', source: 'def total(xs):\n    return 0' },
];

const item = (id, anchor, solution, extra = {}) => ({
  id, name: id.replace('.py', ''), kind: 'script', tier: 'public', points: 1,
  anchor, solution: solution ? { result: solution } : null, ...extra,
});

const suite = {
  version: 1,
  sections: [
    {
      id: 's1', title: 'Task 1: Count', label: 'Task 1', points: 2,
      items: [
        item('test_a.py', { kind: 'function', name: 'count_to', source: 'auto', ambiguous: false }, 'pass'),
        item('test_b.py', { kind: 'function', name: 'count_to', source: 'pinned', ambiguous: false }, 'fail'),
      ],
    },
    {
      id: 's2', title: 'Task 2: Total', label: 'Task 2', points: 1,
      items: [item('test_c.py', { kind: 'section', name: 'Task 2: Total', source: 'auto', ambiguous: false }, null)],
    },
    { id: 's3', title: 'Task 3: Gone', label: 'Task 3', points: 1, items: [] },
  ],
  unlinked: [item('test_d.py', null, 'pass')],
};

test('a section card sits beside its heading, and tests beside their cell', () => {
  const margins = placeSuite(suite, cells, python);
  assert.deepEqual([...margins.keys()].sort(), [0, 1, 2, 3]);
  assert.equal(margins.get(0).section.id, 's1');
  assert.deepEqual(margins.get(1).items.map(i => i.id), ['test_a.py', 'test_b.py']);
  assert.deepEqual(margins.get(1).linkedBy, ['count_to']);
  assert.equal(margins.get(2).section.id, 's2');
  // A section anchor sits beside the first code cell under its heading, and
  // names nothing to link by.
  assert.deepEqual(margins.get(3).items.map(i => i.id), ['test_c.py']);
  assert.deepEqual(margins.get(3).linkedBy, []);
});

test('a test whose cell is gone, and a heading not in the notebook, place nothing', () => {
  const renamed = cells.map(c => ({ ...c, source: c.source.replace('count_to', 'count_up') }));
  const margins = placeSuite(suite, renamed, python);
  assert.equal(margins.get(1), undefined);
  assert.ok([...margins.values()].every(m => m.section?.id !== 's3'));
});

test('an issue: fails on the solution, or passes on the starter for points', () => {
  assert.equal(itemIssue(item('x', null, 'fail')), 'failsOnSolution');
  assert.equal(itemIssue(item('x', null, 'timeout')), 'failsOnSolution');
  assert.equal(itemIssue(item('x', null, 'pass', { starter: { result: 'pass' } })), 'passesOnStarter');
  assert.equal(itemIssue(item('x', null, 'pass', { starter: { result: 'pass' }, points: 0 })), null);
  assert.equal(itemIssue(item('x', null, 'pass', { starter: { result: 'fail' } })), null);
  assert.equal(issueText('failsOnSolution'), 'Fails on the solution');
  assert.match(issueText('passesOnStarter'), /earns its point with no work/);
});

test('the glyph state, the section meta and the folded strip', () => {
  assert.equal(itemState(item('x', null, 'pass')), 'pass');
  assert.equal(itemState(item('x', null, 'error')), 'fail');
  assert.equal(itemState(item('x', null, null)), 'none');
  assert.equal(sectionMeta(suite.sections[0]), '2 pts · 2 checks');
  assert.equal(sectionMeta(suite.sections[1]), '1 pt · 1 check');
  assert.deepEqual(stripSummary(suite.sections[0].items), ['2 checks · 2 pts', '1 fails on the solution']);
  assert.deepEqual(stripSummary([item('x', null, 'pass')]), ['1 check · 1 pt']);
});

test('a pin names the first name the cell defines', () => {
  assert.equal(pinName('def total(xs):\n    return 0\nGOAL = 3', python), 'total');
  assert.equal(pinName('print(1)', python), null);
});

test('a test is found in its section, or among the unlinked', () => {
  assert.equal(findItem(suite, 'test_c.py').id, 'test_c.py');
  assert.equal(findItem(suite, 'test_d.py').id, 'test_d.py');
  assert.equal(findItem(suite, 'nope'), null);
  assert.equal(sectionOf(suite, 'test_b.py').id, 's1');
  assert.equal(sectionOf(suite, 'test_d.py'), null);
});

test('a margin key changes with what the cards show, and with the selection in that cell', () => {
  const margins = placeSuite(suite, cells, python);
  const key = marginKey(margins.get(1), null);
  assert.equal(marginKey(margins.get(1), 'test_c.py'), key);
  assert.notEqual(marginKey(margins.get(1), 'test_a.py'), key);
  assert.notEqual(marginKey(margins.get(3), null), key);
});
