// A browser test's time limit does not count an on-demand package install
// (#2380). The worker brackets each install with `<prefix>_package_install_start`
// and `<prefix>_package_install_end` breadcrumbs, and GradingWorkerExecutor
// stops the run's clock between them, up to GRADING_INIT_TIMEOUT_MS.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const source = fs.readFileSync(path.resolve('Public/grading-executors.js'), 'utf8');

function loadExecutor(initTimeoutMs) {
  const context = {
    console, setTimeout, clearTimeout, TextDecoder,
    __CHICKADEE_GRADING_INIT_TIMEOUT_MS__: initTimeoutMs,
  };
  context.globalThis = context;
  vm.runInContext(source, vm.createContext(context), { filename: 'grading-executors.js' });
  const executors = context.ChickadeeGradingExecutors.makeGradingExecutors({
    workerScripts: {}, languageLabels: {}, interpreterKinds: {},
  });
  return executors.GradingWorkerExecutor;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/// A grading worker whose `run` plays `script`, a list of steps: a number
/// waits that many milliseconds, a string sends that phase breadcrumb, and
/// the end of the list replies with a pass.
function workerFactory(script) {
  return () => ({
    onmessage: null,
    onerror: null,
    terminated: false,
    postMessage(msg) {
      const send = (data) => { if (!this.terminated) this.onmessage({ data }); };
      if (msg.type !== 'run') {
        Promise.resolve().then(() => send({ id: msg.id, ok: true }));
        return;
      }
      (async () => {
        for (const step of script) {
          if (typeof step === 'number') await sleep(step);
          else send({ type: 'phase', phase: step });
        }
        send({ id: msg.id, ok: true, result: { exitCode: 0, stdout: 'ok\n', stderr: '' } });
      })();
    },
    terminate() { this.terminated = true; },
  });
}

async function runOnce(script, { limitSeconds = 0.3, initTimeoutMs = 5000 } = {}) {
  const GradingWorkerExecutor = loadExecutor(initTimeoutMs);
  const executor = new GradingWorkerExecutor(
    { 'test.R': 'library(dplyr)\n' }, null, null, workerFactory(script), () => {}, 'R');
  return executor.run('test.R', limitSeconds);
}

test('a script that runs past its limit still times out', async () => {
  const result = await runOnce([900]);
  assert.equal(result.timedOut, true);
});

test('time spent installing a package does not count against the limit (#2380)', async () => {
  // 300 ms limit; 30 ms of script, a 900 ms install, then 30 ms more.
  const result = await runOnce([30, 'r_package_install_start', 900, 'r_package_install_end', 30]);
  assert.equal(result.timedOut, false);
  assert.equal(result.exitCode, 0);
});

test('the script time on both sides of an install adds up', async () => {
  // 300 ms limit; 250 ms before the install and 250 ms after it is 500 ms.
  const result = await runOnce([250, 'r_package_install_start', 20, 'r_package_install_end', 250]);
  assert.equal(result.timedOut, true);
});

test('an install that never ends still times the test out', async () => {
  const result = await runOnce(['r_package_install_start', 1500], { initTimeoutMs: 300 });
  assert.equal(result.timedOut, true);
});
