// Unit tests for the Files panel's saved notes in Public/support-files.js.
//
// The datasets PUT returns `savedNotes`, keyed by file, when the save stored
// something other than what was sent: a library sample that covers the whole
// file is stored as none (docs/dataset-shared-delivery.md, "Whole-file
// samples"). The row's status shows the note in place of "Saved", so the
// emptied sample field is explained. The PUT carries every row, so a note can
// name another row too.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/support-files.js'), 'utf8');

/// An input whose class list holds its own selector's class, which is how
/// the change handler tells the fields apart.
function makeInput(className) {
  return {
    value: '', disabled: false, checked: false, hidden: false,
    classList: { contains: (name) => name === className },
    focus() {}, select() {},
  };
}

function makeRow(filename) {
  const parts = {};
  [
    '.js-dataset-toggle', '.js-dataset-size-field', '.js-dataset-size', '.js-dataset-stratum-field',
    '.js-dataset-stratum', '.js-dataset-blank-field', '.js-dataset-blank-columns', '.js-dataset-blank-percent',
    '.js-dataset-status', '.js-dataset-estimates', '.js-dataset-similarity', '.js-dataset-drift',
  ].forEach((sel) => { parts[sel] = makeInput(sel.slice(1)); });
  const row = {
    parts,
    getAttribute: (name) => (name === 'data-support-file' ? filename : null),
    querySelector: (sel) => parts[sel] || null,
  };
  Object.values(parts).forEach((el) => {
    el.closest = (want) => (want === 'tr[data-support-file]' ? row : null);
  });
  return row;
}

/// The panel over two rows, with a server that answers every PUT with
/// `savedNotes` and records each status it is asked to show.
function load(savedNotes) {
  const handlers = {};
  const statuses = new Map();
  let stored = [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 2 }];
  const rows = [makeRow('cases.csv'), makeRow('notes.csv')];
  const doc = {
    readyState: 'complete',
    getElementById: () => null,
    body: { addEventListener(type, fn) { (handlers[type] ||= []).push(fn); } },
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: (sel) => (sel === 'tr[data-support-file]' ? rows : []),
  };
  const sandbox = { document: doc, Promise, JSON, Error, Object, Array, Math, parseInt, setTimeout };
  sandbox.ChickadeeUI = {
    setStatus: (el, text, kind) => { statuses.set(el, { text, kind }); },
    showActionError: () => {},
    confirmAction: () => Promise.resolve(true),
    fetchJSON: (url, opts) => {
      if (opts && opts.method === 'PUT') {
        stored = JSON.parse(JSON.stringify(opts.body)).datasets;
        return Promise.resolve({ datasets: stored, diagnostics: [], savedNotes });
      }
      return Promise.resolve({ datasets: stored, diagnostics: [] });
    },
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  sandbox.window.initSupportFiles({
    uploadURL: () => '/u', deleteURL: () => '/d', datasetsURL: () => '/instructor/abc/datasets',
    onChange: () => {},
  });
  const statusOf = (row) => statuses.get(row.querySelector('.js-dataset-status'));
  return { rows, handlers, statusOf };
}

async function editSize(h, row, value) {
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = value;
  const target = row.querySelector('.js-dataset-size');
  await Promise.all((h.handlers.change || []).map((fn) => fn({ target })));
  for (let i = 0; i < 6; i += 1) await new Promise((r) => setTimeout(r, 0));
}

test('a dropped sample shows its note in place of Saved', async () => {
  const note = 'Saved with no sample: it covered all 3 rows.';
  const h = load({ 'cases.csv': note });
  await editSize(h, h.rows[0], '3');
  assert.deepEqual(h.statusOf(h.rows[0]), { text: note, kind: 'ok' });
});

test('a note for another row is shown on that row', async () => {
  const note = 'Saved with no sample: it covered all 4 rows.';
  const h = load({ 'notes.csv': note });
  await editSize(h, h.rows[0], '2');
  assert.equal(h.statusOf(h.rows[0]).text, 'Saved');
  assert.deepEqual(h.statusOf(h.rows[1]), { text: note, kind: 'ok' });
});

test('a save with no notes says Saved', async () => {
  const h = load(undefined);
  await editSize(h, h.rows[0], '2');
  assert.equal(h.statusOf(h.rows[0]).text, 'Saved');
  assert.equal(h.statusOf(h.rows[1]), undefined);
});
