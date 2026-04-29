// Pyodide-in-Web-Worker shim for the pattern family editor's
// auto-compute (`Public/pattern-family-editor.js`).  v0.4.135.
//
// Why a worker:  the prior implementation ran Pyodide on the main
// browser thread.  A 5-second `Promise.race` timeout was supposed to
// catch run-aways, but `runPythonAsync` only yields control to JS at
// `await` boundaries — synchronous tight loops in the instructor's
// solution notebook (e.g. `while True: pass`, deep recursion) blocked
// the event loop indefinitely, freezing the modal and the rest of the
// page.  Past mitigations (v0.4.124 None-return guard, v0.4.125 AST
// shape fix, v0.4.130 type-check guards) addressed cooperative hangs
// but not CPU-bound ones.  This worker moves Pyodide off the main
// thread so the timeout can actually terminate run-away code:
// `Worker.terminate()` kills the worker mid-execution, the main thread
// allocates a fresh one for the next call, and the UI stays
// responsive throughout.
//
// Why not SharedArrayBuffer-based interrupt instead:  that approach
// would let us interrupt Pyodide via setInterruptBuffer + writing
// SIGINT on timeout, and it'd avoid the worker entirely.  But it
// requires cross-origin isolation (COOP/COEP headers), and the
// pattern-family editor lives at /instructor/:id/edit which the
// COEPMiddleware deliberately does NOT cover (require-corp would
// block CDN imports for CodeMirror, JupyterLite content, etc.).
// Worker-based isolation needs no special headers.
//
// Protocol (postMessage from main thread → worker):
//   { id, type: 'init' }
//     → load Pyodide (one-time ~5s download + init)
//     → posts back { id, ok: true } once ready
//   { id, type: 'loadCells', cells: [string, ...] }
//     → run each notebook code cell in order, swallowing per-cell
//       errors (so a broken cell early in the notebook doesn't stop
//       later cells from defining their functions)
//     → posts back { id, ok: true, cellErrors: [{index, message}, ...] }
//   { id, type: 'run', code: string }
//     → run the given Python snippet, return its last_expr value
//     → posts back { id, ok: true, result: <value as string> }
//                or { id, ok: false, error: <message> }
//
// All replies carry the originating `id` so the main-thread client
// can match concurrent in-flight calls.  In practice the editor only
// has one auto-compute in flight at a time (the debounce coalesces),
// but the id field keeps the protocol self-contained.

importScripts('https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js');

let _pyodide = null;
let _pyodidePromise = null;

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
            await getPyodide();
            self.postMessage({ id: id, ok: true });
            return;
        }
        if (msg.type === 'loadCells') {
            var py = await getPyodide();
            var cells = Array.isArray(msg.cells) ? msg.cells : [];
            var cellErrors = [];
            for (var i = 0; i < cells.length; i++) {
                try {
                    await py.runPythonAsync(cells[i]);
                } catch (err) {
                    var line = (err && err.message)
                        ? String(err.message).split('\n').filter(function (l) { return l.trim(); }).pop()
                        : String(err);
                    cellErrors.push({ index: i, message: line || 'error' });
                }
            }
            self.postMessage({ id: id, ok: true, cellErrors: cellErrors });
            return;
        }
        if (msg.type === 'run') {
            var py2 = await getPyodide();
            var result = await py2.runPythonAsync(msg.code || '');
            // Result is the last_expr's value.  For our snippets it's
            // already a JSON string; pass it back verbatim.
            self.postMessage({ id: id, ok: true, result: result });
            return;
        }
        self.postMessage({ id: id, ok: false, error: 'unknown message type: ' + msg.type });
    } catch (err) {
        var emsg = (err && err.message) ? String(err.message) : String(err);
        self.postMessage({ id: id, ok: false, error: emsg });
    }
};
