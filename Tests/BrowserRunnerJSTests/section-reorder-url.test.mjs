// Guards the section-reorder endpoint wiring in suite-table.js.
//
// The reorder URL used to be derived from the suite URL by string surgery:
//
//     urls.putSuite().replace(/\/suite$/, '/suite-sections/reorder')
//
// That works on the edit page, whose putSuite() is '/instructor/<id>/suite'.
// It silently fails on the create page, whose putSuite() is
// '/instructor/new/draft/suite?draftID=<id>' — the anchored pattern does not
// match a URL ending in a query string, so the replace is a no-op and the
// reorder POSTs to the suite endpoint, which is registered GET/PUT only. The
// resulting 405 reached the instructor as "Section reorder failed ... Reload
// the page to recover."
//
// The builder is now explicit and required, so a missing one fails loudly at
// init instead of resolving to a URL that happens to exist.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const SuiteTable = require('../../Public/suite-table.js');

function urlsMissing(key) {
  const urls = {
    putSuite: () => '/instructor/ABC123/suite',
    deleteScript: (n) => `/instructor/ABC123/scripts/${n}`,
    uploadScript: () => '/instructor/ABC123/scripts',
    reorderSections: () => '/instructor/ABC123/suite-sections/reorder',
  };
  delete urls[key];
  return urls;
}

test('initSuiteTable refuses to start without a reorderSections builder', () => {
  assert.throws(
    () => SuiteTable.initSuiteTable({ urls: urlsMissing('reorderSections') }),
    /reorderSections/,
    'a missing reorder builder must throw, not fall back to a derived URL',
  );
});

test('initSuiteTable still requires the other three builders', () => {
  for (const key of ['putSuite', 'deleteScript', 'uploadScript']) {
    assert.throws(
      () => SuiteTable.initSuiteTable({ urls: urlsMissing(key) }),
      new RegExp(key),
      `a missing ${key} builder must throw`,
    );
  }
});

test('the old derivation is gone from suite-table.js', async () => {
  const src = await fs.readFile(path.resolve('Public/suite-table.js'), 'utf8');
  assert.ok(
    !src.includes("replace(/\\/suite$/"),
    'suite-table.js must not derive the reorder URL from the suite URL',
  );
});

// The two pages produce different URL shapes. Pin both, because the shape
// difference is exactly what the old derivation got wrong.  The wiring lives
// in the per-page Public/*.js files (the inline-script conversion), not the
// templates.
test('both authoring pages supply a reorderSections builder', async () => {
  const create = await fs.readFile(path.resolve('Public/assignment-new-page.js'), 'utf8');
  const edit = await fs.readFile(path.resolve('Public/assignment-edit-page.js'), 'utf8');

  assert.ok(create.includes('reorderSections:'), 'create page must pass reorderSections');
  assert.ok(
    create.includes('/instructor/new/draft/suite-sections/reorder?draftID='),
    'create page must target the draft-scoped reorder endpoint with its draftID query',
  );

  assert.ok(edit.includes('reorderSections:'), 'edit page must pass reorderSections');
  assert.ok(
    edit.includes("'/suite-sections/reorder'"),
    'edit page must target the published reorder endpoint',
  );
});

// The Swift render tests can only see that a page loads its wiring file; the
// wiring the create-page test used to grep out of the served HTML is pinned
// here instead: both pages hand generated/edited scripts to the suite table's
// single write path, and the create page targets the draft-scoped scripts
// endpoint.
test('both authoring pages wire the suite write path', async () => {
  for (const rel of ['Public/assignment-new-page.js', 'Public/assignment-edit-page.js']) {
    const src = await fs.readFile(path.resolve(rel), 'utf8');
    assert.ok(
      src.includes('chickadeeAddExistingSuiteScript'),
      `${rel} must wire chickadeeAddExistingSuiteScript`,
    );
  }
  const create = await fs.readFile(path.resolve('Public/assignment-new-page.js'), 'utf8');
  assert.ok(
    create.includes('/instructor/new/draft/scripts'),
    'create page must POST scripts to the draft scripts endpoint',
  );
});

test('the create page no longer binds its own section handlers', async () => {
  const template = await fs.readFile(path.resolve('Resources/Views/assignment-new.leaf'), 'utf8');
  const wiring = await fs.readFile(path.resolve('Public/assignment-new-page.js'), 'utf8');
  // suite-table.js owns all three; the page used to bind duplicates on top.
  for (const src of [template, wiring]) {
    for (const marker of ['js-section-edit-toggle', 'js-section-edit-cancel', 'js-section-delete-btn']) {
      assert.ok(
        !src.includes(`closest('.${marker}')`),
        `create page still binds a handler for .${marker}; suite-table.js owns it`,
      );
    }
    assert.ok(
      !src.includes('draggingHeader'),
      'create page still carries its own section drag-reorder handler',
    );
  }
});
