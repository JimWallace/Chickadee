// Public/octave-eval-worker.js
//
// The pattern-family editor's auto-compute substrate for Octave: loads an
// instructor's solution notebook into the xeus-octave session, then evaluates
// snippets against it to fill in expected values.
//
// The protocol, the boot and the error handling are `serveEvalWorker` in
// xeus-kernel-shared.js, shared with the other three languages.  The runtime
// each message may carry is SEEDED from the server
// (`AssignmentLanguage.autoComputeRuntimeSource`) rather than written here, so
// the serializer that renders a value is the one the personalization driver
// uses and the string escaper is not a second copy.
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
importScripts('/octave-grading-shared.js' + _search);
importScripts('/octave-eval-shared.js' + _search);

var _eval = self.ChickadeeOctaveEvalShared;

self.ChickadeeXeusKernel.serveEvalWorker({
    label: 'Octave',
    kernel: _eval.OCTAVE_KERNEL,
    // The dead-kernel backstop, not a limit on how long code may run: the main
    // thread owns that and enforces it by terminating this worker.  Higher
    // than the others because Octave is the largest vendored env (142 MB) and
    // the slowest to boot.
    maxWaitMs: 90000,
    makeNonce: _eval.makeNonce,
    bootCell: _eval.bootCell,
    loadCell: _eval.loadCell,
    runExpression: _eval.runExpression,
    callFunction: _eval.callFunction,
});
