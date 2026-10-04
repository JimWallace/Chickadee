// Public/r-eval-worker.js
//
// The pattern-family editor's auto-compute substrate for R: loads an
// instructor's solution notebook into the xeus-r global environment, then
// evaluates snippets against it to fill in expected values.
//
// The protocol, the boot and the error handling are `serveEvalWorker` in
// xeus-kernel-shared.js, shared with the other three languages.  The runtime
// each message may carry is SEEDED from the server
// (`AssignmentLanguage.autoComputeRuntimeSource`) rather than written here, so
// the JSON escaper it defines is the same one the personalization driver uses.
// It runs as its own top-level statement at boot, which is exactly why the
// per-call snippets can each stay a single expression; see the
// one-top-level-expression note in r-eval-shared.js.
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
importScripts('/r-grading-shared.js' + _search);
importScripts('/r-eval-shared.js' + _search);

var _eval = self.ChickadeeREvalShared;

self.ChickadeeXeusKernel.serveEvalWorker({
    label: 'R',
    kernel: _eval.R_KERNEL,
    // The dead-kernel backstop, not a limit on how long code may run: the main
    // thread owns that and enforces it by terminating this worker.  Set well
    // above the editor's own 30s load cap so a terminate always wins the race.
    maxWaitMs: 60000,
    makeNonce: _eval.makeNonce,
    // The seeded runtime is plain R, run as it is.
    bootCell: function (runtimeSource) { return runtimeSource; },
    loadCell: _eval.loadCell,
    runExpression: _eval.runExpression,
    callFunction: _eval.callFunction,
});
