import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Browser side of the shared output-interpretation contract. Feeds the cases in
// Tests/Fixtures/output-contract.json through the browser runner's runPyScript
// and asserts (a) the status matches the shared `status` field — keeping the two
// runners' GRADING lock-step with the native worker — and (b) the raw JSON
// result envelope never leaks into the student-facing strings. The native side
// is asserted by Tests/WorkerTests/OutputContractTests.swift.

async function loadHooks() {
  const runnerSource = await fs.readFile(path.resolve('Public/browser-runner.js'), 'utf8');
  const testHooks = {};
  const statusEl = { hidden: true, textContent: '', className: '' };
  const document = {
    currentScript: { dataset: { gradingMode: 'browser' } },
    getElementById: () => statusEl,
  };
  const context = {
    console,
    setTimeout,
    clearTimeout,
    Date,
    document,
    __CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__: testHooks,
  };
  context.window = { document };
  context.globalThis = context;
  vm.runInNewContext(runnerSource, context, { filename: 'browser-runner.js' });
  return testHooks.exports;
}

// Minimal Pyodide stand-in: runPyScript only drives stdout/stderr capture and a
// compile()+exec() call; we intercept those and return the case's recorded
// process output. Mirrors createPyodideHarness in browser-runner.test.mjs.
function makePy(behavior) {
  const state = { stdout: '', stderr: '', exitCode: null };
  return {
    async loadPackagesFromImports() {},
    async runPythonAsync(code) {
      if (code.includes('_br_stdout = io.StringIO()')) {
        state.stdout = ''; state.stderr = ''; state.exitCode = null;
        return null;
      }
      if (code.includes("compile(open('")) {
        state.stdout = behavior.stdout ?? '';
        state.stderr = behavior.stderr ?? '';
        state.exitCode = behavior.exitCode ?? null;
        return null;
      }
      if (code.includes('str(_br_stdout.getvalue())')) {
        return { toJs() { return [state.stdout, state.stderr, state.exitCode]; }, destroy() {} };
      }
      return null;
    },
  };
}

function leaksEnvelope(value) {
  if (typeof value !== 'string') return false;
  return value.includes('"shortResult"') || value.includes('"status"') || value.trim().startsWith('{');
}

test('browser runner agrees on status and never leaks the JSON envelope', async () => {
  const hooks = await loadHooks();
  const corpus = JSON.parse(
    await fs.readFile(path.resolve('Tests/Fixtures/output-contract.json'), 'utf8'),
  );

  for (const c of corpus.cases) {
    const py = makePy({ stdout: c.stdout, stderr: c.stderr, exitCode: c.exitCode });
    const outcome = await hooks.runPyScript(py, `# ${c.name}`, 'case.py', 'public', 10);

    assert.equal(outcome.status, c.status, `status mismatch for case '${c.name}'`);
    assert.ok(!leaksEnvelope(outcome.shortResult),
      `shortResult leaked the JSON envelope for case '${c.name}': ${outcome.shortResult}`);
    assert.ok(!leaksEnvelope(outcome.longResult),
      `longResult leaked the JSON envelope for case '${c.name}': ${outcome.longResult}`);
  }
});
