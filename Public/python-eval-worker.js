// Public/python-eval-worker.js
//
// The pattern-family editor's auto-compute substrate for Python: loads an
// instructor's solution notebook into the xeus-python namespace, then evaluates
// snippets against it to fill in expected values.  It replaced the Pyodide
// worker (#1271), so the value auto-compute computes is the value the generated
// test asserts, on the same interpreter and the same package set.
//
// The protocol, the boot and the error handling are `serveEvalWorker` in
// xeus-kernel-shared.js, shared with the other three languages.  As for them,
// the editor sends `call`, and python-eval-shared.js builds the cell.  Python
// also supplies `readCallResult`.  Its call cell reports a `__chickadee_kind__`
// payload, and that payload tells a `None` return or a type that does not
// round-trip through JSON apart from a value.
//
// This page is NOT cross-origin isolated (/instructor/:id/edit deliberately is
// not) and does not need to be: the kernel is booted directly through its
// emscripten module rather than JupyterLite's transports, so no
// SharedArrayBuffer is involved.  Same path the browser-grading smoke exercises.

var _search = self.location.search || '';
importScripts('/vendor/xeus-bootstrap.js' + _search);
importScripts('/xeus-kernel-shared.js' + _search);
importScripts('/grading-shared.js' + _search);
importScripts('/eval-protocol-shared.js' + _search);
importScripts('/python-grading-shared.js' + _search);
importScripts('/python-eval-shared.js' + _search);

var _eval = self.ChickadeePythonEvalShared;

self.ChickadeeXeusKernel.serveEvalWorker({
    label: 'Python',
    kernel: _eval.PYTHON_KERNEL,
    // The dead-kernel backstop, not a limit on how long code may run: the main
    // thread owns that and enforces it by terminating this worker.  Set well
    // above the editor's own 30s load cap so a terminate always wins the race.
    maxWaitMs: 60000,
    makeNonce: _eval.makeNonce,
    loadCell: _eval.loadCellPython,
    runExpression: _eval.runExpressionPython,
    callFunction: _eval.callFunctionPython,
    readCallResult: _eval.readCallResultPython,
});
