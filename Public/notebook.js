// Public/notebook.js
//
// Chickadee in-browser grading engine.
//
// Loads the assignment notebook, lets the student edit it in JupyterLite,
// then on "Submit" runs the notebook via Pyodide, collects per-test outcomes,
// and POSTs a TestOutcomeCollection to POST /api/v1/submissions/browser-result.
//
// "Upload & submit" (Phase 9): student picks a locally-edited .ipynb file;
// the upload flow mirrors the Submit flow exactly — Pyodide runs against the
// uploaded solution (merged with visible test cells from the server), results
// are shown inline, and the submission is queued for an authoritative worker run.
//
// Results are rendered inline on the same page so students can iterate
// without navigating away. A "View official submission" link is shown
// after each run for the permanent record.

(function () {
    'use strict';

    const frame      = document.getElementById('jl-frame');
    const statusEl   = document.getElementById('nb-status');
    const submitBtn  = document.getElementById('nb-submit');
    const resultsEl  = document.getElementById('nb-results');
    const uploadFile = document.getElementById('nb-upload-file');
    const frameError = document.getElementById('nb-frame-error');
    const setupID    = frame ? frame.dataset.setupId : null;

    if (!frame || !setupID) return;

    // -------------------------------------------------------------------------
    // 1. Load JupyterLite in the iframe
    // -------------------------------------------------------------------------

    // Point the iframe at the embedded JupyterLite distribution.
    // The server provides a concrete JupyterLite file path via data-editor-url.
    // Fall back to a default lab path only if the attribute is missing.
    const notebookURL = `/api/v1/testsetups/${setupID}/assignment`;
    const editorURL = frame.dataset.editorUrl ||
        frame.getAttribute('src') ||
        `/jupyterlite/lab/index.html?workspace=${encodeURIComponent(setupID)}-student&reset=&path=assignment.ipynb`;
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
    });
    setTimeout(() => {
        if (!loaded && frameError) {
            frameError.style.display = '';
        }
    }, 5000);

    // -------------------------------------------------------------------------
    // 2. Submit button — run via Pyodide, POST results, render inline
    // -------------------------------------------------------------------------

    if (submitBtn) {
        submitBtn.addEventListener('click', async () => {
            submitBtn.disabled = true;
            clearResults();
            setStatus('loading', 'Loading grading engine…');

            try {
                // Fetch the notebook JSON directly (same file JupyterLite loaded).
                const nbRes = await fetch(notebookURL);
                if (!nbRes.ok) throw new Error(`Failed to fetch notebook: ${nbRes.status}`);
                const notebook = await nbRes.json();

                setStatus('loading', 'Running tests…');
                const outcomes = await runNotebook(notebook);

                setStatus('loading', 'Submitting…');
                const collection = buildCollection(outcomes, setupID);
                const response   = await postBrowserResult(collection, notebook, setupID);

                setStatus('loading', 'Submission queued. Opening grade details…');
                window.location.assign(`/submissions/${response.workerSubmissionID}`);
                return;
            } catch (err) {
                setStatus('error', `Error: ${err.message}`);
            } finally {
                submitBtn.disabled = false;
            }
        });
    }

    // -------------------------------------------------------------------------
    // 3. Upload & submit — read file → merge → Pyodide → POST → render
    // -------------------------------------------------------------------------

    if (uploadFile) {
        uploadFile.addEventListener('change', async () => {
            const file = uploadFile.files && uploadFile.files[0];
            if (!file) return;

            if (submitBtn) submitBtn.disabled = true;
            clearResults();
            setStatus('loading', 'Loading grading engine…');

            try {
                // Read the student's uploaded notebook.
                const uploadedText     = await readFileAsText(file);
                const uploadedNotebook = JSON.parse(uploadedText);

                // Fetch the assignment notebook to get the visible test cells.
                setStatus('loading', 'Fetching test definitions…');
                const nbRes = await fetch(notebookURL);
                if (!nbRes.ok) throw new Error(`Failed to fetch notebook: ${nbRes.status}`);
                const assignmentNotebook = await nbRes.json();

                // Build a merged notebook for Pyodide:
                // solution cells from the upload + test cells from the assignment.
                const mergedForPyodide = mergeNotebooksForRun(uploadedNotebook, assignmentNotebook);

                setStatus('loading', 'Running tests…');
                const outcomes = await runNotebook(mergedForPyodide);

                setStatus('loading', 'Submitting…');
                const collection = buildCollection(outcomes, setupID);
                // POST the uploaded (unmerged) notebook as the submission artifact;
                // the server will re-inject hidden test cells server-side.
                const response = await postBrowserResult(collection, uploadedNotebook, setupID);

                setStatus('loading', 'Submission queued. Opening grade details…');
                window.location.assign(`/submissions/${response.workerSubmissionID}`);
                return;
            } catch (err) {
                setStatus('error', `Error: ${err.message}`);
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
    // 8. POST to /api/v1/submissions/browser-result
    // -------------------------------------------------------------------------

    async function postBrowserResult(collection, notebook, testSetupID) {
        const formData = new FormData();
        formData.append('collection',  JSON.stringify(collection));
        formData.append('notebook',    new Blob([JSON.stringify(notebook)], { type: 'application/json' }), 'notebook.ipynb');
        formData.append('testSetupID', testSetupID);

        const res = await fetch('/api/v1/submissions/browser-result', {
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

        // "View official submission" link
        const link = document.createElement('a');
        link.className = 'nb-results-link';
        link.href = `/submissions/${response.workerSubmissionID}`;
        link.textContent = 'View official submission →';

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
})();
