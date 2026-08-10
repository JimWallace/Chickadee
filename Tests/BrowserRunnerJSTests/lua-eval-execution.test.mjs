// Executes the Lua auto-compute snippets under a real Lua interpreter.
//
// lua-eval-shared.test.mjs asserts the snippets' SHAPE; this one asserts they
// run. Everything below is the real thing: the seeded runtime is extracted from
// the Swift constants the server sends, the snippets come from the shipped
// module, and each is `load`ed as its OWN CHUNK — because that is what a kernel
// cell is, and it is the only way a `local` that should have been exported
// shows up as a failure rather than as an accident of file scope.
//
// The kernel-side proof is still Tools/browser-grading-smoke (`--language lua
// --mode eval`): only a real kernel can show that stdout reaches the stream and
// that the boot cell survives xeus-lua's `return <cell>` probe. This is the
// cheap half — it catches a Lua syntax error or a wrong helper name in seconds.
//
// Skips silently when no `lua` is on PATH, so a checkout without one is not a
// red suite.

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { readAutoComputeRuntimeSource } from
    '../../Tools/browser-grading-smoke/auto-compute-runtime.mjs';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/eval-protocol-shared.js');
require('../../Public/lua-grading-shared.js');
require('../../Public/lua-eval-shared.js');

const Lua = globalThis.ChickadeeLuaEvalShared;
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const LUA = ['lua', 'lua5.4', 'lua5.3'].find(
    (name) => spawnSync(name, ['-v'], { stdio: 'ignore' }).status === 0);

// A silent skip is right on a laptop and wrong in CI, where it would report a
// green suite that executed nothing. The workflow installs lua5.4 for exactly
// this file; if that step ever goes away, this says so.
test('CI has a Lua interpreter for these tests to use', { skip: !process.env.CI }, () => {
    assert.ok(LUA, 'no lua on PATH — the browser-runner-tests job must install lua5.4');
});

const runtimeSource = LUA ? await readAutoComputeRuntimeSource('lua', REPO_ROOT) : null;

/// Runs `cells` as separate chunks in one Lua state and returns its stdout.
///
/// The driver `load`s each cell exactly as the kernel does, so a helper that
/// only works because everything happened to share a file scope fails here.
function runCells(cells) {
    const driver = [
        'local function cell(src)',
        '  local chunk, err = load(src, "cell", "t")',
        '  if chunk == nil then error("compile: " .. tostring(err)) end',
        '  chunk()',
        'end',
    ].concat(cells.map((source) => {
        assert.ok(!source.includes(']====]'), 'a snippet must not close the driver bracket');
        return 'cell([====[\n' + source + '\n]====])';
    })).join('\n');
    const file = path.join(
        fs.mkdtempSync(path.join(os.tmpdir(), 'ck-lua-eval-')), 'driver.lua');
    fs.writeFileSync(file, driver);
    return execFileSync(LUA, [file], { encoding: 'utf8' });
}

/// Boots the runtime, loads `cells`, then evaluates `snippet`, returning the
/// parsed payload.
function evaluate(snippet, nonce, cells = []) {
    const solutionCells = cells.map((source, index) => Lua.loadCell(source, 'LOAD' + index));
    const stdout = runCells([Lua.bootCell(runtimeSource)].concat(solutionCells, [snippet]));
    return globalThis.ChickadeeEvalProtocol.parseEvalOutput(stdout, nonce);
}

const SOLUTION = [
    'function classify(bmi) if bmi < 18.5 then return "under" else return "ok" end end',
    'this_name_does_not_exist()',
    'function double_it(x) return x * 2 end',
    'function shout(word) print(word .. "!") end',
    'function count(items) return #items end',
];

test('the seeded runtime defines its helpers for LATER chunks', { skip: !LUA }, () => {
    // The whole reason the exports tail exists. Without it the runtime's two
    // `local function` declarations die with the boot cell and every snippet
    // below fails on a nil call.
    const stdout = runCells([
        Lua.bootCell(runtimeSource),
        'io.write(type(chickadee_serialize), " ", type(chickadee_json_str), " ",'
        + ' type(chickadee.NULL), "\\n")',
    ]);
    assert.equal(stdout.trim(), 'function function table');
});

test('a solution cell that raises is reported, and later cells still load',
    { skip: !LUA }, () => {
        const payload = evaluate(
            Lua.callFunction('double_it', [21], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.error, null);
        assert.equal(payload.value, '42');
    });

test('a failing cell reports its own message', { skip: !LUA }, () => {
    const stdout = runCells([
        Lua.bootCell(runtimeSource),
        Lua.loadCell('this_name_does_not_exist()', 'BAD'),
    ]);
    const payload = globalThis.ChickadeeEvalProtocol.parseEvalOutput(stdout, 'BAD');
    assert.match(payload.error, /nil value/);
});

test('a value comes back as Lua source, the same repr the server driver returns',
    { skip: !LUA }, () => {
        const payload = evaluate(
            Lua.callFunction('classify', [18.49], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '"under"');
    });

test('an array argument becomes a table the solution can measure',
    { skip: !LUA }, () => {
        const payload = evaluate(
            Lua.callFunction('count', [[1, 2, 3]], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '3');
    });

test('a null inside an argument keeps its slot', { skip: !LUA }, () => {
    // The trap the literal contract pins, executed: `{60, nil, 20}` would be a
    // two-element table (or worse), so `count` would answer 2.
    const payload = evaluate(
        Lua.callFunction('count', [[60, null, 20]], {}, 'N'), 'N', SOLUTION);
    assert.equal(payload.value, '3');
});

test('a missing function is an error naming the phrase the editor keys on',
    { skip: !LUA }, () => {
        const payload = evaluate(
            Lua.callFunction('no_such_function', [], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, null);
        assert.match(payload.error, /not defined/);
    });

test('a raising solution is an error, not a null value', { skip: !LUA }, () => {
    const payload = evaluate(
        Lua.callFunction('double_it', ['nope'], {}, 'N'), 'N', SOLUTION);
    assert.equal(payload.value, null);
    assert.match(payload.error, /attempt to mul|arithmetic/);
});

test('captureStdout reports what was printed, minus one trailing newline',
    { skip: !LUA }, () => {
        const payload = evaluate(
            Lua.callFunction('shout', ['go'], { captureStdout: true }, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '"go!"');
    });

test('the payload is written through the real io after the capture is undone',
    { skip: !LUA }, () => {
        // If the restore came after the write, the marker would land in the
        // capture buffer and the parser would see nothing at all.
        const stdout = runCells([
            Lua.bootCell(runtimeSource),
            Lua.loadCell('function shout(word) print(word .. "!") end', 'L'),
            Lua.callFunction('shout', ['hi'], { captureStdout: true }, 'N'),
        ]);
        const marker = stdout.indexOf('\nN:');
        assert.ok(marker >= 0, `no payload on stdout:\n${stdout}`);
        // The captured text appears inside the payload, so the check is that it
        // did not ALSO escape to stdout before it.
        assert.ok(!stdout.slice(0, marker).includes('hi!'),
            `captured output escaped to stdout:\n${stdout}`);
    });

test('the expression path evaluates and reports a value', { skip: !LUA }, () => {
    const payload = evaluate(Lua.runExpression('classify(30)', 'N'), 'N', SOLUTION);
    assert.equal(payload.value, '"ok"');
});

test('a statement runs and yields no value rather than a syntax error',
    { skip: !LUA }, () => {
        const payload = evaluate(Lua.runExpression('local x = 1', 'N'), 'N');
        assert.equal(payload.value, null);
        assert.equal(payload.error, null);
    });

test('a quote in a solution cannot break out of the embedded literal',
    { skip: !LUA }, () => {
        const payload = evaluate(
            Lua.callFunction('quoted', [], {}, 'N'), 'N',
            ['function quoted() return "he said \\"hi\\"" end']);
        assert.equal(payload.error, null);
        assert.equal(payload.value, '"he said \\"hi\\""');
    });
