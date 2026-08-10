// Executes the Octave auto-compute snippets under a real Octave interpreter.
//
// The Octave sibling of lua-eval-execution.test.mjs, and it exists for the same
// reason: shape assertions cannot tell you that `eval(["1;" …])` registers a
// command-line function, that `nargout` answers 0 for a printing solution, or
// that `evalc` captures what it printed. Everything below runs the real seeded
// runtime, extracted from the Swift constants the server sends.
//
// One difference from the Lua suite, and it is a property of the language
// rather than a shortcut: Octave cells share one base workspace, so
// concatenating the snippets into a single script is a faithful emulation of a
// kernel session. What it cannot show is the `1;` guard on the BOOT cell (a
// script file accepts function definitions either way) — only the kernel proves
// that, in Tools/browser-grading-smoke with `--language octave --mode eval`.
//
// Skips silently when no `octave` is on PATH.

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
require('../../Public/octave-grading-shared.js');
require('../../Public/octave-eval-shared.js');

const Octave = globalThis.ChickadeeOctaveEvalShared;
const protocol = globalThis.ChickadeeEvalProtocol;
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const OCTAVE = ['octave-cli', 'octave'].find(
    (name) => spawnSync(name, ['--version'], { stdio: 'ignore' }).status === 0);

// A silent skip is right on a laptop and wrong in CI, where it would report a
// green suite that executed nothing.
test('CI has an Octave interpreter for these tests to use',
    { skip: !process.env.CI }, () => {
        assert.ok(OCTAVE, 'no octave on PATH — the browser-runner-tests job must install it');
    });

const runtimeSource = OCTAVE ? await readAutoComputeRuntimeSource('octave', REPO_ROOT) : null;

/// Runs `cells` in one Octave session and returns its stdout.
function runCells(cells) {
    const file = path.join(
        fs.mkdtempSync(path.join(os.tmpdir(), 'ck-octave-eval-')), 'driver.m');
    fs.writeFileSync(file, cells.join('\n') + '\n');
    return execFileSync(OCTAVE, ['--no-gui', '-q', file], { encoding: 'utf8' });
}

/// Boots the runtime, loads `cells`, then evaluates `snippet`.
function evaluate(snippet, nonce, cells = []) {
    const loaded = cells.map((source, index) => Octave.loadCell(source, 'LOAD' + index));
    return protocol.parseEvalOutput(
        runCells([Octave.bootCell(runtimeSource)].concat(loaded, [snippet])), nonce);
}

const SOLUTION = [
    'function r = classify(bmi)\n if bmi < 18.5\n  r = "under";\n else\n  r = "ok";\n end\nend',
    'this_name_does_not_exist()',
    'function r = double_it(x)\n r = x * 2;\nend',
    'function shout(word)\n printf("%s!\\n", word);\nend',
    'function n = count(items)\n n = numel(items);\nend',
    'threshold = 18.5;',
];

test('the seeded runtime defines its helpers for later cells', { skip: !OCTAVE }, () => {
    const stdout = runCells([
        Octave.bootCell(runtimeSource),
        'fputs(stdout, [num2str(exist("chickadee_serialize")) " "'
        + ' num2str(exist("chickadee_escape_string")) "\\n"]);',
    ]);
    // 103 is a command-line function, which is what the `1;` guard produces.
    assert.equal(stdout.trim(), '103 103');
});

test('a solution cell that raises is reported, and later cells still load',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(
            Octave.callFunction('double_it', [21], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.error, null);
        assert.equal(payload.value, '42');
    });

test('a failing cell reports its own message', { skip: !OCTAVE }, () => {
    const stdout = runCells([
        Octave.bootCell(runtimeSource),
        Octave.loadCell('this_name_does_not_exist()', 'BAD'),
    ]);
    const payload = protocol.parseEvalOutput(stdout, 'BAD');
    assert.match(payload.error, /undefined/i);
});

test('a value comes back as Octave source, the repr the server driver returns',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(
            Octave.callFunction('classify', [18.49], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '"under"');
    });

test('a numeric array argument stays a row vector', { skip: !OCTAVE }, () => {
    const payload = evaluate(
        Octave.callFunction('count', [[1, 2, 3]], {}, 'N'), 'N', SOLUTION);
    assert.equal(payload.value, '3');
});

test('THE TRAP: a mixed array is a cell, not a concatenated char array',
    { skip: !OCTAVE }, () => {
        // `[65, "bc"]` in Octave is the char array "Abc" — three characters, not
        // two elements. The cell rendering is what keeps `count` answering 2.
        const payload = evaluate(
            Octave.callFunction('count', [[65, 'bc']], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '2');
    });

test('a missing function says "not defined", which the editor keys on',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(
            Octave.callFunction('no_such_function', [], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, null);
        assert.match(payload.error, /not defined/);
    });

test('a solution function shadowing an Octave builtin is the one that is called',
    { skip: !OCTAVE }, () => {
        // `area` is Octave's plotting function. After the solution defines one,
        // `exist("area")` answers 103 — but `str2func("area")` hands back the
        // BUILT-IN, so a handle-based lookup would call the plotting function
        // and report "no graphics toolkits are available" as a solution error.
        // Calling by name resolves it correctly.
        const payload = evaluate(
            Octave.callFunction('area', [2], {}, 'N'), 'N',
            ['function r = area(rad)\n r = round(pi * rad * rad * 100) / 100;\nend']);
        assert.equal(payload.error, null);
        assert.equal(payload.value, '12.57');
    });

test('a solution that is a handle in a variable is callable too',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(
            Octave.callFunction('triple', [4], {}, 'N'), 'N', ['triple = @(x) x * 3;']);
        assert.equal(payload.error, null);
        assert.equal(payload.value, '12');
    });

test('a raising solution is an error, not a null value', { skip: !OCTAVE }, () => {
    const payload = evaluate(
        Octave.callFunction('boom', [], {}, 'N'), 'N',
        // A `%` in the message is the reason every payload uses fputs: a printf
        // carrying it in the format string would consume it.
        ['function boom()\n error("bad %s thing", "100%");\nend']);
    assert.equal(payload.value, null);
    assert.equal(payload.error, 'bad 100% thing');
});

test('a function that returns nothing reports no value, not an error',
    { skip: !OCTAVE }, () => {
        // `ck_res_ = feval(…)` on a zero-output function raises "value on right
        // hand side of assignment is undefined", which would read as a broken
        // solution. The nargout check is what keeps it honest.
        const payload = evaluate(
            Octave.callFunction('shout', ['hi'], {}, 'N'), 'N', SOLUTION);
        assert.equal(payload.error, null);
        assert.equal(payload.value, null);
    });

test('captureStdout reports what was printed, minus one trailing newline',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(
            Octave.callFunction('shout', ['go'], { captureStdout: true }, 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '"go!"');
    });

test('captured output does not also escape to stdout', { skip: !OCTAVE }, () => {
    const stdout = runCells([
        Octave.bootCell(runtimeSource),
        Octave.loadCell('function shout(word)\n printf("%s!\\n", word);\nend', 'L'),
        Octave.callFunction('shout', ['hi'], { captureStdout: true }, 'N'),
    ]);
    const marker = stdout.indexOf('\nN:');
    assert.ok(marker >= 0, `no payload on stdout:\n${stdout}`);
    assert.ok(!stdout.slice(0, marker).includes('hi!'),
        `captured output escaped to stdout:\n${stdout}`);
});

test('a solution variable set in one cell is visible to a later one',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(Octave.runExpression('threshold', 'N'), 'N', SOLUTION);
        assert.equal(payload.value, '18.5');
    });

test('a statement runs and yields no value rather than an error',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(Octave.runExpression('ck_probe_ = 1;', 'N'), 'N');
        assert.equal(payload.error, null);
    });

test('a quote in a solution cannot break out of the embedded literal',
    { skip: !OCTAVE }, () => {
        const payload = evaluate(
            Octave.callFunction('quoted', [], {}, 'N'), 'N',
            ['function r = quoted()\n r = "he said \\"hi\\"";\nend']);
        assert.equal(payload.error, null);
        assert.equal(payload.value, '"he said \\"hi\\""');
    });
