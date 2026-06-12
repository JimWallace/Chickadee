import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const SuiteList = require('../../Public/suite-list.js');

function fakeFile(name, content) {
  return {
    name,
    size: Buffer.byteLength(content),
    text: () => Promise.resolve(content),
  };
}

test('classifies extensionless shell shebang files as scripts', async () => {
  const sh = await SuiteList.classifyFile(fakeFile('check_submission', '#!/bin/sh\necho ok\n'));
  const bash = await SuiteList.classifyFile(fakeFile('run_public', '#!/usr/bin/env bash\necho ok\n'));

  assert.equal(sh.isScript, true);
  assert.equal(sh.tier, 'public');
  assert.deepEqual(sh.errors, []);
  assert.equal(bash.isScript, true);
  assert.equal(bash.tier, 'public');
  assert.deepEqual(bash.errors, []);
});

test('classifies extensionless python shebang files as scripts', async () => {
  const result = await SuiteList.classifyFile(fakeFile(
    'BMI Boundary Cases',
    '#!/usr/bin/env python3\n\nprint("ok")\n',
  ));

  assert.equal(result.isScript, true);
  assert.equal(result.tier, 'public');
  assert.deepEqual(result.errors, []);
});

test('classifies extensionless files without shebang as support with a clear warning', async () => {
  const result = await SuiteList.classifyFile(fakeFile('notes', 'echo not necessarily runnable\n'));

  assert.equal(result.isScript, false);
  assert.equal(result.tier, 'support');
  assert.deepEqual(result.errors, [
    'No extension or recognized shebang; this file will be included as support unless marked as a test',
  ]);
});

test('mergeFiles appends new files and replaces duplicates in place', () => {
  const oldA = fakeFile('a.py', 'old');
  const oldB = fakeFile('b.sh', 'old');
  const newA = fakeFile('a.py', 'new');
  const newC = fakeFile('c.sh', 'new');

  const merged = SuiteList.mergeFiles([oldA, oldB], [newA, newC]);

  assert.deepEqual(merged.map((file) => file.name), ['a.py', 'b.sh', 'c.sh']);
  assert.equal(merged[0], newA);
  assert.equal(merged[1], oldB);
  assert.equal(merged[2], newC);
});

test('upsertUploadItems preserves settings for replaced upload files', () => {
  const existingItems = [
    { name: 'starter.py', source: 'existing', tier: 'support', dependsOn: [], points: 1 },
    {
      name: 'check',
      source: 'upload',
      index: 0,
      isTest: true,
      tier: 'secret',
      dependsOn: ['starter.py'],
      points: 7,
      displayName: 'Private check',
      errors: [],
    },
  ];
  const files = [fakeFile('check', '#!/bin/sh\necho ok\n'), fakeFile('helper.txt', 'support\n')];
  const classifications = [
    { isScript: true, tier: 'public', errors: [] },
    { isScript: false, tier: 'support', errors: [] },
  ];

  const items = SuiteList.upsertUploadItems(existingItems, files, classifications);
  const check = items.find((item) => item.name === 'check');
  const helper = items.find((item) => item.name === 'helper.txt');

  assert.equal(check.tier, 'secret');
  assert.equal(check.points, 7);
  assert.equal(check.displayName, 'Private check');
  assert.deepEqual(check.dependsOn, ['starter.py']);
  assert.equal(check.index, 0);
  assert.equal(helper.tier, 'support');
  assert.equal(helper.index, 1);
});

test('upsertUploadItems does not create upload rows over existing files', () => {
  const items = [{ name: 'already.py', source: 'existing', tier: 'public', dependsOn: [], points: 1 }];
  const files = [fakeFile('already.py', 'print(1)\n'), fakeFile('new.py', 'print(2)\n')];
  const classifications = [
    { isScript: true, tier: 'public', errors: [] },
    { isScript: true, tier: 'public', errors: [] },
  ];

  const next = SuiteList.upsertUploadItems(items, files, classifications);

  assert.deepEqual(next.map((item) => item.name), ['already.py', 'new.py']);
  assert.equal(next[0].source, 'existing');
  assert.equal(next[1].source, 'upload');
  assert.equal(next[1].index, 1);
});
