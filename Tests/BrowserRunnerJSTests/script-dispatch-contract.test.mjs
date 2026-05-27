import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Cross-runner script-dispatch contract (browser side).
//
// The browser runner (Public/browser-runner.js, classifyScript) and the native
// worker (Sources/Worker/ScriptInvocation.swift, scriptInvocation) each decide
// how to dispatch a test script. They are independent implementations of the
// same rules, so they drift — twice now in two weeks (extensionless Python
// scripts misclassified as unsupported, #754). This test pins the browser side
// to a shared fixture; Tests/WorkerTests/ScriptDispatchContractTests.swift pins
// the worker side to the same fixture. Same input -> same kind, in both runners.

async function loadExports() {
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

const fixture = JSON.parse(
  await fs.readFile(path.resolve('Tests/Fixtures/script-dispatch-cases.json'), 'utf8'),
);

test('browser runner classifies every shared dispatch case as the contract requires', async () => {
  const { classifyScript } = await loadExports();
  assert.equal(typeof classifyScript, 'function', 'classifyScript must be exported via test hooks');

  for (const c of fixture.cases) {
    assert.equal(
      classifyScript(c.name, c.content),
      c.kind,
      `Dispatch contract violated for "${c.name}" (${c.note}): browser classifyScript `
        + `disagrees with Tests/Fixtures/script-dispatch-cases.json. If you changed the rules, `
        + `update both runners (Public/browser-runner.js and Sources/Worker/ScriptInvocation.swift) `
        + `and the fixture together.`,
    );
  }
});
