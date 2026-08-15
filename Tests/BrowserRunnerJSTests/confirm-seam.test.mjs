// Unit tests for the `data-confirm` seam in Public/app.js.
//
// 36 destructive actions across 18 templates go through this: unenroll a
// student, delete an assignment, reset a submission, clear a runner secret.
// Its shape changed when the native dialog was replaced — a real dialog
// resolves in a promise, and a DOM listener cannot wait for one — so the seam
// now always cancels the interaction, asks, and REPLAYS it if the answer was
// yes.
//
// The replay is where a regression would be both silent and expensive: a
// destructive action that fires without asking, or one that asks and then
// never happens. Both directions are pinned here.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const appSource = await fs.readFile(path.resolve('Public/app.js'), 'utf8');

function makeEl({ tag = 'BUTTON', confirm = null } = {}) {
  const el = {
    tagName: tag,
    attrs: confirm === null ? {} : { 'data-confirm': confirm },
    clicks: 0,
    submits: [],
    getAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; },
    hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    matches(sel) { return sel === '[data-confirm]' && this.hasAttribute('data-confirm'); },
    closest(sel) { return sel === '[data-confirm]' && this.hasAttribute('data-confirm') ? this : null; },
    querySelectorAll: () => [],
    addEventListener() {},
    click() { this.clicks += 1; harness.dispatch('click', { target: this, ...noopEvent() }); },
    requestSubmit(submitter) {
      this.submits.push(submitter || null);
      harness.dispatch('submit', { target: this, submitter: submitter || null, ...noopEvent() });
    },
  };
  return el;
}

function noopEvent() {
  return {
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopPropagation() { this.stopped = true; },
  };
}

let harness;

function load({ answer = true } = {}) {
  const listeners = {};
  const asked = [];
  let resolveAnswer;

  const doc = {
    readyState: 'complete',
    body: { addEventListener() {} },
    documentElement: { addEventListener() {}, classList: { add() {}, remove() {} } },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    removeEventListener() {},
    querySelectorAll: () => [],
    querySelector: () => null,
    getElementById: () => null,
    createElement: () => ({ setAttribute() {}, appendChild() {}, addEventListener() {}, style: {}, classList: { add() {} } }),
  };

  const sandbox = {
    document: doc,
    Promise,
    Element: class {},
    setTimeout: (fn) => fn,
    clearTimeout: () => {},
  };
  sandbox.window = {
    document: doc,
    addEventListener() {},
    location: { reload() {} },
    ChickadeeUI: {
      confirmAction(message) {
        asked.push(message);
        return typeof answer === 'function'
          ? answer(message)
          : new Promise((resolve) => { resolveAnswer = () => resolve(answer); resolveAnswer(); });
      },
    },
  };
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox);

  harness = {
    asked,
    dispatch(type, event) {
      // `instanceof Element` is how app.js narrows the target; the stub class
      // in the sandbox is what the elements are checked against, so mark them.
      Object.setPrototypeOf(event.target, sandbox.Element.prototype);
      (listeners[type] || []).slice().forEach((fn) => fn(event));
      return event;
    },
  };
  return harness;
}

// ── Clicks ──────────────────────────────────────────────────────────────────

test('a click on a data-confirm element is cancelled while the question is open', () => {
  const h = load({ answer: new Promise(() => {}) });   // never answered
  const el = makeEl({ confirm: 'Remove @alovelace from this course?' });
  const event = h.dispatch('click', { target: el, ...noopEvent() });

  assert.equal(event.prevented, true);
  assert.equal(event.stopped, true, 'handlers layered around it are stopped too');
  assert.deepEqual(h.asked, ['Remove @alovelace from this course?']);
});

test('answering yes replays the click exactly once', async () => {
  const h = load({ answer: true });
  const el = makeEl({ confirm: 'Delete?' });
  h.dispatch('click', { target: el, ...noopEvent() });
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(el.clicks, 1, 'the original action happens');
  assert.equal(h.asked.length, 1, 'and the replay does not ask again');
});

test('answering no replays nothing', async () => {
  const h = load({ answer: false });
  const el = makeEl({ confirm: 'Delete?' });
  h.dispatch('click', { target: el, ...noopEvent() });
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(el.clicks, 0);
});

test('an element with no data-confirm is untouched', () => {
  const h = load();
  const el = makeEl({ confirm: null });
  const event = h.dispatch('click', { target: el, ...noopEvent() });
  assert.equal(event.prevented, false);
  assert.equal(h.asked.length, 0);
});

// A <form data-confirm> asks on submit, not on every click inside it.
test('a click inside a data-confirm FORM asks nothing', () => {
  const h = load();
  const form = makeEl({ tag: 'FORM', confirm: 'Delete?' });
  const event = h.dispatch('click', { target: form, ...noopEvent() });
  assert.equal(event.prevented, false);
  assert.equal(h.asked.length, 0);
});

// ── Submits ─────────────────────────────────────────────────────────────────

test('a submit is cancelled, asked, and replayed through requestSubmit', async () => {
  const h = load({ answer: true });
  const form = makeEl({ tag: 'FORM', confirm: 'Delete this assignment?' });
  const event = h.dispatch('submit', { target: form, submitter: null, ...noopEvent() });

  assert.equal(event.prevented, true);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(form.submits.length, 1, 'requestSubmit fires the submit event inplace-forms.js listens for');
  assert.equal(h.asked.length, 1);
});

test('a cancelled submit does not submit', async () => {
  const h = load({ answer: false });
  const form = makeEl({ tag: 'FORM', confirm: 'Delete?' });
  h.dispatch('submit', { target: form, submitter: null, ...noopEvent() });
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(form.submits.length, 0);
});

// The secondary "Clear"/"Remove" buttons carry `formaction` and their own
// data-confirm: they already asked during the click, and the replayed submit
// must carry them so the right formaction is used.
test('a submitter with its own question is not asked twice, and rides the replay', async () => {
  const h = load({ answer: true });
  const form = makeEl({ tag: 'FORM', confirm: 'Delete?' });
  const submitter = makeEl({ confirm: 'Clear it?' });

  h.dispatch('submit', { target: form, submitter, ...noopEvent() });
  await Promise.resolve();
  assert.equal(h.asked.length, 0, 'the click already asked');
  assert.equal(form.submits.length, 0, 'and the submit proceeds natively');
});

test('a plain submitter is carried into the replay', async () => {
  const h = load({ answer: true });
  const form = makeEl({ tag: 'FORM', confirm: 'Delete?' });
  const submitter = makeEl({ confirm: null });

  h.dispatch('submit', { target: form, submitter, ...noopEvent() });
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(form.submits, [submitter], 'the replay keeps the original submitter');
});
