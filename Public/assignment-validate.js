// Public/assignment-validate.js
//
// In-browser solution validator for the assignment validation page.
//
// Workflow:
//   1. Instructor selects a .py / .ipynb solution file via the file input.
//   2. Clicking "Run tests" uses BrowserRunner to fetch the setup zip and
//      current manifest, then runs the manifest's configured test scripts.
//   3. Results are rendered inline (same CSS classes as submission.leaf).
//   4. If all tests pass, the "Go live" panel is revealed.
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
            const solutionFile = fileInput.files[0];
            const solutionBytes = await readFileAsBytes(solutionFile);

            setStatus('loading', 'Running tests…');
            if (!window.BrowserRunner || typeof window.BrowserRunner.runScripts !== 'function') {
                throw new Error('Browser runner failed to load.');
            }
            const result = await window.BrowserRunner.runScripts(solutionBytes, setupID, {
                filename: solutionFile.name || 'submission.ipynb',
            });
            const outcomes = result.outcomes || [];

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
    // Kernel language detection
    // -------------------------------------------------------------------------

    // Returns 'r' for R notebooks (ir / r / webr kernelspec) or 'python' otherwise.
    function notebookKernelLanguage(notebook) {
        const ks = notebook.metadata && notebook.metadata.kernelspec;
        if (ks) {
            const name = (ks.name || '').toLowerCase();
            const lang = (ks.language || '').toLowerCase();
            if (name === 'ir' || name === 'r' || name === 'webr' || lang === 'r') return 'r';
        }
        const li = notebook.metadata && notebook.metadata.language_info;
        if (li && (li.name || '').toLowerCase() === 'r') return 'r';
        return 'python';
    }

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
        {
            const { stdout, stderr, error } = await withStreams(py, () => py.runPythonAsync(solutionSource));
            if (error) {
                const traceback = await captureTraceback(py, error);
                return [{
                    testName:          'solution_load_error',
                    testClass:         null,
                    tier:              'public',
                    status:            'error',
                    shortResult:       `Solution failed to load: ${firstLine(error.message)}`,
                    longResult:        formatStreams(stdout, stderr, traceback),
                    executionTimeMs:   0,
                    memoryUsageBytes:  null,
                    attemptNumber:     1,
                    isFirstPassSuccess: false,
                }];
            }
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
                {
                    const { stdout, stderr, error } = await withStreams(py, () => py.runPythonAsync(source));
                    if (error) {
                        const traceback = await captureTraceback(py, error);
                        outcomes.push({
                            testName:          'setup_error',
                            testClass:         null,
                            tier:              'public',
                            status:            'error',
                            shortResult:       `Setup cell failed: ${firstLine(error.message)}`,
                            longResult:        formatStreams(stdout, stderr, traceback),
                            executionTimeMs:   Date.now() - startMs,
                            memoryUsageBytes:  null,
                            attemptNumber:     1,
                            isFirstPassSuccess: false,
                        });
                        break;
                    }
                }
            }
        }

        return outcomes;
    }

    // Run a single # TEST: cell and return a TestOutcome-shaped object.
    async function runTestCell(py, source, meta, startMs) {
        let status      = 'pass';
        let shortResult = 'passed';
        let traceback   = null;

        const { stdout, stderr, error } = await withStreams(py, () => py.runPythonAsync(source));

        if (error) {
            const msg = error.message || String(error);
            traceback = await captureTraceback(py, error);

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
            longResult:        formatStreams(stdout, stderr, traceback),
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

    // Run fn() while capturing Pyodide stdout/stderr. Always resets streams.
    // Returns { stdout, stderr, error } where error is non-null if fn() threw.
    async function withStreams(py, fn) {
        const stdoutChunks = [], stderrChunks = [];
        py.setStdout({ batched: (s) => stdoutChunks.push(s) });
        py.setStderr({ batched: (s) => stderrChunks.push(s) });
        let error = null;
        try { await fn(); }
        catch (e) { error = e; }
        finally { py.setStdout({}); py.setStderr({}); }
        return {
            stdout: stdoutChunks.join('').trimEnd(),
            stderr: stderrChunks.join('').trimEnd(),
            error,
        };
    }

    // Build a longResult string from captured streams and optional traceback.
    // Matches the section format produced by the runner ("stdout:\n…", etc.).
    function formatStreams(stdout, stderr, traceback) {
        const sections = [];
        if (stdout)   sections.push(`stdout:\n${stdout}`);
        if (stderr)   sections.push(`stderr:\n${stderr}`);
        if (traceback) sections.push(`traceback:\n${traceback}`);
        return sections.length ? sections.join('\n\n') : null;
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

    function readFileAsBytes(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = e => resolve(new Uint8Array(e.target.result));
            reader.onerror = () => reject(new Error('Could not read file'));
            reader.readAsArrayBuffer(file);
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
            tr.innerHTML = `
                <td><code>${escHtml(o.displayName || o.testName)}</code></td>
                <td><span class="tier">${escHtml(o.tier)}</span></td>
                <td>${escHtml(o.shortResult)}${buildOutputPanes(o)}</td>
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

    // Build collapsible output panes from a longResult string.
    // Recognises "stdout:\n…", "stderr:\n…", "traceback:\n…" section headers
    // produced by both the runner and the Pyodide validator. Falls back to a
    // single pane if no headers are found.
    function buildOutputPanes(o) {
        if (!o.longResult) return '';
        const failing = o.status !== 'pass';

        const sectionRe = /^(stdout|stderr|traceback):\n/gm;
        const matches = [...o.longResult.matchAll(sectionRe)];
        if (matches.length === 0) {
            return `<details${failing ? ' open' : ''}><summary>details</summary><pre>${escHtml(o.longResult)}</pre></details>`;
        }

        let html = '';
        for (let i = 0; i < matches.length; i++) {
            const name    = matches[i][1];
            const start   = matches[i].index + matches[i][0].length;
            const end     = i + 1 < matches.length ? matches[i + 1].index : o.longResult.length;
            const content = o.longResult.slice(start, end).trimEnd();
            if (!content) continue;
            const autoOpen = failing && (name === 'stderr' || name === 'traceback');
            html += `<details class="stream-pane stream-${name}"${autoOpen ? ' open' : ''}><summary>${name}</summary><pre>${escHtml(content)}</pre></details>`;
        }
        return html;
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
