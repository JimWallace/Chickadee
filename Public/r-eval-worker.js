// Public/r-eval-worker.js
//
// The pattern-family editor's auto-compute substrate for R: loads an
// instructor's solution notebook into the xeus-r global environment, then
// evaluates snippets against it to fill in expected values.
//
// The R sibling of python-eval-worker.js, speaking the SAME message protocol,
// so the editor's client code is identical for both:
//   { id, type: 'init' }                 → { id, ok: true }
//   { id, type: 'loadCells', cells: [] } → { id, ok: true, cellErrors: [{index, message}] }
//   { id, type: 'run', code }            → { id, ok: true, result: <string|null> }
//   any failure                          → { id, ok: false, error }
//
// One protocol addition, backward-compatible: every message may carry
// `runtimeSource`, the R the worker must define before it can report anything.
// It is SEEDED from the server (`AssignmentLanguage.autoComputeRuntimeSource`)
// rather than written here, so the JSON escaper it defines is the same one the
// personalization driver uses. There are three R JSON encoders in this
// codebase; a copy in this file would have been a fourth.
//
// Why a worker at all, inherited from the Python path and still true: auto-
// compute runs the instructor's own solution, and a synchronous CPU-bound loop
// in it never yields, so a Promise.race timeout on the main thread can never
// fire. Only `Worker.terminate()` kills it.
//
// This page is NOT cross-origin isolated — /instructor/:id/edit deliberately is
// not — and does not need to be: the kernel is booted directly through its
// emscripten module rather than JupyterLite's transports, so no
// SharedArrayBuffer is involved. Same path the browser-grading smoke exercises.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/eval-protocol-shared.js' + _search);
importScripts('/r-grading-shared.js' + _search);
importScripts('/r-eval-shared.js' + _search);

var _kernel = self.ChickadeeXeusKernel;
var _eval = self.ChickadeeREvalShared;
var _reply = _kernel.reply;

// The dead-kernel backstop, not a limit on how long code may run — the main
// thread owns that and enforces it by terminating this worker. Set well above
// the editor's own 30s load cap so a terminate always wins the race, and this
// only ever fires for a kernel that is never going to reply at all.
var MAX_WAIT_MS = 60000;

var _booted = false;

/// Boots the kernel and defines the seeded runtime once.
///
/// The runtime is executed as its own top-level statement at boot, which is
/// exactly why the per-call snippets can each stay a single expression — see
/// the one-top-level-expression note in r-eval-shared.js.
async function ensureBooted(runtimeSource) {
    if (_booted) return;
    await _kernel.boot(_eval.R_KERNEL);
    if (runtimeSource) {
        var reply = await _kernel.execute(runtimeSource, { maxWaitMs: MAX_WAIT_MS });
        // A runtime that fails to define leaves every later snippet calling an
        // undefined `.ck_json_str`, which reports as a confusing per-cell error
        // rather than as the substrate failure it is. Fail loudly at boot.
        if (reply.failure) {
            throw new Error('the R auto-compute runtime failed to load: ' + reply.failure);
        }
    }
    _booted = true;
}

/// Runs one solution-notebook cell, returning its error message or null.
async function loadOneCell(source) {
    var nonce = _eval.makeNonce();
    var reply = await _kernel.execute(
        _eval.loadCell(source, nonce), { maxWaitMs: MAX_WAIT_MS });
    var parsed = _eval.parseEvalOutput(reply.stdout, nonce);
    if (parsed) return parsed.error;
    // The cell never reported. Attribute it to the cell rather than failing the
    // whole load, so the remaining cells still get a chance to define their
    // functions — same reason the per-cell errors are caught in R.
    return reply.failure || (reply.stderr || '').trim() || 'the R kernel produced no result';
}

self.onmessage = async function (e) {
    var msg = e.data || {};
    var id = msg.id;
    try {
        if (msg.type === 'init') {
            await ensureBooted(msg.runtimeSource);
            _reply({ id: id, ok: true });
            return;
        }
        if (msg.type === 'loadCells') {
            await ensureBooted(msg.runtimeSource);
            var cells = Array.isArray(msg.cells) ? msg.cells : [];
            var cellErrors = [];
            for (var i = 0; i < cells.length; i++) {
                var message = await loadOneCell(cells[i]);
                if (message) cellErrors.push({ index: i, message: message });
            }
            _reply({ id: id, ok: true, cellErrors: cellErrors });
            return;
        }
        if (msg.type === 'call') {
            // The language-neutral request: call this function with these
            // JSON args. The SNIPPET is built here rather than on the main
            // thread, so rendering R values stays in the R module.
            await ensureBooted(msg.runtimeSource);
            var callNonce = _eval.makeNonce();
            var callReply = await _kernel.execute(
                _eval.callFunction(
                    msg.functionName, msg.args || [],
                    { captureStdout: !!msg.captureStdout }, callNonce),
                { maxWaitMs: MAX_WAIT_MS });
            var parsedCall = _eval.parseEvalOutput(callReply.stdout, callNonce);
            if (!parsedCall) {
                throw new Error(
                    callReply.failure || (callReply.stderr || '').trim()
                    || 'the R kernel produced no result');
            }
            if (parsedCall.error) throw new Error(parsedCall.error);
            _reply({ id: id, ok: true, result: parsedCall.value });
            return;
        }
        if (msg.type === 'run') {
            await ensureBooted(msg.runtimeSource);
            var nonce = _eval.makeNonce();
            var runReply = await _kernel.execute(
                _eval.runExpression(msg.code || '', nonce), { maxWaitMs: MAX_WAIT_MS });
            var parsedRun = _eval.parseEvalOutput(runReply.stdout, nonce);
            if (!parsedRun) {
                throw new Error(
                    runReply.failure || (runReply.stderr || '').trim()
                    || 'the R kernel produced no result');
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
