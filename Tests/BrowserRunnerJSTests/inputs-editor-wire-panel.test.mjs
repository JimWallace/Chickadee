// ChickadeeInputsCore.wirePanel and syncCueNote (#2721): the panel wiring
// that the Global Inputs and the section inputs editors used to write twice.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/authoring-language.js');
const Core = require('../../Public/inputs-editor-core.js');

const CLASSES = { row: 'js-x-row', remove: 'js-x-remove' };

/// A panel with a tbody of `rows` rows and a cue note, a stub editor and a
/// stub saver that count their calls.
function panel({ rows = 1, inside = true } = {}) {
  const calls = { refresh: 0, schedule: 0 };
  const handlers = {};
  const note = { hidden: null };
  const tbody = { rows, querySelector: (sel) => (sel === 'tr' && tbody.rows > 0 ? {} : null) };
  const root = {
    querySelector: (sel) => (sel === '.js-value-cue-note' ? note : null),
    addEventListener: (type, fn) => { (handlers[type] ||= []).push(fn); },
    contains: () => inside,
  };
  const editor = { refreshAllRows: (t) => { assert.equal(t, tbody); calls.refresh += 1; } };
  const saver = { schedule: () => { calls.schedule += 1; } };
  Core.wirePanel(root, tbody, CLASSES, editor, saver);
  const fire = (type, event) => (handlers[type] || []).forEach((fn) => fn(event));
  return { calls, handlers, note, tbody, fire };
}

test('wirePanel refreshes the rows once and shows the cue note while a row exists', () => {
  const withRow = panel({ rows: 1 });
  assert.equal(withRow.calls.refresh, 1);
  assert.equal(withRow.note.hidden, false);
  assert.equal(panel({ rows: 0 }).note.hidden, true);
});

test('an edit in a row refreshes and schedules a save; an edit elsewhere does not', () => {
  const p = panel();
  p.fire('input', { target: { closest: (sel) => (sel === 'tr.js-x-row' ? {} : null) } });
  assert.deepEqual({ ...p.calls }, { refresh: 2, schedule: 1 });
  p.fire('input', { target: { closest: () => null } });
  assert.deepEqual({ ...p.calls }, { refresh: 2, schedule: 1 });
});

test('the remove button drops its row, saves, and hides the note when no row is left', () => {
  const p = panel({ rows: 1 });
  const tr = { remove: () => { p.tbody.rows -= 1; } };
  const btn = { closest: (sel) => (sel === 'tr.js-x-row' ? tr : null) };
  p.fire('click', { target: { closest: (sel) => (sel === '.js-x-remove' ? btn : null) } });
  assert.equal(p.tbody.rows, 0);
  assert.deepEqual({ ...p.calls }, { refresh: 2, schedule: 1 });
  assert.equal(p.note.hidden, true);
});

test('a remove button outside the panel is not this panel\'s', () => {
  const p = panel({ inside: false });
  const tr = { remove: () => assert.fail('removed a row of another panel') };
  const btn = { closest: () => tr };
  p.fire('click', { target: { closest: () => btn } });
  assert.deepEqual({ ...p.calls }, { refresh: 1, schedule: 0 });
});

test('syncCueNote does nothing on a panel with no note', () => {
  const root = { querySelector: () => null };
  assert.doesNotThrow(() => Core.syncCueNote(root, { querySelector: () => null }));
});
