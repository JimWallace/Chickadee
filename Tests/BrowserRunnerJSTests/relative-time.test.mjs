// Unit tests for Public/relative-time.js — the one relative-timestamp
// renderer, loaded on every page from base.leaf.
//
// It had no tests, which is how it kept applying exactly ONCE per page load.
// That made a timestamp live only where something else repainted it — the
// three tables table-poll.js refreshes — and frozen at load time on the runner
// dashboard, the MCP agent list, alerts and the activity log. The tick, its
// cadence, and the fact that it stops while the tab is hidden are the things
// worth pinning; the formatting is pinned alongside because six drifted copies
// of it is why this file exists.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/relative-time.js'), 'utf8');

function makeNode(iso) {
  return {
    iso,
    textContent: '(unrendered)',
    title: '',
    writes: 0,
    getAttribute(name) { return name === 'data-iso' ? this.iso : null; },
    set text(v) { this.textContent = v; },
  };
}

// Counts textContent writes so "write only on change" can be asserted.
function instrument(node) {
  let value = node.textContent;
  Object.defineProperty(node, 'textContent', {
    get() { return value; },
    set(v) { node.writes += 1; value = v; },
  });
  return node;
}

function load({ nodes = [], hidden = false, now = Date.parse('2026-08-14T12:00:00Z') } = {}) {
  const timers = [];
  let clock = now;
  const listeners = {};

  const documentStub = {
    readyState: 'complete',
    hidden,
    querySelectorAll: () => nodes,
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn); },
  };

  const sandbox = {
    document: documentStub,
    module: { exports: {} },
    Intl,
    Number,
    Math,
    String,
    Date: class extends Date {
      constructor(...args) { super(...(args.length ? args : [clock])); }
      static now() { return clock; }
    },
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearTimeout: (id) => { if (timers[id - 1]) timers[id - 1].cleared = true; },
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  return {
    RelativeTime: sandbox.module.exports,
    timers,
    pending: () => timers.filter((t) => !t.cleared && !t.fired).slice(-1)[0] || null,
    // Firing consumes the timer, as a real one does — otherwise a tick that
    // deliberately does NOT re-arm looks identical to one that did.
    fire: () => {
      const t = timers.filter((x) => !x.cleared && !x.fired).slice(-1)[0];
      if (!t) return;
      t.fired = true;
      t.fn();
    },
    advance: (seconds) => { clock += seconds * 1000; },
    emit: (type) => (listeners[type] || []).forEach((fn) => fn()),
    setHidden: (v) => { documentStub.hidden = v; },
  };
}

// ── Cadence ─────────────────────────────────────────────────────────────────

test('the cadence follows the freshest timestamp on the page', () => {
  const { RelativeTime } = load();
  assert.equal(RelativeTime.tickSecondsFor(5), 15, 'seconds-old stamps tick every 15s');
  assert.equal(RelativeTime.tickSecondsFor(59), 15);
  assert.equal(RelativeTime.tickSecondsFor(60), 60, 'minutes-old stamps tick every minute');
  assert.equal(RelativeTime.tickSecondsFor(3599), 60);
  assert.equal(RelativeTime.tickSecondsFor(3600), 300, 'hours-old stamps tick every 5 minutes');
  assert.equal(RelativeTime.tickSecondsFor(null), null, 'a page with no timestamps does not tick');
});

test('a page with no timestamps arms no timer at all', () => {
  const h = load({ nodes: [] });
  assert.equal(h.pending(), null);
});

test('a page of fresh stamps arms the fast tick; an old page the slow one', () => {
  const fresh = load({ nodes: [makeNode('2026-08-14T11:59:50Z')] });
  assert.equal(fresh.pending().ms, 15000);

  const old = load({ nodes: [makeNode('2026-08-14T06:00:00Z')] });
  assert.equal(old.pending().ms, 300000);
});

test('the freshest stamp sets the pace, not the average', () => {
  const h = load({
    nodes: [
      makeNode('2026-08-10T12:00:00Z'),   // days old
      makeNode('2026-08-14T11:59:55Z'),   // seconds old
      makeNode('2026-08-13T12:00:00Z'),   // a day old
    ],
  });
  assert.equal(h.pending().ms, 15000);
});

// ── The tick itself ─────────────────────────────────────────────────────────

test('the text keeps up as time passes', () => {
  const node = makeNode('2026-08-14T11:59:00Z');
  const h = load({ nodes: [node] });
  assert.equal(node.textContent, '1 minute ago');

  h.advance(3600);
  h.fire();
  assert.equal(node.textContent, '1 hour ago', 'the tick re-renders rather than freezing at load');
});

test('the tick re-arms itself, and slows as the page ages', () => {
  const node = makeNode('2026-08-14T11:59:30Z');   // 30s old
  const h = load({ nodes: [node] });
  assert.equal(h.pending().ms, 15000);

  h.advance(120);      // now 2.5 minutes old
  h.fire();
  assert.equal(h.pending().ms, 60000, 'a re-armed tick uses the cadence for the NEW age');
});

test('text is written only when it changes', () => {
  const node = instrument(makeNode('2026-08-14T06:00:00Z'));   // 6 hours old
  const h = load({ nodes: [node] });
  const afterFirstPaint = node.writes;
  assert.equal(afterFirstPaint, 1, 'one write to render it');

  h.advance(60);
  h.fire();
  assert.equal(node.writes, afterFirstPaint, 'a minute later "6 hours ago" is unchanged: no write');

  h.advance(3600);
  h.fire();
  assert.equal(node.writes, afterFirstPaint + 1, 'when the string changes, it is written');
});

// ── Hidden tabs ─────────────────────────────────────────────────────────────

test('a hidden tab stops ticking and catches up when it comes back', () => {
  const node = makeNode('2026-08-14T11:59:00Z');
  const h = load({ nodes: [node] });
  assert.equal(node.textContent, '1 minute ago');

  h.setHidden(true);
  h.emit('visibilitychange');
  assert.equal(h.pending(), null, 'no timer while hidden');

  h.advance(7200);
  h.setHidden(false);
  h.emit('visibilitychange');
  assert.equal(node.textContent, '2 hours ago', 'restored tab re-renders immediately');
  assert.ok(h.pending(), 'and starts ticking again');
});

test('a tick that fires while hidden renders nothing and does not re-arm', () => {
  const node = instrument(makeNode('2026-08-14T11:59:50Z'));
  const h = load({ nodes: [node] });
  const writes = node.writes;

  h.setHidden(true);
  h.fire();                       // a timer already in flight when the tab hid
  assert.equal(node.writes, writes, 'no work while hidden');
  assert.equal(h.pending(), null, 'and no re-arm — visibilitychange restarts it');
});

// ── Formatting (six drifted copies is why this file exists) ─────────────────

test('formatting spans seconds to years, in both directions', () => {
  const { RelativeTime } = load();
  assert.equal(RelativeTime.formatRelative('2026-08-14T11:59:30Z'), '30 seconds ago');
  assert.equal(RelativeTime.formatRelative('2026-08-14T11:00:00Z'), '1 hour ago');
  assert.equal(RelativeTime.formatRelative('2026-08-07T12:00:00Z'), 'last week');
  assert.equal(RelativeTime.formatRelative('2026-08-15T12:00:00Z'), 'tomorrow');
  assert.equal(RelativeTime.formatRelative('2027-08-14T12:00:00Z'), 'next year');
});

test('an unparseable timestamp renders as itself rather than "Invalid Date"', () => {
  const { RelativeTime } = load();
  assert.equal(RelativeTime.formatRelative('not-a-date'), 'not-a-date');
});

test('isStale is the client half of the 5-minute runner rule', () => {
  const { RelativeTime } = load();
  assert.equal(RelativeTime.isStale('2026-08-14T11:59:00Z'), false, '1 minute is fresh');
  assert.equal(RelativeTime.isStale('2026-08-14T11:50:00Z'), true, '10 minutes is stale');
  assert.equal(RelativeTime.isStale(''), false, 'no timestamp is not a staleness claim');
});
