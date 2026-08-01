// Public/grading-shared.js
//
// Grading semantics shared by the two browser graders:
//
//   - Public/grading-worker.js  — Pyodide in a Web Worker (the primary grader;
//     the main thread races its replies against a real timeout and terminates
//     the worker to kill run-away student code)
//   - Public/browser-runner.js  — the main-thread fallback executor, used when
//     Worker construction fails
//
// Everything in this file defines WHAT Python runs and HOW its outcome is
// interpreted: the env-config / per-script exec / stream-capture snippets, the
// exit-code derivation, how files land in the Pyodide MEMFS, and which Pyodide
// packages get preloaded.  Both graders must agree on all of it or the same
// submission could grade differently depending on whether the browser had
// Worker support.  These used to be duplicated copies pinned by a bespoke
// drift test (grading-worker-drift.test.mjs); the 0.5 cleanup replaced that
// with this single module, so drift is structurally impossible.
//
// Loading: classic script, no dependencies.
//   - Workers: importScripts('/grading-shared.js' + self.location.search)
//     (forwarding the worker's own ?v= cache-buster pins all grading files to
//     one release).
//   - Pages: a <script src="/grading-shared.js?v=..."> tag BEFORE
//     browser-runner.js (see notebook.leaf).
// Exposes exactly one global: ChickadeeGradingShared.
//
// The Swift/native grading parity is pinned separately by
// Tests/Fixtures/output-contract.json (RunnerCore).

(function (root) {
    'use strict';

    // Add workDir to sys.path, chdir, flush stale helper/student modules,
    // import test_runtime, wire builtins, and load student modules into
    // globals+builtins.
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

    function assignmentSeedPython(seed) {
        return `import os\nos.environ['CHICKADEE_ASSIGNMENT_SEED'] = ${JSON.stringify(seed)}`;
    }

    // Redirect sys.stdout / sys.stderr to in-memory buffers for one script run.
    const STDOUT_REDIRECT_PY = `
import sys, io
_br_stdout = io.StringIO()
_br_stderr = io.StringIO()
sys.stdout = _br_stdout
sys.stderr = _br_stderr
`;

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

    const CAPTURE_OUTPUT_PY = `
(str(_br_stdout.getvalue()), str(_br_stderr.getvalue()), _br_exit_code)
`;

    const RESTORE_STREAMS_PY = `
sys.stdout = sys.__stdout__
sys.stderr = sys.__stderr__
`;

    // Derive the script's exit code from the captured SystemExit code
    // (preferred) or — when none was captured — from the raised JS error,
    // mirroring a `python3 script` subprocess: 0 on clean completion, 1 on an
    // uncaught exception (with the traceback on stderr so RunnerCore puts it
    // in longResult).  Returns the (possibly augmented) stderr too, since an
    // uncaught-exception message is folded into stderr when stderr is empty.
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

    // Materialize a plain file map { <relativePath>: <string|bytes> } into the
    // Pyodide MEMFS under workDir, creating parent directories as needed.
    // Byte values may arrive as a typed array OR a plain Array (postMessage
    // serialization in the worker path), so array-likes are coerced to
    // Uint8Array before writing — FS.writeFile stores a plain Array as text
    // otherwise, corrupting binary support files.
    function writeFilesToPyFS(py, workDir, files) {
        Object.keys(files).forEach(function (relPath) {
            const value = files[relPath];
            const parts = relPath.split('/');
            if (parts.length > 1) {
                let cur = workDir;
                for (let i = 0; i < parts.length - 1; i++) {
                    cur += '/' + parts[i];
                    try { py.FS.mkdir(cur); } catch (e) { /* already exists */ }
                }
            }
            let data = value;
            if (value && typeof value !== 'string' && typeof value.length === 'number') {
                data = new Uint8Array(value);
            }
            py.FS.writeFile(workDir + '/' + relPath, data);
        });
    }

    // Preload the Pyodide packages every bundled .py file imports.
    //
    // loadPackagesFromImports only scans the one source string it is handed,
    // and does NOT follow imports into local modules.  A test script that
    // imports a bundled helper which in turn imports numpy would therefore run
    // with numpy unloaded and die on ModuleNotFoundError — green on the native
    // validation run (where numpy is installed system-wide) and broken for
    // every student.  Scanning the whole setup up front closes that gap.
    //
    // Per-file rather than one concatenated blob, so a single unparseable file
    // (a student's half-finished submission) cannot suppress every other
    // file's imports.  Non-fatal throughout: a name Pyodide doesn't ship must
    // never block the run.
    async function preloadPackagesForFiles(py, files) {
        const names = Object.keys(files || {});
        for (let i = 0; i < names.length; i++) {
            if (!/\.py$/.test(names[i])) continue;
            const value = files[names[i]];
            let text = null;
            if (typeof value === 'string') {
                text = value;
            } else if (value) {
                try { text = new TextDecoder().decode(new Uint8Array(value)); } catch (e) { text = null; }
            }
            if (!text) continue;
            try { await py.loadPackagesFromImports(text); } catch (e) { /* non-fatal */ }
        }
    }

    root.ChickadeeGradingShared = {
        envConfigPython: envConfigPython,
        assignmentSeedPython: assignmentSeedPython,
        STDOUT_REDIRECT_PY: STDOUT_REDIRECT_PY,
        runScriptPython: runScriptPython,
        CAPTURE_OUTPUT_PY: CAPTURE_OUTPUT_PY,
        RESTORE_STREAMS_PY: RESTORE_STREAMS_PY,
        deriveExitCode: deriveExitCode,
        writeFilesToPyFS: writeFilesToPyFS,
        preloadPackagesForFiles: preloadPackagesForFiles
    };
})(typeof self !== 'undefined' ? self : globalThis);
