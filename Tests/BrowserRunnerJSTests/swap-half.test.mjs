// Unit tests for the pane swap in Public/chickadee-ui.js — the mechanism that
// re-renders half of the merged workbench without navigating.
//
// `refresh-edit-surface.test.mjs` covers the swap's OUTER decisions: swap vs.
// reload, which URL, scroll restoration, and the reload fallback on failure.
// Its DOM stub deliberately reports no scripts and no carried element, so two
// of the swap's rules were never exercised by anything. Both are the kind that
// fail silently:
//
//   * `runInlineScripts`, the one place in the frontend that turns markup into
//     running code on purpose. A `<script>` inserted by parsing HTML does not
//     run — a deliberate platform rule — so the swap re-creates the element to
//     get the page's wiring back. Get its exclusions wrong and you either
//     double-load a module or execute a JSON seed island.
//   * `keepElement`, which carries `#jl-frame` across the swap by object
//     identity. 34 closures in notebook.js captured that element; rebuilding it
//     leaves every one of them on a detached node, and the page still LOOKS
//     right — the notebook renders, and nothing it does afterwards works.
//
// So this file is a real-enough DOM: nodes with identity, a fragment that
// actually moves its children, and a parser whose output is a tree rather than
// a string. Identity is the whole subject, and a stub that returns fresh
// objects would make every assertion here vacuous.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

// ── A miniature DOM ─────────────────────────────────────────────────────────

let nextNodeID = 1;

function node(tagName, attrs = {}, children = []) {
  const el = {
    nodeID: nextNodeID++,
    tagName: String(tagName).toUpperCase(),
    attrs: { ...attrs },
    children: [],
    parentNode: null,
    scrollTop: 0,
    _text: '',

    get attributes() {
      return Object.keys(this.attrs).map((name) => ({ name, value: this.attrs[name] }));
    },
    get id() { return this.attrs.id ?? ''; },
    get type() { return this.attrs.type ?? ''; },
    set type(v) { this.attrs.type = v; },
    get textContent() { return this._text; },
    set textContent(v) {
      // Assigning textContent empties the element, which is how the swap clears
      // the half before appending the new subtree. An emptied element stops
      // overflowing, so the browser clamps its scroll offset to 0 — modelled,
      // because without it the scroll-restoration assertion below passes
      // whether or not the restore exists.
      this.children.forEach((c) => { c.parentNode = null; });
      this.children = [];
      this._text = String(v);
      this.scrollTop = 0;
    },

    setAttribute(name, value) { this.attrs[name] = String(value); },
    getAttribute(name) { return this.attrs[name] ?? null; },
    hasAttribute(name) { return name in this.attrs; },

    appendChild(child) {
      // A DocumentFragment MOVES its children rather than being inserted
      // itself. Modelled, because `runInlineScripts` runs against the half
      // AFTER the append and would find nothing if the fragment stayed whole.
      if (child.isFragment) {
        child.children.slice().forEach((c) => this.appendChild(c));
        child.children = [];
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = this;
      this.children.push(child);
      this._text = '';
      return child;
    },
    removeChild(child) {
      this.children = this.children.filter((c) => c !== child);
      child.parentNode = null;
      return child;
    },
    replaceChild(fresh, old) {
      const at = this.children.indexOf(old);
      if (at < 0) throw new Error('replaceChild: node is not a child');
      if (fresh.parentNode) fresh.parentNode.removeChild(fresh);
      this.children[at] = fresh;
      fresh.parentNode = this;
      old.parentNode = null;
      return old;
    },

    get childNodes() { return this.children.slice(); },

    /// Depth-first search for `#id` and for the two script selectors the swap
    /// uses. Deliberately narrow: an over-general matcher would let a wrong
    /// selector in the source still pass here.
    querySelector(sel) {
      return descendants(this).find((n) => matches(n, sel)) ?? null;
    },
    querySelectorAll(sel) {
      return descendants(this).filter((n) => matches(n, sel));
    },
  };
  Object.entries(attrs).forEach(([k, v]) => { el.attrs[k] = String(v); });
  children.forEach((c) => el.appendChild(c));
  return el;
}

function descendants(root) {
  const out = [];
  const walk = (n) => n.children.forEach((c) => { out.push(c); walk(c); });
  walk(root);
  return out;
}

function matches(n, sel) {
  if (sel === 'script:not([src])') return n.tagName === 'SCRIPT' && !n.hasAttribute('src');
  if (sel.startsWith('#')) return n.attrs.id === sel.slice(1);
  if (sel.startsWith('.')) return String(n.attrs.class || '').split(/\s+/).includes(sel.slice(1));
  return n.tagName === sel.toUpperCase();
}

function fragment() {
  const f = node('#fragment');
  f.isFragment = true;
  return f;
}

/// A deep copy with FRESH identity, which is what `importNode` is.
function importNode(n) {
  const copy = node(n.tagName, n.attrs, n.children.map(importNode));
  copy._text = n._text;
  return copy;
}

// ── The harness ─────────────────────────────────────────────────────────────

/// Load chickadee-ui.js with `freshHalf` as the subtree the refresh fetches.
///
/// `keptID` seeds an element already in the live document, so the carried-over
/// path has something with identity to carry.
function load({ freshHalf, selector = '.wb-pane-edit', keptID = null, fetchFails = false } = {}) {
  const calls = [];
  const half = node('div', { class: selector.slice(1) }, [node('p', {}, [])]);
  half.scrollTop = 420;
  const kept = keptID ? node('iframe', { id: keptID, 'data-file': 'old.ipynb' }) : null;
  const created = [];

  const document = {
    body: { getAttribute: () => null },
    querySelector: (sel) => (matches(half, sel) ? half : null),
    getElementById: (id) => {
      if (id === 'wb-shell') return {};
      if (kept && id === keptID) return kept;
      return null;
    },
    createElement: (tag) => { const el = node(tag); created.push(el); return el; },
    createDocumentFragment: fragment,
    importNode: (n) => importNode(n),
  };

  const window = {
    location: {
      href: 'https://chickadee.example/instructor/DEJr2f/workbench',
      reload: () => calls.push({ kind: 'reload' }),
    },
    document,
    addEventListener: () => {},
    fetch: (url, init) => {
      calls.push({ kind: 'fetch', url, init });
      if (fetchFails) return Promise.reject(new Error('network'));
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve('<html/>') });
    },
    DOMParser: class {
      parseFromString() {
        return { querySelector: (sel) => (matches(freshHalf, sel) ? freshHalf : null) };
      }
    },
  };
  window.parent = window;

  const context = vm.createContext({
    window, document, globalThis: {},
    fetch: window.fetch, DOMParser: window.DOMParser,
    Array, Object, String, Promise, Error, setTimeout,
  });
  vm.runInContext(source, context);
  return { ui: window.ChickadeeUI, calls, half, kept, created, document, window };
}

/// The subtree the server sends back for the edit half.
function freshEditHalf(children) {
  return node('div', { class: 'wb-pane-edit' }, children);
}

function scriptNode(text, attrs = {}) {
  const s = node('script', attrs);
  s._text = text;
  return s;
}

// ── runInlineScripts ────────────────────────────────────────────────────────

test('an inline script is RE-CREATED, because a parsed one would never run', async () => {
  const original = scriptNode('initSuiteTable();');
  const { ui, half } = load({ freshHalf: freshEditHalf([original]) });

  await ui.refreshEditSurface();

  const live = half.querySelectorAll('script:not([src])');
  assert.equal(live.length, 1);
  assert.equal(live[0].textContent, 'initSuiteTable();');
  assert.notEqual(live[0].nodeID, original.nodeID,
    'a script element inserted by parsing HTML is inert; only a freshly created one executes');
});

test('a src= script is left alone, so a swap never re-runs a module', async () => {
  const module = scriptNode('', { src: '/suite-table.js' });
  const { ui, half } = load({ freshHalf: freshEditHalf([module]) });

  await ui.refreshEditSurface();

  const live = half.children.filter((n) => n.tagName === 'SCRIPT');
  assert.equal(live.length, 1);
  assert.equal(live[0].getAttribute('src'), '/suite-table.js');
  // Re-created it would re-fetch and re-run the module's IIFE, double-binding
  // every listener it installs.
  assert.equal(live[0].children.length, 0);
  assert.equal(live[0].textContent, '');
});

test('a JSON seed island is data: not re-run, and it keeps its type', async () => {
  const seed = scriptNode('{"language":"r"}', { type: 'application/json', id: 'assignment-language-seed' });
  const { ui, half } = load({ freshHalf: freshEditHalf([seed]) });

  await ui.refreshEditSurface();

  const live = half.querySelector('#assignment-language-seed');
  assert.ok(live, 'the seed must stay findable — every authoring editor reads it by id');
  assert.equal(live.getAttribute('type'), 'application/json',
    'a re-created element without its type would be executed as script by the browser');
  assert.equal(live.textContent, '{"language":"r"}');
});

test('scripts nested inside the swapped subtree are re-run too, not just top-level ones', async () => {
  const inner = scriptNode('initSection();');
  const { ui, half } = load({
    freshHalf: freshEditHalf([node('section', { class: 'section-block' }, [inner])]),
  });

  await ui.refreshEditSurface();

  const live = half.querySelectorAll('script:not([src])');
  assert.equal(live.length, 1);
  assert.notEqual(live[0].nodeID, inner.nodeID);
  assert.equal(live[0].parentNode.tagName, 'SECTION', 'and it stays where the markup put it');
});

test('a swapped half with no scripts at all is fine', async () => {
  const { ui, half } = load({ freshHalf: freshEditHalf([node('p')]) });
  assert.equal(await ui.refreshEditSurface(), true);
  assert.equal(half.children.length, 1);
});

// ── The swap itself ─────────────────────────────────────────────────────────

test('the old content is replaced by the new, and scroll survives it', async () => {
  const { ui, half } = load({ freshHalf: freshEditHalf([node('h2'), node('table')]) });

  await ui.refreshEditSurface();

  assert.deepEqual(half.children.map((n) => n.tagName), ['H2', 'TABLE']);
  assert.equal(half.scrollTop, 420,
    're-rendering after a one-line edit must not send the author back to the top');
});

test('the swapped nodes are copies, so the fetched document is not adopted', async () => {
  const incoming = node('table', { id: 'suite' });
  const fresh = freshEditHalf([incoming]);
  const { ui, half } = load({ freshHalf: fresh });

  await ui.refreshEditSurface();

  assert.notEqual(half.children[0].nodeID, incoming.nodeID);
  assert.equal(incoming.parentNode, fresh, 'the parsed document keeps its own tree');
});

// ── keepElement ─────────────────────────────────────────────────────────────

test('the carried element keeps its IDENTITY across the swap', async () => {
  const incomingFrame = node('iframe', { id: 'jl-frame', 'data-file': 'new.ipynb' });
  const { ui, half, kept } = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [node('div', {}, [incomingFrame])]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
  });

  await ui.refreshNotebookSurface('/instructor/DEJr2f/workbench?file=new.ipynb');

  const live = half.querySelector('#jl-frame');
  assert.equal(live, kept,
    '34 closures captured this element; a rebuilt one leaves every one of them detached');
  assert.notEqual(live.nodeID, incomingFrame.nodeID);
});

test('the carried element takes on the incoming attributes, but keeps its id', async () => {
  const incomingFrame = node('iframe', { id: 'jl-frame', 'data-file': 'new.ipynb', 'data-view': 'notebook' });
  const { ui, kept } = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [incomingFrame]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
  });

  await ui.refreshNotebookSurface('/x');

  assert.equal(kept.getAttribute('data-file'), 'new.ipynb',
    'the incoming attributes name which notebook to open — they are the point of the swap');
  assert.equal(kept.getAttribute('data-view'), 'notebook');
  assert.equal(kept.getAttribute('id'), 'jl-frame');
});

test('the carried element lands where the incoming one would have gone', async () => {
  const incomingFrame = node('iframe', { id: 'jl-frame' });
  const wrapper = node('div', { class: 'jl-wrap' }, [incomingFrame]);
  const { ui, half, kept } = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [node('header'), wrapper]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
  });

  await ui.refreshNotebookSurface('/x');

  assert.equal(kept.parentNode.getAttribute('class'), 'jl-wrap');
  assert.equal(half.querySelectorAll('#jl-frame').length, 1, 'and there is exactly one of it');
});

// The failure is louder than a missing frame, on purpose: a swap that silently
// dropped `#jl-frame` would leave the notebook half with no editor in it.
test('a response missing the carried element falls back to a reload', async () => {
  const { ui, calls } = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [node('p')]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
  });

  assert.equal(await ui.refreshNotebookSurface('/x'), false);
  assert.equal(calls.filter((c) => c.kind === 'reload').length, 1);
});

// ── refreshNotebookSurface ──────────────────────────────────────────────────

test('a successful notebook swap re-mounts, so the moved frame opens the new file', async () => {
  const incomingFrame = node('iframe', { id: 'jl-frame', 'data-file': 'new.ipynb' });
  const h = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [incomingFrame]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
  });
  let remounts = 0;
  h.window.chickadeeRemountNotebook = () => { remounts += 1; };

  assert.equal(await h.ui.refreshNotebookSurface('/x'), true);
  assert.equal(remounts, 1,
    'the frame was MOVED, not rebuilt, so nothing re-reads its new data-* without this');
});

test('a failed notebook swap does not re-mount a frame that never moved', async () => {
  const h = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [node('p')]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
    fetchFails: true,
  });
  let remounts = 0;
  h.window.chickadeeRemountNotebook = () => { remounts += 1; };

  assert.equal(await h.ui.refreshNotebookSurface('/x'), false);
  assert.equal(remounts, 0);
  assert.equal(h.calls.filter((c) => c.kind === 'reload').length, 1);
});

test('a page with no remount hook swaps without complaint', async () => {
  const h = load({
    freshHalf: node('div', { class: 'wb-notebook-body' }, [node('iframe', { id: 'jl-frame' })]),
    selector: '.wb-notebook-body',
    keptID: 'jl-frame',
  });
  assert.equal(await h.ui.refreshNotebookSurface('/x'), true);
});
