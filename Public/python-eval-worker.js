// Public/python-eval-worker.js
//
// The pattern-family editor's auto-compute substrate: loads an instructor's
// solution notebook into a Python namespace, then evaluates snippets against it
// to fill in expected values. Replaces Public/pyodide-worker.js (#1271, plan
// §A2) — the last consumer of the vendored Pyodide that runs authored code.
//
// Why a worker at all (inherited from the Pyodide version, and still true):
// auto-compute runs the instructor's own solution, and a synchronous CPU-bound
// loop in it — `while True: pass`, runaway recursion — never yields, so a
// Promise.race timeout on the main thread can never fire. Only
// `Worker.terminate()` kills it. Everything about the timeout contract is
// unchanged; only the interpreter underneath it moved.
//
// What moving to xeus-python buys here:
//   * ONE Python for authoring and grading. The value auto-compute computes is
//     the value the generated test will assert, and until now those ran on
//     different interpreters with different package sets. A `numpy` version
//     difference between Pyodide and the kernel could produce an expected value
//     the graded test then failed to reproduce.
//   * it is the last of the two remaining consumers, so retiring the ~465 MB
//     Public/pyodide comes down to the vendored jupyterlite-pyodide-kernel
//     after this.
//   * it drops the accidental CSP dependency documented at the top of the file
//     it replaces: Pyodide 3.14 refuses to load in a classic worker and only
//     loaded because `script-src` has no `data:`, which blocked its detection
//     probe.
//
// This page is NOT cross-origin isolated — /instructor/:id/edit deliberately is
// not, so `require-corp` cannot break its subresources — and does not need to
// be: the kernel is booted directly through its emscripten module rather than
// JupyterLite's coincident/comlink transports, so no SharedArrayBuffer is
// involved. That is the same path the browser-grading smoke exercises on a
// non-isolated harness page.
//
// Protocol (unchanged from pyodide-worker.js, so the editor's client code is
// untouched apart from the script URL):
//   { id, type: 'init' }                → { id, ok: true }
//   { id, type: 'loadCells', cells: [] } → { id, ok: true, cellErrors: [{index, message}] }
//   { id, type: 'run', code }            → { id, ok: true, result: <string|null> }
//   any failure                          → { id, ok: false, error }

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/python-grading-shared.js' + _search);
importScripts('/python-eval-shared.js' + _search);

var _kernel = self.ChickadeeXeusKernel;
var _eval = self.ChickadeePythonEvalShared;
var _reply = _kernel.reply;

// The dead-kernel backstop, not a limit on how long code may run — the main
// thread owns that and enforces it by terminating this worker (see
// xeus-kernel-shared.js). Set well above the editor's own 30s load cap so a
// terminate always wins the race, and this only ever fires for a kernel that is
// never going to reply at all.
var MAX_WAIT_MS = 60000;

var _booted = false;

async function ensureBooted() {
    if (_booted) return;
    await _kernel.boot(_eval.PYTHON_KERNEL);
    _booted = true;
}

/// Runs one solution-notebook cell, returning its error message or null.
async function loadOneCell(source) {
    var nonce = _eval.makeNonce();
    var reply = await _kernel.execute(
        _eval.loadCellPython(source, nonce), { maxWaitMs: MAX_WAIT_MS });
    var parsed = _eval.parseEvalOutput(reply.stdout, nonce);
    if (parsed) return parsed.error;
    // The cell never reported. Attribute it to the cell rather than failing the
    // whole load, so the remaining cells still get a chance to define their
    // functions — same reason the per-cell errors are caught in Python.
    return reply.failure || (reply.stderr || '').trim() || 'the Python kernel produced no result';
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            await ensureBooted();
            _reply({ id: id, ok: true });
            return;
        }
        if (msg.type === 'loadCells') {
            await ensureBooted();
            var cells = Array.isArray(msg.cells) ? msg.cells : [];
            var cellErrors = [];
            for (var i = 0; i < cells.length; i++) {
                var message = await loadOneCell(cells[i]);
                if (message) cellErrors.push({ index: i, message: message });
            }
            _reply({ id: id, ok: true, cellErrors: cellErrors });
            return;
        }
        if (msg.type === 'run') {
            await ensureBooted();
            var nonce = _eval.makeNonce();
            var runReply = await _kernel.execute(
                _eval.runExpressionPython(msg.code || '', nonce), { maxWaitMs: MAX_WAIT_MS });
            var parsedRun = _eval.parseEvalOutput(runReply.stdout, nonce);
            if (!parsedRun) {
                throw new Error(
                    runReply.failure || (runReply.stderr || '').trim()
                    || 'the Python kernel produced no result');
            }
            if (parsedRun.error) throw new Error(parsedRun.error);
            _reply({ id: id, ok: true, result: parsedRun.value });
            return;
        }
        _reply({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        _reply({ id: id, ok: false, error: (err && err.message) ? String(err.message) : String(err) });
    }
};
