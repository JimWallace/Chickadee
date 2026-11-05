// Unit tests for ChickadeeSparkline.setWindow (Public/sparkline.js).
//
// A cyclable diagnostic card is a button named by its content. Its window chip
// ("24h") is hidden from assistive technology, and a visually hidden
// `.js-window-spoken` beside it says the window in words, from the
// `data-phrase-<chip>` attributes the server renders on it. When a script
// cycles the window, the chip and the phrase must change together, or a screen
// reader names one window while the card shows another.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/sparkline.js'), 'utf8');

function load() {
  const sandbox = { Array, Math, String, module: { exports: {} } };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

const Spark = load();

function fakeCard({ withSpoken = true } = {}) {
  const chip = { textContent: '24h' };
  // The attributes DiagnosticWindowSpoken renders: the words live on the
  // server, and setWindow only looks them up.
  const phrases = {
    'data-phrase-24h': 'last 24 hours',
    'data-phrase-7d': 'last 7 days',
    'data-phrase-30d': 'last 30 days',
  };
  const spoken = {
    textContent: 'last 24 hours',
    getAttribute: (name) => (name in phrases ? phrases[name] : null),
  };
  return {
    chip,
    spoken,
    querySelector(selector) {
      if (selector === '.diagnostic-window-chip') return chip;
      if (selector === '.js-window-spoken') return withSpoken ? spoken : null;
      return null;
    },
  };
}

test('setWindow changes the chip and the spoken phrase together', () => {
  const card = fakeCard();
  Spark.setWindow(card, '7d');
  assert.equal(card.chip.textContent, '7d');
  assert.equal(card.spoken.textContent, 'last 7 days');
  Spark.setWindow(card, '30d');
  assert.equal(card.chip.textContent, '30d');
  assert.equal(card.spoken.textContent, 'last 30 days');
  Spark.setWindow(card, '24h');
  assert.equal(card.spoken.textContent, 'last 24 hours');
});

test('an unknown window is spoken as its chip text, not dropped', () => {
  const card = fakeCard();
  Spark.setWindow(card, '90d');
  assert.equal(card.chip.textContent, '90d');
  assert.equal(card.spoken.textContent, '90d');
});

test('a card without a spoken phrase still gets its chip, and no card is a no-op', () => {
  const card = fakeCard({ withSpoken: false });
  Spark.setWindow(card, '7d');
  assert.equal(card.chip.textContent, '7d');
  assert.doesNotThrow(() => Spark.setWindow(null, '7d'));
});
