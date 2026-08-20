// Unit tests for Public/list-filter.js — the one live list-filter
// implementation (UI audit S1, re-engineered 2026-08).
//
// The stubs below model the shape the real tables have, because every rule
// worth pinning here is a rule about SHAPE:
//
//   * a role cell is a <select> whose text is every option label,
//   * an Actions cell holds forms, buttons and (on a pending student row) a
//     collapsed registration panel full of prose and field labels,
//   * a Last Seen cell carries a data-iso the sorter reads and the user
//     does not see.
//
// Two shipped defects live in that shape: "ta" matched every row through the
// select's option labels (fixed in S1), and "student" matched every pending
// row through the Actions panel's "Student number (optional)" label — on a
// students roster. If these tests fail, one of those is back.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/list-filter.js'), 'utf8');

// ── Minimal DOM ─────────────────────────────────────────────────────────────

function makeElement(tag) {
  return {
    tagName: tag.toUpperCase(),
    className: '',
    textContent: '',
    hidden: false,
    attrs: {},
    // Real enough for the one thing list-filter.js does with it: mark and
    // unmark the last visible row. `className` stays the backing store so a
    // selector check can read it.
    classList: {
      add(name) {
        const set = new Set(this.owner.className.split(/\s+/).filter(Boolean));
        set.add(name);
        this.owner.className = [...set].join(' ');
      },
      remove(name) {
        const set = new Set(this.owner.className.split(/\s+/).filter(Boolean));
        set.delete(name);
        this.owner.className = [...set].join(' ');
      },
      contains(name) {
        return this.owner.className.split(/\s+/).filter(Boolean).includes(name);
      },
    },
    children: [],
    parentNode: null,
    nextSibling: null,
    setAttribute(name, value) { this.attrs[name] = String(value); },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
    },
    hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name); },
    removeAttribute(name) { delete this.attrs[name]; },
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; },
    insertBefore(child) { this.children.push(child); child.parentNode = this; return child; },
    addEventListener(type, fn) { (this.listeners ||= []).push({ type, fn }); },
    querySelector() { return null; },
    closest() { return null; },
  };
}

function newElement(tag) {
  const el = makeElement(tag);
  el.classList.owner = el;
  return el;
}

function makeCell(text, { select = null, iso = null } = {}) {
  const cell = newElement('td');
  cell.textContent = text;
  if (iso) cell.setAttribute('data-iso', iso);
  cell.querySelector = (sel) => (sel === 'select' ? select : null);
  return cell;
}

function makeSelect(value, labels = ['Student', 'TA', 'Instructor']) {
  const byValue = { student: 'Student', ta: 'TA', instructor: 'Instructor' };
  return {
    value,
    selectedOptions: [{ text: byValue[value] || value }],
    optionText: labels.join(' '),
  };
}

// A roster row: Name | Username | Role (<select>) | Last Seen | Actions.
// The role cell's TEXT is every option label; the actions cell's text is the
// buttons plus, on a pending row, the whole registration panel.
function makeRow({ name, username, role, pending = false }) {
  const select = pending ? null : makeSelect(role);
  const actionsText = pending
    ? 'Register Materialize into a real account now (for grade-sync testing). '
      + 'Display name Student number (optional) Email (optional) SSO subject (optional) Register'
    : 'Remove from course';
  const cells = [
    makeCell(name),
    makeCell(username),
    select ? makeCell(select.optionText, { select }) : makeCell('(pending)'),
    makeCell('2 hours ago', { iso: '2026-08-14T20:00:00Z' }),
    makeCell(actionsText),
  ];
  const row = newElement('tr');
  row.cells = cells;
  row.textContent = cells.map((c) => c.textContent).join(' ');
  return row;
}

const SORTABLE_HEADERS = ['name', 'username', 'role', 'last-seen', null];

function loadModule({ rows, tableID = 'the-table', headerKeys = SORTABLE_HEADERS, input }) {
  const tbody = newElement('tbody');
  tbody.querySelectorAll = () => rows;
  tbody.querySelector = (sel) => {
    const match = /^tr\.(.+)$/.exec(sel);
    if (!match) return null;
    return rows.find((row) => row.classList.contains(match[1])) || null;
  };

  const headers = headerKeys.map((key) => {
    const th = newElement('th');
    if (key !== null) th.setAttribute('data-sort-key', key);
    return th;
  });

  const table = newElement('table');
  table.querySelector = (sel) => (sel === 'tbody' ? tbody : null);
  table.querySelectorAll = (sel) => (sel === 'thead th' ? headers : []);
  const tableHost = newElement('div');
  tableHost.appendChild(table);

  const documentStub = {
    readyState: 'complete',
    getElementById: (id) => (id === tableID ? table : null),
    querySelectorAll: () => [],
    addEventListener: () => {},
    createElement: (tag) => newElement(tag),
  };
  const sandbox = { document: documentStub, module: { exports: {} }, WeakMap };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { ListFilter: sandbox.module.exports, table, input };
}

function makeInput(value, { tableID = 'the-table', emptyMessage = null } = {}) {
  const input = newElement('input');
  input.value = value;
  input.setAttribute('data-list-filter', tableID);
  if (emptyMessage) input.setAttribute('data-list-filter-empty', emptyMessage);
  newElement('span').appendChild(input);
  return input;
}

function setQuery(input, value) { input.value = value; return input; }

// ── What is matched ─────────────────────────────────────────────────────────

test('select cells match the selected option, not every option label', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' }),
    makeRow({ name: 'Ines Structor', username: 'instruct', role: 'instructor' }),
  ];
  const { ListFilter } = loadModule({ rows });

  ListFilter.apply(makeInput('ta'));
  assert.equal(rows[0].hidden, true, 'student row must hide for query "ta"');
  assert.equal(rows[1].hidden, false, 'TA row must stay for query "ta"');
  assert.equal(rows[2].hidden, true, 'instructor row must hide for query "ta"');
});

// The defect this rewrite exists for. The Actions cell of a PENDING row holds a
// collapsed registration panel whose labels include "Student number
// (optional)" — so on a roster of students, the query "student" matched every
// pending row. Only columns the table declares sortable are searched now.
test('the Actions column is not searched', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Pat Pending', username: 'ppending', pending: true }),
  ];
  const { ListFilter } = loadModule({ rows });

  ListFilter.apply(makeInput('student'));
  assert.equal(rows[1].hidden, true, '"student" must not match a pending row via its Actions panel');
  assert.equal(rows[0].hidden, false, 'the real student row matches on its role cell');

  ListFilter.apply(makeInput('email'));
  assert.equal(rows[0].hidden, true);
  assert.equal(rows[1].hidden, true, '"email" must not match through the registration panel');

  ListFilter.apply(makeInput('remove'));
  assert.equal(rows[0].hidden, true, 'a button label must not match every row');
});

test('a table declaring no sortable columns falls back to every cell', () => {
  const rows = [makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' })];
  const { ListFilter } = loadModule({ rows, headerKeys: [null, null, null, null, null] });

  ListFilter.apply(makeInput('remove'));
  assert.equal(rows[0].hidden, false, 'with no data columns declared, all cells are searched');
});

test('terms are ANDed and may match different cells, in any order', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Ada Byron', username: 'abyron', role: 'student' }),
  ];
  const { ListFilter } = loadModule({ rows });

  ListFilter.apply(makeInput('lovelace ada'));
  assert.equal(rows[0].hidden, false, 'reversed terms still match');
  assert.equal(rows[1].hidden, true);

  ListFilter.apply(makeInput('ada abyron'));
  assert.equal(rows[0].hidden, true, 'each term must match some cell of the SAME row');
  assert.equal(rows[1].hidden, false);
});

test('a term may not match across a cell boundary', () => {
  const rows = [makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' })];
  const { ListFilter } = loadModule({ rows });

  ListFilter.apply(makeInput('lovelace alovelace'), 'both terms exist in their own cells');
  assert.equal(rows[0].hidden, false);

  ListFilter.apply(makeInput('lovelace alov'));
  assert.equal(rows[0].hidden, false);

  ListFilter.apply(makeInput('acealovelace'));
  assert.equal(rows[0].hidden, true, 'the old joined-text match spanned cells; this must not');
});

test('matching folds case and diacritics', () => {
  const rows = [
    makeRow({ name: 'José Muñoz', username: 'jmunoz', role: 'student' }),
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
  ];
  const { ListFilter } = loadModule({ rows });

  ListFilter.apply(makeInput('munoz'));
  assert.equal(rows[0].hidden, false, 'an unaccented query finds an accented name');
  assert.equal(rows[1].hidden, true);

  ListFilter.apply(makeInput('JOSÉ'));
  assert.equal(rows[0].hidden, false, 'case-insensitive, accents intact');
});

test('empty and whitespace-only queries unhide every row', () => {
  const rows = [makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' })];
  const { ListFilter } = loadModule({ rows });

  ListFilter.apply(makeInput('zzz-no-match'));
  assert.equal(rows[0].hidden, true);
  ListFilter.apply(makeInput('   '));
  assert.equal(rows[0].hidden, false);
});

test('a cell-less row falls back to whole-row textContent', () => {
  const row = newElement('tr');
  row.cells = [];
  row.textContent = 'Standalone message row';
  const { ListFilter } = loadModule({ rows: [row] });

  ListFilter.apply(makeInput('standalone'));
  assert.equal(row.hidden, false);
  ListFilter.apply(makeInput('absent'));
  assert.equal(row.hidden, true);
});

test('a missing target table is a no-op, not a throw', () => {
  const { ListFilter } = loadModule({ rows: [] });
  ListFilter.apply(makeInput('anything', { tableID: 'no-such-table' }));
  ListFilter.apply(null);
});

// ── What is reported ────────────────────────────────────────────────────────

test('filtering to nothing shows the page-worded no-match message', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' }),
  ];
  const { ListFilter, table } = loadModule({ rows });
  const input = makeInput('', { emptyMessage: 'No students match this filter.' });

  ListFilter.apply(setQuery(input, 'zzz'));
  const host = table.parentNode;
  const message = host.children.find((el) => el.className.includes('js-filter-no-match'));
  assert.ok(message, 'a no-match message is inserted after the table');
  assert.equal(message.textContent, 'No students match this filter.');
  assert.equal(message.hidden, false, 'shown when nothing matches');

  ListFilter.apply(setQuery(input, 'ada'));
  assert.equal(message.hidden, true, 'hidden as soon as something matches');

  ListFilter.apply(setQuery(input, ''));
  assert.equal(message.hidden, true, 'hidden when the filter is cleared');
});

// table-poll.js calls apply() every few seconds on the users and students
// pages. If that minted the status span, an unfiltered page would grow an empty
// element and its flex gap without anyone touching the filter.
test('a poll repaint on an unfiltered page mints nothing', () => {
  const rows = [makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' })];
  const { ListFilter } = loadModule({ rows });
  const input = makeInput('');

  ListFilter.apply(input);
  ListFilter.apply(input);
  assert.deepEqual(input.parentNode.children.map((el) => el.tagName), ['INPUT'],
    'no status span until something is filtered');
});

test('the status region announces the count only while filtering', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' }),
  ];
  const { ListFilter } = loadModule({ rows });
  const input = makeInput('');
  const status = () => input.parentNode.children.find((el) => el.className === 'filter-status');

  ListFilter.apply(setQuery(input, 'ada'));
  assert.equal(status().getAttribute('role'), 'status');
  assert.equal(status().getAttribute('aria-live'), 'polite');
  assert.equal(status().textContent, 'Showing 1 of 2');

  ListFilter.apply(setQuery(input, ''));
  assert.equal(status().textContent, '', 'silent when the box is empty');
});

// ── Enhancement ─────────────────────────────────────────────────────────────

// The suppression covers every .filter-input, not only the live ones. Scoping
// it to data-list-filter left the two GET-form filters (activity, audit) with a
// bare autocomplete="off" — the suppression this module's own header calls
// insufficient — so one control had two strengths depending on the page.
test('a GET-form filter (no target table) still gets full suppression', () => {
  const { ListFilter } = loadModule({ rows: [] });
  const input = newElement('input');

  ListFilter.enhance(input);
  assert.equal(input.getAttribute('autocomplete'), 'off');
  assert.equal(input.hasAttribute('readonly'), true, 'readonly-until-focus applies');
  assert.deepEqual(input.listeners.map((l) => l.type), ['focus', 'keydown'],
    'no input listener without a target table');
  assert.equal(input.hasAttribute('aria-controls'), false);

  input.listeners[0].fn();
  assert.equal(input.hasAttribute('readonly'), false, 'focus releases readonly');
});

test('a live filter gets the suppression, the binding and aria-controls', () => {
  const { ListFilter } = loadModule({ rows: [] });
  const input = makeInput('');

  ListFilter.enhance(input);
  assert.equal(input.getAttribute('autocomplete'), 'off');
  assert.equal(input.getAttribute('aria-controls'), 'the-table');
  assert.deepEqual(input.listeners.map((l) => l.type), ['focus', 'keydown', 'input']);
});

test('Escape clears the box and restores every row', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' }),
  ];
  const { ListFilter } = loadModule({ rows });
  const input = makeInput('');
  ListFilter.enhance(input);

  ListFilter.apply(setQuery(input, 'ada'));
  assert.equal(rows[1].hidden, true);

  const keydown = input.listeners.find((l) => l.type === 'keydown');
  keydown.fn({ key: 'Escape' });
  assert.equal(input.value, '');
  assert.equal(rows[1].hidden, false, 'Escape re-shows the rows');
});

// ── Speed, and the correctness it must not cost ─────────────────────────────

test('a narrowing keystroke cannot resurrect a hidden row, and a widening one can', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' }),
  ];
  const { ListFilter } = loadModule({ rows });
  const input = makeInput('');

  ListFilter.apply(setQuery(input, 'a'));
  assert.equal(rows[0].hidden, false);
  assert.equal(rows[1].hidden, false);

  ListFilter.apply(setQuery(input, 'ada'));       // narrowing
  assert.equal(rows[1].hidden, true);

  ListFilter.apply(setQuery(input, 'ad'));        // widening — full re-test
  assert.equal(rows[0].hidden, false);
  assert.equal(rows[1].hidden, true, 'still no match, but re-tested rather than assumed');

  ListFilter.apply(setQuery(input, 'a'));         // widening back to everything
  assert.equal(rows[1].hidden, false, 'a widened query must re-test hidden rows');
});

test('a repaint with new rows is a full pass even when the query narrows', () => {
  const rows = [
    makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' }),
    makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' }),
  ];
  const { ListFilter } = loadModule({ rows });
  const input = makeInput('');

  ListFilter.apply(setQuery(input, 'ada'));
  assert.equal(rows[1].hidden, true);

  // table-poll.js replaces tbody.innerHTML: same count, all-new row nodes, and
  // the fresh nodes start visible. A narrowing query must not skip them.
  const replacement = makeRow({ name: 'Ada Byron', username: 'abyron', role: 'student' });
  rows[0] = replacement;
  rows[1] = makeRow({ name: 'Tom Assistant', username: 'tassist', role: 'ta' });

  ListFilter.apply(setQuery(input, 'ada b'));
  assert.equal(rows[0].hidden, false, 'the new matching row is shown');
  assert.equal(rows[1].hidden, true, 'the new non-matching row is hidden, not left visible');
});

test('hidden is written only when it changes', () => {
  const rows = [makeRow({ name: 'Ada Lovelace', username: 'alovelace', role: 'student' })];
  const { ListFilter } = loadModule({ rows });

  let writes = 0;
  let hidden = false;
  Object.defineProperty(rows[0], 'hidden', {
    get() { return hidden; },
    set(value) { writes += 1; hidden = value; },
  });

  const input = makeInput('');
  ListFilter.apply(setQuery(input, 'ada'));   // matches — already visible
  assert.equal(writes, 0, 'a row that stays visible is not written');

  ListFilter.apply(setQuery(input, 'zzz'));   // now hidden
  assert.equal(writes, 1);

  ListFilter.apply(setQuery(input, 'zzzz'));  // still hidden (narrowing)
  assert.equal(writes, 1, 'a row that stays hidden is not written again');
});

// ── The last VISIBLE row carries the separator-suppressing class ────────────
//
// CSS cannot express "last visible row": `:last-child` is the DOM's last row,
// and filtering hides rows with the `hidden` attribute rather than removing
// them. The stale separator then collapsed with the table's own bottom border
// and won it — cell beats table in CSS conflict resolution — so a filtered
// table's bottom edge rendered a shade lighter than an unfiltered one.

const LAST_VISIBLE = 'row-last-visible';

function marked(rows) {
  return rows.filter((row) => row.classList.contains(LAST_VISIBLE)).map((row) => row.cells[0].textContent);
}

test('unfiltered: the mark sits on the final row', () => {
  const rows = [
    makeRow({ name: 'Ada', username: 'ada', role: 'student' }),
    makeRow({ name: 'Brendan', username: 'bren', role: 'ta' }),
    makeRow({ name: 'Cai', username: 'cai', role: 'student' }),
  ];
  const { ListFilter } = loadModule({ rows });
  ListFilter.apply(makeInput(''));
  assert.deepEqual(marked(rows), ['Cai']);
});

test('filtering moves the mark to the last row still on screen', () => {
  const rows = [
    makeRow({ name: 'Ada', username: 'ada', role: 'student' }),
    makeRow({ name: 'Brendan', username: 'bren', role: 'ta' }),
    makeRow({ name: 'Cai', username: 'cai', role: 'student' }),
  ];
  const { ListFilter } = loadModule({ rows });
  ListFilter.apply(makeInput('ada'));
  // Only Ada survives, so Ada — not the hidden final row — closes the table.
  assert.deepEqual(marked(rows), ['Ada']);
  assert.equal(rows[2].hidden, true);
});

test('the mark is exclusive and follows a widening filter back', () => {
  const rows = [
    makeRow({ name: 'Ada', username: 'ada', role: 'student' }),
    makeRow({ name: 'Brendan', username: 'bren', role: 'ta' }),
    makeRow({ name: 'Cai', username: 'cai', role: 'student' }),
  ];
  const { ListFilter } = loadModule({ rows });
  const input = makeInput('ada');
  ListFilter.apply(input);
  input.value = '';
  ListFilter.apply(input);
  assert.deepEqual(marked(rows), ['Cai']);
});

test('a filter matching nothing leaves no row marked', () => {
  const rows = [makeRow({ name: 'Ada', username: 'ada', role: 'student' })];
  const { ListFilter } = loadModule({ rows });
  ListFilter.apply(makeInput('zzzznomatch'));
  assert.deepEqual(marked(rows), []);
});
