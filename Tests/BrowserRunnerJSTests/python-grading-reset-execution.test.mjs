// Executes the Python grading cells under a real python3, as one kernel would.
//
// Each native test is a fresh `python3` process; the browser grades every
// script in one kernel namespace, so the grader resets it before each script
// (#1959). python-grading-shared.test.mjs pins the cells' SHAPE; this runs
// them. The driver executes each cell as its own chunk in ONE globals dict,
// which is what a kernel cell is, so state that survives a cell here survives
// one in the browser too.
//
// The kernel-side proof is Tools/browser-grading-smoke (`--language python`),
// which runs the same two fixtures. This is the cheap half: it runs in seconds
// and shows the leak without the reset, so the fixtures cannot pass by accident.
//
// Skips silently when no python3 is on PATH, so a checkout without one is not
// a red suite.

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

const PYTHON = ['python3', 'python'].find(
    (name) => spawnSync(name, ['--version'], { stdio: 'ignore' }).status === 0);

// A silent skip is right on a laptop and wrong in CI, where it would report a
// green suite that executed nothing.
test('CI has a python3 for these tests to use', { skip: !process.env.CI }, () => {
    assert.ok(PYTHON, 'no python3 on PATH');
});

const LEAK = `import builtins
import os
import helper
import submission
from test_runtime import load_student_module, passed

leaked_from_a_previous_test = "yes"
classify = lambda x: "tampered"
submission.classify = lambda x: "tampered"
load_student_module().classify = lambda x: "tampered"
builtins.leaked_builtin = "yes"
os.environ["CHICKADEE_LEAKED"] = "yes"
helper.calls.append("leak")
import colorsys
passed("left state behind")
`;

const ISOLATION = `import builtins
import os
import sys
import helper
import submission
from test_runtime import failed, load_student_module, passed

problems = []
if "leaked_from_a_previous_test" in globals():
    problems.append("a global")
if hasattr(builtins, "leaked_builtin"):
    problems.append("a builtin")
if os.environ.get("CHICKADEE_LEAKED"):
    problems.append("an environment variable")
if submission.classify(1) != "positive":
    problems.append("the imported student module")
if load_student_module().classify(1) != "positive":
    problems.append("the loaded student module")
exposed = globals().get("classify")
if exposed is not None and exposed(1) != "positive":
    problems.append("the exposed student function")
if helper.calls:
    problems.append("a workspace helper module")
print("library still loaded=" + str("colorsys" in sys.modules))
if problems:
    failed("a previous test leaked " + ", ".join(problems))
passed("each test starts clean")
`;

/// Stages a workspace like the browser's, runs the leak then the isolation
/// fixture in one namespace, and returns each script's parsed payload.
function grade({ reset }) {
    const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'chickadee_work_'));
    fs.copyFileSync(
        path.join(REPO_ROOT, 'Tools/runner-support/test_runtime.py'),
        path.join(workDir, 'test_runtime.py'));
    fs.writeFileSync(path.join(workDir, '.chickadee_student_module'), 'submission.py');
    fs.writeFileSync(path.join(workDir, 'submission.py'),
        'def classify(x):\n    return "positive" if x > 0 else "non-positive"\n');
    fs.writeFileSync(path.join(workDir, 'helper.py'), 'calls = []\n');
    fs.writeFileSync(path.join(workDir, 'publictest_leak.py'), LEAK);
    fs.writeFileSync(path.join(workDir, 'publictest_isolation.py'), ISOLATION);

    const scripts = [['publictest_leak.py', 'NONCEA'], ['publictest_isolation.py', 'NONCEB']];
    const cells = [Shared.assignmentSeedPython('deadbeef')];
    if (reset) cells.push(Python.cleanStateCellPython(workDir));
    cells.push(Shared.envConfigPython(workDir));
    for (const [script, nonce] of scripts) {
        if (reset) cells.push(Python.RESET_CELL_PYTHON + '\n' + Shared.envConfigPython(workDir));
        cells.push(Python.runScriptCellPython(script, nonce));
    }

    const driver = [
        'import json, sys',
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
    return Object.fromEntries(scripts.map(([script, nonce]) =>
        [script, Python.parseRunOutput(run.stdout, nonce)]));
}

test('without the reset, a script sees what the previous one left behind', { skip: !PYTHON }, () => {
    const results = grade({ reset: false });
    assert.equal(results['publictest_leak.py'].exitCode, 0);
    const isolation = results['publictest_isolation.py'];
    assert.equal(isolation.exitCode, 1, 'the fixture must detect the leak it exists for');
    for (const leak of ['a global', 'a builtin', 'an environment variable',
        'the imported student module', 'the loaded student module',
        'the exposed student function', 'a workspace helper module']) {
        assert.match(isolation.stdout, new RegExp(leak), leak);
    }
});

test('with the reset, each script starts as a fresh python3 would', { skip: !PYTHON }, () => {
    const results = grade({ reset: true });
    assert.equal(results['publictest_leak.py'].exitCode, 0);
    const isolation = results['publictest_isolation.py'];
    assert.equal(isolation.exitCode, 0, isolation.stdout + isolation.stderr);
    assert.match(isolation.stdout, /each test starts clean/);
});

/// Library modules are not graded state, and importing pandas again costs
/// seconds per test, so the reset keeps every module from outside the workspace.
test('the reset keeps library modules loaded', { skip: !PYTHON }, () => {
    const isolation = grade({ reset: true })['publictest_isolation.py'];
    assert.match(isolation.stdout, /library still loaded=True/);
});
