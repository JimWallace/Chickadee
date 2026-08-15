// Unit tests for the destructive-action confirmation
// (ChickadeeUI.confirmAction in Public/chickadee-ui.js, plus the data-confirm
// seam in Public/app.js).
//
// This replaced window.confirm, which covered 41 destructive actions — 36
// `data-confirm` attributes across 18 templates and 5 direct callers — and was
// the last piece of UI outside the design system: unthemed, unstyleable, and
// invisible to the axe scan because the browser chrome drew it, not the page.
//
// Two things are worth pinning. The DIALOG's own behaviour is mostly
// accessibility: what takes focus, what Escape does, where focus goes back to.
// And the SEAM's, which changed shape: a real dialog cannot block the event
// loop, so app.js now always cancels the action, asks, and REPLAYS it on yes.
// The replay is where a regression would be silent and expensive — a
// destructive action that fires without asking, or one that asks and then
// never happens.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const uiSource = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

// ── A DOM just real enough ──────────────────────────────────────────────────

function makeDoc() {
  const listeners = {};
  const doc = {
    readyState: 'complete',
    body: null,
    activeElement: null,
    listeners,
    createElement(tag) { return makeEl(tag, doc); },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn);
    },
    querySelector: () => null,
    dispatch(type, event) { (listeners[type] || []).slice().forEach((fn) => fn(event)); },
  };
  doc.body = makeEl('body', doc);
  return doc;
}

function makeEl(tag, doc) {
  return {
    tagName: tag.toUpperCase(),
    ownerDocument: doc,
    className: '',
    textContent: '',
    id: '',
    type: '',
    attrs: {},
    children: [],
    parentNode: null,
    handlers: {},
    focused: 0,
    setAttribute(n, v) { this.attrs[n] = String(v); },
    getAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; },
    hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    removeChild(c) { this.children = this.children.filter((x) => x !== c); c.parentNode = null; return c; },
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
    click() { (this.handlers.click || []).slice().forEach((fn) => fn({ target: this })); },
    focus() { this.focused += 1; if (this.ownerDocument) this.ownerDocument.activeElement = this; },
    querySelector: () => null,
    closest: () => null,
  };
}

function loadUI(doc) {
  const sandbox = { document: doc, window: {}, Promise, module: { exports: {} } };
  sandbox.self = sandbox;
  sandbox.window.document = doc;
  vm.createContext(sandbox);
  vm.runInContext(uiSource, sandbox);
  return sandbox.window.ChickadeeUI || sandbox.ChickadeeUI;
}

function dialogParts(doc) {
  const overlay = doc.body.children.find((c) => c.className === 'modal-overlay');
  if (!overlay) return null;
  const card = overlay.children[0];
  const foot = card.children[1];
  return { overlay, card, body: card.children[0], cancel: foot.children[0], confirm: foot.children[1] };
}

// ── The dialog ──────────────────────────────────────────────────────────────

test('the dialog announces itself as an alert dialog carrying the question', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  UI.confirmAction('Remove @alovelace from this course?');

  const parts = dialogParts(doc);
  assert.ok(parts, 'a dialog is mounted');
  assert.equal(parts.card.getAttribute('role'), 'alertdialog');
  assert.equal(parts.card.getAttribute('aria-modal'), 'true');
  assert.equal(parts.body.textContent, 'Remove @alovelace from this course?');
  assert.equal(parts.card.getAttribute('aria-describedby'), parts.body.id);
});

// The message is user/instructor-authored text (a student's username, a test
// script's filename). It goes in as textContent, never as markup.
test('the question is set as text, not parsed as markup', () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  UI.confirmAction('Delete "<img src=x onerror=alert(1)>"?');
  const parts = dialogParts(doc);
  assert.equal(parts.body.textContent, 'Delete "<img src=x onerror=alert(1)>"?');
  assert.equal(parts.body.children.length, 0, 'no elements were created from the message');
});

test('Cancel takes focus, so an accidental Enter is the safe answer', () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  UI.confirmAction('Delete everything?');
  const parts = dialogParts(doc);
  assert.equal(parts.cancel.focused, 1);
  assert.equal(parts.confirm.focused, 0);
});

test('confirming resolves true and removes the dialog', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const answer = UI.confirmAction('Delete?');
  dialogParts(doc).confirm.click();
  assert.equal(await answer, true);
  assert.equal(dialogParts(doc), null, 'the dialog is gone');
});

test('cancelling resolves false', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const answer = UI.confirmAction('Delete?');
  dialogParts(doc).cancel.click();
  assert.equal(await answer, false);
});

test('Escape cancels', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const answer = UI.confirmAction('Delete?');
  let prevented = false;
  doc.dispatch('keydown', { key: 'Escape', preventDefault: () => { prevented = true; } });
  assert.equal(await answer, false);
  assert.equal(prevented, true, 'Escape is consumed, not passed to the page beneath');
});

test('a click on the scrim cancels; a click inside the card does not', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const answer = UI.confirmAction('Delete?');
  const parts = dialogParts(doc);

  parts.overlay.handlers.click.forEach((fn) => fn({ target: parts.card }));
  assert.ok(dialogParts(doc), 'a click inside the card leaves the dialog open');

  parts.overlay.handlers.click.forEach((fn) => fn({ target: parts.overlay }));
  assert.equal(await answer, false);
});

test('Tab cycles between the two buttons rather than leaving the dialog', () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  UI.confirmAction('Delete?');
  const parts = dialogParts(doc);

  doc.dispatch('keydown', { key: 'Tab', preventDefault: () => {} });
  assert.equal(doc.activeElement, parts.confirm);
  doc.dispatch('keydown', { key: 'Tab', preventDefault: () => {} });
  assert.equal(doc.activeElement, parts.cancel);
});

test('focus returns to whatever had it, so the page does not jump to the top', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const trigger = makeEl('button', doc);
  trigger.focus();
  const before = trigger.focused;

  const answer = UI.confirmAction('Delete?', trigger);
  dialogParts(doc).cancel.click();
  await answer;
  assert.ok(trigger.focused > before, 'the trigger is focused again on close');
});

test('the dialog settles once even if answered twice', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const answer = UI.confirmAction('Delete?');
  const parts = dialogParts(doc);
  parts.cancel.click();
  parts.confirm.click();          // a stray second click must not re-resolve
  assert.equal(await answer, false);
});

test('the keydown listener is removed when the dialog closes', async () => {
  const doc = makeDoc();
  const UI = loadUI(doc);
  const before = (doc.listeners.keydown || []).length;
  const answer = UI.confirmAction('Delete?');
  assert.equal((doc.listeners.keydown || []).length, before + 1);
  dialogParts(doc).cancel.click();
  await answer;
  assert.equal((doc.listeners.keydown || []).length, before, 'no listener is left behind');
});
