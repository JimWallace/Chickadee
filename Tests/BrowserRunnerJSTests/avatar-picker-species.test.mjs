// Unit tests for the species half of the account page's bird live preview
// (Public/avatar-picker.js, docs/avatar-species.md, A2).
//
// A colourway radio carries six tone tokens and two layer references. The
// preview may write only the six tone properties, as var(<token>), and point
// the plumage and tuft layers only at same-page plumage, tuft or crest
// symbols. Anything else would be a styling decision made in script.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Picker = require('../../Public/avatar-picker.js');

const robin = {
  cap: '--avatar-copper-cap', wing: '--avatar-copper-wing', body: '--avatar-copper-body',
  bib: '--avatar-copper-bib', beak: '--avatar-copper-beak', mark: '--avatar-copper-mark',
  plumage: '#av-plumage-robin', tuft: '#av-tuft-none',
};

test('previewTones: gives every tone the checked colourway token', () => {
  assert.deepEqual(Picker.previewTones(name => robin[name]), {
    cap: 'var(--avatar-copper-cap)', wing: 'var(--avatar-copper-wing)',
    body: 'var(--avatar-copper-body)', bib: 'var(--avatar-copper-bib)',
    beak: 'var(--avatar-copper-beak)', mark: 'var(--avatar-copper-mark)',
  });
});

test('previewTones: nothing checked leaves every tone alone', () => {
  const tones = Picker.previewTones(() => null);
  assert.deepEqual(Object.values(tones), [null, null, null, null, null, null]);
});

test('previewTones: a value that is not a custom-property token is never passed', () => {
  const tones = Picker.previewTones(name => (name === 'cap' ? 'red' : robin[name]));
  assert.equal(tones.cap, null);
  assert.equal(tones.wing, 'var(--avatar-copper-wing)');
});

test('previewLayers: passes a plumage and a tuft or crest reference, and nothing else', () => {
  assert.deepEqual(Picker.previewLayers(name => robin[name]),
    { plumage: '#av-plumage-robin', tuft: '#av-tuft-none' });
  assert.deepEqual(Picker.previewLayers(name => ({ plumage: '#av-plumage-cardinal', tuft: '#av-crest-cardinal' })[name]),
    { plumage: '#av-plumage-cardinal', tuft: '#av-crest-cardinal' });
  assert.deepEqual(Picker.previewLayers(() => null), { plumage: null, tuft: null });
  assert.deepEqual(Picker.previewLayers(name => ({ plumage: '#av-ring-rainbow', tuft: 'https://x/#av-tuft-crest' })[name]),
    { plumage: null, tuft: null });
});

test('attach: a colourway choice sets the six tones and repoints the plumage and tuft layers', () => {
  const input = { getAttribute: name => robin[name.replace('data-av-', '')] };
  let onChange = null;
  const formWritten = {};
  const form = {
    querySelector: sel => (sel.includes('name="cap"') ? input : null),
    addEventListener: (_type, fn) => { onChange = fn; },
    style: { setProperty: (name, value) => { formWritten[name] = value; } },
  };
  const layers = {
    'use[href^="#av-plumage-"]': { href: '#av-plumage-chickadee', setAttribute(n, v) { this[n] = v; } },
    'use[href^="#av-tuft-"], use[href^="#av-crest-"]': { href: '#av-tuft-swoop', setAttribute(n, v) { this[n] = v; } },
  };
  const written = {};
  const preview = {
    style: { setProperty: (name, value) => { written[name] = value; } },
    querySelector: sel => layers[sel] || null,
  };

  Picker.attach(form, preview);
  onChange();
  assert.deepEqual(written, {
    '--av-cap': 'var(--avatar-copper-cap)', '--av-wing': 'var(--avatar-copper-wing)',
    '--av-body': 'var(--avatar-copper-body)', '--av-bib': 'var(--avatar-copper-bib)',
    '--av-beak': 'var(--avatar-copper-beak)', '--av-mark': 'var(--avatar-copper-mark)',
  });
  assert.equal(layers['use[href^="#av-plumage-"]'].href, '#av-plumage-robin');
  assert.equal(layers['use[href^="#av-tuft-"], use[href^="#av-crest-"]'].href, '#av-tuft-none');
  // The two-tone ring sample draws the cap colour, so the form follows too.
  assert.deepEqual(formWritten, { '--av-cap': 'var(--avatar-copper-cap)' });
});
