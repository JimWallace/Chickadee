// Unit tests for Public/accordion-row.js — the inline detail-row editor the
// suite table and the achievements table expand beneath a row.
//
// It had no tests while it lived inside chickadee-ui.js, and it is the kind of
// code that fails invisibly: every one of its animation paths ends in a
// teardown, and a teardown that does not run leaves a stranded detail row in
// the table with an editor still mounted in it. Three of its rules are here
// because of engine behaviour rather than design, and each is pinned below:
//
//   * the open is a DOUBLE requestAnimationFrame — one frame does not reliably
//     start the transition, and a transition that never starts is a row that
//     never reveals its overflow, which clips the editor's popovers;
//   * every animated path carries a TIMEOUT fallback, because transitionend
//     does not fire in a backgrounded tab or under a display:none ancestor;
//   * the teardown runs exactly ONCE however it is reached — the caller's
//     synchronous finishNow(), the transition, and the fallback timer all
//     race, and running onDone twice would tear down an editor body that has
//     already been rescued.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/accordion-row.js'), 'utf8');

/// A DOM stub with just enough structure for the accordion: elements that
/// remember their class list, style, children and listeners.
function makeEl(tag) {
  const el = {
    tagName: String(tag).toUpperCase(),
    className: '',
    textContent: '',
    type: '',
    style: {},
    attrs: {},
    children: [],
    parentNode: null,
    handlers: {},
    scrolledIntoView: null,
    setAttribute(n, v) { this.attrs[n] = String(v); },
    getAttribute(n) { return this.attrs[n] ?? null; },
    appendChild(c) { c.parentNode = this; this.children.push(c); return c; },
    removeChild(c) {
      this.children = this.children.filter((x) => x !== c);
      c.parentNode = null;
      return c;
    },
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
    fire(type, e) { (this.handlers[type] || []).slice().forEach((fn) => fn(e || {})); },
    scrollIntoView(opts) { this.scrolledIntoView = opts; },
    querySelector(sel) {
      const want = sel.replace('.', '');
      const walk = (node) => {
        for (const c of node.children) {
          if (String(c.className).split(/\s+/).includes(want)) return c;
          const hit = walk(c);
          if (hit) return hit;
        }
        return null;
      };
      return walk(this);
    },
  };
  el.classes = new Set();
  el.classList = {
    add: (...c) => c.forEach((n) => el.classes.add(n)),
    remove: (...c) => c.forEach((n) => el.classes.delete(n)),
    contains: (n) => el.classes.has(n),
  };
  return el;
}

function load({ reducedMotion = false } = {}) {
  const timers = [];
  const rafs = [];
  const sandbox = {
    document: { createElement: makeEl },
    String,
    Array,
    Object,
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    matchMedia: (q) => ({ matches: reducedMotion && q.includes('reduce') }),
    requestAnimationFrame: (fn) => { rafs.push(fn); return rafs.length; },
  };
  sandbox.self = sandbox;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  return {
    A: sandbox.ChickadeeAccordion,
    timers,
    rafs,
    /// Run every currently-queued animation frame callback, one frame's worth.
    frame() { const due = rafs.splice(0, rafs.length); due.forEach((fn) => fn()); },
    /// Fire the fallback timer(s) the browser would fire after the deadline.
    fireTimers() { const due = timers.splice(0, timers.length); due.forEach((t) => t.fn()); },
  };
}

/// A built detail row, inserted into a stub table body, with a parent row.
function mounted(h, opts) {
  const parts = h.A.build(opts);
  const tbody = makeEl('tbody');
  const parentRow = makeEl('tr');
  tbody.appendChild(parentRow);
  tbody.appendChild(parts.tr);
  return { parts, tbody, parentRow };
}

// ── build ───────────────────────────────────────────────────────────────────

test('build returns the skeleton unattached, for the caller to place', () => {
  const h = load();
  const parts = h.A.build({ colspan: 4 });

  assert.equal(parts.tr.tagName, 'TR');
  assert.equal(parts.tr.parentNode, null,
    'the two editors place the row differently, so build must not insert it');
  assert.equal(parts.tr.className, 'suite-detail-row');
  assert.equal(parts.host.className, 'suite-detail-host');
  assert.equal(parts.saveBtn.textContent, 'Save');
  assert.equal(parts.cancelBtn.textContent, 'Cancel');
});

test('the buttons are type=button, so neither submits the page form', () => {
  const h = load();
  const parts = h.A.build({});
  assert.equal(parts.saveBtn.type, 'button');
  assert.equal(parts.cancelBtn.type, 'button');
});

test('colspan comes from the caller and defaults rather than rendering "undefined"', () => {
  const h = load();
  assert.equal(h.A.build({ colspan: 7 }).tr.children[0].getAttribute('colspan'), '7');
  assert.equal(h.A.build().tr.children[0].getAttribute('colspan'), '4');
});

test('the caret markup is aria-hidden, since the row label carries the meaning', () => {
  const h = load();
  assert.match(h.A.CARET_HTML, /aria-hidden="true"/);
  assert.match(h.A.CARET_HTML, /accordion-caret/);
});

// ── open ────────────────────────────────────────────────────────────────────

test('the open flips to is-open only after a SECOND animation frame', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  h.A.open(m.parts, m.parentRow);
  assert.equal(m.parts.anim.classList.contains('is-open'), false,
    'flipping in the same frame as insertion skips the transition entirely');

  h.frame();
  assert.equal(m.parts.anim.classList.contains('is-open'), false, 'one frame is not enough');

  h.frame();
  assert.equal(m.parts.anim.classList.contains('is-open'), true);
});

test('the parent row is marked expanded, and the detail row is scrolled to', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  h.A.open(m.parts, m.parentRow);
  assert.equal(m.parentRow.classList.contains('suite-row-expanded'), true);
  assert.equal(m.parts.tr.scrolledIntoView.block, 'nearest');
});

test('opening with no parent row is fine — a brand-new row has none yet', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });
  h.A.open(m.parts, null);   // must not throw
  h.frame(); h.frame();
  assert.equal(m.parts.anim.classList.contains('is-open'), true);
});

test('overflow is revealed only once the height transition ends', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  h.A.open(m.parts, m.parentRow);
  assert.notEqual(m.parts.inner.style.overflow, 'visible',
    'revealing early would let a partly-open row spill its editor over the table');

  // Another property finishing is not the one we are waiting for.
  m.parts.anim.fire('transitionend', { propertyName: 'opacity' });
  assert.notEqual(m.parts.inner.style.overflow, 'visible');

  m.parts.anim.fire('transitionend', { propertyName: 'grid-template-rows' });
  assert.equal(m.parts.inner.style.overflow, 'visible',
    'an editor popover must not be clipped by the row that hosts it');
});

test('the reveal still happens if transitionend never fires', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  h.A.open(m.parts, m.parentRow);
  h.fireTimers();          // the backgrounded-tab case
  assert.equal(m.parts.inner.style.overflow, 'visible');
});

test('under reduced motion the row opens immediately, with no frames at all', () => {
  const h = load({ reducedMotion: true });
  const m = mounted(h, { colspan: 4 });

  h.A.open(m.parts, m.parentRow);
  assert.equal(m.parts.anim.classList.contains('is-open'), true);
  assert.equal(m.parts.inner.style.overflow, 'visible');
  assert.equal(h.rafs.length, 0);
});

// ── close ───────────────────────────────────────────────────────────────────

test('the row is removed and the parent un-marked when the collapse ends', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });
  m.parentRow.classList.add('suite-row-expanded');

  h.A.close(m.parts.tr, { parentRow: m.parentRow });
  assert.equal(m.parts.tr.parentNode, m.tbody, 'it stays mounted while it animates');
  assert.equal(m.parts.anim.classList.contains('is-open'), false);

  m.parts.anim.fire('transitionend', { propertyName: 'grid-template-rows' });
  assert.equal(m.parts.tr.parentNode, null);
  assert.equal(m.parentRow.classList.contains('suite-row-expanded'), false);
});

test('the row is re-clipped before collapsing, so content does not spill out', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });
  m.parts.inner.style.overflow = 'visible';   // as open() left it

  h.A.close(m.parts.tr, {});
  assert.equal(m.parts.inner.style.overflow, 'hidden');
});

test('onDone runs while the content is still mounted, and exactly once', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });
  const seen = [];

  const finishNow = h.A.close(m.parts.tr, {
    parentRow: m.parentRow,
    onDone: () => seen.push(m.parts.tr.parentNode === m.tbody),
  });

  finishNow();
  m.parts.anim.fire('transitionend', { propertyName: 'grid-template-rows' });
  h.fireTimers();

  assert.deepEqual(seen, [true],
    'the editor body is rescued in onDone, so it must run once and before removal');
});

test('the returned finishNow tears down synchronously, for an immediate re-open', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  const finishNow = h.A.close(m.parts.tr, { parentRow: m.parentRow });
  finishNow();

  assert.equal(m.parts.tr.parentNode, null,
    'a new editor opens before the old row finished animating; the old row must be gone');
});

test('the row is removed even if transitionend never fires', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  h.A.close(m.parts.tr, { parentRow: m.parentRow });
  h.fireTimers();
  assert.equal(m.parts.tr.parentNode, null, 'otherwise a stranded detail row survives forever');
});

test('immediate and reduced motion both remove the row with no animation', () => {
  for (const [label, h, opts] of [
    ['immediate', load(), { immediate: true }],
    ['reduced motion', load({ reducedMotion: true }), {}],
  ]) {
    const m = mounted(h, { colspan: 4 });
    h.A.close(m.parts.tr, { ...opts, parentRow: m.parentRow });
    assert.equal(m.parts.tr.parentNode, null, label);
    assert.equal(h.timers.length, 0, `${label}: no fallback timer is armed`);
  }
});

test('an onDone that throws does not strand the row in the table', () => {
  const h = load();
  const m = mounted(h, { colspan: 4 });

  h.A.close(m.parts.tr, {
    immediate: true,
    parentRow: m.parentRow,
    onDone: () => { throw new Error('the editor rescue failed'); },
  });

  assert.equal(m.parts.tr.parentNode, null);
  assert.equal(m.parentRow.classList.contains('suite-row-expanded'), false);
});

test('closing a row that was never inserted is a no-op, not a throw', () => {
  const h = load();
  const parts = h.A.build({ colspan: 4 });
  h.A.close(parts.tr, {})();
  h.A.close(null, {});
});
