// Unit tests for Public/test-renderer-script-core.js, the DOM-free half of the
// custom-script body renderer. The renderer is an ES module built on
// CodeMirror, so its decisions could not be tested until they moved into a
// classic core. Pinned here: which template groups a language is offered (an
// Octave author was once offered Python templates), the extension a template
// forces, the filename following the template, the time-limit range, and the
// spec each editing mode saves.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/test-renderer-script-core.js');

const python = { isPython: () => true, scriptExtension: () => 'py' };
const octave = { isPython: () => false, scriptExtension: () => 'm' };
const cpp = { isPython: () => false, scriptExtension: () => 'sh' };

test('Python (or no declared language) gets both groups; every other language gets Shell only', () => {
  assert.deepEqual(Core.templateGroups(python).map((g) => g.group), ['Python', 'Shell']);
  assert.deepEqual(Core.templateGroups(undefined).map((g) => g.group), ['Python', 'Shell']);
  assert.deepEqual(Core.templateGroups(octave).map((g) => g.group), ['Shell']);
  assert.deepEqual(Core.PYTHON_TEMPLATE_GROUP.items.map((i) => i.value), ['py:differential']);
});

test('a sh: template forces .sh; anything else takes the language extension', () => {
  assert.equal(Core.extensionFor('sh:always_pass', octave), 'sh');
  assert.equal(Core.extensionFor('py:differential', octave), 'm');
  assert.equal(Core.extensionFor(null, python), 'py');
  assert.equal(Core.extensionFor(null, undefined), 'py');
  assert.equal(Core.extensionFor('blank', cpp), 'sh');
});

test('highlighting: python, r, and shell for everything else, case-insensitively', () => {
  assert.equal(Core.highlightModeFor('test_a.py'), 'python');
  assert.equal(Core.highlightModeFor('test_a.R'), 'r');
  assert.equal(Core.highlightModeFor('test_a.lua'), 'shell');
  assert.equal(Core.highlightModeFor(''), 'shell');
});

test('the templates URL names the language when there is one', () => {
  assert.equal(Core.templatesURL('r'), '/instructor/script-templates?language=r');
  assert.equal(Core.templatesURL(undefined), '/instructor/script-templates');
  assert.equal(Core.templateContent({ 'sh:file_exists': 'x' }, 'sh:file_exists'), 'x');
  assert.equal(Core.templateContent(null, 'sh:file_exists'), '');
});

test('the filename follows the chosen template, except when blank or when Blank is chosen', () => {
  assert.equal(Core.renamedForTemplate('test_a.py', 'sh:file_exists', python), 'test_a.sh');
  assert.equal(Core.renamedForTemplate('test_a', 'py:differential', python), 'test_a.py');
  assert.equal(Core.renamedForTemplate('   ', 'sh:file_exists', python), null);
  assert.equal(Core.renamedForTemplate('test_a.py', 'blank', octave), null);
  assert.equal(Core.defaultFilename('blank', octave), 'test_new.m');
  assert.equal(Core.defaultFilename('sh:always_pass', octave), 'test_new.sh');
});

test('the time limit is blank-or-1-to-600, refused out of range with the documented message', () => {
  assert.equal(Core.parseTimeLimit(''), null);
  assert.equal(Core.parseTimeLimit('  '), null);
  assert.equal(Core.parseTimeLimit('30'), 30);
  assert.equal(Core.parseTimeLimit('600'), 600);
  for (const bad of ['0', '601', 'abc', '-5']) {
    assert.throws(() => Core.parseTimeLimit(bad), new RegExp(Core.TIME_LIMIT_MESSAGE.replace(/[()]/g, '\\$&')));
  }
});

test('buildSpec per mode: upload edit, saved-script edit, and create with its defaults', () => {
  assert.deepEqual(Core.buildSpec({ mode: 'uploadEdit', content: 'c', uploadEditName: 'up.py' }),
    { uploadEdit: true, name: 'up.py', content: 'c' });
  assert.deepEqual(Core.buildSpec({ mode: 'edit', content: 'c', hint: ' h ', timeLimitText: '5', failureDetail: 'verdictOnly', filename: 'old.py' }),
    { filename: 'old.py', content: 'c', hint: 'h', timeLimitSeconds: 5, failureDetail: 'verdictOnly' });
  assert.deepEqual(Core.buildSpec({ mode: 'create', content: '', hint: '', timeLimitText: '', failureDetail: '', filename: ' new.sh ' }),
    { filename: 'new.sh', content: '', hint: '', timeLimitSeconds: null, failureDetail: null, tier: 'public', points: 1, isTest: true });
});

test('buildSpec refuses an edit with no script and a create with no filename, and a bad limit before either', () => {
  assert.throws(() => Core.buildSpec({ mode: 'edit', filename: '' }), /No script selected/);
  assert.throws(() => Core.buildSpec({ mode: 'create', filename: '  ' }), /Enter a filename first/);
  assert.throws(() => Core.buildSpec({ mode: 'create', filename: 'x.py', timeLimitText: '9999' }), /between 1 and 600/);
});

test('the failure-detail list stays in the renderer, where the Swift coverage test reads it', async () => {
  const src = await fs.readFile(path.resolve('Public/test-renderer-script.js'), 'utf8');
  assert.ok(src.includes('var FAILURE_DETAIL_OPTIONS = ['), 'FailureDetailOptionCoverageTests greps this literal');
});

test('both authoring pages load the classic core before the module renderer', async () => {
  for (const file of ['Resources/Views/_assignment-edit-body.leaf', 'Resources/Views/assignment-new.leaf']) {
    const src = await fs.readFile(path.resolve(file), 'utf8');
    const core = src.indexOf('/test-renderer-script-core.js');
    const wiring = src.indexOf('/test-renderer-script.js');
    assert.ok(core >= 0 && wiring >= 0 && core < wiring, file + ' must load the core before test-renderer-script.js');
    assert.ok(!src.includes('type="module" src="/test-renderer-script-core.js'), 'the core is a classic script, not a module');
  }
});
