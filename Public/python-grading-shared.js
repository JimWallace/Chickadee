// Public/python-grading-shared.js
//
// Grading semantics for the xeus-python browser grader — the Python analogue of
// Public/r-grading-shared.js, and the counterpart to Public/grading-shared.js
// (which holds the Python that BOTH substrates run).
//
// Loading: classic script.  Requires /grading-shared.js first.
// Exposes exactly one global: ChickadeePythonGradingShared.
//
//
// How little this has to do
// -------------------------
// The R port had to re-create a process contract from scratch, because
// test_runtime.R calls `quit()` and reads `commandArgs()` and a kernel has
// neither.  Python needs almost none of that, for one reason: grading-shared.js
// already captures output IN-PROCESS — it swaps sys.stdout/sys.stderr for
// StringIO and catches SystemExit itself — rather than relying on the substrate
// to hand it two pipes.  All of that is ordinary Python and behaves identically
// inside a kernel.  So `envConfigPython`, `STDOUT_REDIRECT_PY`,
// `RESTORE_STREAMS_PY`, `assignmentSeedPython` and `deriveExitCode` are reused
// verbatim, and the Pyodide and xeus-python graders share them the way the
// worker and main-thread Pyodide graders already do.
//
// Two things that were true of R are deliberately NOT repeated here:
//
//   * stderr is captured by the StringIO redirection, not read off the kernel's
//     iopub stream.  R forced the latter because `evaluate::evaluate()` installs
//     calling handlers that intercept message conditions before a sink sees
//     them; Python has no equivalent, and reading the kernel's streams would be
//     a strictly worse contract (it would also pick up anything the kernel
//     itself logged).
//   * the wrapper is not squeezed into one top-level expression.  That rule
//     exists because xeus-r charges ~180ms per top-level expression; measured,
//     xeus-python costs ~5ms per cell whether it contains one statement or
//     twenty.  Write it for clarity.
//
//
// The one thing that genuinely changes
// ------------------------------------
// `py.runPythonAsync(CAPTURE_OUTPUT_PY)` RETURNS the captured tuple to JS.
// `execute_request` returns nothing — a kernel replies with messages, not
// values.  So the payload is printed on the last line of the cell behind a
// per-run nonce and parsed back.  JSON, because it is stdlib and removes every
// escaping question; the nonce, because student code prints arbitrary text and
// must not be able to forge the boundary (it cannot guess a value it never
// sees).
//
// The cell must therefore be exception-safe end to end: if the payload does not
// print, the run reports nothing at all.  Every failure mode inside is caught
// and folded into the payload instead of being allowed to abort the cell.

(function (root) {
    'use strict';

    var shared = root.ChickadeeGradingShared;

    // The vendored kernel the Python grader boots — mirroring
    // Public/jupyterlite/xeus/kernels.json and chickadee-python/xpython/kernel.json.
    // This is the SAME env the notebook editor boots for Python notebooks, which
    // is the property the Pyodide grader does not have (editor xeus-python 3.13,
    // grading Pyodide 3.14).
    var PYTHON_KERNEL = {
        envName: 'chickadee-python',
        kernelName: 'xpython',
        // xpython links only libxeus; the R kernel additionally dlopen()s libR
        // and friends. From the `metadata.shared` block of xpython/kernel.json.
        sharedLibs: { 'libxeus.so': 'lib/libxeus.so' },
        // Unlike xeus-r, the CPython runtime has to be started once the env is
        // unpacked. See xeus-kernel-shared.js.
        needsPythonRuntime: true,
        // The subset booted before any script runs: the interpreter and the
        // kernel, and nothing from the data-science half. Everything else is
        // installed on demand when a script or a submission imports it.
        // `xeus-python` transitively pulls python, pyjs-rt, ipython and the
        // xeus-python-shell chain, so this one name is the whole kernel.
        bootSeeds: ['xeus-python'],
        argv: ['xeus/chickadee-python/bin/xpython.js'],
    };

    // A fresh, unguessable delimiter for one script run. crypto.getRandomValues
    // is available in every browser worker; Math.random is a test-harness
    // fallback only.
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

    // The cell that grades ONE script.
    //
    // Structure mirrors what the Pyodide path does across several
    // runPythonAsync calls, collapsed into one cell because a kernel round-trip
    // is per-cell: redirect the streams, run the script catching SystemExit the
    // way a `python3 script` subprocess would report an exit status, restore the
    // streams, then print the payload.
    //
    // `compile(source, scriptName, 'exec')` gives inspect.stack() the real
    // filename, which is how test_runtime reads the correct test label — the
    // same reason grading-shared.js's runScriptPython does it.
    function runScriptCellPython(scriptName, nonce) {
        var name = JSON.stringify(String(scriptName));
        var marker = JSON.stringify('\n' + nonce + ':');
        return [
            'import sys as _ck_sys, io as _ck_io, json as _ck_json, traceback as _ck_tb',
            '_ck_exit = None',
            '_ck_error = None',
            '_ck_out = _ck_io.StringIO()',
            '_ck_err = _ck_io.StringIO()',
            '_ck_saved = (_ck_sys.stdout, _ck_sys.stderr)',
            'try:',
            '    _ck_sys.stdout = _ck_out',
            '    _ck_sys.stderr = _ck_err',
            '    try:',
            '        from test_runtime import passed, failed, errored, require_function',
            '    except Exception:',
            // A setup without the helper library is not automatically a failure:
            // a hand-authored script need not import it. Let the script itself
            // decide, exactly as it would under `python3`.
            '        pass',
            '    try:',
            '        with open(' + name + ', encoding="utf-8") as _ck_fh:',
            '            _ck_src = _ck_fh.read()',
            '        exec(compile(_ck_src, ' + name + ', "exec"), globals())',
            '    except SystemExit as _ck_e:',
            '        _ck_exit = _ck_e.code',
            '    except BaseException:',
            // Mirrors `python3 script` dying on an uncaught exception: the
            // traceback goes to stderr and the process exits non-zero. The exit
            // code itself is derived on the JS side by deriveExitCode, so the
            // mapping stays in one place.
            '        _ck_error = _ck_tb.format_exc()',
            'finally:',
            '    _ck_sys.stdout, _ck_sys.stderr = _ck_saved',
            'try:',
            '    _ck_payload = _ck_json.dumps({',
            '        "exit": _ck_exit, "out": _ck_out.getvalue(),',
            '        "err": _ck_err.getvalue(), "error": _ck_error})',
            'except Exception:',
            // Output that will not serialise (a lone surrogate from a mangled
            // decode, say) must not take the whole result down with it.
            '    _ck_payload = _ck_json.dumps({"exit": _ck_exit, "out": "",',
            '        "err": "grading could not serialise this test\'s output", "error": _ck_error})',
            'print(' + marker + ' + _ck_payload)',
        ].join('\n');
    }

    // Pull the payload back out of the kernel's concatenated stdout.
    //
    // Anchored on the LAST occurrence of the marker, so a submission that echoes
    // an earlier line cannot shadow the real one — and it cannot produce the
    // marker in the first place without the nonce.
    //
    // Returns null when the cell never reported: the caller turns that into a
    // substrate error rather than guessing at a status, since a cell that died
    // before printing tells us nothing about the test.
    function parseRunOutput(stdoutText, nonce) {
        var text = String(stdoutText == null ? '' : stdoutText);
        var marker = '\n' + nonce + ':';
        var at = text.lastIndexOf(marker);
        if (at < 0) return null;
        var from = at + marker.length;
        var end = text.indexOf('\n', from);
        var line = end < 0 ? text.slice(from) : text.slice(from, end);
        var payload;
        try { payload = JSON.parse(line); } catch (_) { return null; }
        if (!payload || typeof payload !== 'object') return null;

        // One implementation of "exit code from a captured SystemExit, else from
        // the raised error" — the same helper the Pyodide path uses, so the two
        // substrates cannot disagree about what a crashed script scores.
        var derived = shared.deriveExitCode(
            payload.exit, payload.error || null, payload.err || '');
        return {
            exitCode: derived.exitCode,
            stdout: payload.out || '',
            stderr: derived.stderr || '',
        };
    }

    root.ChickadeePythonGradingShared = {
        PYTHON_KERNEL: PYTHON_KERNEL,
        makeNonce: makeNonce,
        runScriptCellPython: runScriptCellPython,
        parseRunOutput: parseRunOutput,
    };
})(typeof self !== 'undefined' ? self : globalThis);
