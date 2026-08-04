// Unit tests for ChickadeeUI.reloadEditSurface — how a page that is rendered
// into a workbench pane re-renders itself after a write.
//
// The property under test is a navigation sink. `reloadEditSurface` reads
// `data-ck-panel-url` off <body> and hands it to `location.replace`, which is
// DOM text reaching a sink that will execute a `javascript:` URL. The attribute
// is server-written today, so nothing hostile reaches it — the guard exists so
// that stays true if a future page ever sets it from data it did not author,
// and CodeQL flags the unguarded form (it flagged exactly this one).
//
// The fallback matters as much as the rejection: a rejected URL must still
// re-render the surface, because every caller has just written something to the
// server and is asking to see the result. Failing closed by doing nothing would
// leave the author looking at stale state with no error.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/chickadee-ui.js'), 'utf8');

/// Load chickadee-ui.js against a stub DOM whose <body> carries `panelAttr`,
/// recording which navigation the module performs.
function load(panelAttr) {
  const calls = [];
  const body = {
    getAttribute: (name) => (name === 'data-ck-panel-url' ? panelAttr : null),
  };
  const document = { body, querySelector: () => null };
  const window = {
    location: {
      origin: 'https://chickadee.example',
      reload: () => calls.push({ kind: 'reload' }),
      replace: (url) => calls.push({ kind: 'replace', url }),
    },
    document,
    scrollY: 0,
    sessionStorage: { setItem: () => {}, getItem: () => null, removeItem: () => {} },
  };
  window.parent = window;

  const context = vm.createContext({ window, document, globalThis: {} });
  vm.runInContext(source, context);
  return { ui: window.ChickadeeUI, calls };
}

test('reloadEditSurface: navigates to a well-formed panel URL', () => {
  const { ui, calls } = load('/instructor/DEJr2f/workbench/panel');
  ui.reloadEditSurface();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].kind, 'replace');
  assert.equal(calls[0].url, '/instructor/DEJr2f/workbench/panel');
});

test('reloadEditSurface: plainly reloads when there is no panel URL', () => {
  // The standalone /edit page. It emits no attribute, and following its own
  // handlers' redirects is the correct behaviour there.
  const { ui, calls } = load(null);
  ui.reloadEditSurface();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].kind, 'reload');
});

test('reloadEditSurface: refuses a URL that is not a panel route', () => {
  // Each of these reaches `location.replace` if the pattern is dropped; the
  // first two would execute. All must fall back to a plain reload — the surface
  // still re-renders, only the pane-aware destination is lost.
  const hostile = [
    'javascript:alert(1)',
    'JavaScript:alert(1)',
    'https://evil.example/instructor/x/workbench/panel',
    '//evil.example/instructor/x/workbench/panel',
    '/instructor/x/workbench/panel/../../../admin',
    '/instructor/x/edit',
    '/instructor/x/workbench/panel?next=evil',
    '',
  ];

  for (const url of hostile) {
    const { ui, calls } = load(url);
    ui.reloadEditSurface();
    assert.equal(calls.length, 1, `expected exactly one navigation for ${JSON.stringify(url)}`);
    assert.equal(
      calls[0].kind, 'reload',
      `${JSON.stringify(url)} reached location.replace — the panel-URL pattern let it through`);
  }
});
