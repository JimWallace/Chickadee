import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Unit coverage for Public/python-grading-shared.js — the semantics the
// xeus-python browser substrate runs (#1271).
//
// As with the R module, this pins the SHAPE of the cell and the parsing of what
// comes back; it cannot prove Python behaves as the cell assumes, because no
// kernel is booted here.  That half is Tools/browser-grading-smoke.

const sharedSource = await fs.readFile(path.resolve('Public/grading-shared.js'), 'utf8');
const pythonSource = await fs.readFile(path.resolve('Public/python-grading-shared.js'), 'utf8');

const context = { console };
context.globalThis = context;
const vmContext = vm.createContext(context);
vm.runInContext(sharedSource, vmContext, { filename: 'grading-shared.js' });
vm.runInContext(pythonSource, vmContext, { filename: 'python-grading-shared.js' });
const shared = context.ChickadeePythonGradingShared;

const plain = (value) => JSON.parse(JSON.stringify(value));

test('the kernel spec matches the vendored chickadee-python environment on disk', async () => {
  const kernels = JSON.parse(
    await fs.readFile(path.resolve('Public/jupyterlite/xeus/kernels.json'), 'utf8'));
  const entry = kernels.find(k => k.env_name === shared.PYTHON_KERNEL.envName);
  assert.ok(entry, `kernels.json has no env named ${shared.PYTHON_KERNEL.envName}`);
  assert.equal(entry.kernel, shared.PYTHON_KERNEL.kernelName);

  const kernelJson = JSON.parse(await fs.readFile(
    path.resolve(`Public/jupyterlite/xeus/${entry.env_name}/${entry.kernel}/kernel.json`), 'utf8'));
  assert.deepEqual(plain(shared.PYTHON_KERNEL.sharedLibs), kernelJson.metadata.shared);
  assert.deepEqual(plain(shared.PYTHON_KERNEL.argv), kernelJson.argv);
});

test('xpython is flagged as needing the CPython runtime bootstrapped', () => {
  // xeus-r does not need this and xeus-python does; getting it wrong means the
  // kernel starts and then fails on the first import.
  assert.equal(shared.PYTHON_KERNEL.needsPythonRuntime, true);
});

test('the grading cell always prints its payload, whatever the script does', () => {
  // The cell is the only channel back — execute_request returns no value — so a
  // script that raises, exits, or writes unserialisable output must still leave
  // the payload on stdout. Structurally: the print is at top level, outside
  // every try, and the exec sits inside a try/finally that restores the streams.
  const cell = shared.runScriptCellPython('publictest_a.py', 'n0nce');
  const lines = cell.split('\n');
  const printLine = lines[lines.length - 1];
  assert.match(printLine, /^print\(/, 'the payload print must be the last top-level statement');
  assert.match(cell, /except SystemExit as _ck_e:/);
  assert.match(cell, /except BaseException:/);
  assert.match(cell, /^finally:$/m);
  assert.match(cell, /_ck_sys\.stdout, _ck_sys\.stderr = _ck_saved/);
});

test('the cell captures output in-process rather than off the kernel stream', () => {
  // The R substrate has to read stderr from the kernel's iopub stream because
  // evaluate's calling handlers intercept it first. Python must NOT copy that:
  // StringIO redirection is exact, and reading kernel streams would also pick up
  // anything the kernel itself logged.
  const cell = shared.runScriptCellPython('publictest_a.py', 'n0nce');
  assert.match(cell, /_ck_out = _ck_io\.StringIO\(\)/);
  assert.match(cell, /_ck_err = _ck_io\.StringIO\(\)/);
  assert.match(cell, /"out": _ck_out\.getvalue\(\)/);
  assert.match(cell, /"err": _ck_err\.getvalue\(\)/);
});

test('the script name is compiled in, so inspect.stack() gives the real label', () => {
  const cell = shared.runScriptCellPython('publictest_bmi.py', 'n0nce');
  assert.match(cell, /compile\(_ck_src, "publictest_bmi\.py", "exec"\)/);
});

test('script names are escaped rather than interpolated raw', () => {
  const cell = shared.runScriptCellPython('odd"name.py', 'n0nce');
  assert.match(cell, /"odd\\"name\.py"/);
});

test('parseRunOutput recovers exit code, stdout and stderr from the payload', () => {
  const nonce = 'abc123';
  const payload = JSON.stringify({
    exit: 1, out: 'checking case 3\n', err: 'expected 5, got 4\n', error: null,
  });
  const kernelStdout = 'noise the script printed\n' + '\n' + nonce + ':' + payload + '\n';
  assert.deepEqual(plain(shared.parseRunOutput(kernelStdout, nonce)), {
    exitCode: 1,
    stdout: 'checking case 3\n',
    stderr: 'expected 5, got 4\n',
  });
});

test('an uncaught exception becomes exit 1 with the traceback on stderr', () => {
  // Mirrors `python3 script` dying: non-zero exit, traceback on stderr. The
  // mapping comes from grading-shared.js's deriveExitCode, shared with the
  // Pyodide substrate, so the two cannot disagree about a crashed script.
  const nonce = 'abc123';
  const traceback = 'Traceback (most recent call last):\nValueError: boom\n';
  const payload = JSON.stringify({ exit: null, out: '', err: '', error: traceback });
  const parsed = shared.parseRunOutput('\n' + nonce + ':' + payload + '\n', nonce);
  assert.equal(parsed.exitCode, 1);
  assert.match(parsed.stderr, /ValueError: boom/);
});

test('a clean run with no SystemExit is exit 0', () => {
  const nonce = 'abc123';
  const payload = JSON.stringify({ exit: null, out: 'done\n', err: '', error: null });
  const parsed = shared.parseRunOutput('\n' + nonce + ':' + payload + '\n', nonce);
  assert.equal(parsed.exitCode, 0);
  assert.equal(parsed.stdout, 'done\n');
});

test('parseRunOutput returns null when the cell never reported', () => {
  assert.equal(shared.parseRunOutput('partial output, kernel died', 'abc123'), null);
  assert.equal(shared.parseRunOutput('', 'abc123'), null);
  // A marker with a body that is not JSON is not a result either.
  assert.equal(shared.parseRunOutput('\nabc123:not json\n', 'abc123'), null);
});

test('student output cannot forge a payload', () => {
  // The nonce is generated per run and never shown to student code. A
  // submission that prints a marker-looking line is just stdout, and the parser
  // anchors on the LAST real marker.
  const nonce = 'realnonce';
  const fake = JSON.stringify({ exit: 0, out: '', err: '', error: null });
  const real = JSON.stringify({ exit: 1, out: 'guessed:' + fake + '\n', err: '', error: null });
  const parsed = shared.parseRunOutput('\n' + nonce + ':' + real + '\n', nonce);
  assert.equal(parsed.exitCode, 1, 'the real payload must win');
  assert.match(parsed.stdout, /guessed:/);
});

test('makeNonce is unguessable and fresh per call', () => {
  const a = shared.makeNonce();
  assert.notEqual(a, shared.makeNonce());
  assert.match(a, /^[0-9a-f]{16,}$/);
});
