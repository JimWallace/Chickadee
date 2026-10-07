// Tests for Public/grading-executors.js on its own, without the browser
// runner. The runner-level behaviour (routing, kill and respawn, the init
// bound) is pinned through the runner in browser-runner.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const source = fs.readFileSync(path.resolve('Public/grading-executors.js'), 'utf8');

function loadExecutors() {
  const context = { console, setTimeout, clearTimeout, TextDecoder };
  context.globalThis = context;
  vm.runInContext(source, vm.createContext(context), { filename: 'grading-executors.js' });
  return context.ChickadeeGradingExecutors;
}

// A grading worker that answers `init`, and answers `run` after it sends the
// breadcrumbs it was given, as the real worker does around an on-demand
// package install.
function fakeWorkerFactory(phasesDuringRun) {
  return () => ({
    onmessage: null,
    onerror: null,
    postMessage(msg) {
      Promise.resolve().then(() => {
        if (msg.type === 'run') {
          for (const phase of phasesDuringRun) this.onmessage({ data: phase });
          this.onmessage({ data: { id: msg.id, ok: true, result: { exitCode: 0, stdout: '', stderr: '' } } });
        } else {
          this.onmessage({ data: { id: msg.id, ok: true } });
        }
      });
    },
    terminate() {},
  });
}

test('phaseDetail keeps the timing and the installed packages of a breadcrumb', () => {
  const { phaseDetail } = loadExecutors();
  assert.equal(phaseDetail({ type: 'phase', phase: 'x', ms: 12 }), 'ms=12');
  assert.equal(
    phaseDetail({ type: 'phase', phase: 'python_package_installed', packages: 'pandas,numpy' }),
    'packages=pandas,numpy');
  assert.equal(phaseDetail({ type: 'phase', phase: 'x', ms: 0, packages: 'dplyr' }), 'ms=0;packages=dplyr');
  assert.equal(phaseDetail({ type: 'phase', phase: 'x' }), undefined);
});

test('GradingWorkerExecutor forwards the package names of an on-demand install to telemetry', async () => {
  const executors = loadExecutors();
  const { GradingWorkerExecutor } = executors.makeGradingExecutors({ workerScripts: {}, languageLabels: {} });
  const reported = [];
  const executor = new GradingWorkerExecutor(
    { 'test.R': 'library(dplyr)\n' },
    null,
    null,
    fakeWorkerFactory([{ type: 'phase', phase: 'r_package_installed', packages: 'dplyr' }]),
    (phase, detail) => reported.push({ phase, detail }),
    'R');

  const result = await executor.run('test.R', 5);

  assert.equal(result.exitCode, 0);
  assert.deepEqual(
    reported.filter(r => r.phase === 'r_package_installed'),
    [{ phase: 'r_package_installed', detail: 'packages=dplyr' }]);
});
