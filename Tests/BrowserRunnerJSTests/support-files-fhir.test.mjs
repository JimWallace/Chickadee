// Unit tests for how the per-row dataset control in Public/support-files.js
// treats a FHIR NDJSON file (docs/fhir-datasets-plan.md §6, P3).
//
// A FHIR spec is delivered whole, so the panel shows no sample, stratum or
// blanking fields for it. (A FHIR file that is not attached has no toggle at
// all: SupportFileRow does not render one, because FHIR enters through the
// course library.) The harness is the one in support-files-partition.test.mjs,
// with the file name and the lock as options.

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

function load({ specs = [], diagnostics = null, filename = 'ed_feed.ndjson', lock = null } = {}) {
  const puts = [];
  const bodyHandlers = {};
  let stored = specs.slice();

  const rows = [makeRow(filename)];
  // The server marks a locked toggle with data-lock (SupportFileRow).
  if (lock) rows[0].parts['.js-dataset-toggle'].dataset = { lock };
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

async function settle() {
  for (let i = 0; i < 6; i += 1) await new Promise((r) => setTimeout(r, 0));
}

const fhir = { file: 'ed_feed.ndjson', kind: 'rowSample', format: 'fhirNdjson', transforms: [] };

test('a FHIR row shows no sample fields', async () => {
  const h = load({ specs: [fhir], lock: 'attached' });
  await settle();
  const row = h.rows[0];
  assert.equal(row.querySelector('.js-dataset-toggle').checked, true);
  assert.equal(row.querySelector('.js-dataset-toggle').disabled, true);
  assert.equal(row.querySelector('.js-dataset-size-field').hidden, true);
  assert.equal(row.querySelector('.js-dataset-stratum-field').hidden, true);
  assert.equal(row.querySelector('.js-dataset-blank-field').hidden, true);
  assert.equal(row.querySelector('.js-dataset-partition-note').hidden, true);
});

test('a CSV spec still shows its sample fields', async () => {
  const h = load({
    filename: 'cases.csv',
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50, transforms: [] }],
  });
  await settle();
  const row = h.rows[0];
  assert.equal(row.querySelector('.js-dataset-size-field').hidden, false);
  assert.equal(row.querySelector('.js-dataset-toggle').disabled, false);
});
