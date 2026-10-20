// Unit tests for the TA lock in Public/section-items-dnd.js (#2743).
//
// Moving an assignment to another section is an instructor action
// (`DashboardRoleFloor.manageSections`). The dashboard marks the page
// `data-assignment-moves="locked"` for a viewer who may not do it. Then an
// assignment row stays in its own section, a content item still moves, and
// the within-section reorder (TA and above) still runs.
//
// The harness is a copy of the one in section-items-dnd.test.mjs, with the
// lock selector and attribute added.

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
    if (sel === '[data-assignment-moves="locked"]') return node.getAttribute('data-assignment-moves') === 'locked';
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
function load({ sections, moves }) {
  const fetches = [];
  const reloads = [];
  const listeners = {};

  const root = makeNode('div');
  // The page element that carries the lock, as AssignmentsPage renders it.
  root.append(makeNode('section', { 'data-assignment-moves': moves }));
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

// ── The lock ────────────────────────────────────────────────────────────────

test('a locked page keeps an assignment in its own section and posts nothing', async () => {
  const a = row('assignment', 'a1');
  const other = row('assignment', 'a9');
  const h = load({ sections: { labs: [a], exams: [other] }, moves: 'locked' });

  h.fire('dragstart', { target: a, ...noopEvent() });
  h.fire('dragover', { target: other, clientY: 1, preventDefault() {} });
  h.fire('dragover', { target: h.tbodies.exams, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.equal(a.parentElement, h.tbodies.labs, 'the assignment row did not leave its section');
  assert.deepEqual(h.fetches, [], 'no move is posted, so the server has nothing to refuse');
});

test('a locked page still reorders an assignment inside its section', async () => {
  const a = row('assignment', 'a1');
  const b = row('assignment', 'a2');
  const h = load({ sections: { labs: [a, b] }, moves: 'locked' });

  h.fire('dragstart', { target: b, ...noopEvent() });
  h.fire('dragover', { target: a, clientY: 1, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.deepEqual(h.fetches.map((f) => f.url), ['/instructor/section-items/reorder']);
});

test('a locked page still moves a content item to another section', async () => {
  const c = row('content', 'c1');
  const other = row('assignment', 'a9');
  const h = load({ sections: { labs: [c], exams: [other] }, moves: 'locked' });

  h.fire('dragstart', { target: c, ...noopEvent() });
  h.fire('dragover', { target: h.tbodies.exams, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.equal(h.fetches[0].url, '/instructor/content-items/c1/section');
});

test('a free page moves an assignment to another section', async () => {
  const a = row('assignment', 'a1');
  const other = row('assignment', 'a9');
  const h = load({ sections: { labs: [a], exams: [other] }, moves: 'free' });

  h.fire('dragstart', { target: a, ...noopEvent() });
  h.fire('dragover', { target: h.tbodies.exams, preventDefault() {} });
  h.fire('dragend', {});
  await settle();

  assert.equal(h.fetches[0].url, '/instructor/a1/section');
});
