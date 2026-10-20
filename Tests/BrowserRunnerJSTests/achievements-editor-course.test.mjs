// Unit tests for the course condition rules in
// Public/achievements-editor-core.js (docs/achievement-rewards.md, S4): how a
// course condition's target and extra field serialise, and how the table
// phrases it.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/achievements-editor-core.js');

function option(value, text, data) {
  return { value, text, getAttribute: (name) => (data && name in data ? data[name] : null) };
}

const OPTIONS = [
  option('assignmentsGraded', 'Assignments graded', { 'data-course-field': '' }),
  option('assignmentsAtGrade', 'Assignments at grade', { 'data-course-field': 'gradeFloor' }),
  option('achievementsEarned', 'Achievements earned', { 'data-course-field': 'achievementRef' }),
];
const META = Core.signalMetaFromOptions(OPTIONS);
const FIELDS = Core.signalCourseFieldsFromOptions(OPTIONS);
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const LABELS = { 'courseSection:S1': 'Unit 2', 'concept:loops': 'Loops', 'assignments:': 'Chosen assignments' };
const ctx = {
  signalMeta: META, sectionNames: {}, esc, dimLabel: (d) => d,
  targetLabel: (c) => Core.courseTargetLabel(c, LABELS),
};

test('the course field of each signal is read off data-course-field', () => {
  assert.deepEqual(FIELDS, {
    assignmentsGraded: '', assignmentsAtGrade: 'gradeFloor', achievementsEarned: 'achievementRef',
  });
});

test('a stored target maps to the select value and back', () => {
  assert.equal(Core.courseTargetValue(null), '');
  assert.equal(Core.courseTargetValue({ signal: 'x' }), '');
  assert.equal(Core.courseTargetValue({ targetKind: 'courseSection', targetRef: 'S1' }), 'courseSection:S1');
  assert.equal(Core.courseTargetValue({ targetKind: 'assignments', targetRef: 'A,B' }), 'assignments:');
  assert.deepEqual(Core.pickedAssignments({ targetKind: 'assignments', targetRef: ' A, ,B' }), ['A', 'B']);
  assert.deepEqual(Core.pickedAssignments({ targetKind: 'concept', targetRef: 'loops' }), []);
});

test('a course condition carries its target and only its own extra field', () => {
  const base = () => ({ signal: 'assignmentsAtGrade', comparator: 'atLeast', value: 2 });
  assert.deepEqual(
    Core.withCourseFields(base(), { target: 'concept:loops', floor: '80', achievementRef: 'x' }, 'gradeFloor'),
    { signal: 'assignmentsAtGrade', comparator: 'atLeast', value: 2, targetKind: 'concept', targetRef: 'loops',
      gradeFloor: 80 });
  assert.deepEqual(
    Core.withCourseFields(base(), { target: 'assignments:', picked: ['A', 'B'] }, ''),
    { signal: 'assignmentsAtGrade', comparator: 'atLeast', value: 2, targetKind: 'assignments', targetRef: 'A,B' });
  assert.deepEqual(Core.withCourseFields(base(), { target: '', achievementRef: ' ' }, 'achievementRef'), base());
  assert.equal(
    Core.withCourseFields(base(), { achievementRef: ' ace ' }, 'achievementRef').achievementRef, 'ace');
});

test('the table phrases a course condition with its floor, its id and its set', () => {
  assert.equal(
    Core.condPhrase({ signal: 'assignmentsAtGrade', comparator: 'atLeast', value: 2, gradeFloor: 80,
      targetKind: 'courseSection', targetRef: 'S1' }, ctx),
    'Assignments at grade ≥ 2 at 80% in “Unit 2”');
  assert.equal(
    Core.condPhrase({ signal: 'achievementsEarned', comparator: 'atLeast', value: 1, achievementRef: 'ace',
      targetKind: 'assignments', targetRef: 'A' }, ctx),
    'Achievements earned ≥ 1 (“ace”) in “1 chosen assignment”');
  assert.equal(
    Core.condPhrase({ signal: 'assignmentsGraded', comparator: 'atLeast', value: 3 }, ctx),
    'Assignments graded ≥ 3');
});

test('a target whose section is gone never shows its id', () => {
  assert.equal(Core.courseTargetLabel({ targetKind: 'courseSection', targetRef: 'GONE' }, LABELS), Core.DELETED_SECTION);
  assert.equal(Core.courseTargetLabel({ targetKind: 'courseSection', targetRef: 'S1' }, LABELS), 'Unit 2');
});

test('the table names an achievement by its name when the page knows it', () => {
  const named = { ...ctx, achievementName: (id) => (id === 'ace' ? 'Ace' : id) };
  assert.equal(
    Core.condPhrase({ signal: 'achievementsEarned', comparator: 'atLeast', value: 1, achievementRef: 'ace' }, named),
    'Achievements earned ≥ 1 (“Ace”)');
});
