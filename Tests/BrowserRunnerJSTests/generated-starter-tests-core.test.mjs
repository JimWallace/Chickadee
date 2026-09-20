// Unit tests for Public/generated-starter-tests-core.js, the DOM-free half of
// the "Generate Starter Tests" panel. Two of its rules were defects that the
// template it used to live in could not show: the scan not naming the
// assignment's language, and the generate step reporting a count of files it
// had refused to write. Both are pinned here, with the refusal wording that
// tells an author a limitation from a mistake.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/generated-starter-tests-core.js');

test('the scan names the declared language, and omits it only when there is none', () => {
  assert.equal(Core.scanURL('r'), '/instructor/scan-notebook?language=r');
  assert.equal(Core.scanURL(null), '/instructor/scan-notebook');
  assert.equal(Core.draftScriptsURL('d/1'), '/instructor/new/draft/scripts?draftID=d%2F1');
});

test('a just-picked file wins over the saved solution, which wins over nothing', () => {
  assert.equal(Core.scanSource({ hasUpload: true, solutionNotebookURL: '/s' }), 'upload');
  assert.equal(Core.scanSource({ hasUpload: false, solutionNotebookURL: '/s' }), 'saved');
  assert.equal(Core.scanSource({ hasUpload: false, solutionNotebookURL: null }), 'none');
});

test('the Python-only refusals name the step and the assignment language', () => {
  assert.equal(Core.pythonOnlyMessage('scan', 'R'),
    'Scanning a solution for functions is Python-only, and this is a R assignment. Use "+ Add Test" in a section to add a test by hand.');
  assert.equal(Core.pythonOnlyMessage('generate', ''),
    'Generated starter tests are Python-only. Use "+ Add Test" in a section to add one by hand.');
});

test('a function uses the template the scan rendered for it, else the placeholder', () => {
  const scanned = [{ name: 'f', templates: [{ id: 'differential', content: '# real' }] }, { name: 'g' }];
  assert.equal(Core.generatedTemplate(scanned, 'py:differential', 'f'), '# real');
  assert.equal(Core.generatedTemplate(scanned, 'differential', 'f'), '# real', 'a bare id works too');
  assert.equal(Core.generatedTemplate(scanned, 'py:other', 'f'), Core.placeholderTemplate('f'));
  assert.equal(Core.generatedTemplate(scanned, 'py:differential', 'g'), Core.placeholderTemplate('g'));
  assert.equal(Core.generatedTemplate([], 'py:differential', 'h'), '# Test: h\n# TODO: implement test\npassed("placeholder")\n');
});

test('each checked function becomes one public 1-point .py test script', () => {
  assert.deepEqual(Core.scriptPayload('bmi', '# c'), { filename: 'test_bmi.py', content: '# c', tier: 'public', points: 1, isTest: true });
  assert.equal(Core.savedMessage(3), '3 test file(s) added to suite.');
});

test('the new-assignment page loads the core before the panel', async () => {
  const src = await fs.readFile(path.resolve('Resources/Views/assignment-new.leaf'), 'utf8');
  const core = src.indexOf('/generated-starter-tests-core.js');
  const wiring = src.indexOf('/generated-starter-tests.js');
  assert.ok(core >= 0 && wiring >= 0 && core < wiring, 'core must be loaded before generated-starter-tests.js');
});
