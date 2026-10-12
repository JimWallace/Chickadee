// The slow-boot notice on the notebook page (#2028).
//
// A slow boot used to rewrite and reveal the failure panel (#js-nb-fallback),
// a role="alert" stand-in for an editor that is not there, while the editor was
// still on the page and loading. Its "Diagnostic details" box was empty, and
// its copy was three sentences. A slow boot now reveals its own dismissible
// warning banner, with an upload input, and the failure panel is for a failure
// only.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const coreSource = await fs.readFile(path.resolve('Public/notebook-preflight-core.js'), 'utf8');
const wiringSource = await fs.readFile(path.resolve('Public/notebook-preflight.js'), 'utf8');
const view = await fs.readFile(path.resolve('Sources/APIServer/Views/NotebookBody.swift'), 'utf8');
const layoutSource = await fs.readFile(path.resolve('Sources/APIServer/Views/BaseLayout.swift'), 'utf8');
const notebookSource = await fs.readFile(path.resolve('Public/notebook.js'), 'utf8');

/// A stub element with what notebook-preflight.js touches. `inner` lists the
/// elements inside it, for `contains`.
function element(children = {}, inner = []) {
  const handlers = {};
  const el = {
    hidden: true,
    textContent: '',
    href: '',
    style: {},
    dataset: {},
    querySelector: (selector) => children[selector] ?? null,
    contains: (node) => node === el || inner.includes(node),
    addEventListener(type, fn) { (handlers[type] ||= []).push(fn); },
    click() { (handlers.click || []).forEach((fn) => fn()); },
  };
  return el;
}

function loadPage() {
  const slowTitle = element();
  const slowText = element();
  const slowUpload = element();
  const slowDismiss = element();
  const doc = {
    activeElement: null,
    getElementById: (id) => elements[id] ?? null,
    querySelector: () => null,
  };
  const status = element();
  status.focus = () => { doc.activeElement = status; };
  const elements = {
    'nb-slow-notice': element(
      { '.js-nb-slow-title': slowTitle, '.js-nb-slow-text': slowText },
      [slowTitle, slowText, slowUpload, slowDismiss]),
    'nb-slow-notice-dismiss': slowDismiss,
    'nb-slow-upload-file': slowUpload,
    'nb-status': status,
    'js-nb-fallback': element({ '.js-nb-fallback-title': element(), '.js-nb-fallback-text': element() }),
    'js-nb-fallback-details': element(),
    'jl-frame': element(),
    'nb-reset-editor-link': element(),
  };
  const posts = [];
  const ctx = {
    console, JSON, Array, Object, Math, String, Promise, Error,
    document: doc,
    navigator: { userAgent: 'UA/1' },
    location: { pathname: '/CS136/lab1', search: '' },
    fetch: (url, init) => { posts.push(JSON.parse(init.body)); return Promise.resolve({}); },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(coreSource, ctx, { filename: 'notebook-preflight-core.js' });
  vm.runInNewContext(wiringSource, ctx, { filename: 'notebook-preflight.js' });
  return { failures: ctx.ChickadeeNotebookFailures, core: ctx.ChickadeeNotebookPreflightCore, elements, doc, slowTitle, slowText, posts };
}

test('a slow boot reveals the warning banner and leaves the failure panel hidden', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, false);
  assert.equal(page.slowTitle.textContent, page.core.FALLBACK_COPY.slow.title);
  assert.equal(page.slowText.textContent, page.core.FALLBACK_COPY.slow.text);
  assert.equal(page.elements['js-nb-fallback'].hidden, true, 'the failure panel is for a failure only');
  // The telemetry beacon does not change.
  assert.equal(page.posts.length, 1);
  assert.equal(page.posts[0].source, 'slow_boot_notice');
});

test('Dismiss hides the slow-boot banner and moves focus to the status line', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, false);
  page.elements['nb-slow-notice-dismiss'].click();
  assert.equal(page.elements['nb-slow-notice'].hidden, true);
  assert.equal(page.doc.activeElement, page.elements['nb-status']);
});

test('a ready kernel hides the slow-boot banner, unless focus is inside it', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  // A student choosing a file keeps the banner.
  page.doc.activeElement = page.elements['nb-slow-upload-file'];
  page.failures.hideSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, false);
  page.doc.activeElement = null;
  page.failures.hideSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, true);
  // notebook.js calls it when the kernel first reports ready.
  const ready = notebookSource.slice(notebookSource.indexOf('function markKernelEverReady'));
  assert.match(ready.slice(0, ready.indexOf('\n    }\n')), /hideSlowEditorNotice\(\)/);
});

test('a failure after a slow boot replaces the banner with the panel', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, false);
  page.failures.showFailure({ kind: 'watchdog_timeout' });
  assert.equal(page.elements['nb-slow-notice'].hidden, true);
  assert.equal(page.elements['js-nb-fallback'].hidden, false);
  assert.match(page.elements['js-nb-fallback-details'].textContent, /^Failure: watchdog_timeout/);
  // Focus was not inside the banner, so it does not move.
  assert.equal(page.doc.activeElement, null);
});

test('a failure moves focus out of the banner it hides', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  page.doc.activeElement = page.elements['nb-slow-upload-file'];
  page.failures.showFailure({ kind: 'watchdog_timeout' });
  assert.equal(page.doc.activeElement, page.elements['nb-status']);
});

test('the status line can take focus, and both help links say they open a new tab', () => {
  // Read from NotebookBody.swift, in its Swift spelling.
  assert.match(view, /span\(\s*\.class\("nb-status"\),\s*\.id\("nb-status"\)[^{]*\.tabindex\(-1\)/);
  // Both links go through helpLink, and nothing else links the help page.
  const links = [...view.matchAll(/helpLink\(\s*"[^"]*notebook-editor-help\.md[^"]*"/g)];
  assert.equal(links.length, 2);
  assert.equal([...view.matchAll(/"[^"]*notebook-editor-help\.md[^"]*"/g)].length, 2);
  const helper = /private func helpLink\([\s\S]*?\n {4}\}/.exec(view);
  assert.ok(helper, 'NotebookBody has no helpLink');
  assert.match(helper[0], /\.target\(\.blank\)/);
  assert.match(helper[0], /Icon\("i-external"\)/);
  assert.match(helper[0], /span\(\.class\("visually-hidden"\)\) \{ "\(opens in a new tab\)" \}/);
});

test('the fallback copy is one sentence per text', () => {
  const { core } = loadPage();
  for (const variant of ['memory', 'slow']) {
    const text = core.FALLBACK_COPY[variant].text;
    assert.equal((text.match(/[.?!](\s|$)/g) || []).length, 1, variant + ': "' + text + '"');
  }
});

test('the slow-boot banner is a status warning with its own upload input', () => {
  // Read from NotebookBody.swift: the banner is the FlashBanner block that
  // ends in the attributes giving it its id. Read the code, not a comment.
  const tail = view.indexOf('.attributes(.id("nb-slow-notice"), .hidden)');
  assert.ok(tail >= 0, 'the banner must exist, hidden');
  const start = view.lastIndexOf('FlashBanner(', tail);
  const banner = view.slice(start, tail);
  // A warning banner, with the default role, which BaseLayout sets to status.
  assert.match(banner, /^FlashBanner\(\.warning\) \{/);
  assert.match(layoutSource, /case warning = "flash flash-warning"/);
  assert.match(layoutSource, /role: MarkupAttributeValue\.Role = "status"/);
  assert.match(banner, /uploadInput\(id: "nb-slow-upload-file"\)/);
  assert.match(view, /private func uploadInput\(id: String\)[\s\S]*?input\(\s*\.type\(\.file\), \.id\(id\)/);
  // notebook.js gives both inputs the one upload handler.
  assert.match(notebookSource, /'nb-upload-file', 'nb-slow-upload-file'/);
});
