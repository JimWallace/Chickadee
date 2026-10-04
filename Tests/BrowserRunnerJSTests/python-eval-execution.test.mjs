// Executes the Python auto-compute call cells under a real Python interpreter.
//
// The call cells came out of Public/pattern-family-editor.js into
// Public/python-eval-shared.js (#1964), so the worker builds them as it does
// for R, Lua and Octave. pattern-family-editor.test.mjs runs the bare snippets;
// this test runs the WHOLE cell the `call` message sends: the snippet inside
// `runExpressionPython`, printed behind a nonce, parsed back with
// `parseEvalOutput`, and read with `readCallResultPython`. Each solution cell
// and the call cell are executed one after another in one shared namespace,
// as kernel cells are.
//
// The kernel-side proof is still Tools/browser-grading-smoke (`--language
// python --mode eval`). This is the cheap half.
//
// Skips when no `python3` is on PATH, so a checkout without one is not a red
// suite.

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/eval-protocol-shared.js');
require('../../Public/python-grading-shared.js');
require('../../Public/python-eval-shared.js');

const Python = globalThis.ChickadeePythonEvalShared;
const PYTHON = spawnSync('python3', ['--version'], { stdio: 'ignore' }).status === 0;

// A silent skip is right on a laptop and wrong in CI, where it would report a
// green suite that executed nothing.
test('CI has a Python interpreter for these tests to use', { skip: !process.env.CI }, () => {
    assert.ok(PYTHON, 'no python3 on PATH — the browser-runner-tests image must carry it');
});

/// Runs `cells` in order in one namespace and returns the stdout.
///
/// Each cell is compiled and executed on its own, so a cell that only works
/// because it shares a source file with the next one fails here.
function runCells(cells) {
    const driver = [
        'import json, sys',
        '_ns = {"__name__": "__main__"}',
        'for _src in json.load(sys.stdin):',
        '    exec(compile(_src, "<cell>", "exec"), _ns)',
    ].join('\n');
    const result = spawnSync('python3', ['-c', driver],
        { input: JSON.stringify(cells), encoding: 'utf8' });
    assert.equal(result.status, 0, `python3 failed: ${result.stderr}`);
    return result.stdout;
}

const SOLUTION = [
    'import math\n\ndef classify(bmi):\n    return "under" if bmi < 18.5 else "ok"',
    'this_name_does_not_exist()',
    'def area(r):\n    return round(math.pi * r * r, 2)',
    'def shout(word):\n    print(word + "!")',
    'def lines():\n    print("a")\n    print("b")',
    'def noisy(x):\n    print("working")\n    return x * 2',
    'def pair(a, b):\n    return (a, b)',
    'def members():\n    return {1, 2}',
    'def record():\n    return {"a": [1, 2], "b": True, "c": None}',
    'def echo(value):\n    return value',
    'def divide(a, b):\n    return a / b',
];

/// Loads SOLUTION, then calls `functionName` with `args` the way the `call`
/// message does. Returns the reply fields, or `{ error }` when the call
/// raised.
function call(functionName, args, options = {}) {
    const nonce = 'CALLNONCE';
    const loads = SOLUTION.map((source, index) => Python.loadCellPython(source, 'LOAD' + index));
    const stdout = runCells(loads.concat(
        [Python.callFunctionPython(functionName, args, options, nonce)]));
    const payload = Python.parseEvalOutput(stdout, nonce);
    assert.ok(payload, `the call cell printed no payload:\n${stdout}`);
    if (payload.error) return { error: payload.error };
    return JSON.parse(JSON.stringify(Python.readCallResultPython(payload.value)));
}

test('a call returns its value', { skip: !PYTHON }, () => {
    assert.deepEqual(call('classify', [18.49]), { result: 'under' });
});

test('a function defined after a failing cell is callable', { skip: !PYTHON }, () => {
    assert.deepEqual(call('area', [2]), { result: 12.57 });
});

test('a composite value comes back parsed', { skip: !PYTHON }, () => {
    assert.deepEqual(call('record', []), { result: { a: [1, 2], b: true, c: null } });
});

test('arguments round-trip with quotes, newlines and nesting', { skip: !PYTHON }, () => {
    const value = ['say "hi"', 'line\nbreak', { k: [1, null, true] }, 'é'];
    assert.deepEqual(call('echo', [value]), { result: value });
});

test('a None return is returnedNone', { skip: !PYTHON }, () => {
    assert.deepEqual(call('shout', ['hi']), { result: null, returnedNone: true });
});

test('a tuple and a set are unsupported, with the reason', { skip: !PYTHON }, () => {
    assert.deepEqual(call('pair', [1, 2]), { unsupported: 'tuple' });
    assert.deepEqual(call('members', []), { unsupported: 'set' });
});

test('stdout capture returns the printed text without its final newline', { skip: !PYTHON }, () => {
    assert.deepEqual(call('shout', ['hi'], { captureStdout: true }), { result: 'hi!' });
    assert.deepEqual(call('lines', [], { captureStdout: true }), { result: 'a\nb' });
});

test('without stdout capture, printed text does not replace the value', { skip: !PYTHON }, () => {
    assert.deepEqual(call('noisy', [4]), { result: 8 });
});

test('a missing function says "not defined", which the editor keys on', { skip: !PYTHON }, () => {
    // describeCallFailure adds the first failed cell to a message that says
    // "not defined". Without those words the instructor loses the reason.
    assert.deepEqual(call('no_such_function', []),
        { error: 'NameError: no_such_function not defined in solution notebook' });
});

test('an exception in the solution is the last traceback line', { skip: !PYTHON }, () => {
    assert.deepEqual(call('divide', [1, 0]), { error: 'ZeroDivisionError: division by zero' });
});
