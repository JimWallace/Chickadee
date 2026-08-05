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
// terminates it.  The per-script exec snippets, env-config block, exit-code
// derivation, MEMFS file writer, and package preloader come from
// Public/grading-shared.js — the single copy both this worker and
// browser-runner.js's main-thread fallback run, so the two graders cannot
// drift.  `self.location.search` forwards this worker's own ?v= cache-buster
// so all grading files pin to one release.

//
// LOAD-BEARING CSP DEPENDENCY (measured 2026-08, docs/xeus-python-grading-spike.md).
// This is a CLASSIC worker, and Pyodide 3.14 refuses to load in one:
//   throw new Error("Classic web workers are not supported")
// It detects a classic worker by probing `importScripts("data:text/javascript,")`
// and treating success as proof.  Chickadee's CSP is
// `script-src 'self' 'unsafe-eval' 'unsafe-inline' blob:` — no `data:` — so that
// probe is blocked by policy, throws, and reports FALSE.  Pyodide concludes it is
// not in a classic worker and loads normally.
//
// So this file works because a security header defeats a feature probe.  Adding
// `data:` to script-src would break every browser-graded Python submission; they
// would fail over to the native worker and grade correctly but silently slower,
// with nothing pointing at the CSP.  If script-src ever needs `data:`, convert
// this to a module worker (`import { loadPyodide } from '/pyodide/pyodide.mjs'`)
// in the same change.
importScripts('/pyodide/pyodide.js');
importScripts('/grading-shared.js' + (self.location.search || ''));

var _shared = self.ChickadeeGradingShared;
var envConfigPython = _shared.envConfigPython;
var assignmentSeedPython = _shared.assignmentSeedPython;
var STDOUT_REDIRECT_PY = _shared.STDOUT_REDIRECT_PY;
var runScriptPython = _shared.runScriptPython;
var CAPTURE_OUTPUT_PY = _shared.CAPTURE_OUTPUT_PY;
var RESTORE_STREAMS_PY = _shared.RESTORE_STREAMS_PY;
var deriveExitCode = _shared.deriveExitCode;
var writeFilesToPyFS = _shared.writeFilesToPyFS;
var preloadPackagesForFiles = _shared.preloadPackagesForFiles;

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
// snippet, stdout/stderr capture, and exit-code derivation are the shared
// implementations from grading-shared.js, same as browser-runner.js's
// runPyScriptRaw.
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
