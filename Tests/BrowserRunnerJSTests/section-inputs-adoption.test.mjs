// Guards the create page's adoption of the shared inputs modules.
//
// Until v0.5.x, Resources/Views/assignment-new.leaf carried its own
// pre-v0.4.160 inline copy of the section-inputs editor. That copy's value
// parser had no `=` branch, so a per-student expression typed into a section
// input on the Create Assignment page was classified as a bare string and
// persisted as the literal text "= seed % 26" — and its payload omitted the
// `expressions` key entirely, which the draft endpoint coalesces to []. The
// same keystrokes on the edit page created a real expression.
//
// These assertions fail against the pre-adoption template.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/inputs-editor-core.js');

// Both authoring surfaces must reach section inputs through the same modules.
const SECTION_INPUT_PAGES = [
  'Resources/Views/assignment-new.leaf',
  'Resources/Views/_assignment-edit-body.leaf',
];

test('both authoring pages load the shared inputs modules', async () => {
  for (const rel of SECTION_INPUT_PAGES) {
    const src = await fs.readFile(path.resolve(rel), 'utf8');
    assert.ok(
      src.includes('/inputs-editor-core.js'),
      `${rel} must load inputs-editor-core.js`,
    );
    assert.ok(
      src.includes('/section-inputs-editor.js'),
      `${rel} must load section-inputs-editor.js`,
    );
  }
});

test('neither authoring page re-declares the inline value parser', async () => {
  for (const rel of SECTION_INPUT_PAGES) {
    const src = await fs.readFile(path.resolve(rel), 'utf8');
    // `tryParseValue` was the inline classifier's name; `buildPayload` and
    // `wireAutoSave` were the rest of the fork. Any of them reappearing means
    // the page has stopped sharing the core.
    for (const symbol of ['tryParseValue', 'buildPayload', 'wireAutoSave']) {
      assert.ok(
        !new RegExp(`function\\s+${symbol}\\s*\\(`).test(src),
        `${rel} re-declares ${symbol} inline; use ChickadeeInputsCore instead`,
      );
    }
  }
});

test('the shared core classifies a section expression as an expression', () => {
  // This is the exact input the inline copy mishandled. The old parser
  // returned { ok: true, value: '= seed % 26', strict: false } — a string.
  assert.deepEqual(
    Core.classifyValue('= seed % 26'),
    { kind: 'expression', expression: 'seed % 26' },
  );
});

test('a mixed literal/expression panel builds a payload carrying both keys', () => {
  const editor = Core.createEditor({
    row: 'section-var-row',
    name: 'section-var-name',
    value: 'section-var-value',
    valid: 'section-var-row-valid',
    remove: 'section-var-remove',
  });

  // Minimal stand-in for the rows the panel reads; only the two input
  // lookups and the row list are exercised by buildPayload.
  const rows = [
    { name: 'max_bmi', value: '30' },
    { name: 'shift', value: '= seed % 26' },
  ];
  const tbody = {
    querySelectorAll: () => rows.map((r) => ({
      querySelector: (sel) => ({
        value: sel.includes('name') ? r.name : r.value,
      }),
    })),
  };

  const payload = editor.buildPayload(tbody);
  assert.ok(payload, 'a valid panel should build a payload');
  assert.deepEqual(payload.variables, [{ name: 'max_bmi', value: 30 }]);
  assert.deepEqual(payload.expressions, [{ name: 'shift', expression: 'seed % 26' }]);
});
