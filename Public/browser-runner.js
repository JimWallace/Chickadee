// Public/browser-runner.js
//
// Chickadee browser-side WASM runner for labs (gradingMode: "browser").
//
// Submit-triggered (not polling): notebook.js calls window.BrowserRunner.runAndSubmit()
// when the student clicks Submit.  Tests run locally on xeus kernels in Web
// Workers; the notebook bytes and TestOutcomeCollection are submitted to the
// server in one atomic call.
//
// Workflow:
//   1. Fetch test setup zip from /api/v1/browser-runner/testsetups/:id/download
//   2. Unpack zip into a file map that each kernel writes to its own filesystem
//   3. Write the test_runtime helper libraries
//   4. Write notebook bytes and extract the code cells through RunnerCore
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
// All are Web Workers running a xeus kernel.  Each one is the SAME environment
// the notebook editor boots for that language, so "it ran in the editor"
// implies "it grades here".  Only the substrates an assignment actually needs
// are booted, so an R lab never pays for the Python env (and vice versa).
// Shell scripts (.sh) are not supported in the browser environment on any
// substrate.

(function () {
    'use strict';

    const scriptEl    = document.currentScript;
    const gradingMode = scriptEl ? scriptEl.dataset.gradingMode : null;

    // Only expose browser runner for browser-graded assignments.
    if (gradingMode !== 'browser') return;

    const statusEl = document.getElementById('browser-runner-status');
    if (statusEl) statusEl.hidden = false;

    // Public/grading-shared.js is a <script> tag before this file on the
    // notebook page (see _notebook-body.leaf).  The grading workers use it;
    // this file does not call into it.  The exit-code mapping is only
    // re-exported on the test hooks below.  Throws loudly here if the tag is
    // missing.
    const { deriveExitCode } = ChickadeeGradingShared;
    const {
        makeGradingExecutors, fileAsText, interpreterToKind, scriptExtension, toMessage,
    } = ChickadeeGradingExecutors;

    // The per-student inputs file renderers for R, Lua and Octave.  Each comes
    // from that language's grading-shared.js, which its grading worker also
    // loads.  Loaded by <script> tags alongside grading-shared.js (see
    // _notebook-body.leaf).
    const { personalizationInputsSourceR } = ChickadeeRGradingShared;
    const { personalizationInputsSourceLua } = ChickadeeLuaGradingShared;
    const { personalizationInputsSourceOctave } = ChickadeeOctaveGradingShared;

    // The runtime helpers that every grading workspace gets, by filename: each
    // file in Tools/runner-support/ that the native runner compiles in, byte
    // for byte. scripts/generate-js-constants.sh writes
    // Public/runner-support-sources.js, and a <script> tag loads it before
    // this file (see _notebook-body.leaf). Throws loudly here if the tag is
    // missing.
    const RUNTIME_HELPER_SOURCES = ChickadeeRunnerSupportSources;

    // Which renderer writes the per-student inputs file, by language token.
    //
    // The RENDERER is genuinely per-language — four different wrappers around
    // values the server already rendered as literals. The FILENAME is not:
    // that is `LanguageDescriptor.inputsFileName`, generated below. Keeping the
    // two apart is the point. They were one hand-written pair of strings, and a
    // browser-graded Lua assignment wrote `_ck_inputs.py` while the Lua runtime
    // read `_ck_inputs.lua` — every per-student value silently missing, no
    // error anywhere.
    //
    // Keyed by the four languages with an editor kernel, which are exactly the
    // languages a browser grades. `BrowserInputsWriterCoverageTests` fails if
    // that stops being true — a fifth kernel language missing from here would
    // fall back to Python's writer and reproduce the Lua bug exactly.
    const INPUTS_WRITERS = {
        python: personalizationInputsSource,
        r: personalizationInputsSourceR,
        lua: personalizationInputsSourceLua,
        octave: personalizationInputsSourceOctave,
    };

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
    const GRADED_SCRIPT_EXTENSIONS = ['.cpp', '.h', '.hpp', '.java', '.lua', '.m', '.py', '.r', '.rkt'];
    // CHICKADEE_GENERATED:GRADED_SCRIPT_EXTENSIONS:END

    // The per-student inputs file each language's test_runtime reads. A
    // GENERATED copy of LanguageDescriptor.inputsFileName, keyed by the enum
    // case — which is the token the seed endpoint reports, so the lookup needs
    // no translation. Same rule as above: edit the Swift literal and re-run the
    // script, never this line. Every language is emitted, including the
    // upload-only ones a browser never grades; deciding here which languages
    // "matter" would be one more list to keep current.
    // CHICKADEE_GENERATED:INPUTS_FILE_NAMES:BEGIN
    const INPUTS_FILE_NAMES = { cpp: '_ck_inputs.hpp', java: '_ck_inputs.java', lua: '_ck_inputs.lua', octave: '_ck_inputs.m', python: '_ck_inputs.py', r: '_ck_inputs.R', racket: '_ck_inputs.rkt' };
    // CHICKADEE_GENERATED:INPUTS_FILE_NAMES:END

    // The Web Worker that grades each kernel language. A GENERATED copy of
    // `EditorSupport.notebookKernel`'s `gradingWorkerScript`, keyed by the enum
    // case — which is also the substrate kind `interpreterToKind` computes, so
    // the router looks a worker up by the value it already has.
    //
    // Same rule as the tables above: edit the Swift literal and re-run
    // scripts/generate-js-constants.sh, never this line. Only kernel languages
    // appear; an upload-only language has no worker because it has no kernel,
    // and `executorForKind` answering null for one is exactly right.
    //
    // The other half of this fact is `NotebookAssetIsolationMiddleware
    // .isolatedWorkerScripts`, which now derives from the same descriptor
    // field. Those two lists were hand-written and unconnected, and the
    // allowlist half fails SILENTLY when it is short: the browser refuses the
    // script on an isolated page, ensureReady throws, and the grade quietly
    // fails over to the native worker (#1274).
    // How each language is spelled to a student, from
    // `LanguageDescriptor.displayName`. The raw value is a wire token, so
    // "r grading needs Web Worker support" would read like a typo.
    // CHICKADEE_GENERATED:LANGUAGE_LABELS:BEGIN
    const LANGUAGE_LABELS = { cpp: 'C++', java: 'Java', lua: 'Lua', octave: 'Octave', python: 'Python', r: 'R', racket: 'Racket' };
    // CHICKADEE_GENERATED:LANGUAGE_LABELS:END

    // CHICKADEE_GENERATED:GRADING_WORKER_SCRIPTS:BEGIN
    const GRADING_WORKER_SCRIPTS = { lua: '/lua-grading-worker.js', octave: '/octave-grading-worker.js', python: '/python-grading-worker.js', r: '/r-grading-worker.js' };
    // CHICKADEE_GENERATED:GRADING_WORKER_SCRIPTS:END

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
            throw new Error('Failed to load ZIP library: ' + toMessage(e), { cause: e });
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
        // The heavy kernel boot happens inside the executor (the worker's init)
        // and is covered by the suite_started → suite_done window, so a boot
        // hang shows up as "stuck after suite_started" rather than disappearing
        // before runtime_loaded.
        if (options.reportPhase) options.reportPhase('runtime_loaded');

        // 1. Download and unpack the test setup zip into a plain JS file map
        //    { <relativePath>: <string|Uint8Array> }. This is the canonical
        //    workspace; each grading worker materializes it into its kernel's
        //    filesystem.
        setRunnerStatus('loading', 'Fetching test setup…');
        let setupZip;
        try {
            setupZip = await fetchBytes(`/api/v1/browser-runner/testsetups/${setupID}/download`);
        } catch (e) {
            throw new Error('Failed to download test setup: ' + toMessage(e), { cause: e });
        }
        let zip;
        try {
            zip = await JSZip.loadAsync(setupZip);
        } catch (e) {
            throw new Error('Failed to unpack test setup zip: ' + toMessage(e), { cause: e });
        }

        const files = {};  // relativePath -> string | Uint8Array
        for (const [name, file] of Object.entries(zip.files)) {
            if (file.dir) continue;
            files[name] = await file.async('uint8array');
        }
        if (options.reportPhase) options.reportPhase('setup_unpacked');

        // 2. Runtime helper libraries. Every helper in the generated map is
        //    written unconditionally, and none can be mistaken for a
        //    submission. A kernel language's own helper is a reserved filename
        //    in its own scanner (test_runtime.R is in test_runtime.R's
        //    `.chickadee_reserved_files`, test_runtime.lua in test_runtime.lua's
        //    RESERVED set, test_runtime.m in `ck_is_reserved`; the .py helpers
        //    are in the Python scanner's skip set). The C++, Java and Racket
        //    helpers have extensions that no kernel scanner reads. That keeps
        //    the workspace independent of detecting the assignment's language,
        //    which matters because the language is only known after the seed
        //    fetch below. The native runner writes all of them unconditionally
        //    too, but for the opposite reason: it builds one workspace before
        //    any script is classified.
        for (const [name, source] of Object.entries(RUNTIME_HELPER_SOURCES)) {
            files[name] = source;
        }

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
        // The assignment's language, as the SERVER resolved it. NULL until the
        // server says otherwise, which is the distinction that matters: "the
        // assignment declares Python" and "nobody told us" were the same value
        // when this defaulted to `'python'`, and that is the shape every silent
        // misroute in this area has come from.
        //
        // It decides which inputs file the per-student values land in, and
        // which substrate `ensureReady` boots. Which substrate RUNS a given
        // script is still decided per script by RunnerCore's classification,
        // exactly as the native worker does it.
        let assignmentLanguage = null;
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
            // Python on an unrecognised token, unchanged. It is unreachable in a
            // consistent deployment — this file is served by the same build that
            // resolved the language — and the coverage test is what keeps a new
            // kernel language from reaching it.
            // Python on an unrecognised OR absent token — unchanged behaviour,
            // now written out because `assignmentLanguage` can be null.
            const language = INPUTS_WRITERS[assignmentLanguage] ? assignmentLanguage : 'python';
            files[INPUTS_FILE_NAMES[language]] = INPUTS_WRITERS[language](personalizedInputs);
        }

        // 4. Fetch manifest from server (test.properties.json is not in the zip;
        //    the server serves it directly from the database via the manifest endpoint).
        setRunnerStatus('loading', 'Loading test configuration…');
        let manifest;
        try {
            const manifestText = await fetchText(`/api/v1/browser-runner/testsetups/${setupID}/manifest`);
            manifest = JSON.parse(manifestText);
        } catch (e) {
            throw new Error('Failed to load test configuration: ' + toMessage(e), { cause: e });
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

        // 5. Pick the executor. Every substrate runs its kernel in a Web Worker,
        //    off the main thread, so a CPU-bound infinite loop in student code
        //    (which never yields to JS) can be killed via Worker.terminate()
        //    when the per-test timeout fires. A browser with no Worker fails
        //    the grade over to the native worker (see executorForKind).
        const executor = makeExecutor(
            files, assignmentSeed, runnerCore, options.reportPhase, suites, assignmentLanguage);
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
            // a required substrate can't initialize at all — a kernel that never
            // boots, or a browser with no Worker — abort the whole grade by
            // THROWING here, so submitBrowserNotebook's catch (notebook.js)
            // fails the submission over to server-side grading
            // (/submissions/browser-failover → the native worker backstop).
            // Without this probe the failure is invisible to the caller: the
            // shared RunnerCore wasm catches each rejected run() and returns an
            // exit-2 `error` ScriptOutput
            // (wasm/Sources/RunnerWasm/main.swift, "browser executor: script run
            // rejected"), so executeSuites COMPLETES with an all-`error`
            // collection that runAndSubmit then posts as a real 0% result — the
            // failover never fires and the student is recorded a 0. A per-script
            // error after a HEALTHY init still flows through as a normal error
            // outcome, unchanged — only a substrate that can't start fails over.
            try {
                await executor.ensureReady();
            } catch (e) {
                throw new Error('Browser grading runtime failed to initialize: ' + toMessage(e), { cause: e });
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
    // Executors (Public/grading-executors.js)
    // -------------------------------------------------------------------------

    // The three executor classes and the script helpers live in
    // grading-executors.js (#1965). The router needs two of the generated
    // tables above, so the classes are built over them here; the tables stay
    // in this file, where generate-js-constants.sh and the drift tests read
    // them.
    const { RoutingExecutor, UnavailableExecutor, GradingWorkerExecutor, makeExecutor } =
        makeGradingExecutors({
            workerScripts: GRADING_WORKER_SCRIPTS,
            languageLabels: LANGUAGE_LABELS,
        });

    // -------------------------------------------------------------------------
    // Status display
    // -------------------------------------------------------------------------

    function setRunnerStatus(type, msg) {
        if (!statusEl) return;
        statusEl.textContent = msg;
        statusEl.className   = `nb-status${type ? ' nb-status-' + type : ''}`;
    }

    // -------------------------------------------------------------------------
    // Notebook extraction (RunnerCore, shared with the native worker)
    // -------------------------------------------------------------------------

    // Notebook extraction into a plain file map { <relativePath>: <string> }.
    // runScripts adds the result to the workspace, and each grading worker
    // writes that workspace into its kernel's filesystem. Every language
    // extracts through the shared RunnerCore wasm (already loaded as `core`):
    // extractPython, extractR, extractLua or extractOctave — the same Swift
    // code the native worker runs, so the two extractors cannot drift.
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


    // Per-cell extraction (Python: magic stripping, def/usage split,
    // exec(compile()) wrapping; R: cell-boundary markers) lives in RunnerCore
    // (Swift, compiled to wasm) and is shared with the native worker — see
    // extractNotebookToMap above.

    // -------------------------------------------------------------------------
    // Script helpers
    // -------------------------------------------------------------------------


    // Script classification (recognised extension \u2192 shebang \u2192 Python
    // content-sniff) now lives in RunnerCore (Swift/wasm) and is shared with the
    // native worker \u2014 see loadRunnerCore().classifyScript / interpreterToKind.


    // -------------------------------------------------------------------------
    // Outcome / collection builders
    // -------------------------------------------------------------------------

    // Exit-code → status mapping and result interpretation (JSON-footer parsing,
    // traceback extraction, longResult assembly) now live in RunnerCore
    // (interpretScriptOutput), shared with the native worker and applied inside
    // `executeSuites`. The browser no longer interprets output in JS — it only
    // produces raw ScriptOutput (see GradingWorkerExecutor.run).

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


    const testHooks = globalThis.__CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__;
    if (testHooks) {
        testHooks.exports = {
            runAndSubmit,
            runScripts,
            scriptExtension,
            loadRunnerCore,
            extractNotebookToMap,
            personalizationInputsSource,
            personalizationInputsSourceR,
            // Re-exported from grading-shared.js.
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
