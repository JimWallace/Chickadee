// Public/grading-executors.js
//
// The browser runner's executors: the ScriptExecutor faces that RunnerCore's
// shared executeSuites loop drives in the browser.
//
//   - RoutingExecutor: one face over the language substrates. It classifies
//     each script with RunnerCore and sends it to the substrate for that kind.
//   - GradingWorkerExecutor: a xeus kernel in a Web Worker, so a run-away can
//     be killed.
//   - UnavailableExecutor: stands in for a substrate this environment cannot
//     provide.
//
// Split out of Public/browser-runner.js (#1965). That file keeps the page
// wiring, the submission path and the notebook extraction. It also keeps the
// GENERATED language tables (scripts/generate-js-constants.sh writes them and
// the Swift drift tests read them there), so the router is built over the two
// tables it needs by `makeGradingExecutors`, which the runner calls once.
//
// Loading: classic script, before browser-runner.js on the notebook page
// (_notebook-body.leaf). No worker imports it. Exposes exactly one global,
// ChickadeeGradingExecutors.
//
// Tested through the runner's test hooks in
// Tests/BrowserRunnerJSTests/browser-runner.test.mjs, which loads this file
// before the runner as the page does.

(function (root) {
    'use strict';
    // Decode a file-map value (UTF-8 string or byte array) to text — used to
    // classify a script on the main thread without round-tripping the worker.
    function fileAsText(value) {
        if (typeof value === 'string') return value;
        try { return new TextDecoder().decode(value instanceof Uint8Array ? value : new Uint8Array(value)); }
        catch (_) { return ''; }
    }


    // Map a RunnerCore interpreter raw value to how the browser dispatches it.
    // A kernel language's interpreter maps to its substrate kind through
    // `interpreterKinds`, the GENERATED INTERPRETER_KINDS table in
    // browser-runner.js (#2388). Shell and the other interpreters have no
    // browser substrate, so RoutingExecutor.run gives them a precise "not
    // here" message.
    function interpreterToKind(interp, interpreterKinds) {
        if (Object.prototype.hasOwnProperty.call(interpreterKinds, interp)) return interpreterKinds[interp];
        if (interp === 'sh' || interp === 'bash' || interp === 'zsh') return 'shell';
        return 'unsupported';  // ruby / perl / node / php / unknown
    }

    // Lowercased file extension of a script name, or '' when there is none —
    // a bare name like `beats` or a leading-dot dotfile. Mirrors the semantics
    // of URL.pathExtension on the worker side.
    function scriptExtension(name) {
        const base = name.slice(name.lastIndexOf('/') + 1);
        const dot  = base.lastIndexOf('.');
        return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
    }

    // A synthetic raw output for a substrate error: exit 2 → RunnerCore maps to
    // `error`, with `message` as the (last-line) shortResult.
    function rawError(message) {
        return { exitCode: 2, stdout: message, stderr: '', executionTimeMs: 0, timedOut: false };
    }

    /** Converts any thrown value to a human-readable string. */
    function toMessage(e) {
        if (e instanceof Error && e.message) return e.message;
        const s = String(e);
        return (s && s !== '[object Object]') ? s : 'unknown error';
    }

    // -------------------------------------------------------------------------
    // Executor selection (one Web Worker per substrate, no main-thread path)
    // -------------------------------------------------------------------------

    // A grading worker can be used when the environment exposes the Worker
    // constructor OR a test/embed override factory is present. The factory seam
    // lets the Node harness inject a fake Worker (no real kernel); production
    // spawns the substrate's worker with the page's ?v= cache-buster so the
    // worker (and the grading-shared.js it importScripts with the same query)
    // pin to this release's bytes.
    function gradingWorkerFactory(scriptPath) {
        const override = globalThis.__CHICKADEE_GRADING_WORKER_FACTORY__
            || (typeof window !== 'undefined' ? window.__CHICKADEE_GRADING_WORKER_FACTORY__ : undefined);
        if (typeof override === 'function') return () => override(scriptPath);
        if (typeof Worker !== 'undefined') {
            return () => {
                const meta = document.querySelector('meta[name="app-version"]');
                const v = meta && meta.content ? '?v=' + encodeURIComponent(meta.content) : '';
                return new Worker(scriptPath + v);
            };
        }
        return null;
    }

    // Stands in for a substrate this environment cannot provide. ensureReady
    // throws so the caller fails over; run() is only reachable if the caller
    // ignored that and is answered with the same explanation.
    class UnavailableExecutor {
        constructor(reason) { this.reason = reason; }
        scriptExists() { return false; }
        ensureReady() { return Promise.reject(new Error(this.reason)); }
        run() { return Promise.resolve(rawError(this.reason)); }
        dispose() { return Promise.resolve(); }
    }


    // -------------------------------------------------------------------------
    // GradingWorkerExecutor — a xeus kernel in a Web Worker, so run-aways can be
    // killed.
    //
    // Holds the file map + seed and lazily spawns a grading worker (via the
    // injectable factory), sending it `init`. Each run posts `{type:'run', …}`
    // and races the reply against a real setTimeout. Classification is decided
    // upstream, on the MAIN thread, by RoutingExecutor (so a shell or
    // unsupported script never touches a worker). A script that blows the
    // timeout is killed with Worker.terminate(). The next run detects the dead
    // worker and spawns + re-inits a fresh one — re-sending the same file map +
    // seed — before proceeding. Worker.terminate() is the only kill path that
    // works against a synchronous CPU-bound loop.
    // -------------------------------------------------------------------------

    // Bounded init: how long to wait for a grading worker to finish booting its
    // kernel + env-config before declaring it wedged, terminating it, and
    // retrying once on a fresh worker. The init path used to be UNBOUNDED —
    // unlike run(), which races a timer — so a runtime boot that never completed
    // (first observed when the editor booted a SECOND runtime beside the grader
    // under cross-origin isolation) hung the whole grade forever, with no
    // telemetry, since the per-test timer only covers the 'run' message. A real
    // cold init is seconds, so a generous default never trips a healthy boot; it
    // only converts an infinite hang into a bounded, observable, self-healing
    // failure. Overridable for tests via __CHICKADEE_GRADING_INIT_TIMEOUT_MS__.
    const GRADING_INIT_TIMEOUT_MS =
        (typeof globalThis !== 'undefined' && Number(globalThis.__CHICKADEE_GRADING_INIT_TIMEOUT_MS__) > 0)
            ? Number(globalThis.__CHICKADEE_GRADING_INIT_TIMEOUT_MS__)
            : 120000;

    // The telemetry detail of a worker breadcrumb: its timing and, for an
    // on-demand install, which packages it installed (#2387).
    function phaseDetail(msg) {
        const parts = [];
        if (msg.ms != null) parts.push('ms=' + msg.ms);
        if (msg.packages) parts.push('packages=' + msg.packages);
        return parts.length > 0 ? parts.join(';') : undefined;
    }

    class GradingWorkerExecutor {
        constructor(files, assignmentSeed, runnerCore, factory, reportPhase, label) {
            this.files = files;
            this.assignmentSeed = assignmentSeed ?? null;
            this.runnerCore = runnerCore;
            this.factory = factory;
            // Which substrate this instance drives (a display label such as
            // 'Python' or 'R') — used only in error text and telemetry, so a
            // failed init says which runtime failed. The protocol and lifecycle
            // are identical for every substrate.
            this.label = label || 'Python';
            // Submit-phase breadcrumb sink (student submit path only). Undefined
            // on the instructor-validation path, so init telemetry stays silent
            // there, matching the existing reportPhase scoping.
            this.reportPhase = (typeof reportPhase === 'function') ? reportPhase : function () {};
            this.worker = null;
            this._initPromise = null;
            this._nextID = 1;
            this._pending = new Map();  // id -> { resolve, reject }
            // Test-observable counters: how many workers we spawned and how many
            // we terminated (a fresh spawn after a timeout proves the kill path).
            this.spawnCount = 0;
            this.terminateCount = 0;
        }

        // Forward a diagnostic breadcrumb to the submit-phase telemetry. Best
        // effort: never let telemetry break grading.
        _report(phase, detail) {
            try { this.reportPhase(phase, detail); } catch (_) { /* telemetry is best-effort */ }
        }

        scriptExists(name) {
            return Object.prototype.hasOwnProperty.call(this.files, name);
        }

        _spawn() {
            const worker = this.factory();
            this.spawnCount += 1;
            worker.onmessage = (e) => {
                const msg = (e && e.data) || {};
                // Diagnostic breadcrumbs (no `id`) emitted from inside the worker
                // during init — forward to submit-phase telemetry so an init hang
                // is localizable to the kernel-boot vs env-config step. Never
                // grading state; ignored if telemetry is unwired.
                if (msg.type === 'phase') {
                    this._report(msg.phase, phaseDetail(msg));
                    return;
                }
                const entry = this._pending.get(msg.id);
                if (!entry) return;
                this._pending.delete(msg.id);
                entry.resolve(msg);
            };
            worker.onerror = (err) => {
                // A hard worker error rejects every in-flight call; the next run
                // rebuilds. (A worker script that fails to load surfaces here.)
                const reason = (err && (err.message || err.filename)) || 'grading worker error';
                for (const [, entry] of this._pending) entry.reject(new Error(String(reason)));
                this._pending.clear();
                this._killWorker();
            };
            this.worker = worker;
            return worker;
        }

        // Terminate the current worker process and reject its in-flight calls,
        // but LEAVE _initPromise intact — used by the init retry loop, which owns
        // and manages _initPromise across attempts itself.
        _terminateWorker() {
            if (this.worker) {
                try { this.worker.terminate(); } catch (_) { /* best-effort */ }
                this.terminateCount += 1;
                this.worker = null;
            }
            // Reject any still-pending calls so they don't hang forever.
            for (const [, entry] of this._pending) entry.reject(new Error('grading worker terminated'));
            this._pending.clear();
        }

        _killWorker() {
            this._terminateWorker();
            // Drop the init cache so the NEXT run rebuilds a fresh worker.
            this._initPromise = null;
        }

        _post(message) {
            const id = this._nextID++;
            return new Promise((resolve, reject) => {
                this._pending.set(id, { resolve, reject });
                try {
                    this.worker.postMessage(Object.assign({ id }, message));
                } catch (e) {
                    this._pending.delete(id);
                    reject(e);
                }
            });
        }

        // Post a message and race the reply against a REAL timer. Resolves to
        // { __timedOut: true } if the worker doesn't answer within timeoutMs; the
        // timer is always cleared. Used for both init (bounded) and run (per-test
        // limit) so neither path can hang the grade indefinitely.
        _postWithTimeout(message, timeoutMs) {
            let timer = null;
            const timeoutPromise = new Promise((resolve) => {
                timer = setTimeout(() => resolve({ __timedOut: true }), timeoutMs);
            });
            return Promise.race([this._post(message), timeoutPromise])
                .finally(() => { if (timer !== null) clearTimeout(timer); });
        }

        // Spawn (if needed) and init the worker with the file map + seed. Cached
        // so concurrent/repeated runs share one init; cleared by _killWorker so
        // the NEXT run after a terminate rebuilds from scratch.
        _ensureWorker() {
            if (this._initPromise) return this._initPromise;
            const p = this._initWithRetry();
            this._initPromise = p;
            // On ultimate failure, drop the cache so a later run can try fresh.
            p.catch(() => { if (this._initPromise === p) this._initPromise = null; });
            return p;
        }

        // Init the worker, bounded by GRADING_INIT_TIMEOUT_MS and retried once on
        // a fresh worker. A wedged kernel boot / env-config (e.g. two wasm runtimes
        // contending at boot under cross-origin isolation) terminates + respawns
        // instead of hanging the whole grade forever; a second failure surfaces
        // as a clear error (matching the old throw-on-init-failure contract),
        // never an infinite hang. Each attempt is breadcrumbed so a future hang
        // is visible server-side via the keepalive submit-phase telemetry.
        async _initWithRetry() {
            const attempts = 2;
            let lastErr = null;
            for (let attempt = 1; attempt <= attempts; attempt++) {
                const startMs = Date.now();
                this._report('grading_init_start', 'attempt=' + attempt);
                this._spawn();
                try {
                    const reply = await this._postWithTimeout(
                        { type: 'init', files: this.files, seed: this.assignmentSeed },
                        GRADING_INIT_TIMEOUT_MS);
                    if (reply && reply.__timedOut) {
                        throw new Error('grading worker init timed out after ' + GRADING_INIT_TIMEOUT_MS + 'ms');
                    }
                    if (!reply || !reply.ok) {
                        throw new Error(`Failed to configure ${this.label} environment: `
                            + ((reply && reply.error) || 'grading worker init failed'));
                    }
                    this._report('grading_init_done', 'attempt=' + attempt + ';ms=' + (Date.now() - startMs));
                    return;  // success — worker is live, _initPromise stays cached
                } catch (e) {
                    lastErr = e;
                    // Drop the wedged/failed worker but keep _initPromise (this
                    // loop owns it); a fresh worker is spawned on the next attempt.
                    this._terminateWorker();
                    this._report('grading_init_failed', 'attempt=' + attempt + ';' + toMessage(e));
                }
            }
            throw lastErr || new Error('grading worker init failed');
        }

        async run(name, limitSeconds) {
            // Classification and substrate selection happen upstream in
            // RoutingExecutor, which is what decides that this instance is the
            // right one for this script. All that is left here is the existence
            // check, kept so a direct caller still gets the worker's raw-error
            // shape rather than a rejected postMessage.
            if (!this.scriptExists(name)) {
                return rawError(`Script not found: ${name}`);
            }

            const startMs = Date.now();
            await this._ensureWorker();

            // Race the worker reply against a REAL timer. Because the worker runs
            // the kernel on its own thread, the timer always fires even when
            // student code is in a synchronous CPU-bound loop — so terminate()
            // can kill it.
            const reply = await this._postWithTimeout(
                { type: 'run', script: name, limit: limitSeconds }, limitSeconds * 1000);

            if (reply && reply.__timedOut) {
                // Kill the run-away worker; the next run rebuilds a fresh one.
                this._killWorker();
                return { exitCode: -1, stdout: '', stderr: '', executionTimeMs: Date.now() - startMs, timedOut: true };
            }
            if (!reply || !reply.ok || !reply.result) {
                // A worker-side failure → surface as an error outcome rather than
                // throwing, matching the worker's exit-2 substrate-error path.
                this._killWorker();
                return rawError(`${this.label} grading worker failed: `
                    + ((reply && reply.error) || 'unknown error'));
            }
            const r = reply.result;
            return {
                exitCode: r.exitCode,
                stdout: r.stdout || '',
                stderr: r.stderr || '',
                executionTimeMs: Date.now() - startMs,
                timedOut: false,
            };
        }

        // Eagerly spawn + init the grading worker so a wedged or trapping kernel
        // init rejects HERE (for the caller to fail over) instead of being
        // swallowed into per-script `error` outcomes by the wasm run() catch.
        // Idempotent: shares the cached _ensureWorker() init the run() path uses.
        ensureReady() {
            return this._ensureWorker();
        }

        async dispose() {
            // Terminate the worker so the kernel's memory is reclaimed. This counts
            // as a terminate, but a fresh run() would spawn a new worker anyway.
            if (this.worker) {
                try { this.worker.terminate(); } catch (_) { /* best-effort */ }
                this.terminateCount += 1;
                this.worker = null;
            }
            this._initPromise = null;
            this._pending.clear();
        }
    }

    // -------------------------------------------------------------------------
    // The router, built over the generated tables
    // -------------------------------------------------------------------------

    /// The executor classes bound to the runner's generated tables.
    ///
    /// `tables.workerScripts` is GRADING_WORKER_SCRIPTS (substrate kind to the
    /// worker script that grades it) and `tables.languageLabels` is
    /// LANGUAGE_LABELS (kind to display name). The two classes that do not
    /// read a table are returned unchanged, so a caller gets the whole set from
    /// one call.
    function makeGradingExecutors(tables) {
        const GRADING_WORKER_SCRIPTS = tables.workerScripts;
        const LANGUAGE_LABELS = tables.languageLabels;
        const INTERPRETER_KINDS = tables.interpreterKinds;

        function makeExecutor(files, assignmentSeed, runnerCore, reportPhase, suites, assignmentLanguage) {
            return new RoutingExecutor(
                files, assignmentSeed, runnerCore, reportPhase, suites, assignmentLanguage);
        }

        // -------------------------------------------------------------------------
        // RoutingExecutor — one ScriptExecutor face over the language substrates.
        //
        // RunnerCore's shared executeSuites loop asks for exactly two things:
        // "does this script exist?" and "run it". Which interpreter that means is a
        // browser concern, so it is decided here, per script, using the SAME
        // RunnerCore classification (extension → shebang → content sniff) the
        // native worker uses to pick a subprocess command.
        //
        // Substrates are created lazily and — importantly — only STARTED for kinds
        // the assignment actually contains. ensureReady() classifies the manifest's
        // scripts up front, so an R lab never boots the Python kernel and a Python
        // lab never fetches the 74 MB R environment. Before #1271 there was only one
        // substrate and this question could not arise.
        // -------------------------------------------------------------------------

        class RoutingExecutor {
            constructor(files, assignmentSeed, runnerCore, reportPhase, suites, assignmentLanguage) {
                this.files = files;
                this.assignmentSeed = assignmentSeed ?? null;
                this.runnerCore = runnerCore;
                this.reportPhase = reportPhase;
                this.suites = Array.isArray(suites) ? suites : [];
                // The language the assignment DECLARES, or null when the server did
                // not say. Null is not Python — see ensureReady.
                this.assignmentLanguage = assignmentLanguage ?? null;
                // kind -> executor, created on first use. Was four named slots.
                this.executors = new Map();
            }

            scriptExists(name) {
                return Object.prototype.hasOwnProperty.call(this.files, name);
            }

            kindOf(name) {
                const src = this.scriptExists(name) ? fileAsText(this.files[name]) : '';
                return interpreterToKind(this.runnerCore.classifyScript(name, src), INTERPRETER_KINDS);
            }

            // The distinct substrate kinds this assignment's manifest actually
            // needs — the basis for booting one runtime instead of both.
            requiredKinds() {
                const kinds = new Set();
                for (const suite of this.suites) {
                    const name = suite && suite.script;
                    if (!name || !this.scriptExists(name)) continue;
                    kinds.add(this.kindOf(name));
                }
                return kinds;
            }

            // ONE lazy factory for every kernel language, from the generated
            // GRADING_WORKER_SCRIPTS table.
            //
            // This was four near-identical methods — pythonExecutor, rExecutor,
            // luaExecutor, octaveExecutor — differing only in a worker path and a
            // display label, plus four `this.<lang> = null` slots, a four-arm
            // executorForKind and a four-name dispose list. Thirteen places to
            // remember for a seventh kernel language, none of which the Swift side
            // could see. The table is generated from the descriptor now, so a
            // seventh language appears here the day its literal does.
            //
            // Every substrate is a Web Worker running a vendored xeus kernel and
            // they all speak the same init/run protocol, so GradingWorkerExecutor
            // drives any of them without knowing which it has.
            //
            // There is no main-thread fallback. The old one existed only because
            // Pyodide can run on the main thread, and it carried a real hazard: a
            // synchronous CPU-bound loop in student code never yields, so the
            // per-test timer never fires and the tab freezes with the submission
            // lost. Worker.terminate() is the only kill path that works, and a
            // xeus kernel cannot boot outside a worker anyway (it needs
            // importScripts). A Worker-less browser therefore fails the grade over
            // to the native worker: slower, and correct — which is why the
            // unavailable case is an executor whose ensureReady throws rather than
            // one that records every test as an error.
            executorForKind(kind) {
                const script = GRADING_WORKER_SCRIPTS[kind];
                if (!script) return null;
                const existing = this.executors.get(kind);
                if (existing) return existing;
                const factory = gradingWorkerFactory(script);
                const label = LANGUAGE_LABELS[kind] || kind;
                const executor = factory
                    ? new GradingWorkerExecutor(
                        this.files, this.assignmentSeed, this.runnerCore, factory,
                        this.reportPhase, label)
                    : new UnavailableExecutor(
                        label + ' grading needs Web Worker support, '
                        + 'which this browser did not provide');
                this.executors.set(kind, executor);
                return executor;
            }

            async ensureReady() {
                // BOOT THE ASSIGNMENT'S OWN SUBSTRATE, AND ONLY THAT ONE.
                //
                // An assignment is written in one language and declares it. That
                // declaration is the answer to "which runtime must be working for
                // this grade to mean anything", so it is the only thing booted here
                // — and its failure aborts the grade, which is what routes the
                // submission to the native worker instead of posting an all-`error`
                // collection as a real 0 (see the ensureReady probe in runScripts).
                //
                // A script of some OTHER kind is not this function's problem. It
                // still runs: `GradingWorkerExecutor.run` boots its worker on first
                // use, and if that fails it returns an error outcome for that
                // script alone. The author handles it, exactly as they would a test
                // that fails for any other reason.
                //
                // WHAT THIS REPLACED. A `PRIMARY_KIND = 'python'` constant, with
                // every other substrate's boot failure swallowed whenever Python
                // was present. On an R assignment carrying one stray `.py`, that
                // made R's boot the swallowed one — so every R test posted a real
                // zero while the incidental file got the protection. The constant
                // was the last place the browser assumed a language instead of
                // reading the one the assignment declares.
                const declared = this.assignmentLanguage;
                const kinds = this.requiredKinds();

                // No declaration reaching us — an older server, or a seed fetch that
                // failed — is NOT treated as Python. Every present substrate is
                // required instead, which is the conservative reading: a boot
                // failure fails the grade over rather than scoring zeros. Guessing
                // a language here is the bug class this whole change removes.
                if (declared === null) {
                    const boots = [];
                    for (const kind of kinds) {
                        const executor = this.executorForKind(kind);
                        if (executor) boots.push(executor.ensureReady());
                    }
                    await Promise.all(boots);
                    return;
                }

                // Declared a language this assignment's suite does not actually use
                // (or an upload-only one, which has no kernel and never reaches a
                // browser): nothing to boot. Any script present still self-boots and
                // reports its own error.
                if (!kinds.has(declared)) return;
                const executor = this.executorForKind(declared);
                if (!executor) return;
                // REQUIRED: a rejection here propagates to the runScripts probe and
                // fails the submission over to the native worker.
                await executor.ensureReady();
            }

            async run(name, limitSeconds) {
                if (!this.scriptExists(name)) return rawError(`Script not found: ${name}`);
                const kind = this.kindOf(name);
                const executor = this.executorForKind(kind);
                if (executor) return executor.run(name, limitSeconds);
                if (kind === 'shell') return rawError('Shell scripts cannot run in the browser runner');
                const ext = scriptExtension(name);
                return rawError(`Unsupported test script type: ${ext ? '.' + ext : name}`);
            }

            async dispose() {
                // Every executor that was actually created, rather than a
                // hand-written list of four that a seventh language would silently
                // leak past.
                for (const executor of this.executors.values()) {
                    try { await executor.dispose(); } catch (_) { /* best-effort */ }
                }
            }
        }

        return { RoutingExecutor, UnavailableExecutor, GradingWorkerExecutor, makeExecutor };
    }

    root.ChickadeeGradingExecutors = Object.freeze({
        makeGradingExecutors,
        gradingWorkerFactory,
        fileAsText,
        interpreterToKind,
        phaseDetail,
        scriptExtension,
        rawError,
        toMessage,
        GRADING_INIT_TIMEOUT_MS,
    });

})(typeof self !== 'undefined' ? self : this);
