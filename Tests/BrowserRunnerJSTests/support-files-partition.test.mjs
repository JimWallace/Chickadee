// Unit tests for how the per-row dataset control in Public/support-files.js
// treats a partition (docs/datasets-course-library.md §4.11).
//
// The panel has no fields for a partition: it hides the sample fields, shows
// the note the server rendered, and never sends a part count on a spec that
// is not a partition. The harness is the one in support-files-datasets.test.mjs,
// with the note element added to the row.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/support-files.js'), 'utf8');

// ── Minimal row markup ──────────────────────────────────────────────────────

function makeInput(value = '', disabled = false) {
  return {
    value,
    disabled,
    checked: false,
    hidden: false,
    classes: [],
    classList: { contains(name) { return this.owner.classes.indexOf(name) >= 0; } },
    focus() {}, select() {},
  };
}

/// One `tr[data-support-file]` carrying the control's six elements.
function makeRow(filename) {
  const parts = {
    '.js-dataset-toggle': makeInput(),
    '.js-dataset-size-field': makeInput(),
    '.js-dataset-size': makeInput(),
    '.js-dataset-stratum-field': makeInput(),
    '.js-dataset-stratum': makeInput(),
    '.js-dataset-blank-field': makeInput(),
    '.js-dataset-blank-columns': makeInput(),
    '.js-dataset-blank-percent': makeInput(),
    '.js-dataset-status': makeInput(),
    '.js-dataset-estimates': makeInput(),
    '.js-dataset-similarity': makeInput(),
    '.js-dataset-drift': makeInput(),
    '.js-dataset-partition-note': makeInput(),
    '.js-dataset-part-count': makeInput(),
  };
  const row = {
    filename,
    parts,
    getAttribute: (name) => (name === 'data-support-file' ? filename : null),
    querySelector: (sel) => parts[sel] || null,
  };
  Object.keys(parts).forEach((sel) => {
    const el = parts[sel];
    el.owner = el;
    el.classes = [sel.replace('.', '')];
    el.classList.owner = el;
    el.closest = (want) => (want === 'tr[data-support-file]' ? row : null);
  });
  return row;
}

function load({ specs = [], diagnostics = null } = {}) {
  const puts = [];
  const bodyHandlers = {};
  let stored = specs.slice();

  const rows = [makeRow('cases.csv')];
  const doc = {
    readyState: 'complete',
    getElementById: () => null,
    body: { addEventListener(type, fn) { (bodyHandlers[type] ||= []).push(fn); } },
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: (sel) => (sel === 'tr[data-support-file]' ? rows : []),
  };

  // The server serves an estimate block per marked file on the same GET/PUT
  // the controls use; the mock mirrors that by deriving them from whatever is
  // currently stored (a caller passes `diagnostics` as a per-spec factory).
  const blocks = () => (diagnostics ? stored.map(diagnostics).filter(Boolean) : []);

  const sandbox = { document: doc, Promise, JSON, Error, Object, Array, Math, parseInt, setTimeout };
  sandbox.ChickadeeUI = {
    setStatus: () => {},
    showActionError: () => {},
    confirmAction: () => Promise.resolve(true),
    // GET returns what the server holds; PUT records the body and becomes the
    // new stored state, so a second edit is built from the first one's result.
    fetchJSON: (url, opts) => {
      if (opts && opts.method === 'PUT') {
        // Round-tripped through JSON so the recorded body is a host-realm
        // value: objects built inside the vm context carry that context's
        // prototypes, and deepStrictEqual compares those too.
        const body = JSON.parse(JSON.stringify(opts.body));
        puts.push(body);
        stored = body.datasets.slice();
      }
      return Promise.resolve({ datasets: stored, diagnostics: blocks() });
    },
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const config = {
    csrfToken: 'csrf',
    uploadURL: () => '/u',
    deleteURL: () => '/d',
    datasetsURL: () => '/instructor/abc/datasets',
    onChange: () => {},
  };
  sandbox.window.initSupportFiles(config);

  return {
    puts, rows, bodyHandlers, stored: () => stored,
    // A second init paints the server state again, as after a workbench swap.
    repaint: (next) => { stored = next; sandbox.window.initSupportFiles(config); },
  };
}

function change(h, row, selector) {
  const target = row.querySelector(selector);
  return Promise.all((h.bodyHandlers.change || []).map((fn) => fn({ target })));
}

async function settle() {
  for (let i = 0; i < 6; i += 1) await new Promise((r) => setTimeout(r, 0));
}

const lastSpec = (h) => h.puts[h.puts.length - 1].datasets[0];
const partition = { file: 'cases.csv', kind: 'partition', partCount: 4, transforms: [] };

test('a partition row hides the sample fields and shows its note', async () => {
  const h = load({ specs: [partition] });
  await settle();
  const row = h.rows[0];
  assert.equal(row.querySelector('.js-dataset-toggle').checked, true);
  assert.equal(row.querySelector('.js-dataset-size-field').hidden, true);
  assert.equal(row.querySelector('.js-dataset-stratum-field').hidden, true);
  assert.equal(row.querySelector('.js-dataset-blank-field').hidden, true);
  assert.equal(row.querySelector('.js-dataset-partition-note').hidden, false);
  assert.equal(row.querySelector('.js-dataset-part-count').textContent, '4');
  // One click must not end a partition: the toggle is locked.
  assert.equal(row.querySelector('.js-dataset-toggle').disabled, true);
});

test('a partition removed elsewhere unlocks the toggle and hides the note', async () => {
  const h = load({ specs: [partition] });
  await settle();
  h.repaint([]);
  await settle();
  const row = h.rows[0];
  assert.equal(row.querySelector('.js-dataset-toggle').disabled, false);
  assert.equal(row.querySelector('.js-dataset-partition-note').hidden, true);
});

test('a sampled row keeps its fields and hides the note', async () => {
  const h = load({ specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50, transforms: [] }] });
  await settle();
  const row = h.rows[0];
  assert.equal(row.querySelector('.js-dataset-size-field').hidden, false);
  assert.equal(row.querySelector('.js-dataset-partition-note').hidden, true);
});

test('a sample edit never sends a part count', async () => {
  // A stale part count on a sampled spec would be refused by the server.
  const h = load({ specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50, partCount: 4 }] });
  await settle();
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '30';
  await change(h, row, '.js-dataset-size');
  await settle();
  const spec = lastSpec(h);
  assert.equal(spec.sampleSize, 30);
  assert.equal('partCount' in spec, false);
});
