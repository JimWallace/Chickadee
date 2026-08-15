// Unit tests for Public/inplace-forms.js — the workbench's form interception.
//
// It had none. It is small, but what it does is submit the author's work: if
// it picks the wrong encoding the handler parses nothing, if it drops the CSRF
// header every save 403s, and if it reports success on a failure the author is
// told their edit landed when it did not. None of that is visible to the render
// tests (they never run page JS) or to the visual harness (the workbench is not
// a captured page).
//
// The encoding rule is the subtle one and the reason this file exists in the
// shape it does: each form keeps its OWN encoding rather than everything going
// out as FormData, because the section and secret-reveal endpoints decode
// urlencoded bodies and switching them to multipart would change how their
// handlers parse, silently, for no reason.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/inplace-forms.js'), 'utf8');

function makeForm({ enctype = '', method = 'POST', action = '/instructor/x/edit/save' } = {}) {
  const submitter = { disabled: false, type: 'submit' };
  const children = [];
  return {
    enctype,
    method,
    action,
    submitter,
    children,
    inserted: [],
    firstChild: null,
    querySelector(sel) {
      if (sel === '[type="submit"]') return submitter;
      if (sel === '.js-inplace-error-banner') {
        return children.find((c) => c.className && c.className.includes('js-inplace-error-banner')) || null;
      }
      return null;
    },
    insertBefore(node) { children.push(node); this.inserted.push(node); return node; },
    addEventListener() {},
    matches: () => true,
  };
}

function load({ response, hasShell = true } = {}) {
  const fetches = [];
  const scheduled = [];
  const doc = {
    readyState: 'complete',
    getElementById: (id) => (id === 'wb-shell' && hasShell ? {} : null),
    createElement: () => ({
      className: '',
      textContent: '',
      attrs: {},
      setAttribute(n, v) { this.attrs[n] = v; },
      scrollIntoView() {},
      remove() {},
    }),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
  };

  const sandbox = {
    document: doc,
    Promise,
    FormData: class { constructor(form) { this.form = form; } },
    URLSearchParams: class { constructor(fd) { this.fd = fd; } },
    ChickadeeUI: {
      getCsrfToken: () => 'csrf-token-value',
      refreshEditSurface: () => scheduled.push('refresh'),
      // The shared extractor the real page uses (chickadee-ui.js); the banner
      // text is its output, so stubbing it keeps this file about inplace-forms.
      extractErrorMessage: (text) => text,
    },
    setTimeout: (fn) => { fn(); return 1; },
    fetch: (url, opts) => {
      fetches.push({ url, opts });
      return Promise.resolve(response);
    },
  };
  sandbox.window = { ChickadeeUI: sandbox.ChickadeeUI };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { fetches, scheduled, sandbox };
}

function ok() {
  return { ok: true, status: 200, text: () => Promise.resolve('') };
}
function failure(status, body) {
  return { ok: false, status, text: () => Promise.resolve(body) };
}

// The module exposes its submit as the global the workbench's Save button
// calls. If it is absent the harness cannot test anything, which must fail
// loudly rather than pass vacuously.
function submitOf(h) {
  const fn = h.sandbox.window.chickadeeSubmitInPlace;
  assert.ok(typeof fn === 'function', 'inplace-forms must expose chickadeeSubmitInPlace for the workbench Save');
  return fn;
}

test('a urlencoded form keeps its encoding and declares it', async () => {
  const h = load({ response: ok() });
  const form = makeForm({ enctype: 'application/x-www-form-urlencoded' });
  await submitOf(h)(form);

  const sent = h.fetches[0];
  assert.equal(sent.url, form.action);
  assert.equal(sent.opts.headers['Content-Type'], 'application/x-www-form-urlencoded');
  assert.equal(sent.opts.body.constructor.name, 'URLSearchParams');
});

test('a multipart form sends FormData and sets no Content-Type', async () => {
  const h = load({ response: ok() });
  const form = makeForm({ enctype: 'multipart/form-data' });
  await submitOf(h)(form);

  const sent = h.fetches[0];
  assert.equal(sent.opts.body.constructor.name, 'FormData');
  assert.equal(sent.opts.headers['Content-Type'], undefined,
    'the browser must set the multipart boundary itself');
});

test('the CSRF token rides the header on both encodings', async () => {
  for (const enctype of ['application/x-www-form-urlencoded', 'multipart/form-data']) {
    const h = load({ response: ok() });
    await submitOf(h)(makeForm({ enctype }));
    assert.equal(h.fetches[0].opts.headers['x-csrf-token'], 'csrf-token-value', enctype);
  }
});

test('the request is same-origin and keeps the form method', async () => {
  const h = load({ response: ok() });
  await submitOf(h)(makeForm({ method: 'post' }));
  assert.equal(h.fetches[0].opts.method, 'POST');
  assert.equal(h.fetches[0].opts.credentials, 'same-origin');
});

test('success resolves true and re-renders the pane', async () => {
  const h = load({ response: ok() });
  const result = await submitOf(h)(makeForm());
  assert.equal(result, true);
  assert.deepEqual(h.scheduled, ['refresh']);
});

test('a failure resolves false, shows a banner, and does NOT re-render', async () => {
  const h = load({ response: failure(422, 'Name is required') });
  const form = makeForm();
  const result = await submitOf(h)(form);

  assert.equal(result, false, 'a caller waiting on the save must learn it failed');
  assert.deepEqual(h.scheduled, [], 'a failed save must not look like a successful one');
  assert.equal(form.inserted.length, 1, 'an inline banner is added to the form');
  assert.equal(form.inserted[0].attrs.role, 'alert');
  assert.match(form.inserted[0].textContent, /422/);
});

test('the submit button is disabled while the request is in flight', async () => {
  let resolveFetch;
  const pending = new Promise((resolve) => { resolveFetch = resolve; });
  const h = load({ response: pending });
  const form = makeForm();

  const done = submitOf(h)(form);
  assert.equal(form.submitter.disabled, true, 'a double-submit cannot start a second save');
  resolveFetch(ok());
  await done;
});

test('submitting nothing resolves false rather than throwing', async () => {
  const h = load({ response: ok() });
  assert.equal(await submitOf(h)(null), false);
});
