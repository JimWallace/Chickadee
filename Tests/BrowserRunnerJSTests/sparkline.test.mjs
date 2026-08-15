// Unit tests for Public/sparkline.js — the dashboard sparkline renderer,
// split out of chickadee-ui.js.
//
// It had no tests inside the junk drawer either. What it gets wrong quietly is
// the difference between "no data" and "zero": both draw a short bar, and if
// the empty-slot styling stops being applied, an admin reads a dashboard where
// a runner that reported zero jobs looks the same as one that reported nothing
// at all.
//
// The last test here is the one that exists for a structural reason rather than
// a behavioural one. This file assigns to `innerHTML`, so it owns its own
// escape rather than borrowing ChickadeeUI's through a global — a sink whose
// sanitizer lives in another file is one whose safety depends on load order,
// and the first draft of this extraction proved it by degrading to a
// non-escaping fallback when that global was absent. Owning the escape means a
// second copy of a function the June 2026 audit deduplicated, so the copy is
// pinned against the original character for character.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/sparkline.js'), 'utf8');

function load() {
  const sandbox = { Array, Math, String, module: { exports: {} } };
  sandbox.ChickadeeUI = {
    escapeHtml: (s) => String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;'),
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

const Spark = load();

function draw(series, labels, format, opts) {
  const container = { innerHTML: '' };
  Spark.render(container, series, labels, format, opts);
  return container.innerHTML;
}

function heights(html) {
  return [...html.matchAll(/--bar-h:([\d.]+)%/g)].map((m) => Number(m[1]));
}

test('bars are scaled against the series maximum', () => {
  const html = draw([5, 10, 0], ['a', 'b', 'c'], String);
  assert.deepEqual(heights(html), [50, 100, 0]);
});

test('an all-zero series draws flat rather than dividing by zero', () => {
  assert.deepEqual(heights(draw([0, 0], ['a', 'b'], String)), [0, 0]);
});

// "no data" and "zero" must not look alike on a dashboard.
test('a null value is an empty slot; a zero is a real bar unless asked otherwise', () => {
  const withNull = draw([null, 4], ['a', 'b'], String);
  assert.equal((withNull.match(/spark-fill-empty/g) || []).length, 1);

  const withZero = draw([0, 4], ['a', 'b'], String);
  assert.equal(withZero.includes('spark-fill-empty'), false);

  const zeroIsEmpty = draw([0, 4], ['a', 'b'], String, { zeroIsEmpty: true });
  assert.equal((zeroIsEmpty.match(/spark-fill-empty/g) || []).length, 1);
});

test('floorPct lifts a populated bucket above the sliver threshold', () => {
  // 1 against a max of 1000 is 0.1% — visually indistinguishable from empty.
  assert.deepEqual(heights(draw([1, 1000], ['a', 'b'], String, { floorPct: 8 })), [8, 100]);
  // It must not promote a genuinely empty bucket.
  assert.deepEqual(heights(draw([0, 1000], ['a', 'b'], String, { floorPct: 8 })), [0, 100]);
});

test('the tooltip is label + formatted value, and says "no data" for a null', () => {
  const html = draw([12, null], ['09:00', '10:00'], (v) => v + ' ms');
  assert.ok(html.includes('title="09:00: 12 ms"'));
  assert.ok(html.includes('title="10:00: no data"'));
});

// Labels come from a server payload; they reach an attribute, so they are
// escaped rather than concatenated raw.
test('a label with markup in it is escaped into the title attribute', () => {
  const html = draw([1], ['" onmouseover="x()'], String);
  assert.ok(!html.includes('onmouseover="x()'), `unescaped label: ${html}`);
  assert.ok(html.includes('&quot;'));
});

test('missing labels and a missing formatter degrade rather than throw', () => {
  const html = draw([1, 2], [], undefined);
  assert.ok(html.includes('title=": 1"'));
  assert.equal(heights(html).length, 2);
});

test('a non-array series renders nothing, and a missing container is a no-op', () => {
  assert.equal(draw(null, [], String), '');
  Spark.render(null, [1], [], String);   // must not throw
});

// The bar height is a per-datum value — it comes from the row being drawn —
// which is why it is allowed to be an inline custom property at all
// (check-styles.sh 4c). If this ever became a class or a fixed style, the
// guard's rationale would need revisiting.
test('the height rides the --bar-h custom property', () => {
  const html = draw([3, 6], ['a', 'b'], String);
  assert.ok(html.includes('style="--bar-h:50.0%"'));
  assert.ok(html.includes('style="--bar-h:100.0%"'));
});

// ── The escape copy ─────────────────────────────────────────────────────────

test('the local escape agrees with ChickadeeUI.escapeHtml, character for character', async () => {
  const uiSource = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');
  const uiSandbox = {
    document: { querySelector: () => null, addEventListener() {}, body: { addEventListener() {} } },
    Promise, JSON, Object, Error, Array, String, setTimeout,
  };
  uiSandbox.window = uiSandbox;
  uiSandbox.self = uiSandbox;
  vm.createContext(uiSandbox);
  vm.runInContext(uiSource, uiSandbox);
  const canonical = uiSandbox.ChickadeeUI.escapeHtml;

  const Spark = load();
  // Every character the two could disagree on, plus the null-ish inputs and an
  // already-escaped entity (which must double-escape, not pass through).
  //
  // Non-empty strings only: a falsy label is replaced with '' by the renderer
  // before the escape ever sees it, so including one would compare the
  // renderer's own defaulting rather than the escaping. Which CHARACTERS get
  // escaped is the thing that can drift, and every one of them is here.
  const corpus = ['&', '<', '>', '"', "'", '&amp;', '&lt;script&gt;', '<img src=x onerror=1>',
    "O'Brien & <b>co</b>", ' ', 'plain', '0', 'ünïcode', '&&<<>>""\'\''];

  for (const input of corpus) {
    // The renderer escapes into the title attribute, which is where the copy is
    // actually used — so compare through the real sink rather than reaching for
    // a private function.
    const box = { innerHTML: '' };
    Spark.render(box, [1], [input], (v) => String(v));
    const rendered = /title="([^]*?)"><span/.exec(box.innerHTML)[1];
    assert.equal(rendered, canonical(input) + ': ' + canonical('1'),
      `escaping drifted for ${JSON.stringify(input)}`);
  }
});
