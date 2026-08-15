// Unit tests for the core of Public/chickadee-ui.js — the module loaded from
// base.leaf on EVERY page, and the one with the fewest tests relative to its
// reach.
//
// This covers the utilities the rest of the frontend is built on: escaping,
// the CSRF token, the shared fetch-error extractor, and the JSON fetch
// wrapper.
//
// NOT covered here: `runInlineScripts`, which re-executes script elements from
// swapped HTML. It is internal to `swapHalf` and unexported, so reaching it
// would mean widening the public API to suit a test. Its CONTRACT is now
// written down in the source; covering its behaviour needs a `swapHalf`
// harness (DOMParser, importNode, the keepElement identity rule), which is its
// own slice.
//
// Each of these exists because it replaced drifted copies — escapeHtml
// replaced per-file variants that disagreed on which characters they escaped,
// extractErrorMessage replaced two copies flowing through the same slot (one
// parsing JSON, the other scraping the Leaf error page). A shared
// implementation only helps while it stays correct, and nothing was checking.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

function load({ meta = null, csrfField = null, fetchImpl } = {}) {
  const created = [];
  const doc = {
    readyState: 'complete',
    querySelector: (sel) => {
      if (sel === 'meta[name="csrf-token"]') return meta === null ? null : { content: meta };
      if (sel === 'input[name="_csrf"]') return csrfField === null ? null : { value: csrfField };
      return null;
    },
    querySelectorAll: () => [],
    createElement: (tag) => {
      const el = { tagName: tag.toUpperCase(), textContent: '', type: '', attrs: {},
        setAttribute(n, v) { this.attrs[n] = v; }, appendChild() {}, addEventListener() {} };
      created.push(el);
      return el;
    },
    addEventListener() {},
    body: { appendChild() {}, addEventListener() {} },
  };

  const sandbox = { document: doc, Promise, JSON, Object, Error, Array, String, setTimeout, console: { error() {} } };
  if (fetchImpl) sandbox.fetch = fetchImpl;
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { UI: sandbox.ChickadeeUI, created, doc };
}

const UI = load().UI;

// ── Escaping ────────────────────────────────────────────────────────────────

test('escapeHtml covers all five characters, and escapeAttr is the same function', () => {
  assert.equal(UI.escapeHtml('<a href="x">O\'Brien & co</a>'),
    '&lt;a href=&quot;x&quot;&gt;O&#39;Brien &amp; co&lt;/a&gt;');
  // The per-file copies this replaced disagreed on " and ': both are escaped.
  assert.equal(UI.escapeAttr('"\''), '&quot;&#39;');
});

test('escaping is ampersand-first, so an escape is never double-escaped wrong', () => {
  assert.equal(UI.escapeHtml('&lt;'), '&amp;lt;');
});

test('null and undefined escape to the empty string rather than "null"', () => {
  assert.equal(UI.escapeHtml(null), '');
  assert.equal(UI.escapeHtml(undefined), '');
  assert.equal(UI.escapeHtml(0), '0');
});

// ── CSRF token ──────────────────────────────────────────────────────────────

test('the CSRF token comes from the meta tag, falling back to the hidden field', () => {
  assert.equal(load({ meta: 'from-meta', csrfField: 'from-field' }).UI.getCsrfToken(), 'from-meta');
  assert.equal(load({ meta: null, csrfField: 'from-field' }).UI.getCsrfToken(), 'from-field');
  assert.equal(load({}).UI.getCsrfToken(), '', 'a page with neither yields "" rather than undefined');
});

// ── Error extraction ────────────────────────────────────────────────────────

test('a JSON error body is read by reason, then error, then message', () => {
  assert.equal(UI.extractErrorMessage('{"reason":"Name is required"}'), 'Name is required');
  assert.equal(UI.extractErrorMessage('{"error":"nope"}'), 'nope');
  assert.equal(UI.extractErrorMessage('{"message":"also nope"}'), 'also nope');
  assert.equal(UI.extractErrorMessage('{"reason":"first","error":"second"}'), 'first');
});

test('the Leaf error page is scraped for its message', () => {
  const page = '<html><body><p class="error-message">Assignment not found</p></body></html>';
  assert.equal(UI.extractErrorMessage(page), 'Assignment not found');
});

// The scrape strips tags to a FIXPOINT, so a nested fragment cannot survive
// one pass and reassemble into markup at the sink.
test('tag stripping is run to a fixpoint', () => {
  const page = '<p class="error-message">a<scr<script>ipt>b</p>';
  const out = UI.extractErrorMessage(page);
  assert.ok(!out.includes('<'), `nothing tag-like survives: ${out}`);
});

// Entities decode with &amp; LAST, so "&amp;lt;" becomes "&lt;" — one level —
// and never "<". Decoding &amp; first would re-create markup from text that
// was already safely escaped.
test('entity decoding is one level, ampersand last', () => {
  assert.equal(UI.extractErrorMessage('<p class="error-message">&amp;lt;script&amp;gt;</p>'), '&lt;script&gt;');
  assert.equal(UI.extractErrorMessage('<p class="error-message">a &amp; b</p>'), 'a & b');
});

test('an unrecognized body is returned, truncated past 200 characters', () => {
  assert.equal(UI.extractErrorMessage('plain text'), 'plain text');
  const long = 'x'.repeat(500);
  const out = UI.extractErrorMessage(long);
  assert.equal(out.length, 201);
  assert.ok(out.endsWith('…'));
});

test('an empty body extracts to the empty string', () => {
  assert.equal(UI.extractErrorMessage(''), '');
  assert.equal(UI.extractErrorMessage(null), '');
});

// ── fetchJSON ───────────────────────────────────────────────────────────────

function fetchHarness(response) {
  const calls = [];
  const impl = (url, opts) => {
    calls.push({ url, opts });
    return Promise.resolve(response);
  };
  return { calls, impl };
}

test('a body is JSON-encoded and declared, and the CSRF token rides the header', async () => {
  const h = fetchHarness({ ok: true, status: 200, json: () => Promise.resolve({ ok: 1 }) });
  const { UI: ui } = load({ meta: 'tok', fetchImpl: h.impl });

  const result = await ui.fetchJSON('/x', { method: 'PUT', body: { a: 1 } });
  assert.deepEqual(result, { ok: 1 });
  assert.equal(h.calls[0].opts.method, 'PUT');
  assert.equal(h.calls[0].opts.headers['Content-Type'], 'application/json');
  assert.equal(h.calls[0].opts.headers['x-csrf-token'], 'tok');
  assert.equal(h.calls[0].opts.body, '{"a":1}');
});

test('a GET sends no body and no Content-Type', async () => {
  const h = fetchHarness({ ok: true, status: 200, json: () => Promise.resolve(null) });
  const { UI: ui } = load({ meta: 'tok', fetchImpl: h.impl });

  await ui.fetchJSON('/x');
  assert.equal(h.calls[0].opts.method, 'GET');
  assert.equal(h.calls[0].opts.body, undefined);
  assert.equal(h.calls[0].opts.headers['Content-Type'], undefined);
});

test('an explicit csrfToken wins over the page token', async () => {
  const h = fetchHarness({ ok: true, status: 204 });
  const { UI: ui } = load({ meta: 'page-token', fetchImpl: h.impl });

  await ui.fetchJSON('/x', { method: 'DELETE', csrfToken: 'explicit' });
  assert.equal(h.calls[0].opts.headers['x-csrf-token'], 'explicit');
});

test('204 resolves to null rather than failing to parse an empty body', async () => {
  const h = fetchHarness({ ok: true, status: 204 });
  const { UI: ui } = load({ fetchImpl: h.impl });
  assert.equal(await ui.fetchJSON('/x', { method: 'DELETE' }), null);
});

test('a non-JSON success body resolves to null rather than throwing', async () => {
  const h = fetchHarness({ ok: true, status: 200, json: () => Promise.reject(new Error('not json')) });
  const { UI: ui } = load({ fetchImpl: h.impl });
  assert.equal(await ui.fetchJSON('/x'), null);
});

test('a failure rejects with the SERVER message, not a bare status', async () => {
  const h = fetchHarness({ ok: false, status: 422, text: () => Promise.resolve('{"reason":"Name is required"}') });
  const { UI: ui } = load({ fetchImpl: h.impl });

  await assert.rejects(() => ui.fetchJSON('/x', { method: 'POST', body: {} }),
    /Name is required/);
});

test('a failure with an unreadable body still rejects with the status', async () => {
  const h = fetchHarness({ ok: false, status: 500, text: () => Promise.resolve('') });
  const { UI: ui } = load({ fetchImpl: h.impl });
  await assert.rejects(() => ui.fetchJSON('/x'), /HTTP 500/);
});
