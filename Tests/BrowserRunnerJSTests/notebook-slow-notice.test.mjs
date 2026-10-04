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
const template = await fs.readFile(path.resolve('Resources/Views/_notebook-body.leaf'), 'utf8');
const notebookSource = await fs.readFile(path.resolve('Public/notebook.js'), 'utf8');

/// A stub element with what notebook-preflight.js touches.
function element(children = {}) {
  const handlers = {};
  return {
    hidden: true,
    textContent: '',
    href: '',
    style: {},
    dataset: {},
    querySelector: (selector) => children[selector] ?? null,
    addEventListener(type, fn) { (handlers[type] ||= []).push(fn); },
    click() { (handlers.click || []).forEach((fn) => fn()); },
  };
}

function loadPage() {
  const slowTitle = element();
  const slowText = element();
  const elements = {
    'nb-slow-notice': element({ '.js-nb-slow-title': slowTitle, '.js-nb-slow-text': slowText }),
    'nb-slow-notice-dismiss': element(),
    'js-nb-fallback': element({ '.js-nb-fallback-title': element(), '.js-nb-fallback-text': element() }),
    'js-nb-fallback-details': element(),
    'jl-frame': element(),
    'nb-reset-editor-link': element(),
  };
  const posts = [];
  const ctx = {
    console, JSON, Array, Object, Math, String, Promise, Error,
    document: {
      getElementById: (id) => elements[id] ?? null,
      querySelector: () => null,
    },
    navigator: { userAgent: 'UA/1' },
    location: { pathname: '/CS136/lab1', search: '' },
    fetch: (url, init) => { posts.push(JSON.parse(init.body)); return Promise.resolve({}); },
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.runInNewContext(coreSource, ctx, { filename: 'notebook-preflight-core.js' });
  vm.runInNewContext(wiringSource, ctx, { filename: 'notebook-preflight.js' });
  return { failures: ctx.ChickadeeNotebookFailures, core: ctx.ChickadeeNotebookPreflightCore, elements, slowTitle, slowText, posts };
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

test('Dismiss hides the slow-boot banner', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, false);
  page.elements['nb-slow-notice-dismiss'].click();
  assert.equal(page.elements['nb-slow-notice'].hidden, true);
});

test('a failure after a slow boot replaces the banner with the panel', () => {
  const page = loadPage();
  page.failures.showSlowEditorNotice();
  assert.equal(page.elements['nb-slow-notice'].hidden, false);
  page.failures.showFailure({ kind: 'watchdog_timeout' });
  assert.equal(page.elements['nb-slow-notice'].hidden, true);
  assert.equal(page.elements['js-nb-fallback'].hidden, false);
  assert.match(page.elements['js-nb-fallback-details'].textContent, /^Failure: watchdog_timeout/);
});

test('the fallback copy is one sentence per text', () => {
  const { core } = loadPage();
  for (const variant of ['memory', 'slow']) {
    const text = core.FALLBACK_COPY[variant].text;
    assert.equal((text.match(/[.?!](\s|$)/g) || []).length, 1, variant + ': "' + text + '"');
  }
});

test('the slow-boot banner is a status warning with its own upload input', () => {
  // Read the banner's open tag, not the document: a comment may name it.
  const open = /<div id="nb-slow-notice"[^>]*>/.exec(template);
  assert.ok(open, 'the banner must exist');
  assert.match(open[0], /class="flash flash-warning"/);
  assert.match(open[0], /role="status"/);
  assert.match(open[0], /\shidden[\s>]/);
  const start = template.indexOf(open[0]);
  const banner = template.slice(start, template.indexOf('</div>\n</div>', start));
  assert.match(banner, /<input type="file" id="nb-slow-upload-file"/);
  // notebook.js gives both inputs the one upload handler.
  assert.match(notebookSource, /'nb-upload-file', 'nb-slow-upload-file'/);
});
