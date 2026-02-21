// Public/notebook.js
//
// Chickadee in-browser grading engine.
//
// Loads the assignment notebook, lets the student edit it in JupyterLite,
// then on "Submit" runs the notebook via Pyodide, collects per-test outcomes,
// and POSTs a TestOutcomeCollection to POST /api/v1/submissions/browser-result.

(function () {
    'use strict';

    const frame    = document.getElementById('jl-frame');
    const statusEl = document.getElementById('nb-status');
    const submitBtn = document.getElementById('nb-submit');
    const setupID  = frame ? frame.dataset.setupId : null;

    if (!frame || !setupID) return;

    // -------------------------------------------------------------------------
    // 1. Load JupyterLite in the iframe
    // -------------------------------------------------------------------------

    // Point the iframe at the embedded JupyterLite distribution.
    // We pass the assignment notebook URL as a query parameter so JupyterLite
    // can pre-populate it.
    const notebookURL = `/api/v1/testsetups/${setupID}/assignment`;
    frame.src = `/jupyterlite/index.html?path=assignment.ipynb&fromURL=${encodeURIComponent(notebookURL)}`;

    // -------------------------------------------------------------------------
    // 2. Submit button — run via Pyodide and POST results
    // -------------------------------------------------------------------------

    submitBtn.addEventListener('click', async () => {
        submitBtn.disabled = true;
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

            // Redirect to the submission results page (shows browser preview
            // immediately, polls for the official worker result).
            window.location.href = `/submissions/${response.workerSubmissionID}`;
        } catch (err) {
            setStatus('error', `Error: ${err.message}`);
            submitBtn.disabled = false;
        }
    });

    // -------------------------------------------------------------------------
    // 3. Pyodide execution engine
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
                    // A non-test cell threw — record a generic error and stop.
                    outcomes.push({
                        testName:          'setup_error',
                        testClass:         null,
                        tier:              'public',
                        status:            'error',
                        shortResult:       `Setup cell failed: ${err.message}`,
                        longResult:        err.message,
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
            if (msg.includes('AssertionError') || msg.includes('assert')) {
                status      = 'fail';
                shortResult = 'failed';
            } else {
                status      = 'error';
                shortResult = 'error';
            }
            longResult = msg;
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

    // -------------------------------------------------------------------------
    // 4. # TEST: comment parser
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
    // 5. Build TestOutcomeCollection
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
    // 6. POST to /api/v1/submissions/browser-result
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
    // 7. Helpers
    // -------------------------------------------------------------------------

    function setStatus(type, msg) {
        statusEl.textContent  = msg;
        statusEl.className    = `nb-status nb-status-${type}`;
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
