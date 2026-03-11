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
    const frameError = document.getElementById('nb-frame-error');
    const setupID     = frame ? frame.dataset.setupId : null;
    const gradingMode = frame ? frame.dataset.gradingMode : null;

    if (!frame || !setupID) return;

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
    frame.src = editorURL;

    // Quick reachability check helps explain blank/failed editor loads.
    fetch(notebookURL, { method: 'GET' }).then((res) => {
        if (!res.ok) {
            setStatus('error', `Notebook source unavailable (${res.status})`);
            if (frameError) frameError.style.display = '';
        }
    }).catch(() => {
        setStatus('error', 'Notebook source unavailable');
        if (frameError) frameError.style.display = '';
    });

    // Detect blank/failed iframe loads and provide an explicit fallback path.
    let loaded = false;
    frame.addEventListener('load', () => {
        loaded = true;
        if (frameError) frameError.style.display = 'none';
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
    setTimeout(() => {
        if (!loaded && frameError) {
            frameError.style.display = '';
        }
    }, 5000);

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

                if (gradingMode === 'browser' && window.BrowserRunner) {
                    // Browser-graded lab: run tests locally in Pyodide then submit atomically.
                    setStatus('loading', 'Running tests in your browser…');
                    const notebookBytes = new Uint8Array(
                        new TextEncoder().encode(JSON.stringify(notebook))
                    );
                    const { outcomes, response } =
                        await window.BrowserRunner.runAndSubmit(notebookBytes, setupID);
                    renderResults(outcomes, response);
                    const passCount = outcomes.filter(o => o.status === 'pass').length;
                    setStatus('ok', `${passCount} / ${outcomes.length} tests passed.`);
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
            if (!contents || typeof contents.save !== 'function') return;

            await contents.save(lockedNotebookPath, {
                type: 'notebook',
                format: 'json',
                content: snapshotNotebook
            });

            if (app.commands && typeof app.commands.execute === 'function') {
                try {
                    await app.commands.execute('docmanager:open', { path: lockedNotebookPath });
                } catch (_) {
                    // Best-effort open only; save above is the critical sync step.
                }
            }

            serverSyncComplete = true;
        } catch (_) {
            // Retry on the next load tick if synchronization fails.
        } finally {
            serverSyncInFlight = false;
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
            method: 'POST',
            body:   formData,
        });
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Server error ${res.status}: ${text}`);
        }
        return res.json();
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

    function renderResults(outcomes, response) {
        if (!resultsEl) return;

        const pass  = outcomes.filter(o => o.status === 'pass').length;
        const total = outcomes.length;
        const totalMs = outcomes.reduce((s, o) => s + o.executionTimeMs, 0);

        const allPassed = pass === total && total > 0;

        // Score line
        const scoreEl = document.createElement('p');
        scoreEl.className = 'score';
        scoreEl.innerHTML =
            `${pass} / ${total} passed ` +
            `<span class="exec-time">(${totalMs} ms)</span>`;
        if (allPassed) {
            scoreEl.innerHTML += ' <span style="color:var(--green)">✓ All tests passed!</span>';
        }

        // Results table — reuses the same CSS classes as submission.leaf
        const table = document.createElement('table');
        table.className = 'results-table';
        table.innerHTML = `
            <thead>
                <tr>
                    <th>Test</th>
                    <th>Tier</th>
                    <th>Result</th>
                    <th>ms</th>
                </tr>
            </thead>`;

        const tbody = document.createElement('tbody');
        for (const o of outcomes) {
            const tr = document.createElement('tr');
            tr.className = `status-${o.status}`;

            const longCell = o.longResult
                ? `<details><summary>details</summary><pre>${escHtml(o.longResult)}</pre></details>`
                : '';

            tr.innerHTML = `
                <td><code>${escHtml(o.testName)}</code></td>
                <td><span class="tier">${escHtml(o.tier)}</span></td>
                <td>${escHtml(o.shortResult)}${longCell}</td>
                <td class="time">${o.executionTimeMs}</td>`;
            tbody.appendChild(tr);
        }
        table.appendChild(tbody);

        // "View submission" link
        const link = document.createElement('a');
        link.className = 'nb-results-link';
        link.href = `/submissions/${response.submissionID}`;
        link.textContent = 'View submission →';

        resultsEl.innerHTML = '';
        resultsEl.appendChild(scoreEl);
        resultsEl.appendChild(table);
        resultsEl.appendChild(link);
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
})();
