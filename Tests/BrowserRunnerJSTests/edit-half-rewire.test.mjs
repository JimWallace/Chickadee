// Unit tests for the re-wire of the workbench edit half (#1957).
//
// On the merged workbench, an in-place save swaps the edit half for a fresh
// server render. The fresh markup has no running code: a `<script>` that the
// parser makes does not run, and the CSP blocks inline scripts. Before #1957
// nothing wired the new half, so the suite table came back with no rows and
// every editor in the half was dead. There was no error, and a reload made it
// all work again, which is why it read as a flaky page.
//
// surface-swap.js now calls `ChickadeeEditPage.init()` after the swap
// (pinned in swap-half.test.mjs). This file pins the other side of that hook:
//
//   * init() wires a NEW render, and does nothing on a render it has wired;
//   * a listener on document or <body>, which a swap keeps, is bound once;
//   * every module that init() calls is idempotent in the same way, because
//     init() runs on the first load AND after each swap.
//
// Each module is loaded into its own vm context against a small stub DOM.
// The stubs model only what a module touches, and element IDENTITY is the
// point: a swap is "the same id, a different element".

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const read = (file) => fs.readFile(path.resolve(file), 'utf8');
const editPageSource = await read('Public/assignment-edit-page.js');
const modalSource = await read('Public/test-editor-modal.js');
const supportFilesSource = await read('Public/support-files.js');
const sectionInputsSource = await read('Public/section-inputs-editor.js');
const globalInputsSource = await read('Public/global-inputs-editor.js');
const achievementsSource = await read('Public/achievements-editor.js');
const languageSource = await read('Public/authoring-language.js');
const familyEditorSource = await read('Public/pattern-family-editor.js');
const inputsCoreSource = await read('Public/inputs-editor-core.js');

/// An element stub that records its listeners.
function el(id = '', extra = {}) {
  return {
    id,
    handlers: {},
    style: {},
    hidden: false,
    children: [],
    classList: { add() {}, remove() {}, contains: () => false },
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
    listeners(type) { return (this.handlers[type] || []).length; },
    setAttribute() {},
    getAttribute() { return null; },
    appendChild(c) { this.children.push(c); return c; },
    querySelector: () => null,
    querySelectorAll: () => [],
    closest: () => null,
    focus() {},
    ...extra,
  };
}

// ── assignment-edit-page.js: ChickadeeEditPage.init() ───────────────────────

/// Load the edit page with every module it wires stubbed to count its calls.
function loadEditPage() {
  const calls = {};
  const count = (name) => { calls[name] = (calls[name] || 0) + 1; };
  const body = el('body');
  const modalOpens = [];
  let seed = el('suite-state-seed');
  let familyBodies = [];

  const doc = {
    body,
    getElementById: (id) => (id === 'suite-state-seed' ? seed : null),
    querySelector: (sel) => (sel === '[data-assignment-id]'
      ? { getAttribute: () => 'ABC123' } : null),
    querySelectorAll: (sel) => (sel === '[id="family-editor-body"]' ? familyBodies : []),
  };
  const sandbox = { document: doc, JSON, Array, Error };
  sandbox.window = sandbox;
  sandbox.ChickadeeUI = { getCsrfToken: () => 'tok' };
  sandbox.initSuiteTable = () => {
    count('initSuiteTable');
    return {
      addExistingScript() {}, saveFamiliesViaSuite() {}, saveChecksViaSuite() {},
      saveScriptViaSuite() {}, getItems: () => [],
    };
  };
  sandbox.initPatternFamilyEditor = () => { count('initPatternFamilyEditor'); return {}; };
  sandbox.initTestEditorModal = () => {
    count('initTestEditorModal');
    return { open: (o) => modalOpens.push(o), close() {} };
  };
  sandbox.initSupportFiles = () => count('initSupportFiles');
  sandbox.initSectionInputsEditor = () => count('initSectionInputsEditor');
  sandbox.initGlobalInputsEditor = () => count('initGlobalInputsEditor');
  sandbox.initAchievementsEditor = () => count('initAchievementsEditor');
  vm.createContext(sandbox);
  vm.runInContext(editPageSource, sandbox);

  return {
    sandbox, calls, body, modalOpens,
    /// What a swap does to the page, as far as init() can tell: a new seed.
    swapRender() { seed = el('suite-state-seed'); },
    setFamilyBodies(list) { familyBodies = list; },
  };
}

const WIRED_BY_INIT = [
  'initSuiteTable', 'initPatternFamilyEditor', 'initTestEditorModal', 'initSupportFiles',
  'initSectionInputsEditor', 'initGlobalInputsEditor', 'initAchievementsEditor',
];

test('the edit page exports one re-wire hook, and the first load wires every editor once', () => {
  const h = loadEditPage();
  assert.equal(typeof h.sandbox.ChickadeeEditPage?.init, 'function',
    'surface-swap.js has nothing to call after a swap without ChickadeeEditPage.init');
  for (const name of WIRED_BY_INIT) assert.equal(h.calls[name], 1, name);
});

test('init() on a render it has wired does nothing', () => {
  const h = loadEditPage();
  h.sandbox.ChickadeeEditPage.init();
  h.sandbox.ChickadeeEditPage.init();
  for (const name of WIRED_BY_INIT) {
    assert.equal(h.calls[name], 1, `${name} ran twice on one render, so its listeners stack`);
  }
});

test('init() on a swapped render wires every editor again', () => {
  const h = loadEditPage();
  h.swapRender();
  h.sandbox.ChickadeeEditPage.init();
  for (const name of WIRED_BY_INIT) {
    assert.equal(h.calls[name], 2, `${name} was not re-run, so its part of the new half is dead`);
  }
});

test('the script-edit listener on <body> is bound once, and a click opens one editor', () => {
  const h = loadEditPage();
  h.swapRender();
  h.sandbox.ChickadeeEditPage.init();
  h.swapRender();
  h.sandbox.ChickadeeEditPage.init();

  assert.equal(h.body.listeners('click'), 1, '<body> survives a swap; a second listener opens a second editor');
  const button = { getAttribute: (n) => (n === 'data-filename' ? 'test_a.py' : null) };
  h.body.handlers.click[0]({ target: { closest: (sel) => (sel === '.js-suite-edit-btn' ? button : null) } });
  assert.equal(h.modalOpens.length, 1);
  assert.equal(h.modalOpens[0].editing.id, 'test_a.py');
});

test('a family-editor body parked by an earlier render is removed before the editor wires', () => {
  const h = loadEditPage();
  const removed = [];
  const inRender = el('family-editor-body', { parentNode: el('section'), remove: () => removed.push('in-render') });
  const parked = el('family-editor-body', { parentNode: h.body, remove: () => removed.push('parked') });
  h.setFamilyBodies([inRender, parked]);

  h.swapRender();
  h.sandbox.ChickadeeEditPage.init();

  assert.deepEqual(removed, ['parked'],
    'two elements with one id: the editor would find its fields in whichever comes first');
});

// ── test-editor-modal.js: the "+ Add Test" buttons of a new render ──────────

function loadModal() {
  const byID = {};
  const body = el('body', {
    appendChild(c) { if (c.id) byID[c.id] = c; return c; },
  });
  const docHandlers = {};
  let addTestButtons = [];
  // The shell builds its chrome with innerHTML, then looks each part up by id.
  ['test-editor-type', 'test-editor-type-row', 'test-editor-desc', 'test-editor-title',
    'test-editor-body', 'test-editor-status', 'test-editor-save', 'test-editor-cancel',
    'test-editor-close'].forEach((id) => { byID[id] = el(id); });

  const doc = {
    body,
    createElement: (tag) => el(tag),
    getElementById: (id) => byID[id] || null,
    addEventListener(type, fn) { (docHandlers[type] ||= []).push(fn); },
    querySelector: () => null,
    querySelectorAll: (sel) => (sel === '.js-section-add-test-btn' ? addTestButtons : []),
  };
  const sandbox = { document: doc, JSON, Object, Error, setTimeout: (fn) => fn() };
  sandbox.window = sandbox;
  sandbox.ChickadeeUI = {
    setStatus() {},
    escapeHtml: (s) => String(s == null ? '' : s),
    escapeAttr: (s) => String(s == null ? '' : s),
  };
  sandbox.ChickadeeLanguage = { checkKindUnsupportedReason: () => null };
  vm.createContext(sandbox);
  vm.runInContext(modalSource, sandbox);
  return {
    sandbox, body, docHandlers,
    setButtons(list) { addTestButtons = list; },
  };
}

function addTestButton(replaced) {
  return {
    getAttribute: (n) => (n === 'data-section-id' ? 'S1' : null),
    parentNode: { replaceChild: (fresh, old) => replaced.push({ fresh, old }) },
  };
}

test('a second shell init upgrades the "+ Add Test" buttons of the new render', () => {
  const h = loadModal();
  const first = h.sandbox.initTestEditorModal({ csrfToken: 't' });
  const bodyListeners = h.body.listeners('click');
  const keydown = (h.docHandlers.keydown || []).length;

  const replaced = [];
  const button = addTestButton(replaced);
  h.setButtons([button]);
  const second = h.sandbox.initTestEditorModal({ csrfToken: 't' });

  assert.equal(replaced.length, 1,
    'a swapped half brings plain "+ Add Test" buttons; left as they are, they do nothing');
  assert.equal(replaced[0].old, button);
  assert.equal(replaced[0].fresh.className.includes('add-test-details'), true);
  assert.equal(second, first, 'the shell is built once per document');
  assert.equal(h.body.listeners('click'), bodyListeners, 'no second set of <body> listeners');
  assert.equal((h.docHandlers.keydown || []).length, keydown, 'no second Escape listener');
});

// ── support-files.js: one Remove listener, estimates repainted ──────────────

function loadSupportFiles() {
  const body = el('body');
  const fetches = [];
  const datasetGets = [];
  const elements = {
    'add-support-file-btn': el('add-support-file-btn'),
    'support-file-upload-input': el('support-file-upload-input'),
    'support-file-upload-status': el('support-file-upload-status'),
  };
  const doc = {
    body,
    getElementById: (id) => elements[id] || null,
    querySelectorAll: () => [],
  };
  const sandbox = {
    document: doc, Promise, JSON, Error,
    fetch: (url, opts) => {
      fetches.push({ url, opts });
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('') });
    },
  };
  sandbox.ChickadeeUI = {
    setStatus() {},
    confirmAction: () => Promise.resolve(true),
    showActionError() {},
    fetchJSON: (url, opts) => {
      if (!opts || !opts.method) datasetGets.push(url);
      return Promise.resolve({ datasets: [], diagnostics: [] });
    },
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  vm.createContext(sandbox);
  vm.runInContext(supportFilesSource, sandbox);

  const changed = [];
  function init(tag) {
    sandbox.window.initSupportFiles({
      csrfToken: 'tok-' + tag,
      uploadURL: () => '/instructor/abc/scripts',
      deleteURL: (name) => '/instructor/abc/scripts/' + name + '?from=' + tag,
      datasetsURL: () => '/instructor/abc/datasets',
      onChange: () => changed.push(tag),
    });
  }
  return { body, fetches, datasetGets, changed, init };
}

async function settle() {
  for (let i = 0; i < 6; i += 1) await new Promise((r) => setTimeout(r, 0));
}

test('a re-init binds no second Remove listener, and the one it has uses the latest config', async () => {
  const h = loadSupportFiles();
  h.init('load');
  h.init('swap');

  assert.equal(h.body.listeners('click'), 1,
    'two listeners on <body> ask twice and send two DELETEs for one click');
  assert.equal(h.body.listeners('change'), 1);

  const btn = { getAttribute: (n) => (n === 'data-filename' ? 'data.csv' : null) };
  await h.body.handlers.click[0]({ target: { closest: (sel) => (sel === '.js-support-file-delete-btn' ? btn : null) } });
  await settle();

  const deletes = h.fetches.filter((f) => f.opts && f.opts.method === 'DELETE');
  assert.equal(deletes.length, 1);
  assert.equal(deletes[0].url, '/instructor/abc/scripts/data.csv?from=swap');
  assert.equal(deletes[0].opts.headers['x-csrf-token'], 'tok-swap');
  assert.deepEqual(h.changed, ['swap']);
});

test('a re-init repaints the dataset estimates of the new rows', async () => {
  const h = loadSupportFiles();
  h.init('load');
  h.init('swap');
  await settle();
  assert.equal(h.datasetGets.length, 2,
    'the server renders the estimate chips empty; only this GET fills them');
});

// ── The three editors that start themselves ─────────────────────────────────

function loadSelfStarting(source, doc, extra = {}) {
  const sandbox = { document: { readyState: 'complete', addEventListener() {}, ...doc }, JSON, Array, Promise, Error, ...extra };
  sandbox.window = sandbox;
  sandbox.ChickadeeUI = {
    getCsrfToken: () => 'tok', setStatus() {}, notifyWorkbench() {},
    escapeHtml: (s) => String(s), extractErrorMessage: () => '',
  };
  sandbox.ChickadeeInputsCore ||= {
    createEditor: () => ({ buildPayload: () => null, refreshAllRows() {}, addEmptyRow() {} }),
    makeDebouncedSaver: () => ({ schedule() {}, flush: () => Promise.resolve() }),
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return sandbox;
}

test('section inputs: init is exported, wires a new form, and never wires a form twice', () => {
  const tbody = el('tbody');
  const makeForm = () => el('form', { querySelector: () => tbody, contains: () => true });
  const addButton = () => el('button', { getAttribute: () => 'S1' });
  let forms = [makeForm()];
  let buttons = [addButton()];
  const sandbox = loadSelfStarting(sectionInputsSource, {
    querySelectorAll: (sel) => (sel === 'form.section-vars-form' ? forms
      : sel === 'button.js-section-var-add' ? buttons : []),
    querySelector: () => null,
  });
  assert.equal(typeof sandbox.initSectionInputsEditor, 'function');

  const [oldForm] = forms;
  const [oldButton] = buttons;
  sandbox.initSectionInputsEditor();
  assert.equal(oldForm.listeners('input'), 1, 'a second init stacked a second auto-save');
  assert.equal(oldButton.listeners('click'), 1, 'a second init stacked a second "+ Add Input"');

  forms = [makeForm()];
  buttons = [addButton()];
  sandbox.initSectionInputsEditor();
  assert.equal(forms[0].listeners('input'), 1, 'the swapped-in form was not wired');
  assert.equal(buttons[0].listeners('click'), 1, 'the swapped-in "+ Add Input" was not wired');
});

test('global inputs: init is exported, wires a new panel, and never wires a panel twice', () => {
  const makeBlock = () => el('global-inputs-block', {
    querySelector: () => el('tbody'),
    getAttribute: (n) => (n === 'data-assignment-id' ? 'ABC123' : null),
  });
  let block = makeBlock();
  const sandbox = loadSelfStarting(globalInputsSource, {
    getElementById: (id) => (id === 'global-inputs-block' ? block : null),
  });
  assert.equal(typeof sandbox.initGlobalInputsEditor, 'function');

  const oldBlock = block;
  sandbox.initGlobalInputsEditor();
  assert.equal(oldBlock.listeners('input'), 1, 'a second init stacked a second auto-save');

  block = makeBlock();
  sandbox.initGlobalInputsEditor();
  assert.equal(block.listeners('input'), 1, 'the swapped-in panel was not wired');
});

test('achievements: init is exported, wires and loads a new panel, and never wires a panel twice', () => {
  const loads = [];
  const template = el('achievement-editor-template');
  const condTemplate = el('achievement-condition-template', { content: { querySelectorAll: () => [] } });
  const makeBlock = () => el('achievements-block', {
    querySelector: () => el('tbody'),
    getAttribute: (n) => (n === 'data-assignment-id' ? 'ABC123' : null),
  });
  let block = makeBlock();
  const ids = () => ({
    'achievements-block': block,
    'achievement-editor-template': template,
    'achievement-condition-template': condTemplate,
  });
  const sandbox = loadSelfStarting(achievementsSource, {
    getElementById: (id) => ids()[id] || null,
    querySelectorAll: () => [],
  }, {
    ChickadeeAchievementsCore: { signalMetaFromOptions: () => ({}) },
    fetch: (url) => { loads.push(url); return new Promise(() => {}); },
  });
  assert.equal(typeof sandbox.initAchievementsEditor, 'function');

  const oldBlock = block;
  sandbox.initAchievementsEditor();
  assert.equal(oldBlock.listeners('click'), 1, 'a second init stacked a second row handler');
  assert.equal(loads.length, 1);

  block = makeBlock();
  sandbox.initAchievementsEditor();
  assert.equal(block.listeners('click'), 1, 'the swapped-in panel was not wired');
  assert.equal(loads.length, 2, 'the swapped-in panel was not loaded');
});

// ── authoring-language.js: a new seed is read again ─────────────────────────

test('the language facts follow the seed element, so a save that changes the language is seen', () => {
  const python = { textContent: JSON.stringify({ name: 'python', displayName: 'Python' }) };
  const r = { textContent: JSON.stringify({ name: 'r', displayName: 'R', trueLiteral: 'TRUE' }) };
  let seed = python;
  const sandbox = { document: { getElementById: (id) => (id === 'assignment-language-seed' ? seed : null) }, JSON };
  vm.createContext(sandbox);
  vm.runInContext(languageSource, sandbox);
  const lang = sandbox.ChickadeeLanguage;

  assert.equal(lang.label(), 'Python');
  assert.equal(lang.facts(), lang.facts(), 'one render, one parse');

  seed = r;
  assert.equal(lang.label(), 'R',
    'a swapped half carries a new seed; the old facts would render R values as Python');
  assert.equal(lang.facts().trueLiteral, 'TRUE');
});

// ── pattern-family-editor.js: the old editor's worker is stopped ────────────

/// The family editor under a stub DOM in which every id exists, with a fake
/// Worker that records `terminate()`. Timers are queued, not run, so a test
/// runs only the auto-compute debounce and never the worker's own timeout,
/// which would terminate the worker for an unrelated reason.
function loadFamilyEditor() {
  const elements = {};
  const stub = (tag = 'div') => el(tag, {
    value: '', textContent: '', innerHTML: '', dataset: {}, attrs: {},
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    setAttribute(n, v) { this.attrs[n] = v; },
    getAttribute(n) { return this.attrs[n] ?? null; },
    removeAttribute() {}, insertBefore: (c) => c, removeChild: (c) => c, remove() {}, select() {},
  });
  const workers = [];
  const timers = [];
  const seed = {
    textContent: JSON.stringify({
      name: 'python', displayName: 'Python', autoComputeWorker: '/python-eval-worker.js',
    }),
  };
  const solution = { cells: [{ cell_type: 'code', source: 'def f(x):\n    return x\n' }] };
  const ctx = {
    JSON, Array, Object, Math, Set, Map, Promise, RegExp, String, Boolean, Number, Error,
    encodeURIComponent,
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearTimeout() {},
    fetch: () => Promise.resolve({ ok: true, json: () => Promise.resolve(solution) }),
    Worker: class {
      constructor(url) { this.url = url; this.terminated = 0; workers.push(this); }
      addEventListener() {}
      postMessage() {}
      terminate() { this.terminated += 1; }
    },
    document: {
      getElementById: (id) => (id === 'assignment-language-seed' ? seed : (elements[id] ||= stub())),
      querySelector: () => null,
      querySelectorAll: () => [],
      createElement: (tag) => stub(tag),
      addEventListener() {},
      body: stub('body'),
    },
  };
  ctx.window = ctx;
  ctx.ChickadeeUI = {
    escapeHtml: (s) => String(s), escapeAttr: (s) => String(s), getCsrfToken: () => 't',
    extractErrorMessage: () => '', setStatus() {}, confirmAction: () => Promise.resolve(true),
    fetchJSON: () => new Promise(() => {}),
  };
  vm.createContext(ctx);
  vm.runInContext(languageSource, ctx);
  vm.runInContext(familyEditorSource, ctx);

  const config = {
    csrfToken: 't', initialFamilies: [],
    urls: { solutionNotebook: () => '/s', scanNotebook: () => '/scan', computeExpected: () => '/c' },
  };

  /// Edit one argument cell of a case row. That starts one auto-compute,
  /// which boots the editor's worker.
  async function autoComputeOnce() {
    elements['family-kind'].value = 'boundary_equality';
    elements['family-function'].value = 'f';
    elements['family-params'].value = 'x';
    const expected = stub('input');
    const arg = stub('input');
    arg.value = '1';
    arg.classList = { add() {}, remove() {}, toggle() {}, contains: (c) => c === 'js-pf-case-arg' };
    const row = stub('tr');
    row.parentElement = stub('tbody');
    row.querySelector = (sel) => (sel === '.js-pf-case-expected' ? expected
      : sel.startsWith('.js-pf-case-arg') ? arg : null);
    arg.closest = (sel) => (sel === 'tr' ? row : null);
    (elements['family-cases-body'].handlers.input || []).forEach((fn) => fn({ target: arg }));
    timers.splice(0).filter((t) => t.ms === 400).forEach((t) => t.fn());
    await settle();
  }

  return { init: () => ctx.initPatternFamilyEditor(config), autoComputeOnce, workers };
}

test('a second family-editor init stops the auto-compute worker of the editor it replaces', async () => {
  const h = loadFamilyEditor();
  h.init();
  await h.autoComputeOnce();
  assert.equal(h.workers.length, 1, 'the harness must boot a worker, or this test proves nothing');
  assert.equal(h.workers[0].terminated, 0);

  h.init();

  assert.equal(h.workers[0].terminated, 1,
    'each swap builds a new editor, and the old editor\'s worker holds a booted kernel until it is stopped');
});

// ── The pending-only flush that the swap awaits ─────────────────────────────

test('flushPending sends a save that waits, and sends nothing when none waits', async () => {
  const sandbox = { setTimeout, clearTimeout, Promise };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(inputsCoreSource, sandbox);
  let saves = 0;
  const saver = sandbox.ChickadeeInputsCore.makeDebouncedSaver(
    () => { saves += 1; return Promise.resolve(); }, 10000);

  await saver.flushPending();
  assert.equal(saves, 0,
    'the swap calls this on every refresh, and a Global Inputs save also marks the notebook stale');

  saver.schedule();
  await saver.flushPending();
  assert.equal(saves, 1, 'a value typed just before the swap must reach the server');
});

test('section inputs expose the pending-only flush, and it reaches every form', async () => {
  const pending = [];
  const forms = ['a', 'b'].map((id) => el('form', { id, querySelector: () => el('tbody') }));
  let made = 0;
  const sandbox = loadSelfStarting(sectionInputsSource, {
    querySelectorAll: (sel) => (sel === 'form.section-vars-form' ? forms : []),
    querySelector: () => null,
  }, {
    ChickadeeInputsCore: {
      createEditor: () => ({ buildPayload: () => null, refreshAllRows() {}, addEmptyRow() {} }),
      makeDebouncedSaver: () => {
        const form = forms[made++];
        return {
          schedule() {},
          flush: () => Promise.resolve(),
          flushPending: () => { pending.push(form.id); return Promise.resolve(); },
        };
      },
    },
  });

  await sandbox.chickadeeFlushPendingSectionVars();
  assert.deepEqual(pending, ['a', 'b']);
});
