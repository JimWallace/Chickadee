// Public/assignment-validate.js
//
// In-browser solution validator for the assignment validation page.
//
// Workflow:
//   1. Instructor selects a .py solution file via the file input.
//   2. Clicking "Run tests" fetches the assignment notebook to get # TEST: cells.
//   3. The solution file is injected into a fresh Pyodide interpreter.
//   4. Each # TEST: cell from the notebook is run against the solution's namespace.
//   5. Results are rendered inline (same CSS classes as submission.leaf).
//   6. If all tests pass, the "Go live" panel is revealed.
//
// No submission is posted to the server — this is purely local validation.

(function () {
    'use strict';

    const scriptEl     = document.currentScript;
    const assignmentID = scriptEl ? scriptEl.dataset.assignmentId : null;
    const setupID      = scriptEl ? scriptEl.dataset.setupId : null;

    const fileInput   = document.getElementById('solution-file');
    const runBtn      = document.getElementById('run-btn');
    const statusEl    = document.getElementById('validate-status');
    const resultsEl   = document.getElementById('validate-results');
    const goLivePanel = document.getElementById('go-live-panel');

    if (!setupID || !fileInput || !runBtn) return;

    // Enable "Run tests" when a file is selected.
    fileInput.addEventListener('change', () => {
        runBtn.disabled = !fileInput.files || fileInput.files.length === 0;
    });

    // -------------------------------------------------------------------------
    // Run button handler
    // -------------------------------------------------------------------------

    runBtn.addEventListener('click', async () => {
        if (!fileInput.files || fileInput.files.length === 0) return;

        runBtn.disabled = true;
        clearResults();
        setStatus('loading', 'Loading grading engine…');

        try {
            const solutionSource = await readFileAsText(fileInput.files[0]);

            // Fetch the assignment notebook to extract # TEST: cells.
            setStatus('loading', 'Fetching test definitions…');
            const notebookURL = `/api/v1/testsetups/${setupID}/assignment`;
            const nbRes = await fetch(notebookURL);
            if (!nbRes.ok) throw new Error(`Could not fetch assignment notebook: ${nbRes.status}. Make sure this test setup includes an assignment.ipynb.`);
            const notebook = await nbRes.json();

            setStatus('loading', 'Running tests…');
            const outcomes = await runSolutionAgainstNotebook(solutionSource, notebook);

            renderResults(outcomes);
            setStatus('', '');

            const allPassed = outcomes.length > 0 && outcomes.every(o => o.status === 'pass');
            if (allPassed) {
                goLivePanel.hidden = false;
            }
        } catch (err) {
            setStatus('error', `Error: ${err.message}`);
        } finally {
            runBtn.disabled = false;
        }
    });

    // -------------------------------------------------------------------------
    // Pyodide execution engine
    // -------------------------------------------------------------------------

    let pyodide = null;

    async function loadPyodideOnce() {
        if (pyodide) return pyodide;
        if (!window.loadPyodide) {
            await loadScript('https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js');
        }
        pyodide = await window.loadPyodide();
        return pyodide;
    }

    // Run the solution file then all # TEST: cells from the notebook.
    async function runSolutionAgainstNotebook(solutionSource, notebook) {
        const py = await loadPyodideOnce();

        // Fresh interpreter for each run.
        await py.runPythonAsync('import sys; sys.modules.clear()');

        // Step 1: Execute the solution file.
        try {
            await py.runPythonAsync(solutionSource);
        } catch (err) {
            const longResult = await captureTraceback(py, err);
            return [{
                testName:          'solution_load_error',
                testClass:         null,
                tier:              'public',
                status:            'error',
                shortResult:       `Solution failed to load: ${firstLine(err.message)}`,
                longResult,
                executionTimeMs:   0,
                memoryUsageBytes:  null,
                attemptNumber:     1,
                isFirstPassSuccess: false,
            }];
        }

        // Step 2: Run notebook setup cells (non-test code cells), then test cells.
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
                const outcome = await runTestCell(py, source, testMeta, startMs);
                outcomes.push(outcome);
            } else {
                // Setup cell (imports, helpers, etc.) — run silently.
                try {
                    await py.runPythonAsync(source);
                } catch (err) {
                    const longResult = await captureTraceback(py, err);
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

    // Run a single # TEST: cell and return a TestOutcome-shaped object.
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

    // -------------------------------------------------------------------------
    // Helpers (mirrored from notebook.js)
    // -------------------------------------------------------------------------

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

    function extractAssertionMessage(msg) {
        const line = msg.split('\n').find(l => l.includes('AssertionError'));
        if (!line) return null;
        const colon = line.indexOf(':');
        return colon >= 0 ? line.slice(colon + 1).trim() : null;
    }

    function firstLine(msg) {
        return (msg || '').split('\n')[0].trim();
    }

    // Parse "# TEST: name [key=value ...]" from the first line of a cell.
    function parseTestComment(source) {
        const line  = source.trimStart().split('\n')[0];
        const match = line.match(/^#\s*TEST:\s*(\S+)(.*)/);
        if (!match) return null;

        const name  = match[1];
        const kvStr = match[2].trim();
        const kv    = {};
        for (const part of kvStr.split(/\s+/)) {
            const [k, v] = part.split('=');
            if (k && v !== undefined) kv[k] = v;
        }
        return { name, tier: kv.tier || 'public' };
    }

    function readFileAsText(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload  = e => resolve(e.target.result);
            reader.onerror = () => reject(new Error('Could not read file'));
            reader.readAsText(file);
        });
    }

    // -------------------------------------------------------------------------
    // Inline results rendering (same CSS as submission.leaf / notebook.js)
    // -------------------------------------------------------------------------

    function clearResults() {
        if (resultsEl) {
            resultsEl.hidden  = true;
            resultsEl.innerHTML = '';
        }
        if (goLivePanel) goLivePanel.hidden = true;
    }

    function renderResults(outcomes) {
        if (!resultsEl) return;

        const pass    = outcomes.filter(o => o.status === 'pass').length;
        const total   = outcomes.length;
        const totalMs = outcomes.reduce((s, o) => s + o.executionTimeMs, 0);
        const allPassed = pass === total && total > 0;

        const scoreEl = document.createElement('p');
        scoreEl.className = 'score';
        scoreEl.innerHTML =
            `${pass} / ${total} passed ` +
            `<span class="exec-time">(${totalMs} ms)</span>` +
            (allPassed ? ' <span style="color:var(--green)">✓ All tests passed!</span>' : '');

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

        resultsEl.innerHTML = '';
        resultsEl.appendChild(scoreEl);
        resultsEl.appendChild(table);
        resultsEl.hidden = false;
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
    // Misc helpers
    // -------------------------------------------------------------------------

    function setStatus(type, msg) {
        statusEl.textContent = msg;
        statusEl.className   = `nb-status${type ? ' nb-status-' + type : ''}`;
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
})();
