// Unit tests for suite-table.js's pure upload-classification helpers
// (folded in from the retired suite-list.js, #1126) and for the shared
// chickadee-ui.js fetch-error extractor those editors now route through.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const SuiteTable = require('../../Public/suite-table.js');
const ChickadeeUI = require('../../Public/chickadee-ui.js');

function fakeFile(name, content) {
  return {
    name,
    size: Buffer.byteLength(content),
    text: () => Promise.resolve(content),
  };
}

test('classifies extensionless shell shebang files as scripts', async () => {
  const sh = await SuiteTable.classifyFile(fakeFile('check_submission', '#!/bin/sh\necho ok\n'));
  const bash = await SuiteTable.classifyFile(fakeFile('run_public', '#!/usr/bin/env bash\necho ok\n'));

  assert.equal(sh.isScript, true);
  assert.equal(sh.tier, 'public');
  assert.deepEqual(sh.errors, []);
  assert.equal(bash.isScript, true);
  assert.equal(bash.tier, 'public');
  assert.deepEqual(bash.errors, []);
});

test('classifies extensionless python shebang files as scripts', async () => {
  const result = await SuiteTable.classifyFile(fakeFile(
    'BMI Boundary Cases',
    '#!/usr/bin/env python3\n\nprint("ok")\n',
  ));

  assert.equal(result.isScript, true);
  assert.equal(result.tier, 'public');
  assert.deepEqual(result.errors, []);
});

test('classifies extensionless files without shebang as support with a clear warning', async () => {
  const result = await SuiteTable.classifyFile(fakeFile('notes', 'echo not necessarily runnable\n'));

  assert.equal(result.isScript, false);
  assert.equal(result.tier, 'support');
  assert.deepEqual(result.errors, [
    'No extension or recognized shebang; this file will be included as support unless marked as a test',
  ]);
});

test('classifies by extension without reading content, flags binaries and empties', async () => {
  const py = await SuiteTable.classifyFile({ name: 'test_a.py', size: 10 });
  assert.equal(py.isScript, true);
  assert.equal(py.tier, 'public');

  const zip = SuiteTable.classify('data.zip', '', 10);
  assert.equal(zip.isScript, false);
  assert.equal(zip.tier, 'support');
  assert.ok(zip.errors.some((e) => e.includes('Binary file')));

  const empty = SuiteTable.classify('test_b.py', '', 0);
  assert.ok(empty.errors.includes('Empty file'));
});

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
