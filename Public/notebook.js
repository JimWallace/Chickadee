// Public/notebook.js
//
// Chickadee notebook submission page.
//
// Loads the assignment notebook, lets the student edit it in JupyterLite,
// then on "Submit" either:
//   - gradingMode="browser": runs tests locally via window.BrowserRunner
//     (browser-runner.js) and displays results inline, or
//   - gradingMode="worker": sends the notebook to the server and redirects
//     to the submission detail page once the native runner completes.
//
// "Upload & submit": if a file picker is present, uploaded notebook files are
// submitted directly to the native runner (no browser-side grading).

(function () {
    'use strict';

    const frame      = document.getElementById('jl-frame');
    const statusEl   = document.getElementById('nb-status');
    const submitBtn  = document.getElementById('nb-submit');
    const resultsEl  = document.getElementById('nb-results');
    const uploadFile = document.getElementById('nb-upload-file');
    const setupID     = frame ? frame.dataset.setupId : null;
    const gradingMode = frame ? frame.dataset.gradingMode : null;

    if (!frame || !setupID) return;

    // Disable Submit until the student's notebook has been synced into the
    // JupyterLite editor. This prevents a race condition where students click
    // Submit before their work is loaded, causing a blank notebook to be
    // submitted (the fallback path reads the starter template instead of
    // their saved cells).
    if (submitBtn) {
        submitBtn.disabled = true;
        submitBtn.title = 'Loading notebook\u2026';
    }
    setStatus('loading', 'Loading notebook\u2026');

    // -------------------------------------------------------------------------
    // 1. Load JupyterLite in the iframe
    // -------------------------------------------------------------------------

    // Point the iframe at the embedded JupyterLite distribution.
    // The server provides a concrete JupyterLite file path via data-editor-url.
    // Fall back to the notebook-focused app only if the attribute is missing.
    const notebookURL = frame.dataset.notebookUrl || `/api/v1/testsetups/${setupID}/assignment`;
    const editorURL = frame.dataset.editorUrl ||
        frame.getAttribute('src') ||
        `/jupyterlite/notebooks/index.html?workspace=${encodeURIComponent(setupID)}-student&reset=&path=assignment.ipynb`;
    const lockedNotebookPath = normalizeJupyterPath(extractPathFromEditorURL(editorURL));
    let lastForcedEditorResetMs = 0;
    let serverSyncInFlight = false;
    let serverSyncComplete = false;

    // Capability preflight: gate iframe mounting on the browser actually
    // supporting JupyterLite + Pyodide.  If the preflight module isn't
    // loaded (older cached page, network glitch) fall through to the
    // legacy behaviour of mounting unconditionally.
    const failures = window.ChickadeeNotebookFailures;
    const preflightPromise = failures
        ? failures.runPreflight()
        : Promise.resolve({ ok: true, failed: [] });

    preflightPromise.then((result) => {
        if (!result.ok) {
            if (failures) {
                failures.showFailure({
                    kind:         'preflight_fail',
                    failedChecks: result.failed
                });
            }
            // Re-enable Submit so the upload-fallback handler runs.
            if (submitBtn) {
                submitBtn.disabled = false;
                submitBtn.title = '';
            }
            setStatus('error', 'In-browser editor unavailable — upload your notebook below.');
            return;
        }
        mountEditor();
    });

    function mountEditor() {
        frame.src = editorURL;

        // Quick reachability check helps explain blank/failed editor loads.
        fetch(notebookURL, { method: 'GET' }).then((res) => {
            if (!res.ok) {
                setStatus('error', `Notebook source unavailable (${res.status})`);
            }
        }).catch(() => {
            setStatus('error', 'Notebook source unavailable');
        });

        frame.addEventListener('load', () => {
            if (!serverSyncComplete && !serverSyncInFlight) {
                void syncNotebookFromServerSnapshot();
            }
            applyLockedNotebookUI();
            enforceLockedNotebookPath();
        });
        setInterval(() => {
            applyLockedNotebookUI();
            enforceLockedNotebookPath();
        }, 1500);

        armEditorWatchdog();
    }

    // Watchdog: poll for JupyterLite's `jupyterapp` global on the iframe's
    // contentWindow (the same readiness signal used elsewhere in this file).
    // If the kernel doesn't come up within 45s, surface the fallback panel.
    function armEditorWatchdog() {
        if (!failures) return;
        const startedAt = Date.now();
        const deadline  = 45000; // 45s — generous for mid-spec Windows laptops.
        let cancelled = false;

        function tick() {
            if (cancelled) return;
            let ready = false;
            try {
                ready = !!(frame.contentWindow && frame.contentWindow.jupyterapp);
            } catch (_) { /* cross-origin or transient — keep polling */ }

            if (ready) { cancelled = true; return; }

            if (Date.now() - startedAt >= deadline) {
                cancelled = true;
                failures.showFailure({ kind: 'watchdog_timeout' });
                // Re-enable Submit so the upload-fallback handler runs.
                if (submitBtn) {
                    submitBtn.disabled = false;
                    submitBtn.title = '';
                }
                return;
            }
            setTimeout(tick, 500);
        }
        // First poll after 1s — the kernel is never up before that.
        setTimeout(tick, 1000);
    }

    // Hard fallback: if the notebook hasn't synced within 15 seconds (e.g. the
    // iframe never loaded) re-enable Submit so the student isn't stuck. The
    // fallback submit path (server snapshot → DOM → contents API) will still
    // attempt to find their work.
    setTimeout(() => {
        if (submitBtn && submitBtn.disabled) {
            submitBtn.disabled = false;
            submitBtn.title = '';
            if (!serverSyncComplete) setStatus('', '');
        }
    }, 15000);

    // -------------------------------------------------------------------------
    // 2. Submit button — queue runner grading
    // -------------------------------------------------------------------------

    if (submitBtn) {
        submitBtn.addEventListener('click', async () => {
            submitBtn.disabled = true;
            clearResults();
            setStatus('loading', 'Preparing submission…');

            try {
                setStatus('loading', 'Capturing notebook…');
                const notebook = await loadNotebookForSubmit();

                if (gradingMode === 'browser') {
                    if (!window.BrowserRunner || typeof window.BrowserRunner.runAndSubmit !== 'function') {
                        throw new Error('Browser grading is unavailable right now. Please reload and try again.');
                    }
                    // Browser-graded lab: run tests locally in Pyodide then submit atomically.
                    const { outcomes } = await submitBrowserNotebook(notebook, setupID);
                    const passCount = outcomes.filter(o => o.status === 'pass').length;
                    const allPassed = passCount === outcomes.length && outcomes.length > 0;
                    const summary   = `${passCount} / ${outcomes.length} passed` +
                                      (allPassed ? ' ✓ All tests passed!' : '');
                    setStatus('ok', summary);
                    return;
                }

                // Worker-graded assignment: enqueue for native runner.
                setStatus('loading', 'Submitting…');
                const response = await postRunnerSubmission(notebook, setupID);
                setStatus('loading', 'Submission queued. Opening grade details…');
                window.location.assign(`/submissions/${response.submissionID}`);
                return;
            } catch (err) {
                const msg = (err instanceof Error && err.message)
                    ? err.message
                    : String(err);
                console.error('[notebook] Submit error:', err);
                setStatus('error', `Error: ${msg}`);
            } finally {
                submitBtn.disabled = false;
            }
        });
    }

    async function loadNotebookForSubmit() {
        const liveNotebook = await readNotebookFromJupyterFrame();
        if (liveNotebook) return liveNotebook;

        const snapshotNotebook = await fetchNotebookSnapshot();
        const domNotebook = readNotebookFromVisibleDOM(snapshotNotebook);
        if (domNotebook) return domNotebook;

        const pathFromURL = lockedNotebookPath || extractPathFromEditorURL(editorURL);
        const apiNotebook = await readNotebookViaContentsAPI(pathFromURL);
        if (apiNotebook) return apiNotebook;

        if (snapshotNotebook) return snapshotNotebook;
        throw new Error('Failed to capture notebook contents');
    }

    async function fetchNotebookSnapshot() {
        const nbRes = await fetch(notebookURL);
        if (!nbRes.ok) return null;
        const notebook = await nbRes.json();
        return looksLikeNotebook(notebook) ? notebook : null;
    }

    async function readNotebookFromJupyterFrame() {
        try {
            const childWindow = frame.contentWindow;
            const app = childWindow && childWindow.jupyterapp;
            if (!app || !app.shell) return null;

            // Best effort: flush edits to the notebook model/context before reading.
            if (app.commands && typeof app.commands.execute === 'function') {
                try { await app.commands.execute('docmanager:save'); } catch (_) {}
                try { await app.commands.execute('docmanager:save-all'); } catch (_) {}
            }
            // Allow save handlers to settle before reading back from contents.
            await delay(125);

            const widget = notebookWidgetFromShell(app.shell, lockedNotebookPath);
            const modelNotebook = notebookFromWidget(widget);
            if (modelNotebook) return modelNotebook;

            const pathFromWidget = normalizeJupyterPath(widget && widget.context && widget.context.path);
            const pathFromURL = lockedNotebookPath || normalizeJupyterPath(extractPathFromEditorURL(editorURL));
            const notebookPath = pathFromWidget || pathFromURL;

            const contents = app.serviceManager && app.serviceManager.contents;
            if (!contents || typeof contents.get !== 'function' || !notebookPath) return null;

            const contentModel = await contents.get(notebookPath, { content: true, format: 'json' });
            const contentNotebook = contentModel && contentModel.content;
            if (looksLikeNotebook(contentNotebook)) {
                return toPlainNotebook(contentNotebook);
            }
        } catch (_) {
            // Fall back to server-provided notebook URL below.
        }
        return null;
    }

    function notebookWidgetFromShell(shell, preferredPath) {
        if (!shell) return null;
        const preferred = normalizeJupyterPath(preferredPath);
        let firstNotebook = null;
        const pathLooksNotebook = (path) => !!path && path.toLowerCase().endsWith('.ipynb');

        try {
            if (typeof shell.widgets === 'function') {
                const widgets = shell.widgets('main');
                for (const widget of widgets) {
                    const path = normalizeJupyterPath(widget && widget.context && widget.context.path);
                    const modelNotebook = notebookFromWidget(widget);
                    const isNotebookWidget = pathLooksNotebook(path) || !!modelNotebook;
                    if (!isNotebookWidget) continue;
                    if (!firstNotebook) firstNotebook = widget;
                    if (preferred && path === preferred) return widget;
                }
            }
        } catch (_) {
            // Ignore shell traversal errors.
        }

        const current = shell.currentWidget || null;
        const currentPath = normalizeJupyterPath(current && current.context && current.context.path);
        const currentNotebook = notebookFromWidget(current);
        if (pathLooksNotebook(currentPath) || currentNotebook) {
            return current;
        }
        return firstNotebook;
    }

    function notebookFromWidget(widget) {
        if (!widget) return null;

        const candidates = [
            widget.content && widget.content.model,
            widget.context && widget.context.model,
            widget.model
        ];

        for (const candidate of candidates) {
            if (!candidate || typeof candidate.toJSON !== 'function') continue;
            try {
                const notebook = candidate.toJSON();
                if (looksLikeNotebook(notebook)) return toPlainNotebook(notebook);
            } catch (_) {
                // Try next candidate.
            }
        }
        return null;
    }

    function extractPathFromEditorURL(url) {
        try {
            const parsed = new URL(url, window.location.origin);
            return parsed.searchParams.get('path');
        } catch (_) {
            return null;
        }
    }

    function normalizeJupyterPath(path) {
        if (!path) return '';
        return String(path).replace(/^\/+/, '').trim();
    }

    function readNotebookFromVisibleDOM(baseNotebook) {
        if (!baseNotebook || !looksLikeNotebook(baseNotebook) || !frame.contentDocument) return null;
        try {
            const doc = frame.contentDocument;
            const codeCellNodes = Array.from(doc.querySelectorAll('.jp-CodeCell'));
            if (!codeCellNodes.length) return null;

            const visibleCodeSources = codeCellNodes.map(extractVisibleCodeCellText);
            const notebook = toPlainNotebook(baseNotebook);
            const codeCellIndexes = [];
            for (let i = 0; i < notebook.cells.length; i += 1) {
                const cell = notebook.cells[i];
                if (cell && cell.cell_type === 'code') codeCellIndexes.push(i);
            }
            if (!codeCellIndexes.length || !visibleCodeSources.length) return null;

            const pairCount = Math.min(codeCellIndexes.length, visibleCodeSources.length);
            for (let i = 0; i < pairCount; i += 1) {
                const cellIndex = codeCellIndexes[i];
                notebook.cells[cellIndex].source = sourceArrayFromText(visibleCodeSources[i]);
            }

            for (let i = codeCellIndexes.length; i < visibleCodeSources.length; i += 1) {
                notebook.cells.push({
                    cell_type: 'code',
                    execution_count: null,
                    metadata: {},
                    outputs: [],
                    source: sourceArrayFromText(visibleCodeSources[i])
                });
            }
            return notebook;
        } catch (_) {
            return null;
        }
    }

    function extractVisibleCodeCellText(cellNode) {
        if (!cellNode) return '';
        const lineNodes = Array.from(cellNode.querySelectorAll('.cm-content .cm-line'));
        if (!lineNodes.length) return '';
        return lineNodes
            .map(node => normalizeEditorText(node.textContent || ''))
            .join('\n');
    }

    function normalizeEditorText(text) {
        return String(text)
            .replace(/\u200b/g, '')
            .replace(/\r\n/g, '\n');
    }

    function sourceArrayFromText(text) {
        const normalized = normalizeEditorText(text);
        if (!normalized.length) return [];
        const lines = normalized.split('\n');
        return lines.map((line, idx) => (idx < lines.length - 1 ? `${line}\n` : line));
    }

    function enforceLockedNotebookPath() {
        if (!lockedNotebookPath || !frame.contentWindow) return;
        try {
            const currentURL = new URL(frame.contentWindow.location.href, window.location.origin);
            const currentPath = normalizeJupyterPath(currentURL.searchParams.get('path'));
            const inNotebookApp = currentURL.pathname.includes('/jupyterlite/notebooks/');

            if (inNotebookApp && currentPath === lockedNotebookPath) return;

            const now = Date.now();
            if (now - lastForcedEditorResetMs < 1000) return;
            lastForcedEditorResetMs = now;
            frame.src = editorURL;
        } catch (_) {
            // Ignore transient cross-frame navigation states.
        }
    }

    async function syncNotebookFromServerSnapshot() {
        if (!lockedNotebookPath || serverSyncInFlight || serverSyncComplete) return;
        serverSyncInFlight = true;
        try {
            const snapshotRes = await fetch(notebookURL, { method: 'GET' });
            if (!snapshotRes.ok) return;
            const snapshotNotebook = await snapshotRes.json();
            if (!looksLikeNotebook(snapshotNotebook)) return;

            const app = await waitForJupyterApp(8000);
            if (!app) return;

            const contents = app.serviceManager && app.serviceManager.contents;

            // Before writing the server snapshot into JupyterLite, check whether
            // this browser already has a copy of the notebook in local storage
            // (IndexedDB). If it does, preserve it — the local version is the
            // student's most-recent in-progress work and must not be clobbered
            // with the (potentially older) server copy. The server copy is only
            // authoritative for seeding a fresh browser or a different device;
            // in both of those cases local storage will be empty.
            let hasLocalContent = false;
            if (contents && typeof contents.get === 'function') {
                try {
                    const localModel = await contents.get(lockedNotebookPath, { content: true });
                    hasLocalContent = looksLikeNotebook(localModel && localModel.content);
                } catch (_) {
                    // Not found in local storage — will seed from server below.
                }
            }

            if (!hasLocalContent && contents && typeof contents.save === 'function') {
                await contents.save(lockedNotebookPath, {
                    type: 'notebook',
                    format: 'json',
                    content: snapshotNotebook
                });
            }

            if (app.commands && typeof app.commands.execute === 'function') {
                try {
                    await app.commands.execute('docmanager:open', { path: lockedNotebookPath });
                } catch (_) {
                    // Best-effort open only.
                }
            }

            serverSyncComplete = true;
        } catch (_) {
            // Retry on the next load tick if synchronization fails.
        } finally {
            serverSyncInFlight = false;
            // Always re-enable Submit — either the sync loaded the student's
            // saved work, or the fallback submit path will handle it.
            if (submitBtn) {
                submitBtn.disabled = false;
                submitBtn.title = '';
            }
            setStatus('', '');
        }
    }

    async function waitForJupyterApp(timeoutMs) {
        const started = Date.now();
        while (Date.now() - started < timeoutMs) {
            const app = frame.contentWindow && frame.contentWindow.jupyterapp;
            const contents = app && app.serviceManager && app.serviceManager.contents;
            if (app && contents) return app;
            await delay(100);
        }
        return null;
    }

    function applyLockedNotebookUI() {
        if (!frame.contentDocument) return;
        const doc = frame.contentDocument;
        if (doc.getElementById('chickadee-notebook-lock-style')) return;

        const style = doc.createElement('style');
        style.id = 'chickadee-notebook-lock-style';
        style.textContent = [
            '.jp-SideBar, .jp-SidePanel, .jp-FileBrowser, .jp-FileBrowser-Panel, .jp-DirListing { display: none !important; }',
            '.lm-MenuBar, .jp-MenuBar, .jp-TopBar { display: none !important; }'
        ].join('\n');
        doc.head.appendChild(style);
    }

    function looksLikeNotebook(value) {
        return !!value && typeof value === 'object' && Array.isArray(value.cells);
    }

    function toPlainNotebook(notebook) {
        try {
            return JSON.parse(JSON.stringify(notebook));
        } catch (_) {
            return notebook;
        }
    }

    async function readNotebookViaContentsAPI(path) {
        if (!path) return null;
        const encodedPath = path.split('/').map(encodeURIComponent).join('/');
        const candidates = [
            `/jupyterlite/api/contents/${encodedPath}?content=1`,
            `/jupyterlite/lab/api/contents/${encodedPath}?content=1`,
            `/jupyterlite/notebooks/api/contents/${encodedPath}?content=1`,
            `/notebooks/api/contents/${encodedPath}?content=1`,
            `/api/contents/${encodedPath}?content=1`
        ];

        for (const url of candidates) {
            try {
                const res = await fetch(url);
                if (!res.ok) continue;
                const payload = await res.json();
                if (looksLikeNotebook(payload && payload.content)) {
                    return toPlainNotebook(payload.content);
                }
            } catch (_) {
                // Try the next candidate URL.
            }
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // 3. Upload & submit — read file → queue runner grading
    // -------------------------------------------------------------------------

    if (uploadFile) {
        uploadFile.addEventListener('change', async () => {
            const file = uploadFile.files && uploadFile.files[0];
            if (!file) return;

            if (submitBtn) submitBtn.disabled = true;
            clearResults();
            setStatus('loading', 'Preparing submission…');

            try {
                // Read the student's uploaded notebook.
                const uploadedText     = await readFileAsText(file);
                const uploadedNotebook = JSON.parse(uploadedText);

                if (gradingMode === 'browser') {
                    if (!window.BrowserRunner || typeof window.BrowserRunner.runAndSubmit !== 'function') {
                        throw new Error('Browser grading is unavailable right now. Please reload and try again.');
                    }
                    const { outcomes } = await submitBrowserNotebook(uploadedNotebook, setupID);
                    const passCount = outcomes.filter(o => o.status === 'pass').length;
                    const allPassed = passCount === outcomes.length && outcomes.length > 0;
                    const summary   = `${passCount} / ${outcomes.length} passed` +
                                      (allPassed ? ' ✓ All tests passed!' : '');
                    setStatus('ok', summary);
                    return;
                }

                setStatus('loading', 'Submitting…');
                const response = await postRunnerSubmission(
                    uploadedNotebook,
                    setupID,
                    file.name || 'submission.ipynb'
                );

                setStatus('loading', 'Submission queued. Opening grade details…');
                window.location.assign(`/submissions/${response.submissionID}`);
                return;
            } catch (err) {
                const msg = (err instanceof Error && err.message)
                    ? err.message
                    : String(err);
                console.error('[notebook] Upload error:', err);
                setStatus('error', `Error: ${msg}`);
            } finally {
                if (submitBtn) submitBtn.disabled = false;
                // Reset so the same file can be re-selected.
                uploadFile.value = '';
            }
        });
    }

    // -------------------------------------------------------------------------
    // 4. Pyodide execution engine
    // -------------------------------------------------------------------------

    let pyodide = null;

    async function loadPyodideOnce() {
        if (pyodide) return pyodide;
        // Pyodide is loaded from CDN the first time Submit is clicked.
        if (!window.loadPyodide) {
            await loadScript('https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js');
        }
        pyodide = await window.loadPyodide();
        return pyodide;
    }

    // Run all cells in order; collect outcomes for TEST cells.
    async function runNotebook(notebook) {
        const py = await loadPyodideOnce();

        // Reset the interpreter for a clean run.
        await py.runPythonAsync('import sys; sys.modules.clear()');

        const outcomes = [];

        for (const cell of notebook.cells) {
            if (cell.cell_type !== 'code') continue;

            const source = Array.isArray(cell.source)
                ? cell.source.join('')
                : cell.source;

            if (!source.trim()) continue;

            const testMeta = parseTestComment(source);
            const startMs  = Date.now();

            if (testMeta) {
                // This is a test cell — run it and record pass/fail.
                const outcome = await runTestCell(py, source, testMeta, startMs);
                outcomes.push(outcome);
            } else {
                // Regular cell — run it silently; exceptions propagate and abort.
                try {
                    await py.runPythonAsync(source);
                } catch (err) {
                    const longResult = await captureTraceback(py, err);
                    // A non-test cell threw — record a generic error and stop.
                    outcomes.push({
                        testName:          'setup_error',
                        testClass:         null,
                        tier:              'public',
                        status:            'error',
                        shortResult:       `Setup cell failed: ${firstLine(err.message)}`,
                        longResult,
                        executionTimeMs:   Date.now() - startMs,
                        memoryUsageBytes:  null,
                        attemptNumber:     1,
                        isFirstPassSuccess: false,
                    });
                    break;
                }
            }
        }

        return outcomes;
    }

    // Run a single test cell; return a TestOutcome-shaped object.
    async function runTestCell(py, source, meta, startMs) {
        let status      = 'pass';
        let shortResult = 'passed';
        let longResult  = null;

        try {
            await py.runPythonAsync(source);
        } catch (err) {
            const msg = err.message || String(err);
            longResult = await captureTraceback(py, err);

            if (msg.includes('AssertionError') || msg.includes('assert')) {
                status = 'fail';
                // Surface the assertion message if one was provided.
                const assertMsg = extractAssertionMessage(msg);
                shortResult = assertMsg
                    ? `failed: ${assertMsg.substring(0, 80)}`
                    : 'failed';
            } else {
                status      = 'error';
                shortResult = `error: ${firstLine(msg).substring(0, 80)}`;
            }
        }

        return {
            testName:          meta.name,
            testClass:         null,
            tier:              meta.tier,
            status,
            shortResult,
            longResult,
            executionTimeMs:   Date.now() - startMs,
            memoryUsageBytes:  null,
            attemptNumber:     1,
            isFirstPassSuccess: status === 'pass',
        };
    }

    // Ask Pyodide to format the last traceback from Python's sys module.
    // Falls back to err.message if Python-level info is unavailable.
    async function captureTraceback(py, err) {
        try {
            const tb = await py.runPythonAsync(`
import traceback, sys
_exc = sys.last_value
if _exc is not None:
    ''.join(traceback.format_exception(type(_exc), _exc, _exc.__traceback__))
else:
    ''
`);
            return tb.trim() || (err.message || String(err));
        } catch (_) {
            return err.message || String(err);
        }
    }

    // Extract the message from an AssertionError line, e.g.:
    //   "AssertionError: expected 5 but got 3"  →  "expected 5 but got 3"
    function extractAssertionMessage(msg) {
        const line = msg.split('\n').find(l => l.includes('AssertionError'));
        if (!line) return null;
        const colon = line.indexOf(':');
        return colon >= 0 ? line.slice(colon + 1).trim() : null;
    }

    function firstLine(msg) {
        return (msg || '').split('\n')[0].trim();
    }

    // -------------------------------------------------------------------------
    // 5. # TEST: comment parser
    //
    // Format: # TEST: <name> [key=value ...]
    // Supported keys: tier (default "public"), weight (reserved), requires (reserved)
    // -------------------------------------------------------------------------

    function parseTestComment(source) {
        const firstLine = source.trimStart().split('\n')[0];
        const match     = firstLine.match(/^#\s*TEST:\s*(\S+)(.*)/);
        if (!match) return null;

        const name   = match[1];
        const kvStr  = match[2].trim();
        const kvPairs = {};
        for (const part of kvStr.split(/\s+/)) {
            const [k, v] = part.split('=');
            if (k && v !== undefined) kvPairs[k] = v;
        }

        return {
            name,
            tier:     kvPairs.tier     || 'public',
            weight:   kvPairs.weight   ? parseFloat(kvPairs.weight) : null,
            requires: kvPairs.requires ? kvPairs.requires.split(',') : [],
        };
    }

    // -------------------------------------------------------------------------
    // 6. Notebook merge helper (client-side, for Pyodide only)
    //
    // Produces a notebook with:
    //   - non-test cells from the student's upload  (their solution code)
    //   - test cells from the assignment notebook    (visible tiers only)
    //
    // The server re-injects hidden test cells when the notebook is saved.
    // -------------------------------------------------------------------------

    function mergeNotebooksForRun(studentNB, assignmentNB) {
        const isTestCellJS = function (cell) {
            const source = Array.isArray(cell.source)
                ? cell.source.join('')
                : (cell.source || '');
            return /^#\s*TEST:/.test(source.trimStart().split('\n')[0]);
        };
        const solutionCells = (studentNB.cells   || []).filter(c => !isTestCellJS(c));
        const testCells     = (assignmentNB.cells || []).filter(c =>  isTestCellJS(c));
        return { ...studentNB, cells: [...solutionCells, ...testCells] };
    }

    // -------------------------------------------------------------------------
    // 7. Build TestOutcomeCollection
    // -------------------------------------------------------------------------

    function buildCollection(outcomes, testSetupID) {
        const pass    = outcomes.filter(o => o.status === 'pass').length;
        const fail    = outcomes.filter(o => o.status === 'fail').length;
        const error   = outcomes.filter(o => o.status === 'error').length;
        const timeout = outcomes.filter(o => o.status === 'timeout').length;
        const totalMs = outcomes.reduce((s, o) => s + o.executionTimeMs, 0);

        return {
            submissionID:    '',          // filled in by server
            testSetupID,
            attemptNumber:   1,           // server will recompute
            buildStatus:     'passed',
            compilerOutput:  null,
            outcomes,
            totalTests:      outcomes.length,
            passCount:       pass,
            failCount:       fail,
            errorCount:      error,
            timeoutCount:    timeout,
            executionTimeMs: totalMs,
            runnerVersion:   'browser-pyodide/1.0',
            timestamp:       new Date().toISOString(),
        };
    }

    // -------------------------------------------------------------------------
    // 8. POST to /api/v1/submissions/runner-submit
    // -------------------------------------------------------------------------

    async function postRunnerSubmission(notebook, testSetupID, filename = 'submission.ipynb') {
        const formData = new FormData();
        formData.append('notebook',    new Blob([JSON.stringify(notebook)], { type: 'application/json' }), 'notebook.ipynb');
        formData.append('testSetupID', testSetupID);
        formData.append('filename', filename);

        const res = await fetch('/api/v1/submissions/runner-submit', {
            method:  'POST',
            headers: { 'x-csrf-token': getCsrfToken() },
            body:    formData,
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Server error ${res.status}: ${text}`);
        }
        return res.json();
    }

    async function submitBrowserNotebook(notebook, testSetupID) {
        setStatus('loading', 'Testing…');
        const notebookBytes = new Uint8Array(
            new TextEncoder().encode(JSON.stringify(notebook))
        );
        const { outcomes, response } =
            await window.BrowserRunner.runAndSubmit(notebookBytes, testSetupID);
        renderResults(outcomes, response);
        return { outcomes, response };
    }

    // -------------------------------------------------------------------------
    // 9. Inline results rendering
    // -------------------------------------------------------------------------

    function clearResults() {
        if (resultsEl) {
            resultsEl.hidden = true;
            resultsEl.innerHTML = '';
        }
    }

    // Pattern that identifies a dependency-skip shortResult.
    const SKIP_RE = /^Skipped: prerequisite '(.+)' did not pass$/;

    function renderResults(outcomes, response) {
        if (!resultsEl) return;
        const displayNameMap = buildOutcomeDisplayNameMap(outcomes);

        const pass    = outcomes.filter(o => o.status === 'pass').length;
        const fail    = outcomes.filter(o => o.status === 'fail').length;
        const error   = outcomes.filter(o => o.status === 'error').length;
        const timeout = outcomes.filter(o => o.status === 'timeout').length;
        const total   = outcomes.length;

        // Summary line below the status bar
        const summaryEl = document.createElement('p');
        summaryEl.className = 'score';
        const parts = [`${pass} / ${total} passed`];
        if (fail)    parts.push(`${fail} failed`);
        if (error)   parts.push(`${error} error${error > 1 ? 's' : ''}`);
        if (timeout) parts.push(`${timeout} timed out`);
        summaryEl.textContent = parts.join(' · ');

        // Results table — 4-column structure matching submission.leaf
        const table = document.createElement('table');
        table.className = 'results-table';
        table.innerHTML = `
            <thead>
                <tr>
                    <th>Test</th>
                    <th>Tier</th>
                    <th>Output</th>
                    <th>Mark</th>
                </tr>
            </thead>`;

        const tbody = document.createElement('tbody');
        for (const o of outcomes) {
            const skipMatch  = SKIP_RE.exec(o.shortResult || '');
            const isSkipped  = !!skipMatch;
            const blockerRaw = isSkipped ? skipMatch[1] : null;
            // Strip file extension: "test_build.py" → "test_build"
            const blockerKey = blockerRaw
                ? (blockerRaw.includes('.') ? blockerRaw.replace(/\.[^.]+$/, '') : blockerRaw)
                : null;
            const blockerName = blockerKey ? (displayNameMap.get(blockerKey) || blockerKey) : null;
            const displayName = bestOutcomeDisplayName(o);
            const shortResult = formattedOutcomeShortResult(o);
            const longResult = formattedOutcomeDetailedOutput(o);

            const tr = document.createElement('tr');
            tr.className = isSkipped ? 'status-skipped' : `status-${o.status}`;

            // Mark label and CSS class
            let markLabel, markClass;
            if (isSkipped) {
                markLabel = '—';       markClass = 'skipped';
            } else {
                switch (o.status) {
                    case 'pass':    markLabel = 'Pass';    markClass = 'pass';    break;
                    case 'fail':    markLabel = 'Fail';    markClass = 'fail';    break;
                    case 'error':   markLabel = 'Error';   markClass = 'error';   break;
                    case 'timeout': markLabel = 'Timeout'; markClass = 'timeout'; break;
                    default:        markLabel = 'Fail';    markClass = 'fail';
                }
            }

            // Test name cell — with optional "↳ blocked by" annotation for skips
            const blockerHtml = blockerName
                ? `<div class="skip-blocker">↳ blocked by <code>${escHtml(blockerName)}</code></div>`
                : '';

            // Output cell
            let outputHtml;
            if (isSkipped) {
                outputHtml = `<span class="skip-reason">${escHtml(shortResult)}</span>`;
            } else {
                const longHtml = longResult
                    ? `<details><summary>Show output ▸</summary><pre>${escHtml(longResult)}</pre></details>`
                    : '';
                outputHtml = escHtml(shortResult) + longHtml;
            }

            tr.innerHTML = `
                <td><code>${escHtml(displayName)}</code>${blockerHtml}</td>
                <td><span class="tier">${escHtml(o.tier)}</span></td>
                <td>${outputHtml}</td>
                <td><span class="result-mark result-mark-${markClass}">${escHtml(markLabel)}</span></td>`;
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);

        resultsEl.innerHTML = '';
        resultsEl.appendChild(summaryEl);
        resultsEl.appendChild(table);
        resultsEl.hidden = false;

        // Scroll results into view so student sees feedback immediately.
        resultsEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function escHtml(str) {
        return String(str ?? '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function buildOutcomeDisplayNameMap(outcomes) {
        const map = new Map();
        for (const outcome of outcomes || []) {
            const displayName = bestOutcomeDisplayName(outcome);
            const keys = [outcome && outcome.scriptName, outcome && outcome.testName];
            for (const key of keys) {
                if (typeof key === 'string' && key.trim()) {
                    map.set(key.trim(), displayName);
                    const stem = key.replace(/\.[^.]+$/, '').trim();
                    if (stem) map.set(stem, displayName);
                }
            }
        }
        return map;
    }

    function bestOutcomeDisplayName(outcome) {
        const explicit = trimmedString(outcome && outcome.displayName);
        if (explicit) return explicit;
        const testName = trimmedString(outcome && outcome.testName);
        if (testName) return testName;
        return trimmedString(outcome && outcome.scriptName) || 'test';
    }

    function formattedOutcomeShortResult(outcome) {
        const shortResult = trimmedString(outcome && outcome.shortResult);
        const parsed = parseStructuredPayload(shortResult)
            || parseStructuredPayload(trimmedString(outcome && outcome.longResult));
        if (parsed) {
            const summary = structuredSummaryText(parsed, outcome && outcome.status);
            if (summary) return summary;
        }
        return shortResult || defaultShortResult(outcome && outcome.status);
    }

    function formattedOutcomeDetailedOutput(outcome) {
        const longResult = trimmedString(outcome && outcome.longResult);
        const shortResult = trimmedString(outcome && outcome.shortResult);
        const parsed = parseStructuredPayload(longResult) || parseStructuredPayload(shortResult);
        const traceback = extractTracebackText(parsed)
            || extractTracebackText(longResult)
            || extractTracebackText(shortResult);
        if (traceback) return traceback;
        return longResult || null;
    }

    function structuredSummaryText(payload, status) {
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;

        if (status && status !== 'pass') {
            for (const key of ['error', 'message', 'detail', 'reason']) {
                const text = trimmedString(payload[key]);
                if (text) return text;
            }
        }

        const shortResult = trimmedString(payload.shortResult);
        if (shortResult) {
            const label = trimmedString(payload.test);
            return stripLeadingLabel(shortResult, label) || shortResult;
        }

        return trimmedString(payload.status) || null;
    }

    function extractTracebackText(value) {
        if (!value) return null;
        if (typeof value === 'object' && !Array.isArray(value)) {
            return trimmedString(value.traceback) || null;
        }

        const text = trimmedString(value);
        if (!text) return null;
        const parsed = parseStructuredPayload(text);
        if (parsed) {
            const traceback = extractTracebackText(parsed);
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
                // Try the next shape.
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

    function defaultShortResult(status) {
        if (status === 'pass') return 'passed';
        if (status === 'fail') return 'failed';
        if (status === 'timeout') return 'timed out';
        return 'error';
    }

    // -------------------------------------------------------------------------
    // 10. Helpers
    // -------------------------------------------------------------------------

    function setStatus(type, msg) {
        statusEl.textContent  = msg;
        statusEl.className    = `nb-status${type ? ' nb-status-' + type : ''}`;
    }

    function readFileAsText(file) {
        return new Promise((resolve, reject) => {
            const r   = new FileReader();
            r.onload  = e => resolve(e.target.result);
            r.onerror = () => reject(new Error('Could not read file'));
            r.readAsText(file);
        });
    }

    function loadScript(src) {
        return new Promise((resolve, reject) => {
            const s  = document.createElement('script');
            s.src    = src;
            s.onload  = resolve;
            s.onerror = () => reject(new Error(`Failed to load ${src}`));
            document.head.appendChild(s);
        });
    }

    function delay(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    const testHooks = globalThis.__CHICKADEE_NOTEBOOK_TEST_HOOKS__;
    if (testHooks) {
        testHooks.exports = {
            buildOutcomeDisplayNameMap,
            bestOutcomeDisplayName,
            formattedOutcomeShortResult,
            formattedOutcomeDetailedOutput,
            structuredSummaryText,
            extractTracebackText,
            parseStructuredPayload,
        };
    }
})();
