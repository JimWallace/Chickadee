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
//   2. Unpack zip into Pyodide in-memory filesystem
//   3. Write test_runtime.py + sitecustomize.py helper libraries
//   4. Write notebook bytes and extract code cells to .py (equiv. of nb_to_py.py)
//   5. Run each .py test script in Pyodide; capture stdout/stderr
//   6. POST notebook bytes + TestOutcomeCollection to /api/v1/submissions/browser-result
//
// Only active for gradingMode="browser" pages (guard at top of IIFE).
// R test scripts (.R) are deferred until WebR is available (Issue #77).
// Shell scripts (.sh) are not supported in the browser environment.

(function () {
    'use strict';

    const scriptEl    = document.currentScript;
    const gradingMode = scriptEl ? scriptEl.dataset.gradingMode : null;

    // Only expose browser runner for browser-graded assignments.
    if (gradingMode !== 'browser') return;

    const statusEl = document.getElementById('browser-runner-status');
    if (statusEl) statusEl.hidden = false;

    // -------------------------------------------------------------------------
    // Public API — called by notebook.js on Submit
    // -------------------------------------------------------------------------

    window.BrowserRunner = { runAndSubmit, runScripts };

    /**
     * Run all test scripts against the student's notebook and submit results.
     *
     * @param {Uint8Array} notebookBytes  Raw bytes of the student's .ipynb file.
     * @param {string}     setupID        The test setup ID for this assignment.
     * @returns {{ outcomes: object[], response: object }}
     */
    async function runAndSubmit(notebookBytes, setupID) {
        const result = await runScripts(notebookBytes, setupID, { filename: 'submission.ipynb' });

        // Hide the loading-progress status bar — results are now in #nb-results.
        if (statusEl) statusEl.hidden = true;

        return {
            outcomes: result.outcomes,
            response: await postBrowserResult(notebookBytes, result.collection, setupID),
        };
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
        let py, JSZip;
        try {
            setRunnerStatus('loading', 'Initializing Python runtime…');
            py = await loadPyodideOnce();
        } catch (e) {
            throw new Error('Failed to initialize Python runtime: ' + toMessage(e));
        }
        try {
            JSZip = await loadJSZip();
        } catch (e) {
            throw new Error('Failed to load ZIP library: ' + toMessage(e));
        }

        // Unique work directory per run to avoid state leakage.
        const workDir = `/chickadee_work_${Date.now()}`;
        try {
            py.FS.mkdir(workDir);
        } catch (e) {
            throw new Error('Failed to create work directory: ' + toMessage(e));
        }

        try {
            // 1. Download and unpack the test setup zip.
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
            for (const [name, file] of Object.entries(zip.files)) {
                if (file.dir) continue;
                const data     = await file.async('uint8array');
                const fullPath = `${workDir}/${name}`;
                // Create parent directories as needed.
                const parts = name.split('/');
                if (parts.length > 1) {
                    let cur = workDir;
                    for (const part of parts.slice(0, -1)) {
                        cur += '/' + part;
                        try { py.FS.mkdir(cur); } catch (_) { /* already exists */ }
                    }
                }
                py.FS.writeFile(fullPath, data);
            }

            // 2. Write runtime helper libraries.
            py.FS.writeFile(`${workDir}/test_runtime.py`,  TEST_RUNTIME_PY);
            py.FS.writeFile(`${workDir}/sitecustomize.py`, SITECUSTOMIZE_PY);

            // 3. Write submitted solution bytes. Notebooks are extracted to a
            // Python/R source file; plain .py files are used directly.
            const submissionFilename = safeSubmissionFilename(options.filename || 'submission.ipynb');
            py.FS.writeFile(`${workDir}/${submissionFilename}`, submissionBytes);
            const lowerSubmissionName = submissionFilename.toLowerCase();
            if (lowerSubmissionName.endsWith('.ipynb')) {
                const notebookText = new TextDecoder().decode(submissionBytes);
                await extractNotebook(py, workDir, submissionFilename, notebookText);
            } else if (lowerSubmissionName.endsWith('.py')) {
                py.FS.writeFile(`${workDir}/.chickadee_student_module`, submissionFilename);
            } else if (lowerSubmissionName.endsWith('.r')) {
                py.FS.writeFile(`${workDir}/.chickadee_student_module`, submissionFilename);
            }

            // Add working directory to Python's path and set up builtins.
            //
            // We cannot rely on sitecustomize.py being auto-imported in Pyodide:
            // the interpreter is already running when we write the file, and
            // "sitecustomize" is a special name that Python's site machinery may
            // have already tried and cached.  Instead we import test_runtime
            // directly and wire up the builtins ourselves — identical to what
            // sitecustomize.py does, but without the name-based special-casing.
            //
            // We also flush stale copies of our helper/student modules so that
            // repeated submissions in the same Pyodide session don't inherit the
            // previous run's module state (especially test_runtime's
            // _loaded_student_modules global).
            try {
                await py.runPythonAsync(`
import sys, os, builtins

# Replace any stale chickadee work-directory on the path.
sys.path = [p for p in sys.path if not p.startswith('/chickadee_work_')]
sys.path.insert(0, '${workDir}')
os.chdir('${workDir}')

# Flush stale helper + student modules so fresh files are picked up.
for _key in list(sys.modules.keys()):
    if _key in ('sitecustomize', 'test_runtime') or _key.startswith('student_'):
        del sys.modules[_key]

# Import test_runtime — set functions in BOTH __main__ globals and builtins.
# Pyodide may not resolve builtins the same way CPython does, so we need
# them as __main__ globals too (runPythonAsync runs in __main__).
from test_runtime import passed, failed, errored, require_function
from test_runtime import load_student_modules, load_student_module
from test_runtime import student_module_names_in_load_order

builtins.passed           = passed
builtins.failed           = failed
builtins.errored          = errored
builtins.require_function = require_function

# Load student code and expose in both globals and builtins.
_student_modules = load_student_modules()
student_modules  = _student_modules
builtins.student_modules = _student_modules
_student_module  = load_student_module()
student_module   = _student_module
builtins.student_module  = _student_module
for _module_name in student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith('_'):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)
            globals()[_name] = _value
`);
            } catch (e) {
                throw new Error('Failed to configure Python environment: ' + toMessage(e));
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
            // Shared RunnerCore (wasm): the SAME Swift `executeSuites` loop the
            // native worker runs. Dependency gating, the "Skipped: prerequisite…"
            // messages, missing-script handling, and — crucially — output
            // interpretation (exit code → status, JSON-footer parsing, longResult
            // assembly) all live in RunnerCore now. The browser supplies only the
            // one substrate-specific operation: run a script via Pyodide and
            // report its RAW output (exit code + stdout/stderr), which RunnerCore
            // interprets byte-for-byte the way the worker does. No grading logic
            // or output interpretation remains in JS.
            const runnerCore = await loadRunnerCore();
            if (typeof globalThis.runnerExecuteSuites !== 'function') {
                throw new Error('RunnerCore wasm did not register runnerExecuteSuites');
            }

            const timeLimitSeconds = manifest.timeLimitSeconds || 10;
            const suites = (manifest.testSuites || []).map(entry => ({
                script: entry.script || '',
                tier: entry.tier || 'public',
                displayName: (typeof entry.name === 'string' && entry.name.trim()) ? entry.name.trim() : null,
                dependsOn: Array.isArray(entry.dependsOn) ? entry.dependsOn : [],
                points: typeof entry.points === 'number' ? entry.points : 1,
            }));

            // Substrate callbacks handed to the Swift loop.
            const scriptExists = (name) => {
                try { py.FS.stat(`${workDir}/${name}`); return true; }
                catch (_) { return false; }
            };
            const runScript = (name, limit) => runRawScript(py, runnerCore, workDir, name, limit);

            const outcomes = await globalThis.runnerExecuteSuites(
                suites, timeLimitSeconds, 1, scriptExists, runScript);

            // 5. Build collection. The caller decides whether to submit it.
            const collection = buildCollection(setupID, outcomes);
            return { outcomes, collection };

        } finally {
            // Clean up MEMFS to avoid OOM on repeated submissions.
            try { removeRecursive(py, workDir); } catch (_) { /* best-effort */ }
        }
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
        let notebook;
        try { notebook = JSON.parse(notebookText); } catch (_) { return; }

        // Detect kernel language the same way RunnerDaemon.swift does.
        const meta   = notebook.metadata || {};
        const ks     = meta.kernelspec || {};
        const ksName = (ks.name || '').toLowerCase();
        const liName = ((meta.language_info || {}).name || '').toLowerCase();
        const isR    = ksName === 'ir' || ksName === 'r' || ksName === 'webr' || liName === 'r';
        const stem   = filename.replace(/\.ipynb$/i, '');

        if (isR) {
            // R stays on the JS path — RunnerCore (the shared wasm extractor) is
            // Python-only, matching the native worker.
            let code = `# Generated from ${filename}\n\n`;
            for (const cell of (notebook.cells || [])) {
                if (cell.cell_type !== 'code') continue;
                const src = Array.isArray(cell.source) ? cell.source.join('') : (cell.source || '');
                const block = extractRCell(src);
                if (block) code += block + '\n\n';
            }
            py.FS.writeFile(`${workDir}/${stem}.R`, code);
            py.FS.writeFile(`${workDir}/.chickadee_student_module`, `${stem}.R`);
            return;
        }

        // Python: extract via the shared RunnerCore wasm — the SAME code the
        // native worker runs (Sources/RunnerCore), instead of a JS reimplementation.
        const cells = (notebook.cells || []).map(cell => ({
            cell_type: cell.cell_type,
            source: Array.isArray(cell.source) ? cell.source.join('') : (cell.source || ''),
        }));
        const core = await loadRunnerCore();
        const result = core.extractPython(cells, filename);

        py.FS.writeFile(`${workDir}/${stem}.py`, result.executableModule);
        py.FS.writeFile(`${workDir}/.chickadee_student_module`, `${stem}.py`);

        // Sidecar: the introspectable (un-exec-wrapped) source, so structural /
        // AST NotebookChecks can read real `def`s via student_source().
        py.FS.writeFile(`${workDir}/${stem}.source.py`, result.introspectableSource);
        py.FS.writeFile(`${workDir}/.chickadee_student_source`, `${stem}.source.py`);
    }

    // -------------------------------------------------------------------------
    // RunnerCore wasm (lazy singleton)
    //
    // Loads the vendored, embedded-Swift RunnerCore bridge and returns its
    // exported functions — `extractPython(cells, filename)` and
    // `classifyScript(name, source)`, the SAME Swift code the native worker
    // runs. A test harness can preset the `globalThis.runner*` globals to skip
    // loading the wasm.
    // -------------------------------------------------------------------------

    let _runnerCore = null;

    async function loadRunnerCore() {
        if (_runnerCore) return _runnerCore;
        const ready = () =>
            typeof globalThis.runnerExtractPython === 'function'
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

    // R cells are emitted verbatim — the browser R path (WebR) is not yet active.
    function extractRCell(src) {
        const trimmed = src.replace(/\s+$/, '');
        return trimmed.trim() ? trimmed : '';
    }

    // Python per-cell extraction (magic stripping, def/usage split,
    // exec(compile()) wrapping) now lives in RunnerCore (Swift, compiled to
    // wasm) and is shared with the native worker — see extractNotebook above.

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

    // Run one script and return a RAW ScriptOutput
    // { exitCode, stdout, stderr, executionTimeMs, timedOut }. RunnerCore's
    // shared `interpretScriptOutput` (driven by `executeSuites`) turns it into a
    // TestOutcome — identical interpretation to the native worker. The browser
    // only runs Python (Pyodide); other interpreters return their "not here"
    // message as a non-zero exit so the shared interpreter surfaces it the same
    // way for every runner.
    async function runRawScript(py, runnerCore, workDir, scriptName, timeLimitSeconds) {
        let src = null;
        try { src = py.FS.readFile(`${workDir}/${scriptName}`, { encoding: 'utf8' }); }
        catch (_) { src = null; }

        const kind = interpreterToKind(runnerCore.classifyScript(scriptName, src ?? ''));
        if (kind === 'r') {
            return rawError('R test scripts require WebR — not yet supported in browser runner');
        }
        if (kind === 'shell') {
            return rawError('Shell scripts cannot run in the browser runner');
        }
        if (kind !== 'python') {
            const ext = scriptExtension(scriptName);
            return rawError(`Unsupported test script type: ${ext ? '.' + ext : scriptName}`);
        }
        if (src === null) {
            return rawError(`Script not found: ${scriptName}`);
        }
        return runPyScriptRaw(py, src, scriptName, timeLimitSeconds);
    }

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
    async function runPyScriptRaw(py, src, scriptName, timeLimitSeconds) {
        const startMs = Date.now();

        // Auto-load any Pyodide packages the script imports (numpy, pandas, …).
        try { await py.loadPackagesFromImports(src); } catch (_) { /* non-fatal */ }

        // Redirect sys.stdout / sys.stderr to JS buffers.
        await py.runPythonAsync(`
import sys, io
_br_stdout = io.StringIO()
_br_stderr = io.StringIO()
sys.stdout = _br_stdout
sys.stderr = _br_stderr
`);

        let timedOut = false;
        let pyErr    = null;

        // compile(source, scriptName) gives inspect.stack() the real filename so
        // test_runtime reads the correct test label; `except SystemExit` catches
        // the exit that passed()/failed()/errored() raise (a clean subprocess
        // exit on the native side); imports + exec share one globals dict.
        const runSrc = `
from test_runtime import passed, failed, errored, require_function
_br_exit_code = None
try:
    _br_code = compile(open('${scriptName}', encoding='utf-8').read(), '${scriptName}', 'exec')
    exec(_br_code, globals())
except SystemExit as _e:
    _br_exit_code = _e.code
`;
        const runPromise     = py.runPythonAsync(runSrc).catch(err => { pyErr = err; });
        const timeoutPromise = sleep(timeLimitSeconds * 1000).then(() => { timedOut = true; });
        await Promise.race([runPromise, timeoutPromise]);

        let stdout = '', stderr = '', brExitCode = null;
        try {
            const captured = await py.runPythonAsync(`
(str(_br_stdout.getvalue()), str(_br_stderr.getvalue()), _br_exit_code)
`);
            const result = captured.toJs ? captured.toJs() : [String(captured), '', null];
            stdout = result[0] || '';
            stderr = result[1] || '';
            brExitCode = result[2];
            captured.destroy && captured.destroy();
        } catch (_) { /* fallback: no output */ }

        await py.runPythonAsync(`
sys.stdout = sys.__stdout__
sys.stderr = sys.__stderr__
`);

        const executionTimeMs = Date.now() - startMs;
        if (timedOut) {
            return { exitCode: -1, stdout, stderr, executionTimeMs, timedOut: true };
        }

        // Exit code: prefer the SystemExit code; otherwise mirror a `python3
        // script` subprocess — 0 on clean completion, 1 on an uncaught exception
        // (with the traceback on stderr so RunnerCore puts it in longResult).
        let exitCode;
        if (brExitCode !== null && brExitCode !== undefined) {
            exitCode = typeof brExitCode === 'number' ? brExitCode : (parseInt(brExitCode) || 1);
        } else if (pyErr) {
            const msg = pyErr.message || String(pyErr);
            const match = msg.match(/SystemExit:\s*(-?\d+)/);
            if (match) {
                exitCode = parseInt(match[1]);
            } else {
                exitCode = 1;
                if (!stderr.trim()) stderr = msg;
            }
        } else {
            exitCode = 0;
        }
        return { exitCode, stdout, stderr, executionTimeMs, timedOut: false };
    }

    // -------------------------------------------------------------------------
    // Outcome / collection builders
    // -------------------------------------------------------------------------

    // Map a process exit code to a test status — kept identical to the native
    // runner (RunnerDaemon+JobProcessing.swift): 0=pass, 1=fail, 3=fail
    // (Marmoset chickadee.py convention), everything else=error.
    function statusFromExitCode(code) {
        if (code === 0) return 'pass';
        if (code === 1 || code === 3) return 'fail';
        return 'error';
    }

    function makeOutcome(scriptName, tier, status, shortResult, longResult, executionTimeMs) {
        // Strip extension to get test name (matches native runner).
        const testName = scriptName.replace(/\.\w+$/, '') || scriptName;
        return {
            testName,
            testClass:          null,
            tier,
            status,
            shortResult,
            longResult:         longResult || null,
            executionTimeMs,
            memoryUsageBytes:   null,
            attemptNumber:      1,
            isFirstPassSuccess: status === 'pass',
        };
    }

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

    function structuredSummaryText(payload, status) {
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;

        if (status !== 'pass') {
            for (const key of ['error', 'message', 'detail', 'reason']) {
                const text = trimmedString(payload[key]);
                if (text) return text;
            }
        }

        const shortResult = trimmedString(payload.shortResult);
        if (shortResult) {
            const testLabel = trimmedString(payload.test);
            return stripLeadingLabel(shortResult, testLabel) || shortResult;
        }

        return trimmedString(payload.status) || null;
    }

    function detailedOutputFromParts({ parsedPayload, stdout, stderr, pyErr }) {
        const traceback = extractTracebackText(parsedPayload)
            || extractTracebackText(stdout)
            || extractTracebackText(stderr);
        if (traceback) return traceback;

        const exceptionText = pyErr && !String(pyErr.message || '').includes('SystemExit')
            ? trimmedString(pyErr.message || String(pyErr))
            : null;
        return stderr || stdout || exceptionText || null;
    }

    function extractTracebackText(value) {
        if (!value) return null;
        if (typeof value === 'object' && !Array.isArray(value)) {
            return trimmedString(value.traceback) || null;
        }

        const text = trimmedString(value);
        if (!text) return null;

        const structured = parseStructuredPayload(text);
        if (structured) {
            const traceback = extractTracebackText(structured);
            if (traceback) return traceback;
        }

        const marker = text.indexOf('Traceback (most recent call last):');
        return marker >= 0 ? text.slice(marker).trim() : null;
    }

    function parseStructuredPayload(text) {
        const trimmed = trimmedString(text);
        if (!trimmed) return null;

        const candidates = [trimmed];
        const stdoutMatch = trimmed.match(/(?:^|\n)stdout:\n([\s\S]*?)(?:\n\nstderr:\n|$)/);
        if (stdoutMatch && stdoutMatch[1]) candidates.unshift(stdoutMatch[1].trim());
        const stderrMatch = trimmed.match(/(?:^|\n)stderr:\n([\s\S]*)$/);
        if (stderrMatch && stderrMatch[1]) candidates.push(stderrMatch[1].trim());

        for (const candidate of candidates) {
            try {
                return JSON.parse(candidate);
            } catch (_) {
                // Try the next candidate shape.
            }
        }
        return null;
    }

    function stripLeadingLabel(text, label) {
        const trimmedText = trimmedString(text);
        const trimmedLabel = trimmedString(label);
        if (!trimmedText || !trimmedLabel) return null;
        const prefix = `${trimmedLabel}: `;
        return trimmedText.startsWith(prefix) ? trimmedText.slice(prefix.length).trim() : null;
    }

    function trimmedString(value) {
        return typeof value === 'string' ? value.trim() : '';
    }

    // Removes the trailing machine-readable JSON result line emitted by
    // test_runtime's passed()/failed()/errored() so students see only the
    // human-readable output above it.
    function stripJsonFooterLine(text) {
        const lines = String(text || '').split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
            if (lines[i].trim()) {
                lines.splice(i, 1);
                break;
            }
        }
        return lines.join('\n');
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
            headers: { 'x-csrf-token': getCsrfToken() },
            body:    formData,
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Failed to submit results: ${res.status} ${text}`);
        }
        return res.json();
    }

    // -------------------------------------------------------------------------
    // Pyodide loader (lazy singleton)
    // -------------------------------------------------------------------------

    let _pyodide = null;

    async function loadPyodideOnce() {
        if (_pyodide) return _pyodide;
        if (!window.loadPyodide) {
            await loadScript('/pyodide/pyodide.js');
        }
        _pyodide = await window.loadPyodide();
        return _pyodide;
    }

    // -------------------------------------------------------------------------
    // JSZip loader (lazy singleton)
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

    // -------------------------------------------------------------------------
    // MEMFS helpers
    // -------------------------------------------------------------------------

    function removeRecursive(py, path) {
        const stat = py.FS.stat(path);
        if (py.FS.isDir(stat.mode)) {
            for (const name of py.FS.readdir(path)) {
                if (name === '.' || name === '..') continue;
                removeRecursive(py, `${path}/${name}`);
            }
            py.FS.rmdir(path);
        } else {
            py.FS.unlink(path);
        }
    }

    // -------------------------------------------------------------------------
    // Misc helpers
    // -------------------------------------------------------------------------

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

    function loadScript(src) {
        return new Promise((resolve, reject) => {
            const s   = document.createElement('script');
            s.src     = src;
            s.onload  = resolve;
            s.onerror = () => reject(new Error(`Failed to load ${src}`));
            document.head.appendChild(s);
        });
    }

    function sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

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
        if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py"}:
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


def student_source() -> str:
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

    const testHooks = globalThis.__CHICKADEE_BROWSER_RUNNER_TEST_HOOKS__;
    if (testHooks) {
        testHooks.exports = {
            // Embedded runtime sources, exposed so the drift test can assert
            // they stay in sync with Tools/runner-support/*.py.
            TEST_RUNTIME_PY,
            SITECUSTOMIZE_PY,
            runAndSubmit,
            runScripts,
            scriptExtension,
            extractNotebook,
            runRawScript,
            runPyScriptRaw,
            buildCollection,
            removeRecursive,
            fetchBytes,
            fetchText,
            toMessage,
            __resetStateForTests() {
                _pyodide = null;
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
