// Public/python-grading-worker.js
//
// The xeus-python browser-grading substrate — the Python counterpart to
// Public/r-grading-worker.js, and the eventual replacement for
// Public/grading-worker.js (Pyodide).
//
// Why move Python off Pyodide at all (#1271):
//   * ONE environment for authoring and grading.  The editor has run
//     xeus-python since #1270 while grading ran Pyodide, so "it ran in the
//     editor" did not imply "it grades in the browser".  R has had this property
//     since browser-graded R shipped; this gives it to Python.
//   * it is the step that lets the ~465 MB vendored Pyodide go, once the other
//     consumers move (see docs/xeus-python-grading-migration-plan.md).
//   * it removes an accidental dependency: Pyodide 3.14 refuses to load in a
//     classic worker and only loads today because the CSP blocks its detection
//     probe.  See the comment at the top of grading-worker.js.
//
// Measured before building this (docs/xeus-python-grading-spike.md): xeus-python
// costs ~5 ms per cell regardless of statement count — R's ~180 ms
// per-top-level-expression yield does not generalise — and boot is a wash once
// Pyodide's on-demand numpy/pandas fetch is counted.
//
// RunnerCore still owns the suite loop, dependency gating, and output
// interpretation.  This worker supplies one operation: run a script, report its
// raw exit code + stdout + stderr.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js    — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js       — booting a kernel + driving one cell (any kernel)
//   /grading-shared.js           — the Python BOTH substrates run, and the FS writer
//   /python-grading-shared.js    — the grading cell and its reply parsing
//   this file                    — the worker protocol
//
// Protocol is identical to grading-worker.js and r-grading-worker.js, so
// GradingWorkerExecutor drives all three without knowing which it has:
//   { id, type: 'init', files, seed } → { id, ok: true } | { id, ok: false, error }
//   { id, type: 'run', script, limit } → { id, ok: true, result: {exitCode, stdout, stderr} }
//
// No timeout here — the main thread races the reply against a real timer and
// terminates the worker, the only kill path that works against a synchronous
// CPU-bound loop in student code.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/python-grading-shared.js' + _search);

var _kernel = self.ChickadeeXeusKernel;
var _shared = self.ChickadeeGradingShared;
var _py = self.ChickadeePythonGradingShared;
var _reply = _kernel.reply;

// `No module named 'X'` → X, from anywhere in a traceback. Python reports the
// top-level name that failed to resolve, which is exactly the key moduleOwners
// is indexed by.
var MISSING_MODULE = /No module named '([A-Za-z_][A-Za-z0-9_]*)'/;

// Python caches per-directory listings in its path finders, so a package that
// appears in an already-scanned site-packages AFTER a failed import can stay
// invisible. invalidate_caches() is the supported way to make it visible and
// costs nothing. (The current kernel appears not to need it — the spike passed
// without — but that is a timing-dependent property of emscripten's FS mtimes,
// not a guarantee, and this is the documented fix.)
var REFRESH_IMPORT_CACHES = 'import importlib\nimportlib.invalidate_caches()';

// Grade one Python script and return RAW output { exitCode, stdout, stderr }.
// No interpretation happens here — RunnerCore maps the exit code to a status and
// reads the last stdout line for the shortResult, byte-for-byte as it does for
// the native `python3` subprocess and for the Pyodide grader.
//
// The kernel boots with the bare interpreter (see the seeds in `init`) and gains
// packages as scripts ask for them. The retry loop itself lives in
// xeus-kernel-shared.js because R needs exactly the same one.
async function runPythonScript(scriptName) {
    var parsed = null;
    var reply = await _kernel.runInstallingMissingPackages(
        async function () {
            var nonce = _py.makeNonce();
            var attemptReply = await _kernel.execute(_py.runScriptCellPython(scriptName, nonce));
            parsed = _py.parseRunOutput(attemptReply.stdout, nonce);
            return attemptReply;
        },
        {
            pattern: MISSING_MODULE,
            // A failing import surfaces on the cell's stderr; if the cell never
            // reported at all, `failure` is where the kernel put the reason.
            textOf: function (r) { return (parsed ? parsed.stderr : '') || r.stderr || r.failure; },
            afterInstall: REFRESH_IMPORT_CACHES,
            onInstall: function (added) {
                _reply({
                    type: 'phase', phase: 'python_package_installed', packages: added.join(','),
                });
            },
        });
    if (parsed) return parsed;

    // The cell never reported. Surface it as a substrate error (exit 2) with
    // whatever the kernel did say, rather than inventing a pass/fail. This is
    // also the path a killed-mid-cell kernel takes.
    var detail = reply.failure || (reply.stderr || '').trim()
        || 'the Python kernel produced no result for this test';
    return { exitCode: 2, stdout: 'Python grading failed: ' + detail, stderr: reply.stderr || '' };
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            var initT0 = Date.now();
            // Boot the bare interpreter, not the whole environment. The env's
            // data-science half is 84% of its 61 MB and most of its install
            // time, and a given assignment uses little of it; whatever a script
            // or a submission actually imports is added on demand below.
            //
            // Measured, Chromium, 3 runs, local disk (so this is untar + dlopen
            // cost, not download — the saving survives a fully warm cache):
            // full env 8604 ms, bare kernel 4822 ms, +numpy 4839 ms. An add into
            // the live kernel costs 242 ms for numpy, 696 ms for pandas.
            //
            // env config only needs the stdlib plus the workspace's own
            // test_runtime, so nothing here depends on the optional half.
            await _kernel.boot(_py.PYTHON_KERNEL, { seeds: _py.PYTHON_KERNEL.bootSeeds });
            // Breadcrumbs (no `id`) — the kernel boot is the slow step, so a
            // wedge there is worth telling apart from a wedge in env setup.
            // browser-runner.js forwards these to the submit-phase telemetry.
            _reply({ type: 'phase', phase: 'python_kernel_booted', ms: Date.now() - initT0 });

            var workDir = '/chickadee_work_' + Date.now();
            _kernel.mountWorkspace(workDir, msg.files, _shared.writeFilesToEmscriptenFS);

            // os.environ persists for the whole session, so one set covers every
            // script (parity with the worker's test subprocess).
            if (msg.seed !== null && msg.seed !== undefined) {
                await _kernel.execute(_shared.assignmentSeedPython(msg.seed));
            }
            // The SAME env-config block the Pyodide grader runs: sys.path, the
            // chdir, the stale-module flush, and the test_runtime/builtins
            // wiring. Reused rather than reimplemented so the two substrates
            // cannot disagree about what a test script sees.
            var envReply = await _kernel.execute(_shared.envConfigPython(workDir));
            if (envReply.failure) {
                throw new Error('Failed to configure Python environment: ' + envReply.failure);
            }
            _reply({ type: 'phase', phase: 'python_env_configured', ms: Date.now() - initT0 });
            _reply({ id: id, ok: true });
            return;
        }
        if (msg.type === 'run') {
            var result = await runPythonScript(msg.script);
            _reply({ id: id, ok: true, result: result });
            return;
        }
        _reply({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        _reply({ id: id, ok: false, error: (err && err.message) ? String(err.message) : String(err) });
    }
};
