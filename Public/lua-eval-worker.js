// Public/lua-eval-worker.js
//
// The pattern-family editor's auto-compute substrate for Lua: loads an
// instructor's solution notebook into the xeus-lua globals, then evaluates
// snippets against it to fill in expected values.
//
// The protocol, the boot and the error handling are `serveEvalWorker` in
// xeus-kernel-shared.js, shared with the other three languages.  The runtime
// each message may carry is SEEDED from the server
// (`AssignmentLanguage.autoComputeRuntimeSource`) rather than written here, so
// the serializer that renders a value is the one the personalization driver
// uses and the JSON encoder is not a third copy.
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
importScripts('/lua-grading-shared.js' + _search);
importScripts('/lua-eval-shared.js' + _search);

var _eval = self.ChickadeeLuaEvalShared;

self.ChickadeeXeusKernel.serveEvalWorker({
    label: 'Lua',
    kernel: _eval.LUA_KERNEL,
    // The dead-kernel backstop, not a limit on how long code may run: the main
    // thread owns that and enforces it by terminating this worker.  Set well
    // above the editor's own 30s load cap so a terminate always wins the race.
    maxWaitMs: 60000,
    makeNonce: _eval.makeNonce,
    bootCell: _eval.bootCell,
    loadCell: _eval.loadCell,
    runExpression: _eval.runExpression,
    callFunction: _eval.callFunction,
});
