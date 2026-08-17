// Unit tests for the per-row dataset control in Public/support-files.js.
//
// The existing support-files tests cover upload and delete; they pass no
// `datasetsURL`, so the dataset control returns early and is never exercised.
// This harness supplies one, plus the row markup the control reads.
//
// What is worth pinning here is the PUT BODY, because every defect this control
// has had is a defect in what it sends rather than in what it shows:
//
//   * the panel once wrote `kind: "rowSample"` unconditionally, which would have
//     downgraded every stratified spec on the next row-count edit,
//   * and it built each spec from a fixed field list, so any setting it had not
//     been taught about was dropped by an unrelated edit.
//
// The transform fields make that second shape live again — the model is an
// ordered list of steps and the panel has fields for exactly one — so the rules
// asserted below are: the panel sends what it owns, and leaves alone what it
// does not.

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

/// The estimates disclosure body: collects appended line elements, and
/// clears them when the control resets `textContent`.
function makeDiagnosticsBody() {
  const el = makeInput();
  el.children = [];
  el.appendChild = (child) => { el.children.push(child); };
  Object.defineProperty(el, 'textContent', {
    set(value) { if (value === '') el.children = []; },
    get() { return el.children.map((c) => c.textContent).join('\n'); },
  });
  return el;
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
    '.js-dataset-diagnostics': makeInput(),
    '.js-dataset-diagnostics-body': makeDiagnosticsBody(),
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
    createElement: (tag) => ({ tagName: tag, className: '', textContent: '' }),
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

  sandbox.window.initSupportFiles({
    csrfToken: 'csrf',
    uploadURL: () => '/u',
    deleteURL: () => '/d',
    datasetsURL: () => '/instructor/abc/datasets',
    onChange: () => {},
  });

  return { puts, rows, bodyHandlers, stored: () => stored };
}

function change(h, row, selector) {
  const target = row.querySelector(selector);
  return Promise.all((h.bodyHandlers.change || []).map((fn) => fn({ target })));
}

async function settle() {
  for (let i = 0; i < 6; i += 1) await new Promise((r) => setTimeout(r, 0));
}

const lastSpec = (h) => h.puts[h.puts.length - 1].datasets[0];

// ── Authoring a step ────────────────────────────────────────────────────────

test('naming columns sends one missingValues step at the shown percent', async () => {
  const h = load({ specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50 }] });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '50';
  row.querySelector('.js-dataset-blank-columns').value = 'systolic, ward';
  row.querySelector('.js-dataset-blank-percent').value = '25';

  await change(h, row, '.js-dataset-blank-columns');
  await settle();

  const spec = lastSpec(h);
  assert.equal(spec.transforms.length, 1);
  assert.equal(spec.transforms[0].kind, 'missingValues');
  // Comma-separated, trimmed — an instructor types them as prose.
  assert.deepEqual(spec.transforms[0].columns, ['systolic', 'ward']);
  // Authored as a percentage, stored as the 0 < rate <= 1 fraction.
  assert.equal(spec.transforms[0].rate, 0.25);
});

test('a blank percent field falls back to the default rather than sending none', async () => {
  const h = load({ specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50 }] });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '50';
  row.querySelector('.js-dataset-blank-columns').value = 'systolic';

  await change(h, row, '.js-dataset-blank-columns');
  await settle();

  // A rate is required at save, so sending none would be rejected by the
  // server for a spec the instructor plainly meant.
  assert.equal(lastSpec(h).transforms[0].rate, 0.1);
  assert.equal(row.querySelector('.js-dataset-blank-percent').value, '10');
});

test('clearing the columns field clears the step', async () => {
  const h = load({
    specs: [{
      file: 'cases.csv', kind: 'rowSample', sampleSize: 50,
      transforms: [{ kind: 'missingValues', columns: ['systolic'], rate: 0.25 }],
    }],
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '50';
  row.querySelector('.js-dataset-blank-columns').value = '   ';

  await change(h, row, '.js-dataset-blank-columns');
  await settle();

  // Empty means "no step", the same way an empty stratum box means "no
  // stratification" — the field carries whether the thing exists.
  assert.deepEqual(lastSpec(h).transforms, []);
});

// ── Not clobbering what the panel does not own ──────────────────────────────

test('a row-count edit preserves the step it was not asked about', async () => {
  const h = load({
    specs: [{
      file: 'cases.csv', kind: 'rowSample', sampleSize: 50,
      transforms: [{ kind: 'missingValues', columns: ['systolic'], rate: 0.25 }],
    }],
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '90';
  row.querySelector('.js-dataset-blank-columns').value = 'systolic';
  row.querySelector('.js-dataset-blank-percent').value = '25';

  await change(h, row, '.js-dataset-size');
  await settle();

  const spec = lastSpec(h);
  assert.equal(spec.sampleSize, 90);
  assert.deepEqual(spec.transforms[0].columns, ['systolic']);
  assert.equal(spec.transforms[0].rate, 0.25);
});

test('a spec the panel cannot represent is left intact by an unrelated edit', async () => {
  // Two steps: more than this control has fields for. Rendering it into the one
  // pair of fields and saving would silently drop the second.
  const authored = [
    { kind: 'missingValues', columns: ['systolic'], rate: 0.25 },
    { kind: 'missingValues', columns: ['ward'], rate: 0.5 },
  ];
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50, transforms: authored }],
  });
  const row = h.rows[0];
  // First paint is server-side: the row arrives with the fields already
  // disabled, because `SupportFileRow.datasetTransformsEditable` said the panel
  // cannot represent this spec. (That half is pinned in Swift; what matters
  // here is that the JS honours it.)
  row.querySelector('.js-dataset-blank-columns').disabled = true;
  row.querySelector('.js-dataset-blank-percent').disabled = true;

  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '90';
  await change(h, row, '.js-dataset-size');
  await settle();

  const spec = lastSpec(h);
  assert.equal(spec.sampleSize, 90, 'the edit still lands');
  assert.deepEqual(spec.transforms, authored, 'both steps survive it');
});

test('an unknown transform kind is preserved, not narrowed away', async () => {
  // The kind a future release adds, seen by a panel that predates it.
  const authored = [{ kind: 'formatNoise', columns: ['admitted'], rate: 0.3 }];
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50, transforms: authored }],
  });
  const row = h.rows[0];
  // Again server-rendered: an unrecognised kind is not representable either.
  row.querySelector('.js-dataset-blank-columns').disabled = true;
  row.querySelector('.js-dataset-blank-percent').disabled = true;

  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '90';
  await change(h, row, '.js-dataset-size');
  await settle();

  assert.deepEqual(lastSpec(h).transforms, authored);
});

test('a re-render disables the fields for a spec the panel cannot represent', async () => {
  // The paint that follows a successful write, which is the one place the JS
  // (rather than Leaf) decides the disabled state.
  const authored = [
    { kind: 'missingValues', columns: ['systolic'], rate: 0.25 },
    { kind: 'missingValues', columns: ['ward'], rate: 0.5 },
  ];
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 50, transforms: authored }],
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-blank-columns').disabled = true;
  row.querySelector('.js-dataset-blank-percent').disabled = true;
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '90';

  await change(h, row, '.js-dataset-size');
  await settle();

  // Still disabled, and still not showing half of a two-step spec.
  assert.equal(row.querySelector('.js-dataset-blank-columns').disabled, true);
  assert.equal(row.querySelector('.js-dataset-blank-columns').value, '');
});

// ── The estimates disclosure ────────────────────────────────────────────────

const sampleBlock = (spec) => ({
  file: spec.file,
  overlap: {
    poolRows: 6388,
    rowsPerStudent: spec.sampleSize || 6388,
    expectedSharedRows: 39.1,
    sharedFraction: 0.078,
    worstPairSharedRows: 63.2,
    mostCopyableStratum: spec.stratumColumn
      ? { value: 'D', poolRows: 5, rowsPerStudent: 2, sharedFraction: 0.4 }
      : null,
  },
  headlines: [
    { measure: 'wasserstein', column: 'systolic', median: 0.037, worst: 0.061 },
    { measure: 'totalVariation', column: 'ward', median: 0.02, worst: 0.05 },
  ],
  divergenceMeasured: true,
  classSize: 100,
});

test('the estimates paint on init from the GET, one line per fact', async () => {
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 500 }],
    diagnostics: sampleBlock,
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  await settle();

  assert.equal(row.querySelector('.js-dataset-diagnostics').hidden, false);
  const text = row.querySelector('.js-dataset-diagnostics-body').textContent;
  assert.match(text, /39 of their 500 rows \(7\.8%\)/);
  assert.match(text, /unluckiest pair in a class of 100 shares about 63/);
  assert.match(text, /systolic sits about 0\.04 SD/);
  assert.match(text, /any two students within about 0\.12 SD/);
  assert.match(text, /ward sits about 0\.02 total-variation/);
  assert.equal(h.puts.length, 0, 'the first paint is a read, not a write');
});

test('a stratified block names its most copyable category', async () => {
  const h = load({
    specs: [{
      file: 'cases.csv', kind: 'stratifiedSample', sampleSize: 500, stratumColumn: 'ward',
    }],
    diagnostics: sampleBlock,
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  await settle();

  const text = row.querySelector('.js-dataset-diagnostics-body').textContent;
  assert.match(text, /Most copyable category: "D"/);
  assert.match(text, /2 of the same 5 pool rows \(40% shared\)/);
});

test('the estimates repaint from the PUT response when a parameter changes', async () => {
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 500 }],
    diagnostics: (spec) => ({
      ...sampleBlock(spec),
      overlap: { ...sampleBlock(spec).overlap, rowsPerStudent: spec.sampleSize },
    }),
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '900';
  await change(h, row, '.js-dataset-size');
  await settle();

  const text = row.querySelector('.js-dataset-diagnostics-body').textContent;
  assert.match(text, /of their 900 rows/, 'the numbers follow the saved edit');
});

test('a row without an estimate block hides the disclosure', async () => {
  // The server sends no block for an unreadable file (and for an unmarked
  // one); an empty disclosure would read as a broken panel.
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 500 }],
    diagnostics: null,
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  await settle();

  assert.equal(row.querySelector('.js-dataset-diagnostics').hidden, true);
});

test('an unmeasured divergence says so instead of showing nothing', async () => {
  const h = load({
    specs: [{ file: 'cases.csv', kind: 'rowSample', sampleSize: 500 }],
    diagnostics: (spec) => ({
      ...sampleBlock(spec), headlines: [], divergenceMeasured: false,
    }),
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  await settle();

  const text = row.querySelector('.js-dataset-diagnostics-body').textContent;
  assert.match(text, /not measured — the file is too large/);
});

test('a stratified spec keeps its kind when only the blanking changes', async () => {
  const h = load({
    specs: [{
      file: 'cases.csv', kind: 'stratifiedSample', sampleSize: 50, stratumColumn: 'ward',
    }],
  });
  const row = h.rows[0];
  row.querySelector('.js-dataset-toggle').checked = true;
  row.querySelector('.js-dataset-size').value = '50';
  row.querySelector('.js-dataset-stratum').value = 'ward';
  row.querySelector('.js-dataset-blank-columns').value = 'systolic';

  await change(h, row, '.js-dataset-blank-columns');
  await settle();

  const spec = lastSpec(h);
  assert.equal(spec.kind, 'stratifiedSample');
  assert.equal(spec.stratumColumn, 'ward');
  assert.equal(spec.transforms.length, 1);
});
