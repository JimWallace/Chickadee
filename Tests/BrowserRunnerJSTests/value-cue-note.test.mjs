// The amber cue on an input value (#1996). Every value editor includes one
// note partial that links the explanation in docs/inputs.md, and the value
// cell's title names its cause in one phrase.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
// The page loads the language module ahead of the core. With no seed in
// scope it reads Python's spellings.
require('../../Public/authoring-language.js');
const Core = require('../../Public/inputs-editor-core.js');

const read = (file) => fs.readFile(path.resolve(file), 'utf8');

test('every value editor includes the one note partial and holds no copy of its own', async () => {
  for (const file of ['_assignment-edit-body.leaf', '_family-editor-body.leaf', '_suite-sections.leaf']) {
    const source = await read('Resources/Views/' + file);
    assert.match(source, /#extend\("_value-cue-note"\)/, file + ' must include the note partial');
    assert.doesNotMatch(source, /amber border/, file + ' holds its own copy of the note');
  }
  // The create page reaches the section inputs through _suite-sections.
  assert.doesNotMatch(await read('Resources/Views/assignment-new.leaf'), /amber border/);
});

test('the note links a heading that docs/inputs.md has', async () => {
  const note = await read('Resources/Views/_value-cue-note.leaf');
  const doc = await read('docs/inputs.md');
  const link = /docs\/inputs\.md#([a-z0-9-]+)/.exec(note);
  assert.ok(link, 'the note must link a section of docs/inputs.md');
  // GitHub's anchor for a heading: lower case, punctuation dropped, spaces to hyphens.
  const anchors = [...doc.matchAll(/^#+ (.+)$/gm)].map((m) =>
    m[1].toLowerCase().replace(/[^a-z0-9 -]/g, '').replace(/ /g, '-'));
  assert.ok(anchors.includes(link[1]), '#' + link[1] + ' names no heading in docs/inputs.md');
});

test('every value input is named "Value", so its title is only a description', async () => {
  const templates = [
    ['_assignment-edit-body.leaf', 'js-global-input-value'],
    ['_suite-sections.leaf', 'js-section-var-value'],
  ];
  for (const [file, hook] of templates) {
    const source = await read('Resources/Views/' + file);
    const tag = new RegExp('<input[^>]*' + hook + '[^>]*>').exec(source);
    assert.ok(tag, file + ' has no value input');
    assert.match(tag[0], /aria-label="Value"/, file);
  }
  // The rows the scripts build.
  assert.match(await read('Public/inputs-editor-core.js'), /classes\.value \+ '" aria-label="Value"/);
  assert.match(await read('Public/pattern-family-editor.js'), /js-pf-var-value" aria-label="Value"/);
});

/// A stub input with what refreshRow touches.
function input(value) {
  return { value, title: '', classList: { toggle() {} } };
}

test('a value cell names its cause in one phrase', () => {
  const editor = Core.createEditor({ row: 'r', name: 'n', value: 'v', valid: 'c', remove: 'x' });
  const cases = [
    ['hello', 'Kept as text'],
    ["['a', 'b']", 'Read as a pasted literal'],
    ['= seed % 26', 'Per-student expression'],
    ['=', 'Empty expression'],
    ['42', ''],
  ];
  for (const [raw, title] of cases) {
    const value = input(raw);
    const cells = { '.n': input('x'), '.v': value, '.c': { textContent: '' } };
    editor.refreshRow({ querySelector: (selector) => cells[selector] ?? null }, null);
    assert.equal(value.title, title, raw);
  }
});
