// Unit tests for Public/test-editor-modal.js — the one "+ Add Test" shell.
//
// It had none, and it carries a fix whose failure mode is a blank form. When
// editing, the mechanism and kind are authoritative from the edit payload; the
// hidden type dropdown's leftover value must not decide which renderer runs.
// Before that, editing a check or a script resolved to whatever the dropdown
// last showed (default `family`), so the shell called reset() instead of
// populate() and the modal opened empty — the author's existing test appearing
// to have lost its contents. That is pinned first here.
//
// The other invariant worth holding is cleanup(). A renderer owns a CodeMirror
// instance or a kernel worker; the shell must tear the old one down when the
// body morphs to another mechanism and when the modal closes, or those leak
// for the life of the page.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/test-editor-modal.js'), 'utf8');

function stubEl(id) {
  const el = {
    id,
    textContent: '',
    value: '',
    hidden: false,
    disabled: false,
    style: {},
    classes: new Set(),
    classList: {
      add(...c) { c.forEach((name) => el.classes.add(name)); },
      remove(...c) { c.forEach((name) => el.classes.delete(name)); },
      contains: (name) => el.classes.has(name),
    },
    children: [],
    handlers: {},
    innerHTML: '',
    appendChild(c) { this.children.push(c); return c; },
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
    fire(type, e) { (this.handlers[type] || []).slice().forEach((fn) => fn(e || {})); },
    setAttribute() {},
    getAttribute() { return null; },
    focus() {},
    contains: () => false,
    querySelector: () => null,
    querySelectorAll: () => [],
    closest: () => null,
  };
  return el;
}

function load({ renderers, language = {} } = {}) {
  const els = {};
  const docHandlers = {};
  const bodyHandlers = {};
  const created = [];

  const idFor = (id) => (els[id] ||= stubEl(id));
  // The shell builds its chrome with innerHTML then looks each part up by id.
  ['test-editor-type', 'test-editor-type-row', 'test-editor-desc', 'test-editor-title',
    'test-editor-body', 'test-editor-status', 'test-editor-save', 'test-editor-cancel',
    'test-editor-close'].forEach(idFor);

  const doc = {
    readyState: 'complete',
    body: {
      appendChild(c) { created.push(c); return c; },
      addEventListener(type, fn) { (bodyHandlers[type] ||= []).push(fn); },
    },
    createElement: (tag) => {
      const el = stubEl(tag);
      el.classList = { add: () => {}, remove: () => {}, contains: () => false };
      return el;
    },
    getElementById: (id) => els[id] || null,
    addEventListener(type, fn) { (docHandlers[type] ||= []).push(fn); },
    querySelector: () => null,
    querySelectorAll: () => [],
  };

  const sandbox = {
    document: doc,
    Promise,
    JSON,
    Object,
    Error,
    setTimeout: (fn) => { fn(); return 1; },
    console: { error() {} },
  };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  sandbox.ChickadeeUI = {
    setStatus: (el, text, kind) => { sandbox.lastStatus = { text, kind }; },
    escapeHtml: (s) => String(s == null ? '' : s),
    escapeAttr: (s) => String(s == null ? '' : s),
  };
  sandbox.ChickadeeTestRenderers = renderers || {};
  sandbox.ChickadeeLanguage = {
    checkKindUnsupportedReason: language.checkKindUnsupportedReason || (() => null),
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const api = sandbox.initTestEditorModal({ csrfToken: 't', getSectionID: () => '' });
  return { api, els, sandbox, docHandlers, bodyHandlers, created };
}

/// A renderer that records every call the shell makes on it.
function recordingRenderer(name, log) {
  return {
    mount: () => log.push(name + ':mount'),
    reset: (kind) => log.push(name + ':reset:' + kind),
    populate: (item) => log.push(name + ':populate:' + (item && item.id)),
    readSpec: () => ({}),
    persistAndSync: () => Promise.resolve(),
    cleanup: () => log.push(name + ':cleanup'),
    title: (editing) => (editing ? 'Edit ' + name : 'Add ' + name),
  };
}

function renderers(log) {
  return {
    family: recordingRenderer('family', log),
    check: recordingRenderer('check', log),
    script: recordingRenderer('script', log),
  };
}

// ── Editing must populate, not reset ────────────────────────────────────────

test('editing a check populates it, whatever the hidden dropdown last showed', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });
  h.els['test-editor-type'].value = 'boundary_equality';   // a FAMILY kind, stale

  h.api.open({ editing: { mechanism: 'check', id: 'chk1', item: { id: 'chk1', kind: 'variable_exists' } } });

  assert.ok(log.includes('check:populate:chk1'),
    'the edit payload decides the renderer, not the leftover dropdown value');
  assert.ok(!log.some((l) => l.endsWith(':reset:boundary_equality')),
    'the modal must not open blank on an existing test');
});

test('editing a script populates the script renderer', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });
  h.els['test-editor-type'].value = 'boundary_equality';

  h.api.open({ editing: { mechanism: 'script', id: 's1', item: { id: 's1' } } });
  assert.ok(log.includes('script:populate:s1'));
});

test('opening fresh resets to the chosen kind rather than populating', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });

  h.api.open({ mechanism: 'family', kind: 'approximate_equality', presetType: true });
  assert.ok(log.includes('family:reset:approximate_equality'));
  assert.ok(!log.some((l) => l.includes(':populate:')));
});

test('the renderer mounts once, then is reused across opens', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });

  h.api.open({ mechanism: 'family', kind: 'boundary_equality', presetType: true });
  h.api.close();
  h.api.open({ mechanism: 'family', kind: 'boundary_equality', presetType: true });

  assert.equal(log.filter((l) => l === 'family:mount').length, 1);
});

// ── Teardown ────────────────────────────────────────────────────────────────

test('closing tears the active renderer down', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });

  h.api.open({ mechanism: 'script', kind: 'script', presetType: true });
  log.length = 0;
  h.api.close();

  assert.deepEqual(log, ['script:cleanup'], 'a CodeMirror or kernel worker must not outlive the modal');
  assert.equal(h.els['test-editor-body'] && true, true);
});

test('switching mechanism tears the previous renderer down first', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });

  h.api.open({ mechanism: 'script', kind: 'script', presetType: true });
  log.length = 0;
  h.api.open({ mechanism: 'family', kind: 'boundary_equality', presetType: true });

  assert.equal(log[0], 'script:cleanup', 'the old renderer is cleaned up before the new one runs');
  assert.ok(log.includes('family:reset:boundary_equality'));
});

test('a renderer whose cleanup throws does not block the close', () => {
  const log = [];
  const rs = renderers(log);
  rs.script.cleanup = () => { throw new Error('boom'); };
  const h = load({ renderers: rs });

  h.api.open({ mechanism: 'script', kind: 'script', presetType: true });
  h.api.close();   // must not throw
});

// ── Degraded cases ──────────────────────────────────────────────────────────

test('a missing renderer says so instead of showing a blank body', () => {
  const log = [];
  const rs = renderers(log);
  delete rs.check;
  const h = load({ renderers: rs });

  h.api.open({ mechanism: 'check', kind: 'variable_exists', presetType: true });

  assert.equal(h.sandbox.lastStatus.kind, 'error');
  assert.match(h.sandbox.lastStatus.text, /unavailable/i);
});

// ── The type picker ─────────────────────────────────────────────────────────

test('the type picker is hidden when editing and when the type was preset', () => {
  const log = [];
  const h = load({ renderers: renderers(log) });
  const row = h.els['test-editor-type-row'];

  h.api.open({ editing: { mechanism: 'check', id: 'c', item: { id: 'c', kind: 'variable_exists' } } });
  assert.equal(row.style.display, 'none');

  h.api.open({ mechanism: 'family', kind: 'boundary_equality', presetType: true });
  assert.equal(row.style.display, 'none');

  h.api.open({ mechanism: 'family', kind: 'boundary_equality' });
  assert.equal(row.style.display, 'flex', 'without a preset the picker is the fallback');
});

// ── The catalog ─────────────────────────────────────────────────────────────

test('every catalog entry names one of the three renderer mechanisms', () => {
  const h = load({ renderers: renderers([]) });
  const catalog = h.sandbox.ChickadeeTestEditorCatalog;
  assert.ok(catalog.length > 0, 'an empty catalog would make every assertion here vacuous');

  for (const group of catalog) {
    assert.ok(group.group, 'each group is labelled for the instructor');
    assert.ok(group.items.length > 0);
    for (const item of group.items) {
      assert.ok(['family', 'check', 'script'].includes(item.mechanism),
        `${item.value} names an unknown mechanism ${item.mechanism}`);
      assert.ok(item.label && item.value);
    }
  }
});

// A kind the assignment's language cannot save is DISABLED with its reason
// rather than hidden (#1290) — hiding would leave the instructor wondering.
// Only check kinds are ever filtered: all pattern kinds render in every
// language.
test('unsupported check kinds are asked about; family kinds never are', () => {
  const asked = [];
  const h = load({
    renderers: renderers([]),
    language: { checkKindUnsupportedReason: (v) => { asked.push(v); return v === 'figure_count' ? 'Lua has no plotting library' : null; } },
  });

  const catalog = h.sandbox.ChickadeeTestEditorCatalog;
  const checkKinds = catalog.flatMap((g) => g.items).filter((i) => i.mechanism === 'check').map((i) => i.value);
  const familyKinds = catalog.flatMap((g) => g.items).filter((i) => i.mechanism === 'family').map((i) => i.value);

  assert.ok(checkKinds.length > 0 && familyKinds.length > 0);
  checkKinds.forEach((k) => assert.ok(asked.includes(k), `check kind ${k} was never checked for support`));
  familyKinds.forEach((k) => assert.ok(!asked.includes(k), `family kind ${k} must not be filtered`));
});
