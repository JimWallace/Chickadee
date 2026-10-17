// Browser half of the script-dispatch contract (Tests/Fixtures/script-dispatch-cases.json).
//
// The native half is Tests/WorkerTests/ScriptDispatchContractTests.swift. Both
// read one fixture, so the interpreter a script runs under cannot differ
// between the native worker and the browser.
//
// Two questions are asked of every case:
//   1. Does the REAL vendored RunnerCore wasm classify it as the fixture says?
//      This is the same `classifyScriptInterpreter` the worker calls.
//   2. Does the browser router send it to the substrate that kind implies?
//      A kind with a browser kernel runs there; shell is refused by name;
//      anything else (Racket today) is unsupported in the browser.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

import { loadRunnerWasm } from './support/runner-wasm.mjs';

const fixture = JSON.parse(
  fs.readFileSync(path.resolve('Tests/Fixtures/script-dispatch-cases.json'), 'utf8'));

/// The coarse vocabulary of the fixture, from the raw `ScriptInterpreter`
/// value. It matches `kind(of:)` in ScriptDispatchContractTests.swift: an
/// interpreter outside it maps to "other" so a surprise fails loudly.
function coarseKind(interpreter) {
  switch (interpreter) {
    case 'python': return 'python';
    case 'rscript': return 'r';
    case 'lua': return 'lua';
    case 'octave': return 'octave';
    case 'racket': return 'racket';
    case 'sh':
    case 'bash':
    case 'zsh': return 'shell';
    default: return 'other';
  }
}

/// The generated interpreter-to-substrate table in browser-runner.js.
function interpreterKinds() {
  const source = fs.readFileSync(path.resolve('Public/browser-runner.js'), 'utf8');
  const match = source.match(/const INTERPRETER_KINDS = (\{[^}]*\});/);
  assert.ok(match, 'browser-runner.js has no generated INTERPRETER_KINDS');
  return vm.runInNewContext(`(${match[1]})`);
}

function loadExecutors() {
  const source = fs.readFileSync(path.resolve('Public/grading-executors.js'), 'utf8');
  const context = { console, setTimeout, clearTimeout, TextDecoder };
  context.globalThis = context;
  vm.runInContext(source, vm.createContext(context), { filename: 'grading-executors.js' });
  return context.ChickadeeGradingExecutors;
}

test('the fixture has cases, and every kind is one the contract can produce', () => {
  assert.ok(fixture.cases.length > 0);
  const vocabulary = new Set(['python', 'r', 'lua', 'octave', 'racket', 'shell']);
  for (const c of fixture.cases) {
    assert.ok(vocabulary.has(c.kind), `case '${c.name}' has unknown kind '${c.kind}'`);
  }
});

test('the vendored wasm classifies every case as the native worker does', async () => {
  const { exports } = await loadRunnerWasm();
  for (const c of fixture.cases) {
    const interpreter = exports.classifyScript(c.name, c.content);
    assert.equal(coarseKind(interpreter), c.kind,
      `'${c.name}' (${c.note}): wasm says '${interpreter}'`);
  }
});

test('the browser router sends every case to the substrate its kind implies', async () => {
  const { exports } = await loadRunnerWasm();
  const { interpreterToKind } = loadExecutors();
  const kinds = interpreterKinds();
  const browserKinds = new Set(Object.values(kinds));
  // Pinned, not derived: the four substrates CLAUDE.md names. A kind that
  // drops out of the generated table must fail here, not change the answer.
  assert.deepEqual([...browserKinds].sort(), ['lua', 'octave', 'python', 'r']);
  for (const c of fixture.cases) {
    const expected = browserKinds.has(c.kind) ? c.kind : c.kind === 'shell' ? 'shell' : 'unsupported';
    const routed = interpreterToKind(exports.classifyScript(c.name, c.content), kinds);
    assert.equal(routed, expected, `'${c.name}' (${c.note})`);
  }
});
