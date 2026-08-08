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
// Four substrates, picked per script by RunnerCore's shared classification:
//   .py  → the vendored xeus-python kernel, via /python-grading-worker.js
//   .R   → the vendored xeus-r kernel, via /r-grading-worker.js
//   .lua → the vendored xeus-lua kernel, via /lua-grading-worker.js
//   .m   → the vendored xeus-octave kernel, via /octave-grading-worker.js
// All are Web Workers running a xeus kernel.  For Python, R and Octave it is
// the SAME environment the notebook editor boots, so "it ran in the editor"
// implies "it grades here"; Lua is a grading substrate only, with no editor
// kernel to skew from.  Only the substrates an assignment actually needs are booted, so an R
// lab never pays for the Python env (and vice versa).  Shell scripts (.sh) are
// not supported in the browser environment on any substrate.

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
    const { personalizationInputsSourceLua } = ChickadeeLuaGradingShared;
    const { personalizationInputsSourceOctave } = ChickadeeOctaveGradingShared;

    // Kernelspec names that mark an R notebook. The browser cannot import
    // Swift, so this is a GENERATED copy of AssignmentLanguage.rKernelNames
    // (Sources/Core/AssignmentLanguage.swift), written by
    // scripts/generate-js-constants.sh — edit the Swift set and re-run that
    // script, never this line. CI (format-lint) fails if the two drift.
    // CHICKADEE_GENERATED:R_KERNEL_NAMES:BEGIN
    const R_KERNEL_NAMES = ['ir', 'r', 'webr', 'xr'];
    // CHICKADEE_GENERATED:R_KERNEL_NAMES:END
    // CHICKADEE_GENERATED:LUA_KERNEL_NAMES:BEGIN
    const LUA_KERNEL_NAMES = ['lua', 'xlua'];
    // CHICKADEE_GENERATED:LUA_KERNEL_NAMES:END
    // CHICKADEE_GENERATED:OCTAVE_KERNEL_NAMES:BEGIN
    const OCTAVE_KERNEL_NAMES = ['octave', 'xoctave'];
    // CHICKADEE_GENERATED:OCTAVE_KERNEL_NAMES:END
    // CHICKADEE_GENERATED:PYTHON_KERNEL_NAMES:BEGIN
    const PYTHON_KERNEL_NAMES = ['python', 'python3', 'xpython'];
    // CHICKADEE_GENERATED:PYTHON_KERNEL_NAMES:END

    // Filename extensions that mark a directly-uploaded file as gradeable
    // source, so it gets a `.chickadee_student_module` hint. A GENERATED copy of
    // the union of LanguageDescriptor.scriptExtensions — same rule as above:
    // edit the Swift literal and re-run the script, never this line. Hand-listing
    // them here is what omitted `.lua`, leaving a Lua upload with no hint and
    // test_runtime.lua (which cannot list a directory) unable to find it.
    // CHICKADEE_GENERATED:GRADED_SCRIPT_EXTENSIONS:BEGIN
    const GRADED_SCRIPT_EXTENSIONS = ['.cpp', '.h', '.hpp', '.lua', '.m', '.py', '.r', '.rkt'];
    // CHICKADEE_GENERATED:GRADED_SCRIPT_EXTENSIONS:END

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

        // 2. Runtime helper libraries. Every language's helpers are written
        //    unconditionally: each is a reserved filename the OTHER languages'
        //    submission scanners already skip (test_runtime.R is in
        //    test_runtime.R's own `.chickadee_reserved_files`, test_runtime.lua
        //    in test_runtime.lua's RESERVED set; the .py helpers are in the
        //    Python scanner's skip set), so a spare copy cannot be mistaken for
        //    a submission. That keeps the workspace independent of detecting
        //    the assignment's language, which matters because the language is
        //    only known after the seed fetch below. The native runner writes
        //    all of them unconditionally too, but for the opposite reason: it
        //    builds one workspace before any script is classified.
        files['test_runtime.py']  = TEST_RUNTIME_PY;
        files['sitecustomize.py'] = SITECUSTOMIZE_PY;
        files['test_runtime.R']   = TEST_RUNTIME_R;
        files['test_runtime.lua'] = TEST_RUNTIME_LUA;
        files['test_runtime.m']   = TEST_RUNTIME_OCTAVE;

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
        } else if (GRADED_SCRIPT_EXTENSIONS.some((ext) => lowerSubmissionName.endsWith(ext))) {
            // Generated from LanguageDescriptor.scriptExtensions, so a new
            // language's uploads get a student-module hint the day its literal
            // lands rather than whenever someone remembers this line.
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
            if (parsed && typeof parsed.language === 'string' && parsed.language) {
                // Honour whatever language the server resolved (python/r/lua).
                // Testing only `=== 'r'` left every Lua assignment on 'python',
                // so the `'lua'` inputs writer below was dead code and a
                // browser-graded Lua assignment wrote _ck_inputs.py — the Lua
                // runtime reads _ck_inputs.lua and saw an empty table, so every
                // per-student value went missing. The browser twin of the
                // server-side resolve/rederive gap.
                assignmentLanguage = parsed.language;
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
            } else if (assignmentLanguage === 'lua') {
                files['_ck_inputs.lua'] = personalizationInputsSourceLua(personalizedInputs);
            } else if (assignmentLanguage === 'octave') {
                files['_ck_inputs.m'] = personalizationInputsSourceOctave(personalizedInputs);
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
        constructor(files, assignmentSeed, runnerCore, reportPhase, suites) {
            this.files = files;
            this.assignmentSeed = assignmentSeed ?? null;
            this.runnerCore = runnerCore;
            this.reportPhase = reportPhase;
            this.suites = Array.isArray(suites) ? suites : [];
            this.python = null;
            this.r = null;
            this.lua = null;
            this.octave = null;
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

        // Same shape as the Python substrate, and worker-only for the same
        // reason: booting a xeus kernel needs importScripts, which exists only
        // inside a worker. A Worker-less environment therefore gets an executor
        // whose ensureReady throws, routing the whole grade to the server-side
        // failover rather than recording every R test as an error.
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

        // Third of the same shape (the vendored xeus-lua kernel), and
        // worker-only for the same reason.
        luaExecutor() {
            if (!this.lua) {
                const factory = gradingWorkerFactory('/lua-grading-worker.js');
                this.lua = factory
                    ? new GradingWorkerExecutor(
                        this.files, this.assignmentSeed, this.runnerCore, factory, this.reportPhase,
                        'Lua')
                    : new UnavailableExecutor(
                        'Lua grading needs Web Worker support, '
                        + 'which this browser did not provide');
            }
            return this.lua;
        }

        // Fourth of the same shape (the vendored xeus-octave kernel), and
        // worker-only for the same reason.
        octaveExecutor() {
            if (!this.octave) {
                const factory = gradingWorkerFactory('/octave-grading-worker.js');
                this.octave = factory
                    ? new GradingWorkerExecutor(
                        this.files, this.assignmentSeed, this.runnerCore, factory,
                        this.reportPhase, 'Octave')
                    : new UnavailableExecutor(
                        'Octave grading needs Web Worker support, '
                        + 'which this browser did not provide');
            }
            return this.octave;
        }

        executorForKind(kind) {
            if (kind === 'python') return this.pythonExecutor();
            if (kind === 'r') return this.rExecutor();
            if (kind === 'lua') return this.luaExecutor();
            if (kind === 'octave') return this.octaveExecutor();
            return null;
        }

        async ensureReady() {
            const kinds = this.requiredKinds();
            const needsPython = kinds.has('python');
            const boots = [];
            if (needsPython) boots.push(this.pythonExecutor().ensureReady());
            for (const kind of ['r', 'lua', 'octave']) {
                if (!kinds.has(kind)) continue;
                // A substrate that cannot start must abort the grade — that is
                // what routes the submission to the server-side worker instead
                // of posting an all-`error` collection as a real 0 (see the
                // ensureReady probe in runScripts).
                //
                // But only when it is the substrate this assignment RUNS on.
                // An assignment is one language, so "R failed to boot" on an R
                // lab is a failed grade; a stray .R or .lua sitting beside
                // Python tests is not, and must not sink the tests that can
                // run. Those scripts then report their own error through run().
                const boot = this.executorForKind(kind).ensureReady();
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
            const executor = this.executorForKind(kind);
            if (executor) return executor.run(name, limitSeconds);
            if (kind === 'shell') return rawError('Shell scripts cannot run in the browser runner');
            const ext = scriptExtension(name);
            return rawError(`Unsupported test script type: ${ext ? '.' + ext : name}`);
        }

        async dispose() {
            for (const executor of [this.python, this.r, this.lua, this.octave]) {
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
        const isLua  = LUA_KERNEL_NAMES.includes(ksName) || liName === 'lua';
        const isOctave = OCTAVE_KERNEL_NAMES.includes(ksName) || liName === 'octave';
        const isPython = PYTHON_KERNEL_NAMES.includes(ksName) || liName === 'python';
        const stem   = filename.replace(/\.ipynb$/i, '');

        const cells = (notebook.cells || []).map(cell => ({
            cell_type: cell.cell_type,
            source: Array.isArray(cell.source) ? cell.source.join('') : (cell.source || ''),
        }));

        if (isLua) {
            if (typeof core.extractLua !== 'function') {
                // Loud, and specific to Lua. Falling through to the Python
                // extractor would silently produce a `.py` file from a Lua
                // notebook and grade it against a Lua suite — every test
                // failing for a reason no student could act on.
                throw new Error(
                    'This Lua notebook cannot be extracted: the vendored RunnerCore wasm '
                    + 'predates extractLua. Re-vendor Public/runner-wasm '
                    + '(scripts/build-runner-wasm.sh) or grade on the native worker.');
            }
            // Same shared marker-emitting extractor as R, differing only in the
            // comment leader — `extractLua` and `extractR` are both one call to
            // RunnerCore's `extractWithCellMarkers`, so the browser and the
            // native worker cannot drift.
            files[`${stem}.lua`] = core.extractLua(cells, filename).source;
            files['.chickadee_student_module'] = `${stem}.lua`;
            return;
        }

        if (isOctave) {
            if (typeof core.extractOctave !== 'function') {
                // Loud, and specific to Octave — the same one-release-window
                // rule as extractLua above: falling through to the Python
                // extractor would silently produce a `.py` file from an Octave
                // notebook and grade it against an Octave suite.
                throw new Error(
                    'This Octave notebook cannot be extracted: the vendored RunnerCore wasm '
                    + 'predates extractOctave. Re-vendor Public/runner-wasm '
                    + '(scripts/build-runner-wasm.sh) or grade on the native worker.');
            }
            files[`${stem}.m`] = core.extractOctave(cells, filename).source;
            files['.chickadee_student_module'] = `${stem}.m`;
            return;
        }

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
        function extractAsPython() {
            const result = core.extractPython(cells, filename);

            files[`${stem}.py`] = result.executableModule;
            files['.chickadee_student_module'] = `${stem}.py`;

            // Sidecar: the introspectable (un-exec-wrapped) source, so structural /
            // AST NotebookChecks can read real `def`s via student_source().
            files[`${stem}.source.py`] = result.introspectableSource;
            files['.chickadee_student_source'] = `${stem}.source.py`;
        }

        if (isPython) {
            return extractAsPython();
        }

        // Unrecognised kernel. Extraction still has to produce a file in SOME
        // syntax, so it falls back to Python — the same explicit choice the
        // native NotebookExtractor makes (`?? .python`). Written as its own
        // branch rather than left as the shape of the tail, so the fallback is
        // visible where it happens: "we could not tell" and "this is Python"
        // are different facts that used to share one code path here, exactly as
        // they used to share one value in AssignmentLanguage.
        return extractAsPython();
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
    // filename)`, `extractLua(cells, filename)` and `classifyScript(name,
    // source)`, the SAME Swift code the native worker runs. A test harness can preset the `globalThis.runner*`
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
            // Deliberately NOT part of `ready()` above. The vendored wasm is
            // rebuilt by a main-only workflow (runner-wasm-vendor.yml), so
            // between merging a new export and that job committing the
            // artifact there is a window where the checked-in wasm does not
            // register it. Requiring it in `ready()` would make
            // `loadRunnerCore` throw in that window and fail browser grading
            // over to the native worker for EVERY language — right marks, none
            // of the speed — because one language's extractor was missing.
            // Left possibly-undefined here and checked at the one use site,
            // which errors loudly for Lua alone.
            extractLua: globalThis.runnerExtractLua,
            // Same one-release-window rule as extractLua above.
            extractOctave: globalThis.runnerExtractOctave,
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
        if (interp === 'lua') return 'lua';
        if (interp === 'octave') return 'octave';
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

    // test_runtime.lua — mirrors Tools/runner-support/test_runtime.lua (and the
    // testRuntimeLua string in Sources/Worker/TestRuntimeSources.swift). Written
    // into every browser grading workspace alongside the Python and R helpers,
    // for the same reason they are: the assignment's language is not known until
    // after the seed fetch, and a spare copy is a reserved filename every
    // language's submission scanner already skips.
    //
    // Pinned against the canonical file by
    // Tests/BrowserRunnerJSTests/runtime-drift.test.mjs.
    const TEST_RUNTIME_LUA = `\
-- test_runtime.lua — Chickadee Lua test helper library.
-- Require at the top of each Lua test script:
--     local t = require("test_runtime")
--
-- API (a module table, the Lua idiom — R sources a file and Python imports
-- names, but a Lua library that assigned globals would be a surprise):
--   t.passed(message)            — exit 0  (pass)
--   t.failed(message)            — exit 1  (fail)
--   t.errored(message)           — exit 2  (error)
--   t.label()                    — the test's name, from arg[0]
--   t.seed()                     — deterministic per-student integer seed
--   t.inputs()                   — per-student inputs from _ck_inputs.lua
--   t.student_file()             — the submitted .lua file to grade
--   t.load_student()             — that file, loaded into a fresh environment
--   t.require_fn(env, name)      — fetch a function the student had to write
--   t.format(value)              — one-line rendering, for failure messages
--   t.equal(a, b)                — value equality across Lua's number types
--
-- No external dependencies: JSON is hand-formatted, so this works on a bare
-- \`lua\` install and inside the xeus-lua kernel alike.
--
-- WHAT MAKES THIS FILE WORK IN BOTH RUNNERS, which is the whole difficulty.
-- The native runner spawns \`lua publictest_foo.lua\`, so the contract is a
-- PROCESS contract: os.exit sets the status, arg[0] names the script,
-- os.getenv reads the environment. A xeus-lua kernel has none of those — there
-- is no process to exit and no argv. Rather than fork this file, the browser
-- wrapper (Public/lua-grading-shared.js) re-creates that contract inside one
-- Lua session by masking \`os.exit\`, \`os.getenv\` and \`arg\` before the script
-- runs. This file therefore stays byte-identical across both runners, exactly
-- as test_runtime.R does. Do not replace os.exit with a \`return\`-based
-- protocol: under \`lua\` that would exit 0 for a failing test.

local M = {}

local function json_str(value)
    local s = tostring(value)
    s = s:gsub("\\\\", "\\\\\\\\")
    s = s:gsub('"', '\\\\"')
    s = s:gsub("\\n", "\\\\n")
    s = s:gsub("\\r", "\\\\r")
    s = s:gsub("\\t", "\\\\t")
    return '"' .. s .. '"'
end

-- The test's name, as the grader labels it: the script filename without its
-- directory or extension. \`arg\` is what \`lua script.lua\` populates and what
-- the browser wrapper masks, so both runners answer the same thing.
function M.label()
    local path = (type(arg) == "table" and arg[0]) or ""
    local base = path:match("([^/\\\\]+)$") or path
    local stem = base:match("^(.*)%.[^.]*$") or base
    if stem == "" then return "test" end
    return stem
end

-- The script currently executing, with its extension — never mistakable for
-- the student's submission when scanning the working directory.
local function running_script()
    local path = (type(arg) == "table" and arg[0]) or ""
    return path:match("([^/\\\\]+)$") or ""
end

local function emit(status, short_result, err)
    local parts = {
        '"status":' .. json_str(status),
        '"shortResult":' .. json_str(short_result),
        '"test":' .. json_str(M.label()),
    }
    if err ~= nil then
        parts[#parts + 1] = '"error":' .. json_str(err)
    end
    io.write("{" .. table.concat(parts, ",") .. "}\\n")
end

function M.passed(message)
    local msg = message ~= nil and tostring(message) or (M.label() .. ": passed")
    emit("pass", msg)
    os.exit(0)
end

function M.failed(message)
    local msg = tostring(message == nil and "failed" or message)
    emit("fail", M.label() .. ": " .. msg, msg)
    os.exit(1)
end

function M.errored(message)
    local msg = tostring(message == nil and "error" or message)
    emit("error", M.label() .. ": " .. msg, msg)
    os.exit(2)
end

-- --- Value formatting + comparison -----------------------------------------
-- Used by hand-authored tests so failure messages read the same whatever
-- produced them. The Lua analogue of chickadee_format / chickadee_equal in
-- test_runtime.R.

-- One-line, student-readable rendering. Tables are shown one level deep with
-- their array part in order, which is what a test's expected value normally
-- is; anything deeper is elided rather than recursed, so a cyclic table cannot
-- hang the grader.
function M.format(value, max_chars)
    max_chars = max_chars or 300
    local rendered
    if type(value) == "string" then
        rendered = string.format("%q", value)
    elseif type(value) ~= "table" then
        rendered = tostring(value)
    else
        local parts = {}
        for _, item in ipairs(value) do
            parts[#parts + 1] = type(item) == "table" and "{...}" or tostring(item)
        end
        rendered = "{" .. table.concat(parts, ", ") .. "}"
    end
    if #rendered > max_chars then
        return rendered:sub(1, max_chars) .. " ..."
    end
    return rendered
end

-- The stand-in for a JSON null inside a generated table literal.
--
-- Lua has no missing-value scalar, and a bare \`nil\` in a table constructor is
-- not stored at all: \`{60, nil, 20}\` makes \`ipairs\` stop after one element and
-- \`table.concat\` raise, so an authored case's positional alignment is silently
-- lost. A sentinel TABLE is a real value and occupies its slot. This is Lua's
-- answer to the problem R solves with \`NA\` (see \`JSONValue.luaLiteral\`, which
-- emits \`chickadee.NULL\` and is what requires this to exist under that name).
--
-- Compared by identity, so nothing a student can construct is equal to it.
M.NULL = setmetatable({}, { __tostring = function() return "NULL" end })

-- Exact equality, with Lua 5.4's integer/float split handled the way a student
-- would expect: 1 and 1.0 are the same answer. \`==\` already says so for
-- numbers, so the only work is comparing array-like tables element by element.
--
-- \`M.NULL\` is equal only to itself. It must be checked BEFORE the table arm,
-- or two distinct sentinels would compare equal as empty tables — which would
-- be harmless today but wrong the moment a student returned \`{}\`.
function M.equal(actual, expected)
    if actual == M.NULL or expected == M.NULL then
        return rawequal(actual, expected)
    end
    if type(actual) == "table" and type(expected) == "table" then
        if #actual ~= #expected then return false end
        for i = 1, #actual do
            if not M.equal(actual[i], expected[i]) then return false end
        end
        return true
    end
    return actual == expected
end

-- Order-insensitive comparison for the unordered_equality kind: the two arrays
-- hold the same elements in any order. Defined in terms of \`M.equal\`, greedily
-- pairing each actual element with an as-yet-unused expected one — so it can
-- NEVER disagree with \`equal\`, because it IS \`equal\`, applied pairwise.
--
-- The previous version keyed each element through a string rendering and sorted
-- the keys, which was a second, weaker notion of equality living beside the real
-- one. It disagreed with \`equal\` in both directions: {1} vs {1.0} rendered
-- "1" vs "1.0" and failed while equal(1, 1.0) passed; and { {"a, b"} } vs
-- { {"a", "b"} } rendered alike (the comma-join) and passed while they are
-- plainly different. Keying only reached the top level, so nested tables were
-- worse still. Delegating to \`equal\` removes the whole second notion.
--
-- Greedy matching is exact here because \`equal\` is an equivalence relation
-- (exact value equality is transitive): if an actual element equals several
-- expected ones they are mutually equal, so consuming any is safe. O(n^2),
-- which is nothing at the sizes a generated case compares.
function M.unordered_equal(actual, expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        return false
    end
    if #actual ~= #expected then return false end
    local used = {}
    for i = 1, #actual do
        local matched = false
        for j = 1, #expected do
            if not used[j] and M.equal(actual[i], expected[j]) then
                used[j] = true
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return true
end

-- --- Per-student personalization primitives ---------------------------------
-- Mirror of chickadee_seed() in test_runtime.R and the Python equivalent. Lua
-- 5.4 has 64-bit integers but no bignum, so the 256-bit hex seed is folded with
-- Horner's method modulo 2^31-1 — the SAME reduction R uses, so a student's
-- seed is one number whatever language the assignment is in.

function M.seed()
    local raw = os.getenv("CHICKADEE_ASSIGNMENT_SEED") or ""
    local hex = raw:lower():gsub("[^0-9a-f]", "")
    if hex == "" then return 0 end
    local modulus = 2147483647  -- 2^31 - 1; intermediates stay well inside 2^53
    local acc = 0
    for i = 1, #hex do
        acc = (acc * 16 + tonumber(hex:sub(i, i), 16)) % modulus
    end
    return math.tointeger(acc) or acc
end

-- The per-student grading inputs the worker materialized into _ck_inputs.lua
-- (a chunk returning a table), or an empty table when none were delivered.
-- The chunk is loaded with \`chickadee\` bound, because the values in it were
-- rendered by \`JSONValue.luaLiteral\`, which spells a JSON null inside a table
-- as the sentinel \`chickadee.NULL\` (Lua stores no \`nil\` in a constructor, so a
-- hole would silently eat an authored case's positional alignment).
--
-- Binding it HERE rather than making the file \`require\` the runtime itself
-- keeps \`_ck_inputs.lua\` a pure data chunk with no dependencies — which is what
-- lets the conformance matrix write one into an empty directory and read it
-- back. Without the binding a single null makes the chunk raise, \`pcall\`
-- swallows it, this returns \`{}\`, and every per-student value silently reads as
-- missing: a wrong mark rather than a crash.
function M.inputs()
    local env = setmetatable({ chickadee = M }, { __index = _G })
    local chunk = loadfile("_ck_inputs.lua", "t", env)
    if not chunk then return {} end
    local ok, value = pcall(chunk)
    if ok and type(value) == "table" then return value end
    return {}
end

-- --- Locating the student's submission --------------------------------------
-- Filenames Chickadee itself writes into the grading workspace are never the
-- student's submission.
local RESERVED = { ["test_runtime.lua"] = true, ["_ck_inputs.lua"] = true }

local function is_test_file(name)
    return name:match("^publictest") ~= nil
        or name:match("^releasetest") ~= nil
        or name:match("^secrettest") ~= nil
        or name:match("^studenttest") ~= nil
end

-- The student's submitted Lua file: solution.lua during validation, the
-- extracted notebook during grading.
--
-- Unlike R and Python, this reads ONLY the runner's \`.chickadee_student_module\`
-- hint, with \`solution.lua\` as the fallback. Lua's standard library cannot list
-- a directory — there is no \`list.files\` and no \`os.listdir\`, and \`io.popen\`
-- is a subprocess the wasm kernel does not have — so the scan those two fall
-- back to has no Lua equivalent. The hint is written by the runner on every
-- job, so this is the normal path rather than a degraded one.
function M.student_file()
    local hint = io.open(".chickadee_student_module", "r")
    if hint then
        local named = (hint:read("l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        hint:close()
        local base = named:match("([^/\\\\]+)$") or named
        if base:match("%.lua$") and not RESERVED[base] and not is_test_file(base)
            and base ~= running_script() then
            local exists = io.open(base, "r")
            if exists then
                exists:close()
                return base
            end
        end
    end
    local fallback = io.open("solution.lua", "r")
    if fallback then
        fallback:close()
        return "solution.lua"
    end
    return nil
end

-- Load the submission into a fresh environment, so the tests see exactly what
-- the student defined and nothing they defined can overwrite the harness.
--
-- Runtime errors are swallowed deliberately: a submission whose last top-level
-- line raises has still defined every function above it, and those are what the
-- tests are about. Compare test_runtime.R, which evaluates expression by
-- expression for the same reason.
function M.load_student()
    local file = M.student_file()
    if not file then
        M.errored("No Lua submission file was found to grade.")
    end
    local env = setmetatable({}, { __index = _G })
    local chunk, err = loadfile(file, "t", env)
    if not chunk then
        M.errored("Your submission (" .. file .. ") could not be parsed as Lua: " .. tostring(err))
    end
    pcall(chunk)
    return env
end

-- The submission split into notebook cells, for source-level checks.
--
-- \`extractLua\` writes an inert \`-- ---- chickadee:cell N ----\` comment ahead of
-- each cell, which is what gives a source-level check cell granularity that
-- plain concatenation loses. Same design as chickadee_student_cells in
-- test_runtime.R, down to the marker text — only the comment leader differs,
-- which is why both extractors share \`extractWithCellMarkers\`.
--
-- A submission that never came from a notebook (a hand-written .lua upload) has
-- no markers, so the whole file comes back as one cell — file granularity,
-- which is the honest answer for a file with no cells.
function M.student_cells()
    local file = M.student_file()
    if not file then
        M.errored("No Lua submission file was found to grade.")
    end
    local handle = io.open(file, "r")
    if not handle then return {} end
    local text = handle:read("a") or ""
    handle:close()

    -- Split without inventing a trailing empty line. Appending "\\n" and
    -- matching greedily does invent one, which put a stray newline on the end
    -- of the LAST cell only — so a \`cellContains\` check comparing exact source
    -- would behave differently for the final cell than for every other one.
    local lines = {}
    local pos = 1
    while pos <= #text do
        local nl = text:find("\\n", pos, true)
        if nl then
            lines[#lines + 1] = text:sub(pos, nl - 1)
            pos = nl + 1
        else
            lines[#lines + 1] = text:sub(pos)
            pos = #text + 1
        end
    end

    local cells, current, seen_marker = {}, nil, false
    for _, line in ipairs(lines) do
        if line:match("^%-%- ---- chickadee:cell %d+ ----$") then
            if current then cells[#cells + 1] = table.concat(current, "\\n") end
            current, seen_marker = {}, true
        elseif current then
            current[#current + 1] = line
        end
    end
    if current then cells[#cells + 1] = table.concat(current, "\\n") end
    if not seen_marker then return { (text:gsub("\\n$", "")) } end
    return cells
end

-- Fetch a function the student was asked to write; a clear error when it is
-- missing or was bound to something that is not a function.
function M.require_fn(env, name)
    local value = rawget(env, name)
    if type(value) ~= "function" then
        M.errored(string.format("Your submission must define a function called \`%s()\`.", name))
    end
    return value
end

return M
`;

    // test_runtime.m — mirrors Tools/runner-support/test_runtime.m (and the
    // testRuntimeOctave string in Sources/Worker/TestRuntimeSources.swift).
    // Written into every browser grading workspace alongside the other
    // languages' helpers, for the same reason: the assignment's language is
    // not known until after the seed fetch, and a spare copy is a reserved
    // filename every language's submission scanner already skips.
    //
    // Pinned against the canonical file by
    // Tests/BrowserRunnerJSTests/runtime-drift.test.mjs.
    const TEST_RUNTIME_OCTAVE = `\
% test_runtime.m — Chickadee Octave test helper library.
% Obtain at the top of each Octave test script:
%     chickadee = test_runtime();
%
% API (a struct of function handles — Octave's one-function-per-file rule
% means separate helpers would each need their own file, and the runner
% injects exactly one; a handle struct is the idiomatic single-file namespace):
%   chickadee.passed(message)        — exit 0  (pass)
%   chickadee.failed(message)        — exit 1  (fail)
%   chickadee.errored(message)       — exit 2  (error)
%   chickadee.label()                — the test's name, from program_name()
%   chickadee.seed()                 — deterministic per-student integer seed
%   chickadee.inputs()               — per-student inputs from _ck_inputs.m
%   chickadee.student_file()         — the submitted .m file to grade
%   chickadee.load_student()         — that file, loaded; returns an env struct
%   chickadee.require_fn(env, name)  — a function the student had to write
%   chickadee.has_var(env, name)     — is a workspace variable defined?
%   chickadee.get_var(env, name)     — that variable's value
%   chickadee.student_cells()        — submission split into notebook cells
%   chickadee.format(value)          — one-line rendering, for failure messages
%   chickadee.equal(a, b)            — value equality (see below)
%   chickadee.unordered_equal(a, b)  — same elements, any order
%
% No package dependencies: JSON is hand-formatted, so this works on a bare
% \`octave-cli\` install and inside the xeus-octave kernel alike.
%
% WHAT MAKES THIS FILE WORK IN BOTH RUNNERS. The native runner spawns
% \`octave-cli publictest_foo.m\`, so the contract is a PROCESS contract:
% exit() sets the status, program_name() names the script, getenv reads the
% environment. A xeus-octave kernel has none of those — there is no process to
% exit. The browser wrapper (Public/octave-grading-shared.js) re-creates the
% contract inside one session by masking \`exit\`/\`quit\` and \`program_name\`
% (command-line functions shadow builtins) before any script runs. This file
% resolves all three by NAME at call time, so the masks are what its helpers
% reach and the canonical copy stays byte-identical across both runners. Do
% not replace exit() with a return-based protocol: under \`octave-cli\` that
% would exit 0 for a failing test.
%
% THE SUBMISSION CONTRACT (the function-file/script-file question, decided):
% a submission is loaded by evaluating its text prefixed with \`1;\`, which
% forces Octave to read it as a SCRIPT whatever its first token is. That one
% rule covers all three shapes a student can hand in:
%   * a flattened notebook (statements + \`function\` definitions in any order),
%   * a hand-written script,
%   * a traditional one-function-per-file submission — the \`1;\` prefix stops
%     Octave treating the FILE as the function, so the definition registers
%     under its own name (\`function r = classify(x)\` defines \`classify\`
%     whatever the file is called, where file-based resolution would have
%     bound it to the filename).
% Functions defined this way are command-line functions (exist() == 103),
% fetched with str2func by require_fn. Variables land in the loader's private
% workspace and are captured into the returned env struct. A runtime error
% mid-file keeps everything defined before it, matching the R runtime's
% expression-by-expression tolerance for the common shape (working functions
% above, a stray failing call below); definitions after the error are lost,
% which R's loader would have kept — a smaller promise, stated honestly.

function M = test_runtime()
    M = struct( ...
        "passed", @ck_passed, ...
        "failed", @ck_failed, ...
        "errored", @ck_errored, ...
        "label", @ck_label, ...
        "seed", @ck_seed, ...
        "inputs", @ck_inputs, ...
        "student_file", @ck_student_file, ...
        "load_student", @ck_load_student, ...
        "require_fn", @ck_require_fn, ...
        "has_var", @ck_has_var, ...
        "get_var", @ck_get_var, ...
        "student_cells", @ck_student_cells, ...
        "format", @ck_format, ...
        "equal", @ck_equal, ...
        "unordered_equal", @ck_unordered_equal);
end

function s = ck_json_str(value)
    s = num2str(value);
    if ischar(value)
        s = value;
    end
    s = strrep(s, "\\\\", "\\\\\\\\");
    s = strrep(s, "\\"", "\\\\\\"");
    s = strrep(s, sprintf("\\n"), "\\\\n");
    s = strrep(s, sprintf("\\r"), "\\\\r");
    s = strrep(s, sprintf("\\t"), "\\\\t");
    s = ["\\"" s "\\""];
end

% The test's name, as the grader labels it: the script filename without its
% directory or extension. program_name() is what \`octave-cli script.m\`
% populates and what the browser wrapper masks, so both runners answer the
% same thing.
function name = ck_label()
    path = program_name();
    [~, stem, ~] = fileparts(path);
    if isempty(stem)
        name = "test";
    else
        name = stem;
    end
end

% The script currently executing, with its extension — never mistakable for
% the student's submission.
function name = ck_running_script()
    path = program_name();
    [~, stem, ext] = fileparts(path);
    name = [stem ext];
end

function ck_emit(status, short_result, err)
    parts = { ...
        ["\\"status\\":" ck_json_str(status)], ...
        ["\\"shortResult\\":" ck_json_str(short_result)], ...
        ["\\"test\\":" ck_json_str(ck_label())]};
    if nargin >= 3 && !isempty(err)
        parts{end + 1} = ["\\"error\\":" ck_json_str(err)];
    end
    printf("{%s}\\n", strjoin(parts, ","));
end

function ck_passed(message)
    if nargin < 1 || isempty(message)
        message = [ck_label() ": passed"];
    end
    ck_emit("pass", message);
    exit(0);
end

function ck_failed(message)
    if nargin < 1 || isempty(message)
        message = "failed";
    end
    ck_emit("fail", [ck_label() ": " message], message);
    exit(1);
end

function ck_errored(message)
    if nargin < 1 || isempty(message)
        message = "error";
    end
    ck_emit("error", [ck_label() ": " message], message);
    exit(2);
end

% --- Value formatting + comparison ------------------------------------------
% Used by generated pattern-family tests (and available to hand-authored ones)
% so failure messages read the same whatever produced them.

% One-line, student-readable rendering — the Octave analogue of Python's
% repr(). mat2str handles numeric/logical/char matrices; cells are shown one
% level deep; a containers.Map shows its keys. Anything deeper or unprintable
% is elided rather than recursed, so a cyclic struct cannot hang the grader.
function s = ck_format(value, max_chars)
    if nargin < 2
        max_chars = 300;
    end
    s = ck_format_value(value);
    if numel(s) > max_chars
        s = [s(1:max_chars) " ..."];
    end
end

function s = ck_format_value(value)
    if ischar(value)
        s = ["\\"" value "\\""];
    elseif isa(value, "containers.Map")
        keys_list = value.keys();
        parts = cell(1, numel(keys_list));
        for i = 1:numel(keys_list)
            parts{i} = [keys_list{i} ": " ck_format_scalar(value(keys_list{i}))];
        end
        s = ["{" strjoin(parts, ", ") "}"];
    elseif iscell(value)
        parts = cell(1, numel(value));
        for i = 1:numel(value)
            parts{i} = ck_format_scalar(value{i});
        end
        s = ["{" strjoin(parts, ", ") "}"];
    elseif isnumeric(value) || islogical(value)
        s = mat2str(value);
    elseif isstruct(value)
        s = ["<struct with fields: " strjoin(fieldnames(value)', ", ") ">"];
    elseif is_function_handle(value)
        s = func2str(value);
    else
        s = ["<" class(value) ">"];
    end
end

function s = ck_format_scalar(value)
    if iscell(value) || isstruct(value)
        s = "{...}";
    else
        s = ck_format_value(value);
    end
end

% Value equality for generated tests. Built on isequaln — NOT isequal or a
% string rendering — for three measured reasons:
%   * a JSON null renders as NA (NaN-flavoured), and isequal(NA, NA) is
%     false; isequaln treats missing-vs-missing as equal, which is what an
%     authored [60, null, 20] case needs;
%   * isequaln is type-blind across logical/int/double (isequal(1, true) and
%     isequal(int32(1), 1.0) are both true), which matches how Octave's own
%     \`==\` treats those values and what a student can observe;
%   * it recurses into cells and containers.Map by content.
% On top of isequaln, two Chickadee rules:
%   * both-empty is equal whatever the container class: the literal renderer
%     spells an empty JSON array \`{}\` (nothing says what it would have held),
%     while a student computing an empty result usually produces \`[]\` — and
%     \`""\` is the same absence in char form. isequal([], {}) is false, so
%     without this rule every empty-expected case would fail on container
%     kind, a distinction the assignment's JSON never drew.
%   * numeric/logical values with equal element counts compare shape-blind
%     (a(:) vs b(:)): the renderer emits JSON arrays as row vectors, while
%     student arithmetic freely produces columns. R's \`==\`-with-all() does
%     the same via recycling, so the two languages agree.
function r = ck_equal(actual, expected)
    if isempty(actual) && isempty(expected)
        r = true;
        return;
    end
    numeric_like = @(v) (isnumeric(v) || islogical(v)) && !isa(v, "containers.Map");
    if numeric_like(actual) && numeric_like(expected)
        r = numel(actual) == numel(expected) && isequaln(actual(:), expected(:));
        return;
    end
    if iscell(actual) && iscell(expected)
        if numel(actual) != numel(expected)
            r = false;
            return;
        end
        for i = 1:numel(actual)
            if !ck_equal(actual{i}, expected{i})
                r = false;
                return;
            end
        end
        r = true;
        return;
    end
    r = isequaln(actual, expected);
end

% Order-insensitive comparison for the unordered_equality kind: the two
% collections hold the same elements in any order. Defined by greedy pairwise
% ck_equal — so it can NEVER disagree with \`equal\`, because it IS \`equal\`
% applied pairwise (the F3 lesson from the Lua audit: a second, weaker notion
% of equality beside the real one disagreed with it in both directions).
% Numeric vectors and cell arrays are both accepted; each is viewed as a list
% of elements first.
function r = ck_unordered_equal(actual, expected)
    a = ck_as_element_list(actual);
    b = ck_as_element_list(expected);
    if isempty(a) || isempty(b)
        r = isempty(a) && isempty(b);
        return;
    end
    if numel(a) != numel(b)
        r = false;
        return;
    end
    used = false(1, numel(b));
    for i = 1:numel(a)
        matched = false;
        for j = 1:numel(b)
            if !used(j) && ck_equal(a{i}, b{j})
                used(j) = true;
                matched = true;
                break;
            end
        end
        if !matched
            r = false;
            return;
        end
    end
    r = true;
end

function list = ck_as_element_list(value)
    if iscell(value)
        list = value(:)';
    elseif isnumeric(value) || islogical(value)
        list = num2cell(value(:)');
    else
        list = {value};
    end
end

% --- Per-student personalization primitives ---------------------------------
% Mirror of OctavePersonalizationRuntime.chickadeeSeedOctaveSource in
% Sources/Core — the server-side expression driver composes the same body, so
% the seed it binds and the seed this reads are computed identically. Octave
% has no bignum, so the 256-bit hex seed is folded with Horner's method modulo
% 2^31-1 — the SAME reduction R and Lua use, so a student's seed is one number
% whatever language the assignment is in. Every intermediate stays below 2^35,
% safely inside a double.

function value = ck_seed()
    raw = getenv("CHICKADEE_ASSIGNMENT_SEED");
    hex = lower(raw(isstrprop(raw, "xdigit")));
    if isempty(hex)
        value = 0;
        return;
    end
    modulus = 2147483647;
    acc = 0;
    for i = 1:numel(hex)
        acc = mod(acc * 16 + hex2dec(hex(i)), modulus);
    end
    value = acc;
end

% The per-student grading inputs the worker materialized into _ck_inputs.m
% (two parallel cell arrays, names and values), as a containers.Map — or an
% empty Map when none were delivered. The file is EVALUATED from its text
% rather than run by name, so its leading-underscore filename never has to be
% resolvable as a function and the same read works in both runners.
function map = ck_inputs()
    map = containers.Map();
    if exist("_ck_inputs.m", "file") != 2
        return;
    end
    ck_input_names = {};
    ck_input_values = {};
    try
        eval(fileread("_ck_inputs.m"));
    catch
        return;
    end
    for i = 1:min(numel(ck_input_names), numel(ck_input_values))
        map(ck_input_names{i}) = ck_input_values{i};
    end
end

% --- Locating the student's submission --------------------------------------
% Filenames Chickadee itself writes into the grading workspace are never the
% student's submission.

function r = ck_is_reserved(name)
    r = any(strcmp(name, {"test_runtime.m", "_ck_inputs.m"}));
end

function r = ck_is_test_file(name)
    r = !isempty(regexp(name, "^(publictest|releasetest|secrettest|studenttest)", "once"));
end

% The student's submitted Octave file: solution.m during validation, the
% extracted notebook during grading. Prefers the runner's
% \`.chickadee_student_module\` hint when it names an .m file actually present,
% then falls back to scanning the working directory (readdir works in both
% runners, unlike Lua whose standard library cannot list a directory).
% Returns "" when nothing looks like a submission.
function file = ck_student_file()
    file = "";
    hinted = "";
    if exist(".chickadee_student_module", "file") == 2
        try
            hinted = strtrim(fileread(".chickadee_student_module"));
        catch
            hinted = "";
        end
        newline_at = find(hinted == sprintf("\\n"), 1);
        if !isempty(newline_at)
            hinted = strtrim(hinted(1:newline_at - 1));
        end
    end
    if !isempty(hinted)
        [~, stem, ext] = fileparts(hinted);
        base = [stem ext];
        if strcmpi(ext, ".m") && !ck_is_reserved(base) && !ck_is_test_file(base) ...
            && !strcmp(base, ck_running_script()) && exist(base, "file") == 2
            file = base;
            return;
        end
    end
    entries = sort(cellstr(readdir(pwd())));
    candidates = {};
    for i = 1:numel(entries)
        name = entries{i};
        [~, ~, ext] = fileparts(name);
        if !strcmpi(ext, ".m")
            continue;
        end
        if ck_is_reserved(name) || ck_is_test_file(name) || strcmp(name, ck_running_script())
            continue;
        end
        candidates{end + 1} = name;
    end
    if isempty(candidates)
        return;
    end
    if any(strcmp(candidates, "solution.m"))
        file = "solution.m";
        return;
    end
    file = candidates{1};
end

% Load the submission. See "THE SUBMISSION CONTRACT" in the header: the text
% is evaluated with a \`1;\` prefix so every submission shape reads as a script,
% its function definitions register under their own names, and its variables
% land here — captured into the returned env struct. A runtime error mid-file
% keeps everything defined before it.
function env = ck_load_student()
    ck_file_ = ck_student_file();
    if isempty(ck_file_)
        ck_errored("No Octave submission file was found to grade.");
    end
    ck_text_ = fileread(ck_file_);
    env = struct("file", ck_file_, "vars", struct());
    try
        eval(["1;" sprintf("\\n") ck_text_]);
    catch ck_err_
        % A parse error means nothing was defined; a runtime error partway is
        % the tolerated shape. Distinguishing them is not worth a parser: if
        % no function or variable materialised at all, report the message.
        ck_defined_ = setdiff(who(), ...
            {"ck_file_", "ck_text_", "ck_err_", "ck_defined_", "env"});
        if isempty(ck_defined_)
            ck_errored(["Your submission (" ck_file_ ") could not be run as Octave: " ...
                ck_err_.message]);
        end
    end
    ck_names_ = setdiff(who(), {"ck_file_", "ck_text_", "ck_err_", "ck_defined_", "env"});
    for ck_i_ = 1:numel(ck_names_)
        env.vars.(ck_names_{ck_i_}) = eval(ck_names_{ck_i_});
    end
end

% Fetch a function the student was asked to write; a clear error when it is
% missing or bound to something that is not callable. Checks the submission's
% own variables first (a handle assigned with \`f = @(x) ...\`), then the
% command-line functions its definitions registered.
function fn = ck_require_fn(env, name)
    if isfield(env.vars, name)
        candidate = env.vars.(name);
        if is_function_handle(candidate)
            fn = candidate;
            return;
        end
        ck_errored(sprintf( ...
            "Your submission must define a function called \`%s()\` (found a %s).", ...
            name, class(candidate)));
    end
    kind = exist(name);
    if any(kind == [2, 3, 5, 103])
        fn = str2func(name);
        return;
    end
    ck_errored(sprintf("Your submission must define a function called \`%s()\`.", name));
end

function r = ck_has_var(env, name)
    r = isfield(env.vars, name);
end

function value = ck_get_var(env, name)
    value = env.vars.(name);
end

% The submission split into notebook cells, for source-level checks.
% \`extractOctave\` writes an inert \`% ---- chickadee:cell N ----\` comment ahead
% of each cell — same design as R and Lua, only the comment leader differs. A
% submission that never came from a notebook has no markers, so the whole file
% comes back as one cell: file granularity, the honest answer for a file with
% no cells.
function cells = ck_student_cells()
    file = ck_student_file();
    if isempty(file)
        ck_errored("No Octave submission file was found to grade.");
    end
    text = fileread(file);
    lines = strsplit(text, sprintf("\\n"), "CollapseDelimiters", false);
    cells = {};
    current = {};
    seen_marker = false;
    started = false;
    for i = 1:numel(lines)
        line = lines{i};
        if !isempty(regexp(line, "^% ---- chickadee:cell [0-9]+ ----$", "once"))
            if started
                cells{end + 1} = strjoin(current, sprintf("\\n"));
            end
            current = {};
            started = true;
            seen_marker = true;
        elseif started
            current{end + 1} = line;
        end
    end
    if started
        cells{end + 1} = strjoin(current, sprintf("\\n"));
    end
    if !seen_marker
        whole = text;
        if !isempty(whole) && whole(end) == sprintf("\\n")
            whole = whole(1:end - 1);
        end
        cells = {whole};
        return;
    end
    for i = 1:numel(cells)
        cells{i} = regexprep(cells{i}, "\\\\s+$", "");
    end
end
`;

    const testHooks = globalThis.__CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__;
    if (testHooks) {
        testHooks.exports = {
            // Embedded runtime sources, exposed so the drift test can assert
            // they stay in sync with Tools/runner-support/*.py.
            TEST_RUNTIME_PY,
            SITECUSTOMIZE_PY,
            TEST_RUNTIME_R,
            TEST_RUNTIME_LUA,
            TEST_RUNTIME_OCTAVE,
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
