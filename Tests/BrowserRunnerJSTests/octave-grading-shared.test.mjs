import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Unit coverage for Public/octave-grading-shared.js — the Octave grading
// semantics the browser Octave substrate runs.
//
// What this file can and cannot prove: it pins the SHAPE of the harness and
// the parsing of what comes back, which is where a silent regression would
// turn every Octave test green — if `exit` stopped being masked, `passed()`
// and `failed()` would raise nothing the wrapper recognises and every script
// would look like a clean exit 0. It cannot prove Octave behaves as the
// harness assumes; no kernel is booted here. That half is
// Tools/browser-grading-smoke, which grades real scripts through the real
// xeus-octave kernel in a real browser.

const source = await fs.readFile(path.resolve('Public/octave-grading-shared.js'), 'utf8');

function load() {
  const context = { console };
  context.globalThis = context;
  const vmContext = vm.createContext(context);
  vm.runInContext(source, vmContext, { filename: 'octave-grading-shared.js' });
  return context.ChickadeeOctaveGradingShared;
}

const shared = load();

// Values built inside the vm context are cross-realm; compare the JSON
// projection instead of references.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('the kernel spec matches the vendored chickadee-octave environment on disk', async () => {
  const kernels = JSON.parse(
    await fs.readFile(path.resolve('Public/jupyterlite/xeus/kernels.json'), 'utf8'));
  const entry = kernels.find(k => k.env_name === shared.OCTAVE_KERNEL.envName);
  assert.ok(entry, `kernels.json has no env named ${shared.OCTAVE_KERNEL.envName}`);
  assert.equal(entry.kernel, shared.OCTAVE_KERNEL.kernelName);

  // argv and the shared-library map come from the kernel's own kernel.json. A
  // re-vendor that renames a library (the Octave version is IN the path:
  // lib/octave/10.3.0/...) would leave locateFile pointing at a 404 and the
  // kernel would never start — an opaque boot failure, which is why this is
  // asserted here rather than discovered in a browser.
  const kernelJson = JSON.parse(await fs.readFile(
    path.resolve(`Public/jupyterlite/xeus/${entry.env_name}/${entry.kernel}/kernel.json`), 'utf8'));
  assert.deepEqual(plain(shared.OCTAVE_KERNEL.argv), kernelJson.argv);
  assert.deepEqual(plain(shared.OCTAVE_KERNEL.sharedLibs), kernelJson.metadata.shared || {});
  assert.equal(shared.OCTAVE_KERNEL.needsPythonRuntime, false);
});

test('the per-script wrapper is a single call into the installed harness', () => {
  // One call expression whose harness function owns a private workspace — that
  // workspace is what isolates one script's variables from the next, standing
  // in for the fresh process the native runner gives each test.
  const wrapper = shared.runScriptOctave('publictest_a.m', 'n0nce');
  assert.equal(wrapper, '__ck_run("publictest_a.m", "n0nce");');
});

test('the harness re-creates the process contract test_runtime.m depends on', () => {
  const setup = shared.SETUP_OCTAVE;
  // The setup cell must be a SCRIPT (function definitions register as
  // command-line functions, which is what lets them shadow builtins).
  assert.match(setup, /^1;\n/);
  // exit is how passed()/failed()/errored() report a status; quit is its
  // synonym and a student may call either. Both masks must raise the
  // chickadee:exit identifier the runner recognises. Third kernel, third exit
  // mask (R's quit(), Lua's os.exit) — if it regresses, every test reads as a
  // clean pass.
  assert.match(setup, /function exit\(code\)/);
  assert.match(setup, /function quit\(varargin\)/);
  assert.match(setup, /error\("chickadee:exit", "%d", code\);/);
  // program_name() is where chickadee.label() reads the script name from
  // under octave-cli, so the mask must answer with the script being graded.
  assert.match(setup, /function name = program_name\(\)/);
  // An uncaught error must reach stderr in octave-cli's own shape, which is
  // where longResult comes from.
  assert.match(setup, /fprintf\(2, "error: %s\\n", err\.message\);/);
  // The status line the parser anchors on.
  assert.match(setup, /printf\("\\n%s:status:%d\\n", nonce, status\);/);
  // The fresh-process stand-in: ordinary variables die with __ck_run's own
  // workspace, and globals — the one thing that outlives the call — are
  // cleared per script, sparing only the harness's own state.
  assert.match(setup, /who\("global"\)/);
  assert.match(setup, /clear\("-global", __ck_globals\{__ck_i\}\);/);
});

test('script names and nonces are escaped rather than interpolated raw', () => {
  const wrapper = shared.runScriptOctave('odd"name\\.m', 'n0nce');
  assert.equal(wrapper, '__ck_run("odd\\"name\\\\.m", "n0nce");');
});

test('parseRunOutput recovers the exit code and the script stdout', () => {
  const nonce = 'abc123';
  const kernelStdout = 'checking case 3\nfailed: expected 5, got 4\n'
    + `\n${nonce}:status:1\n`;
  assert.deepEqual(plain(shared.parseRunOutput(kernelStdout, nonce)), {
    exitCode: 1,
    stdout: 'checking case 3\nfailed: expected 5, got 4\n',
  });
});

test('a script whose last write had no newline does not gain one', () => {
  const nonce = 'abc123';
  assert.equal(
    shared.parseRunOutput(`no trailing newline\n${nonce}:status:0\n`, nonce).stdout,
    'no trailing newline');
});

test('parseRunOutput returns null when the wrapper never reported', () => {
  assert.equal(shared.parseRunOutput('some partial output', 'abc123'), null);
  assert.equal(shared.parseRunOutput('\nabc123:status:', 'abc123'), null);
  assert.equal(shared.parseRunOutput('\nabc123:status:notanumber\n', 'abc123'), null);
  assert.equal(shared.parseRunOutput('', 'abc123'), null);
});

test('student output cannot forge the status boundary', () => {
  const nonce = 'realnonce';
  const stdout = 'sneaky output:\n\nguessed:status:1\n'
    + `\n${nonce}:status:0\n`;
  const parsed = shared.parseRunOutput(stdout, nonce);
  assert.equal(parsed.exitCode, 0);
  assert.match(parsed.stdout, /sneaky output/);
  assert.match(parsed.stdout, /guessed:status:1/);
});

test('makeNonce is unguessable and fresh per call', () => {
  const a = shared.makeNonce();
  const b = shared.makeNonce();
  assert.notEqual(a, b);
  assert.match(a, /^[0-9a-f]{16,}$/);
});

test('the seed is delivered through a plain setenv', () => {
  // Octave CAN write its own environment (unlike Lua), so the native runner's
  // `CHICKADEE_ASSIGNMENT_SEED=... octave-cli script.m` becomes one setenv
  // call and test_runtime.m's getenv needs no overlay.
  assert.equal(
    shared.assignmentSeedOctave('deadbeef'),
    'setenv("CHICKADEE_ASSIGNMENT_SEED", "deadbeef");');
});

test('the inputs writer matches the server renderer byte for byte', async () => {
  // The JS twin of AssignmentLanguage.renderInputsFile(.octave). The worker
  // writes the file from Swift and the browser from here; a byte of drift
  // means the two runners deliver different per-student values.
  // BrowserRunnerSeedLanguageTests pins the Swift side against this same
  // shape.
  const rendered = shared.personalizationInputsSourceOctave({
    threshold: '42',
    labels: '{"a", "b"}',
  });
  assert.equal(
    rendered,
    '% Auto-generated per-student grading inputs (issue #461). Do not edit.\n'
      + 'ck_input_names = { "labels", "threshold" };\n'
      + 'ck_input_values = { {"a", "b"}, 42 };\n');

  assert.equal(
    shared.personalizationInputsSourceOctave({}),
    '% Auto-generated per-student grading inputs (issue #461). Do not edit.\n'
      + 'ck_input_names = {};\nck_input_values = {};\n');
});
