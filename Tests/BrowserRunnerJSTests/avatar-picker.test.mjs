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

test('previewRing: passes a ring symbol reference and nothing else', () => {
  assert.equal(Picker.previewRing(() => '#av-ring-rainbow'), '#av-ring-rainbow');
  assert.equal(Picker.previewRing(() => null), null);
  assert.equal(Picker.previewRing(() => ''), null);
  assert.equal(Picker.previewRing(() => '#av-wing-plain'), null);
  assert.equal(Picker.previewRing(() => 'https://example.com/x.svg#a'), null);
});

test('attach: a ring choice points the preview ring layer at the checked ring', () => {
  const attrs = {
    'data-av-token': '--avatar-border-none',
    'data-av-ring': '#av-ring-rainbow',
  };
  const border = { getAttribute: name => attrs[name] };
  let onChange = null;
  const form = {
    querySelector: sel => (sel.includes('name="border"') ? border : null),
    addEventListener: (_type, fn) => { onChange = fn; },
  };
  const layer = { href: '#av-ring-none', setAttribute(name, value) { this[name] = value; } };
  const written = {};
  const preview = {
    style: { setProperty: (name, value) => { written[name] = value; } },
    querySelector: sel => (sel === 'use[data-av-ring]' ? layer : null),
  };

  Picker.attach(form, preview);
  onChange();
  assert.equal(layer.href, '#av-ring-rainbow');
  assert.deepEqual(written, { '--av-border': 'var(--avatar-border-none)' });
});

test('attach: a backdrop choice also goes on the form, so the ring samples follow it', () => {
  const backdrop = { getAttribute: () => '--avatar-back-rose' };
  let onChange = null;
  const formWritten = {};
  const form = {
    querySelector: sel => (sel.includes('name="backdrop"') ? backdrop : null),
    addEventListener: (_type, fn) => { onChange = fn; },
    style: { setProperty: (name, value) => { formWritten[name] = value; } },
  };
  const preview = { style: { setProperty: () => {} } };

  Picker.attach(form, preview);
  onChange();
  assert.deepEqual(formWritten, { '--av-backdrop': 'var(--avatar-back-rose)' });
});
