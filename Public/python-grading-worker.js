// Public/python-grading-worker.js
//
// The Python browser-grading substrate: boots the vendored xeus-python kernel
// in a Web Worker and grades one Python test script per request.  It replaced
// the Pyodide grader (#1271), so the editor and the grader run one Python
// environment and "it ran in the editor" implies "it grades in the browser".
//
// What this is NOT: a grading implementation.  RunnerCore (Swift, the same
// code the native worker runs, compiled to wasm) owns the suite loop,
// dependency gating, and output interpretation.  The worker protocol, the boot
// sequence and the error handling are `serveGradingWorker` in
// xeus-kernel-shared.js, shared with the other three graders.  This file is
// the part only Python can supply.
//
// Split of responsibilities:
//   /vendor/xeus-bootstrap.js    — the mambajs slice that unpacks a conda env
//   /xeus-kernel-shared.js       — booting a kernel, driving one cell, the protocol
//   /grading-shared.js           — the environment config, the seed, and the FS writer
//   /python-grading-shared.js    — the grading cell, the reset, and the reply parsing
//   this file                    — the Python config
//
// The worker's own ?v= cache-buster is forwarded to every Chickadee-authored
// file it pulls in, so one release's grading files pin together. The kernel's
// own assets under /jupyterlite/xeus/ are not busted: they are regenerated
// only by a deliberate re-vendor, and the editor loads them unbusted too.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/python-grading-shared.js' + _search);

var _shared = self.ChickadeeGradingShared;
var _py = self.ChickadeePythonGradingShared;

self.ChickadeeXeusKernel.serveGradingWorker({
    label: 'Python',
    phasePrefix: 'python',
    // The kernel boots the bare interpreter (`PYTHON_KERNEL.bootSeeds`), not
    // the whole environment.  The env's data-science half is 84% of its 61 MB
    // and most of its install time, and a given assignment uses little of it;
    // whatever a script or a submission imports is added on demand.
    //
    // Measured, Chromium, 3 runs, local disk (so this is untar + dlopen cost,
    // not download): full env 8604 ms, bare kernel 4822 ms, +numpy 4839 ms. An
    // add into the live kernel costs 242 ms for numpy, 696 ms for pandas.
    kernel: _py.PYTHON_KERNEL,
    // os.environ persists for the whole session, so one set covers every
    // script (parity with the worker's test subprocess).
    seedCell: _shared.assignmentSeedPython,
    workspaceCells: function (workDir) {
        return [
            // Record the state a fresh process starts in, after the seed and
            // before anything a script can change.  Each script is reset to it.
            {
                source: _py.cleanStateCellPython(workDir),
                what: 'Failed to record the clean Python state',
            },
            // sys.path, the chdir, the stale-module flush, and the
            // test_runtime/builtins wiring.
            {
                source: _shared.envConfigPython(workDir),
                what: 'Failed to configure Python environment',
            },
        ];
    },
    // Put the kernel back the way a fresh `python3` process would find it, then
    // configure the environment again (#1959).
    beforeEachScript: function (workDir) {
        return _py.RESET_CELL_PYTHON + '\n' + _shared.envConfigPython(workDir);
    },
    makeNonce: _py.makeNonce,
    runScript: _py.runScriptCellPython,
    // The cell captures the script's stderr itself, so the parsed result
    // carries it.
    parseRunOutput: _py.parseRunOutput,
    missingPackage: {
        // `No module named 'X'` → X, from anywhere in a traceback.  Python
        // reports the top-level name that failed to resolve, which is exactly
        // the key moduleOwners is indexed by.
        pattern: /No module named '([A-Za-z_][A-Za-z0-9_]*)'/,
        // A failing import surfaces on the cell's stderr; if the cell never
        // reported at all, `failure` is where the kernel put the reason.
        textOf: function (reply, parsed) {
            return (parsed ? parsed.stderr : '') || reply.stderr || reply.failure;
        },
        // Python caches per-directory listings in its path finders, so a
        // package that appears in an already-scanned site-packages AFTER a
        // failed import can stay invisible.  invalidate_caches() is the
        // documented fix and costs nothing.
        afterInstall: 'import importlib\nimportlib.invalidate_caches()',
    },
});
