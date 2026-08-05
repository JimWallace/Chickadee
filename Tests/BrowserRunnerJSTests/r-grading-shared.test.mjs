import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Unit coverage for Public/r-grading-shared.js — the R grading semantics the
// browser R substrate runs (#1271).
//
// What this file can and cannot prove: it pins the SHAPE of the wrapper and the
// parsing of what comes back, which is where a silent regression would turn
// every R test green.  It cannot prove R behaves as the wrapper assumes — no
// kernel is booted here.  That half is covered by Tools/r-grading-smoke, which
// grades real scripts through the real xeus-r kernel in a real browser.

const source = await fs.readFile(path.resolve('Public/r-grading-shared.js'), 'utf8');

function load() {
  const context = { console };
  context.globalThis = context;
  const vmContext = vm.createContext(context);
  vm.runInContext(source, vmContext, { filename: 'r-grading-shared.js' });
  return context.ChickadeeRGradingShared;
}

const shared = load();

// Values built inside the vm context are cross-realm, so deepEqual reports
// "same structure but not reference-equal" against a plain literal. Compare the
// JSON projection instead.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('the kernel spec matches the vendored chickadee-r environment on disk', async () => {
  const kernels = JSON.parse(
    await fs.readFile(path.resolve('Public/jupyterlite/xeus/kernels.json'), 'utf8'));
  const entry = kernels.find(k => k.env_name === shared.R_KERNEL.envName);
  assert.ok(entry, `kernels.json has no env named ${shared.R_KERNEL.envName}`);
  assert.equal(entry.kernel, shared.R_KERNEL.kernelName);

  // The shared-library map and argv come from the kernel's own kernel.json.
  // A re-vendor that renames or drops one of these would leave the grader
  // pointing locateFile at a 404 and the kernel would never start.
  const kernelJson = JSON.parse(await fs.readFile(
    path.resolve(`Public/jupyterlite/xeus/${entry.env_name}/${entry.kernel}/kernel.json`), 'utf8'));
  assert.deepEqual(plain(shared.R_KERNEL.sharedLibs), kernelJson.metadata.shared);
  assert.deepEqual(plain(shared.R_KERNEL.argv), kernelJson.argv);
});

test('the wrapper is exactly one top-level R expression', () => {
  // Not stylistic. xeus-r evaluates a cell one top-level expression at a time
  // and charges ~250ms for each; a wrapper that grew back into a statement list
  // would quietly add seconds to every test a student runs. Checked by shape:
  // the whole body must be a single local({ ... }) call.
  const wrapper = shared.runScriptR('publictest_a.R', 'n0nce');
  assert.match(wrapper, /^local\(\{/);
  assert.match(wrapper, /\}\)$/);
  // No top-level statement may follow the closing brace of that one call: once
  // the nesting opens it must not return to zero before the last character.
  let depth = 0;
  let opened = false;
  let closedEarlyAt = -1;
  for (let i = 0; i < wrapper.length; i++) {
    const ch = wrapper[i];
    if (ch === '(' || ch === '{') { depth++; opened = true; }
    if (ch === ')' || ch === '}') depth--;
    if (opened && depth === 0 && i < wrapper.length - 1) { closedEarlyAt = i; break; }
  }
  assert.equal(closedEarlyAt, -1,
    'the wrapper closes and reopens — it is more than one expression, '
      + `see offset ${closedEarlyAt}`);
});

test('the wrapper masks the process primitives test_runtime.R depends on', () => {
  const wrapper = shared.runScriptR('publictest_bmi.R', 'n0nce');
  // quit() is how passed()/failed()/errored() report a status. Without the mask
  // they would try to kill the kernel session and the exit code would be lost.
  assert.match(wrapper, /assign\("quit",/);
  assert.match(wrapper, /assign\("q",/);
  assert.match(wrapper, /chickadee_exit/);
  // commandArgs() is where .chickadee_label() and .chickadee_running_script()
  // read the script name from under Rscript.
  assert.match(wrapper, /assign\("commandArgs",/);
  assert.match(wrapper, /--file=/);
  assert.match(wrapper, /"publictest_bmi\.R"/);
  // A fresh global environment per script stands in for the fresh process the
  // native runner gets.
  assert.match(wrapper, /rm\(list = ls\(\.ck_g, all\.names = TRUE\), envir = \.ck_g\)/);
});

test('script names are escaped rather than interpolated raw', () => {
  const wrapper = shared.runScriptR('odd"name\\.R', 'n0nce');
  assert.match(wrapper, /"odd\\"name\\\\\.R"/);
});

test('parseRunOutput recovers the exit code and the replayed stdout', () => {
  const nonce = 'abc123';
  const kernelStdout = [
    'noise the kernel printed before the report\n',
    `\n${nonce}:status:1\n`,
    'checking case 3\nfailed: expected 5, got 4\n',
    `\n${nonce}:end\n`,
  ].join('');
  assert.deepEqual(plain(shared.parseRunOutput(kernelStdout, nonce)), {
    exitCode: 1,
    stdout: 'checking case 3\nfailed: expected 5, got 4\n',
  });
});

test('parseRunOutput returns null when the wrapper never reported', () => {
  // The caller turns this into a substrate error rather than guessing a status
  // — a cell that died before the replay tells us nothing about the test.
  assert.equal(shared.parseRunOutput('some partial output', 'abc123'), null);
  assert.equal(shared.parseRunOutput('\nabc123:status:0\nstdout but no end marker', 'abc123'), null);
  assert.equal(shared.parseRunOutput('', 'abc123'), null);
});

test('student output cannot forge a section boundary', () => {
  // The nonce is generated per run and never shown to student code, so a
  // submission that prints a marker-looking line is just stdout. The parser
  // anchors on the LAST real status marker.
  const nonce = 'realnonce';
  const stdout = [
    `\n${nonce}:status:0\n`,
    'sneaky output:\n\nguessed:status:1\n\nguessed:end\n',
    `\n${nonce}:end\n`,
  ].join('');
  const parsed = shared.parseRunOutput(stdout, nonce);
  assert.equal(parsed.exitCode, 0);
  assert.match(parsed.stdout, /sneaky output/);
});

test('makeNonce is unguessable and fresh per call', () => {
  const a = shared.makeNonce();
  const b = shared.makeNonce();
  assert.notEqual(a, b);
  assert.match(a, /^[0-9a-f]{16,}$/);
});

test('the seed is delivered through the environment, as the native runner does it', () => {
  assert.equal(
    shared.assignmentSeedR('deadbeef'),
    'Sys.setenv(CHICKADEE_ASSIGNMENT_SEED = "deadbeef")');
});

test('_ck_inputs.R renders a .ck_inputs list with sorted, back-quoted names', () => {
  // Must stay byte-identical to AssignmentLanguage.renderInputsFile(.r); the
  // parity is asserted against the Swift implementation in
  // Tests/APITests/BrowserRunnerSeedLanguageTests.swift.
  assert.equal(
    shared.personalizationInputsSourceR({ threshold: '42', alpha: 'c(1, 2)' }),
    '# Auto-generated per-student grading inputs (issue #461). Do not edit.\n'
      + '.ck_inputs <- list(\n'
      + '    `alpha` = c(1, 2),\n'
      + '    `threshold` = 42\n'
      + ')\n');
  assert.equal(
    shared.personalizationInputsSourceR({}),
    '# Auto-generated per-student grading inputs (issue #461). Do not edit.\n'
      + '.ck_inputs <- list()\n');
});
