import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Unit coverage for Public/lua-grading-shared.js — the Lua grading semantics the
// browser Lua substrate runs.
//
// What this file can and cannot prove: it pins the SHAPE of the harness and the
// parsing of what comes back, which is where a silent regression would turn
// every Lua test green — if `os.exit` stopped being masked, `passed()` and
// `failed()` would both raise nothing the wrapper recognises and every script
// would look like a clean exit 0. It cannot prove Lua behaves as the harness
// assumes; no kernel is booted here. That half is Tools/browser-grading-smoke,
// which grades real scripts through the real xeus-lua kernel in a real browser.

const source = await fs.readFile(path.resolve('Public/lua-grading-shared.js'), 'utf8');

function load() {
  const context = { console };
  context.globalThis = context;
  const vmContext = vm.createContext(context);
  vm.runInContext(source, vmContext, { filename: 'lua-grading-shared.js' });
  return context.ChickadeeLuaGradingShared;
}

const shared = load();

// Values built inside the vm context are cross-realm, so deepEqual reports
// "same structure but not reference-equal" against a plain literal. Compare the
// JSON projection instead.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('the kernel spec matches the vendored chickadee-lua environment on disk', async () => {
  const kernels = JSON.parse(
    await fs.readFile(path.resolve('Public/jupyterlite/xeus/kernels.json'), 'utf8'));
  const entry = kernels.find(k => k.env_name === shared.LUA_KERNEL.envName);
  assert.ok(entry, `kernels.json has no env named ${shared.LUA_KERNEL.envName}`);
  assert.equal(entry.kernel, shared.LUA_KERNEL.kernelName);

  // argv comes from the kernel's own kernel.json. A re-vendor that renames or
  // drops it would leave the grader pointing locateFile at a 404 and the kernel
  // would never start — an opaque boot failure, which is why this is asserted
  // here rather than discovered in a browser.
  const kernelJson = JSON.parse(await fs.readFile(
    path.resolve(`Public/jupyterlite/xeus/${entry.env_name}/${entry.kernel}/kernel.json`), 'utf8'));
  assert.deepEqual(plain(shared.LUA_KERNEL.argv), kernelJson.argv);

  // xlua declares no shared libraries: it links only libxeus, which
  // jupyterlite-xeus places at the env root where xeus-kernel-shared.js finds
  // it by name. If a future build starts declaring a `metadata.shared` block,
  // the spec has to grow one too — the empty map must track the kernel's own
  // answer, not merely stay empty.
  assert.deepEqual(plain(shared.LUA_KERNEL.sharedLibs), kernelJson.metadata.shared || {});
  assert.equal(shared.LUA_KERNEL.needsPythonRuntime, false);
});

test('the per-script wrapper is a single call into the installed harness', () => {
  // Not stylistic. xeus-lua first tries to compile a cell as `return <cell>` so
  // it can report a value, and falls back to running it as a plain block; a
  // cell mixing `local` declarations with later uses of them is reported as an
  // undefined GLOBAL under that fallback. One call expression compiles under
  // the first reading and never meets the second.
  const wrapper = shared.runScriptLua('publictest_a.lua', 'n0nce');
  assert.equal(wrapper, '_ck.run("publictest_a.lua", "n0nce")');
});

test('the harness re-creates the process contract test_runtime.lua depends on', () => {
  const setup = shared.SETUP_LUA;
  // os.exit is how passed()/failed()/errored() report a status. Without the
  // replacement they would try to end a process that does not exist, and the
  // exit code would be lost — every test reading as a pass.
  assert.match(setup, /os\.exit = function/);
  assert.match(setup, /__chickadee_exit/);
  // arg[0] is where label() reads the script name from under `lua`.
  assert.match(setup, /G\.arg = \{ \[0\] = name \}/);
  // os.getenv is where seed() reads CHICKADEE_ASSIGNMENT_SEED.
  assert.match(setup, /os\.getenv = function/);
  // require("test_runtime") only resolves if the cwd is on package.path; the
  // kernel's own path points at its asset dir alone.
  assert.match(setup, /package\.path = "\.\/\?\.lua/);
  // A per-script wipe of globals added since boot stands in for the fresh
  // process the native runner gives each test — and must not take the standard
  // library with it, which is why it is keyed on the boot snapshot.
  assert.match(setup, /if not base\[k\] then G\[k\] = nil end/);
  assert.match(setup, /if not loaded\[k\] then package\.loaded\[k\] = nil end/);
  // The harness itself has to survive its own wipe.
  assert.match(setup, /base\["_ck"\] = true/);
  // An uncaught error must reach stderr, which is where longResult comes from.
  assert.match(setup, /io\.stderr:write/);
});

test('script names and nonces are escaped rather than interpolated raw', () => {
  const wrapper = shared.runScriptLua('odd"name\\.lua', 'n0nce');
  assert.equal(wrapper, '_ck.run("odd\\"name\\\\.lua", "n0nce")');
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
  // The marker carries its own leading newline precisely so that stdout can be
  // reproduced exactly; RunnerCore reads the LAST non-empty stdout line as the
  // result envelope, so a spurious trailing newline is not cosmetic.
  const nonce = 'abc123';
  assert.equal(
    shared.parseRunOutput(`no trailing newline\n${nonce}:status:0\n`, nonce).stdout,
    'no trailing newline');
});

test('parseRunOutput returns null when the wrapper never reported', () => {
  // The caller turns this into a substrate error rather than guessing a status
  // — a cell that died before the status line tells us nothing about the test.
  assert.equal(shared.parseRunOutput('some partial output', 'abc123'), null);
  assert.equal(shared.parseRunOutput('\nabc123:status:', 'abc123'), null);
  assert.equal(shared.parseRunOutput('\nabc123:status:notanumber\n', 'abc123'), null);
  assert.equal(shared.parseRunOutput('', 'abc123'), null);
});

test('student output cannot forge the status boundary', () => {
  // The nonce is generated per run and never shown to student code, so a
  // submission that prints a marker-looking line is just stdout. The parser
  // anchors on the LAST real status marker.
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

test('the seed is delivered through the os.getenv overlay', () => {
  // Lua cannot write its own environment, so the native runner's
  // `CHICKADEE_ASSIGNMENT_SEED=... lua script.lua` becomes an overlay the
  // masked os.getenv consults first.
  assert.equal(
    shared.assignmentSeedLua('deadbeef'),
    '_ck.setenv("CHICKADEE_ASSIGNMENT_SEED", "deadbeef")');
});
