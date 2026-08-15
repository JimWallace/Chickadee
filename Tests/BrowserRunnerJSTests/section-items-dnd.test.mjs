// Unit tests for Public/section-items-dnd.js — drag-ordering of the
// instructor dashboard's section item list.
//
// It had none. What it decides is which of three things a finished drag means:
// nothing happened, the order changed within a section, or the item moved to
// another section. Getting that wrong is not a visual bug — it writes the wrong
// order to the server, or writes one when the author only picked a row up and
// put it back.
//
// The mixed-type list is the other reason to pin it: assignments and content
// items interleave, they have DIFFERENT move endpoints, and the reorder body
// must carry the whole tbody in order — both types — or the section's numbering
// comes out wrong for whichever type was omitted.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/section-items-dnd.js'), 'utf8');

// ── A DOM with just enough tree to move rows between tbodies ────────────────

function makeNode(tag, attrs = {}) {
  const node = {
    tagName: tag.toUpperCase(),
    attrs,
    children: [],
    parentElement: null,
    classes: new Set(),
    classList: {
      add: (...c) => c.forEach((x) => node.classes.add(x)),
      remove: (...c) => c.forEach((x) => node.classes.delete(x)),
      contains: (c) => node.classes.has(c),
    },
    style: {},
    getAttribute: (n) => (Object.prototype.hasOwnProperty.call(attrs, n) ? attrs[n] : null),
    setAttribute: (n, v) => { attrs[n] = String(v); },
    getBoundingClientRect: () => ({ top: 0, height: 20 }),
    append(child) {
      if (child.parentElement) child.parentElement.remove(child);
      child.parentElement = node;
      node.children.push(child);
      return child;
    },
    remove(child) { node.children = node.children.filter((c) => c !== child); },
    appendChild(child) { return node.append(child); },
    insertBefore(child, ref) {
      if (child.parentElement) child.parentElement.remove(child);
      child.parentElement = node;
      const at = ref ? node.children.indexOf(ref) : -1;
      if (at < 0) node.children.push(child);
      else node.children.splice(at, 0, child);
      return child;
    },
    get nextSibling() {
      if (!node.parentElement) return null;
      const sibs = node.parentElement.children;
      return sibs[sibs.indexOf(node) + 1] || null;
    },
    querySelectorAll(sel) { return descendants(node).filter((n) => matches(n, sel)); },
    querySelector(sel) { return node.querySelectorAll(sel)[0] || null; },
    closest(sel) {
      let cur = node;
      while (cur) {
        if (matches(cur, sel)) return cur;
        cur = cur.parentElement;
      }
      return null;
    },
  };
  return node;
}

function descendants(node) {
  return node.children.flatMap((c) => [c, ...descendants(c)]);
}

// Only the selectors this module actually uses.
function matches(node, selector) {
  return selector.split(',').map((s) => s.trim()).some((sel) => {
    if (sel === 'tr[data-assignment-id]') return node.tagName === 'TR' && node.getAttribute('data-assignment-id');
    if (sel === 'tr[data-content-item-id]') return node.tagName === 'TR' && node.getAttribute('data-content-item-id');
    if (sel === 'tbody[data-section-id]') return node.tagName === 'TBODY' && node.getAttribute('data-section-id') !== null;
    if (sel === 'tr.section-empty-row') return node.tagName === 'TR' && node.classes.has('section-empty-row');
    if (sel === '.section-block[data-section-id]') return node.classes.has('section-block') && node.getAttribute('data-section-id') !== null;
    if (sel === 'a, img' || sel === 'a' || sel === 'img') return node.tagName === 'A' || node.tagName === 'IMG';
    return false;
  });
}

function row(kind, id) {
  const tr = makeNode('tr', kind === 'assignment'
    ? { 'data-assignment-id': id }
    : { 'data-content-item-id': id });
  return tr;
}

/// Two sections, each a .section-block containing a tbody of rows.
function load({ sections }) {
  const fetches = [];
  const reloads = [];
  const listeners = {};

  const root = makeNode('div');
  const tbodies = {};
  for (const [sectionID, rows] of Object.entries(sections)) {
    const block = makeNode('div', { 'data-section-id': sectionID });
    block.classes.add('section-block');
    const tbody = makeNode('tbody', { 'data-section-id': sectionID });
    rows.forEach((r) => tbody.append(r));
    block.append(tbody);
    root.append(block);
    tbodies[sectionID] = tbody;
  }

  const doc = {
    readyState: 'complete',
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    querySelectorAll: (sel) => root.querySelectorAll(sel),
    querySelector: (sel) => root.querySelector(sel),
  };

  const sandbox = {
    document: doc,
    Promise,
    JSON,
    Array,
    Element: class {},
    fetch: (url, opts) => {
      fetches.push({ url, opts, body: JSON.parse(opts.body) });
      return Promise.resolve({ ok: true, status: 200 });
    },
  };
  sandbox.window = {
    ChickadeeUI: { getCsrfToken: () => 'csrf-token-value' },
    location: { reload: () => reloads.push('reload') },
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  function fire(type, event) {
    if (event && event.target) Object.setPrototypeOf(event.target, sandbox.Element.prototype);
    (listeners[type] || []).slice().forEach((fn) => fn(event || {}));
  }

  return { fetches, reloads, tbodies, root, fire };
}

const noopEvent = () => ({ preventDefault() {}, dataTransfer: { setData() {} } });

async function settle() {
  for (let i = 0; i < 6; i += 1) await Promise.resolve();
}

// ── What a finished drag means ──────────────────────────────────────────────

test('a drag that ends where it started posts nothing', async () => {
  const a = row('assignment', 'a1');
  const b = row('assignment', 'a2');
  const h = load({ sections: { labs: [a, b] } });

  h.fire('dragstart', { target: a, ...noopEvent() });
  h.fire('dragend', {});
  await settle();

  assert.deepEqual(h.fetches, [], 'picking a row up and putting it back is not a change');
  assert.deepEqual(h.reloads, []);
});

test('a reorder inside one section posts the whole tbody in its new order', async () => {
  const a = row('assignment', 'a1');
  const c = row('content', 'c1');
  const b = row('assignment', 'a2');
  const h = load({ sections: { labs: [a, c, b] } });

  h.fire('dragstart', { target: b, ...noopEvent() });
  // Drop b above a: dragover the top half of a.
  h.fire('dragover', { target: a, clientY: 1, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.equal(h.fetches.length, 1);
  assert.equal(h.fetches[0].url, '/instructor/section-items/reorder');
  assert.equal(h.fetches[0].opts.headers['x-csrf-token'], 'csrf-token-value');
  assert.deepEqual(h.fetches[0].body, {
    sectionID: 'labs',
    items: [
      { type: 'assignment', id: 'a2' },
      { type: 'assignment', id: 'a1' },
      { type: 'content', id: 'c1' },
    ],
  }, 'both row types ride the reorder, in the order they now appear');
});

test('dropping below a row places it after, not before', async () => {
  const a = row('assignment', 'a1');
  const b = row('assignment', 'a2');
  const h = load({ sections: { labs: [a, b] } });

  h.fire('dragstart', { target: b, ...noopEvent() });
  h.fire('dragover', { target: a, clientY: 19, preventDefault() {} });   // bottom half
  h.fire('dragend', {});
  await settle();

  assert.deepEqual(h.fetches, [], 'a2 is already after a1 — no change, so no post');
});

// ── Cross-section moves ─────────────────────────────────────────────────────

test('moving an assignment to another section uses the assignment endpoint, then reorders, then reloads', async () => {
  const a = row('assignment', 'a1');
  const other = row('assignment', 'a9');
  const h = load({ sections: { labs: [a], exams: [other] } });

  h.fire('dragstart', { target: a, ...noopEvent() });
  h.fire('dragover', { target: h.tbodies.exams, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.deepEqual(h.fetches.map((f) => f.url), [
    '/instructor/a1/section',
    '/instructor/section-items/reorder',
  ]);
  assert.deepEqual(h.fetches[0].body, { sectionID: 'exams' });
  assert.deepEqual(h.fetches[1].body.items, [
    { type: 'assignment', id: 'a9' },
    { type: 'assignment', id: 'a1' },
  ]);
  assert.deepEqual(h.reloads, ['reload']);
});

// The two types have different move endpoints; sending a content item to the
// assignment one would 404 and lose the move.
test('moving a content item uses the content endpoint', async () => {
  const c = row('content', 'c1');
  const other = row('assignment', 'a9');
  const h = load({ sections: { labs: [c], exams: [other] } });

  h.fire('dragstart', { target: c, ...noopEvent() });
  h.fire('dragover', { target: h.tbodies.exams, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.equal(h.fetches[0].url, '/instructor/content-items/c1/section');
  assert.deepEqual(h.fetches[0].body, { sectionID: 'exams' });
});

test('moving into an empty section hides its placeholder and lands there', async () => {
  const a = row('assignment', 'a1');
  const empty = makeNode('tr');
  empty.classes.add('section-empty-row');
  const h = load({ sections: { labs: [a], exams: [empty] } });

  h.fire('dragstart', { target: a, ...noopEvent() });
  h.fire('dragover', { target: empty, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.equal(empty.style.display, 'none', 'the "no items" row gets out of the way');
  assert.equal(a.parentElement, h.tbodies.exams);
  assert.equal(h.fetches[0].url, '/instructor/a1/section');
});

test('a section with no id at all is the ungrouped section, sent as ""', async () => {
  const a = row('assignment', 'a1');
  const other = row('assignment', 'a9');
  const h = load({ sections: { '': [other], labs: [a] } });

  h.fire('dragstart', { target: a, ...noopEvent() });
  h.fire('dragover', { target: h.tbodies[''], preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.deepEqual(h.fetches[0].body, { sectionID: '' });
});

// ── Setup ───────────────────────────────────────────────────────────────────

test('rows are made draggable and their links are not', () => {
  const a = row('assignment', 'a1');
  const link = makeNode('a');
  a.append(link);
  load({ sections: { labs: [a] } });

  assert.equal(a.getAttribute('draggable'), 'true');
  assert.ok(a.classes.has('assignment-draggable'));
  assert.equal(link.getAttribute('draggable'), 'false',
    'native link drag must not hijack the row drag');
});

test('a drag that never started ignores dragover and dragend', async () => {
  const a = row('assignment', 'a1');
  const h = load({ sections: { labs: [a] } });

  h.fire('dragover', { target: a, clientY: 1, preventDefault() {} });
  h.fire('dragend', {});
  await settle();
  assert.deepEqual(h.fetches, []);
});
