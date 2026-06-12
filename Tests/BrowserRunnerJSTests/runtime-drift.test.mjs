import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Guards against the embedded Python runtime helpers in Public/browser-runner.js
// drifting from the canonical copies in Tools/runner-support/.  The Swift embeds
// are checked separately by Tests/WorkerTests/RuntimeSourceDriftTests.swift.
//
// Comparison is over executable code only: blank lines and full-line comments
// are stripped, since the embeds intentionally omit some documentation comments
// but MUST keep identical behaviour.

function normalizeCode(src) {
  return String(src)
    .split('\n')
    .filter(line => {
      const s = line.trim();
      return s && !s.startsWith('#');
    })
    .map(line => line.replace(/[ \t]+$/, ''))
    .join('\n');
}

async function loadEmbeds() {
  const runnerSource = await fs.readFile(path.resolve('Public/browser-runner.js'), 'utf8');
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
  vm.runInNewContext(runnerSource, context, { filename: 'browser-runner.js' });
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
