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

    // Map a RunnerCore interpreter raw value to how the browser dispatches it.
    // Each kernel language maps to its substrate kind.  Shell and the other
    // interpreters have no browser substrate, so RoutingExecutor.run gives them
    // a precise "not here" message.
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
    // Script helpers
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

    /** Converts any thrown value to a human-readable string. */
    function toMessage(e) {
        if (e instanceof Error && e.message) return e.message;
        const s = String(e);
        return (s && s !== '[object Object]') ? s : 'unknown error';
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
