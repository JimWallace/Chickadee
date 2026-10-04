// Public/auto-compute-client.js
//
// Auto-compute for the pattern-family editor: run the solution on a case's
// arguments, and write the answer into the case's Expected cell.
//
// Split out of Public/pattern-family-editor.js (#1966). That file decides WHEN
// a case row is computed, from the form it owns. This file does the rest:
//   - where the call runs. A language whose seed names an in-page worker runs
//     in that worker. Every other language runs on the server, through the
//     compute-expected endpoint.
//   - the worker client: one worker at a time, requests matched to replies by
//     id, and a time limit on each request. A request that runs past its limit
//     terminates the worker, so a tight loop in a solution cannot freeze the
//     page. The next call starts a new worker and loads the solution again.
//   - how each failure is reported, and how a result lands in a cell.
// The result shape that callSolution returns and applyAutoComputeResult reads
// is therefore in one file.
//
// Loading: classic script. Needs Public/authoring-language.js
// (ChickadeeLanguage) before it, because the seed decides where a call runs.
// A <script> tag loads it before pattern-family-editor.js on both authoring
// pages (assignment-new.leaf, _assignment-edit-body.leaf).
// Exposes exactly one global: ChickadeeAutoCompute.
//
// Tested with a fake Worker in
// Tests/BrowserRunnerJSTests/auto-compute-client.test.mjs.

(function (root) {
    'use strict';

    // Hard cap on how long we wait for the solution function to return.
    // The worker is terminated on timeout, so this is a true wall-clock
    // limit and not only a catch for cooperative hangs.
    var TIMEOUT_MS = 5000;
    // Longer cap for the one-time solution-notebook load (importing
    // heavy modules, reading a CSV, etc.). It includes the kernel boot.
    // Bounded so a top-level infinite loop in a setup cell can't strand
    // auto-compute on "computing…" forever.
    var LOAD_TIMEOUT_MS = 30000;

    /// Splits a notebook into its code cells' source, skipping markdown,
    /// stripping IPython magic (`%`) and shell (`!`) lines.
    function extractSolutionCells(nb) {
        if (!nb || !Array.isArray(nb.cells)) return [];
        var out = [];
        nb.cells.forEach(function (cell) {
            if (cell.cell_type !== 'code') return;
            var src = Array.isArray(cell.source) ? cell.source.join('') : (cell.source || '');
            var lines = src.split('\n').filter(function (ln) {
                var t = ln.replace(/^\s+/, '');
                return t[0] !== '%' && t[0] !== '!';
            });
            var code = lines.join('\n');
            if (code.trim()) out.push(code);
        });
        return out;
    }

    /// Readable copy for a solution-load failure: the two sentinels the
    /// load raises, else a network or kernel failure.
    function loadFailureText(code) {
        if (code === 'no-solution') return 'no solution notebook';
        if (code === 'empty-solution') return 'solution notebook has no code';
        return 'solution notebook did not load';
    }

    /// A client for one editor.
    ///
    /// `options`:
    ///   csrfToken      — sent on the solution fetch and the server call.
    ///   urls           — `solutionNotebook()` (required for an in-page
    ///                    worker) and `computeExpected()` (optional; without
    ///                    it the server route reports itself unavailable).
    ///                    Read at call time, the same object the editor got.
    ///   timeoutMs,
    ///   loadTimeoutMs  — test seams. The editor passes neither, so it gets
    ///                    TIMEOUT_MS and LOAD_TIMEOUT_MS.
    ///
    /// Returns `{ callSolution, timeoutMs, loadTimeoutMs }`.
    function createClient(options) {
        options = options || {};
        var csrfToken = options.csrfToken || '';
        var urls = options.urls || {};
        var timeoutMs = options.timeoutMs > 0 ? options.timeoutMs : TIMEOUT_MS;
        var loadTimeoutMs = options.loadTimeoutMs > 0 ? options.loadTimeoutMs : LOAD_TIMEOUT_MS;

        var _solutionLoadedPromise = null;
        var _worker = null;
        var _nextRequestId = 1;
        var _pendingRequests = new Map();

        function getWorker() {
            if (_worker) return _worker;
            var version = (document.querySelector('meta[name="app-version"]') || {}).content || '';
            // WHICH worker comes from the language seed, not from this file.
            // It was hardcoded to the Python one, which is why auto-compute
            // could only ever be in-page for Python.
            var workerScript = ChickadeeLanguage.autoComputeWorker();
            if (!workerScript) return null;
            var workerURL = workerScript + (version ? '?v=' + encodeURIComponent(version) : '');
            _worker = new Worker(workerURL);
            _worker.addEventListener('message', function (e) {
                var data = e.data || {};
                var handler = _pendingRequests.get(data.id);
                if (handler) {
                    _pendingRequests.delete(data.id);
                    handler(data);
                }
            });
            _worker.addEventListener('error', function (e) {
                // Surface uncaught worker errors to every pending request
                // so the modal doesn't sit forever.  The next call spins
                // up a fresh worker.
                var err = (e && e.message) ? e.message : 'worker error';
                _pendingRequests.forEach(function (handler) {
                    handler({ ok: false, error: err });
                });
                _pendingRequests.clear();
                killWorker();
            });
            return _worker;
        }

        function killWorker() {
            if (_worker) {
                try { _worker.terminate(); } catch (_) {}
                _worker = null;
            }
            // The worker held the loaded solution module; the next call
            // must re-load it.
            _solutionLoadedPromise = null;
        }

        /// Sends a message to the eval worker, optionally with a
        /// wall-clock timeout.  When the timeout fires we terminate the
        /// worker (killing whatever the kernel is running, including
        /// synchronous tight loops) and reject with `__chickadee_timeout__`.
        ///
        /// Only the request that timed out is rejected then. Another request
        /// still pending on the killed worker keeps its own timer, and is
        /// rejected with the same sentinel when that timer fires.
        function workerSend(message, requestTimeoutMs) {
            return new Promise(function (resolve, reject) {
                var id = _nextRequestId++;
                var worker = getWorker();
                // Unreachable through `callSolution`, which routes to the
                // server when the language declares no in-page worker. Guarded
                // anyway so a future caller gets a rejection rather than a
                // TypeError on `worker.postMessage`.
                if (!worker) {
                    reject(new Error('This language has no in-page evaluator.'));
                    return;
                }
                var timer = null;
                if (requestTimeoutMs && requestTimeoutMs > 0) {
                    timer = setTimeout(function () {
                        _pendingRequests.delete(id);
                        killWorker();
                        reject(new Error('__chickadee_timeout__'));
                    }, requestTimeoutMs);
                }
                _pendingRequests.set(id, function (data) {
                    if (timer) { clearTimeout(timer); }
                    if (data.ok) {
                        resolve(data);
                    } else {
                        reject(new Error(data.error || 'unknown error'));
                    }
                });
                try {
                    var payload = Object.assign({ id: id }, message);
                    worker.postMessage(payload);
                } catch (err) {
                    if (timer) { clearTimeout(timer); }
                    _pendingRequests.delete(id);
                    reject(err);
                }
            });
        }

        /// Loads the solution notebook into the eval worker's kernel, cell
        /// by cell. The worker catches per-cell errors, so one failing
        /// statement doesn't stop later cells from defining their functions.
        ///
        /// Resolves to `{ cellErrors: [{ index, message }] }`.  The
        /// `cellErrors` list lets `callSolution` explain a downstream
        /// NameError ("function `foo` not defined") in terms of the
        /// earlier cell that crashed before reaching the def — pre-v0.4.130
        /// the per-cell errors were swallowed silently and a missing
        /// function gave a confusing message that didn't mention the cause.
        function ensureSolutionLoaded() {
            if (_solutionLoadedPromise) return _solutionLoadedPromise;
            _solutionLoadedPromise = fetch(urls.solutionNotebook(), {
                headers: { 'x-csrf-token': csrfToken }
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('no-solution')); })
            .then(function (nb) {
                var cells = extractSolutionCells(nb);
                if (!cells.length) return Promise.reject(new Error('empty-solution'));
                // Hard cap on the load too.  A pathological top-level
                // cell (e.g. `while True: pass` outside any function,
                // or a heavy CSV read with a bug that loops) used to
                // hang the auto-compute forever — the function-call
                // timeout never fired because we never got past load.
                // 30s is generous (legitimate heavy imports, large
                // pandas reads) while still bounded.  On timeout we
                // terminate the worker; the next attempt re-loads.
                return workerSend({
                    type: 'loadCells', cells: cells,
                    runtimeSource: ChickadeeLanguage.facts().autoComputeRuntimeSource || null
                }, loadTimeoutMs);
            })
            .then(function (data) {
                return { cellErrors: data.cellErrors || [] };
            });
            _solutionLoadedPromise.catch(function () { _solutionLoadedPromise = null; });
            return _solutionLoadedPromise;
        }

        /// Auto-compute via the SERVER, in the assignment's own language.
        ///
        /// For a language whose seed names no in-page worker (C++, Racket,
        /// Java, or no language). `PersonalizationEvaluator` on the server
        /// evaluates in every language, so this routes there rather than
        /// growing more kernels into the page.
        ///
        /// The value comes back as a LITERAL in that language (base R and Lua
        /// have no JSON to serialize with), so it is read with the same
        /// language-aware parser hand-typed values go through. A composite the
        /// parser cannot take is reported, not stored: storing a repr string
        /// would make it compare as text at grade time.
        function callSolutionOnServer(fnName, args, opts) {
            var captureStdout = !!(opts && opts.captureStdout);
            if (!urls.computeExpected) {
                return Promise.resolve({ ok: false, error: 'Auto-compute is unavailable on this page.' });
            }
            return fetch(urls.computeExpected(), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrfToken },
                body: JSON.stringify({
                    functionName: fnName, args: args, captureStdout: captureStdout
                })
            })
            .then(function (r) { return r.ok ? r.json() : Promise.reject('compute failed'); })
            .then(function (res) {
                if (res.unsupportedReason) return { ok: false, error: res.unsupportedReason };
                if (!res.ok) return { ok: false, error: res.error || 'The solution raised an error.' };
                var parsed = ChickadeeLanguage.parseValue(res.rendered);
                if (!parsed.ok || !parsed.strict) {
                    // Scalars round-trip; a language repr of a list or record
                    // does not. Say so instead of storing the text.
                    var scalar = ChickadeeLanguage.matchScalarToken(String(res.rendered).trim());
                    if (scalar) return { ok: true, value: scalar.value };
                    return {
                        ok: false,
                        error: 'Computed ' + res.rendered + ' — enter it here in JSON.'
                    };
                }
                return { ok: true, value: parsed.value };
            })
            .catch(function (e) { return { ok: false, error: String(e) }; });
        }

        /// Turns a failed auto-compute into the shape the UI reads.
        ///
        /// Every in-page kernel reaches it through the same `call` path, so an R
        /// author gets the same explanation a Python author does — including
        /// the part that matters most: when a function is missing, WHY it is
        /// missing.
        function describeCallFailure(err, cellErrors) {
            if (err && err.message === '__chickadee_timeout__') {
                return { ok: false, timedOut: true,
                         error: 'timed out after ' + (timeoutMs / 1000) + 's' };
            }
            var msg = (err && err.message)
                ? String(err.message).split('\n').filter(function (l) { return l.trim(); }).pop()
                : String(err);
            // When the function isn't found, fold the first solution-load error
            // into the message so the instructor sees *why* it never landed —
            // typical case: an earlier cell raised. R says "object '<name>' not
            // found" where Python says "not defined", so both are matched.
            var missing = msg
                && (msg.indexOf('not defined') >= 0 || msg.indexOf('not found') >= 0);
            if (missing && (cellErrors || []).length > 0) {
                var first = cellErrors[0];
                msg += ' (cell ' + (first.index + 1) + ' failed: ' + first.message + ')';
            }
            return { ok: false, error: msg || 'error' };
        }

        /// Calls `fnName(*args)` on the loaded solution and returns the
        /// result as a JSON-serialisable value, or an error summary if it
        /// throws.  When `opts.captureStdout` is set, the result is what the
        /// function printed instead of its return value (used by the
        /// `stdout_equality` pattern kind).
        ///
        /// Result shape:
        ///   { ok: true,  value: <parsed>, returnedNone: false }     // value-returning success
        ///   { ok: true,  value: null,     returnedNone: true  }     // function returned None
        ///   { ok: false, unsupported: "<reason>" }                  // non-JSON-native return type
        ///   { ok: false, error: "<msg>" }                           // exception inside the solution
        ///   { ok: false, timedOut: true, error: "..." }             // time limit exceeded
        ///   { ok: false, loadFailed: true, error: "...", detail }   // the solution did not load
        ///
        /// `returnedNone` and `unsupported` come from the worker's `call`
        /// reply. Python sends them: its call snippet in python-eval-shared.js
        /// marks a `None` return, and each return type that does not
        /// round-trip through JSON, with a `__chickadee_kind__` payload.
        function callSolution(fnName, args, opts) {
            // IN-PAGE WHEREVER A KERNEL EXISTS, and the language seed decides
            // which — not a name check here.
            //
            // This read `name !== 'python'` and sent every other language to
            // the server, which was true when the in-page evaluator was the
            // only kernel the editor could boot. It is the wrong rule for an
            // editor whose job is in-browser authoring and verification: an
            // author changing a case should see what their solution returns
            // without a server round-trip. The languages with no kernel
            // (C++, Racket) declare `serverDriver` and still route there.
            if (!ChickadeeLanguage.autoComputeWorker()) {
                return callSolutionOnServer(fnName, args, opts);
            }
            // Every in-page kernel takes the same structured request, and the
            // worker builds the snippet. Rendering arguments into a language
            // belongs in that language's module (`<language>-eval-shared.js`),
            // not here. Until #1964 the editor built the Python snippet itself.
            return ensureSolutionLoaded().then(function (loaded) {
                var cellErrors = loaded.cellErrors || [];
                return workerSend({
                    type: 'call',
                    functionName: fnName,
                    args: args,
                    captureStdout: !!(opts && opts.captureStdout),
                    runtimeSource: ChickadeeLanguage.facts().autoComputeRuntimeSource || null
                }, timeoutMs)
                .then(function (data) {
                    if (data.returnedNone) return { ok: true, value: null, returnedNone: true };
                    if (data.unsupported) return { ok: false, unsupported: data.unsupported };
                    return { ok: true, value: data.result, returnedNone: false };
                })
                .catch(function (err) {
                    // Already `{ ok: false, error }` — wrapping it again
                    // showed every R, Lua and Octave error as
                    // "[object Object]" (#1994).
                    return describeCallFailure(err, cellErrors);
                });
            }).catch(function (err) {
                // Solution-load failures (no-solution, empty-solution,
                // network, load-timeout).  These come *before* any
                // callSolution-specific error wrapping, so cellErrors
                // is not in scope.  v0.4.137: translate the
                // load-timeout sentinel into the same {timedOut: true}
                // shape the run-timeout produces, so the UI's
                // `res.timedOut` branch handles both — pre-fix the
                // load timeout leaked the literal '__chickadee_timeout__'
                // string into the Expected cell.
                if (err && err.message === '__chickadee_timeout__') {
                    return { ok: false, timedOut: true,
                             error: 'solution notebook load timed out after ' + (loadTimeoutMs / 1000) + 's' };
                }
                // The other load failures are not errors the solution raised,
                // so they carry their own copy instead of a sentinel code.
                var detail = (err && err.message) ? String(err.message) : String(err || '');
                return { ok: false, loadFailed: true, error: loadFailureText(detail), detail: detail };
            });
        }

        return {
            callSolution: callSolution,
            timeoutMs: timeoutMs,
            loadTimeoutMs: loadTimeoutMs
        };
    }

    /// Writes one auto-compute result into an Expected cell: the value, or a
    /// warning in the placeholder with the reason in the title. Module scope,
    /// with the editor's renderer, cue setter and time limits passed in `env`,
    /// so a test can drive every branch on a plain object.
    ///
    /// Every failure clears a value that auto-compute filled earlier. A
    /// placeholder is not visible behind a value, so the error would otherwise
    /// be only in the title, which a touch screen never shows (#1998). The
    /// caller has already returned for a manual value, so a value here was
    /// computed.
    function applyAutoComputeResult(cell, res, env) {
        if (res.ok && res.returnedNone) {
            // The solution function returned None.  Don't write the string
            // "null" to the cell — that used to round-trip as a literal value
            // and confuse instructors.  Instead leave it empty with a clear
            // hint, and suggest stdout_equality (which is the most common
            // reason a function returns None: it print()s instead of
            // returning).
            cell.value = '';
            cell.placeholder = '⚠ solution returned None';
            cell.title = 'The solution function returned None. Did you mean to print() and use the Stdout equality kind?';
            env.setCue(cell, 'input-attention');
            delete cell.dataset.autoComputed;
        } else if (res.ok) {
            cell.placeholder = 'e.g. underweight';
            cell.value = env.render(res.value);
            cell.dataset.autoComputed = '1';
            cell.title = 'Auto-computed from solution notebook';
            env.setCue(cell, 'input-computed');
        } else if (res.timedOut) {
            cell.value = '';
            cell.placeholder = '⚠ ' + res.error;
            // v0.4.137: distinguish load-phase timeouts (a top-level cell
            // hung — e.g. `while True: pass` outside the function under test)
            // from run-phase timeouts (the function itself hung).  Pre-fix
            // both surfaced the run-phase tooltip, which pointed instructors
            // at the wrong cell.
            // The load time includes the kernel boot, so the load title names
            // no cause and no language.
            cell.title = res.error.indexOf('notebook load') >= 0
                ? 'Loading the solution notebook ran longer than ' + (env.loadTimeoutMs / 1000) + ' seconds'
                : 'Solution call did not return within ' + (env.timeoutMs / 1000) + ' seconds. Check for an infinite loop or blocking I/O in the solution notebook.';
            env.setCue(cell, 'input-invalid');
            delete cell.dataset.autoComputed;
        } else if (res.unsupported) {
            // The solution returned a value of a type that doesn't round-trip
            // through JSON in a way the runner-side test will accept.  Show
            // the specific reason so the instructor can decide whether to
            // change the solution or type Expected manually.
            var reasonText = ({
                'coroutine':       'an async function (returned a coroutine without awaiting it)',
                'async-generator': 'an async generator',
                'generator':       'a generator',
                'set':             'a set',
                'tuple':           'a tuple',
                'bytes':           'bytes',
                'complex':         'a complex number'
            })[res.unsupported] || res.unsupported;
            cell.value = '';
            cell.placeholder = '⚠ solution returned ' + reasonText;
            cell.title = "Auto-compute can't represent " + reasonText + ". Type the Expected value manually, or change the solution to return a JSON-friendly type (str, int, float, bool, list, dict).";
            env.setCue(cell, 'input-attention');
            delete cell.dataset.autoComputed;
        } else {
            // v0.4.112: surface the failure in the cell itself (not just the
            // title tooltip) — typical user doesn't think to hover.
            // "computing…" → "⚠ <err>" is enough to flag malformed input /
            // undefined function / etc.
            cell.value = '';
            cell.placeholder = '⚠ ' + (res.error || 'auto-compute failed');
            if (!res.loadFailed) {
                cell.title = 'Solution raised: ' + res.error;
            } else if (res.detail === 'no-solution' || res.detail === 'empty-solution') {
                cell.title = 'Auto-compute runs the solution notebook';
            } else {
                cell.title = 'Load failed: ' + res.detail;
            }
            env.setCue(cell, 'input-invalid');
            delete cell.dataset.autoComputed;
        }
    }

    root.ChickadeeAutoCompute = {
        createClient: createClient,
        applyAutoComputeResult: applyAutoComputeResult,
        extractSolutionCells: extractSolutionCells,
        loadFailureText: loadFailureText,
        TIMEOUT_MS: TIMEOUT_MS,
        LOAD_TIMEOUT_MS: LOAD_TIMEOUT_MS
    };
})(typeof self !== 'undefined' ? self : globalThis);
