// Unit tests for the result page's Earned toast (Public/earned-toast.js,
// docs/result-celebration.md, J2).
//
// Wear it points the page bird at the new item only through a same-page
// symbol or a custom-property token, and a new face gets the bird's current
// face as a second layer, so the two can crossfade.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Toast = require('../../Public/earned-toast.js');

function formWith(attributes) {
  return { getAttribute: name => (name in attributes ? attributes[name] : null) };
}

function layer(href) {
  return {
    attrs: { href },
    getAttribute(name) { return this.attrs[name] ?? null; },
    setAttribute(name, value) { this.attrs[name] = value; },
  };
}

test('wearing: passes same-page symbols and tokens, and nothing else', () => {
  assert.deepEqual(
    Toast.wearing(formWith({
      'data-wear-ring': '#av-ring-twotone', 'data-wear-token': '--avatar-ring-twotone', 'data-wear-face': '',
    })),
    { ring: '#av-ring-twotone', token: '--avatar-ring-twotone', face: null });
  assert.deepEqual(
    Toast.wearing(formWith({
      'data-wear-ring': 'https://x/#av-ring-twotone', 'data-wear-token': 'red', 'data-wear-face': '#av-ring-x',
    })),
    { ring: null, token: null, face: null });
  assert.deepEqual(
    Toast.wearing(formWith({ 'data-wear-face': '#av-expression-chirp' })),
    { ring: null, token: null, face: '#av-expression-chirp' });
});

test('wear: a ring sets the ring layer and the border token', () => {
  const ring = layer('#av-ring-none');
  const written = {};
  const bird = {
    style: { setProperty: (name, value) => { written[name] = value; } },
    querySelector: sel => (sel === 'use[data-av-ring]' ? ring : null),
  };
  Toast.wear(bird, { ring: '#av-ring-twotone', token: '--avatar-ring-twotone', face: null });
  assert.equal(ring.attrs.href, '#av-ring-twotone');
  assert.deepEqual(written, { '--av-border': 'var(--avatar-ring-twotone)' });
});

test('wear: a face sets the face layer and writes no style', () => {
  const face = layer('#av-expression-bright');
  const written = {};
  const bird = {
    style: { setProperty: (name, value) => { written[name] = value; } },
    querySelector: sel => (sel === 'use[href^="#av-expression-"]' ? face : null),
  };
  Toast.wear(bird, { ring: null, token: null, face: '#av-expression-chirp' });
  assert.equal(face.attrs.href, '#av-expression-chirp');
  assert.deepEqual(written, {});
});

test('crossfade: adds the old face over the new one and marks both', () => {
  const inserted = [];
  const face = layer('#av-expression-chirp');
  face.cloneNode = () => layer(face.attrs.href);
  face.parentNode = { insertBefore: (node, before) => inserted.push({ node, before }) };
  face.nextSibling = 'next';
  const bird = { querySelector: () => face };

  const old = Toast.crossfade(bird, '#av-expression-bright');
  assert.equal(old.attrs.href, '#av-expression-bright');
  assert.equal(old.attrs.class, 'earned-face-old');
  assert.equal(face.attrs.class, 'earned-face-new');
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0].before, 'next');
});

test('crossfade: nothing to fade from the same face or a foreign reference', () => {
  const face = layer('#av-expression-chirp');
  const bird = { querySelector: () => face };
  assert.equal(Toast.crossfade(bird, '#av-expression-chirp'), null);
  assert.equal(Toast.crossfade(bird, 'https://x/#av-expression-bright'), null);
  assert.equal(Toast.crossfade(bird, null), null);
  assert.equal(face.attrs.class, undefined);
});
