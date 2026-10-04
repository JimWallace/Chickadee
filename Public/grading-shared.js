// Public/grading-shared.js
//
// Grading semantics that more than one browser grading worker needs: the
// Python environment config, the seed cell, the exit-code mapping and the
// file writer for an emscripten file system.
//
// It began life as the shared copy between a Pyodide worker and a main-thread
// Pyodide fallback, which is why it is a separate module. Both of those are
// gone (#1271). Python now grades on the xeus-python kernel, and every grading
// worker boots a xeus kernel through Public/xeus-kernel-shared.js.
//
// What remains here is still worth keeping separate: `envConfigPython` and
// `deriveExitCode` encode the contract a test script sees and how a crashed
// script scores, and both are asserted against the native worker's behaviour by
// tests that should not have to boot a kernel to run.
//
// Consumers:
//   - Public/python-grading-worker.js: envConfigPython, assignmentSeedPython.
//   - Public/python-grading-shared.js: deriveExitCode.
//   - Public/<language>-grading-shared.js, all four: makeNonce; Lua and
//     Octave also parseStatusRunOutput. Each was copied per language (#1963).
//   - Public/xeus-kernel-shared.js: writeFilesToEmscriptenFS, for every
//     grading worker.
//   - Public/browser-runner.js: deriveExitCode, re-exported on its test hooks.
//
// Loading: classic script, no dependencies.
//   - Workers: importScripts('/grading-shared.js' + self.location.search)
//     (forwarding the worker's own ?v= cache-buster pins all grading files to
//     one release).
//   - Pages: a <script src="/grading-shared.js?v=..."> tag BEFORE
//     browser-runner.js (see _notebook-body.leaf).
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

# Import test_runtime. The import puts the helpers in the __main__ globals,
# where a test script runs. Also put them in builtins, so that other modules
# can call them.
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

    // Materialize a plain file map { <relativePath>: <string|bytes> } into an
    // emscripten module's in-memory file system under workDir, creating parent
    // directories as needed. It only touches `module.FS`, which every
    // emscripten module exposes, so every xeus kernel uses this one copy.
    // Byte values may arrive as a typed array OR a plain Array (postMessage
    // serialization in the worker path), so array-likes are coerced to
    // Uint8Array before writing — FS.writeFile stores a plain Array as text
    // otherwise, corrupting binary support files.
    function writeFilesToEmscriptenFS(module, workDir, files) {
        Object.keys(files).forEach(function (relPath) {
            const value = files[relPath];
            const parts = relPath.split('/');
            if (parts.length > 1) {
                let cur = workDir;
                for (let i = 0; i < parts.length - 1; i++) {
                    cur += '/' + parts[i];
                    try { module.FS.mkdir(cur); } catch (e) { /* already exists */ }
                }
            }
            let data = value;
            if (value && typeof value !== 'string' && typeof value.length === 'number') {
                data = new Uint8Array(value);
            }
            module.FS.writeFile(workDir + '/' + relPath, data);
        });
    }

    // A fresh, unguessable delimiter for one script run. Each grading wrapper
    // writes it around what the grader reads back (a status line, or a replayed
    // stream); student code cannot forge a boundary because it cannot see the
    // nonce. crypto.getRandomValues is available in every browser worker;
    // Math.random is a test-harness fallback only.
    function makeNonce() {
        try {
            var bytes = new Uint8Array(16);
            (root.crypto || globalThis.crypto).getRandomValues(bytes);
            return Array.from(bytes).map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
        } catch (_) {
            var out = '';
            for (var i = 0; i < 4; i++) out += Math.random().toString(16).slice(2, 10);
            return out;
        }
    }

    // Pull the status and the script's stdout back out of a kernel's
    // concatenated stdout stream, for a wrapper that ends its run with ONE
    // line of the form `<nonce>:status:<exitCode>` (Lua and Octave; Python
    // and R report differently and parse in their own modules).
    //
    // Anchored on the LAST occurrence of the marker, so a submission that
    // echoes an earlier line cannot shadow the real one. Returns null when the
    // run never reached the status line; the caller turns that into a
    // substrate error rather than guessing at an exit code, since a missing
    // status means the cell died before it could report anything.
    function parseStatusRunOutput(stdoutText, nonce) {
        var text = String(stdoutText == null ? '' : stdoutText);
        var statusMark = '\n' + nonce + ':status:';

        var statusAt = text.lastIndexOf(statusMark);
        if (statusAt < 0) return null;
        var statusFrom = statusAt + statusMark.length;
        var statusEnd = text.indexOf('\n', statusFrom);
        if (statusEnd < 0) return null;
        var exitCode = parseInt(text.slice(statusFrom, statusEnd).trim(), 10);
        if (!Number.isFinite(exitCode)) return null;

        // The marker's own leading newline is not the script's, so the slice
        // ends before it: a script whose last write had no trailing newline
        // must not gain one.
        return { exitCode: exitCode, stdout: text.slice(0, statusAt) };
    }

    root.ChickadeeGradingShared = {
        envConfigPython: envConfigPython,
        assignmentSeedPython: assignmentSeedPython,
        deriveExitCode: deriveExitCode,
        writeFilesToEmscriptenFS: writeFilesToEmscriptenFS,
        makeNonce: makeNonce,
        parseStatusRunOutput: parseStatusRunOutput
    };
})(typeof self !== 'undefined' ? self : globalThis);
