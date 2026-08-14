// Unit tests for Public/list-filter.js — the one live list-filter
// implementation (UI audit S1).
//
// The behaviour worth pinning is the <select> rule: a row whose role cell is
// a <select> contains every option label as *text* ("Student TA Instructor"),
// so a raw whole-row match lights up every row for the query "ta". Two of the
// three inline copies this module replaced had exactly that defect; the
// module matches a select cell by its VALUE instead. If this test starts
// failing, the defect is back.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/list-filter.js'), 'utf8');

function makeCell(text, select) {
  return {
    textContent: text,
    querySelector: (sel) => (sel === 'select' ? select ?? null : null),
  };
}

// A row shaped like the enrolled-students / users tables: name, username,
// role (a <select> whose text is every option label), last-seen.
function makeRow(name, username, roleValue) {
  const select = roleValue === null ? null : { value: roleValue };
  const cells = [
    makeCell(name),
    makeCell(username),
    roleValue === null ? makeCell('(pending)') : makeCell('Student TA Instructor', select),
    makeCell('2 hours ago'),
  ];
  return { cells, hidden: false, textContent: `${name} ${username} Student TA Instructor 2 hours ago` };
}

function loadModule({ rows, tableID = 'the-table' }) {
  const tbody = { querySelectorAll: () => rows };
  const table = { querySelector: (sel) => (sel === 'tbody' ? tbody : null) };
  const documentStub = {
    readyState: 'complete',
    getElementById: (id) => (id === tableID ? table : null),
    querySelectorAll: () => [],
    addEventListener: () => {},
  };
  const sandbox = { document: documentStub, module: { exports: {} } };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox.module.exports;
}

function makeInput(value, tableID = 'the-table') {
  return { value, getAttribute: () => tableID };
}

test('select cells match by value, not option-label text', () => {
  const rows = [
    makeRow('Ada Lovelace', 'alovelace', 'student'),
    makeRow('Tom Assistant', 'tassist', 'ta'),
    makeRow('Ines Structor', 'instruct', 'instructor'),
  ];
  const ListFilter = loadModule({ rows });

  ListFilter.apply(makeInput('ta'));
  // "ta" appears in every row's option-label text; only the real TA (and the
  // instructor, whose VALUE does not contain "ta") must be decided by value.
  assert.equal(rows[0].hidden, true, 'student row must hide for query "ta"');
  assert.equal(rows[1].hidden, false, 'TA row must stay for query "ta"');
  assert.equal(rows[2].hidden, true, 'instructor row must hide for query "ta"');
});

test('name and username text still match, case-insensitively', () => {
  const rows = [
    makeRow('Ada Lovelace', 'alovelace', 'student'),
    makeRow('Tom Assistant', 'tassist', 'ta'),
  ];
  const ListFilter = loadModule({ rows });

  ListFilter.apply(makeInput('LOVELACE'));
  assert.equal(rows[0].hidden, false);
  assert.equal(rows[1].hidden, true);
});

test('empty and whitespace-only queries unhide every row', () => {
  const rows = [makeRow('Ada Lovelace', 'alovelace', 'student')];
  const ListFilter = loadModule({ rows });

  ListFilter.apply(makeInput('zzz-no-match'));
  assert.equal(rows[0].hidden, true);
  ListFilter.apply(makeInput('   '));
  assert.equal(rows[0].hidden, false);
});

test('a cell-less row falls back to whole-row textContent', () => {
  const row = { cells: [], hidden: false, textContent: 'Standalone message row' };
  const ListFilter = loadModule({ rows: [row] });

  ListFilter.apply(makeInput('standalone'));
  assert.equal(row.hidden, false);
  ListFilter.apply(makeInput('absent'));
  assert.equal(row.hidden, true);
});

test('a missing target table is a no-op, not a throw', () => {
  const ListFilter = loadModule({ rows: [] });
  ListFilter.apply(makeInput('anything', 'no-such-table'));
  ListFilter.apply(null);
});
