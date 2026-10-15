// Unit tests for the account page's click-to-chirp (Public/bird-chirp.js,
// #2589). A click points the face layer at the chirp face, a scheduled step
// points it back at the worn face, and a click during a chirp does nothing.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Chirp = require('../../Public/bird-chirp.js');

function makeHero(href) {
  const face = { href, getAttribute() { return this.href; }, setAttribute(n, v) { this[n] = v; } };
  let onClick = null;
  const bird = {
    querySelector: sel => (sel === 'use[href^="#av-expression-"]' ? face : null),
    addEventListener: (type, fn) => { if (type === 'click') onClick = fn; },
  };
  const hero = { querySelector: sel => (sel === '.avatar' ? bird : null) };
  return { hero, face, click: () => onClick() };
}

test('attach: a click chirps, then the worn face comes back', () => {
  const { hero, face, click } = makeHero('#av-expression-sleepy');
  const pending = [];
  assert.equal(Chirp.attach(hero, (fn, ms) => pending.push({ fn, ms })), true);

  click();
  assert.equal(face.href, Chirp.CHIRP);
  assert.equal(pending.length, 1);
  assert.ok(pending[0].ms > 0);

  pending[0].fn();
  assert.equal(face.href, '#av-expression-sleepy');
});

test('attach: a click during a chirp does nothing', () => {
  const { hero, face, click } = makeHero('#av-expression-keen');
  const pending = [];
  Chirp.attach(hero, (fn, ms) => pending.push({ fn, ms }));

  click();
  click();
  assert.equal(pending.length, 1, 'a second return was scheduled');
  pending[0].fn();
  assert.equal(face.href, '#av-expression-keen');

  click();
  assert.equal(face.href, Chirp.CHIRP, 'the bird does not chirp again after the first ends');
});

test('attach: a hero with no bird is not wired', () => {
  assert.equal(Chirp.attach({ querySelector: () => null }, () => {}), false);
});
