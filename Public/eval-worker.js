// Public/eval-worker.js
//
// The pattern-family editor's auto-compute substrate, for every in-page kernel
// language: loads an instructor's solution notebook into the kernel, then
// evaluates snippets against it to fill in expected values. The value
// auto-compute computes is the value the generated test asserts, on the same
// interpreter and the same package set.
//
// The language comes from `?lang=` on the worker URL, or from
// `self.ChickadeeEvalLanguage`, which each `<language>-eval-worker.js` entry
// file sets before it loads this one. `LanguageDescriptor` names those entry
// files (#2721).
//
// The protocol, the boot and the error handling are `serveEvalWorker` in
// xeus-kernel-shared.js. The editor sends `call`, and `<language>-eval-shared.js`
// builds the cell. Python also supplies `readCallResult`: its call cell reports
// a `__chickadee_kind__` payload, and that payload tells a `None` return or a
// type that does not round-trip through JSON apart from a value. R, Lua and
// Octave each get a runtime that is SEEDED from the server
// (`AssignmentLanguage.autoComputeRuntimeSource`) rather than written here, so
// the serializer that renders a value is the one the personalization driver
// uses. For R it runs as its own top-level statement at boot, which is why the
// per-call snippets can each stay a single expression; see the
// one-top-level-expression note in r-eval-shared.js.
//
// This page is NOT cross-origin isolated (/instructor/:id/edit deliberately is
// not) and does not need to be: the kernel is booted directly through its
// emscripten module rather than JupyterLite's transports, so no
// SharedArrayBuffer is involved.  Same path the browser-grading smoke exercises.

var _search = self.location.search || '';
var _lang = (/[?&]lang=([a-z]+)/.exec(_search) || [])[1] || self.ChickadeeEvalLanguage;
// Only the cache-busting version goes on to the scripts this loads.
var _version = /[?&](v=[^&]*)/.exec(_search);
var _suffix = _version ? '?' + _version[1] : '';

// The dead-kernel backstop, not a limit on how long code may run: the main
// thread owns that and enforces it by terminating this worker.  Set well above
// the editor's own 30s load cap so a terminate always wins the race.
var _MAX_WAIT_MS = 60000;

var _EVALUATORS = {
    python: {
        label: 'Python',
        shared: 'ChickadeePythonEvalShared',
        config: function (e) {
            return {
                kernel: e.PYTHON_KERNEL,
                loadCell: e.loadCellPython,
                runExpression: e.runExpressionPython,
                callFunction: e.callFunctionPython,
                readCallResult: e.readCallResultPython,
            };
        },
    },
    r: {
        label: 'R',
        shared: 'ChickadeeREvalShared',
        config: function (e) {
            return {
                kernel: e.R_KERNEL,
                // The seeded runtime is plain R, run as it is.
                bootCell: function (runtimeSource) { return runtimeSource; },
                loadCell: e.loadCell,
                runExpression: e.runExpression,
                callFunction: e.callFunction,
            };
        },
    },
    lua: {
        label: 'Lua',
        shared: 'ChickadeeLuaEvalShared',
        config: function (e) {
            return {
                kernel: e.LUA_KERNEL,
                bootCell: e.bootCell,
                loadCell: e.loadCell,
                runExpression: e.runExpression,
                callFunction: e.callFunction,
            };
        },
    },
    octave: {
        label: 'Octave',
        shared: 'ChickadeeOctaveEvalShared',
        // Higher than the others because Octave is the largest vendored env
        // (142 MB) and the slowest to boot.
        maxWaitMs: 90000,
        config: function (e) {
            return {
                kernel: e.OCTAVE_KERNEL,
                bootCell: e.bootCell,
                loadCell: e.loadCell,
                runExpression: e.runExpression,
                callFunction: e.callFunction,
            };
        },
    },
};

var _evaluator = Object.prototype.hasOwnProperty.call(_EVALUATORS, _lang) ? _EVALUATORS[_lang] : null;
if (!_evaluator) throw new Error('eval-worker.js: no auto-compute worker for language "' + _lang + '"');

importScripts('/vendor/xeus-bootstrap.js' + _suffix);
importScripts('/xeus-kernel-shared.js' + _suffix);
importScripts('/grading-shared.js' + _suffix);
importScripts('/eval-protocol-shared.js' + _suffix);
importScripts('/' + _lang + '-grading-shared.js' + _suffix);
importScripts('/' + _lang + '-eval-shared.js' + _suffix);

var _eval = self[_evaluator.shared];
var _config = _evaluator.config(_eval);
_config.label = _evaluator.label;
_config.maxWaitMs = _evaluator.maxWaitMs || _MAX_WAIT_MS;
_config.makeNonce = _eval.makeNonce;

self.ChickadeeXeusKernel.serveEvalWorker(_config);
