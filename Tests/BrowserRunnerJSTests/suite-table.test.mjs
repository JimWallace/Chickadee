// Unit tests for the shared chickadee-ui.js fetch-error extractor that the
// suite editors route through. suite-table.js's own pure helpers are tested
// in suite-visual-order.test.mjs and suite-drop-zone.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ChickadeeUI = require('../../Public/chickadee-ui.js');

// The shared extractor replaced two divergent per-file copies: one parsed
// JSON error bodies, the other scraped the Leaf error page. It must handle
// both shapes (and degrade to truncated raw text).
test('extractErrorMessage handles JSON, error-page HTML, and raw text', () => {
  const { extractErrorMessage } = ChickadeeUI;

  assert.equal(extractErrorMessage('{"reason":"points must be positive"}'), 'points must be positive');
  assert.equal(extractErrorMessage('{"error":"nope"}'), 'nope');
  assert.equal(
    extractErrorMessage('<html><p class="error-message">Bad &amp; broken &#39;dep&#39;</p></html>'),
    "Bad & broken 'dep'",
  );
  assert.equal(extractErrorMessage('plain failure'), 'plain failure');
  assert.equal(extractErrorMessage(''), '');
  const long = 'x'.repeat(300);
  assert.equal(extractErrorMessage(long).length, 201); // 200 chars + ellipsis
});

// CodeQL hardening (#1132 review): tag stripping runs to a fixpoint and
// entity decoding is single-level with &amp; handled last.
test('extractErrorMessage strips nested tags and never double-unescapes', () => {
  const { extractErrorMessage } = ChickadeeUI;

  const nested = extractErrorMessage('<p class="error-message">bad <scr<script>ipt>payload</p>');
  assert.ok(!nested.includes('<'), 'no tag-opening character may survive: ' + nested);
  assert.equal(nested, 'bad ipt>payload');
  // "&amp;lt;" is the ESCAPED text "&lt;" — one decode level, not "<".
  assert.equal(
    extractErrorMessage('<p class="error-message">use &amp;lt; carefully</p>'),
    'use &lt; carefully',
  );
});
