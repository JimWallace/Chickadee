// Executes the Python grading cell under a real python3 and checks it against
// what the native runner gives a test script (Sources/Worker/ScriptInvocation.swift):
//
//   * sys.argv[0] and __file__ name the script, as under `python3 script.py`;
//   * a SystemExit raised in the submission's own code is an error, not the
//     test's status (test_runtime's `_check_submission_exit`, which both
//     graders call; PythonSubmissionExitTests covers the native side);
//   * an exit from the test itself, passed() and failed() still count.
//
// Before this, the browser cell took a submission's `sys.exit(0)` as a pass
// where the native runner reported an error.
//
// The driver runs each cell in ONE globals dict, as a kernel does; the same
// shape as python-grading-reset-execution.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
require('../../Public/grading-shared.js');
require('../../Public/python-grading-shared.js');

const Shared = globalThis.ChickadeeGradingShared;
const Python = globalThis.ChickadeePythonGradingShared;
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const TEST_RUNTIME = fs.readFileSync(
    path.join(REPO_ROOT, 'Tools/runner-support/test_runtime.py'), 'utf8');

const PYTHON = ['python3', 'python'].find(
    (name) => spawnSync(name, ['--version'], { stdio: 'ignore' }).status === 0);

// A silent skip is right on a laptop and wrong in CI, where it would report a
// green suite that executed nothing.
test('CI has a python3 for these tests to use', { skip: !PYTHON && !process.env.CI }, () => {
    assert.ok(PYTHON, 'no python3 on PATH');
});

const SUBMISSION = [
    'import sys',
    'def add(a, b):',
    '    return a - b',
    'def quit_early():',
    '    sys.exit(0)',
    '',
].join('\n');

/// Stages a workspace like the browser's, runs `scripts` (name -> source) in
/// order in one namespace with the reset between them, and returns each
/// script's parsed result plus the sys.argv the kernel is left with.
function grade(scripts, { runtime = TEST_RUNTIME } = {}) {
    const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'chickadee_work_'));
    fs.writeFileSync(path.join(workDir, 'test_runtime.py'), runtime);
    fs.writeFileSync(path.join(workDir, '.chickadee_student_module'), 'submission.py');
    fs.writeFileSync(path.join(workDir, 'submission.py'), SUBMISSION);
    const names = Object.keys(scripts);
    names.forEach((name) => fs.writeFileSync(path.join(workDir, name), scripts[name]));

    const cells = [
        Shared.assignmentSeedPython('deadbeef'),
        Python.cleanStateCellPython(workDir),
        Shared.envConfigPython(workDir),
    ];
    names.forEach((name, i) => {
        cells.push(Python.RESET_CELL_PYTHON + '\n' + Shared.envConfigPython(workDir));
        cells.push(Python.runScriptCellPython(name, 'NONCE' + i));
    });
    cells.push('import sys\nprint("\\nARGV:" + repr(sys.argv))');

    const driver = [
        'import json, sys',
        'sys.argv = ["kernel"]',
        'cells = json.load(sys.stdin)',
        'namespace = {"__name__": "__main__", "__builtins__": __builtins__}',
        'for source in cells:',
        '    exec(compile(source, "cell", "exec"), namespace)',
    ].join('\n');
    const run = spawnSync(PYTHON, ['-c', driver], {
        cwd: workDir, input: JSON.stringify(cells), encoding: 'utf8',
    });
    fs.rmSync(workDir, { recursive: true, force: true });
    assert.equal(run.status, 0, run.stderr);
    const results = Object.fromEntries(names.map((name, i) =>
        [name, Python.parseRunOutput(run.stdout, 'NONCE' + i)]));
    results.argv = (run.stdout.match(/\nARGV:(.*)/) || [])[1];
    return results;
}

/// The last stdout line, which the test contract reads as the result.
function lastLine(result) {
    return JSON.parse(result.stdout.trim().split('\n').pop());
}

test('a sys.exit(0) in the submission is an error, not a pass', { skip: !PYTHON }, () => {
    const result = grade({
        'publictest_quit.py': '# Quits early\nfrom submission import quit_early\nquit_early()\nfailed("unreachable")\n',
    })['publictest_quit.py'];
    assert.equal(result.exitCode, 2, result.stdout + result.stderr);
    const payload = lastLine(result);
    assert.equal(payload.status, 'error');
    assert.match(payload.shortResult, /^Quits early: the submission ended the test \(SystemExit: 0\)$/);
});

test('exits from the test itself and the helpers still count', { skip: !PYTHON }, () => {
    const results = grade({
        'publictest_exit.py': 'import sys\nsys.exit(0)\n',
        'publictest_pass.py': 'from submission import add\nif add(2, 2) == 0:\n    passed()\nfailed("wrong")\n',
        'publictest_fail.py': 'from submission import add\nif add(2, 2) == 4:\n    passed()\nfailed("add(2, 2) is not 4")\n',
    });
    assert.equal(results['publictest_exit.py'].exitCode, 0);
    assert.equal(results['publictest_pass.py'].exitCode, 0);
    assert.equal(results['publictest_fail.py'].exitCode, 1);
});

test('sys.argv[0] and __file__ name the script, as under python3', { skip: !PYTHON }, () => {
    const check = (name) => `import sys
if sys.argv != [${JSON.stringify(name)}]:
    failed("argv " + repr(sys.argv))
if __file__ != ${JSON.stringify(name)}:
    failed("__file__ " + repr(__file__))
passed()
`;
    const results = grade({
        'publictest_first.py': check('publictest_first.py'),
        'publictest_second.py': check('publictest_second.py'),
    });
    for (const name of ['publictest_first.py', 'publictest_second.py']) {
        assert.equal(results[name].exitCode, 0, results[name].stdout);
    }
    assert.equal(results.argv, "['kernel']", 'the cell puts the kernel argv back');
});

test('an older test_runtime without the check keeps the old behaviour', { skip: !PYTHON }, () => {
    const older = TEST_RUNTIME.replace(/def _check_submission_exit\(/, 'def _absent_check(');
    assert.notEqual(older, TEST_RUNTIME, 'the fixture must remove the function');
    const result = grade({
        'publictest_quit.py': 'from submission import quit_early\nquit_early()\n',
    }, { runtime: older })['publictest_quit.py'];
    assert.equal(result.exitCode, 0, 'the exit code stands, and nothing crashes');
});

// `sys.exit(x)` with x not an int: python3 prints str(x) to stderr and exits 1.
// An object JSON cannot hold used to stop the cell printing its payload at all.
test('sys.exit with a value that is not an int exits 1 with it on stderr', { skip: !PYTHON }, () => {
    const results = grade({
        'publictest_object.py': 'import sys\nsys.exit(object())\n',
        'publictest_text.py': 'import sys\nsys.exit("bad input")\n',
    });
    const object = results['publictest_object.py'];
    assert.ok(object, 'the cell printed its payload');
    assert.equal(object.exitCode, 1);
    assert.match(object.stderr, /^<object object at 0x[0-9a-f]+>$/m);
    const text = results['publictest_text.py'];
    assert.equal(text.exitCode, 1);
    assert.match(text.stderr, /^bad input$/m);
});
