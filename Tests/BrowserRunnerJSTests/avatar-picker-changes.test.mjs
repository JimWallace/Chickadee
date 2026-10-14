// Unit tests for the Save and "Undo changes" state of the account page's bird
// card (Public/avatar-picker.js, trackChanges).
//
// Save starts disabled and Undo hidden. A change enables Save and shows Undo.
// A reset hides Undo, disables Save and sends one change event, so the live
// preview redraws from the restored choices.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Picker = require('../../Public/avatar-picker.js');

function fakeForm() {
  const save = { disabled: false };
  const undo = { hidden: true };
  const listeners = {};
  const dispatched = [];
  const form = {
    querySelector: sel => (sel === 'button[type="submit"]' ? save : sel === 'button[type="reset"]' ? undo : null),
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    dispatchEvent: event => {
      dispatched.push(event.type);
      (listeners[event.type] || []).forEach(fn => fn(event));
    },
  };
  return { form, save, undo, listeners, dispatched };
}

test('trackChanges: Save starts disabled and Undo hidden', () => {
  const { form, save, undo } = fakeForm();
  Picker.trackChanges(form);
  assert.equal(save.disabled, true);
  assert.equal(undo.hidden, true);
});

test('trackChanges: a change enables Save and shows Undo', () => {
  const { form, save, undo, listeners } = fakeForm();
  Picker.trackChanges(form);
  listeners.change.forEach(fn => fn({ type: 'change' }));
  assert.equal(save.disabled, false);
  assert.equal(undo.hidden, false);
});

test('trackChanges: a reset redraws the preview and returns to the saved state', async () => {
  const { form, save, undo, listeners, dispatched } = fakeForm();
  Picker.trackChanges(form);
  listeners.change.forEach(fn => fn({ type: 'change' }));
  listeners.reset.forEach(fn => fn({ type: 'reset' }));
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.deepEqual(dispatched, ['change']);
  assert.equal(save.disabled, true);
  assert.equal(undo.hidden, true);
});

test('trackChanges: a form with no buttons is left alone', () => {
  const form = { querySelector: () => null, addEventListener: () => {} };
  assert.doesNotThrow(() => Picker.trackChanges(form));
});
