import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Guards against the embedded runtime helpers in Public/browser-runner.js
// drifting from the canonical copies in Tools/runner-support/.  The Swift embeds
// are checked separately by Tests/WorkerTests/RuntimeSourceDriftTests.swift.
//
// Comparison is over executable code only: blank lines and full-line comments
// are stripped, since the embeds intentionally omit some documentation comments
// but MUST keep identical behaviour.  The comment marker is per-language — `#`
// for Python and R, `--` for Lua — so a reworded Lua comment does not read as a
// behaviour change and teach everyone to stop reading the diff.

function normalizeCode(src, comment = '#') {
  return String(src)
    .split('\n')
    .filter(line => {
      const s = line.trim();
      return s && !s.startsWith(comment);
    })
    .map(line => line.replace(/[ \t]+$/, ''))
    .join('\n');
}

async function loadEmbeds() {
  const runnerSource = await fs.readFile(path.resolve('Public/browser-runner.js'), 'utf8');
  const sharedSource = await fs.readFile(path.resolve('Public/grading-shared.js'), 'utf8');
  const rSharedSource = await fs.readFile(path.resolve('Public/r-grading-shared.js'), 'utf8');
  const luaSharedSource = await fs.readFile(path.resolve('Public/lua-grading-shared.js'), 'utf8');
  const testHooks = {};
  const statusEl = { hidden: true, textContent: '', className: '' };
  const document = {
    currentScript: { dataset: { gradingMode: 'browser' } },
    getElementById: () => statusEl,
  };
  const context = {
    console,
    document,
    __CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__: testHooks,
  };
  context.window = { document };
  context.globalThis = context;
  // The shared-semantics modules first (they define ChickadeeGradingShared and
  // ChickadeeRGradingShared and ChickadeeLuaGradingShared), same as the page.
  const vmContext = vm.createContext(context);
  vm.runInContext(sharedSource, vmContext, { filename: 'grading-shared.js' });
  vm.runInContext(rSharedSource, vmContext, { filename: 'r-grading-shared.js' });
  vm.runInContext(luaSharedSource, vmContext, { filename: 'lua-grading-shared.js' });
  vm.runInContext(runnerSource, vmContext, { filename: 'browser-runner.js' });
  return testHooks.exports;
}

test('embedded TEST_RUNTIME_PY stays in sync with Tools/runner-support/test_runtime.py', async () => {
  const embeds = await loadEmbeds();
  const canon = await fs.readFile(path.resolve('Tools/runner-support/test_runtime.py'), 'utf8');
  assert.equal(
    normalizeCode(embeds.TEST_RUNTIME_PY),
    normalizeCode(canon),
    'Public/browser-runner.js TEST_RUNTIME_PY drifted from Tools/runner-support/test_runtime.py — '
      + 're-sync both, and Sources/Worker/TestRuntimeSources.swift.',
  );
});

test('embedded TEST_RUNTIME_R stays in sync with Tools/runner-support/test_runtime.R', async () => {
  // The browser R grader writes this into every grading workspace so an R test
  // script's `source("test_runtime.R")` resolves to the same helpers the native
  // runner injects (#1271). Three copies now exist — this embed, the canonical
  // file, and the testRuntimeR* literals in Sources/Worker/TestRuntimeSources.swift
  // (pinned by Tests/WorkerTests/RuntimeSourceDriftTests.swift) — and a drift in
  // any of them would make a submission grade differently depending on whether it
  // was graded in the browser or by the worker.
  const embeds = await loadEmbeds();
  const canon = await fs.readFile(path.resolve('Tools/runner-support/test_runtime.R'), 'utf8');
  assert.equal(
    normalizeCode(embeds.TEST_RUNTIME_R),
    normalizeCode(canon),
    'Public/browser-runner.js TEST_RUNTIME_R drifted from Tools/runner-support/test_runtime.R — '
      + 're-sync both, and Sources/Worker/TestRuntimeSources.swift.',
  );
});

test('embedded SITECUSTOMIZE_PY stays in sync with Tools/runner-support/sitecustomize.py', async () => {
  const embeds = await loadEmbeds();
  const canon = await fs.readFile(path.resolve('Tools/runner-support/sitecustomize.py'), 'utf8');
  assert.equal(
    normalizeCode(embeds.SITECUSTOMIZE_PY),
    normalizeCode(canon),
    'Public/browser-runner.js SITECUSTOMIZE_PY drifted from Tools/runner-support/sitecustomize.py — '
      + 're-sync both, and Sources/Worker/TestRuntimeSources.swift.',
  );
});

test('embedded TEST_RUNTIME_LUA stays in sync with Tools/runner-support/test_runtime.lua', async () => {
  const embeds = await loadEmbeds();
  const canon = await fs.readFile(path.resolve('Tools/runner-support/test_runtime.lua'), 'utf8');
  assert.equal(
    normalizeCode(embeds.TEST_RUNTIME_LUA, '--'),
    normalizeCode(canon, '--'),
    'Public/browser-runner.js TEST_RUNTIME_LUA drifted from Tools/runner-support/test_runtime.lua — '
      + 're-sync both, and Sources/Worker/TestRuntimeSources.swift.',
  );
});
