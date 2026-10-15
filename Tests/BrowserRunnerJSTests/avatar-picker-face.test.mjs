// Unit tests for the face half of the account page's bird live preview
// (Public/avatar-picker.js, #2588).
//
// A face radio carries the expression symbol it draws. The preview may point
// the face layer only at a same-page expression symbol, and writes no style:
// the colours come with the bird and do not change in the picker.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Picker = require('../../Public/avatar-picker.js');

test('previewFace: passes a same-page expression reference, and nothing else', () => {
  assert.equal(Picker.previewFace(() => '#av-expression-sleepy'), '#av-expression-sleepy');
  assert.equal(Picker.previewFace(() => null), null);
  assert.equal(Picker.previewFace(() => '#av-ring-rainbow'), null);
  assert.equal(Picker.previewFace(() => 'https://x/#av-expression-sleepy'), null);
});

test('attach: a face choice repoints the face layer and writes no style', () => {
  const input = { getAttribute: name => (name === 'data-av-expression' ? '#av-expression-keen' : null) };
  let onChange = null;
  const formWritten = {};
  const form = {
    querySelector: sel => (sel.includes('name="expression"') ? input : null),
    addEventListener: (_type, fn) => { onChange = fn; },
    style: { setProperty: (name, value) => { formWritten[name] = value; } },
  };
  const face = { href: '#av-expression-wink', setAttribute(n, v) { this[n] = v; } };
  const written = {};
  const preview = {
    style: { setProperty: (name, value) => { written[name] = value; } },
    querySelector: sel => (sel === 'use[href^="#av-expression-"]' ? face : null),
  };

  Picker.attach(form, preview);
  onChange();
  assert.equal(face.href, '#av-expression-keen');
  assert.deepEqual(written, {});
  assert.deepEqual(formWritten, {});
});
