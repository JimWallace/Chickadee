// Unit tests for the account page's Chickadee live preview
// (Public/avatar-picker.js, docs/student-wardrobe.md).
//
// The preview may only ever write the two avatar custom properties, and only
// as var(<token>) of the token the checked radio carries — anything else would
// be a styling decision made in script.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Picker = require('../../Public/avatar-picker.js');

test('previewValues: gives both properties the checked tokens', () => {
  const tokens = { backdrop: '--avatar-back-lilac', border: '--avatar-accent-honey' };
  assert.deepEqual(Picker.previewValues(g => tokens[g]), {
    backdrop: 'var(--avatar-back-lilac)',
    border: 'var(--avatar-accent-honey)',
  });
});

test('previewValues: no border is the transparent token, passed like any other', () => {
  const tokens = { backdrop: '--avatar-back-sky', border: '--avatar-border-none' };
  assert.equal(Picker.previewValues(g => tokens[g]).border, 'var(--avatar-border-none)');
});

test('previewValues: a group with nothing checked is left alone', () => {
  assert.deepEqual(Picker.previewValues(g => (g === 'border' ? '--avatar-accent-moss' : null)), {
    backdrop: null,
    border: 'var(--avatar-accent-moss)',
  });
});

test('previewValues: a value that is not a custom-property token is never passed', () => {
  const tokens = { backdrop: 'red', border: 'url(x)' };
  assert.deepEqual(Picker.previewValues(g => tokens[g]), { backdrop: null, border: null });
});

test('attach: a change on the form sets the preview custom properties', () => {
  const checked = {
    backdrop: { getAttribute: () => '--avatar-back-peach' },
    border: { getAttribute: () => '--avatar-accent-orchid' },
  };
  let onChange = null;
  const form = {
    querySelector: sel => checked[sel.match(/name="(\w+)"/)[1]] || null,
    addEventListener: (type, fn) => { assert.equal(type, 'change'); onChange = fn; },
  };
  const written = {};
  const preview = { style: { setProperty: (name, value) => { written[name] = value; } } };

  Picker.attach(form, preview);
  assert.ok(onChange, 'no change listener attached');
  assert.deepEqual(written, {}, 'nothing may be written before a change');
  onChange();
  assert.deepEqual(written, {
    '--av-backdrop': 'var(--avatar-back-peach)',
    '--av-border': 'var(--avatar-accent-orchid)',
  });
});
