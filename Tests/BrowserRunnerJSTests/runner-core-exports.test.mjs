import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

// The typed BridgeJS surface of the vendored RunnerCore wasm, and the legacy
// `globalThis.runner*` adapters the loader registers over it.
//
// output-contract.test.mjs proves the grading SEMANTICS through the legacy
// entry points; this file pins the two things that changed when the bridge
// moved from hand-marshalled JSClosures to BridgeJS `@JS` exports:
//   * `init()` resolves with typed `exports` whose shapes match the vendored
//     runner-core.d.ts (struct fields cross by name, optionals as null);
//   * the legacy globals are adapters over those exports, carrying the old
//     bridge's tolerances — Jupyter's `cell_type`, an omitted `displayName` /
//     `dependsOn` / `points`, and a rejecting or partial `run` callback, which
//     becomes an exit-2 "error" outcome rather than a failed suite (the text
//     browser-runner.js documents).

const RUNNER_DIR = path.resolve('Public/runner-wasm');
const RUNNER_CORE = path.join(RUNNER_DIR, 'runner-core.js');

let _ready;
async function ensureWasm() {
  if (!_ready) {
    _ready = (async () => {
      const { init } = await import(RUNNER_CORE);
      const wasmName = (await fs.readdir(RUNNER_DIR)).find(f => /^RunnerWasm\..*\.wasm$/.test(f));
      const module = await WebAssembly.compile(await fs.readFile(path.join(RUNNER_DIR, wasmName)));
      return init({ module });
    })();
  }
  return _ready;
}

const rCells = [
  { cellType: 'markdown', source: 'notes' },
  { cellType: 'code', source: 'x <- 1\n' },
  { cellType: 'code', source: '   \n' },
  { cellType: 'code', source: 'y <- 2' },
];

test('init() resolves with the typed exports the vendored d.ts declares', async () => {
  const { exports } = await ensureWasm();
  const declared = await fs.readFile(path.join(RUNNER_DIR, 'runner-core.d.ts'), 'utf8');
  for (const name of ['extractPython', 'extractR', 'extractLua', 'extractOctave', 'classifyScript', 'executeSuites']) {
    assert.equal(typeof exports[name], 'function', `exports.${name}`);
    assert.ok(declared.includes(`${name}(`), `${name} is declared in runner-core.d.ts`);
  }
});

test('typed extractR takes cellType cells and returns { source, codeCellCount }', async () => {
  const { exports } = await ensureWasm();
  const result = exports.extractR(rCells, 'lab.ipynb');
  assert.equal(result.codeCellCount, 2);
  assert.equal(
    result.source,
    '# Generated from lab.ipynb\n\n# ---- chickadee:cell 2 ----\nx <- 1\n\n# ---- chickadee:cell 4 ----\ny <- 2\n\n');
  assert.equal(exports.extractLua(rCells, 'lab.ipynb').source.startsWith('-- Generated from lab.ipynb'), true);
  assert.equal(exports.extractOctave(rCells, 'lab.ipynb').source.startsWith('% Generated from lab.ipynb'), true);
});

test('typed extractPython returns both views and the count', async () => {
  const { exports } = await ensureWasm();
  const result = exports.extractPython(
    [{ cellType: 'code', source: 'def f():\n    return 1\n' }, { cellType: 'code', source: 'print(f())\n' }],
    'hw.ipynb');
  assert.equal(result.codeCellCount, 2);
  assert.ok(result.executableModule.includes('exec(compile('));
  assert.ok(result.introspectableSource.includes('def f():'));
  assert.ok(!result.introspectableSource.includes('exec(compile('));
});

test('typed classifyScript answers as the native worker does', async () => {
  const { exports } = await ensureWasm();
  assert.equal(exports.classifyScript('t.py', ''), 'python');
  assert.equal(exports.classifyScript('t.R', ''), 'rscript');
  assert.equal(exports.classifyScript('run', '#!/usr/bin/env bash\n'), 'bash');
  assert.equal(exports.classifyScript('run', 'import os\n'), 'python');
  assert.equal(exports.classifyScript('run', ''), 'unknown');
});

test('typed executeSuites drives the shared loop with typed callbacks', async () => {
  const { exports } = await ensureWasm();
  const suites = [
    { script: 'a.py', tier: 'public', displayName: null, dependsOn: [], points: 2 },
    { script: 'b.py', tier: 'release', displayName: 'Named', dependsOn: ['a.py'], points: 1 },
    { script: 'missing.py', tier: 'secret', displayName: null, dependsOn: [], points: 1 },
  ];
  const seen = [];
  const outcomes = await exports.executeSuites(
    suites, 7, 3,
    (name) => name !== 'missing.py',
    async (name, limit) => {
      seen.push([name, limit]);
      return { exitCode: name === 'a.py' ? 0 : 1, stdout: '{"score": 0.5, "metric": 12.5}', stderr: '', executionTimeMs: 4, timedOut: false };
    });
  assert.deepEqual(seen, [['a.py', 7], ['b.py', 7]]);
  assert.equal(outcomes.length, 2);
  assert.deepEqual(outcomes[0], {
    testName: 'a', testClass: null, tier: 'public', status: 'pass', shortResult: 'passed',
    longResult: null, score: 0.5, points: 2, metric: 12.5, executionTimeMs: 4,
    memoryUsageBytes: null, attemptNumber: 3, isFirstPassSuccess: false,
  });
  assert.equal(outcomes[1].testName, 'Named');
  assert.equal(outcomes[1].status, 'fail');
});

test('legacy globals adapt Jupyter cell_type cells and omitted suite fields', async () => {
  await ensureWasm();
  const viaLegacy = globalThis.runnerExtractR(
    rCells.map(c => ({ cell_type: c.cellType, source: c.source })), 'lab.ipynb');
  assert.deepEqual(viaLegacy, (await ensureWasm()).exports.extractR(rCells, 'lab.ipynb'));

  const outcomes = await globalThis.runnerExecuteSuites(
    [{ script: 'a.py', tier: 'public' }], undefined, undefined,
    () => true,
    async () => ({ exitCode: 0, stdout: '', stderr: '' }));
  assert.equal(outcomes.length, 1);
  assert.equal(outcomes[0].points, 1);
  assert.equal(outcomes[0].attemptNumber, 1);
  assert.equal(outcomes[0].isFirstPassSuccess, true);
  assert.equal(outcomes[0].executionTimeMs, 0);
});

test('a rejecting or non-object run becomes an exit-2 error outcome, not a failed suite', async () => {
  await ensureWasm();
  const outcomes = await globalThis.runnerExecuteSuites(
    [{ script: 'boom.py', tier: 'public' }, { script: 'odd.py', tier: 'public' }], 10, 1,
    () => true,
    async (name) => { if (name === 'boom.py') throw new Error('kernel died'); return 'not an object'; });
  assert.equal(outcomes[0].status, 'error');
  assert.equal(outcomes[0].longResult, 'stderr:\nbrowser executor: script run rejected');
  assert.equal(outcomes[1].status, 'error');
  assert.equal(outcomes[1].longResult, 'stderr:\nbrowser executor: non-object run result');
});
