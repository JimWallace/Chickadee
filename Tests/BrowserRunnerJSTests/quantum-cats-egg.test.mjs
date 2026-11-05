// Unit tests for Public/quantum-cats-egg.js: the Konami code that opens
// Quantum Cats and grants its ring (docs/student-wardrobe.md, "Found items").
// These pin the DOM-free half: the sequence, how a key is matched, and which
// key events are ignored.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Egg = require('../../Public/quantum-cats-egg.js');

function typed(keys) {
  return keys.reduce((recent, key) => Egg.push(recent, key), []);
}

const CODE = ['ArrowUp', 'ArrowUp', 'ArrowDown', 'ArrowDown',
  'ArrowLeft', 'ArrowRight', 'ArrowLeft', 'ArrowRight', 'b', 'a'];

test('the code is the Konami code', () => {
  assert.deepEqual(Egg.SEQUENCE, CODE);
});

test('the whole code matches', () => {
  assert.equal(Egg.matches(typed(CODE)), true);
});

test('B and A match in either case', () => {
  assert.equal(Egg.matches(typed([...CODE.slice(0, 8), 'B', 'A'])), true);
});

test('keys typed before the code do not stop it', () => {
  assert.equal(Egg.matches(typed(['x', 'ArrowUp', 'Enter', ...CODE])), true);
});

test('an extra up arrow at the start still matches', () => {
  assert.equal(Egg.matches(typed(['ArrowUp', ...CODE])), true);
});

test('part of the code does not match', () => {
  assert.equal(Egg.matches(typed(CODE.slice(0, 9))), false);
});

test('a wrong key inside the code does not match', () => {
  assert.equal(Egg.matches(typed([...CODE.slice(0, 5), 'x', ...CODE.slice(5)])), false);
});

test('the recent keys are kept to the length of the code', () => {
  assert.equal(typed([...'abcdefghijklmnop']).length, CODE.length);
});

test('it grants the Quantum Cats ring and opens the game', () => {
  assert.equal(Egg.ITEM, 'border.quantumcats');
  assert.equal(Egg.FOUND_URL, '/account/wardrobe/found');
  assert.equal(Egg.GAME_URL, '/games/quantum-cats/index.html');
});

function eventOn(selectorMatch, extra = {}) {
  return Object.assign({
    ctrlKey: false, altKey: false, metaKey: false,
    target: {
      isContentEditable: false,
      closest: (selector) => (selectorMatch && selector.includes(selectorMatch) ? {} : null),
    },
  }, extra);
}

test('keys on the page itself count', () => {
  assert.equal(Egg.ignores(eventOn(null)), false);
});

test('keys typed into a field or an editor are ignored', () => {
  assert.equal(Egg.ignores(eventOn('input')), true);
  assert.equal(Egg.ignores(eventOn('.cm-editor')), true);
  assert.equal(Egg.ignores(eventOn(null, {
    target: { isContentEditable: true, closest: () => null },
  })), true);
});

test('keys held with a modifier are ignored', () => {
  assert.equal(Egg.ignores(eventOn(null, { ctrlKey: true })), true);
  assert.equal(Egg.ignores(eventOn(null, { altKey: true })), true);
  assert.equal(Egg.ignores(eventOn(null, { metaKey: true })), true);
});

test('an event with no element target counts', () => {
  assert.equal(Egg.ignores({ ctrlKey: false, altKey: false, metaKey: false, target: null }), false);
});
