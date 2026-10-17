import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

import { loadRunnerWasm } from './support/runner-wasm.mjs';

// Browser side of the shared output-interpretation contract. Drives every case
// in Tests/Fixtures/output-contract.json through the REAL vendored RunnerCore
// wasm (the same Swift `interpretScriptOutput`, invoked via `executeSuites`),
// and asserts the browser produces byte-for-byte the same status / shortResult /
// longResult the native worker does (the fixture's `native` block) — and never
// leaks the raw JSON result envelope into student-facing strings. The native
// side is asserted by Tests/WorkerTests/OutputContractTests.swift; both consume
// one fixture, so the two runners cannot drift.

async function ensureWasm() {
  await loadRunnerWasm();
  if (typeof globalThis.runnerExecuteSuites !== 'function') {
    throw new Error('RunnerCore wasm did not register runnerExecuteSuites');
  }
}

// Interpret one case's raw script output through the real wasm by running a
// single-script suite whose `run` callback returns exactly that raw output.
async function interpretViaWasm(c) {
  const suites = [{ script: 'case.py', tier: 'public', dependsOn: [], points: 1 }];
  const scriptExists = () => true;
  const run = async () => ({
    exitCode: c.exitCode,
    stdout: c.stdout ?? '',
    stderr: c.stderr ?? '',
    executionTimeMs: 0,
    timedOut: c.timedOut ?? false,
  });
  const outcomes = await globalThis.runnerExecuteSuites(suites, 10, 1, scriptExists, run);
  return outcomes[0];
}

function leaksEnvelope(value) {
  if (typeof value !== 'string') return false;
  return value.includes('"shortResult"') || value.includes('"status"') || value.trim().startsWith('{');
}

test('browser wasm interprets output identically to the native worker (shared fixture)', async () => {
  await ensureWasm();
  const corpus = JSON.parse(
    await fs.readFile(path.resolve('Tests/Fixtures/output-contract.json'), 'utf8'),
  );

  for (const c of corpus.cases) {
    const outcome = await interpretViaWasm(c);

    assert.equal(outcome.status, c.status, `status mismatch for case '${c.name}'`);

    if (c.native) {
      assert.equal(outcome.shortResult, c.native.shortResult,
        `shortResult mismatch for case '${c.name}'`);
      assert.equal(outcome.longResult ?? null, c.native.longResult ?? null,
        `longResult mismatch for case '${c.name}'`);
      // Required, not once-present: the vendored artifact carries every field,
      // and a stale artifact must fail here rather than pass by omission.
      assert.equal(typeof outcome.score, 'number', `score missing for case '${c.name}'`);
      assert.ok(Math.abs(outcome.score - c.native.score) < 1e-9,
        `score mismatch for case '${c.name}': ${outcome.score} != ${c.native.score}`);
      assert.notEqual(outcome.metric, undefined, `metric missing for case '${c.name}'`);
      assert.equal(outcome.metric ?? null, c.native.metric ?? null,
        `metric mismatch for case '${c.name}'`);
      assert.notEqual(outcome.composite, undefined, `composite missing for case '${c.name}'`);
      assert.deepEqual(outcome.composite ?? null, c.native.composite ?? null,
        `composite mismatch for case '${c.name}'`);
    }

    assert.ok(!leaksEnvelope(outcome.shortResult),
      `shortResult leaked the JSON envelope for case '${c.name}': ${outcome.shortResult}`);
    assert.ok(!leaksEnvelope(outcome.longResult),
      `longResult leaked the JSON envelope for case '${c.name}': ${outcome.longResult}`);
  }
});
