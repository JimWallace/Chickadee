// Public/grading-worker.js
//
// Pyodide-in-Web-Worker for the browser SUBMISSION grader
// (Public/browser-runner.js).  Sibling of Public/pyodide-worker.js, which does
// the same for the pattern-family editor's auto-compute.
//
// Why a worker:  the grader used to run student Python on the MAIN thread and
// enforce the per-test time limit with `Promise.race([runPythonAsync, sleep])`.
// `runPythonAsync` only yields control to JS at `await` boundaries, so a
// synchronous CPU-bound infinite loop in student code (e.g. `while True: pass`)
// never lets the sleep timer fire — the tab froze and the submission was lost
// (grading reached `suite_started` but never `suite_done`).  The native runner
// avoids this by SIGKILLing a subprocess; the browser has no main-thread
// equivalent.  Moving Pyodide off the main thread lets the timeout actually
// terminate run-away code: the main thread races the worker's reply against a
// real setTimeout and, on timeout, calls `Worker.terminate()` to kill the
// worker mid-execution, then spins up a fresh one for the next script.
//
// Why not SharedArrayBuffer interrupt:  worker isolation + Worker.terminate()
// kills run-away code on ANY page regardless of headers, whereas a SAB interrupt
// needs cross-origin isolation (COOP/COEP).  NOTE (corrected — the old comment
// claimed "the submit/validate pages don't carry COOP/COEP", which is stale
// since #574): the notebook editor page that hosts this grader
// (/testsetups/:id/notebook) now IS cross-origin isolated, unconditionally
// (Sources/APIServer/Middleware/COEPMiddleware.swift), so SharedArrayBuffer IS
// available here — and the JupyterLite editor kernel runs a SECOND Pyodide
// beside this one.  We keep worker-terminate anyway: it's the portable kill path
// and avoids SAB-interrupt complexity.
//
// Protocol (postMessage from main thread → worker; every reply carries the
// originating `id`):
//   { id, type: 'init', files: { <relativePath>: <string | number[]> }, seed }
//     → loadPyodide(), write every file into a fresh work dir (values may be a
//       UTF-8 string or a byte array), set CHICKADEE_ASSIGNMENT_SEED when `seed`
//       is non-null, then run the shared env-config block (import test_runtime,
//       wire builtins, load student modules)
//     → posts back { id, ok: true }  (or { id, ok: false, error })
//   { id, type: 'run', script: <name>, limit: <seconds> }
//     → exec the script and capture stdout/stderr + exit code
//     → posts back { id, ok: true, result: { exitCode, stdout, stderr } }
//                or { id, ok: false, error }
//
// The worker does NOT implement its own timeout — the main thread races and
// terminates it.  The per-script exec snippets and the env-config block are
// byte-identical to Public/browser-runner.js's; the drift guard
// (Tests/BrowserRunnerJSTests/grading-worker-drift.test.mjs) keeps them in sync.

importScripts('/pyodide/pyodide.js');

let _pyodide = null;
let _pyodidePromise = null;
let _workDir = null;

function getPyodide() {
    if (_pyodide) return Promise.resolve(_pyodide);
    if (!_pyodidePromise) {
        _pyodidePromise = self.loadPyodide().then(function (py) {
            _pyodide = py;
            return py;
        });
    }
    return _pyodidePromise;
}

// Write the file map into the Pyodide MEMFS under workDir, creating parent
// directories as needed.  Values may be a UTF-8 string or a byte array (an
// Array or a typed array — postMessage serializes Uint8Array as a plain Array
// for the structured-clone-free string case here, so accept both).
function writeFilesToPyFS(py, workDir, files) {
    Object.keys(files).forEach(function (relPath) {
        var value = files[relPath];
        var parts = relPath.split('/');
        if (parts.length > 1) {
            var cur = workDir;
            for (var i = 0; i < parts.length - 1; i++) {
                cur += '/' + parts[i];
                try { py.FS.mkdir(cur); } catch (e) { /* already exists */ }
            }
        }
        var data = value;
        if (value && typeof value !== 'string' && typeof value.length === 'number') {
            data = new Uint8Array(value);
        }
        py.FS.writeFile(workDir + '/' + relPath, data);
    });
}

// Preload the Pyodide packages every bundled .py file imports.
//
// loadPackagesFromImports only scans the one source string it is handed, and
// does NOT follow imports into local modules.  A test script that imports a
// bundled helper which in turn imports numpy would therefore run with numpy
// unloaded and die on ModuleNotFoundError — green on the native validation run
// (where numpy is installed system-wide) and broken for every student.
// Scanning the whole setup up front closes that gap.
//
// Per-file rather than one concatenated blob, so a single unparseable file (a
// student's half-finished submission) cannot suppress every other file's
// imports.  Non-fatal throughout: a name Pyodide doesn't ship must never block
// the run.  Mirrors browser-runner.js's preloadPackagesForFiles.
async function preloadPackagesForFiles(py, files) {
    var names = Object.keys(files || {});
    for (var i = 0; i < names.length; i++) {
        if (!/\.py$/.test(names[i])) continue;
        var value = files[names[i]];
        var text = null;
        if (typeof value === 'string') {
            text = value;
        } else if (value) {
            try { text = new TextDecoder().decode(new Uint8Array(value)); } catch (e) { text = null; }
        }
        if (!text) continue;
        try { await py.loadPackagesFromImports(text); } catch (e) { /* non-fatal */ }
    }
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            var _initT0 = Date.now();
            var py = await getPyodide();
            // Diagnostic breadcrumb (no `id`): tells the main thread the heavy
            // loadPyodide() step finished, so a 314 init hang is localizable —
            // if this never arrives the wedge is in Pyodide load; if it arrives
            // but `env_configured` never does, the wedge is in env setup.
            // browser-runner.js's GradingWorkerExecutor forwards these `phase`
            // messages to the keepalive submit-phase telemetry.
            self.postMessage({ type: 'phase', phase: 'pyodide_loaded', ms: Date.now() - _initT0 });
            _workDir = '/chickadee_work_' + Date.now();
            try { py.FS.mkdir(_workDir); } catch (err) { /* fresh worker; ignore */ }
            writeFilesToPyFS(py, _workDir, msg.files || {});
            // Load the packages the setup's .py files import (numpy, pandas, …)
            // BEFORE any script runs, including imports reached only through a
            // bundled helper module.
            await preloadPackagesForFiles(py, msg.files || {});
            if (msg.seed !== null && msg.seed !== undefined) {
                await py.runPythonAsync(assignmentSeedPython(msg.seed));
            }
            // Add working directory to the path and wire builtins — the SAME
            // block browser-runner.js runs (drift-guarded).
            await py.runPythonAsync(envConfigPython(_workDir));
            self.postMessage({ type: 'phase', phase: 'env_configured', ms: Date.now() - _initT0 });
            self.postMessage({ id: id, ok: true });
            return;
        }
        if (msg.type === 'run') {
            var py2 = await getPyodide();
            var result = await runPyScript(py2, msg.script, msg.limit);
            self.postMessage({ id: id, ok: true, result: result });
            return;
        }
        self.postMessage({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        var emsg = (err && err.message) ? String(err.message) : String(err);
        self.postMessage({ id: id, ok: false, error: emsg });
    }
};

// Execute one Python test script and return RAW output { exitCode, stdout,
// stderr }.  No timeout here — the main thread races + terminates.  The exec
// snippet, stdout/stderr capture, and exit-code derivation are byte-identical to
// browser-runner.js's runPyScriptRaw (drift-guarded).
async function runPyScript(py, scriptName, _timeLimitSeconds) {
    var src = null;
    try { src = py.FS.readFile(_workDir + '/' + scriptName, { encoding: 'utf8' }); }
    catch (e) { src = null; }

    // Auto-load any Pyodide packages the script imports (numpy, pandas, …).
    if (src !== null) {
        try { await py.loadPackagesFromImports(src); } catch (e) { /* non-fatal */ }
    }

    // Redirect sys.stdout / sys.stderr to JS buffers.
    await py.runPythonAsync(STDOUT_REDIRECT_PY);

    var pyErr = null;
    try {
        await py.runPythonAsync(runScriptPython(scriptName));
    } catch (err) {
        pyErr = err;
    }

    var stdout = '', stderr = '', brExitCode = null;
    try {
        var captured = await py.runPythonAsync(CAPTURE_OUTPUT_PY);
        var arr = captured.toJs ? captured.toJs() : [String(captured), '', null];
        stdout = arr[0] || '';
        stderr = arr[1] || '';
        brExitCode = arr[2];
        if (captured.destroy) captured.destroy();
    } catch (e) { /* fallback: no output */ }

    await py.runPythonAsync(RESTORE_STREAMS_PY);

    var derived = deriveExitCode(brExitCode, pyErr, stderr);
    return { exitCode: derived.exitCode, stdout: stdout, stderr: derived.stderr };
}

// Derive the script's exit code from the captured SystemExit code (preferred) or
// — when none was captured — from the raised JS error, mirroring a `python3
// script` subprocess: 0 on clean completion, 1 on an uncaught exception (with
// the traceback on stderr so RunnerCore puts it in longResult).  Returns the
// (possibly augmented) stderr too.  Byte-identical to browser-runner.js's
// deriveExitCode (drift-guarded).
function deriveExitCode(brExitCode, pyErr, stderr) {
    let exitCode;
    if (brExitCode !== null && brExitCode !== undefined) {
        exitCode = typeof brExitCode === 'number' ? brExitCode : (parseInt(brExitCode) || 1);
    } else if (pyErr) {
        const msg = pyErr.message || String(pyErr);
        const match = msg.match(/SystemExit:\s*(-?\d+)/);
        if (match) {
            exitCode = parseInt(match[1]);
        } else {
            exitCode = 1;
            if (!stderr.trim()) stderr = msg;
        }
    } else {
        exitCode = 0;
    }
    return { exitCode, stderr };
}

// -------------------------------------------------------------------------
// Shared Python snippets — byte-identical copies of browser-runner.js's.
// Tests/BrowserRunnerJSTests/grading-worker-drift.test.mjs asserts they match
// (normalized whitespace).  Edit both files together.
// -------------------------------------------------------------------------

// CHICKADEE_DRIFT:envConfigPython:BEGIN
// Add workDir to sys.path, chdir, flush stale helper/student modules, import
// test_runtime, wire builtins, and load student modules into globals+builtins.
function envConfigPython(workDir) {
    return `
import sys, os, builtins

# Replace any stale chickadee work-directory on the path.
sys.path = [p for p in sys.path if not p.startswith('/chickadee_work_')]
sys.path.insert(0, '${workDir}')
os.chdir('${workDir}')

# Flush stale helper + student modules so fresh files are picked up.
for _key in list(sys.modules.keys()):
    if _key in ('sitecustomize', 'test_runtime') or _key.startswith('student_'):
        del sys.modules[_key]

# Import test_runtime — set functions in BOTH __main__ globals and builtins.
# Pyodide may not resolve builtins the same way CPython does, so we need
# them as __main__ globals too (runPythonAsync runs in __main__).
from test_runtime import passed, failed, errored, require_function
from test_runtime import load_student_modules, load_student_module
from test_runtime import student_module_names_in_load_order

builtins.passed           = passed
builtins.failed           = failed
builtins.errored          = errored
builtins.require_function = require_function

# Load student code and expose in both globals and builtins.
_student_modules = load_student_modules()
student_modules  = _student_modules
builtins.student_modules = _student_modules
_student_module  = load_student_module()
student_module   = _student_module
builtins.student_module  = _student_module
for _module_name in student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith('_'):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)
            globals()[_name] = _value
`;
}
// CHICKADEE_DRIFT:envConfigPython:END

// CHICKADEE_DRIFT:assignmentSeedPython:BEGIN
function assignmentSeedPython(seed) {
    return `import os\nos.environ['CHICKADEE_ASSIGNMENT_SEED'] = ${JSON.stringify(seed)}`;
}
// CHICKADEE_DRIFT:assignmentSeedPython:END

// CHICKADEE_DRIFT:STDOUT_REDIRECT_PY:BEGIN
const STDOUT_REDIRECT_PY = `
import sys, io
_br_stdout = io.StringIO()
_br_stderr = io.StringIO()
sys.stdout = _br_stdout
sys.stderr = _br_stderr
`;
// CHICKADEE_DRIFT:STDOUT_REDIRECT_PY:END

// CHICKADEE_DRIFT:runScriptPython:BEGIN
// compile(source, scriptName) gives inspect.stack() the real filename so
// test_runtime reads the correct test label; `except SystemExit` catches the
// exit that passed()/failed()/errored() raise (a clean subprocess exit on the
// native side); imports + exec share one globals dict.
function runScriptPython(scriptName) {
    return `
from test_runtime import passed, failed, errored, require_function
_br_exit_code = None
try:
    _br_code = compile(open('${scriptName}', encoding='utf-8').read(), '${scriptName}', 'exec')
    exec(_br_code, globals())
except SystemExit as _e:
    _br_exit_code = _e.code
`;
}
// CHICKADEE_DRIFT:runScriptPython:END

// CHICKADEE_DRIFT:CAPTURE_OUTPUT_PY:BEGIN
const CAPTURE_OUTPUT_PY = `
(str(_br_stdout.getvalue()), str(_br_stderr.getvalue()), _br_exit_code)
`;
// CHICKADEE_DRIFT:CAPTURE_OUTPUT_PY:END

// CHICKADEE_DRIFT:RESTORE_STREAMS_PY:BEGIN
const RESTORE_STREAMS_PY = `
sys.stdout = sys.__stdout__
sys.stderr = sys.__stderr__
`;
// CHICKADEE_DRIFT:RESTORE_STREAMS_PY:END
