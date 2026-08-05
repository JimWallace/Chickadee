// Public/browser-runner.js
//
// Chickadee browser-side WASM runner for labs (gradingMode: "browser").
//
// Submit-triggered (not polling): notebook.js calls window.BrowserRunner.runAndSubmit()
// when the student clicks Submit.  Tests run locally in Pyodide; the notebook
// bytes and TestOutcomeCollection are submitted to the server in one atomic call.
//
// Workflow:
//   1. Fetch test setup zip from /api/v1/browser-runner/testsetups/:id/download
//   2. Unpack zip into the kernel's in-memory filesystem
//   3. Write the test_runtime helper libraries
//   4. Write notebook bytes and extract code cells to .py (equiv. of nb_to_py.py)
//   5. Run each test script on its kernel; capture stdout/stderr
//   6. POST notebook bytes + TestOutcomeCollection to /api/v1/submissions/browser-result
//
// Only active for gradingMode="browser" pages (guard at top of IIFE).
//
// Two substrates, picked per script by RunnerCore's shared classification:
//   .py → the vendored xeus-python kernel, via /python-grading-worker.js
//   .R  → the vendored xeus-r kernel, via /r-grading-worker.js
// Both are Web Workers running a xeus kernel from the SAME environment the
// notebook editor boots, so "it ran in the editor" implies "it grades here".
// Only the substrates an assignment actually needs are booted, so an R lab
// never pays for loading Pyodide (and vice versa).  Shell scripts (.sh) are not
// supported in the browser environment on either substrate.

(function () {
    'use strict';

    const scriptEl    = document.currentScript;
    const gradingMode = scriptEl ? scriptEl.dataset.gradingMode : null;

    // Only expose browser runner for browser-graded assignments.
    if (gradingMode !== 'browser') return;

    const statusEl = document.getElementById('browser-runner-status');
    if (statusEl) statusEl.hidden = false;

    // Grading semantics shared with the grading worker — the Python snippets,
    // exit-code derivation, MEMFS writer, and package preloader come from
    // Public/grading-shared.js (a <script> tag before this file on the
    // notebook page), so the worker grader and this main-thread fallback
    // cannot drift.  Throws loudly here if the tag is missing.
    // The one piece of grading-shared.js this file still needs: the exit-code
    // mapping, used nowhere here directly but re-exported for the tests that pin
    // it. Everything else in that module is consumed inside the grading workers.
    const { deriveExitCode } = ChickadeeGradingShared;

    // R grading semantics — the per-script wrapper and the per-student inputs
    // file, shared with /r-grading-worker.js the same way the Python snippets
    // are shared with /r-grading-worker.js.  Loaded by a <script> tag alongside
    // grading-shared.js (see notebook.leaf).
    const { personalizationInputsSourceR } = ChickadeeRGradingShared;

    // Kernelspec names that mark an R notebook. The browser cannot import
    // Swift, so this is a GENERATED copy of AssignmentLanguage.rKernelNames
    // (Sources/Core/AssignmentLanguage.swift), written by
    // scripts/generate-js-constants.sh — edit the Swift set and re-run that
    // script, never this line. CI (format-lint) fails if the two drift.
    // CHICKADEE_GENERATED:R_KERNEL_NAMES:BEGIN
    const R_KERNEL_NAMES = ['ir', 'r', 'webr', 'xr'];
    // CHICKADEE_GENERATED:R_KERNEL_NAMES:END

    // -------------------------------------------------------------------------
    // Public API — called by notebook.js on Submit
    // -------------------------------------------------------------------------

    window.BrowserRunner = { runAndSubmit, runScripts, groupBySection };

    /**
     * Run all test scripts against the student's notebook and submit results.
     *
     * @param {Uint8Array} notebookBytes  Raw bytes of the student's .ipynb file.
     * @param {string}     setupID        The test setup ID for this assignment.
     * @returns {{ outcomes: object[], response: object, sections: object[], sectionIDs: (?string)[] }}
     */
    // Fire-and-forget submit-phase breadcrumb for diagnosing "the page froze
    // during submission". Sent with keepalive so the browser hands it to the
    // network layer immediately — a breadcrumb emitted *before* a phase reaches
    // the server even if that phase then blocks the main thread or the page
    // unloads, so we can see how far a submit got when grading hangs (a hang
    // produces no exception and no result POST, so it is otherwise invisible to
    // the server). Best-effort: never blocks, never throws. Only emitted on the
    // student submit path — runAndSubmit passes `reportPhase` into runScripts;
    // instructor validation calls runScripts without it, so it stays silent.
    function recordSubmitPhase(phase, setupID, detail, isError) {
        try {
            const startMs = window.__ckSubmitStartMs || Date.now();
            const parts = ['elapsed_ms=' + (Date.now() - startMs)];
            if (detail) parts.push(String(detail).slice(0, 200));
            const body = {
                kind: isError ? 'submit_error' : 'submit_phase',
                source: String(phase).slice(0, 64),
                message: parts.join(';'),
            };
            if (setupID) body.testSetupID = setupID;
            // Page-build version (the `app-version` meta), so submit breadcrumbs
            // are attributable to a build like the editor diagnostics. Best-effort.
            try {
                const m = document.querySelector('meta[name="app-version"]');
                if (m && m.content) body.appVersion = String(m.content).slice(0, 32);
            } catch (_) { /* meta absent — fine */ }
            let csrf = '';
            try { csrf = ChickadeeUI.getCsrfToken(); } catch (_) { /* no token */ }
            fetch('/api/v1/client-diagnostics', {
                method: 'POST',
                credentials: 'same-origin',
                keepalive: true,
                headers: { 'content-type': 'application/json', 'x-csrf-token': csrf },
                body: JSON.stringify(body),
            }).catch(function () { /* telemetry is best-effort */ });
        } catch (_) { /* never let telemetry break grading */ }
    }

    async function runAndSubmit(notebookBytes, setupID) {
        window.__ckSubmitStartMs = Date.now();
        recordSubmitPhase('grading_start', setupID);
        try {
            const result = await runScripts(notebookBytes, setupID, {
                filename: 'submission.ipynb',
                reportPhase: function (phase, detail) { recordSubmitPhase(phase, setupID, detail); },
            });

            // Hide the loading-progress status bar — results are now in #nb-results.
            if (statusEl) statusEl.hidden = true;

            recordSubmitPhase('result_posting', setupID);
            const response = await postBrowserResult(notebookBytes, result.collection, setupID);
            recordSubmitPhase('result_posted', setupID);

            return {
                outcomes: result.outcomes,
                response: response,
                sections: result.sections,
                sectionIDs: result.sectionIDs,
            };
        } catch (e) {
            recordSubmitPhase('submit_failed', setupID, toMessage(e), true);
            throw e;
        }
    }

    /**
     * Bucket outcomes into display sections, mirroring the server's
     * groupOutcomesBySection (Sources/APIServer/Routes/Web/WebRoutes+Submission.swift):
     * sections in manifest order, each `outcomes[i]` placed by `sectionIDs[i]`
     * (index correlation — not a name lookup, so two families that share a case
     * label can't collapse onto one section, v0.4.105), with a trailing
     * "Ungrouped" bucket for outcomes whose section is missing or unknown.  When
     * the assignment defines no sections at all, returns a single unlabelled
     * bucket so the layout is identical to the pre-sections flat table.
     *
     * @param {object[]} outcomes
     * @param {{id: string, name: string}[]} sections
     * @param {(?string)[]} sectionIDs  Parallel to outcomes; sectionIDs[i] is the
     *   section id of the manifest entry that produced outcomes[i] (or null).
     * @returns {{ sectionName: ?string, outcomes: object[] }[]}
     */
    function groupBySection(outcomes, sections, sectionIDs) {
        const list = Array.isArray(sections) ? sections : [];
        const ids = Array.isArray(sectionIDs) ? sectionIDs : [];
        const known = new Set(list.map(s => s.id));
        const byID = new Map();
        const ungrouped = [];
        (outcomes || []).forEach((o, i) => {
            const sid = i < ids.length ? ids[i] : null;
            if (sid && known.has(sid)) {
                if (!byID.has(sid)) byID.set(sid, []);
                byID.get(sid).push(o);
            } else {
                ungrouped.push(o);
            }
        });
        const groups = [];
        for (const section of list) {
            const rows = byID.get(section.id);
            if (rows && rows.length) groups.push({ sectionName: section.name, outcomes: rows });
        }
        if (ungrouped.length) {
            groups.push({ sectionName: list.length ? 'Ungrouped' : null, outcomes: ungrouped });
        }
        if (groups.length === 0) groups.push({ sectionName: null, outcomes: [] });
        return groups;
    }

    /**
     * Run all configured test scripts against a supplied reference/student file.
     *
     * This is used by both student submissions (via runAndSubmit) and the
     * instructor validation page, where results should be shown locally without
     * creating a submission record.
     *
     * @param {Uint8Array} submissionBytes Raw bytes of the submitted solution file.
     * @param {string}     setupID         The test setup ID for this assignment.
     * @param {{filename?: string}} options
     * @returns {{ outcomes: object[], collection: object }}
     */
    async function runScripts(submissionBytes, setupID, options = {}) {
        let JSZip;
        try {
            JSZip = await loadJSZip();
        } catch (e) {
            throw new Error('Failed to load ZIP library: ' + toMessage(e));
        }

        // The shared RunnerCore wasm must load before either executor: it both
        // extracts the notebook (extractPython) and drives the suite loop
        // (runnerExecuteSuites) + classification (classifyScript). It runs on the
        // main thread regardless of which executor grades — only the *result
        // strings* of extraction flow into the worker's file map.
        const runnerCore = await loadRunnerCore();
        if (typeof globalThis.runnerExecuteSuites !== 'function') {
            throw new Error('RunnerCore wasm did not register runnerExecuteSuites');
        }
        // Submit-phase breadcrumb (student submit path only — instructor
        // validation calls runScripts without reportPhase, so it stays silent).
        // The heavy Pyodide load is now deferred into the executor (worker init
        // or main-thread _ensureReady) and is covered by the suite_started →
        // suite_done window, so a Pyodide-load hang shows up as "stuck after
        // suite_started" rather than disappearing before runtime_loaded.
        if (options.reportPhase) options.reportPhase('runtime_loaded');

        // 1. Download and unpack the test setup zip into a plain JS file map
        //    { <relativePath>: <string|Uint8Array> }. This is the canonical
        //    workspace; the chosen executor (worker or main-thread Pyodide)
        //    materializes it into its own filesystem.
        setRunnerStatus('loading', 'Fetching test setup…');
        let setupZip;
        try {
            setupZip = await fetchBytes(`/api/v1/browser-runner/testsetups/${setupID}/download`);
        } catch (e) {
            throw new Error('Failed to download test setup: ' + toMessage(e));
        }
        let zip;
        try {
            zip = await JSZip.loadAsync(setupZip);
        } catch (e) {
            throw new Error('Failed to unpack test setup zip: ' + toMessage(e));
        }

        const files = {};  // relativePath -> string | Uint8Array
        for (const [name, file] of Object.entries(zip.files)) {
            if (file.dir) continue;
            files[name] = await file.async('uint8array');
        }
        if (options.reportPhase) options.reportPhase('setup_unpacked');

        // 2. Runtime helper libraries. Both languages' helpers are written
        //    unconditionally: each is a reserved filename the OTHER language's
        //    submission scanner already skips (test_runtime.R is in
        //    test_runtime.R's own `.chickadee_reserved_files`; the .py helpers
        //    are in the Python scanner's skip set), so a spare copy cannot be
        //    mistaken for a submission. That keeps the workspace independent of
        //    detecting the assignment's language, which matters because the
        //    language is only known after the seed fetch below. The native
        //    runner writes test_runtime.R conditionally (writeRRuntimeHelper)
        //    because it builds the workspace after it has resolved the job's
        //    language; the browser has no such ordering.
        files['test_runtime.py']  = TEST_RUNTIME_PY;
        files['sitecustomize.py'] = SITECUSTOMIZE_PY;
        files['test_runtime.R']   = TEST_RUNTIME_R;

        // 3. Submitted solution bytes. Notebooks are extracted (on the main
        //    thread, via the RunnerCore wasm) to a Python/R source file; plain
        //    .py / .R files are used directly. Only the extraction *result
        //    strings* enter the map — never the wasm itself.
        const submissionFilename = safeSubmissionFilename(options.filename || 'submission.ipynb');
        files[submissionFilename] = submissionBytes;
        const lowerSubmissionName = submissionFilename.toLowerCase();
        if (lowerSubmissionName.endsWith('.ipynb')) {
            const notebookText = new TextDecoder().decode(submissionBytes);
            extractNotebookToMap(files, runnerCore, submissionFilename, notebookText);
        } else if (lowerSubmissionName.endsWith('.py') || lowerSubmissionName.endsWith('.r')) {
            files['.chickadee_student_module'] = submissionFilename;
        }

        // Personalization parity (issue #461): the per-student seed and inputs.
        // The seed sets CHICKADEE_ASSIGNMENT_SEED (matching RunnerDaemon's test
        // subprocess); the inputs become _ck_inputs.py in the workspace (matching
        // the worker writing Job.personalizedInputs). The server resolves both
        // with the SAME AssignmentSeedStore.ensureSeed / gradingInputs the worker
        // uses, so all paths share one value. A non-personalized setup (or an
        // older server) yields no seed/inputs → unset env var, no _ck_inputs.py.
        let assignmentSeed = null;
        let personalizedInputs = null;
        // The assignment's language, as the SERVER resolved it
        // (AssignmentLanguage.resolve — manifest scripts, then notebook kernel).
        // It decides only which inputs file the per-student values land in;
        // which substrate runs a given script is still decided per script by
        // RunnerCore's classification, exactly as the native worker does it.
        let assignmentLanguage = 'python';
        try {
            const seedText = await fetchText(`/api/v1/browser-runner/testsetups/${setupID}/seed`);
            const parsed = JSON.parse(seedText);
            if (parsed && typeof parsed.seed === 'string' && parsed.seed) {
                assignmentSeed = parsed.seed;
            }
            if (parsed && parsed.language === 'r') {
                assignmentLanguage = 'r';
            }
            if (parsed && parsed.personalizedInputs && typeof parsed.personalizedInputs === 'object') {
                personalizedInputs = parsed.personalizedInputs;
            }
            // Per-student dataset slices (Phase 1 datasets): overwrite the full-source
            // support file from the zip with the student's personal slice so test
            // scripts see only their rows. No-op when the response has no personalizedFiles.
            if (parsed && parsed.personalizedFiles && typeof parsed.personalizedFiles === 'object') {
                for (const [filename, content] of Object.entries(parsed.personalizedFiles)) {
                    files[filename] = content;
                }
            }
        } catch (_) {
            assignmentSeed = null;  // grade without a seed rather than failing the run
            personalizedInputs = null;
        }
        // The server already rendered each value as a literal in the
        // assignment's language, so only the wrapper differs: `_ck` dict vs
        // `.ck_inputs` list. Writing the Python file for an R assignment is
        // what the pre-#1271 browser runner did, and it left every
        // personalized R test reading an empty chickadee_inputs().
        if (personalizedInputs && Object.keys(personalizedInputs).length > 0) {
            if (assignmentLanguage === 'r') {
                files['_ck_inputs.R'] = personalizationInputsSourceR(personalizedInputs);
            } else {
                files['_ck_inputs.py'] = personalizationInputsSource(personalizedInputs);
            }
        }

        // 4. Fetch manifest from server (test.properties.json is not in the zip;
        //    the server serves it directly from the database via the manifest endpoint).
        setRunnerStatus('loading', 'Loading test configuration…');
        let manifest;
        try {
            const manifestText = await fetchText(`/api/v1/browser-runner/testsetups/${setupID}/manifest`);
            manifest = JSON.parse(manifestText);
        } catch (e) {
            throw new Error('Failed to load test configuration: ' + toMessage(e));
        }

        const timeLimitSeconds = manifest.timeLimitSeconds || 10;
        const suites = (manifest.testSuites || []).map(entry => ({
            script: entry.script || '',
            tier: entry.tier || 'public',
            displayName: (typeof entry.name === 'string' && entry.name.trim()) ? entry.name.trim() : null,
            dependsOn: Array.isArray(entry.dependsOn) ? entry.dependsOn : [],
            points: typeof entry.points === 'number' ? entry.points : 1,
        }));

        // Per-script execution time-limit overrides (script name -> seconds).
        // Resolved here, in the browser executor, NOT inside the shared
        // RunnerCore wasm `executeSuites` loop — which is the wasm-pinned shared
        // implementation and keeps receiving only the assignment default. The
        // effective limit for a script is `perEntryTimeLimit[name] ?? limit`
        // (mirrors the worker's NativeScriptExecutor.resolveTimeLimit). Only a
        // positive number counts as an override; anything else inherits the
        // assignment default.
        const perEntryTimeLimit = {};
        for (const entry of (manifest.testSuites || [])) {
            if (entry && typeof entry.script === 'string'
                && typeof entry.timeLimitSeconds === 'number' && entry.timeLimitSeconds > 0) {
                perEntryTimeLimit[entry.script] = entry.timeLimitSeconds;
            }
        }

        // Section metadata, so the inline results can be grouped per section
        // exactly like the server-rendered submission view. Kept as a parallel
        // array (never stamped onto the outcomes, which must stay the canonical
        // worker TestOutcome shape): `sectionIDPerSuite[i]` is the section of the
        // manifest entry that produces `outcomes[i]` — index correlation,
        // matching groupOutcomesBySection on the server (a name-keyed map would
        // collapse two families that share a case label — v0.4.105).
        const sections = (Array.isArray(manifest.sections) ? manifest.sections : [])
            .filter(s => s && typeof s.id === 'string')
            .map(s => ({ id: s.id, name: typeof s.name === 'string' ? s.name : '' }));
        const sectionIDPerSuite = (manifest.testSuites || []).map(entry =>
            (entry && typeof entry.sectionID === 'string' && entry.sectionID) ? entry.sectionID : null);

        // 5. Pick the executor. The Web-Worker executor is preferred: it runs
        //    Pyodide off the main thread, so a CPU-bound infinite loop in student
        //    code (which never yields to JS) can be killed via Worker.terminate()
        //    when the per-test timeout fires — something the main-thread
        //    Promise.race fallback cannot do (the timer never gets a turn). The
        //    fallback path is preserved for environments with no Worker (and for
        //    the Node test harness, which has neither Worker nor a factory
        //    override, so it deterministically exercises the fallback).
        const executor = makeExecutor(
            files, assignmentSeed, runnerCore, options.reportPhase, suites);
        try {
            const scriptExists = (name) => executor.scriptExists(name);
            // Apply the per-script override before handing the limit to the
            // executor. `limit` is the assignment default the wasm loop passes;
            // a per-entry override (when present) wins for that one script.
            const runScript    = (name, limit) => executor.run(name, perEntryTimeLimit[name] ?? limit);

            // Shared RunnerCore (wasm): the SAME Swift `executeSuites` loop the
            // native worker runs. Dependency gating, the "Skipped: prerequisite…"
            // messages, missing-script handling, and output interpretation (exit
            // code → status, JSON-footer parsing, longResult assembly) all live
            // in RunnerCore. The executor supplies only the one substrate-specific
            // operation: run a script and report its RAW output (exit code +
            // stdout/stderr), which RunnerCore interprets byte-for-byte the way
            // the worker does. No grading logic or interpretation remains in JS.
            if (options.reportPhase) options.reportPhase('suite_started', 'tests=' + suites.length);

            // Probe the grading runtime BEFORE the shared executeSuites loop. If
            // Pyodide can't initialize at all — e.g. the Pyodide-3.14 WebKit
            // `call_indirect to a null table entry` trap that bricks grading on
            // some Safari/iOS builds — abort the whole grade by THROWING here, so
            // submitBrowserNotebook's catch (notebook.js) fails the submission
            // over to server-side grading (/submissions/browser-failover → the
            // native worker backstop). Without this probe the failure is invisible
            // to the caller: the shared RunnerCore wasm catches each rejected
            // run() and returns an exit-2 `error` ScriptOutput
            // (wasm/Sources/RunnerWasm/main.swift, "browser executor: script run
            // rejected"), so executeSuites COMPLETES with an all-`error`
            // collection that runAndSubmit then posts as a real 0% result — the
            // failover never fires and the student is recorded a 0. A per-script
            // error after a HEALTHY init still flows through as a normal error
            // outcome, unchanged — only a substrate that can't start fails over.
            try {
                await executor.ensureReady();
            } catch (e) {
                throw new Error('Browser grading runtime failed to initialize: ' + toMessage(e));
            }

            const outcomes = await globalThis.runnerExecuteSuites(
                suites, timeLimitSeconds, 1, scriptExists, runScript);
            if (options.reportPhase) options.reportPhase('suite_done', 'n=' + outcomes.length);

            // 6. Build collection. The caller decides whether to submit it.
            // `outcomes` stays the canonical worker TestOutcome shape — section
            // info rides alongside in a parallel array, never on the outcome
            // objects, so the posted collection is byte-identical to the worker's.
            const collection = buildCollection(setupID, outcomes);
            return { outcomes, collection, sections, sectionIDs: sectionIDPerSuite };
        } finally {
            try { await executor.dispose(); } catch (_) { /* best-effort */ }
        }
    }

    // -------------------------------------------------------------------------
    // Executor selection (Web-Worker preferred, main-thread Pyodide fallback)
    // -------------------------------------------------------------------------

    // A grading worker can be used when the environment exposes the Worker
    // constructor OR a test/embed override factory is present. The factory seam
    // lets the Node harness inject a fake Worker (no real Pyodide); production
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

    function makeExecutor(files, assignmentSeed, runnerCore, reportPhase, suites) {
        return new RoutingExecutor(files, assignmentSeed, runnerCore, reportPhase, suites);
    }

    // -------------------------------------------------------------------------
    // RoutingExecutor — one ScriptExecutor face over two substrates.
    //
    // RunnerCore's shared executeSuites loop asks for exactly two things:
    // "does this script exist?" and "run it". Which interpreter that means is a
    // browser concern, so it is decided here, per script, using the SAME
    // RunnerCore classification (extension → shebang → content sniff) the
    // native worker uses to pick a subprocess command.
    //
    // Substrates are created lazily and — importantly — only STARTED for kinds
    // the assignment actually contains. ensureReady() classifies the manifest's
    // scripts up front, so an R lab never downloads and boots Pyodide, and a
    // Python lab never fetches the 52 MB R environment. Before #1271 there was
    // only one substrate and this question could not arise.
    // -------------------------------------------------------------------------

    class RoutingExecutor {
        constructor(files, assignmentSeed, runnerCore, reportPhase, suites) {
            this.files = files;
            this.assignmentSeed = assignmentSeed ?? null;
            this.runnerCore = runnerCore;
            this.reportPhase = reportPhase;
            this.suites = Array.isArray(suites) ? suites : [];
            this.python = null;
            this.r = null;
        }

        scriptExists(name) {
            return Object.prototype.hasOwnProperty.call(this.files, name);
        }

        kindOf(name) {
            const src = this.scriptExists(name) ? fileAsText(this.files[name]) : '';
            return interpreterToKind(this.runnerCore.classifyScript(name, src));
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

        // Both substrates are Web Workers running a vendored xeus kernel, and
        // both speak the same init/run protocol, so GradingWorkerExecutor drives
        // either without knowing which it has — the only difference is the
        // script it spawns.
        //
        // There is no main-thread fallback any more. The old one existed only
        // because Pyodide can run on the main thread, and it carried a real
        // hazard: a synchronous CPU-bound loop in student code never yields, so
        // the per-test timer never fires and the tab freezes with the submission
        // lost. Worker.terminate() is the only kill path that works, and a
        // kernel cannot be booted outside a worker anyway (it needs
        // importScripts). A Worker-less browser therefore fails the grade over
        // to the native worker: slower, and correct.
        pythonExecutor() {
            if (!this.python) {
                const factory = gradingWorkerFactory('/python-grading-worker.js');
                this.python = factory
                    ? new GradingWorkerExecutor(
                        this.files, this.assignmentSeed, this.runnerCore, factory,
                        this.reportPhase, 'Python')
                    : new UnavailableExecutor(
                        'Browser grading needs Web Worker support, '
                        + 'which this browser did not provide');
            }
            return this.python;
        }

        // The R substrate is worker-only: booting the xeus-r kernel needs
        // importScripts, which exists only inside a worker. There is no
        // main-thread fallback to degrade to, so a Worker-less environment gets
        // an executor whose ensureReady throws — which routes the whole grade to
        // the server-side failover rather than recording every R test as an
        // error. (Python keeps its main-thread fallback; an assignment is one
        // language, so the two cases never collide in practice.)
        rExecutor() {
            if (!this.r) {
                const factory = gradingWorkerFactory('/r-grading-worker.js');
                this.r = factory
                    ? new GradingWorkerExecutor(
                        this.files, this.assignmentSeed, this.runnerCore, factory, this.reportPhase,
                        'R')
                    : new UnavailableExecutor(
                        'R grading needs Web Worker support, which this browser did not provide');
            }
            return this.r;
        }

        async ensureReady() {
            const kinds = this.requiredKinds();
            const needsPython = kinds.has('python');
            const needsR = kinds.has('r');
            const boots = [];
            if (needsPython) boots.push(this.pythonExecutor().ensureReady());
            if (needsR) {
                // A substrate that cannot start must abort the grade — that is
                // what routes the submission to the server-side worker instead
                // of posting an all-`error` collection as a real 0 (see the
                // ensureReady probe in runScripts).
                //
                // But only when it is the substrate this assignment RUNS on.
                // An assignment is one language, so "R failed to boot" on an R
                // lab is a failed grade; a stray .R sitting beside Python tests
                // is not, and must not sink the tests that can run. Those
                // scripts then report their own error through run().
                const boot = this.rExecutor().ensureReady();
                boots.push(needsPython ? boot.catch(() => {}) : boot);
            }
            // No runnable script kind (all shell/unsupported, or an empty
            // suite): nothing to boot. Each run() still reports its own precise
            // "not here" message, so the grade completes rather than failing
            // over on a runtime that was never needed.
            await Promise.all(boots);
        }

        async run(name, limitSeconds) {
            if (!this.scriptExists(name)) return rawError(`Script not found: ${name}`);
            const kind = this.kindOf(name);
            if (kind === 'python') return this.pythonExecutor().run(name, limitSeconds);
            if (kind === 'r') return this.rExecutor().run(name, limitSeconds);
            if (kind === 'shell') return rawError('Shell scripts cannot run in the browser runner');
            const ext = scriptExtension(name);
            return rawError(`Unsupported test script type: ${ext ? '.' + ext : name}`);
        }

        async dispose() {
            for (const executor of [this.python, this.r]) {
                if (!executor) continue;
                try { await executor.dispose(); } catch (_) { /* best-effort */ }
            }
        }
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
    // GradingWorkerExecutor — Pyodide in a Web Worker so run-aways can be killed.
    //
    // Holds the file map + seed and lazily spawns a grading worker (via the
    // injectable factory), sending it `init`. Each run posts `{type:'run', …}`
    // and races the reply against a real setTimeout: classification (non-python
    // kinds) is decided on the MAIN thread (so a shell/R/unsupported script never
    // touches the worker), and a python script that blows the timeout is killed
    // with Worker.terminate(). The next run detects the dead worker and spawns +
    // re-inits a fresh one — re-sending the same file map + seed — before
    // proceeding. This is the kill path the main-thread Promise.race could not
    // provide against a synchronous CPU-bound loop.
    // -------------------------------------------------------------------------

    // Bounded init: how long to wait for a grading worker to finish booting its
    // kernel +
    // env-config before declaring it wedged, terminating it, and retrying once on
    // a fresh worker. The init path used to be UNBOUNDED — unlike run(), which
    // races a timer — so a Pyodide load/boot that never completed (observed
    // intermittently when the editor kernel boots a SECOND Pyodide beside the
    // grader under cross-origin isolation) hung the whole grade forever, with no
    // telemetry, since the per-test timer only covers the 'run' message. A real
    // cold init is seconds, so a generous default never trips a healthy boot; it
    // only converts an infinite hang into a bounded, observable, self-healing
    // failure. Overridable for tests via __CHICKADEE_GRADING_INIT_TIMEOUT_MS__.
    const GRADING_INIT_TIMEOUT_MS =
        (typeof globalThis !== 'undefined' && Number(globalThis.__CHICKADEE_GRADING_INIT_TIMEOUT_MS__) > 0)
            ? Number(globalThis.__CHICKADEE_GRADING_INIT_TIMEOUT_MS__)
            : 120000;

    class GradingWorkerExecutor {
        constructor(files, assignmentSeed, runnerCore, factory, reportPhase, label) {
            this.files = files;
            this.assignmentSeed = assignmentSeed ?? null;
            this.runnerCore = runnerCore;
            this.factory = factory;
            // Which substrate this instance drives ('Python' | 'R') — used only
            // in error text and telemetry, so a failed init says which runtime
            // failed. The protocol and lifecycle are identical for both.
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
                    this._report(msg.phase, (msg.ms != null) ? ('ms=' + msg.ms) : undefined);
                    return;
                }
                const entry = this._pending.get(msg.id);
                if (!entry) return;
                this._pending.delete(msg.id);
                entry.resolve(msg);
            };
            worker.onerror = (err) => {
                // A hard worker error rejects every in-flight call; the next run
                // rebuilds. (Pyodide load failures surface here.)
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
            // Pyodide on its own thread, the timer always fires even when student
            // code is in a synchronous CPU-bound loop — so terminate() can kill it.
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

        // Eagerly spawn + init the grading worker so a wedged or trapping Pyodide
        // init rejects HERE (for the caller to fail over) instead of being
        // swallowed into per-script `error` outcomes by the wasm run() catch.
        // Idempotent: shares the cached _ensureWorker() init the run() path uses.
        ensureReady() {
            return this._ensureWorker();
        }

        async dispose() {
            // Terminate the worker so Pyodide's memory is reclaimed. This counts
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

    // writeFilesToPyFS comes from grading-shared.js (shared with the worker).

    // Decode a file-map value (UTF-8 string or byte array) to text — used to
    // classify a script on the main thread without round-tripping the worker.
    function fileAsText(value) {
        if (typeof value === 'string') return value;
        try { return new TextDecoder().decode(value instanceof Uint8Array ? value : new Uint8Array(value)); }
        catch (_) { return ''; }
    }

    // -------------------------------------------------------------------------
    // Status display
    // -------------------------------------------------------------------------

    function setRunnerStatus(type, msg) {
        if (!statusEl) return;
        statusEl.textContent = msg;
        statusEl.className   = `nb-status${type ? ' nb-status-' + type : ''}`;
    }

    // -------------------------------------------------------------------------
    // Notebook extraction (mirrors runner-support nb_to_py.py / RunnerDaemon.swift)
    // -------------------------------------------------------------------------

    async function extractNotebook(py, workDir, filename, notebookText) {
        const core = await loadRunnerCore();
        const extracted = {};
        extractNotebookToMap(extracted, core, filename, notebookText);
        // Replay the produced relative paths into the live Pyodide FS — the
        // map-based extractor (used by runScripts) and this py.FS variant (kept
        // for the standalone extractNotebook test + any direct caller) share one
        // implementation; only the sink differs.
        for (const [relPath, value] of Object.entries(extracted)) {
            py.FS.writeFile(`${workDir}/${relPath}`, value);
        }
    }

    // Notebook extraction into a plain file map { <relativePath>: <string> }.
    // Mirrors extractNotebook but writes to a JS object instead of py.FS, so the
    // grading worker (which holds its own Pyodide FS) and the main-thread
    // fallback both consume the same extraction result. BOTH languages extract
    // through the shared RunnerCore wasm (already loaded as `core`): Python via
    // extractPython, R via extractR — the same marker-emitting implementation
    // the native worker runs, so the two extractors cannot drift.
    function extractNotebookToMap(files, core, filename, notebookText) {
        let notebook;
        try { notebook = JSON.parse(notebookText); } catch (_) { return; }

        // Detect kernel language exactly as AssignmentLanguage.isRNotebookMetadata
        // does natively. This file cannot import Swift, so R_KERNEL_NAMES is a
        // generated copy of AssignmentLanguage.rKernelNames (see the fenced
        // block above).
        const meta   = notebook.metadata || {};
        const ks     = meta.kernelspec || {};
        const ksName = (ks.name || '').toLowerCase();
        const liName = ((meta.language_info || {}).name || '').toLowerCase();
        const isR    = R_KERNEL_NAMES.includes(ksName) || liName === 'r';
        const stem   = filename.replace(/\.ipynb$/i, '');

        const cells = (notebook.cells || []).map(cell => ({
            cell_type: cell.cell_type,
            source: Array.isArray(cell.source) ? cell.source.join('') : (cell.source || ''),
        }));

        if (isR) {
            // Shared RunnerCore implementation: header + an inert
            // `# ---- chickadee:cell N ----` marker per cell, which the R
            // grading runtime's chickadee_student_cells() splits on —
            // byte-identical to the native worker's extraction.
            files[`${stem}.R`] = core.extractR(cells, filename).source;
            files['.chickadee_student_module'] = `${stem}.R`;
            return;
        }

        // Python: extract via the shared RunnerCore wasm — the SAME code the
        // native worker runs (Sources/RunnerCore), instead of a JS reimplementation.
        const result = core.extractPython(cells, filename);

        files[`${stem}.py`] = result.executableModule;
        files['.chickadee_student_module'] = `${stem}.py`;

        // Sidecar: the introspectable (un-exec-wrapped) source, so structural /
        // AST NotebookChecks can read real `def`s via student_source().
        files[`${stem}.source.py`] = result.introspectableSource;
        files['.chickadee_student_source'] = `${stem}.source.py`;
    }

    // Build the _ck_inputs.py source from per-student personalization inputs
    // (issue #461, Slice B). Each value is already a Python literal the server
    // resolved for this student's seed (via the same gradingInputs helper);
    // generated pattern-family scripts load this file by path. Keys are sorted
    // for determinism. Mirrors the native worker writing Job.personalizedInputs.
    function personalizationInputsSource(personalizedInputs) {
        let ckSource = '# Auto-generated per-student grading inputs (issue #461). Do not edit.\n_ck = {\n';
        for (const key of Object.keys(personalizedInputs).sort()) {
            ckSource += `    ${JSON.stringify(key)}: ${personalizedInputs[key]},\n`;
        }
        ckSource += '}\n';
        return ckSource;
    }

    // -------------------------------------------------------------------------
    // RunnerCore wasm (lazy singleton)
    //
    // Loads the vendored, embedded-Swift RunnerCore bridge and returns its
    // exported functions — `extractPython(cells, filename)`, `extractR(cells,
    // filename)` and `classifyScript(name, source)`, the SAME Swift code the
    // native worker runs. A test harness can preset the `globalThis.runner*`
    // globals to skip loading the wasm.
    // -------------------------------------------------------------------------

    let _runnerCore = null;

    async function loadRunnerCore() {
        if (_runnerCore) return _runnerCore;
        const ready = () =>
            typeof globalThis.runnerExtractPython === 'function'
            && typeof globalThis.runnerExtractR === 'function'
            && typeof globalThis.runnerClassifyScript === 'function';
        if (!ready()) {
            const mod = await import('/runner-wasm/runner-core.js');
            await mod.init();  // runs the wasm entrypoint → registers the globals
        }
        if (!ready()) {
            throw new Error('RunnerCore wasm did not register its exports');
        }
        _runnerCore = {
            extractPython: globalThis.runnerExtractPython,
            extractR: globalThis.runnerExtractR,
            classifyScript: globalThis.runnerClassifyScript,
        };
        return _runnerCore;
    }

    // Map a RunnerCore interpreter raw value to how the browser dispatches it.
    // The browser can only execute Python (Pyodide); other interpreters get a
    // precise "not here" message.
    function interpreterToKind(interp) {
        if (interp === 'python') return 'python';
        if (interp === 'rscript') return 'r';
        if (interp === 'sh' || interp === 'bash' || interp === 'zsh') return 'shell';
        return 'unsupported';  // ruby / perl / node / php / unknown
    }

    // Per-cell extraction (Python: magic stripping, def/usage split,
    // exec(compile()) wrapping; R: cell-boundary markers) lives in RunnerCore
    // (Swift, compiled to wasm) and is shared with the native worker — see
    // extractNotebookToMap above.

    // -------------------------------------------------------------------------
    // Python script execution
    // -------------------------------------------------------------------------

    // Lowercased file extension of a script name, or '' when there is none —
    // a bare name like `beats` or a leading-dot dotfile. Mirrors the semantics
    // of URL.pathExtension on the worker side.
    function scriptExtension(name) {
        const base = name.slice(name.lastIndexOf('/') + 1);
        const dot  = base.lastIndexOf('.');
        return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
    }

    // Script classification (recognised extension \u2192 shebang \u2192 Python
    // content-sniff) now lives in RunnerCore (Swift/wasm) and is shared with the
    // native worker \u2014 see loadRunnerCore().classifyScript / interpreterToKind.

    // A synthetic raw output for a substrate error: exit 2 → RunnerCore maps to
    // `error`, with `message` as the (last-line) shortResult.
    function rawError(message) {
        return { exitCode: 2, stdout: message, stderr: '', executionTimeMs: 0, timedOut: false };
    }

    // Execute a Python test script in Pyodide and capture RAW output. The exit
    // code comes from the SystemExit that test_runtime's passed/failed/errored
    // raise — the SAME codes the native subprocess exits with — so RunnerCore's
    // exit-code → status mapping is identical across runners. No interpretation
    // happens here.
    // deriveExitCode comes from grading-shared.js (shared with the worker).

    // -------------------------------------------------------------------------
    // Outcome / collection builders
    // -------------------------------------------------------------------------

    // Exit-code → status mapping and result interpretation (JSON-footer parsing,
    // traceback extraction, longResult assembly) now live in RunnerCore
    // (interpretScriptOutput), shared with the native worker and applied inside
    // `executeSuites`. The browser no longer interprets output in JS — it only
    // produces raw ScriptOutput (see runPyScriptRaw).

    function buildCollection(setupID, outcomes) {
        const passCount    = outcomes.filter(o => o.status === 'pass').length;
        const failCount    = outcomes.filter(o => o.status === 'fail').length;
        const errorCount   = outcomes.filter(o => o.status === 'error').length;
        const timeoutCount = outcomes.filter(o => o.status === 'timeout').length;
        const totalMs      = outcomes.reduce((s, o) => s + o.executionTimeMs, 0);

        return {
            submissionID:    '',    // server fills this in when it creates the record
            testSetupID:     setupID,
            attemptNumber:   1,     // server recomputes from prior submission count
            buildStatus:     outcomes.length === 0 ? 'failed' : 'passed',
            compilerOutput:  null,
            outcomes,
            totalTests:      outcomes.length,
            passCount,
            failCount,
            errorCount,
            timeoutCount,
            executionTimeMs: totalMs,
            runnerVersion:   'browser-wasm-runner/1.0',
            timestamp:       new Date().toISOString(),
        };
    }

    function safeSubmissionFilename(filename) {
        const raw = String(filename || '').split(/[\\/]/).pop().trim();
        return raw || 'submission.ipynb';
    }

    // -------------------------------------------------------------------------
    // POST notebook bytes + TestOutcomeCollection to the server
    // -------------------------------------------------------------------------

    async function postBrowserResult(notebookBytes, collection, setupID) {
        const formData = new FormData();
        formData.append('collection', JSON.stringify(collection));
        formData.append('notebook',
            new Blob([notebookBytes], { type: 'application/octet-stream' }),
            'submission.ipynb');
        formData.append('testSetupID', setupID);

        const res = await fetch('/api/v1/submissions/browser-result', {
            method:  'POST',
            headers: { 'x-csrf-token': ChickadeeUI.getCsrfToken() },
            body:    formData,
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Failed to submit results: ${res.status} ${text}`);
        }
        return res.json();
    }

    // -------------------------------------------------------------------------
    // Misc helpers
    // -------------------------------------------------------------------------

    let _JSZip = null;

    async function loadJSZip() {
        if (_JSZip) return _JSZip;
        if (!window.JSZip) {
            await loadScript('/vendor/jszip.min.js');
        }
        _JSZip = window.JSZip;
        return _JSZip;
    }

    function loadScript(src) {
        return new Promise((resolve, reject) => {
            const el   = document.createElement('script');
            el.src     = src;
            el.onload  = resolve;
            el.onerror = () => reject(new Error(`Failed to load ${src}`));
            document.head.appendChild(el);
        });
    }

    async function fetchBytes(url) {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Fetch failed ${res.status}: ${url}`);
        return res.arrayBuffer();
    }

    async function fetchText(url) {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Fetch failed ${res.status}: ${url}`);
        return res.text();
    }

    /** Converts any thrown value to a human-readable string. */
    function toMessage(e) {
        if (e instanceof Error && e.message) return e.message;
        const s = String(e);
        return (s && s !== '[object Object]') ? s : 'unknown error';
    }

    // -------------------------------------------------------------------------
    // Shared Python snippets (env config + per-script exec) live in
    // Public/grading-shared.js — one copy run by BOTH this main-thread
    // fallback and the grading worker, destructured at the top of the IIFE.
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Embedded runtime helpers (kept in sync with Sources/Worker/RunnerDaemon.swift)
    // -------------------------------------------------------------------------

    // test_runtime.py — mirrors the testRuntimePy string in RunnerDaemon.swift.
    // Update both locations when making changes.
    const TEST_RUNTIME_PY = `\
import inspect
import importlib.util
import json
import sys
import traceback
from pathlib import Path
from typing import Dict, List, Optional, Any


def _caller_file(depth: int = 3) -> Path:
    frame = inspect.stack()[depth]
    return Path(frame.filename)


def _first_comment_label() -> str:
    path = _caller_file()
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            if s.startswith("#!") or s.startswith("# -*-"):
                continue
            if s.startswith("#"):
                label = s.lstrip("#").strip()
                return label if label else path.stem
            break
    except Exception:
        pass
    return path.stem


def _emit(payload: Dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def _first_nonempty_line(text: str) -> str:
    for raw in text.splitlines():
        line = raw.strip()
        if line:
            return line
    return ""


def passed(message: Optional[str] = None):
    label = _first_comment_label()
    _emit({
        "shortResult": message or f"{label}: passed",
        "status": "pass",
        "test": label,
    })
    raise SystemExit(0)


def failed(message: str = "failed"):
    label = _first_comment_label()
    text = message if isinstance(message, str) else str(message)
    summary = _first_nonempty_line(text) or "failed"
    if text.strip() and text.strip() != "failed":
        print(text)
    _emit({
        "shortResult": f"{label}: {summary}",
        "status": "fail",
        "test": label,
        "error": text,
    })
    raise SystemExit(1)


def errored(message: str = "error", err: Optional[Exception] = None):
    label = _first_comment_label()
    text = message if isinstance(message, str) else str(message)
    summary = _first_nonempty_line(text) or "error"
    if text.strip() and text.strip() != "error":
        print(text)
    payload = {
        "shortResult": f"{label}: {summary}",
        "status": "error",
        "test": label,
        "error": summary,
    }
    if err is not None:
        payload["exception"] = repr(err)
        payload["traceback"] = traceback.format_exc()
    _emit(payload)
    raise SystemExit(2)


def _candidate_student_files() -> List[Path]:
    cwd = Path(".")
    files: List[Path] = []
    for p in cwd.glob("*.py"):
        name = p.name
        if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py", "_ck_inputs.py"}:
            continue
        lower = name.lower()
        if lower.startswith("publictest") or lower.startswith("secrettest") or lower.startswith("releasetest"):
            continue
        files.append(p)
    return sorted(files, key=_student_file_sort_key)


def _student_file_sort_key(path: Path):
    lower = path.name.lower()
    if lower == "assignment.py":
        return (90, lower)
    if lower in {"solution.py", "submission.py"}:
        return (0, lower)
    return (10, lower)


def _preferred_student_module() -> Optional[Path]:
    hint = Path(".chickadee_student_module")
    if not hint.exists():
        return None
    try:
        raw = hint.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if not raw:
        return None
    preferred = Path(raw).name
    if not preferred.endswith(".py"):
        return None
    path = Path(preferred)
    return path if path.exists() else None


def _module_name_for_path(path: Path) -> str:
    stem = path.stem
    safe = "".join(ch if (ch.isalnum() or ch == "_") else "_" for ch in stem)
    if not safe:
        safe = "student"
    if safe[0].isdigit():
        safe = f"m_{safe}"
    return f"student_{safe}"


def _ordered_student_files() -> List[Path]:
    preferred = _preferred_student_module()
    if preferred is not None:
        return [preferred]
    return _candidate_student_files()


_loaded_student_modules: Optional[Dict[str, Any]] = None
_loaded_student_order: List[str] = []
_student_module_errors: Dict[str, str] = {}


def load_student_modules(force_reload: bool = False) -> Dict[str, Any]:
    global _loaded_student_modules, _loaded_student_order, _student_module_errors
    if _loaded_student_modules is not None and not force_reload:
        return _loaded_student_modules

    modules: Dict[str, Any] = {}
    order: List[str] = []
    errors: Dict[str, str] = {}

    for path in _ordered_student_files():
        key = path.name
        try:
            module_name = _module_name_for_path(path)
            spec = importlib.util.spec_from_file_location(module_name, path)
            if spec is None or spec.loader is None:
                errors[key] = "Could not create import spec."
                continue
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            spec.loader.exec_module(module)
            modules[key] = module
            order.append(key)
        except Exception:
            errors[key] = traceback.format_exc()

    _loaded_student_modules = modules
    _loaded_student_order = order
    _student_module_errors = errors
    return modules


def student_module_errors() -> Dict[str, str]:
    return _student_module_errors


def student_module_names_in_load_order() -> List[str]:
    return list(_loaded_student_order)


def load_student_module():
    modules = load_student_modules()
    if not _loaded_student_order:
        return None
    return modules.get(_loaded_student_order[0])


_student_main_state = None


def student_main_state():
    # The student notebook AS EXECUTED — runs quarantined top-level code once
    # with run_name="__main__" and caches the namespace; falls back to the
    # import-mode module when no student file exists or the run fails.
    global _student_main_state
    if _student_main_state is not None:
        return _student_main_state
    import runpy
    import types

    files = _ordered_student_files()
    if not files:
        return load_student_module()
    try:
        namespace = runpy.run_path(str(files[0]), run_name="__main__")
        _student_main_state = types.SimpleNamespace(**namespace)
    except Exception:
        print(traceback.format_exc(), file=sys.stderr)
        return load_student_module()
    return _student_main_state


def student_source_raw() -> str:
    hint = Path(".chickadee_student_source")
    try:
        if hint.exists():
            name = Path(hint.read_text(encoding="utf-8").strip()).name
            sidecar = Path(name)
            if name and sidecar.exists():
                return sidecar.read_text(encoding="utf-8")
    except Exception:
        pass
    try:
        import inspect
        module = load_student_module()
        if module is not None:
            return inspect.getsource(module)
    except Exception:
        pass
    return ""


def student_cell_sources() -> List[Any]:
    source = student_source_raw()
    chunks: List[Any] = []
    label = "module"
    lines: List[str] = []
    for raw in source.split("\\n"):
        stripped = raw.strip()
        if stripped.startswith("# --- ") and stripped.endswith(" ---"):
            if lines:
                chunks.append((label, "\\n".join(lines)))
            label = stripped[6:-4].strip() or "module"
            lines = []
        else:
            lines.append(raw)
    if lines:
        chunks.append((label, "\\n".join(lines)))
    if not chunks:
        chunks.append(("module", source))
    return chunks


def student_ast(skipped: Optional[List[Any]] = None) -> Any:
    import ast
    module = ast.parse("")
    for label, chunk in student_cell_sources():
        if not chunk.strip():
            continue
        try:
            node = ast.parse(chunk)
        except SyntaxError as ex:
            if skipped is not None:
                skipped.append((label, f"{type(ex).__name__}: {ex}"))
            continue
        module.body.extend(node.body)
    return module


def student_source() -> str:
    import ast
    parts: List[str] = []
    dropped = False
    for label, chunk in student_cell_sources():
        if chunk.strip():
            try:
                ast.parse(chunk)
            except SyntaxError:
                dropped = True
                continue
        parts.append(f"# --- {label} ---\\n{chunk}")
    if not dropped or not parts:
        return student_source_raw()
    return "\\n\\n".join(parts) + "\\n"


def require_function(name: str, num_args: Optional[int] = None):
    modules = load_student_modules()
    for key in _loaded_student_order:
        module = modules.get(key)
        if module is None:
            continue
        fn = getattr(module, name, None)
        if fn is not None and callable(fn):
            if num_args is not None:
                _require_num_args(fn, name, num_args)
            return fn

    if not modules:
        errors = student_module_errors()
        if errors:
            first_name = next(iter(errors.keys()))
            print(errors[first_name], end="")
            errored("SyntaxError in submission")
        errored("Could not load a student Python module from submission.")

    errored(f"Required function '{name}' was not found or is not callable in loaded student modules.")


def _require_num_args(fn: Any, name: str, num_args: int) -> None:
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return
    positional_kinds = {
        inspect.Parameter.POSITIONAL_ONLY,
        inspect.Parameter.POSITIONAL_OR_KEYWORD,
    }
    positional = [p for p in sig.parameters.values() if p.kind in positional_kinds]
    required = sum(1 for p in positional if p.default is inspect.Parameter.empty)
    accepts_varargs = any(
        p.kind == inspect.Parameter.VAR_POSITIONAL for p in sig.parameters.values()
    )
    total = len(positional)
    if accepts_varargs:
        if num_args < required:
            errored(
                f"'{name}' requires at least {required} positional argument(s), "
                f"but the test expects it to take {num_args}."
            )
        return
    if not (required <= num_args <= total):
        if required == total:
            errored(
                f"'{name}' should take {num_args} argument(s), but it takes {total}."
            )
        else:
            errored(
                f"'{name}' should take {num_args} argument(s), "
                f"but it takes {required}-{total}."
            )
`;

    // sitecustomize.py — auto-imported by Python; makes helpers available as builtins.
    // Mirrors the sitecustomizePy constant in RunnerDaemon.swift.
    const SITECUSTOMIZE_PY = `\
import builtins
import test_runtime as _tr

builtins.passed = _tr.passed
builtins.failed = _tr.failed
builtins.errored = _tr.errored
builtins.require_function = _tr.require_function

_student_modules = _tr.load_student_modules()
builtins.student_modules = _student_modules
_student_module = _tr.load_student_module()
builtins.student_module = _student_module
for _module_name in _tr.student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith("_"):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)
`;


    // test_runtime.R — mirrors Tools/runner-support/test_runtime.R (and the
    // testRuntimeR* literals in Sources/Worker/TestRuntimeSources.swift).
    // Written into every browser grading workspace so an R test script's
    // `source("test_runtime.R")` resolves to the same helpers the native runner
    // injects. Pinned by Tests/BrowserRunnerJSTests/runtime-drift.test.mjs.
    //
    // The helpers here call quit()/commandArgs() — process-level primitives a
    // Jupyter kernel does not have. Rather than fork this copy for the browser,
    // r-grading-shared.js masks both in the global environment before sourcing
    // a script, so this file stays byte-identical across the two runners.
    const TEST_RUNTIME_R = `\
# test_runtime.R — Chickadee R test helper library.
# Source at the top of each R test script: source("test_runtime.R")
#
# API:
#   passed(message = NULL)     — exit 0  (pass)
#   failed(message = "failed") — exit 1  (fail)
#   errored(message = "error") — exit 2  (error)
#   chickadee_seed()           — deterministic per-student integer seed
#   chickadee_inputs()         — per-student inputs from _ck_inputs.R
#
# No external package dependencies; JSON is hand-formatted so this works
# on bare R installs without jsonlite.
#
# This file is the canonical source for the runtime that the runner injects
# into every test working directory. The helper API is inlined as the
# \`testRuntimeRHelpers\` string literal in Sources/Worker/TestRuntimeSources.swift;
# the chickadee_seed()/chickadee_inputs() blocks below mirror
# Sources/Core/RPersonalizationRuntime.swift (composed onto the helpers there so
# the server-side expression driver and this grading runtime compute the seed
# identically). Keep all three in sync when editing.

.chickadee_json_str <- function(x) {
    x <- as.character(x)
    x <- gsub("\\\\", "\\\\\\\\", x, fixed = TRUE)
    x <- gsub('"',    '\\\\"',    x, fixed = TRUE)
    x <- gsub("\\n",   "\\\\n",    x, fixed = TRUE)
    x <- gsub("\\r",   "\\\\r",    x, fixed = TRUE)
    x <- gsub("\\t",   "\\\\t",    x, fixed = TRUE)
    paste0('"', x, '"')
}

.chickadee_label <- function() {
    args  <- commandArgs(trailingOnly = FALSE)
    fargs <- args[startsWith(args, "--file=")]
    if (length(fargs) > 0L) {
        path <- sub("^--file=", "", fargs[[1L]])
        return(tools::file_path_sans_ext(basename(path)))
    }
    "test"
}

.chickadee_emit <- function(status, short_result, error = NULL) {
    label <- .chickadee_label()
    parts <- c(
        paste0('"status":',      .chickadee_json_str(status)),
        paste0('"shortResult":', .chickadee_json_str(short_result)),
        paste0('"test":',        .chickadee_json_str(label))
    )
    if (!is.null(error)) {
        parts <- c(parts, paste0('"error":', .chickadee_json_str(as.character(error))))
    }
    cat(paste0("{", paste(parts, collapse = ","), "}\\n"))
}

passed <- function(message = NULL) {
    label <- .chickadee_label()
    msg   <- if (!is.null(message)) as.character(message) else paste0(label, ": passed")
    .chickadee_emit("pass", msg)
    quit(status = 0L, save = "no")
}

failed <- function(message = "failed") {
    label <- .chickadee_label()
    msg   <- as.character(message)
    .chickadee_emit("fail", paste0(label, ": ", msg), error = msg)
    quit(status = 1L, save = "no")
}

errored <- function(message = "error") {
    label <- .chickadee_label()
    msg   <- as.character(message)
    .chickadee_emit("error", paste0(label, ": ", msg), error = msg)
    quit(status = 2L, save = "no")
}

# --- Value formatting + comparison ------------------------------------------
# Used by generated pattern-family tests (and available to hand-authored
# ones) so failure messages read the same whatever produced the test.

# One-line, student-readable rendering of a value - the R analogue of
# Python's repr(). Collapsed to a single line and truncated so a failure
# message stays scannable.
chickadee_format <- function(x, max_chars = 300L) {
    s <- tryCatch(paste(deparse(x), collapse = " "), error = function(e) "<unprintable>")
    s <- gsub("[[:space:]]+", " ", s)
    if (nchar(s) > max_chars) paste0(substr(s, 1L, max_chars), " ...") else s
}

# Exact equality, with JSON-friendly numeric handling: an expected value
# decoded from the family spec is a double (1), while a student may well
# return an integer (1L). Comparing numerics by value keeps that difference
# from failing an otherwise-correct answer. Everything else falls back to
# all.equal's structural comparison (names, nesting, attributes).
chickadee_equal <- function(actual, expected) {
    if (is.numeric(actual) && is.numeric(expected)) {
        if (length(actual) != length(expected)) return(FALSE)
        return(isTRUE(all(actual == expected)))
    }
    if (is.logical(actual) && is.logical(expected)) {
        if (length(actual) != length(expected)) return(FALSE)
        return(isTRUE(all(actual == expected)))
    }
    isTRUE(all.equal(actual, expected))
}

# Order-insensitive comparison for the unordered_equality kind: same
# elements, any order. Compared as characters so mixed numeric/integer
# element types do not matter.
chickadee_unordered_equal <- function(actual, expected) {
    a <- tryCatch(unlist(actual, use.names = FALSE), error = function(e) NULL)
    b <- tryCatch(unlist(expected, use.names = FALSE), error = function(e) NULL)
    if (is.null(a) || is.null(b)) return(FALSE)
    if (length(a) != length(b)) return(FALSE)
    isTRUE(all(sort(as.character(a)) == sort(as.character(b))))
}

# --- Per-student personalization primitives ---------------------------------
# Mirror of Sources/Core/RPersonalizationRuntime.swift. base R has no bignum, so
# the 256-bit hex seed is folded with Horner's method modulo 2^31-1 (every
# intermediate stays < 2^35, safely inside a double). Deterministic per student
# and identical wherever called, so R stays self-consistent.

chickadee_seed <- function() {
    hex <- tolower(gsub("[^0-9a-fA-F]", "", Sys.getenv("CHICKADEE_ASSIGNMENT_SEED", "")))
    if (!nzchar(hex)) return(0L)
    digits <- strtoi(strsplit(hex, "")[[1L]], 16L)
    modulus <- 2147483647            # 2^31 - 1; intermediates stay < 2^35
    acc <- 0
    for (d in digits) acc <- (acc * 16 + d) %% modulus
    as.integer(acc)
}

# Returns the per-student grading inputs the worker materialized into
# _ck_inputs.R (a \`.ck_inputs <- list(...)\` binding), or an empty list when none
# were delivered. The R mirror of a Python test reading _ck["name"].
chickadee_inputs <- function() {
    if (!file.exists("_ck_inputs.R")) return(list())
    env <- new.env(parent = baseenv())
    ok <- tryCatch({ sys.source("_ck_inputs.R", envir = env); TRUE },
                   error = function(e) FALSE)
    if (ok && exists(".ck_inputs", envir = env, inherits = FALSE)) {
        get(".ck_inputs", envir = env)
    } else {
        list()
    }
}

# --- Locating the student's submission --------------------------------------
# Mirror of the testRuntimeRStudentFile block in
# Sources/Worker/TestRuntimeSources.swift (where the reserved inputs filename is
# interpolated from AssignmentLanguage). Filenames Chickadee itself writes into
# the grading workspace are never the student's submission.
.chickadee_reserved_files <- c("test_runtime.R", "_ck_inputs.R")

.chickadee_is_test_file <- function(names) {
    grepl("^(publictest|releasetest|secrettest|studenttest)", names)
}

# The test script currently executing. It is itself a .R file sitting in the
# working directory, so it must never be mistaken for the submission - the
# tier-prefix rule above only covers the conventional names.
.chickadee_running_script <- function() {
    args  <- commandArgs(trailingOnly = FALSE)
    fargs <- args[startsWith(args, "--file=")]
    if (length(fargs) > 0L) return(basename(sub("^--file=", "", fargs[[1L]])))
    ""
}

# The student's submitted R file: solution.R during validation, the extracted
# notebook during grading. Prefers the runner's \`.chickadee_student_module\`
# hint when it names an R file that is actually present, then falls back to
# scanning the working directory. \`extra_skip\` lets an assignment exclude its
# own bundled helpers, e.g. chickadee_student_file(c("a2_helpers.R")).
# Returns NA_character_ when nothing looks like a submission.
chickadee_student_file <- function(extra_skip = character(0)) {
    hint_path <- ".chickadee_student_module"
    if (file.exists(hint_path)) {
        hinted <- tryCatch(trimws(readLines(hint_path, warn = FALSE)),
                           error = function(e) character(0))
        hinted <- hinted[nzchar(hinted)]
        if (length(hinted) > 0L) {
            preferred <- basename(hinted[[1L]])
            if (grepl("\\\\.[Rr]$", preferred) && file.exists(preferred)) return(preferred)
        }
    }
    rfiles <- list.files(pattern = "\\\\.[Rr]$")
    skip   <- c(.chickadee_reserved_files, .chickadee_running_script(), extra_skip)
    cand   <- rfiles[!(rfiles %in% skip) & !.chickadee_is_test_file(rfiles)]
    if (length(cand) == 0L) return(NA_character_)
    if ("solution.R" %in% cand) return("solution.R")
    cand[[1L]]
}

# Evaluate the submission expression-by-expression in a fresh environment, so a
# runtime error in one top-level line still leaves the function definitions
# that loaded before it available to the tests.
chickadee_load_student <- function(extra_skip = character(0)) {
    f <- chickadee_student_file(extra_skip)
    if (is.na(f)) errored("No R submission file was found to grade.")

    env <- new.env(parent = globalenv())
    grDevices::pdf(NULL)                 # swallow any plots the notebook draws
    on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)

    exprs <- tryCatch(parse(file = f), error = function(e) NULL)
    if (is.null(exprs)) {
        errored(paste0("Your submission (", f, ") could not be parsed as R - check for a syntax error."))
    }
    for (ex in exprs) tryCatch(eval(ex, envir = env), error = function(e) invisible(NULL))
    env
}

# Split the submission back into the notebook cells it was flattened from.
# \`extractNotebooksToCode\` writes an inert marker comment ahead of each code
# cell, which is what gives a source-level check cell granularity that plain
# concatenation loses. A submission that never came from a notebook (a
# hand-written .R upload) has no markers, so the whole file is returned as one
# cell — file granularity, which is the honest answer for a file with no cells.
chickadee_student_cells <- function(extra_skip = character(0)) {
    f <- chickadee_student_file(extra_skip)
    if (is.na(f)) errored("No R submission file was found to grade.")
    lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    starts <- which(grepl("^# ---- chickadee:cell [0-9]+ ----$", lines))
    if (length(starts) == 0L) return(paste(lines, collapse = "\\n"))
    ends <- c(starts[-1L] - 1L, length(lines))
    out <- character(length(starts))
    for (i in seq_along(starts)) {
        first <- starts[[i]] + 1L
        out[[i]] <- if (first > ends[[i]]) "" else paste(lines[first:ends[[i]]], collapse = "\\n")
    }
    out
}

# Fetch a function the student was asked to write; a clear error when it is
# missing or was overwritten with something that is not a function.
chickadee_require_fn <- function(env, name) {
    fn <- tryCatch(get(name, envir = env, inherits = FALSE), error = function(e) NULL)
    if (is.null(fn) || !is.function(fn)) {
        errored(sprintf("Your submission must define a function called \`%s()\`.", name))
    }
    fn
}
`;

    const testHooks = globalThis.__CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__;
    if (testHooks) {
        testHooks.exports = {
            // Embedded runtime sources, exposed so the drift test can assert
            // they stay in sync with Tools/runner-support/*.py.
            TEST_RUNTIME_PY,
            SITECUSTOMIZE_PY,
            TEST_RUNTIME_R,
            // Shared grading semantics (re-exported from grading-shared.js).
            runAndSubmit,
            runScripts,
            scriptExtension,
            extractNotebook,
            extractNotebookToMap,
            personalizationInputsSource,
            personalizationInputsSourceR,
            deriveExitCode,
            buildCollection,
            fileAsText,
            makeExecutor,
            GradingWorkerExecutor,
            RoutingExecutor,
            UnavailableExecutor,
            interpreterToKind,
            fetchBytes,
            fetchText,
            toMessage,
            __resetStateForTests() {
                _JSZip   = null;
                _runnerCore = null;
                if (statusEl) {
                    statusEl.textContent = '';
                    statusEl.className   = '';
                    statusEl.hidden      = false;
                }
            },
        };
    }

})();
