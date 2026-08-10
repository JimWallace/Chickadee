// Public/lua-eval-worker.js
//
// The pattern-family editor's auto-compute substrate for Lua: loads an
// instructor's solution notebook into the xeus-lua globals, then evaluates
// snippets against it to fill in expected values.
//
// The Lua sibling of r-eval-worker.js and python-eval-worker.js, speaking the
// SAME message protocol, so the editor's client code is identical for all three:
//   { id, type: 'init' }                 → { id, ok: true }
//   { id, type: 'loadCells', cells: [] } → { id, ok: true, cellErrors: [{index, message}] }
//   { id, type: 'call', functionName, args, captureStdout }
//                                        → { id, ok: true, result: <string|null> }
//   { id, type: 'run', code }            → { id, ok: true, result: <string|null> }
//   any failure                          → { id, ok: false, error }
//
// Every message may carry `runtimeSource`, the Lua the worker must define
// before it can report anything. It is SEEDED from the server
// (`AssignmentLanguage.autoComputeRuntimeSource`) rather than written here, so
// the serializer that renders a value is the one the personalization driver
// uses and the JSON encoder is not a third copy.
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
importScripts('/lua-grading-shared.js' + _search);
importScripts('/lua-eval-shared.js' + _search);

var _kernel = self.ChickadeeXeusKernel;
var _eval = self.ChickadeeLuaEvalShared;
var _reply = _kernel.reply;

// The dead-kernel backstop, not a limit on how long code may run — the main
// thread owns that and enforces it by terminating this worker. Set well above
// the editor's own 30s load cap so a terminate always wins the race, and this
// only ever fires for a kernel that is never going to reply at all.
var MAX_WAIT_MS = 60000;

var _booted = false;

/// Boots the kernel and defines the seeded runtime once.
async function ensureBooted(runtimeSource) {
    if (_booted) return;
    await _kernel.boot(_eval.LUA_KERNEL);
    if (runtimeSource) {
        var reply = await _kernel.execute(
            _eval.bootCell(runtimeSource), { maxWaitMs: MAX_WAIT_MS });
        // A runtime that fails to define leaves every later snippet calling a
        // nil `chickadee_json_str`, which reports as a confusing per-cell error
        // rather than as the substrate failure it is. Fail loudly at boot.
        if (reply.failure) {
            throw new Error('the Lua auto-compute runtime failed to load: ' + reply.failure);
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
    // functions — same reason the per-cell errors are caught in Lua.
    return reply.failure || (reply.stderr || '').trim() || 'the Lua kernel produced no result';
}

/// Runs one snippet that reports a value, unwrapping the payload.
///
/// `build` receives the nonce and returns the snippet, so the nonce the parser
/// reads and the nonce the snippet prints cannot drift apart.
async function evaluateSnippet(build) {
    var nonce = _eval.makeNonce();
    var reply = await _kernel.execute(build(nonce), { maxWaitMs: MAX_WAIT_MS });
    var parsed = _eval.parseEvalOutput(reply.stdout, nonce);
    if (!parsed) {
        throw new Error(
            reply.failure || (reply.stderr || '').trim()
            || 'the Lua kernel produced no result');
    }
    if (parsed.error) throw new Error(parsed.error);
    return parsed.value;
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
            // The language-neutral request: call this function with these JSON
            // args. The SNIPPET is built here rather than on the main thread,
            // so rendering Lua values stays in the Lua module.
            await ensureBooted(msg.runtimeSource);
            var callResult = await evaluateSnippet(function (nonce) {
                return _eval.callFunction(
                    msg.functionName, msg.args || [],
                    { captureStdout: !!msg.captureStdout }, nonce);
            });
            _reply({ id: id, ok: true, result: callResult });
            return;
        }
        if (msg.type === 'run') {
            await ensureBooted(msg.runtimeSource);
            var runResult = await evaluateSnippet(function (nonce) {
                return _eval.runExpression(msg.code || '', nonce);
            });
            _reply({ id: id, ok: true, result: runResult });
            return;
        }
        _reply({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        _reply({ id: id, ok: false, error: (err && err.message) ? String(err.message) : String(err) });
    }
};
